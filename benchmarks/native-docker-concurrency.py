"""Check simultaneous attached Docker runs on an isolated native guest."""

from contextlib import ExitStack
import json
import os
from pathlib import Path
import runpy
import signal
import subprocess
import time


HERE = Path(__file__).resolve().parent
MATCHED = runpy.run_path(str(HERE / 'native-docker-comparison.py'))
INSTALL = runpy.run_path(str(HERE / 'native-oci-live-install.py'))


def collect(endpoint, peer, docker, env, output, session, vmm_pid):
    tools = MATCHED['TOOLS']
    image = MATCHED['IMAGE']['ref']
    connection = tools['UnixHTTP'](endpoint, peer)
    version = tools['api'](connection, 'GET', '/version', (200,))
    if (version['Platform']['Name'] != 'Conjet Native OCI' or version['ConjetContainerCapacity'] != 8
            or tools['file_hash'](Path(docker[0])) != MATCHED['MANIFEST']['clients']['docker']['sha256']):
        raise RuntimeError('candidate endpoint or pinned client differs from the concurrency contract')
    results = []
    interrupted = []
    try:
        with INSTALL['channel'](session, vmm_pid) as (guest, boot):
            witnesses = set()
            for count in (1, 2, 4, 8):
                with ExitStack() as squad:
                    clients = []
                    for index in range(count):
                        name = f'cj-concurrent-{count}-{index}'
                        cmd = [*docker, 'run', *MATCHED['FLAGS'], '--name', name, image,
                               '/bin/sh', '-c', f'printf "%s" {name}; exec /bin/busybox sleep 4']
                        child = subprocess.Popen(cmd, env=env, stdout=subprocess.PIPE,
                                                 stderr=subprocess.PIPE)
                        squad.callback(stop, child, name, interrupted)
                        clients.append((name, child))
                    deadline = time.monotonic() + 3
                    while True:
                        live = INSTALL['exchange'](guest, 19, {'budget_ms': 1000, 'boot_id': boot},
                                                   19)['active_workloads']
                        if len(live) == count and all(row['populated'] and row['paths']['overlay_present']
                                                      for row in live):
                            break
                        if time.monotonic() >= deadline:
                            raise RuntimeError(f'Docker clients did not overlap at size {count}: {live}')
                        time.sleep(0.02)
                    exhausted = None
                    if count == 8:
                        rejected = subprocess.run(
                            [*docker, 'create', *MATCHED['FLAGS'], '--name', 'cj-exhausted', image, '/bin/true'],
                            env=env, capture_output=True, text=True, timeout=5,
                        )
                        exhausted = {'exit': rejected.returncode, 'stderr': rejected.stderr}
                        if rejected.returncode != 1 or 'capacity' not in rejected.stderr:
                            raise RuntimeError(f'ninth Docker create did not reject capacity: {exhausted}')
                    witnesses_before = len(witnesses)
                    row = {'count': count, 'live': live, 'exhausted': exhausted, 'completed': []}
                    results.append(row)
                    for name, child in clients:
                        stdout, stderr = child.communicate(timeout=8)
                        if (child.returncode, stdout, stderr) != (0, name.encode(), b''):
                            raise RuntimeError(f'Docker output or exit failed for {name}: '
                                               f'{child.returncode}, {stdout[:300]!r}, {stderr[:300]!r}')
                        receipt = MATCHED['native_terminal'](connection, name, witnesses)
                        row['completed'].append({'name': name, 'guest': receipt})
                    if len(witnesses) - witnesses_before != count:
                        raise RuntimeError('concurrent Docker owners reused workload identities')
            controls(connection, docker, env, output, guest, boot)
    finally:
        connection.close()
        (output / 'docker-overlap.json').write_text(json.dumps({
            'groups': results, 'unfinished_clients': interrupted,
        }, indent=2) + '\n')


def stop(child, name, interrupted):
    if child.stdout.closed:
        return
    if child.poll() is None:
        child.terminate()
        try:
            stdout, stderr = child.communicate(timeout=2)
        except subprocess.TimeoutExpired:
            child.kill()
            stdout, stderr = child.communicate(timeout=2)
    else:
        stdout, stderr = child.communicate(timeout=2)
    interrupted.append({'name': name, 'exit': child.returncode,
                        'stdout': stdout[:300].decode(errors='replace'),
                        'stderr': stderr[:300].decode(errors='replace')})


def controls(connection, docker, env, output, guest, boot):
    cases = {}
    image = MATCHED['IMAGE']['ref']
    flags = [flag for flag in MATCHED['FLAGS'] if flag != '--rm']
    prefix = MATCHED['PREFIX']

    def call(label, *args, expected=0, stderr=None):
        start = time.monotonic_ns()
        result = subprocess.run([*docker, *args], env=env, capture_output=True, text=True, timeout=16)
        cases[label] = {'argv': args, 'code': result.returncode, 'stdout': result.stdout,
                        'stderr': result.stderr, 'elapsed_ns': time.monotonic_ns() - start}
        if result.returncode != expected or (stderr and stderr not in result.stderr):
            raise RuntimeError(f'control check {label} failed: {cases[label]}')
        return result.stdout.strip()

    def running():
        deadline = time.monotonic() + 3
        while True:
            active = INSTALL['inspect'](guest)['active_workloads']
            if len(active) == 1 and active[0]['exec'] == 'confirmed' and active[0]['phase'] == 'running':
                return
            if time.monotonic() >= deadline:
                raise RuntimeError(f'did not observe exactly one running control fixture: {active}')
            time.sleep(0.02)

    def exit_code(label, name, code):
        actual = call(label, 'wait', name)
        if actual != str(code):
            raise RuntimeError(f'control check {label} expected Docker status {code}, got {actual}')

    try:
        name = 'cj-control'
        command = ['/bin/sh', '-c', 'trap "exit 42" TERM; while :; do :; done']
        container = call('create', 'create', *flags, '--name', name, image, *command)
        call('name_conflict', 'create', *flags, '--name', name, image, '/bin/true',
             expected=1, stderr='name is already owned')
        before = INSTALL['inspect'](guest)['active_workloads']
        if before:
            raise RuntimeError('Docker create started a native workload')
        call('start', 'start', name)
        running()
        call('start_replay', 'start', name, expected=1, stderr='already been submitted')
        time.sleep(0.2)
        call('graceful_stop', 'stop', '--time', '2', name)
        exit_code('graceful_status', name, 42)
        call('first_restart', 'restart', '--time', '0', name)
        running()
        with ExitStack() as cleanup:
            subscribe = MATCHED['TOOLS']['UnixHTTP'](connection.endpoint, connection.pid)
            cleanup.callback(subscribe.close)
            subscribe.request('POST', prefix + '/containers/' + name + '/wait?condition=next-exit')
            response = subscribe.getresponse()
            cleanup.callback(response.close)
            if response.status != 200:
                raise RuntimeError('next-exit subscription failed before restart')
            call('active_restart', 'restart', '--time', '0', name)
            old = json.loads(response.read(16384))
            if old != {'StatusCode': 137, 'Error': None}:
                raise RuntimeError(f'old execution waiter received the wrong result: {old}')
            cases['old_generation_wait'] = old
        running()
        inspected = json.loads(call('inspect_restart', 'inspect', '--format', '{{json .}}', name))
        if inspected['Id'] != container or inspected['RestartCount'] != 2:
            raise RuntimeError('restart did not preserve container ID and advance execution generation')
        call('kill', 'kill', '--signal', 'SIGKILL', name)
        exit_code('kill_status', name, 137)
        call('remove', 'rm', name)
        connection.request('GET', prefix + '/events')
        events = [json.loads(line) for line in connection.getresponse().read(65536).splitlines()]
        deaths = [event['Actor']['Attributes'] for event in events
                  if event['Actor']['ID'] == container and event['Action'] == 'die']
        if (len(deaths) != 3 or len({row['conjet.native_handle'] for row in deaths}) != 3
                or any(row['conjet.guest_cleanup'] != 'complete' for row in deaths)):
            raise RuntimeError('restart did not produce distinct verified guest executions')
        cases['guest_executions'] = deaths
        name = 'cj-control-timeout'
        call('timeout_create', 'create', *flags, '--name', name, image, '/bin/busybox', 'sleep', '20')
        call('timeout_start', 'start', name)
        running()
        call('timeout_stop', 'stop', '--time', '1', name)
        if cases['timeout_stop']['elapsed_ns'] < 1_000_000_000:
            raise RuntimeError('stop skipped the requested grace before escalation')
        exit_code('timeout_status', name, 137)
        call('timeout_remove', 'rm', name)
        if INSTALL['inspect'](guest)['active_workloads']:
            raise RuntimeError('controls left a native workload active')
    finally:
        (output / 'docker-controls.json').write_text(json.dumps(cases, indent=2) + '\n')


def collect_loss(endpoint, peer, output, session, vmm_pid):
    tools = MATCHED['TOOLS']
    image = MATCHED['IMAGE']['ref']
    name = 'cj-vm-loss'
    connection = tools['UnixHTTP'](endpoint, peer)
    cases = {}
    try:
        if tools['api'](connection, 'GET', '/version', (200,))['Platform']['Name'] != 'Conjet Native OCI':
            raise RuntimeError('wrong endpoint for private VM loss diagnostic')
        created = tools['api'](
            connection, 'POST', MATCHED['PREFIX'] + '/containers/create?name=' + name, (201,),
            {'Image': image, 'User': MATCHED['USER'], 'Cmd': ['/bin/busybox', 'sleep', '20'],
             'HostConfig': MATCHED['HOST_CONFIG']},
        )
        cases['create'] = created['Id']
        path = MATCHED['PREFIX'] + '/containers/' + name
        tools['api'](connection, 'POST', path + '/start', (204,))
        with INSTALL['channel'](session, vmm_pid) as (guest, boot):
            deadline = time.monotonic() + 3
            while True:
                active = INSTALL['inspect'](guest)['active_workloads']
                if len(active) == 1 and active[0]['exec'] == 'confirmed' and active[0]['phase'] == 'running':
                    cases['native_before_loss'] = active[0]
                    break
                if time.monotonic() >= deadline:
                    raise RuntimeError('private VM loss fixture never reached confirmed execution')
                time.sleep(0.02)
        os.kill(vmm_pid, signal.SIGKILL)
        cases['owned_vmm_killed'] = vmm_pid
        lost = tools['api'](connection, 'POST', path + '/wait?condition=not-running', (200,))
        if lost['StatusCode'] != 125 or not (lost.get('Error') or {}).get('Message'):
            raise RuntimeError(f'VM loss returned an ordinary terminal exit: {lost}')
        cases['invalidated_wait'] = lost
        cases['blocked_replay'] = tools['api'](connection, 'POST', path + '/start', (409,))
        cases['blocked_new_admission'] = tools['api'](
            connection, 'POST', MATCHED['PREFIX'] + '/containers/create?name=cj-after-loss', (409,),
            {'Image': image, 'User': MATCHED['USER'], 'Cmd': ['/bin/true'],
             'HostConfig': MATCHED['HOST_CONFIG']},
        )
    finally:
        connection.close()
        (output / 'docker-vm-loss.json').write_text(json.dumps(cases, indent=2) + '\n')
