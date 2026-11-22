#!/usr/bin/env python3
"""Measure a staged ARM64 fixture on the disposable native launch endpoint."""
import argparse
import base64
from concurrent.futures import ThreadPoolExecutor
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


def launch_request(boot_id, scenario, network, sequence):
    return {
        'boot_id': boot_id, 'sequence': sequence, 'budget_ms': 3_000,
        'spec': {'image_digest': scenario['manifest_digest'], 'argv': scenario['command'],
                 'env': [], 'cwd': '/work', 'uid': 65532, 'gid': 65532, 'network': network,
                 'limits': scenario['container_limits']},
    }


def state_sample(channel, boot_id, scenario, network, sequence):
    started = time.monotonic_ns()
    accepted_kind, accepted = call(channel, 8, launch_request(boot_id, scenario, network, sequence))
    accepted_ns = time.monotonic_ns() - started
    if accepted_kind != 13 or accepted['handle']['boot_id'] != boot_id:
        raise RuntimeError(f'native launch admission failed: {accepted}')
    kind, removed = call(channel, 10, {'handle': accepted['handle'], 'after_revision': 2**64 - 1,
                                        'budget_ms': 3000})
    if kind != 13 or removed['handle'] != accepted['handle']:
        raise RuntimeError(f'native launch wait failed: {removed}')
    return removed, accepted_ns


def wait_state(channel, state, predicate, budget_ms=3000):
    deadline = time.monotonic() + budget_ms / 1000
    while not predicate(state):
        remaining = int((deadline - time.monotonic()) * 1000)
        if remaining < 1 or state['cleanup'] in ('complete', 'failed'):
            raise RuntimeError(f'unexpected terminal or timed-out prepared state: {state}')
        kind, state = call(channel, 10, {'handle': state['handle'], 'after_revision': state['revision'],
                                         'budget_ms': remaining})
        if kind != 13:
            raise RuntimeError(f'prepared wait failed: {state}')
    return state


def prepare(channel, boot_id, scenario, sequence):
    request = launch_request(boot_id, scenario, 'none', sequence)
    started = time.monotonic_ns()
    kind, admitted = call(channel, 17, request)
    if kind != 13:
        raise RuntimeError(f'prepare admission failed: {admitted}')
    state = wait_state(channel, admitted, lambda value: value['phase'] == 'prepared_ready')
    if state['exec'] != 'pending' or state['prepared_claimed']:
        raise RuntimeError(f'workload ran before claim: {state}')
    return request, state, time.monotonic_ns() - started


def prepared_samples(channel, boot_id, args, scenario, report, connect_peer):
    report['prepared'] = {'checks': [], 'warmups': [], 'samples': []}
    data = report['prepared']
    canary = {**scenario, 'manifest_digest': report['fixture_digest'],
              'command': ['/bin/probe', '--verify-workload-fixture']}
    request, state, _ = prepare(channel, boot_id, canary, 1)
    operation = {'handle': state['handle'], 'spec': request['spec'], 'budget_ms': 3000}
    kind, retry = call(channel, 17, request)
    if kind != 13 or retry['handle'] != state['handle']:
        raise RuntimeError('prepare replay changed its handle')
    changed = {**operation, 'spec': {**request['spec'], 'argv': ['/bin/changed']}}
    stale = {**operation, 'handle': {**state['handle'], 'boot_id': '00' * 16}}
    full = {**request, 'sequence': 2}
    large = {**full, 'spec': {**request['spec'], 'limits': {**request['spec']['limits'],
                                                         'memory_bytes': 64 * 1024 * 1024}}}
    for opcode, payload, expected in [(18, changed, 'spec_mismatch'), (18, stale, 'stale_generation'),
                                      (17, large, 'unsupported_option'), (17, full, 'busy'),
                                      (8, request, 'id_conflict')]:
        kind, error = call(channel, opcode, payload)
        if kind != 15 or error['code'] != expected:
            raise RuntimeError(f'expected {expected}, observed {error}')
        data['checks'].append(expected)
    with connect_peer() as peer, ThreadPoolExecutor(max_workers=2) as clients:
        claims = [clients.submit(call, stream, 18, operation) for stream in (channel, peer)]
        outcomes = [claim.result() for claim in claims]
    if sorted(kind for kind, _ in outcomes) != [13, 15] or not any(
            kind == 15 and reply['code'] == 'slot_unavailable' for kind, reply in outcomes):
        raise RuntimeError(f'expected exactly one successful claim: {outcomes}')
    winner = next(reply for kind, reply in outcomes if kind == 13)
    completed = wait_state(channel, winner, lambda value: value['cleanup'] == 'complete')
    if completed['exit'] != {'code': 0} or completed['exec'] != 'confirmed':
        raise RuntimeError(f'claimed workload did not execute: {completed}')
    kind, output = call(channel, 12, {'handle': completed['handle'], 'budget_ms': 3000,
                                      'stream': 'stdout', 'offset': 0, 'max_bytes': 4096})
    if kind != 14 or b'verified private root, credentials, and seccomp' not in base64.b64decode(output['data']):
        raise RuntimeError('prepared sandbox canary failed')
    data['checks'].append('private root, credentials, and seccomp canary')
    data['checks'].append('exactly one concurrent claim')
    for sequence, cancel in [(2, True), (3, False)]:
        request, state, _ = prepare(channel, boot_id, scenario, sequence)
        if state['handle'] == completed['handle']:
            raise RuntimeError('refill reused a consumed slot identity')
        operation = {'handle': state['handle'], 'budget_ms': 3000}
        if cancel:
            kind, state = call(channel, 11, operation)
            if kind != 13:
                raise RuntimeError(f'prepared cancellation failed: {state}')
        state = wait_state(channel, state, lambda value: value['cleanup'] == 'complete', budget_ms=7500)
        if state['exec'] == 'confirmed' or state['prepared_claimed'] or state['prepared_expired'] == cancel:
            raise RuntimeError(f'unclaimed slot survived or executed: {state}')
        started = time.monotonic_ns()
        kind, error = call(channel, 18, {**operation, 'spec': request['spec']})
        if kind != 15 or error['code'] != 'slot_unavailable':
            raise RuntimeError(f'discarded slot accepted claim: {error}')
        data['checks'].append({'cause': 'cancel' if cancel else 'expiry',
                               'miss_ns': time.monotonic_ns() - started, 'terminal': state})
    state, _ = state_sample(channel, boot_id, scenario, 'none', 4)
    if state['exec'] != 'confirmed' or state['exit'] != {'code': 0} or state['cleanup'] != 'complete':
        raise RuntimeError(f'explicit fresh fallback failed: {state}')
    data['checks'].append('explicit fresh fallback after confirmed no execution')
    for index in range(args.samples + 10):
        row = {}
        data['warmups' if index < 10 else 'samples'].append(row)
        try:
            request, state, row['prepare_ns'] = prepare(channel, boot_id, scenario, index + 5)
            started = time.monotonic_ns()
            kind, claimed = call(channel, 18, {'handle': state['handle'], 'spec': request['spec'],
                                               'budget_ms': 3000})
            if kind != 13 or not claimed['prepared_claimed']:
                raise RuntimeError(f'claim failed: {claimed}')
            row['claim_ack_ns'] = time.monotonic_ns() - started
            state = wait_state(channel, claimed, lambda value: value['exec'] == 'confirmed')
            row['exec_observed_ns'] = time.monotonic_ns() - started
            state = wait_state(channel, state, lambda value: value['cleanup'] == 'complete')
            row['cleanup_observed_ns'] = time.monotonic_ns() - started
            row['state'] = state
            if state['exit'] != {'code': 0} or state['helper_failed']:
                raise RuntimeError(f'prepared workload failed: {state}')
        except Exception as error:
            row['error'] = str(error)
            raise
    print(f'Completed prepared no-network API: {args.samples} samples', flush=True)


def memory_pressure_check(channel, boot_id, scenario, report, footprint, connect_peer):
    rows = report['memory_pressure'] = {}

    def memory(label, **command):
        kind, snapshot = call(channel, 19, {'boot_id': boot_id, 'budget_ms': 1000, **command})
        if kind != 19:
            raise RuntimeError(f'memory operation failed: {snapshot}')
        rows[label] = snapshot
        return snapshot

    def empty(label):
        snapshot = memory(label)
        if snapshot['prepared'] is not None or snapshot['active'] is not None:
            raise RuntimeError(f'resources remain after verified cleanup: {snapshot}')

    empty('empty_initial')
    kind, stale = call(channel, 19, {'boot_id': '00' * 16, 'budget_ms': 1000, 'pressure': True})
    if kind != 15 or stale['code'] != 'stale_generation':
        raise RuntimeError(f'memory control accepted a stale generation: {stale}')
    rows['idle_footprint'] = footprint('empty')
    request, ready, rows['first_prepare_ns'] = prepare(channel, boot_id, scenario, 1)
    snapshot = memory('ready')
    reserve = snapshot['prepared']
    if (snapshot['active'] is not None or not reserve['sample_valid']
            or not reserve['populated'] or reserve['scope'] != 'prepared'
            or reserve['limit_bytes'] != request['spec']['limits']['memory_bytes']):
        raise RuntimeError(f'prepared memory was not accounted for: {snapshot}')
    rows['ready_footprint'] = footprint('ready')
    started = time.monotonic_ns()
    snapshot = memory('evict_requested', pressure=True)
    if snapshot['pressure_evictions'] != 1:
        raise RuntimeError(f'unused prepared slot was not selected for eviction: {snapshot}')
    state = wait_state(channel, ready, lambda value: value['cleanup'] == 'complete')
    rows['eviction_cleanup_ns'] = time.monotonic_ns() - started
    if state['exec'] == 'confirmed' or state['prepared_claimed']:
        raise RuntimeError(f'evicted reserve executed: {state}')
    empty('empty_after_eviction')
    blocked = launch_request(boot_id, scenario, 'none', 2)
    kind, error = call(channel, 17, blocked)
    if kind != 15 or error['code'] != 'memory_pressure':
        raise RuntimeError(f'prepared admission was not paused: {error}')
    rows['paused_admission'] = error
    state, rows['fresh_after_eviction_admission_ns'] = state_sample(channel, boot_id, scenario, 'none', 2)
    if state['exec'] != 'confirmed' or state['exit'] != {'code': 0} or state['cleanup'] != 'complete':
        raise RuntimeError(f'fresh work under pressure failed: {state}')
    memory('cleared', pressure=False)

    canary = {**scenario, 'manifest_digest': report['fixture_digest'],
              'command': ['/bin/probe', '--verify-workload-fixture', '--memory-canary'],
              'container_limits': {**scenario['container_limits'], 'memory_bytes': 32 * 1024 * 1024}}
    request, state, _ = prepare(channel, boot_id, canary, 3)
    kind, claimed = call(channel, 18, {'handle': state['handle'], 'spec': request['spec'], 'budget_ms': 3000})
    if kind != 13 or not claimed['prepared_claimed']:
        raise RuntimeError(f'live memory canary claim failed: {claimed}')
    deadline = time.monotonic() + 1
    rows['active_observations'] = []
    while time.monotonic() < deadline:
        active = memory('claimed_active')['active']
        rows['active_observations'].append(active)
        if active and active['sample_valid'] and active['populated'] and active['current_bytes'] >= 4 * 1024 * 1024:
            break
        if not active:
            break
        time.sleep(0.01)
    else:
        active = None
    if not active:
        _, rows['canary_status'] = call(channel, 9, {'handle': claimed['handle'], 'budget_ms': 1000})
        for stream in ('stdout', 'stderr'):
            _, result = call(channel, 12, {'handle': claimed['handle'], 'budget_ms': 1000,
                                           'stream': stream, 'offset': 0, 'max_bytes': 4096})
            rows[f'canary_{stream}'] = base64.b64decode(result['data']).decode(errors='replace')
        raise RuntimeError('claimed reserve never reported its live allocation')
    snapshot = memory('pressure_during_active', pressure=True)
    if snapshot['active'] is None or snapshot['prepared'] is not None or snapshot['pressure_evictions'] != 1:
        raise RuntimeError(f'pressure disturbed active workload ownership: {snapshot}')
    completed = wait_state(channel, claimed, lambda value: value['cleanup'] == 'complete')
    kind, output = call(channel, 12, {'handle': completed['handle'], 'budget_ms': 3000,
                                      'stream': 'stdout', 'offset': 0, 'max_bytes': 4096})
    if (completed['exit'] != {'code': 0} or kind != 14
            or b'verified live memory canary' not in base64.b64decode(output['data'])):
        raise RuntimeError(f'live workload did not preserve its data: {completed}')
    rows['live_canary_cleanup'] = completed
    empty('empty_after_active')
    memory('refill_allowed', pressure=False)
    request, ready, rows['refill_ns'] = prepare(channel, boot_id, scenario, 4)
    kind, claimed = call(channel, 18, {'handle': ready['handle'], 'spec': request['spec'], 'budget_ms': 3000})
    if kind != 13:
        raise RuntimeError(f'refilled slot claim failed: {claimed}')
    completed = wait_state(channel, claimed, lambda value: value['cleanup'] == 'complete')
    if completed['exec'] != 'confirmed' or completed['exit'] != {'code': 0}:
        raise RuntimeError(f'refilled slot did not complete: {completed}')
    empty('empty_final')
    request, ready, _ = prepare(channel, boot_id, scenario, 5)
    claim_body = {'handle': ready['handle'], 'spec': request['spec'], 'budget_ms': 3000}
    with connect_peer() as peer, ThreadPoolExecutor(max_workers=2) as clients:
        admission = clients.submit(call, channel, 18, claim_body)
        pressure = clients.submit(
            call, peer, 19, {'boot_id': boot_id, 'budget_ms': 1000, 'pressure': True},
        )
        kind, result = admission.result()
        pressure_kind, snapshot = pressure.result()
    rows['racing_pressure'] = snapshot
    if pressure_kind != 19 or kind not in (13, 15) or (kind == 15 and result['code'] != 'memory_pressure'):
        raise RuntimeError(f'inconsistent pressure and claim race: {result} {snapshot}')
    completed = wait_state(channel, result if kind == 13 else ready,
                           lambda value: value['cleanup'] == 'complete')
    rows['pressure_claim_race_terminal'] = completed
    if (kind == 13) != (completed['exec'] == 'confirmed' and completed['exit'] == {'code': 0}):
        raise RuntimeError(f'pressure changed the winning operation: {completed}')
    empty('empty_after_race')
    print('Verified prepared eviction, active allocation canary and refill', flush=True)


def balloon_pressure_check(channel, boot_id, scenario, report):
    rows = report['balloon_pressure'] = []
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        kind, snapshot = call(channel, 19, {'boot_id': boot_id, 'budget_ms': 1000})
        if kind != 19:
            raise RuntimeError(f'guest pressure snapshot failed: {snapshot}')
        rows.append(snapshot)
        if (snapshot['pressure'] and not snapshot['requested_pressure']
                and snapshot['available_bytes'] is not None
                and snapshot['available_bytes'] < snapshot['prepared_floor_bytes']):
            break
        time.sleep(0.10)
    else:
        raise RuntimeError(f'balloon did not reach the preparation floor: {rows[-1:]}')
    kind, error = call(channel, 17, launch_request(boot_id, scenario, 'none', 1))
    if kind != 15 or error['code'] != 'memory_pressure':
        raise RuntimeError(f'low guest memory admitted a reservation: {error}')
    state, _ = state_sample(channel, boot_id, scenario, 'none', 1)
    if state['exec'] != 'confirmed' or state['exit'] != {'code': 0} or state['cleanup'] != 'complete':
        raise RuntimeError(f'fresh work under the guest balloon target failed: {state}')
    report['balloon_fresh_cleanup'] = state
    print(f'Guest memory floor paused preparation at {snapshot["available_bytes"]} available bytes', flush=True)


def run_samples(channel, boot_id, args, scenario, endpoint, key_file, peer, report):
    sequence = 0
    for network in scenario['networks']:
        for lane in scenario['lanes']:
            group = {'network': network, 'lane': lane, 'warmups': [], 'samples': []}
            report['groups'].append(group)
            measured_start = None
            for index in range(args.samples + scenario['warmups_per_lane']):
                if index == scenario['warmups_per_lane']:
                    measured_start = time.monotonic_ns()
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
            group['measured_wall_ns'] = time.monotonic_ns() - measured_start
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
    memory_mib = 512 if args.balloon_pressure else 2048
    report = {'engine': 'native', 'scenario': scenario, 'groups': [], 'passed': False,
              'revision': adapter['run'](['/usr/bin/git', '-C', REPO, 'rev-parse', 'HEAD']),
              'scenario_sha256': adapter['file_hash'](scenario_path), 'production_before': before,
              'hashes': {str(path): adapter['file_hash'](path)
                         for path in (args.kernel, args.init, args.cli, args.vmm, args.client, args.network_helper)},
              'vcpus': 2, 'memory_mib': memory_mib, 'host_tick_ms': 25,
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
        command = [args.vmm, 'boot', '--manifest', manifest_path, '--memory-mib', str(memory_mib), '--cpus', '2',
                   '--max-exits', str(2**64 - 1), '--max-runtime-ms', str(args.runtime_ms),
                   '--host-tick-ms', '25', '--early-console-only', '--enable-native-launch', '--json']
        if args.balloon_pressure:
            command += ['--balloon-target-mib', '72']
        report['command'] = list(map(str, command))
        try:
            subprocess.run([args.cli, 'vm', 'build-initramfs', '--init', args.init,
                            '--output', initrd, '--json'], env=env, check=True, timeout=15)
            descriptor = {'architecture': 'arm64', 'os': 'linux',
                          'executable_sha256': adapter['file_hash'](args.init)}
            fixture_descriptor = json.dumps(descriptor).encode()
            report['fixture_digest'] = 'sha256:' + hashlib.sha256(fixture_descriptor).hexdigest()
            assets = {
                'etc/conjet/launch.key': key, 'etc/conjet/fresh-fixture-image.json': fixture_descriptor,
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
                            report['host_before'] = process_observation(
                                vm.pid, args.network_helper, args.output / 'footprint-before.json', adapter['run'],
                            )
                            def connect_peer():
                                peer, _ = open_native(endpoint, key, vm, args.vmm, adapter['current_executable'])
                                return peer
                            if args.memory_pressure:
                                def footprint(label):
                                    return process_observation(
                                        vm.pid, args.network_helper,
                                        args.output / f'footprint-{label}.json', adapter['run'],
                                    )
                                memory_pressure_check(channel, boot_id, scenario, report, footprint, connect_peer)
                            elif args.balloon_pressure:
                                balloon_pressure_check(channel, boot_id, scenario, report)
                            elif args.prepared:
                                channel.settimeout(9)
                                prepared_samples(channel, boot_id, args, scenario, report, connect_peer)
                            else:
                                run_samples(channel, boot_id, args, scenario, endpoint, key_file, vm.pid, report)
                            report['host_after'] = process_observation(
                                vm.pid, args.network_helper, args.output / 'footprint-after.json', adapter['run'],
                            )
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


def process_observation(pid, network_helper, footprint, run):
    roles = {pid: 'vmm'}
    for row in run(['/bin/ps', '-axo', 'pid=,ppid=,comm=']).splitlines():
        process, parent, executable = row.strip().split(maxsplit=2)
        if int(parent) == pid and Path(executable) == network_helper:
            roles[int(process)] = 'network_helper'
    ids = ','.join(map(str, roles))
    observation = {'load_average': os.getloadavg(), 'process_roles': roles,
                   'cpu_time_and_rss': run(['/bin/ps', '-p', ids, '-o', 'pid=,time=,rss='])}
    try:
        flags = [argument for process in roles for argument in ('--pid', str(process))]
        run(['/usr/bin/footprint', '--noCategories', '--format', 'bytes', '--json',
             footprint, *flags], timeout=10)
        observation['footprint_json'] = footprint.name
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        observation['footprint_error'] = str(error)
    return observation


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
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument('--prepared', action='store_true', help='measure the one-slot no-network experiment')
    modes.add_argument('--memory-pressure', action='store_true', help='verify the authenticated pressure fixture')
    modes.add_argument('--balloon-pressure', action='store_true', help='verify admission under a real Linux balloon target')
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
