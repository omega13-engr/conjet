#!/usr/bin/env python3
"""Measure a staged ARM64 fixture on the disposable native launch endpoint."""
import argparse
import gzip
import hashlib
import hmac
import json
import os
import runpy
import secrets
import signal
import socket
import struct
import subprocess
import tempfile
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
SCRATCH = Path('/Volumes/ExternalSSD/dev_workspace/tmp')
HEADER = struct.Struct('>4sBBHI16s')


def receive(channel, correlation):
    def exact(size):
        data = bytearray()
        while len(data) < size:
            part = channel.recv(size - len(data))
            if not part:
                raise EOFError('native launch peer closed')
            data.extend(part)
        return data

    magic, version, reply, flags, size, echoed = HEADER.unpack(exact(HEADER.size))
    if (magic, version, flags, echoed) != (b'CJLS', 1, 0, correlation) or size > 16_384:
        raise RuntimeError('invalid native launch reply')
    return reply, json.loads(exact(size))


def send(channel, kind, body, correlation):
    payload = json.dumps(body, separators=(',', ':')).encode()
    channel.sendall(HEADER.pack(b'CJLS', 1, kind, 0, len(payload), correlation) + payload)


def call(channel, kind, body):
    correlation = secrets.token_bytes(16)
    send(channel, kind, body, correlation)
    return receive(channel, correlation)


def authenticate(channel, key):
    nonce = secrets.token_bytes(32)
    correlation = secrets.token_bytes(16)
    send(channel, 1, {'versions': [1], 'client_nonce': nonce.hex()}, correlation)
    reply, challenge = receive(channel, correlation)
    if reply != 2 or challenge.get('version') != 1:
        raise RuntimeError('unexpected native launch challenge')
    boot_id = challenge['boot_id']
    transcript = bytes([1, 1, 1]) + correlation + nonce
    transcript += bytes.fromhex(challenge['guest_nonce'] + boot_id)
    expected = hmac.digest(key, b'CJLS1G' + transcript, 'sha256').hex()
    if not hmac.compare_digest(challenge['proof'], expected):
        raise RuntimeError('native launch proof mismatch')
    # Both handshake responses use the hello correlation rather than a
    # newly generated operation ID.
    send(channel, 3, {'proof': hmac.digest(key, b'CJLS1H' + transcript, 'sha256').hex()}, correlation)
    reply, caps = receive(channel, correlation)
    if reply != 4 or caps.get('boot_id') != boot_id or 'private_bridge_fixture' not in caps.get('capabilities', []):
        raise RuntimeError('expected the fresh bridge fixture')
    return boot_id


def cpio_insert(archive, entries):
    def pad(data):
        return data + bytes(-len(data) % 4)

    offset = 0
    while offset + 110 <= len(archive):
        if archive[offset:offset + 6] != b'070701':
            raise ValueError('unexpected initramfs format')
        length = int(archive[offset + 54:offset + 62], 16)
        name_length = int(archive[offset + 94:offset + 102], 16)
        name = archive[offset + 110:offset + 109 + name_length]
        if name == b'TRAILER!!!':
            break
        offset = (offset + 110 + name_length + 3) & ~3
        offset += (length + 3) & ~3
    else:
        raise ValueError('initramfs trailer missing')
    staged = bytearray()
    for inode, (path, contents) in enumerate(entries.items(), 600):
        name = path.encode() + bytes(1)
        fields = (inode, 0o100600, 0, 0, 1, 0, len(contents), 0, 0, 0, 0, len(name), 0)
        staged.extend(pad(b'070701' + ''.join(f'{field:08x}' for field in fields).encode() + name))
        staged.extend(pad(contents))
    return archive[:offset] + staged + archive[offset:]


def state_sample(channel, boot_id, scenario, network, sequence):
    started = time.monotonic_ns()
    accepted_kind, accepted = call(channel, 8, {
        'boot_id': boot_id, 'sequence': sequence, 'budget_ms': 3_000,
        'spec': {'image_digest': scenario['manifest_digest'], 'argv': scenario['command'],
                 'env': [], 'cwd': '/work', 'uid': 65532, 'gid': 65532, 'network': network,
                 'limits': scenario['container_limits']},
    })
    accepted_ns = time.monotonic_ns() - started
    if accepted_kind != 13 or accepted['handle']['boot_id'] != boot_id:
        raise RuntimeError(f'native launch admission failed: {accepted}')
    kind, removed = call(channel, 10, {'handle': accepted['handle'], 'after_revision': 2**64 - 1,
                                        'budget_ms': 3000})
    if kind != 13 or removed['handle'] != accepted['handle']:
        raise RuntimeError(f'native launch wait failed: {removed}')
    return removed, accepted_ns


def run_samples(channel, boot_id, args, scenario, endpoint, key_file, peer, report):
    sequence = 0
    for network in scenario['networks']:
        for lane in scenario['lanes']:
            group = {'network': network, 'lane': lane, 'warmups': [], 'samples': []}
            report['groups'].append(group)
            for index in range(args.samples + scenario['warmups_per_lane']):
                sequence += 1
                row = {'sequence': sequence, 'error': None, 'api_removed_ns': None,
                       'cleanup_complete_ns': None}
                group['warmups' if index < scenario['warmups_per_lane'] else 'samples'].append(row)
                started = time.monotonic_ns()
                try:
                    if lane == 'api':
                        state, row['api_accepted_ns'] = state_sample(channel, boot_id, scenario, network, sequence)
                    else:
                        outcome = subprocess.run(
                            [args.client, endpoint, key_file, '--launch', scenario['manifest_digest'],
                             network, str(sequence), str(peer)],
                            check=False, capture_output=True, timeout=6, text=True,
                        )
                        if outcome.returncode:
                            row['client_stdout'] = outcome.stdout
                            raise RuntimeError(f'native launch client returned {outcome.returncode}: {outcome.stderr}')
                        client_report = json.loads(outcome.stdout)
                        row['client_lifecycle_ns'] = client_report['elapsed_ns']
                        state = client_report['state']
                    row['state'] = state
                    if (state['phase'] != 'removed' or state['cleanup'] != 'complete'
                            or state['exec'] != 'confirmed' or state['exit'] != {'code': 0}
                            or state['helper_failed'] or state['network_cleanup']
                            != ('complete' if network == 'bridge' else 'not_applicable')):
                        raise RuntimeError(f'fixture did not finish with verified cleanup: {state}')
                    row['cleanup_complete_ns'] = time.monotonic_ns() - started
                    if lane == 'api':
                        row['api_removed_ns'] = row['cleanup_complete_ns']
                except Exception as error:
                    row['error'] = str(error)
                    raise
                finally:
                    row['elapsed_ns'] = time.monotonic_ns() - started
            print(f'Completed native {network}/{lane}: {args.samples} samples', flush=True)


def session(args):
    adapter = runpy.run_path(str(REPO / 'benchmarks/fresh-lifecycle.py'))
    launcher = runpy.run_path(str(REPO / 'build-support/run-conjet-speedup.py'))
    scenario_path = args.image / 'scenario.json'
    scenario = json.loads(scenario_path.read_text())
    manifest_bytes = (args.image / 'oci-manifest.json').read_bytes()
    workload = (args.image / 'workload').read_bytes()
    if (scenario['manifest_digest'] != 'sha256:' + hashlib.sha256(manifest_bytes).hexdigest()
            or scenario['workload_sha256'] != hashlib.sha256(workload).hexdigest()):
        raise RuntimeError('staged fixture identity mismatch')
    args.output.mkdir(mode=0o700)
    before = launcher['production']()
    report = {'engine': 'native', 'scenario': scenario, 'groups': [], 'passed': False,
              'revision': adapter['run'](['/usr/bin/git', '-C', REPO, 'rev-parse', 'HEAD']),
              'scenario_sha256': adapter['file_hash'](scenario_path), 'production_before': before,
              'hashes': {str(path): adapter['file_hash'](path)
                         for path in (args.kernel, args.init, args.cli, args.vmm, args.client, args.network_helper)},
              'vcpus': 2, 'memory_mib': 2048, 'host_tick_ms': 25,
              'phase_trace': args.phase_trace, 'diagnostic_expedited_rcu': args.expedited_rcu,
              'cleanup_boundary': 'native removal reply requires verified cleanup'}
    with tempfile.TemporaryDirectory(prefix='cf-', dir=SCRATCH) as temporary:
        qa = Path(temporary)
        home = qa / 'h'
        root = home / 'state/vm'
        for directory in (root / 'bootstrap', home / 'run', home / 'logs', qa / 'tmp', qa / 'docker'):
            directory.mkdir(mode=0o700, parents=True)
        endpoint = home / 'run/native-launch.sock'
        key = secrets.token_bytes(32)
        key_file = qa / 'launch.key'
        with os.fdopen(os.open(key_file, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600), 'wb') as stream:
            stream.write(key)
        disk = root / 'fresh.raw'
        with disk.open('wb') as stream:
            stream.truncate(16 * 1024 * 1024)
        kernel = root / 'Image'
        kernel.write_bytes(args.kernel.read_bytes())
        initrd = root / 'native.cpio.gz'
        manifest_path = root / 'manifest.json'
        manifest = {'name': 'native-fresh-benchmark', 'architecture': 'arm64', 'bootLoaderKind': 'linuxKernel',
                    'kernelPath': str(kernel), 'initialRamdiskPath': str(initrd), 'rootDiskPath': str(disk),
                    'bootstrapSharePath': str(root / 'bootstrap'), 'serialLogPath': str(home / 'logs/serial.log'),
                    'dockerSocketPath': str(home / 'run/docker.sock'), 'source': 'isolated benchmark',
                    'kernelCommandLine': 'console=ttyAMA0 '
                    + ('rcupdate.rcu_expedited=1 ' if args.expedited_rcu else '')
                    + 'rdinit=/init --serve-fresh-fixture quiet'}
        report['kernel_command_line'] = manifest['kernelCommandLine']
        manifest_path.write_text(json.dumps(manifest))
        launcher['vm_paths'](manifest, home, home / 'run/docker.sock')
        env = {'HOME': str(qa), 'CONJET_HOME': str(home), 'DOCKER_CONFIG': str(qa / 'docker'),
               'TMPDIR': str(qa / 'tmp'), 'PATH': '/usr/bin:/bin',
               'CONJET_NETWORK_HELPER_PATH': str(args.network_helper)}
        command = [args.vmm, 'boot', '--manifest', manifest_path, '--memory-mib', '2048', '--cpus', '2',
                   '--max-exits', str(2**64 - 1), '--max-runtime-ms', str(args.runtime_ms),
                   '--host-tick-ms', '25', '--early-console-only', '--enable-native-launch', '--json']
        report['command'] = list(map(str, command))
        try:
            subprocess.run([args.cli, 'vm', 'build-initramfs', '--init', args.init,
                            '--output', initrd, '--json'], env=env, check=True, timeout=15)
            descriptor = {'architecture': 'arm64', 'os': 'linux',
                          'executable_sha256': adapter['file_hash'](args.init)}
            assets = {
                'etc/conjet/launch.key': key, 'etc/conjet/fresh-fixture-image.json': json.dumps(descriptor).encode(),
                'etc/conjet/benchmark-image.json': manifest_bytes, 'etc/conjet/benchmark-executable': workload,
            }
            if args.phase_trace:
                assets['etc/conjet/benchmark-timing'] = b'1\n'
            initrd.write_bytes(gzip.compress(cpio_insert(
                gzip.decompress(initrd.read_bytes()), assets,
            ), mtime=0))
            with (args.output / 'vm.json').open('w') as stdout, (args.output / 'vm.stderr.log').open('w') as stderr:
                with subprocess.Popen(command, env=env, stdout=stdout, stderr=stderr, start_new_session=True) as vm:
                    try:
                        channel, boot_id = open_native(endpoint, key, vm, args.vmm, adapter['current_executable'])
                        with channel:
                            report['host_before'] = process_observation(vm.pid, adapter['run'])
                            run_samples(channel, boot_id, args, scenario, endpoint, key_file, vm.pid, report)
                            report['host_after'] = process_observation(vm.pid, adapter['run'])
                            kind, result = call(channel, 7, {'budget_ms': 3000})
                            if kind != 16 or result['state'] != 'stopped' or vm.wait(timeout=12) != 0:
                                raise RuntimeError('native fixture did not shut down')
                            if endpoint.exists():
                                raise RuntimeError('native socket remained after shutdown')
                            report['passed'] = True
                    finally:
                        if vm.poll() is None:
                            os.killpg(vm.pid, signal.SIGTERM)
                            try:
                                vm.wait(timeout=8)
                            except subprocess.TimeoutExpired:
                                os.killpg(vm.pid, signal.SIGKILL)
                                vm.wait(timeout=5)
        except (Exception, KeyboardInterrupt) as error:
            report['error'] = str(error) or type(error).__name__
            raise
        finally:
            for group in report['groups']:
                group['summary'] = adapter['summarize'](group['samples'])
            report['production_after'] = launcher['production']()
            report['passed'] &= report['production_after'] == before
            (args.output / 'session.json').write_text(json.dumps(report, indent=2) + '\n')
    if not report['passed']:
        raise RuntimeError('native benchmark verification failed')


def process_observation(pid, run):
    return {'load_average': os.getloadavg(),
            'cpu_time_and_rss': run(['/bin/ps', '-p', str(pid), '-o', 'pid=,time=,rss='])}


def open_native(endpoint, key, vm, vmm, executable):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline and vm.poll() is None:
        channel = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            channel.settimeout(5)
            channel.connect(str(endpoint))
            if channel.getsockopt(0, 2) != vm.pid or executable(vm.pid) != vmm:
                raise RuntimeError('native socket is outside its owned VMM')
            return channel, authenticate(channel, key)
        except (FileNotFoundError, ConnectionError, EOFError, TimeoutError):
            channel.close()
            time.sleep(0.1)
        except BaseException:
            channel.close()
            raise
    raise RuntimeError('owned native VMM did not become ready')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('kernel', 'init', 'cli', 'vmm', 'client', 'image', 'output'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--network-helper', type=Path, required=True)
    parser.add_argument('--samples', type=int, default=100)
    parser.add_argument('--runtime-ms', type=int, default=180_000)
    parser.add_argument('--phase-trace', action='store_true')
    parser.add_argument('--expedited-rcu', action='store_true',
                        help='change the benchmark guest kernel only for an RCU diagnostic')
    args = parser.parse_args()
    if not 1 <= args.samples <= 10_000 or not 10_000 <= args.runtime_ms <= 3_600_000:
        parser.error('sample count or VM runtime out of range')
    for name in ('kernel', 'init', 'cli', 'vmm', 'client', 'image', 'network_helper'):
        path = getattr(args, name).resolve(strict=True)
        if not path.is_relative_to(SCRATCH):
            parser.error('use benchmark inputs under designated ExternalSSD scratch')
        setattr(args, name, path)
    if args.output.exists() or not args.output.is_absolute() or not args.output.parent.resolve().is_relative_to(SCRATCH):
        parser.error('output must be a new directory under the designated ExternalSSD root')
    signal.signal(signal.SIGTERM, lambda *_: signal.raise_signal(signal.SIGINT))
    session(args)


if __name__ == '__main__':
    main()
