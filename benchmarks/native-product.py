#!/usr/bin/env python3
"""Exercise the opt-in Conjet CLI and measure the authenticated native API."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import base64
import contextlib
import hashlib
import json
import os
from pathlib import Path
import runpy
import secrets
import select
import signal
import socket
import subprocess
import time

REPO = Path(__file__).resolve().parents[1]
WIRE = runpy.run_path(str(REPO / 'benchmarks/native-fresh-lifecycle.py'))
SCRATCH = WIRE['SCRATCH']
PRODUCTION = runpy.run_path(str(REPO / 'build-support/run-conjet-speedup.py'))
TOOLS = runpy.run_path(str(REPO / 'benchmarks/fresh-lifecycle.py'))


def hash_file(path, algorithm='sha256'):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, algorithm).hexdigest()


class Candidate:
    def __init__(self, args, report):
        self.args = args
        self.report = report
        self.cli = [str(args.cli), 'native', '--experimental']
        self.env = {'PATH': '/usr/bin:/bin', 'CONJET_CORE_VMM_PATH': str(args.vmm)}

    @contextlib.contextmanager
    def boot(self, workload):
        command = self.cli + [
            'serve', '--scratch', str(SCRATCH), '--kernel', str(self.args.kernel),
            '--kernel-sha512', self.args.kernel_sha512, '--executable', str(workload),
            '--sha256', hash_file(workload),
        ]
        if self.args.guest_init:
            command += ['--guest-init', str(self.args.guest_init)]
        record = {'command': command, 'load_start': os.getloadavg()}
        self.report['boots'].append(record)
        with (self.args.output / f'boot-{len(self.report["boots"])}.stderr').open('w+') as log:
            with subprocess.Popen(command, env=self.env, stdout=subprocess.PIPE, stderr=log,
                                  text=True) as vm:
                directory = None
                try:
                    if not select.select([vm.stdout], [], [], 20)[0]:
                        raise RuntimeError('candidate did not report readiness within 20 seconds')
                    line = vm.stdout.readline()
                    if not line:
                        log.seek(0)
                        raise RuntimeError(f'candidate exited before readiness: {log.read().strip()}')
                    ready = json.loads(line)
                    directory = Path(ready['session'])
                    assert directory.parent == SCRATCH and directory.stat().st_mode & 0o777 == 0o700
                    assert vm.pid == ready['pid'] and TOOLS['current_executable'](vm.pid) == self.args.vmm
                    assert ready['image_digest'] == 'sha256:' + hash_file(workload)
                    self.vm, self.directory, self.digest = vm, directory, ready['image_digest']
                    assert not (directory / 'unused.sock').exists()
                    record['host_before'] = self.host_sample()
                    yield record
                    if vm.poll() is None:
                        record['host_after'] = self.host_sample()
                        self.command('stop')
                    assert vm.wait(timeout=10) == 0
                    record['shutdown'] = json.loads(vm.stdout.readline())
                    assert record['shutdown']['guest_cleanup'] == 'complete'
                    assert record['shutdown']['reclaim_failures'] == 0
                    record['shutdown_verified'] = True
                finally:
                    if vm.poll() is None:
                        vm.send_signal(signal.SIGTERM)
                        try:
                            vm.wait(timeout=15)
                        except subprocess.TimeoutExpired:
                            vm.kill()
                            vm.wait(timeout=5)
                    if directory is not None:
                        record['directory_removed'] = not directory.exists()
                        assert record['directory_removed'], f'session directory remained: {directory}'
                    record['pid_exited'] = vm.poll() is not None
                    record['load_end'] = os.getloadavg()

    def host_sample(self):
        return {'load': os.getloadavg(),
                'cpu_time_rss_kib': TOOLS['run'](['/bin/ps', '-p', str(self.vm.pid), '-o', 'time=,rss='])}

    def cli_args(self, action, *extra):
        return self.cli + [action, '--session', str(self.directory), *extra]

    def command(self, action, *extra, expected=None):
        args = self.cli_args(action, *extra)
        start = time.monotonic_ns()
        result = subprocess.run(args, env=self.env, text=True, capture_output=True, timeout=15)
        elapsed_ns = time.monotonic_ns() - start
        if expected:
            assert result.returncode and expected in result.stderr, (args, result)
        else:
            assert result.returncode == 0, (args, result)
        return {'elapsed_ns': elapsed_ns, 'stdout': json.loads(result.stdout) if result.stdout else None,
                'stderr': result.stderr, 'returncode': result.returncode}

    @contextlib.contextmanager
    def channel(self):
        with socket.socket(socket.AF_UNIX) as channel:
            channel.settimeout(8)
            channel.connect(str(self.directory / 'native-launch.sock'))
            assert channel.getsockopt(0, 2) == self.vm.pid
            boot = WIRE['authenticate'](channel, (self.directory / 'launch.key').read_bytes(),
                                        'native_static_arm64_v1')
            yield channel, boot

    def request(self, boot, sequence):
        return {'boot_id': boot, 'sequence': sequence, 'budget_ms': 3000,
                'operation_id': secrets.token_hex(16),
                'spec': {'image_digest': self.digest, 'argv': ['/bin/probe'],
                         'env': [], 'cwd': '/work', 'uid': 65532, 'gid': 65532, 'network': 'none',
                         'limits': {'memory_bytes': 16 * 1024 * 1024, 'pids': 4, 'cpu_millicores': 500}}}


def call(channel, opcode, body, expected):
    kind, response = WIRE['call'](channel, opcode, body)
    assert kind == expected, (opcode, kind, response)
    return response


def wait_phase(channel, state, *phases):
    while state['phase'] not in phases:
        assert state['phase'] not in ('removed', 'cleanup_failed'), state
        state = call(channel, 10, {'handle': state['handle'], 'after_revision': state['revision'],
                                   'budget_ms': 6000}, 13)
    return state


def cleaned(state):
    assert state['phase'] == 'removed' and state['cleanup'] == 'complete' and not state['helper_failed'], state
    return state


def success(state):
    assert state['exec'] == 'confirmed' and state['exit'] == {'code': 0}, state
    return cleaned(state)


def collect_samples(candidate, record, samples):
    timers = record['samples'] = {'fresh_api': [], 'prepared_api': [], 'fresh_cli': [], 'prepared_cli': []}
    record['warmups_per_lane'] = 10
    with candidate.channel() as (channel, boot):
        for mode, entries in timers.items():
            window = time.monotonic_ns()
            for index in range(samples + 10):
                if index == 10:
                    window = time.monotonic_ns()
                started = time.monotonic_ns()
                row = {'index': index, 'warmup': index < 10}
                entries.append(row)
                if mode.endswith('_api'):
                    sequence = call(channel, 20, {'budget_ms': 1000}, 20)['last_sequence'] + 1
                    started = time.monotonic_ns()
                    request = candidate.request(boot, sequence)
                    prepared = mode == 'prepared_api'
                    accept = call(channel, 17 if prepared else 8, request, 13)
                    if prepared:
                        ready = wait_phase(channel, accept, 'prepared_ready')
                        row['refill_ns'] = time.monotonic_ns() - started
                        started = time.monotonic_ns()
                        accept = call(channel, 18, {'handle': ready['handle'], 'spec': request['spec'],
                                                    'budget_ms': 3000}, 13)
                    row['acceptance_ns'] = time.monotonic_ns() - started
                    row['state'] = success(wait_phase(channel, accept, 'removed'))
                    row['elapsed_ns'] = time.monotonic_ns() - started
                else:
                    if mode == 'prepared_cli':
                        result = candidate.command('prepare')
                        row['refill_ns'] = result['elapsed_ns']
                        token = result['stdout']['result']['token']
                        result = candidate.command('claim', token)
                    else:
                        result = candidate.command('run')
                    row['elapsed_ns'] = result['elapsed_ns']
                    row['state'] = success(result['stdout']['result']['state'])
            record.setdefault('windows_ns', {})[mode] = time.monotonic_ns() - window
    miss = candidate.command('status')['stdout']['result']['workload']['token']
    record['one_use_miss'] = candidate.command('claim', miss, expected='slot_unavailable')
    prepared = candidate.command('prepare')['stdout']['result']['token']
    candidate.command('prepare', expected='busy')
    time.sleep(5.2)
    record['expiry'] = candidate.command('claim', prepared, expected='slot_unavailable')
    state = candidate.command('status')['stdout']['result']['workload']
    assert cleaned(state)['prepared_expired'] is True, state


def live_check(candidate, record):
    with candidate.channel() as (channel, boot):
        request = candidate.request(boot, 1)
        request['spec']['network'] = 'bridge'
        unsupported = call(channel, 8, request, 15)
        assert unsupported['code'] == 'unsupported_option'
        request = candidate.request(boot, 1)
        ready = wait_phase(channel, call(channel, 17, request, 13), 'prepared_ready')
        assert candidate.command('memory')['stdout']['result']['prepared']['sample_valid']
        on = candidate.command('memory', '--pressure', 'on')
        assert on['stdout']['result']['pressure_evictions'] == 1
        assert cleaned(wait_phase(channel, ready, 'removed'))['exec'] == 'failed'
        candidate.command('prepare', expected='memory_pressure')
        candidate.command('memory', '--pressure', 'off')
        request = candidate.request(boot, 2)
        running = wait_phase(channel, call(channel, 8, request, 13), 'running')
        conflict = call(channel, 8, candidate.request(boot, 3), 15)
        assert conflict['code'] == 'busy'
        time.sleep(0.15)
        active = candidate.command('memory', '--pressure', 'on')['stdout']['result']
        assert active['pressure_evictions'] == 1 and active['active']['sample_valid']
        assert active['active']['current_bytes'] >= 8 * 1024 * 1024, active
        record['pressure_active'] = active
        terminal = success(wait_phase(channel, running, 'removed'))
        record['pressure_preserved'] = terminal
        candidate.command('memory', '--pressure', 'off')

    with candidate.channel() as (channel, boot):
        sequence = call(channel, 20, {'budget_ms': 1000}, 20)['last_sequence'] + 1
        body = candidate.request(boot, sequence)
        ready = wait_phase(channel, call(channel, 17, body, 13), 'prepared_ready')

        def claim_once():
            with candidate.channel() as (peer, _):
                return WIRE['call'](peer, 18, {'handle': ready['handle'], 'spec': body['spec'],
                                               'budget_ms': 3000})

        with ThreadPoolExecutor(max_workers=2) as pool:
            contenders = list(pool.map(lambda _: claim_once(), range(2)))
        assert sorted(kind for kind, _ in contenders) == [13, 15], contenders
        record['concurrent_claims'] = contenders
        success(wait_phase(channel, ready, 'removed'))

    with contextlib.ExitStack() as peers:
        for _ in range(4):
            peers.enter_context(candidate.channel())
        overloaded = candidate.command('status', expected='Error:')
        record['connection_backpressure'] = overloaded
    candidate.command('status')

    completed = candidate.command('run')['stdout']['result']
    for output in (completed['stdout'], completed['stderr']):
        data = base64.b64decode(output['base64'], validate=True)
        assert len(data) == 65536 and output['dropped_bytes'] == 32768 and data[:2] == b'Z\0'
    record['output_bounds'] = {name: completed[name]['dropped_bytes'] for name in ('stdout', 'stderr')}

    with candidate.channel() as (channel, boot):
        sequence = call(channel, 20, {'budget_ms': 1000}, 20)['last_sequence'] + 1
        request = candidate.request(boot, sequence)
        admitted = call(channel, 8, request, 13)
        handle = admitted['handle']
    # The request was admitted before connection loss. Repeating the exact body
    # returns its original handle, and cancelling it never creates new work.
    with candidate.channel() as (channel, _):
        replay = call(channel, 8, request, 13)
        assert replay['handle'] == handle
        conflicting = dict(request, operation_id=secrets.token_hex(16))
        assert call(channel, 8, conflicting, 15)['code'] == 'id_conflict'
        token = handle['boot_id'] + '.' + handle['workload_id']
        cancel = candidate.command('cancel', token)
        record['disconnect_cancel'] = cleaned(cancel['stdout']['result'])
    record['deadline'] = candidate.command('run', '--timeout-ms', '150', expected='verified cleanup')
    record['recovery'] = success(candidate.command('run')['stdout']['result']['state'])
    candidate.vm.send_signal(signal.SIGTERM)
    assert candidate.vm.wait(timeout=12) == 0
    record['foreground_sigterm'] = True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('cli', 'vmm', 'kernel', 'executable', 'canary', 'output'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--guest-init', type=Path)
    parser.add_argument('--kernel-sha512', required=True)
    parser.add_argument('--samples', type=int, default=100)
    args = parser.parse_args()
    if not 20 <= args.samples <= 2000:
        parser.error('--samples must be between 20 and 2,000')
    for name in ('cli', 'vmm', 'kernel', 'executable', 'canary', 'guest_init'):
        path = getattr(args, name)
        if path is not None:
            path = path.resolve(strict=True)
            if not path.is_relative_to(SCRATCH):
                parser.error(f'--{name} must reside on ExternalSSD')
            setattr(args, name, path)
    if not args.output.parent.resolve().is_relative_to(SCRATCH):
        parser.error('--output must reside on ExternalSSD')
    args.output.mkdir(mode=0o700)
    before = PRODUCTION['production']()
    report = {
        'production_before': before, 'boots': [], 'passed': False,
        'revision': TOOLS['run'](['/usr/bin/git', 'rev-parse', 'HEAD']),
        'system': TOOLS['run'](['/usr/bin/sw_vers']),
        'files': {name: {'path': str(path), 'sha256': hash_file(path)}
                  for name in ('cli','vmm','kernel','executable','canary','guest_init')
                  if (path := getattr(args, name)) is not None},
        'timing': 'Host monotonic, API admission or claim until verified cleanup; CLI process through exit and output.',
        'vm': {'vcpus': 2, 'memory_mib': 2048, 'host_tick_ms': 25, 'network': 'none'},
    }
    candidate = Candidate(args, report)
    try:
        rejected = subprocess.run([str(args.cli), 'native', 'status', '--session', str(SCRATCH)],
                                  capture_output=True, text=True, env=candidate.env, timeout=5)
        assert rejected.returncode and '--experimental' in rejected.stderr
        report['explicit_opt_in'] = True
        with candidate.boot(args.canary) as record:
            live_check(candidate, record)
        with candidate.boot(args.executable) as record:
            collect_samples(candidate, record, args.samples)
        report['passed'] = True
    except BaseException as error:
        report['failure'] = repr(error)
        raise
    finally:
        report['production_after'] = PRODUCTION['production']()
        report['passed'] &= report['production_after'] == before
        (args.output / 'session.json').write_text(json.dumps(report, indent=2) + '\n')
    if not report['passed']:
        raise RuntimeError('production verification failed')


if __name__ == '__main__':
    main()
