import json
from pathlib import Path
import runpy
import subprocess
import tempfile
import threading
import unittest

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
    def test_rejects_unsupported_ordinary_create_options(self):
        make = SERVER['make_process']
        spec = {'Image': IMAGE, 'User': '65532:65532', 'Cmd': ['/bin/sh'],
                'HostConfig': {'NetworkMode': 'none', 'Memory': 16777216,
                               'NanoCpus': 500000000, 'PidsLimit': 4}}
        self.assertEqual(make(spec, IMAGE, METADATA)['env'], ['PATH=/bin'])
        spec['HostConfig']['Binds'] = ['/unexpected:/mnt']
        with self.assertRaisesRegex(SERVER['Rejected'], 'Binds'):
            make(spec, IMAGE, METADATA)

    def test_unmodified_docker_cli_negotiates_attaches_and_waits_once(self):
        docker = Path('/opt/homebrew/bin/docker')
        transport = TransportStub()
        owner = SERVER['Owner'](transport, IMAGE, METADATA)
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


if __name__ == '__main__':
    unittest.main()
