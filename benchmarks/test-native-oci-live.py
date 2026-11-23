#!/usr/bin/env python3
"""Prove staged OCI argv, environment, credentials, streams and cleanup in Jetstream."""

import argparse
import base64
import json
import os
from pathlib import Path
import runpy
import select
import signal
import socket
import subprocess
import sys
import time
import tempfile
import uuid

HERE = Path(__file__).resolve().parent
WIRE = runpy.run_path(str(HERE / 'native-fresh-lifecycle.py'))
TOOLS = runpy.run_path(str(HERE / 'fresh-lifecycle.py'))
PRODUCTION = runpy.run_path(str(HERE.parent / 'build-support/run-conjet-speedup.py'))
SCRATCH = WIRE['SCRATCH']


def call(channel, opcode, payload, reply):
    kind, body = WIRE['call'](channel, opcode, payload)
    if kind != reply:
        raise RuntimeError(f'expected frame {reply}, got {kind}: {body}')
    return body


def execute(channel, request, expected_code, expected_output):
    accepted = call(channel, 8, request, 13)
    handle = accepted['handle']
    result = call(channel, 10, {'handle': handle, 'after_revision': 2**64 - 1,
                                'budget_ms': 3000}, 13)
    if result['exec'] != 'confirmed' or result['exit'] != {'code': expected_code} or result['cleanup'] != 'complete':
        raise RuntimeError(f'OCI result differs from expected execution: {result}')
    for name, expected in zip(('stdout', 'stderr'), expected_output):
        output = call(channel, 12, {'handle': handle, 'stream': name, 'offset': 0,
                                    'max_bytes': 8192, 'budget_ms': 1000}, 14)
        if not output['eof'] or output['dropped_bytes'] or base64.b64decode(output['data']) != expected:
            raise RuntimeError(f'{name} differs from OCI canary: {output}')
    return result


def verify_native(process, session, ready, report):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as channel:
        channel.settimeout(8)
        channel.connect(str(session / 'native-launch.sock'))
        if channel.getsockopt(0, 2) != process.pid:
            raise RuntimeError('unexpected OCI native socket peer')
        boot = WIRE['authenticate'](channel, (session / 'launch.key').read_bytes(),
                                    'native_oci_arm64_v1')
        status = call(channel, 20, {'budget_ms': 1000}, 20)
        if status['image_digest'] != ready['image_digest']:
            raise RuntimeError('unexpected OCI config digest')
        body = {'boot_id': boot, 'sequence': 1, 'operation_id': uuid.uuid4().hex,
                'budget_ms': 3000, 'spec': {'image_digest': status['image_digest'],
                'argv': ['/bin/sh', '-c',
                         'printf "%s:%s:%s" "$1" "$PROOF" "$PWD"; printf err >&2; exit 23',
                         'sh', 'arg'], 'env': ['PROOF=env'], 'cwd': '/tmp',
                'uid': 65532, 'gid': 65532, 'network': 'none',
                'limits': {'memory_bytes': 16777216, 'cpu_millicores': 500, 'pids': 4}}}
        refused = call(channel, 17, body, 15)
        if refused['code'] != 'unsupported_option':
            raise RuntimeError('OCI prepared submission was not explicitly rejected')
        report['argv_env_cwd'] = execute(channel, body, 23, (b'arg:env:/tmp', b'err'))
        body.update(sequence=2, operation_id=uuid.uuid4().hex)
        body['spec']['argv'] = ['/bin/busybox', 'id', '-u']
        report['uid'] = execute(channel, body, 0, (b'65532\n', b''))
        call(channel, 7, {'budget_ms': 3000}, 16)


def api_true(api, image, name=None):
    create = '/v1.44/containers/create' + ('?name=' + name if name else '')
    response = TOOLS['api'](api, 'POST', create, (201,), {
        'Image': image, 'User': '65532:65532', 'Cmd': ['/bin/true'],
        'HostConfig': {'NetworkMode': 'none', 'Memory': 16777216,
                       'NanoCpus': 500000000, 'PidsLimit': 4}})
    path = '/v1.44/containers/' + response['Id']
    TOOLS['api'](api, 'POST', path + '/start', (204,))
    result = TOOLS['api'](api, 'POST', path + '/wait?condition=next-exit', (200,))
    if result['StatusCode'] != 0 or result.get('Error'):
        raise RuntimeError('native Docker API workload failed')
    TOOLS['api'](api, 'DELETE', path, (204,))


def measure_lifecycle(report, counts, run, api, events, image, limits):
    report['lifecycle'] = series = {}
    workload_ids = set()
    cli = ['run', '--rm', '--pull', 'never', *limits]
    for lane in ('cli', 'api'):
        series[lane] = data = {'warmups': [], 'samples': []}
        for bucket, count in [('warmups', counts['warmups']), ('samples', counts['samples_per_session'])]:
            window = time.monotonic_ns()
            for index in range(count):
                name = f'oci-{lane}-{bucket}-{index}'
                before = time.monotonic_ns()
                row = {'name': name, 'elapsed_ns': None, 'error': None}
                data[bucket].append(row)
                try:
                    if lane == 'cli':
                        run([*cli, '--name', name, image, '/bin/true'], stdout=b'', stderr=b'')
                    else:
                        api_true(api, image, name)
                    row['elapsed_ns'] = time.monotonic_ns() - before
                    history = [event for event in events() if event['Actor']['Attributes']['name'] == name]
                    if [event['Action'] for event in history] != ['create', 'start', 'die', 'destroy']:
                        raise RuntimeError('missing one-use Docker lifecycle witness')
                    terminal = history[2]['Actor']['Attributes']
                    handle = terminal['conjet.native_handle']
                    if (terminal['conjet.guest_cleanup'], terminal['exitCode'], terminal['conjet.backend']) != (
                            'complete', '0', 'jetstream-native-oci') or not handle or handle in workload_ids:
                        raise RuntimeError('missing verified native execution or cleanup')
                    workload_ids.add(handle)
                    row['terminal'] = terminal
                except Exception as failure:
                    row['error'] = str(failure)
                    if row['elapsed_ns'] is None:
                        row['elapsed_ns'] = time.monotonic_ns() - before
                    raise
                finally:
                    data[f'{bucket}_wall_ns'] = time.monotonic_ns() - window


def verify_docker(args, session, report):
    image = args.image
    adapter = HERE.parent / 'build-support/conjet-native-docker.py'
    with tempfile.TemporaryDirectory(dir=SCRATCH, prefix='cjd-') as temporary:
        root = Path(temporary)
        context = 'conjet-speedup'
        endpoint = root / 'docker.sock'
        config = root / 'config'
        config.mkdir(mode=0o700)
        env = {'PATH': '/usr/bin:/bin', 'DOCKER_CONFIG': str(config), 'HOME': temporary}
        docker = ['/opt/homebrew/bin/docker', '--config', str(config)]
        subprocess.run(docker + ['context', 'create', context, '--docker', f'host=unix://{endpoint}'],
                       env=env, check=True, timeout=8, capture_output=True)
        docker += ['--context', context]
        limits = ['--network', 'none', '--user', '65532:65532', '--memory', '16m',
                  '--pids-limit', '4', '--cpus', '0.5']
        command = [sys.executable, str(adapter), '--experimental', '--native-session', str(session),
                   '--receipt', str(args.receipt), '--image', image, '--socket', str(endpoint)]
        report['adapter_argv'] = command
        report['binary_sha256'].update(adapter=TOOLS['file_hash'](adapter), docker=TOOLS['file_hash'](Path(docker[0])))
        with (args.output / 'adapter.stderr').open('w') as log:
            with subprocess.Popen(command, env=env, stdout=subprocess.PIPE, stderr=log,
                                  text=True) as bridge:
                try:
                    if not select.select([bridge.stdout], [], [], 8)[0] or not bridge.stdout.readline():
                        raise RuntimeError('Docker adapter did not start')
                    api = TOOLS['UnixHTTP'](endpoint, bridge.pid)
                    version = TOOLS['api'](api, 'GET', '/version', (200,))
                    if version['Platform']['Name'] != 'Conjet Native OCI':
                        raise RuntimeError('unexpected Docker adapter endpoint')

                    def run(argv, code=0, stdout=None, stderr=None):
                        trial = subprocess.run(docker + argv, env=env, capture_output=True, timeout=14)
                        if (trial.returncode != code or (stdout is not None and trial.stdout != stdout)
                                or (stderr is not None and trial.stderr != stderr)):
                            raise RuntimeError(f'Docker CLI assertion failed for {argv}: {trial}')
                        return trial.stdout.decode().strip()

                    run(['run', '--rm', '--pull', 'never', *limits, '-w', '/tmp', '-e', 'PROOF=env',
                         image, '/bin/sh', '-c', 'printf "%s:%s:%s" "$1" "$PROOF" "$PWD"; printf err >&2; exit 23',
                         'sh', 'arg'], 23, b'arg:env:/tmp', b'err')
                    run(['create', '--name', 'denied', *limits, '--privileged', image], 1,
                        stderr=b'Error response from daemon: unsupported Docker HostConfig option Privileged\n')
                    name = 'oci-explicit'
                    identifier = run(['create', '--name', name, *limits, image, '/bin/busybox', 'id', '-u'])
                    observed = TOOLS['api'](api, 'GET', f'/v1.44/containers/{identifier}/json', (200,))
                    if observed['Driver'] != 'jetstream-native-oci' or observed['State']['Status'] != 'created':
                        raise RuntimeError('backend attribution or created state differs')
                    run(['start', name])
                    run(['start', name], 1)
                    run(['wait', name], 0, b'0\n')
                    run(['rm', name])
                    name = 'oci-cancel'
                    run(['run', '-d', '--name', name, '--pull', 'never', *limits, image, '/bin/sleep', '15'])
                    denied = TOOLS['api'](api, 'POST', '/v1.44/containers/create?name=oci-over-capacity', (409,), {
                        'Image': image, 'User': '65532:65532', 'Cmd': ['/bin/true'],
                        'HostConfig': {'NetworkMode': 'none', 'Memory': 16777216,
                                       'NanoCpus': 500000000, 'PidsLimit': 4}})
                    if 'capacity is occupied' not in denied['message']:
                        raise RuntimeError('native adapter did not refuse admission at capacity')
                    report['capacity_rejected'] = True
                    run(['rm', '-f', name])

                    def events():
                        api.request('GET', '/events')
                        return [json.loads(line) for line in api.getresponse().read().splitlines()]

                    report['events'] = events()
                    starts = [event for event in report['events'] if event['Action'] == 'start'
                              and event['Actor']['ID'] == identifier]
                    if len(starts) != 1:
                        raise RuntimeError('explicit start was replayed')

                    # Drop the first Start response. The next client may
                    # observe its disposition, but must not launch again.
                    name = 'oci-disconnect'
                    identifier = run(['create', '--name', name, *limits, image, '/bin/true'])
                    request = f'POST /v1.44/containers/{identifier}/start HTTP/1.1\r\n'
                    with socket.socket(socket.AF_UNIX) as dropped:
                        dropped.settimeout(2)
                        dropped.connect(str(endpoint))
                        if dropped.getsockopt(0, 2) != bridge.pid:
                            raise RuntimeError('wrong Docker peer for disconnect test')
                        dropped.sendall((request + 'Host: localhost\r\nContent-Length: 0\r\n'
                                         'Connection: close\r\n\r\n').encode())
                    reply = TOOLS['api'](api, 'POST',
                        f'/v1.44/containers/{identifier}/wait?condition=next-exit', (200,))
                    if reply['StatusCode'] != 0:
                        raise RuntimeError('disconnected start did not complete')
                    run(['start', name], 1)
                    run(['rm', name])
                    report['disconnected_start'] = [event for event in events()
                        if event['Actor']['ID'] == identifier]
                    if [event['Action'] for event in report['disconnected_start']] != [
                            'create', 'start', 'die', 'destroy']:
                        raise RuntimeError('unexpected events after disconnected start')

                    report['pilot'] = pilot = {'cli': [], 'api': []}
                    for _ in range(args.samples):
                        before = time.monotonic_ns()
                        run(['run', '--rm', '--pull', 'never', *limits, image, '/bin/true'],
                            stdout=b'', stderr=b'')
                        pilot['cli'].append(time.monotonic_ns() - before)

                        before = time.monotonic_ns()
                        api_true(api, image)
                        pilot['api'].append(time.monotonic_ns() - before)
                    report['final_pilot_events'] = events()
                    if args.benchmark_lifecycle:
                        manifest = json.loads((HERE / 'scenarios/docker-comparison-v1.json').read_bytes())
                        counts = manifest['suites']['lifecycle']
                        ps = ['/bin/ps', '-p', f"{report['native_engine_pid']},{bridge.pid}",
                              '-o', 'pid=,time=,rss=']
                        report['process_before'] = TOOLS['run'](ps)
                        try:
                            measure_lifecycle(report, counts, run, api, events, image, limits)
                        finally:
                            report['process_after'] = TOOLS['run'](ps)
                    api.close()
                    report['ordinary_docker_cli'] = True
                finally:
                    if bridge.poll() is None:
                        bridge.send_signal(signal.SIGTERM)
                    output = bridge.communicate(timeout=45)[0]
                    (args.output / 'backend-dispatch.jsonl').write_text(output)
            if bridge.returncode or endpoint.exists():
                raise RuntimeError('Docker adapter shutdown did not remove its socket')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('vmm', 'kernel', 'guest', 'package', 'output'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--receipt', type=Path)
    parser.add_argument('--image')
    parser.add_argument('--samples', type=int, choices=range(0, 21), default=0)
    parser.add_argument('--benchmark-lifecycle', action='store_true',
                        help='run the full no-network native OCI CLI and API sample budgets')
    args = parser.parse_args()
    if bool(args.receipt) != bool(args.image):
        parser.error('--receipt and --image must be supplied together')
    if args.benchmark_lifecycle and (not args.receipt or args.samples):
        parser.error('--benchmark-lifecycle requires Docker mode and a separate run from --samples')
    for name in ('vmm', 'kernel', 'guest', 'package'):
        value = getattr(args, name).resolve(strict=True)
        if not value.is_relative_to(SCRATCH):
            parser.error(f'{name} must reside on ExternalSSD')
        setattr(args, name, value)
    if not args.output.parent.resolve(strict=True).is_relative_to(SCRATCH):
        parser.error('output must reside on ExternalSSD')
    args.output.mkdir(mode=0o700)
    before = PRODUCTION['production']()
    report = {'production_before': before, 'passed': False, 'load_before': os.getloadavg(),
              'harness_revision': TOOLS['run'](['/usr/bin/git', '-C', HERE.parent, 'rev-parse', 'HEAD'])}
    argv = [str(args.vmm), 'native', '--experimental', 'serve', '--scratch', str(SCRATCH),
            '--kernel', str(args.kernel), '--kernel-sha512',
            args.kernel.with_name(args.kernel.name + '.sha512sum').read_text().split()[0],
            '--guest-init', str(args.guest), '--oci-package', str(args.package),
            '--sha256', TOOLS['file_hash'](args.package)]
    report['argv'] = argv
    report['binary_sha256'] = {name: TOOLS['file_hash'](getattr(args, name))
                              for name in ('vmm', 'kernel', 'guest', 'package')}
    try:
        with (args.output / 'vmm.stderr').open('w') as log:
            with subprocess.Popen(argv, env={'PATH': '/usr/bin:/bin'}, stdout=subprocess.PIPE,
                                  stderr=log, text=True) as process:
                session = None
                try:
                    if not select.select([process.stdout], [], [], 20)[0]:
                        raise RuntimeError('OCI guest readiness timed out')
                    line = process.stdout.readline()
                    if not line:
                        raise RuntimeError('OCI guest exited before readiness')
                    ready = json.loads(line)
                    session = Path(ready['session'])
                    if process.pid != ready['pid'] or TOOLS['current_executable'](process.pid) != args.vmm:
                        raise RuntimeError('OCI session does not own the requested executable')
                    report['native_engine_pid'] = process.pid
                    if args.receipt:
                        verify_docker(args, session, report)
                        subprocess.run([args.vmm, 'native', '--experimental', 'stop',
                                        '--session', session], env={'PATH': '/usr/bin:/bin'},
                                       check=True, timeout=12, capture_output=True)
                    else:
                        verify_native(process, session, ready, report)
                    if process.wait(timeout=12) != 0 or session.exists():
                        raise RuntimeError('OCI clean shutdown was not verified')
                    report['passed'] = True
                finally:
                    if process.poll() is None:
                        process.send_signal(signal.SIGTERM)
                        try:
                            process.wait(timeout=15)
                        except subprocess.TimeoutExpired:
                            process.kill()
                            process.wait(timeout=5)
                    report['session_removed'] = session is not None and not session.exists()
    except BaseException as error:
        report['error'] = str(error) or type(error).__name__
        raise
    finally:
        report['production_after'] = PRODUCTION['production']()
        report['load_after'] = os.getloadavg()
        report['passed'] &= before == report['production_after']
        (args.output / 'session.json').write_text(json.dumps(report, indent=2) + '\n')
    if not report['passed']:
        raise SystemExit('OCI production preservation check failed')


if __name__ == '__main__':
    main()
