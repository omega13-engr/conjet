"""Docker comparison workloads running only in an already verified launcher."""

import http.client
import json
from pathlib import Path
import runpy
import struct
import subprocess
import time
import uuid

REPO = Path(__file__).resolve().parents[1]
TOOLS = runpy.run_path(str(REPO / 'benchmarks/fresh-lifecycle.py'))
COMMON = (TOOLS['SCRATCH'] / 'conjet-speedup-evidence/SPEED-008/common-image/image')
LABEL = TOOLS['SESSION_LABEL']


def cli(prefix, env, args, timeout=30):
    return subprocess.run([*prefix, *args], env=env, capture_output=True, timeout=timeout)


def require(result, code=0, stdout=None, stderr=None):
    if result.returncode != code or (stdout is not None and result.stdout != stdout) or (
            stderr is not None and result.stderr != stderr):
        raise RuntimeError(f'expected exit {code}, got {result.returncode}; '
                           f'stdout={result.stdout[:500]!r}, stderr={result.stderr[:500]!r}')
    return result.stdout


def logs(connection, path):
    connection.request('GET', path)
    response = connection.getresponse()
    data = response.read(64 * 1024 + 1)
    if response.status != 200 or len(data) > 64 * 1024:
        connection.close()
        raise RuntimeError(f'Docker logs returned {response.status} or exceeded the output limit')
    streams = [bytearray(), bytearray()]
    cursor = 0
    while cursor < len(data):
        if len(data) - cursor < 8:
            raise RuntimeError('truncated Docker stream header')
        stream, reserved, size = struct.unpack_from('>B3sI', data, cursor)
        cursor += 8
        if stream not in (1, 2) or reserved != b'\0\0\0' or len(data) - cursor < size:
            raise RuntimeError('invalid Docker multiplexed stream')
        streams[stream - 1].extend(data[cursor:cursor + size])
        cursor += size
    return tuple(map(bytes, streams))


def sample(connection, docker, env, spec, network, lane, token, index):
    name = f'cjcmp-{token}-{index}'
    row = {'elapsed_ns': None, 'stages_ns': {}, 'error': None, 'cleanup_complete_ns': None,
           'api_removed_ns': None, 'name': name}
    endpoint = '/v1.44'
    request = TOOLS['api']
    settings, image, command, code, stdout, stderr = spec
    began = time.monotonic_ns()
    resource = '/containers/' + name

    def stage(label, method, path, expected, body=None):
        start = time.monotonic_ns()
        try:
            return request(connection, method, endpoint + path, expected, body)
        finally:
            row['stages_ns'][label] = time.monotonic_ns() - start

    try:
        if lane == 'cli':
            result = cli(docker, env, [
                'run', '--rm', '--pull', 'never', '--platform', 'linux/arm64', '--name', name,
                '--label', f'{LABEL}={token}', '--network', network,
                '--memory', str(settings['memory_bytes']), '--pids-limit', str(settings['pids']),
                '--cpus', str(settings['cpu_millicores'] / 1000), '--cap-drop', 'ALL',
                '--security-opt', 'no-new-privileges', image, *command])
            row['exit_code'] = result.returncode
            require(result, code, stdout, stderr)
        else:
            created = stage('create', 'POST', '/containers/create?name=' + name, (201,), {
                'Image': image, 'Cmd': command, 'Labels': {LABEL: token}, 'HostConfig': {
                    'NetworkMode': network, 'Memory': settings['memory_bytes'], 'PidsLimit': settings['pids'],
                    'NanoCpus': settings['cpu_millicores'] * 1_000_000, 'CapDrop': ['ALL'],
                    'SecurityOpt': ['no-new-privileges']}})
            identifier = created['Id']
            if not identifier or not all(char in '0123456789abcdef' for char in identifier):
                raise RuntimeError('unexpected Docker ID')
            resource = '/containers/' + identifier
            stage('start', 'POST', resource + '/start', (204,))
            status = stage('wait', 'POST', resource + '/wait?condition=not-running', (200,))
            row['exit_code'] = status['StatusCode']
            if status.get('Error') or row['exit_code'] != code:
                raise RuntimeError(f'wrong workload exit: {status}')
            if stdout or stderr:
                start = time.monotonic_ns()
                actual = logs(connection, endpoint + resource + '/logs?stdout=1&stderr=1')
                row['stages_ns']['logs'] = time.monotonic_ns() - start
                if actual != (stdout, stderr):
                    raise RuntimeError(f'wrong Docker output streams: {actual!r}')
            stage('remove', 'DELETE', resource, (204,))
            row['api_removed_ns'] = time.monotonic_ns() - began
    except (RuntimeError, ValueError, KeyError, OSError, http.client.HTTPException,
            subprocess.SubprocessError) as error:
        row['error'] = str(error)
        connection.close()
        try:
            stage('recover', 'DELETE', resource + '?force=1', (204, 404))
        except (RuntimeError, OSError, http.client.HTTPException) as cleanup:
            row['cleanup_error'] = str(cleanup)
            connection.close()
    row['elapsed_ns'] = time.monotonic_ns() - began
    return row


def pilot_probes(manifest, report, output, docker, env, image, token):
    observations = report['capability_probes'] = {}

    def probe(name, args, timeout=30, stdout=None):
        start = time.monotonic_ns()
        try:
            result = cli(docker, env, args, timeout)
            observations[name] = {'exit': result.returncode, 'argv': args,
                                  'stdout': result.stdout[:7000].decode(errors='replace'),
                                  'stderr': result.stderr[:7000].decode(errors='replace'),
                                  'elapsed_ns': time.monotonic_ns() - start,
                                  'passed': result.returncode == 0 and (stdout is None or stdout == result.stdout)}
            return observations[name]['passed']
        except subprocess.TimeoutExpired:
            observations[name] = {'argv': args, 'passed': False, 'error': 'timeout'}
            return False

    probe('image-inspect', ['image', 'inspect', image])
    container, volume, network = [f'cjcmp-{token}-{kind}' for kind in ('control', 'volume', 'net')]
    label = f'{LABEL}={token}'
    if probe('network-create', ['network', 'create', '--label', label, network]):
        probe('network-remove', ['network', 'rm', network])
    if probe('volume-create', ['volume', 'create', '--label', label, volume]):
        try:
            probe('volume-write', ['run', '--rm', '--network', 'none', '-v', f'{volume}:/data',
                                   image, 'sh', '-c', 'printf volume-proof > /data/check'])
            probe('volume-read', ['run', '--rm', '--network', 'none', '-v', f'{volume}:/data',
                                  image, 'cat', '/data/check'], stdout=b'volume-proof')
        finally:
            probe('volume-remove', ['volume', 'rm', volume])
    if probe('control-create', ['create', '--name', container, '--label', label, '--network', 'none',
                               image, 'sleep', '120']):
        try:
            probe('image-rootfs-copy', ['cp', f'{container}:/bin/busybox', str(output / 'alpine-busybox')])
            if probe('precreated-start', ['start', container]):
                probe('exec', ['exec', container, '/bin/echo', 'exec-proof'], stdout=b'exec-proof\n')
                probe('inspect-effective-limits', ['inspect', container])
                probe('stop', ['stop', '--time', '1', container])
                if probe('restart', ['restart', '--time', '1', container]):
                    probe('kill', ['kill', container])
        finally:
            probe('remove', ['rm', '-f', container])

    limits = manifest['lifecycle_limits']
    probe('cgroup-limits', ['run', '--rm', '--network', 'none', '--memory', str(limits['memory_bytes']),
                           '--pids-limit', str(limits['pids']), '--cpus', '0.5', image, 'sh', '-c',
                           'cat /sys/fs/cgroup/memory.max /sys/fs/cgroup/pids.max /sys/fs/cgroup/cpu.max'])
    # Buildx inspect provides a human-readable descriptor. Require its
    # engine-backed driver and the verified context/endpoint before build.
    context = {'conjet': 'conjet-speedup', 'kiri': 'kiri-speedup'}[report['engine']]
    if probe('builder', ['buildx', 'inspect', context]):
        descriptor = observations['builder']['stdout']
        report['builder'] = descriptor
        fields = [line.strip().split(':', 1) for line in descriptor.splitlines() if ':' in line]
        drivers = [value.strip() for key, value in fields if key == 'Driver']
        endpoints = {value.strip() for key, value in fields if key == 'Endpoint'}
        if drivers == ['docker'] and endpoints and endpoints.issubset({context, 'unix://' + report['endpoint']}):
            directory = output / 'build-context'
            directory.mkdir()
            (directory / 'Dockerfile').write_text(
                f'FROM {image}\nRUN printf build-proof > /proof\nCMD ["cat", "/proof"]\n')
            tag = f'cjcmp-{token}:build'
            try:
                if probe('build', ['buildx', 'build', '--builder', context, '--network', 'none',
                                   '--pull=false', '--tag', tag, '--load', str(directory)], timeout=180):
                    probe('built-image', ['run', '--rm', '--pull', 'never', '--network', 'none', tag],
                          stdout=b'build-proof')
            finally:
                probe('built-image-remove', ['image', 'rm', tag])
        else:
            observations['build'] = {'passed': False, 'error': 'embedded builder or endpoint not verified'}

    if report['engine'] == 'kiri' and not observations.get('build', {}).get('passed'):
        builder = f'cjcmp-{token}'
        buildkit = manifest['images']['buildkit']['ref']
        created = probe('private-builder-create', ['buildx', 'create', '--name', builder,
                        '--driver', 'docker-container', '--driver-opt', f'image={buildkit}', context])
        if created:
            try:
                if probe('private-builder-start', ['buildx', 'inspect', '--bootstrap', builder], timeout=180):
                    descriptor = observations['private-builder-start']['stdout']
                    if f'Endpoint:         {context}' in descriptor or f'Endpoint: {context}' in descriptor:
                        probe('private-builder-backing', ['inspect', f'buildx_buildkit_{builder}0'])
                        directory = output / 'build-context'
                        directory.mkdir(exist_ok=True)
                        (directory / 'Dockerfile').write_text(
                            f'FROM {image}\nRUN printf build-proof > /proof\nCMD ["cat", "/proof"]\n')
                        tag = f'cjcmp-{token}:build'
                        try:
                            if probe('private-builder-build', ['buildx', 'build', '--builder', builder,
                                     '--network', 'none', '--tag', tag, '--load', str(directory)], timeout=180):
                                probe('private-built-image', ['run', '--rm', '--pull', 'never', '--network',
                                                              'none', tag], stdout=b'build-proof')
                        finally:
                            probe('private-built-image-remove', ['image', 'rm', tag])
            finally:
                probe('private-builder-remove', ['buildx', 'rm', builder])

    if not probe('image-save', ['image', 'save', '--output', str(output / 'alpine.tar'), image], timeout=60):
        observations['image-save']['receipt'] = 'unavailable'
    redis = manifest['images']['redis']['ref']
    if not probe('compose-pull', ['pull', '--platform', manifest['platform'], redis], timeout=150):
        return
    prefix = ['compose', '--project-name', f'cjcmp{token}', '--file', str(output / 'compose.json')]
    descriptor = {'services': {
        'redis': {'image': redis, 'healthcheck': {'test': ['CMD', 'redis-cli', 'ping'],
                                                 'interval': '1s', 'timeout': '1s', 'retries': 5}},
        'client': {'image': image, 'command': ['sleep', '120']}}}
    (output / 'compose.json').write_text(json.dumps(descriptor))
    try:
        if probe('compose-up', prefix + ['up', '--detach', '--wait', '--wait-timeout', '15',
                                         '--pull', 'never'], timeout=30):
            probe('compose-transaction', prefix + ['exec', '-T', 'client', 'sh', '-c',
                  "printf 'SET probe compose-proof\\r\\nGET probe\\r\\nQUIT\\r\\n' | nc -w 3 redis 6379"],
                  stdout=b'+OK\r\n$13\r\ncompose-proof\r\n+OK\r\n')
        else:
            probe('compose-failure-logs', prefix + ['logs', '--no-color'])
    finally:
        probe('compose-down', prefix + ['down', '--volumes'])


def run_workloads(mode, manifest, report, output, connection, docker, env):
    token = uuid.uuid4().hex[:10]
    image = manifest['images']['alpine']['ref']
    require(cli(docker, env, ['pull', '--platform', manifest['platform'], image], 180))
    identity = json.loads(require(cli(docker, env, ['image', 'inspect', image])))[0]
    if identity['Architecture'] != 'arm64' or identity['Os'] != 'linux':
        raise RuntimeError('wrong pinned Alpine image architecture')
    report['alpine'] = {key: identity.get(key) for key in ('Id', 'RepoDigests', 'Architecture', 'Os')}
    if mode == 'probes':
        try:
            pilot_probes(manifest, report, output, docker, env, image, token)
        finally:
            report['recovered_containers'] = TOOLS['cleanup_fixtures'](docker, env, token)
        return
    common = json.loads((COMMON / 'scenario.json').read_text())
    archive = COMMON / 'image.tar'
    if TOOLS['file_hash'](archive) != manifest['common_static_fixture']['archive_sha256']:
        raise RuntimeError('common Docker archive changed')
    require(cli(docker, env, ['load', '--input', str(archive)], 120))
    loaded = json.loads(require(cli(docker, env, ['image', 'inspect', common['image']])))[0]
    if loaded['Id'] != manifest['common_static_fixture']['config_digest']:
        raise RuntimeError('unexpected common fixture config digest')
    report['common_image'] = loaded['Id']
    budget = manifest['suites'][mode]
    count = budget.get('samples_per_session', budget.get('samples'))
    report['groups'] = groups = []
    limits = manifest['lifecycle_limits']
    workloads = [
        ('alpine-true', (limits, image, ['/bin/true'], 0, b'', b'')),
        ('alpine-stream-exit', (limits, image, ['/bin/sh', '-c',
            'printf docker-stdout; printf docker-stderr >&2; exit 23'], 23, b'docker-stdout', b'docker-stderr')),
        ('common-static', (limits, common['image'], common['command'], 0, b'', b'')),
    ]
    index = 0
    try:
        for workload, spec in workloads:
            for network in ('none', 'bridge'):
                for lane in ('api', 'cli'):
                    series = {'workload': workload, 'network': network, 'lane': lane,
                              'warmups': [], 'samples': []}
                    groups.append(series)
                    window = None
                    for n in range(count + budget['warmups']):
                        key = 'warmups' if n < budget['warmups'] else 'samples'
                        if n == budget['warmups']:
                            window = time.monotonic_ns()
                        index += 1
                        report['in_flight'] = {'index': index, 'workload': workload, 'network': network, 'lane': lane}
                        row = sample(connection, docker, env, spec, network, lane, token, index)
                        series[key].append(row)
                        report.pop('in_flight')
                        if row.get('cleanup_error'):
                            raise RuntimeError('workload cleanup failed')
                        if row['error'] and key == 'warmups':
                            series['admission_failed'] = True
                            break
                    series['summary'] = TOOLS['summarize'](series['samples'])
                    if window is not None:
                        series['measured_wall_ns'] = time.monotonic_ns() - window
        if mode == 'pilot':
            pilot_probes(manifest, report, output, docker, env, image, token)
    finally:
        report['recovered_containers'] = TOOLS['cleanup_fixtures'](docker, env, token)
