"""Validate noninteractive Docker exec against the live native workload."""

from contextlib import closing
import json
from pathlib import Path
import runpy
import subprocess
import time


HERE = Path(__file__).resolve().parent
MATCHED = runpy.run_path(str(HERE / 'native-docker-comparison.py'))
INSTALL = runpy.run_path(str(HERE / 'native-oci-live-install.py'))


def collect(endpoint, peer, docker, env, output, session, vmm_pid):
    tools = MATCHED['TOOLS']
    prefix = MATCHED['PREFIX']
    image = MATCHED['IMAGE']['ref']
    cases = {}
    api = tools['UnixHTTP'](endpoint, peer)
    name = 'cj-exec'
    path = prefix + '/containers/' + name

    def call(label, args, expected=0, stdout=None, stderr=None):
        result = subprocess.run([*docker, *args], env=env, capture_output=True, timeout=10)
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
                               headers={'Content-Type': 'application/json'})
                response = submit.getresponse()
                if response.status != 101:
                    raise RuntimeError('exec start replay fixture did not upgrade')
                response.close()
            inspected = tools['api'](api, 'GET', exec_path + '/json', (200,))
            if inspected['ExitCode'] != 0 or inspected['Running']:
                raise RuntimeError('exec inspect lost the completed exit status')
            cases['duplicate_exec_start'] = tools['api'](api, 'POST', exec_path + '/start', (409,),
                                                        {'Detach': False, 'Tty': False})
            call('exec_ran_once', ['exec', name, '/bin/busybox', 'cat', '/tmp/cj-exec-once'], stdout=b'a')
            call('exec_large_streams', ['exec', name, '/bin/sh', '-c',
                 'printf "%0131072d" 0; printf "%08200d" 1 >&2; exit 23'],
                 expected=23, stdout=b'0' * (128 * 1024), stderr=b'0' * 8199 + b'1')
            call('frozen_zero_output', ['exec', name, 'dd', 'if=/dev/zero', 'bs=1024', 'count=128'],
                 stdout=bytes(128 * 1024))
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
    finally:
        api.close()
        (output / 'docker-exec.json').write_text(json.dumps(cases, indent=2) + '\n')
