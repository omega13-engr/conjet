#!/usr/bin/env python3
"""Measure equivalent fresh Docker work on a launcher-owned endpoint."""
import argparse
import hashlib
import http.client
import json
import math
import os
import platform
import socket
import subprocess
import time
import uuid
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
SCENARIO = REPO / 'benchmarks/scenarios/fresh-lifecycle-v1.json'
SCRATCH = Path('/Volumes/ExternalSSD/dev_workspace/tmp')
MAX_RESPONSE_BYTES = 1024 * 1024
SESSION_LABEL = 'dev.conjet.benchmark.session'


class UnixHTTP(http.client.HTTPConnection):
    def __init__(self, endpoint, pid):
        super().__init__('localhost', timeout=20)
        self.endpoint = endpoint
        self.pid = pid

    def connect(self):
        channel = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            channel.settimeout(self.timeout)
            channel.connect(str(self.endpoint))
            if channel.getsockopt(0, 2) != self.pid:  # Darwin LOCAL_PEERPID
                raise RuntimeError('Docker API peer changed')
        except BaseException:
            channel.close()
            raise
        self.sock = channel


def run(args, env=None, timeout=30):
    result = subprocess.run(args, check=False, env=env, capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError(f'{args[0]} exited {result.returncode}: {result.stderr.strip()}')
    return result.stdout.strip()


def current_executable(pid):
    return Path(run(['/bin/ps', '-p', str(pid), '-o', 'comm='])).resolve(strict=True)


def file_hash(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def verify_endpoint(args):
    endpoint = args.socket
    candidate_root = endpoint.parents[4] if len(endpoint.parents) >= 5 else None
    if args.engine == 'conjet':
        if (candidate_root is None or candidate_root.parent != SCRATCH
                or not candidate_root.name.startswith('cs-')
                or endpoint != candidate_root / 'h/profiles/speedup/run/docker.sock'
                or args.config != candidate_root / 'docker'):
            raise RuntimeError('candidate endpoint is outside the launcher session')
        executable = candidate_root / 'bin/Conjet Core'
        context = 'conjet-speedup'
    else:
        root = SCRATCH / 'conjet-speedup-kiri'
        if endpoint != root / 'docker.sock' or args.config != root / 'docker-config':
            raise RuntimeError('Kiri endpoint is outside its managed session')
        executable = REPO / '.speedup/tools/kiri-0.2.2/Kiri.app/Contents/MacOS/kiri'
        context = 'kiri-speedup'
    if current_executable(args.peer_pid) != executable.resolve(strict=True):
        raise RuntimeError('unexpected engine executable at the Docker peer PID')
    if endpoint.is_symlink() or args.config.is_symlink() or not endpoint.is_socket():
        raise RuntimeError('expected the launcher-owned socket and configuration directory')
    env = {'PATH': '/usr/bin:/bin', 'HOME': str(args.config.parent),
           'DOCKER_CONFIG': str(args.config)}
    prefix = [args.docker, '--config', args.config]
    actual = run(prefix + ['context', 'inspect', context,
                           '--format', '{{.Endpoints.docker.Host}}'], env)
    if actual != f'unix://{endpoint}':
        raise RuntimeError(f'context endpoint mismatch: {actual}')
    return prefix + ['--context', context], env, executable


def api(connection, method, path, acceptable, body=None):
    payload = json.dumps(body).encode() if body is not None else None
    headers = {'Content-Type': 'application/json'} if payload is not None else {}
    connection.request(method, path, body=payload, headers=headers)
    response = connection.getresponse()
    data = response.read(MAX_RESPONSE_BYTES + 1)
    if len(data) > MAX_RESPONSE_BYTES:
        connection.close()
        raise RuntimeError('Docker API response exceeded the measurement bound')
    if response.status not in acceptable:
        raise RuntimeError(f'{method} {path} returned {response.status}: {data[:400]!r}')
    return json.loads(data) if data else None


def api_sample(connection, scenario, network, name, token):
    prefix = '/v' + scenario['api_version']
    container = name
    started = time.monotonic_ns()
    stages = {}
    row = {'name': name, 'stages_ns': stages, 'api_removed_ns': None,
           'cleanup_complete_ns': None, 'error': None}

    def stage(label, method, path, acceptable, body=None):
        t0 = time.monotonic_ns()
        try:
            return api(connection, method, prefix + path, acceptable, body)
        finally:
            stages[label] = time.monotonic_ns() - t0

    try:
        host_config = {'NetworkMode': network}
        if 'container_limits' in scenario:
            limits = scenario['container_limits']
            host_config.update(Memory=limits['memory_bytes'], PidsLimit=limits['pids'],
                               NanoCpus=limits['cpu_millicores'] * 1_000_000,
                               CapDrop=['ALL'], SecurityOpt=['no-new-privileges'])
        result = stage('create', 'POST', '/containers/create?name=' + name, (201,), {
            'Image': scenario['image'], 'Cmd': scenario['command'],
            'Labels': {SESSION_LABEL: token}, 'HostConfig': host_config,
        })
        candidate_id = result['Id']
        if not candidate_id or not all(c in 'abcdef0123456789' for c in candidate_id):
            raise RuntimeError('Docker returned an invalid container ID')
        container = candidate_id
        stage('start', 'POST', f'/containers/{container}/start', (204,))
        result = stage('wait', 'POST', f'/containers/{container}/wait?condition=not-running', (200,))
        row['exit_code'] = result['StatusCode']
        if result['StatusCode'] != 0 or result.get('Error'):
            raise RuntimeError(f'workload returned {result}')
        stage('remove', 'DELETE', f'/containers/{container}', (204,))
        row['api_removed_ns'] = time.monotonic_ns() - started
    except (OSError, http.client.HTTPException, RuntimeError, ValueError, KeyError, TypeError) as error:
        row['error'] = str(error)
        connection.close()
        # Create might have succeeded even if its response was lost. Recover by
        # the unique session name without retrying the workload.
        try:
            stage('recovery_remove', 'DELETE', f'/containers/{container}?force=true', (204, 404))
        except (OSError, http.client.HTTPException, RuntimeError, ValueError) as cleanup_error:
            row['cleanup_error'] = str(cleanup_error)
            connection.close()
    row['elapsed_ns'] = time.monotonic_ns() - started
    return row


def cli_sample(connection, prefix, env, scenario, network, name, token):
    row = {'name': name, 'api_removed_ns': None, 'cleanup_complete_ns': None, 'error': None}
    started = time.monotonic_ns()
    try:
        runtime_args = []
        if 'container_limits' in scenario:
            limits = scenario['container_limits']
            runtime_args = ['--memory', str(limits['memory_bytes']), '--pids-limit', str(limits['pids']),
                            '--cpus', f"{limits['cpu_millicores'] / 1000:.3f}",
                            '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges']
        run(prefix + ['run', '--rm', '--name', name, '--label', f'{SESSION_LABEL}={token}',
                      '--platform', scenario['platform'], '--network', network, *runtime_args,
                      scenario['image'], *scenario['command']], env)
    except (OSError, subprocess.SubprocessError, RuntimeError) as error:
        row['error'] = str(error)
        try:
            api(connection, 'DELETE', f"/v{scenario['api_version']}/containers/{name}?force=true",
                (204, 404))
        except (OSError, http.client.HTTPException, RuntimeError, ValueError) as cleanup_error:
            row['cleanup_error'] = str(cleanup_error)
            connection.close()
    row['elapsed_ns'] = time.monotonic_ns() - started
    return row


def engine_processes(args):
    found = {args.peer_pid: 'docker_peer'}
    if args.engine == 'conjet':
        staged = args.config.parent / 'bin'
        for line in run(['/bin/ps', '-axo', 'pid=,comm=']).splitlines():
            text_pid, executable = line.strip().split(maxsplit=1)
            path = Path(executable)
            if path.parent == staged and path.name in ('conjetd', 'conjet-network'):
                found[int(text_pid)] = path.name
    else:
        data_disk = args.config.parent / 'data/vm/data.img'
        try:
            holders = run(['/usr/sbin/lsof', '-t', data_disk], timeout=10)
        except (RuntimeError, OSError, subprocess.SubprocessError):
            holders = ''
        for holder in holders.splitlines():
            pid = int(holder)
            try:
                if current_executable(pid).name == 'com.apple.Virtualization.VirtualMachine':
                    found[pid] = 'virtualization_vm'
            except (RuntimeError, OSError):
                continue
    return found


def sample_host(args, path):
    processes = engine_processes(args)
    pid_list = ','.join(map(str, processes))
    observation = {'load_average': os.getloadavg(), 'process_roles': processes,
                   'process_cpu_time_and_rss': run(
                       ['/bin/ps', '-p', pid_list, '-o', 'pid=,time=,rss='])}
    if args.engine == 'kiri' and 'virtualization_vm' not in processes.values():
        observation['missing_coverage'] = 'Virtualization VM could not be attributed to the private disk'
    try:
        flags = [argument for pid in processes for argument in ('--pid', str(pid))]
        run(['/usr/bin/footprint', '--noCategories', '--format', 'bytes', '--json',
             path, *flags], timeout=10)
        observation['footprint_json'] = path.name
    except (RuntimeError, OSError, subprocess.SubprocessError) as error:
        observation['footprint_error'] = str(error)
    return observation


def summarize(rows):
    success = sorted(row['elapsed_ns'] for row in rows if row['error'] is None)
    elapsed = sum(row['elapsed_ns'] for row in rows)
    return {
        'operations': len(rows),
        'failures': len(rows) - len(success),
        'successes_per_second': len(success) * 1_000_000_000 / elapsed if elapsed else None,
        **{f'p{int(p * 100)}_ns': success[math.ceil(p * len(success)) - 1] if success else None
           for p in (0.50, 0.95, 0.99)},
    }


def cleanup_fixtures(docker, env, token):
    query = docker + ['ps', '-aq', '--no-trunc', '--filter', f'label={SESSION_LABEL}={token}']
    owned = run(query, env).splitlines()
    if not owned:
        return []
    if len(owned) > 4 or any(len(identifier) != 64 for identifier in owned):
        raise RuntimeError('unexpected benchmark fixture list')
    if any(not all(char in '0123456789abcdef' for char in identifier) for identifier in owned):
        raise RuntimeError('invalid benchmark fixture identifier')
    run(docker + ['rm', '-f', *owned], env)
    if run(query, env):
        raise RuntimeError('session-owned fixture containers remain')
    return owned


def session(args):
    scenario_path = args.scenario or SCENARIO
    scenario = json.loads(scenario_path.read_text())
    docker, env, executable = verify_endpoint(args)
    args.output.mkdir(mode=0o700)
    token = uuid.uuid4().hex
    connection = UnixHTTP(args.socket, args.peer_pid)
    env['DOCKER_API_VERSION'] = scenario['api_version']
    report = {'session': token, 'engine': args.engine, 'socket': str(args.socket),
              'docker_config': str(args.config), 'docker_peer_pid': args.peer_pid,
              'revision': run(['/usr/bin/git', '-C', REPO, 'rev-parse', 'HEAD']),
              'engine_binary_sha256': file_hash(executable), 'docker_binary_sha256': file_hash(args.docker),
              'scenario': scenario, 'scenario_sha256': file_hash(scenario_path),
              'machine': {'machine': platform.machine(), 'release': platform.release(),
                          'hardware': run(['/usr/sbin/sysctl', '-n', 'hw.model']),
                          'cpu': run(['/usr/sbin/sysctl', '-n', 'machdep.cpu.brand_string']),
                          'memory_bytes': int(run(['/usr/sbin/sysctl', '-n', 'hw.memsize']))},
              'storage': 'ExternalSSD', 'samples_per_group': args.samples, 'groups': [],
              'cleanup_boundary': 'unobservable by this Docker API adapter', 'passed': False}
    try:
        report['server'] = api(connection, 'GET', '/version', (200,))
        if args.engine == 'kiri':
            components = {c['Name']: c['Version'] for c in report['server'].get('Components', [])}
            if report['server'].get('Platform', {}).get('Name') != 'Kiri' or components.get('Kiri') != '0.2.2':
                raise RuntimeError('unexpected Kiri server identity')
        api_version = tuple(int(part) for part in scenario['api_version'].split('.'))
        for key, valid in [('MinAPIVersion', lambda version: version <= api_version),
                           ('ApiVersion', lambda version: version >= api_version)]:
            value = report['server'].get(key)
            if value and not valid(tuple(int(part) for part in value.split('.'))):
                raise RuntimeError(f"server {key}={value} cannot use pinned API {scenario['api_version']}")
        info = api(connection, 'GET', '/info', (200,))
        report['guest'] = {key: info.get(key) for key in ('Architecture', 'NCPU', 'MemTotal', 'KernelVersion',
                                                         'Driver', 'OperatingSystem', 'CgroupVersion')}
        if args.archive:
            archive_hash = file_hash(args.archive)
            report['image_archive_sha256'] = archive_hash
            if archive_hash != scenario['archive_sha256']:
                raise RuntimeError('fixture archive digest mismatch')
            run(docker + ['load', '--input', args.archive], env, timeout=120)
        else:
            run(docker + ['pull', '--platform', scenario['platform'], scenario['image']], env, timeout=120)
        report['image'] = json.loads(run(docker + ['image', 'inspect', scenario['image'],
                                                  '--format', '{{json .}}'], env))
        if report['image'].get('Os') != 'linux' or report['image'].get('Architecture') != 'arm64':
            raise RuntimeError('unexpected fixture image architecture')
        if args.archive and report['image'].get('Id') != scenario['config_digest']:
            raise RuntimeError('loaded fixture image has unexpected config digest')
        report['host_before'] = sample_host(args, args.output / 'footprint-before.json')
        for network in scenario['networks']:
            for lane in scenario['lanes']:
                group = {'network': network, 'lane': lane, 'warmups': [], 'samples': []}
                report['groups'].append(group)
                count = args.samples + scenario['warmups_per_lane']
                measured_start = None
                for index in range(count):
                    if index == scenario['warmups_per_lane']:
                        measured_start = time.monotonic_ns()
                    name = f'speed-{token}-{network}-{lane}-{index}'
                    report['in_flight'] = {'name': name, 'network': network, 'lane': lane,
                                           'warmup': index < scenario['warmups_per_lane']}
                    if lane == 'api':
                        row = api_sample(connection, scenario, network, name, token)
                    else:
                        row = cli_sample(connection, docker, env, scenario, network, name, token)
                    warmup = index < scenario['warmups_per_lane']
                    group['warmups' if warmup else 'samples'].append(row)
                    del report['in_flight']
                    if row['error'] is not None:
                        group['summary'] = summarize(group['samples'])
                        raise RuntimeError(f"fixture failed in {network}/{lane}: {row['error']}")
                group['measured_wall_ns'] = time.monotonic_ns() - measured_start
                group['summary'] = summarize(group['samples'])
                print(f"Completed {args.engine} {network}/{lane}: {args.samples} samples", flush=True)
        remaining = run(docker + ['ps', '-aq', '--filter', f'label={SESSION_LABEL}={token}'], env)
        if remaining:
            raise RuntimeError('session-owned fixture containers remain')
        report['passed'] = all(row['error'] is None for group in report['groups']
                               for row in group['warmups'] + group['samples'])
    except (Exception, KeyboardInterrupt) as error:
        report['error'] = str(error) or type(error).__name__
        raise
    finally:
        connection.close()
        try:
            report['recovered_after_abort'] = cleanup_fixtures(docker, env, token)
        except (OSError, RuntimeError, subprocess.SubprocessError) as error:
            report['final_cleanup_error'] = str(error)
            report['passed'] = False
        try:
            report['host_after'] = sample_host(args, args.output / 'footprint-after.json')
        finally:
            (args.output / 'session.json').write_text(json.dumps(report, indent=2) + '\n')
    if not report['passed']:
        raise RuntimeError('fresh fixture had failed samples; see retained session.json')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--engine', choices=('conjet', 'kiri'), required=True)
    parser.add_argument('--socket', type=Path, required=True)
    parser.add_argument('--config', type=Path, required=True)
    parser.add_argument('--peer-pid', type=int, required=True)
    parser.add_argument('--docker', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--samples', type=int, default=100)
    parser.add_argument('--scenario', type=Path)
    parser.add_argument('--archive', type=Path)
    args = parser.parse_args(argv)
    if not 1 <= args.samples <= 10_000:
        parser.error('--samples must be between 1 and 10000')
    if not args.output.is_absolute() or not args.output.parent.resolve().is_relative_to(SCRATCH):
        parser.error('--output must be a new directory under the designated ExternalSSD root')
    if bool(args.scenario) != bool(args.archive):
        parser.error('--scenario and --archive must be supplied together')
    for path in (args.scenario, args.archive):
        if path is not None and (path.is_symlink() or not path.is_file()
                                 or not path.resolve().is_relative_to(SCRATCH)):
            parser.error('fixture inputs must be files under the designated ExternalSSD root')
    session(args)


if __name__ == '__main__':
    main()
