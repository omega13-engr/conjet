"""Validate noninteractive Docker exec against the live native workload."""

from contextlib import closing
import json
from pathlib import Path
import runpy
import socket
import struct
import subprocess
import time


HERE = Path(__file__).resolve().parent
MATCHED = runpy.run_path(str(HERE / 'native-docker-comparison.py'))
INSTALL = runpy.run_path(str(HERE / 'native-oci-live-install.py'))
FROZEN = runpy.run_path(str(HERE / 'docker-comparison-workloads.py'))


def exec_stream_frame(stream):
    def exact(count):
        data = bytearray()
        while len(data) < count:
            chunk = stream.recv(count - len(data))
            if not chunk:
                raise RuntimeError('live exec stream closed before terminal status')
            data.extend(chunk)
        return bytes(data)

    channel, count = struct.unpack('>B3xI', exact(8))
    if channel not in (1, 2, 3, 4) or not 1 <= count <= 8192 or (channel == 4 and count != 1):
        raise RuntimeError('invalid live native exec stream frame')
    return channel, exact(count)


def live_exec_stream(session, vmm_pid, control, active, cases):
    request = {'handle': active, 'budget_ms': 12000,
               'argv': ['/bin/sh', '-c', 'printf ready; cat; printf err >&2; exit 23']}
    data = bytes(range(256)) * 64
    with INSTALL['channel'](session, vmm_pid) as (rejected, _):
        cases['live_long_budget_denied'] = INSTALL['exchange'](
            rejected, 33, {**request, 'budget_ms': 600000}, 15, 'invalid_spec')
    with INSTALL['channel'](session, vmm_pid) as (live, _):
        accepted = INSTALL['exchange'](live, 33, request, 33)
        if accepted.get('attached') is not True or exec_stream_frame(live) != (1, b'ready'):
            raise RuntimeError('live exec had no output before client stdin')
        for offset in range(0, len(data), 4096):
            payload = data[offset:offset + 4096]
            live.sendall(struct.pack('>I', len(payload)) + payload)
        live.sendall(bytes(4))
        captured = {1: bytearray(), 2: bytearray()}
        while True:
            channel, payload = exec_stream_frame(live)
            if channel == 4:
                if payload != bytes([23]):
                    raise RuntimeError('live exec did not preserve its exit status')
                break
            if channel not in captured:
                raise RuntimeError(f'live native exec error: {payload!r}')
            captured[channel].extend(payload)
        if captured != {1: data, 2: b'err'}:
            raise RuntimeError('live exec did not preserve binary stdout and stderr')
    if INSTALL['inspect'](control)['exec_streams'] != 0:
        raise RuntimeError('terminal live exec retained its slot')
    cases['live_stream'] = {'binary_bytes': len(data), 'stderr': 'err', 'code': 23,
                            'output_before_input': True, 'cleanup': 'complete'}
    with INSTALL['channel'](session, vmm_pid) as (live, _):
        request['argv'] = ['/bin/sh', '-c', 'printf ready; exec sleep 10']
        INSTALL['exchange'](live, 33, request, 33)
        if exec_stream_frame(live) != (1, b'ready'):
            raise RuntimeError('live exec disconnect fixture did not start')
    until = time.monotonic() + 2
    while INSTALL['inspect'](control)['exec_streams'] != 0:
        if time.monotonic() >= until:
            raise RuntimeError('disconnected live exec did not release its workload slot')
        time.sleep(.02)
    cases['live_disconnect'] = True


def buildkit_version_stream(endpoint, peer, api, call, cases, session, vmm_pid):
    manifest = json.loads((HERE / 'scenarios/docker-comparison-v1.json').read_text())
    image = manifest['images']['buildkit']['ref']
    prefix = MATCHED['PREFIX']
    name = 'cj-buildkit-control'
    cache = name + '_state'
    active_names = []

    def start(label, container):
        call(label, ['run', '--detach', '--pull', 'never', '--name', container,
                     '--network', 'none', '--memory', '64m', '--pids-limit', '32',
                     '--mount', f'type=volume,source={cache},target=/var/lib/buildkit',
                     '--entrypoint', '/bin/busybox', image, 'sleep', '30'])
        active_names.append(container)

    call('buildkit_pull', ['pull', '--platform', 'linux/arm64', image], timeout=180)
    call('buildkit_volume_create', ['volume', 'create', cache], stdout=(cache + '\n').encode())
    try:
        start('buildkit_start', name)
        with INSTALL['channel'](session, vmm_pid) as (guest, _):
            deadline = time.monotonic() + 3
            while True:
                active = INSTALL['inspect'](guest)['active_workloads']
                if len(active) == 1 and active[0]['phase'] == 'running':
                    break
                if time.monotonic() >= deadline:
                    raise RuntimeError('pinned BuildKit image did not reach native running state')
                time.sleep(.02)
        call('buildkit_pinned_mode', ['exec', name, '/bin/busybox', 'stat', '-c', '%a',
                                     '/usr/bin/fusermount3'], stdout=b'4755\n')
        call('buildkit_cache_write', ['exec', name, 'sh', '-c',
                                      'printf owned-cache >/var/lib/buildkit/proof'])
        body = {'Cmd': ['buildkitd', '--version'], 'AttachStdin': True,
                'AttachStdout': True, 'AttachStderr': True}
        exec_id = MATCHED['TOOLS']['api'](api, 'POST', f'{prefix}/containers/{name}/exec', (201,), body)['Id']
        route = f'{prefix}/exec/{exec_id}'
        with socket.socket(socket.AF_UNIX) as connection:
            connection.settimeout(5)
            connection.connect(str(endpoint))
            if connection.getsockopt(0, 2) != peer:
                raise RuntimeError('BuildKit exec did not connect to the private Docker owner')
            payload = b'{}'
            connection.sendall((f'POST {route}/start HTTP/1.1\r\nHost: conjet\r\n'
                                'Upgrade: tcp\r\nConnection: Upgrade\r\n'
                                'Content-Type: application/json\r\n'
                                f'Content-Length: {len(payload)}\r\n\r\n').encode() + payload)
            # The pinned Buildx driver leaves its stdin open while waiting
            # for buildkitd --version. Exercise that same attached boundary.
            with connection.makefile('rb') as stream:
                status = stream.readline(4096)
                if not status.startswith(b'HTTP/1.1 101 '):
                    raise RuntimeError(f'BuildKit exec did not upgrade: {status!r}')
                total = len(status)
                while True:
                    line = stream.readline(4096)
                    total += len(line)
                    if not line or total > 8192:
                        raise RuntimeError('invalid BuildKit exec response header')
                    if line == b'\r\n':
                        break
                outputs = {1: bytearray(), 2: bytearray()}
                while frame := stream.read(8):
                    channel, size = struct.unpack('>B3xI', frame)
                    if channel not in (1, 2, 3) or not 0 < size <= 8192:
                        raise RuntimeError('invalid BuildKit exec output')
                    data = stream.read(size)
                    if len(data) != size:
                        raise RuntimeError('BuildKit exec output was truncated')
                    if channel == 3:
                        cases['buildkit_live_error'] = data.decode(errors='replace')
                        raise RuntimeError(f'BuildKit exec stream failed: {data!r}')
                    if len(outputs[channel]) + size > 16384:
                        raise RuntimeError('BuildKit exec output exceeded the diagnostic limit')
                    outputs[channel].extend(data)
        observed = outputs[1].decode()
        expected = manifest['images']['buildkit']['tag']
        state = MATCHED['TOOLS']['api'](api, 'GET', route + '/json', (200,))
        cases['buildkit_live_version'] = {'stdout': observed,
                                          'stderr': outputs[2].decode(errors='replace'),
                                          'status': state['ExitCode'], 'running': state['Running']}
        if expected not in observed or outputs[2] or state['ExitCode'] != 0 or state['Running']:
            raise RuntimeError(f'BuildKit version exec changed its output or status: {cases["buildkit_live_version"]}')
        call('buildkit_remove', ['rm', '--force', name], stdout=(name + '\n').encode())
        active_names.remove(name)
        cases['buildkit_cleanup'] = MATCHED['native_terminal'](api, name, set(), 137)
        reopened = name + '-reopen'
        start('buildkit_reopen', reopened)
        call('buildkit_cache_readback', ['exec', reopened, 'cat', '/var/lib/buildkit/proof'],
             stdout=b'owned-cache')
    finally:
        for container in active_names:
            call('buildkit_remove_active', ['rm', '--force', container],
                 stdout=(container + '\n').encode())
        call('buildkit_volume_remove', ['volume', 'rm', cache], stdout=(cache + '\n').encode())
    cases['buildkit_reopen_cleanup'] = MATCHED['native_terminal'](
        api, reopened, {cases['buildkit_cleanup']['conjet.native_handle']}, 137)


def collect(endpoint, peer, docker, env, output, session, vmm_pid, *, buildkit=False):
    tools = MATCHED['TOOLS']
    prefix = MATCHED['PREFIX']
    image = MATCHED['IMAGE']['ref']
    cases = {}
    api = tools['UnixHTTP'](endpoint, peer)
    name = 'cj-exec'
    path = prefix + '/containers/' + name

    def call(label, args, expected=0, stdout=None, stderr=None, stdin=None, timeout=10):
        result = subprocess.run([*docker, *args], env=env, input=stdin, capture_output=True, timeout=timeout)
        cases[label] = {'args': args, 'code': result.returncode, 'stdout': result.stdout.decode(errors='replace'),
                        'stderr': result.stderr.decode(errors='replace')}
        if (result.returncode != expected or (stdout is not None and stdout != result.stdout)
                or (stderr is not None and stderr not in result.stderr)):
            raise RuntimeError(f'Docker exec check {label} failed: {cases[label]}')
        return result

    try:
        if tools['api'](api, 'GET', '/version', (200,))['Platform']['Name'] != 'Conjet Native OCI':
            raise RuntimeError('wrong Docker endpoint for exec')
        call('create', ['create', *MATCHED['FLAGS'][1:], '--name', name,
                        '--env', 'CJ_EXEC_PROOF=context', '--workdir', '/tmp', image, '/bin/sh', '-c',
                        'printf shared-exec >/tmp/cj-exec-proof; exec /bin/busybox sleep 20'])
        call('start', ['start', name], stdout=name.encode() + b'\n')
        with INSTALL['channel'](session, vmm_pid) as (guest, boot):
            deadline = time.monotonic() + 3
            while True:
                running = INSTALL['inspect'](guest)['active_workloads']
                if len(running) == 1 and running[0]['phase'] == 'running':
                    active = running[0]['handle']
                    break
                if time.monotonic() >= deadline:
                    raise RuntimeError(f'exec did not find its live target: {running}')
                time.sleep(0.02)
            time.sleep(0.15)
            call('read_target_upper', ['exec', name, '/bin/busybox', 'cat', '/tmp/cj-exec-proof'],
                 stdout=b'shared-exec')
            call('namespace_uid', ['exec', name, '/bin/busybox', 'id', '-u'], stdout=b'65532\n')
            call('nonzero', ['exec', name, 'sh', '-c', 'printf exec-out; printf exec-err >&2; exit 23'],
                 expected=23, stdout=b'exec-out', stderr=b'exec-err')
            call('inherited_exec_context', ['exec', name, 'sh', '-c', 'printf "%s:%s" "$CJ_EXEC_PROOF" "$PWD"'],
                 stdout=b'context:/tmp')
            data = bytes(range(256)) * 16
            call('stdin_binary', ['exec', '-i', name, 'cat'], stdin=data, stdout=data)
            call('stdin_empty', ['exec', '-i', name, 'cat'], stdin=b'', stdout=b'')
            call('stdin_overflow', ['exec', '-i', name, 'sh', '-c', 'touch /tmp/cj-exec-overflow'],
                 stdin=data + b'x', expected=1, stderr=b'native exec stdin exceeds 4096 bytes')
            call('stdin_overflow_not_executed',
                 ['exec', name, 'sh', '-c', 'test ! -e /tmp/cj-exec-overflow'])
            live_exec_stream(session, vmm_pid, guest, active, cases)
            call('missing', ['exec', name, '/bin/cj-missing-exec'], expected=127)
            call('invalid_creds', ['exec', '--user', '0:0', name, '/bin/true'],
                 expected=1, stderr=b'unsupported Docker exec option User')
            call('deadline', ['exec', name, '/bin/busybox', 'sleep', '8'],
                 expected=1, stderr=b'deadline_exceeded')
            call('after_exec_failure', ['exec', name, '/bin/busybox', 'cat', '/tmp/cj-exec-proof'],
                 stdout=b'shared-exec')
            body = {'Cmd': ['/bin/sh', '-c', 'printf a >>/tmp/cj-exec-once'],
                    'AttachStdout': True, 'AttachStderr': True}
            exec_id = tools['api'](api, 'POST', path + '/exec', (201,), body)['Id']
            exec_path = prefix + '/exec/' + exec_id
            with closing(tools['UnixHTTP'](endpoint, peer)) as submit:
                submit.request('POST', exec_path + '/start', body=b'{"Detach":false,"Tty":false}',
                               headers={'Content-Type': 'application/json',
                                        'Connection': 'Upgrade', 'Upgrade': 'tcp'})
                response = submit.getresponse()
                if response.status != 101:
                    raise RuntimeError('exec start replay fixture did not upgrade')
                response.close()
            inspected = tools['api'](api, 'GET', exec_path + '/json', (200,))
            if inspected['ExitCode'] != 0 or inspected['Running']:
                raise RuntimeError('exec inspect lost the completed exit status')
            cases['duplicate_exec_start'] = tools['api'](api, 'POST', exec_path + '/start', (409,),
                                                        {'Detach': False, 'Tty': False})
            body['Cmd'] = ['sh', '-c', 'printf exec-out; printf exec-err >&2; exit 23']
            plain = prefix + '/exec/' + tools['api'](api, 'POST', path + '/exec', (201,), body)['Id']
            if FROZEN['docker_streams'](api, 'POST', plain + '/start', {'Detach': False, 'Tty': False}) != (
                    b'exec-out', b'exec-err'):
                raise RuntimeError('plain exec API changed the separated output streams')
            cases['plain_exec'] = tools['api'](api, 'GET', plain + '/json', (200,))
            if cases['plain_exec']['ExitCode'] != 23 or cases['plain_exec']['Running']:
                raise RuntimeError('plain exec inspect lost the original exit status')
            call('exec_ran_once', ['exec', name, '/bin/busybox', 'cat', '/tmp/cj-exec-once'], stdout=b'a')
            call('exec_large_streams', ['exec', name, '/bin/sh', '-c',
                 'printf "%0131072d" 0; printf "%08200d" 1 >&2; exit 23'],
                 expected=23, stdout=b'0' * (128 * 1024), stderr=b'0' * 8199 + b'1')
            call('frozen_zero_output', ['exec', name, 'dd', 'if=/dev/zero', 'bs=1024', 'count=128'],
                 stdout=bytes(128 * 1024))
            call('frozen_tty', ['exec', '-t', name, 'sh', '-c', 'test -t 1 && printf tty-ok'],
                 stdout=b'tty-ok')
            call('device_scope', ['exec', name, '/bin/sh', '-c',
                 'printf suppressed >/dev/null; test ! -e /dev/mem && test ! -e /dev/kmsg'],
                 stdout=b'')
            call('exec_output_bound', ['exec', name, '/bin/sh', '-c', 'printf "%0270000d" 0'],
                 expected=1, stdout=b'0' * (256 * 1024), stderr=b'native exec output exceeds the retained limit')
            request = {'handle': active, 'budget_ms': 1000,
                       'argv': ['/bin/sh', '-c', 'printf "%09000d" 0']}
            with INSTALL['channel'](session, vmm_pid) as (output_owner, _):
                lease = INSTALL['exchange'](output_owner, 22, request, 22)
                chunk = {'boot_id': boot, 'budget_ms': 1000, 'output_id': lease['output_id'],
                         'stream': 'stdout', 'offset': 0}
                cases['foreign_output_denied'] = INSTALL['exchange'](guest, 28, chunk, 15, 'not_found')
                cases['output_offset_denied'] = INSTALL['exchange'](
                    output_owner, 28, {**chunk, 'offset': 1}, 15, 'malformed')
            recovery = {**request, 'argv': ['/bin/true']}
            deadline = time.monotonic() + 2
            while True:
                kind, reply = INSTALL['WIRE']['call'](guest, 22, recovery)
                if kind == 22 and reply['exit_code'] == 0:
                    cases['output_disconnect_released'] = True
                    break
                if kind != 15 or reply.get('code') != 'busy' or time.monotonic() >= deadline:
                    raise RuntimeError(f'old exec output lease did not release: {reply}')
            if [row['handle'] for row in INSTALL['inspect'](guest)['active_workloads']] != [active]:
                raise RuntimeError('failed exec changed the native container identity')
            cases['native_handle'] = active
        call('kill', ['kill', name], stdout=name.encode() + b'\n')
        call('wait', ['wait', name], stdout=b'137\n')
        call('removed_target', ['exec', name, '/bin/true'],
             expected=1, stderr=b'native exec target is not running')
        call('rm', ['rm', name], stdout=name.encode() + b'\n')
        cases['cleanup'] = MATCHED['native_terminal'](api, name, set(), 137)
        name = 'cj-exec-remove-active'
        call('active_create', ['create', *MATCHED['FLAGS'][1:], '--name', name, image, '/bin/busybox', 'sleep', '20'])
        call('active_start', ['start', name], stdout=name.encode() + b'\n')
        with INSTALL['channel'](session, vmm_pid) as (guest, boot):
            deadline = time.monotonic() + 3
            while not any(row['phase'] == 'running' for row in INSTALL['inspect'](guest)['active_workloads']):
                if time.monotonic() >= deadline:
                    raise RuntimeError('removal fixture did not reach running')
                time.sleep(0.02)
            child = subprocess.Popen([*docker, 'exec', name, 'sleep', '8'], env=env,
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                while not INSTALL['inspect'](guest)['exec_active']:
                    if time.monotonic() >= deadline or child.poll() is not None:
                        raise RuntimeError('exec never started before container removal')
                    time.sleep(0.02)
                call('remove_active_exec', ['rm', '--force', name], stdout=name.encode() + b'\n')
                stdout, stderr = child.communicate(timeout=6)
                cases['interrupted_exec'] = {'code': child.returncode, 'stdout': stdout.decode(errors='replace'),
                                             'stderr': stderr.decode(errors='replace')}
                if child.returncode == 0 or INSTALL['inspect'](guest)['exec_active']:
                    raise RuntimeError('container removal left exec ownership behind')
                cases['active_removal_cleanup'] = MATCHED['native_terminal'](api, name, set(), 137)
            finally:
                if child.poll() is None:
                    child.terminate()
                    child.wait(timeout=5)
                child.stdout.close()
                child.stderr.close()
        if buildkit:
            buildkit_version_stream(endpoint, peer, api, call, cases, session, vmm_pid)
    finally:
        api.close()
        (output / 'docker-exec.json').write_text(json.dumps(cases, indent=2) + '\n')
