"""Run serial native Docker and official Kiri lifecycle comparison sessions."""

import argparse
import fcntl
import http.client
import json
import os
from pathlib import Path
import runpy
import signal
import subprocess
import sys
import time
from types import SimpleNamespace
from urllib.parse import quote
import uuid

HERE = Path(__file__).resolve().parent
TOOLS = runpy.run_path(str(HERE / 'fresh-lifecycle.py'))
MANIFEST = json.loads((HERE / 'scenarios/docker-comparison-v1.json').read_text())
IMAGE = MANIFEST['images']['alpine']
DOCKER = Path('/opt/homebrew/bin/docker')
USER = '65532:65532'
HOST_CONFIG = {'NetworkMode': 'none', 'Memory': 16777216, 'PidsLimit': 4, 'NanoCpus': 500000000,
               'CapDrop': ['ALL'], 'SecurityOpt': ['no-new-privileges']}
FLAGS = ['--rm', '--pull', 'never', '--platform', 'linux/arm64', '--network', 'none', '--user', USER,
         '--memory', '16m', '--pids-limit', '4', '--cpus', '0.5', '--cap-drop', 'ALL',
         '--security-opt', 'no-new-privileges']
PREFIX = '/v1.44'


def invoke(docker, env, args, *, code=0, stdout=b'', stderr=b''):
    result = subprocess.run([*docker, *args], env=env, capture_output=True, timeout=30)
    if (result.returncode, result.stdout, result.stderr) != (code, stdout, stderr):
        raise RuntimeError(f'Docker CLI failed the canary: exit={result.returncode}, '
                           f'stdout={result.stdout[:300]!r}, stderr={result.stderr[:300]!r}')


def lifecycle(connection, name, stages, *, argv=('/bin/true',), code=0):
    def call(label, method, path, expected, body=None):
        start = time.monotonic_ns()
        try:
            return TOOLS['api'](connection, method, PREFIX + path, expected, body)
        finally:
            stages[label] = time.monotonic_ns() - start

    path = '/containers/' + name
    call('create', 'POST', '/containers/create?name=' + name, (201,), {
        'Image': IMAGE['ref'], 'User': USER, 'Cmd': list(argv), 'HostConfig': HOST_CONFIG})
    call('start', 'POST', path + '/start', (204,))
    result = call('wait', 'POST', path + '/wait?condition=not-running', (200,))
    if result['StatusCode'] != code or result.get('Error'):
        raise RuntimeError(f'API workload did not exit {code}: {result}')
    call('remove', 'DELETE', path, (204,))


def native_terminal(connection, name, handles, code=0):
    connection.request('GET', PREFIX + '/events')
    response = connection.getresponse()
    raw = response.read(65537)
    if response.status != 200 or len(raw) > 65536:
        raise RuntimeError('native adapter event snapshot is unavailable')
    events = [json.loads(line) for line in raw.splitlines()]
    owned = [event for event in events if event['Actor']['Attributes']['name'] == name]
    if [event['Action'] for event in owned] != ['create', 'start', 'die', 'destroy']:
        raise RuntimeError('native Docker operation lacks its exact lifecycle event sequence')
    attributes = owned[2]['Actor']['Attributes']
    handle = attributes['conjet.native_handle']
    if (attributes['conjet.backend'] != 'jetstream-native-oci' or attributes['conjet.guest_cleanup'] != 'complete'
            or attributes['exitCode'] != str(code) or not handle or handle in handles):
        raise RuntimeError('native execution or cleanup lacks a unique guest witness')
    handles.add(handle)
    return attributes


def host_observation(engine, config, peer, vm_pid, output):
    if engine == 'kiri':
        args = SimpleNamespace(engine=engine, config=config, peer_pid=peer)
        return TOOLS['sample_host'](args, output)
    pids = f'{peer},{vm_pid}'
    return {'process_roles': {peer: 'docker_adapter', vm_pid: 'jetstream_vmm'},
            'process_cpu_time_and_rss': TOOLS['run'](['/bin/ps', '-p', pids, '-o', 'pid=,time=,rss='])}


def measure(engine, endpoint, peer, docker, env, output, samples, vm_pid=None):
    output = output.parent.resolve(strict=True) / output.name
    if not output.is_relative_to(TOOLS['SCRATCH']):
        raise ValueError('benchmark output must reside on ExternalSSD')
    output.mkdir(mode=0o700)
    env = dict(env, DOCKER_API_VERSION='1.44')
    config = Path(env['DOCKER_CONFIG'])
    identity = {'native': 'Conjet Native OCI', 'kiri': 'Kiri'}[engine]
    if TOOLS['file_hash'](Path(docker[0])) != MANIFEST['clients']['docker']['sha256']:
        raise RuntimeError('Docker client differs from the frozen version')
    report = {'engine': engine, 'backend': identity, 'scope': 'full-budget' if samples == 2000 else 'pilot',
              'samples_per_lane': samples, 'image': IMAGE, 'user': USER, 'host_config': HOST_CONFIG,
              'docker_command_prefix': list(map(str, docker)), 'endpoint': str(endpoint), 'peer': peer,
              'harness_revision': TOOLS['run'](['/usr/bin/git', '-C', HERE.parent, 'rev-parse', 'HEAD']),
              'harness_sha256': TOOLS['file_hash'](Path(__file__)),
              'docker_sha256': TOOLS['file_hash'](Path(docker[0])),
              'host_load_before': os.getloadavg(), 'lanes': {}, 'passed': False}
    connection = TOOLS['UnixHTTP'](endpoint, peer)
    handles = set()
    token = uuid.uuid4().hex[:12]
    try:
        version = TOOLS['api'](connection, 'GET', '/version', (200,))
        if version['Platform']['Name'] != identity:
            raise RuntimeError('wrong engine for the matched comparison')
        report['version'] = version
        loaded = TOOLS['api'](connection, 'GET', PREFIX + '/images/' + quote(IMAGE['ref'], safe='') + '/json', (200,))
        if loaded.get('Id') != IMAGE['config_digest'] or loaded.get('Architecture') != 'arm64':
            raise RuntimeError('measured image differs from the pinned ARM64 config')
        for identity_flag in ('-u', '-g'):
            invoke(docker, env, ['run', *FLAGS, IMAGE['ref'], '/bin/busybox', 'id', identity_flag],
                   stdout=b'65532\n')
        invoke(docker, env, ['run', *FLAGS, IMAGE['ref'], '/bin/sh', '-c',
                             'printf matched-out; printf matched-err >&2; exit 23'],
               code=23, stdout=b'matched-out', stderr=b'matched-err')
        report['user_and_stream_canary'] = True
        if engine == 'kiri':
            info = TOOLS['api'](connection, 'GET', PREFIX + '/info', (200,))
            report['guest'] = {key: info[key] for key in ('KernelVersion', 'NCPU', 'MemTotal', 'Architecture')}
            if info['NCPU'] != 2 or not 1800 * 1024**2 <= info['MemTotal'] <= 2048 * 1024**2:
                raise RuntimeError('Kiri VM differs from the declared two-vCPU, 2 GiB envelope')
            participants = runpy.run_path(str(HERE / 'docker-comparison.py'))
            disks = participants['vm_disks'](engine, config, None)
            report['vm_backing'] = participants['observed_disks'](engine, peer, disks)
            invoke(docker, env, ['run', *FLAGS, IMAGE['ref'], '/bin/sh', '-c',
                                 'read m </sys/fs/cgroup/memory.max; read p </sys/fs/cgroup/pids.max; '
                                 'read q period </sys/fs/cgroup/cpu.max; '
                                 'test "$m" = 16777216 && test "$p" = 4 && test "$((q*2))" = "$period"'])
            report['limit_witness'] = 'read effective memory.max, pids.max and cpu.max in the guest'
        else:
            report['limit_witness'] = 'authenticated guest admission and checked cgroup setup'
        report['host_before'] = host_observation(engine, config, peer, vm_pid, output / 'footprint-before.json')
        for lane in ('api', 'cli'):
            data = {'samples': [], 'warmups': []}
            report['lanes'][lane] = data
            for phase, count in [('warmups', 10), ('samples', samples)]:
                window = time.monotonic_ns()
                for index in range(count):
                    name = f'cjmatch-{token}-{lane}-{phase}-{index}'
                    row = {'name': name, 'elapsed_ns': None, 'error': None, 'stages_ns': {},
                           'verified_guest_cleanup': None}
                    data[phase].append(row)
                    start = time.monotonic_ns()
                    try:
                        if lane == 'api':
                            lifecycle(connection, name, row['stages_ns'])
                        else:
                            invoke(docker, env, ['run', *FLAGS, '--name', name, IMAGE['ref'], '/bin/true'])
                        row['elapsed_ns'] = time.monotonic_ns() - start
                        if engine == 'native':
                            row['guest_witness'] = native_terminal(connection, name, handles)
                            row['verified_guest_cleanup'] = True
                    except (OSError, RuntimeError, ValueError, KeyError, http.client.HTTPException,
                            subprocess.SubprocessError) as error:
                        row['error'] = str(error)
                        connection.close()
                        TOOLS['api'](connection, 'DELETE', PREFIX + '/containers/' + name + '?force=true', (204, 404))
                    finally:
                        if row['elapsed_ns'] is None:
                            row['elapsed_ns'] = time.monotonic_ns() - start
                        data[phase + '_wall_ns'] = time.monotonic_ns() - window
        report['host_after'] = host_observation(engine, config, peer, vm_pid, output / 'footprint-after.json')
        for data in report['lanes'].values():
            data['summary'] = TOOLS['summarize'](data['samples'])
            successes = data['summary']['operations'] - data['summary']['failures']
            data['summary']['verified_operations_per_second'] = successes * 1_000_000_000 / data['samples_wall_ns']
        report['passed'] = all(row['error'] is None for lane in report['lanes'].values()
                               for phase in ('samples', 'warmups') for row in lane[phase])
    except BaseException as error:
        report['error'] = str(error) or type(error).__name__
        raise
    finally:
        connection.close()
        report['host_load_after'] = os.getloadavg()
        (output / 'session.json').write_text(json.dumps(report, indent=2) + '\n')
    if not report['passed']:
        raise RuntimeError(f'matched comparison has failed rows: {output}')


def measure_kiri(endpoint, peer, config, output, samples):
    args = SimpleNamespace(engine='kiri', socket=endpoint, config=config, peer_pid=peer, docker=DOCKER)
    docker, env, executable = TOOLS['verify_endpoint'](args)
    if TOOLS['file_hash'](executable) != MANIFEST['participants']['kiri']['executable_sha256']:
        raise RuntimeError('Kiri executable differs from the frozen official version')
    env['TMPDIR'] = str(config.parent / 'tmp')
    TOOLS['run'](docker + ['pull', '--platform', 'linux/arm64', IMAGE['ref']], env, timeout=180)
    measure('kiri', endpoint, peer, docker, env, output, samples)


def run_pair(args, root, pair, participants):
    order = ['native', 'kiri'] if pair % 2 else ['kiri', 'native']
    root.mkdir(mode=0o700)
    participants['save'](root / 'pair.json', {'pair': pair, 'order': order, 'samples': args.samples})
    for engine in order:
        name = 'conjet' if engine == 'native' else engine
        launcher = HERE.parent / f'build-support/run-{name}-speedup.py'
        command = [sys.executable, launcher, '--matched-output', root / engine,
                   '--matched-samples', str(args.samples)]
        evidence = root / 'native-launcher' / 'launcher.json'
        if engine == 'native':
            command += ['--image', IMAGE['ref'], '--native-evidence', evidence.parent]
            for key in ('swift_bin', 'core', 'native_kernel', 'native_guest', 'native_package', 'native_receipt',
                        'native_memd', 'native_reclaimd'):
                command += ['--' + key.replace('_', '-'), getattr(args, key)]
        else:
            evidence = participants['KIRI_ROOT'] / 'last-session.json'
        started = time.time()
        record = {'command': list(map(str, command))}
        with (root / f'{engine}.log').open('w') as log:
            with subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT,
                                  start_new_session=True) as process:
                try:
                    record['exit_code'] = participants['wait_for_launcher'](process, args.timeout)
                finally:
                    try:
                        if evidence.is_file() and evidence.stat().st_mtime >= started:
                            metadata = json.loads(evidence.read_text())
                            record['launcher'] = metadata
                            if engine == 'kiri':
                                participants['validate_cleanup'](engine, metadata)
                            elif not (metadata['production_unchanged'] and metadata['native_session_removed']
                                      and metadata['adapter_socket_removed'] and not metadata['cleanup_errors']
                                      and metadata.get('shutdown', {}).get('guest_cleanup') == 'complete'):
                                raise RuntimeError('native launcher did not verify cleanup or production')
                    finally:
                        participants['save'](root / f'{engine}-launcher.json', record)
        if record.get('exit_code') != 0 or not record.get('launcher', {}).get('passed'):
            raise RuntimeError(f'{engine} failed capture or cleanup; see {root}')


def interrupt(_signum, _frame):
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    raise KeyboardInterrupt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for key in ('swift-bin', 'core', 'native-kernel', 'native-guest', 'native-package', 'native-receipt',
                'native-memd', 'native-reclaimd', 'output'):
        parser.add_argument('--' + key, type=Path, required=True)
    selection = parser.add_mutually_exclusive_group()
    selection.add_argument('--pair', type=int, choices=range(1, 6), default=1)
    selection.add_argument('--all-pairs', action='store_true')
    parser.add_argument('--samples', type=int, choices=range(1, 2001), metavar='1..2000', default=2000)
    parser.add_argument('--timeout', type=int, default=900)
    args = parser.parse_args()
    participants = runpy.run_path(str(HERE / 'docker-comparison.py'))
    output = participants['private_path'](args.output)
    if args.timeout <= 0 or not TOOLS['SCRATCH'].parents[1].is_mount():
        parser.error('require a positive timeout and mounted ExternalSSD')
    lock_path = TOOLS['SCRATCH'] / '.conjet-docker-comparison.lock'
    descriptor = os.open(lock_path, os.O_CREAT | os.O_NOFOLLOW | os.O_WRONLY, 0o600)
    with os.fdopen(descriptor, 'w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        signal.signal(signal.SIGTERM, interrupt)
        signal.signal(signal.SIGINT, interrupt)
        if args.all_pairs:
            output.mkdir(mode=0o700)
            for pair in range(1, 6):
                run_pair(args, output / f'pair-{pair}', pair, participants)
        else:
            run_pair(args, output, args.pair, participants)


if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
