import json
import os
from pathlib import Path
import runpy
import subprocess
import tempfile
import threading
import unittest
from unittest.mock import Mock, patch

HERE = Path(__file__).resolve().parent
SERVER = runpy.run_path(str(HERE.parent / 'build-support/conjet-native-docker.py'))
MANIFEST = json.loads((HERE / 'scenarios/docker-comparison-v1.json').read_text())
IMAGE = MANIFEST['images']['alpine']['ref']
METADATA = {
    'config_digest': 'sha256:' + '1' * 64,
    'process': {'Entrypoint': [], 'Cmd': ['/bin/sh'], 'Env': ['PATH=/bin'], 'WorkingDir': '/'},
}


class TransportStub:
    def __init__(self):
        self.calls = []

    def execute(self, process, cancellation):
        self.calls.append(process)
        return 23, b'fixture-out', b'fixture-err', {'cleanup': 'complete'}


class NativeDockerTests(unittest.TestCase):
    def make_native(self, exchange, *, trace=None):
        with tempfile.TemporaryDirectory(dir=SERVER['SCRATCH']) as temporary:
            root = Path(temporary)
            (root / 'launch.key').write_bytes(bytes(32))
            (root / 'native-session.json').write_text(json.dumps({
                'pid': os.getpid(), 'image_digest': METADATA['config_digest']}))
            connection = Mock()
            connection.getsockopt.return_value = os.getpid()
            auth = Mock(return_value='boot')
            native_type = SERVER['Native']
            with patch.object(native_type.execute.__globals__['socket'], 'socket', return_value=connection):
                with patch.dict(native_type.execute.__globals__['WIRE'], {'authenticate': auth, 'call': exchange}):
                    native = native_type(root, METADATA['config_digest'], trace)
        self.addCleanup(native.close)
        auth.assert_called_once_with(connection, bytes(32), 'native_oci_arm64_v1')
        return native, connection

    def test_one_authenticated_lease_advances_identity_and_closes(self):
        handle = {'boot_id': 'boot', 'workload_id': 'workload'}
        operations = []

        def exchange(_channel, opcode, request):
            if opcode == 20:
                return 20, {'image_digest': METADATA['config_digest'], 'workload': None,
                            'boot_id': 'boot', 'last_sequence': 4}
            if opcode == 8:
                operations.append(request)
                return 13, {'handle': handle, 'cleanup': 'pending'}
            self.assertEqual(opcode, 10)
            self.assertTrue(request['terminal_output'])
            stdout = {'data': 'b3V0', 'offset': 0, 'next_offset': 3, 'dropped_bytes': 0, 'eof': True}
            stderr = {'data': '', 'offset': 0, 'next_offset': 0, 'dropped_bytes': 0, 'eof': True}
            return 13, {'handle': handle, 'cleanup': 'complete', 'exit': {'code': 0}, 'exec': 'confirmed',
                        'terminal_output': {'stdout': stdout, 'stderr': stderr}}

        trace = SERVER['Trace']()
        native, connection = self.make_native(exchange, trace=trace)
        with patch.dict(native.execute.__globals__['WIRE'], {'call': exchange}):
            cancellation = threading.Event()
            cancellation.set()
            self.assertEqual(native.execute({}, cancellation)[0], 137)
            cancellation.clear()
            for _ in range(2):
                code, stdout, stderr, state = native.execute({}, cancellation)
                self.assertEqual((code, stdout, stderr), (0, b'out', b''))
                self.assertEqual(state['adapter_output_calls'], 0)
        self.assertEqual([op['sequence'] for op in operations], [5, 6])
        self.assertEqual(len({op['operation_id'] for op in operations}), 2)
        self.assertEqual([row['event'] for row in trace.rows].count('native_connect'), 1)
        self.assertIsNone(native.pending)
        native.close()
        native.close()
        connection.close.assert_called_once()

    def test_malformed_inline_cursor_is_rejected(self):
        native = SERVER['Native'].__new__(SERVER['Native'])
        stdout = {'data': 'b3V0', 'offset': 0, 'next_offset': 2, 'dropped_bytes': 0, 'eof': True}
        with self.assertRaisesRegex(RuntimeError, 'invalid native output chunk'):
            native.read_output(None, {}, {'terminal_output': {'stdout': stdout, 'stderr': {}}})

    def test_disconnect_timeout_and_reboot_fail_closed_without_replaying(self):
        for case in ('disconnect-before-reply', 'disconnect-after-admit', 'timeout', 'boot-changed'):
            with self.subTest(case=case):
                opcodes = []

                def exchange(_channel, opcode, request):
                    opcodes.append(opcode)
                    if opcode == 20:
                        return 20, {'image_digest': METADATA['config_digest'], 'workload': None,
                                    'boot_id': 'boot', 'last_sequence': 0}
                    if opcode == 8:
                        if case == 'disconnect-before-reply':
                            raise EOFError('no launch reply')
                        return 13, {'cleanup': 'pending', 'handle': {'workload_id': 'workload',
                                    'boot_id': 'rebooted' if case == 'boot-changed' else 'boot'}}
                    self.assertEqual(opcode, 10)
                    if case == 'timeout':
                        raise TimeoutError('native channel deadline')
                    raise ConnectionResetError('native channel reset')

                native, connection = self.make_native(exchange)
                with patch.dict(native.execute.__globals__['WIRE'], {'call': exchange}):
                    with self.assertRaises((EOFError, OSError, RuntimeError)):
                        native.execute({}, threading.Event())
                    with self.assertRaisesRegex(RuntimeError, 'channel is closed'):
                        native.execute({}, threading.Event())
                self.assertEqual(opcodes.count(8), 1)
                self.assertEqual(native.pending['sequence'], 1)
                self.assertEqual('handle' in native.pending, case in ('disconnect-after-admit', 'timeout'))
                connection.close.assert_called_once()

    def test_terminal_wait_timeout_observes_cancellation_without_replay(self):
        cancellation = threading.Event()
        operations = []
        handle = {'boot_id': 'boot', 'workload_id': 'workload'}

        def exchange(_channel, opcode, request):
            if opcode == 20:
                return 20, {'image_digest': METADATA['config_digest'], 'workload': None,
                            'boot_id': 'boot', 'last_sequence': 0}
            operations.append(opcode)
            if opcode == 8:
                self.assertEqual(request['sequence'], 1)
                return 13, {'handle': handle, 'cleanup': 'pending'}
            self.assertEqual(request['handle'], handle)
            if opcode == 10:
                self.assertEqual(request['after_revision'], 2**64 - 1)
                self.assertEqual(request['budget_ms'], 100)
                cancellation.set()
                return 15, {'code': 'deadline_exceeded'}
            if opcode == 11:
                return 13, {'handle': handle, 'cleanup': 'complete', 'exit': None}
            self.assertEqual(opcode, 12)
            return 14, {'data': '', 'offset': 0, 'next_offset': 0, 'dropped_bytes': 0, 'eof': True}

        native, _ = self.make_native(exchange)
        with patch.dict(native.execute.__globals__['WIRE'], {'call': exchange}):
            code, stdout, stderr, state = native.execute({'argv': ['/bin/true']}, cancellation)
        self.assertEqual((code, stdout, stderr), (137, b'', b''))
        self.assertEqual(state['adapter_wait_calls'], 1)
        self.assertEqual(operations, [8, 10, 11, 12, 12])

    def test_rejects_unsupported_ordinary_create_options(self):
        make = SERVER['make_process']
        spec = {'Image': IMAGE, 'User': '65532:65532', 'Cmd': ['/bin/sh'],
                'HostConfig': {'NetworkMode': 'none', 'Memory': 16777216,
                               'NanoCpus': 500000000, 'PidsLimit': 4}}
        self.assertEqual(make(spec, IMAGE, METADATA)['env'], ['PATH=/bin'])
        spec['HostConfig']['Binds'] = ['/unexpected:/mnt']
        with self.assertRaisesRegex(SERVER['Rejected'], 'Binds'):
            make(spec, IMAGE, METADATA)

    def test_lost_backend_disposition_prevents_replay_and_new_admission(self):
        class LostTransport:
            calls = 0

            def execute(self, process, cancellation):
                self.calls += 1
                raise ConnectionResetError('guest exited with execution unresolved')

        transport = LostTransport()
        owner = SERVER['Owner'](transport, IMAGE, METADATA)
        request = {'Image': IMAGE, 'User': '65532:65532', 'Cmd': ['/bin/sh'],
                   'HostConfig': {'NetworkMode': 'none', 'Memory': 16777216,
                                  'NanoCpus': 500000000, 'PidsLimit': 4}}
        item = owner.create('lost-backend', request)
        owner.start(item)
        owner.worker.join(3)
        self.assertFalse(owner.worker.is_alive())
        self.assertTrue(owner.poisoned)
        self.assertEqual(item.code, 125)
        self.assertEqual(item.error, 'guest exited with execution unresolved')
        with self.assertRaisesRegex(SERVER['Rejected'], 'already been submitted'):
            owner.start(item)
        with self.assertRaisesRegex(SERVER['Rejected'], 'cleanup is unresolved'):
            owner.remove(item, True)
        with self.assertRaisesRegex(SERVER['Rejected'], 'capacity is occupied or unresolved'):
            owner.create('next', request)
        self.assertEqual(transport.calls, 1)

    def test_unmodified_docker_cli_negotiates_attaches_and_waits_once(self):
        docker = Path('/opt/homebrew/bin/docker')
        transport = TransportStub()
        trace = SERVER['Trace']()
        owner = SERVER['Owner'](transport, IMAGE, METADATA, trace)
        with tempfile.TemporaryDirectory(dir=SERVER['SCRATCH']) as temporary:
            root = Path(temporary)
            endpoint = root / 'docker.sock'
            with SERVER['Server'](endpoint, owner) as bridge:
                worker = threading.Thread(target=bridge.serve_forever, daemon=False)
                worker.start()
                try:
                    config = root / 'docker'
                    config.mkdir()
                    args = [docker, '--config', config, '--host', f'unix://{endpoint}',
                            'run', '--rm', '--pull', 'never', '--network', 'none',
                            '--user', '65532:65532', '--memory', '16m', '--pids-limit', '4',
                            '--cpus', '0.5', '--workdir', '/tmp', '-e', 'PROOF=hello',
                            IMAGE, '/bin/sh', '-c', 'exit 23']
                    cmd = subprocess.run(args, env={'PATH': '/usr/bin:/bin'}, timeout=10, capture_output=True)
                    self.assertEqual((cmd.returncode, cmd.stdout, cmd.stderr),
                                     (23, b'fixture-out', b'fixture-err'), cmd)
                    self.assertEqual(len(transport.calls), 1)
                    self.assertEqual(transport.calls[0]['cwd'], '/tmp')
                    self.assertIn('PROOF=hello', transport.calls[0]['env'])
                    self.assertEqual([event['Action'] for event in owner.events],
                                     ['create', 'start', 'die', 'destroy'])
                finally:
                    bridge.shutdown()
                    worker.join(2)
            endpoint.unlink()
            records = list(trace.rows)
            requests = [row for row in records if row['event'] == 'http_request']
            self.assertTrue(any(row['path'] == '/_ping' for row in requests))
            for event in ('attach_headers', 'wait_headers', 'worker_enter', 'die', 'destroy',
                          'attach_output_written', 'wait_body_written'):
                self.assertEqual(sum(row['event'] == event for row in records), 1, event)
            self.assertGreaterEqual(len({row['connection'] for row in requests}), 2)
            self.assertEqual([row['host_ns'] for row in records],
                             sorted(row['host_ns'] for row in records))


if __name__ == '__main__':
    unittest.main()
