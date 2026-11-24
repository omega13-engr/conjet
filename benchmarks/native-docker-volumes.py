"""Verify named volume ownership through Docker and the private native authority."""

import json
from pathlib import Path
import runpy
import subprocess
import time


MATCHED = runpy.run_path(str(Path(__file__).with_name('native-docker-comparison.py')))
NATIVE = runpy.run_path(str(Path(__file__).with_name('native-oci-live-install.py')))
NAME = 'cj-mount-data'
PAYLOAD = b'conjet native volume canary'


def collect(endpoint, owner_pid, session, vm_pid, output, phase, client, env, *, target='/data'):
    api = MATCHED['TOOLS']['api']
    conn = MATCHED['TOOLS']['UnixHTTP'](endpoint, owner_pid)
    prefix = MATCHED['PREFIX']
    volume_path = prefix + '/volumes/' + NAME
    holder_name = 'cj-volume-holder'
    holder = prefix + '/containers/' + holder_name
    readonly_mount = f'type=volume,source={NAME},target={target},readonly'
    witness = f'{target}/witness'
    image = MATCHED['IMAGE']['ref']
    evidence = {}

    def invoke(arguments, stdout=b'', code=0, stderr=b''):
        return MATCHED['invoke'](client, env, arguments, stdout=stdout, code=code, stderr=stderr)

    def launch_config(argv, **overrides):
        host = dict(MATCHED['HOST_CONFIG'])
        host['Mounts'] = [{'Type': 'volume', 'Source': NAME, 'Target': target, **overrides}]
        return {'Image': image, 'User': MATCHED['USER'], 'Cmd': argv, 'HostConfig': host}

    def run(argv, **kwargs):
        invoke(['run', *MATCHED['FLAGS'], '--mount', readonly_mount, image, *argv], **kwargs)

    try:
        if phase == 'create':
            invoke(['volume', 'create', NAME], stdout=(NAME + '\n').encode())
            evidence['created'] = api(conn, 'GET', volume_path, (200,))
            if evidence['created']['Name'] != NAME or evidence['created']['Driver'] != 'local':
                raise RuntimeError('Docker volume identity is missing')
            malformed = launch_config(['/bin/true'], BindOptions={'Propagation': 'shared'})
            evidence['unsupported_mount'] = api(
                conn, 'POST', prefix + '/containers/create?name=cj-volume-invalid', (400,), malformed)
            holder_config = launch_config(['/bin/sh', '-ec', f'printf "{PAYLOAD.decode()}" >{witness}; '
                                           'exec /bin/busybox sleep 20'])
            api(conn, 'POST', prefix + '/containers/create?name=' + holder_name, (201,), holder_config)
            evidence['busy_created'] = api(conn, 'DELETE', volume_path, (409,))
            api(conn, 'POST', holder + '/start', (204,))
            deadline = time.monotonic() + 3
            argv = [*client, 'exec', holder_name, '/bin/busybox', 'cat', witness]
            while True:
                check = subprocess.run(argv, env=env, capture_output=True, timeout=3)
                if (check.returncode, check.stdout, check.stderr) == (0, PAYLOAD, b''):
                    break
                if time.monotonic() >= deadline:
                    evidence['holder_state'] = api(conn, 'GET', holder + '/json', (200,))['State']
                    logs = subprocess.run([*client, 'logs', holder_name], env=env, capture_output=True,
                                          timeout=3, text=True)
                    evidence['holder_logs'] = {'stdout': logs.stdout, 'stderr': logs.stderr}
                    raise RuntimeError('native holder did not write the mounted payload')
                time.sleep(0.05)
            evidence['mount'] = api(conn, 'GET', holder + '/json', (200,))['Mounts']
            if (len(evidence['mount']) != 1 or not evidence['mount'][0]['RW']
                    or evidence['mount'][0]['Destination'] != target):
                raise RuntimeError('Docker inspected the wrong volume mount')
            evidence['busy_running'] = api(conn, 'DELETE', volume_path, (409,))
            with NATIVE['channel'](session, vm_pid) as (stream, boot):
                evidence['guest_busy'] = NATIVE['exchange'](stream, 25, {
                    'boot_id': boot, 'budget_ms': 1000, 'operation': {'action': 'remove', 'name': NAME},
                }, 15, 'in_use')
            api(conn, 'DELETE', holder + '?force=true', (204,))
            evidence['cancelled'] = MATCHED['native_terminal'](conn, holder_name, set(), code=137)

        run(['/bin/busybox', 'stat', '-c', '%u:%g:%a', target], stdout=b'65532:65532:700\n')
        run(['/bin/busybox', 'cat', witness], stdout=PAYLOAD)
        result = subprocess.run([*client, 'run', *MATCHED['FLAGS'], '--mount', readonly_mount, image,
                                 '/bin/sh', '-ec', f'printf changed >{witness}'],
                                env=env, capture_output=True, timeout=20)
        evidence['readonly_write'] = {'exit': result.returncode,
                                      'stderr': result.stderr.decode(errors='replace')}
        if result.returncode == 0 or b'Read-only file system' not in result.stderr:
            raise RuntimeError('read-only volume did not reject writes')
        run(['/bin/busybox', 'cat', witness], stdout=PAYLOAD)
        evidence['same_payload_after_readonly_write'] = True
        if phase == 'inspect':
            invoke(['volume', 'rm', NAME], stdout=(NAME + '\n').encode())
            evidence['removed'] = api(conn, 'GET', volume_path, (404,))
    finally:
        conn.close()
        (output / 'native-mounted-volume.json').write_text(json.dumps(evidence, indent=2) + '\n')
