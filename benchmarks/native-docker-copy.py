"""Exercise a bounded Docker file archive in a live, owned guest."""

from contextlib import closing
import hashlib
import json
from pathlib import Path
import runpy
import subprocess
import time


HERE = Path(__file__).resolve().parent
MATCHED = runpy.run_path(str(HERE / 'native-docker-comparison.py'))
GUEST = runpy.run_path(str(HERE / 'native-oci-live-install.py'))


def collect(endpoint, peer, docker, env, output, session, vm_pid):
    cases = {}
    name = 'cj-copy-archive'
    archive = '/tmp/control'
    image = MATCHED['IMAGE']['ref']
    api = MATCHED['TOOLS']['api']

    def call(label, args, expected=0):
        result = subprocess.run([*docker, *args], env=env, capture_output=True, timeout=30)
        cases[label] = {'argv': list(map(str, args)), 'exit': result.returncode,
                        'stdout': result.stdout.decode(errors='replace'),
                        'stderr': result.stderr.decode(errors='replace')}
        if result.returncode != expected:
            raise RuntimeError(f'copy check {label} failed: {cases[label]}')

    try:
        call('start', ['run', '-d', '--network', 'none', '--name', name, '--pull', 'never',
                       image, 'sleep', '1800'])
        try:
            with GUEST['channel'](session, vm_pid) as (guest, boot):
                deadline = time.monotonic() + 3
                while time.monotonic() < deadline:
                    scoped = GUEST['inspect'](guest)['active_workloads']
                    if len(scoped) == 1 and scoped[0]['phase'] == 'running':
                        break
                    time.sleep(0.025)
                else:
                    raise RuntimeError('copy fixture did not enter a live guest generation')
                request = {'boot_id': boot, 'budget_ms': 1000, 'handle': scoped[0]['handle']}
                first = None
                for size in (4096, 8 * 1024 * 1024):
                    call(f'prepare_{size}', ['exec', name, 'dd', 'if=/dev/zero',
                                             f'of={archive}', 'bs=1024', f'count={size // 1024}'])
                    current = GUEST['exchange'](guest, 29, {**request, 'operation': {
                        'action': 'stat', 'path': archive}}, 29)
                    if first:
                        cases['stale_file_denied'] = GUEST['exchange'](guest, 29, {**request, 'operation': {
                            'action': 'read', 'path': archive, 'offset': 0, 'identity': first}}, 15, 'archive_rejected')
                    first = current['identity']
                    target = output / f'copy-{size}.bin'
                    try:
                        call(f'copy_out_{size}', ['cp', f'{name}:{archive}', target])
                        with target.open('rb') as stream:
                            digest = hashlib.file_digest(stream, 'sha256').hexdigest()
                        if target.stat().st_size != size or digest != hashlib.sha256(bytes(size)).hexdigest():
                            raise RuntimeError('Docker copy export differed from the known guest bytes')
                        cases[f'copy_out_{size}']['sha256'] = digest
                    finally:
                        target.unlink(missing_ok=True)
                with closing(MATCHED['TOOLS']['UnixHTTP'](endpoint, peer)) as connection:
                    route = f'/v1.44/containers/{name}/archive?path='
                    cases['symlink_denied'] = api(connection, 'GET', route + '/bin/sh', (400,))
                    cases['parent_path_denied'] = api(connection, 'GET', route + '/tmp/../etc/passwd', (400,))
                    cases['missing_denied'] = api(connection, 'GET', route + '/tmp/cj-does-not-exist', (404,))
        finally:
            call('remove', ['rm', '-f', name])
        with closing(MATCHED['TOOLS']['UnixHTTP'](endpoint, peer)) as connection:
            cases['cleanup'] = MATCHED['native_terminal'](connection, name, set(), code=137)
    finally:
        (output / 'copy-checks.json').write_text(json.dumps(cases, indent=2) + '\n')
