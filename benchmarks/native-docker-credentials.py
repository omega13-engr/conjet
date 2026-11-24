"""Verify native OCI credentials through the pinned CLI and Docker API."""

import json
from pathlib import Path
import re
import runpy
import subprocess
from urllib.parse import quote
import uuid

MATCHED = runpy.run_path(str(Path(__file__).with_name('native-docker-comparison.py')))
TOOLS = MATCHED['TOOLS']
FLAGS = ['--network', 'none', '--memory', '16m', '--pids-limit', '4', '--cpus', '0.5']
SCENARIOS = Path(__file__).with_name('scenarios') / 'docker-comparison-v1.json'
DEFAULT_PROBE = ('printf "%s:%s\\n" "$(id -u)" "$(id -g)"; '
                 'read memory </sys/fs/cgroup/memory.max; '
                 'read pids </sys/fs/cgroup/pids.max; '
                 'read quota period </sys/fs/cgroup/cpu.max; '
                 'printf "%s:%s:%s:%s\\n" "$memory" "$pids" "$quota" "$period"')
DEFAULT_RESULT = '0:0\n16777216:4:50000:100000\n'


def collect(endpoint, peer, docker, env, output, *, all_images=False):
    report = {'passed': False, 'cases': {}, 'image_defaults': {}}
    cases = report['cases']
    image = MATCHED['IMAGE']['ref']
    token = uuid.uuid4().hex[:12]
    connection = TOOLS['UnixHTTP'](endpoint, peer)

    def call(case, argv, expected):
        result = subprocess.run([*docker, *argv], env=env, capture_output=True, timeout=30)
        cases[case] = {'argv': argv, 'exit': result.returncode,
                       'stdout': result.stdout.decode(), 'stderr': result.stderr.decode()}
        if (result.returncode != 0 or result.stderr
                or (result.stdout != expected if expected is not None
                    else not re.fullmatch(rb'[0-9a-f]{64}\n', result.stdout))):
            raise RuntimeError(f'native credential case {case} failed')
        return result.stdout

    handles = set()
    try:
        for case, user, expected in (('default', [], (0, 0)),
                                     ('numeric', ['--user', '1234:4321'], (1234, 4321)),
                                     ('named', ['--user', 'nobody'], (65534, 65534)),
                                     ('named-group', ['--user', 'root:nogroup'], (0, 65533)),
                                     ('numeric-primary-group', ['--user', '65534'], (65534, 65534)),
                                     ('missing-numeric', ['--user', '61234'], (61234, 0)),
                                     ('fixture', ['--user', '65532:65532'], (65532, 65532))):
            for flag, identity in zip(('u', 'g'), expected):
                key = f'{case}-{flag}'
                name = f'cj-id-{token}-{key}'
                call(key, ['run', '--rm', '--pull', 'never', '--name', name, *FLAGS, *user,
                           image, '/bin/busybox', 'id', '-' + flag], f'{identity}\n'.encode())
                cases[key]['guest'] = MATCHED['native_terminal'](connection, name, handles)
        name = f'cj-id-{token}-matched-cli'
        MATCHED['invoke'](docker, env, ['run', *MATCHED['FLAGS'], '--name', name, image, '/bin/sh',
                                      '-c', 'printf matched-out; printf matched-err >&2; exit 23'],
                          code=23, stdout=b'matched-out', stderr=b'matched-err')
        cases['matched_cli'] = MATCHED['native_terminal'](connection, name, handles, 23)
        name = f'cj-id-{token}-matched-api'
        MATCHED['lifecycle'](connection, name, {}, argv=('/bin/true',))
        cases['matched_api'] = MATCHED['native_terminal'](connection, name, handles)
        name = f'cj-id-{token}-exec'
        call('exec_parent', ['run', '--detach', '--pull', 'never', '--name', name, *FLAGS,
                             image, '/bin/busybox', 'sleep', '30'], None)
        try:
            for flag in ('u', 'g'):
                call('exec_inherited_' + flag, ['exec', name, '/bin/busybox', 'id', '-' + flag], b'0\n')
        finally:
            call('exec_cleanup', ['rm', '--force', name], (name + '\n').encode())
        name = f'cj-id-{token}-exec-account'
        call('exec_named_parent', ['run', '--detach', '--pull', 'never', '--name', name, *FLAGS,
                                   '--user', 'nobody', image, '/bin/busybox', 'sleep', '30'], None)
        try:
            for flag in ('u', 'g'):
                call('exec_named_inherited_' + flag,
                     ['exec', name, '/bin/busybox', 'id', '-' + flag], b'65534\n')
        finally:
            call('exec_named_cleanup', ['rm', '--force', name], (name + '\n').encode())
        cases['exec_named_witness'] = MATCHED['native_terminal'](connection, name, handles, 137)
        for case, user, extra in (('unmapped_uid', '65536:0', {}),
                                  ('unmapped_gid', '0:65536', {}),
                                  ('unknown_user', 'cj-missing-account', {}),
                                  ('unknown_group', 'root:cj-missing-group', {}),
                                  ('privileged', '0:0', {'Privileged': True}),
                                  ('added_capability', '0:0', {'CapAdd': ['SYS_ADMIN']})):
            body = {'Image': image, 'User': user, 'Cmd': ['/bin/true'],
                    'HostConfig': {**MATCHED['HOST_CONFIG'], **extra}}
            name = f'cj-id-{token}-{case}'
            rejected = TOOLS['api'](connection, 'POST',
                                    f'{MATCHED["PREFIX"]}/containers/create?name={name}',
                                    (400,), body)
            cases[case] = {'expected_status': 400, 'response': rejected}
            TOOLS['api'](connection, 'GET', f'{MATCHED["PREFIX"]}/containers/{name}/json', (404,))
            cases[case]['absent_after_rejection'] = True
        report['passed'] = True
        if all_images:
            for case, descriptor in json.loads(SCENARIOS.read_bytes())['images'].items():
                name = f'cj-id-{token}-default-{case}'
                argv = ['run', '--rm', '--pull', 'missing', '--name', name, *FLAGS,
                        '--entrypoint', '/bin/sh', descriptor['ref'], '-ec', DEFAULT_PROBE]
                row = {'argv': argv}
                report['image_defaults'][case] = row
                # The image pull can outlive the idle Docker API connection.
                # Open a fresh peer-verified connection for the terminal witness.
                connection.close()
                try:
                    result = subprocess.run([*docker, *argv], env=env, capture_output=True,
                                            text=True, timeout=300)
                    row.update(exit=result.returncode, stdout=result.stdout, stderr=result.stderr)
                    if result.returncode == 0 and result.stdout == DEFAULT_RESULT:
                        row['guest'] = MATCHED['native_terminal'](connection, name, handles)
                    else:
                        row['error'] = 'default image credentials or cgroup witness failed'
                except (OSError, RuntimeError, subprocess.SubprocessError) as error:
                    row['error'] = str(error)
                    connection.close()
                finally:
                    TOOLS['api'](connection, 'DELETE', f'{MATCHED["PREFIX"]}/containers/{name}?force=true',
                                 (204, 404))
                    if case != 'alpine':
                        ref = quote(descriptor['ref'], safe='')
                        path = f'{MATCHED["PREFIX"]}/images/{ref}'
                        TOOLS['api'](connection, 'DELETE', path, (200, 404))
                        TOOLS['api'](connection, 'GET', path + '/json', (404,))
                        row['image_released'] = True
    finally:
        connection.close()
        (output / 'native-credentials.json').write_text(json.dumps(report, indent=2) + '\n')
