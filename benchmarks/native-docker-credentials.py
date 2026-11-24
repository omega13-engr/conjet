"""Verify native OCI credentials through the pinned CLI and Docker API."""

import json
from pathlib import Path
import re
import runpy
import subprocess
import uuid

MATCHED = runpy.run_path(str(Path(__file__).with_name('native-docker-comparison.py')))
TOOLS = MATCHED['TOOLS']
FLAGS = ['--network', 'none', '--memory', '16m', '--pids-limit', '4', '--cpus', '0.5']


def collect(endpoint, peer, docker, env, output):
    report = {'passed': False, 'cases': {}}
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
            rejected = TOOLS['api'](connection, 'POST',
                                    f'{MATCHED["PREFIX"]}/containers/create?name=cj-id-{token}-{case}',
                                    (400,), body)
            cases[case] = {'expected_status': 400, 'response': rejected}
        report['passed'] = True
    finally:
        connection.close()
        (output / 'native-credentials.json').write_text(json.dumps(report, indent=2) + '\n')
