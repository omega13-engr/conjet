"""Check live stdout and stderr through the real Docker CLI."""

import json
import os
from pathlib import Path
import runpy
import select
import subprocess
import time


HERE = Path(__file__).resolve().parent
MATCHED = runpy.run_path(str(HERE / 'native-docker-comparison.py'))
CONCURRENCY = runpy.run_path(str(HERE / 'native-docker-concurrency.py'))
COMMAND = ['/bin/sh', '-c',
           'trap "printf late-out; printf late-err >&2; exit 23" TERM; '
           'printf early-out; printf early-err >&2; while :; do :; done']


def first_output(child, seconds=2):
    streams = [child.stdout, child.stderr]
    output = [bytearray(), bytearray()]
    expected = [b'early-out', b'early-err']
    deadline = time.monotonic() + seconds
    while output != expected:
        active = [stream for index, stream in enumerate(streams) if output[index] != expected[index]]
        ready, _, _ = select.select(active, [], [], max(0, deadline - time.monotonic()))
        if not ready:
            raise RuntimeError(f'live stream did not arrive before the running fixture exited: {output}')
        for stream in ready:
            index = streams.index(stream)
            chunk = os.read(stream.fileno(), len(expected[index]) - len(output[index]))
            output[index].extend(chunk)
            if not chunk or not expected[index].startswith(output[index]):
                raise RuntimeError(f'live output bytes changed: {output}')
    return [bytes(stream) for stream in output]


def collect(endpoint, peer, docker, env, output):
    tools = MATCHED['TOOLS']
    connection = tools['UnixHTTP'](endpoint, peer)
    image = MATCHED['IMAGE']['ref']
    cases = {}
    failed = []

    def run(label, args, code, name):
        child = subprocess.Popen([*docker, *args], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            start = time.monotonic_ns()
            early = first_output(child)
            first = time.monotonic_ns()
            state = tools['api'](connection, 'GET', f'/v1.44/containers/{name}/json', (200,))
            if not state['State']['Running'] or child.poll() is not None:
                raise RuntimeError(f'{label} only released bytes after terminal cleanup')
            tools['api'](connection, 'POST', f'/v1.44/containers/{name}/stop?t=2', (204,))
            stdout, stderr = child.communicate(timeout=8)
            if (child.returncode, stdout, stderr) != (code, b'late-out', b'late-err'):
                raise RuntimeError(f'{label} final output differs: {child.returncode}, {stdout!r}, {stderr!r}')
            cases[label] = {'early': [value.decode() for value in early],
                            'first_bytes_elapsed_ns': first - start, 'running_at_first_read': True,
                            'remaining': [stdout.decode(), stderr.decode()], 'client_exit': code}
        finally:
            CONCURRENCY['stop'](child, name, failed)

    try:
        if tools['api'](connection, 'GET', '/version', (200,))['Platform']['Name'] != 'Conjet Native OCI':
            raise RuntimeError('live-output check found the wrong Docker endpoint')
        name = 'cj-live-attach'
        run('attach', ['run', *MATCHED['FLAGS'], '--name', name, image, *COMMAND], 23, name)
        cases['attach_guest'] = MATCHED['native_terminal'](connection, name, set(), 23)
        name = 'cj-live-logs'
        case = subprocess.run([*docker, 'create', *MATCHED['FLAGS'][1:], '--name', name, image, *COMMAND],
                              env=env, capture_output=True, timeout=5, check=True)
        container = case.stdout.strip()
        MATCHED['invoke'](docker, env, ['start', name], stdout=name.encode() + b'\n')
        run('follow', ['logs', '--follow', name], 0, name)
        MATCHED['invoke'](docker, env, ['logs', name], stdout=b'early-outlate-out', stderr=b'early-errlate-err')
        MATCHED['invoke'](docker, env, ['wait', name], stdout=b'23\n')
        MATCHED['invoke'](docker, env, ['rm', name], stdout=name.encode() + b'\n')
        cases['logs_guest'] = MATCHED['native_terminal'](connection, name, set(), 23)
        cases['retained_container_id'] = container.decode()
        name = 'cj-live-log-overflow'
        subprocess.run([*docker, 'create', *MATCHED['FLAGS'][1:], '--name', name, image,
                        '/bin/sh', '-c',
                        'n=0; while [ "$n" -lt 65 ]; do printf "%01024d" 0; n=$((n+1)); done'],
                       env=env, capture_output=True, timeout=5, check=True)
        MATCHED['invoke'](docker, env, ['start', name], stdout=name.encode() + b'\n')
        overflow = tools['api'](connection, 'POST', f'/v1.44/containers/{name}/wait', (200,))
        if overflow['StatusCode'] != 125 or not overflow['Error']:
            raise RuntimeError(f'overflow did not produce explicit wait failure: {overflow}')
        result = subprocess.run([*docker, 'logs', name], env=env, capture_output=True, timeout=5)
        if (result.returncode != 1 or b'OCI output exceeds the Docker adapter limit' not in result.stderr
                or result.stdout != b'0' * 65536):
            raise RuntimeError(f'overflow logs did not report truncation: {result.returncode} {result.stderr!r}')
        cases['log_overflow'] = {'returned_bytes': len(result.stdout), 'code': result.returncode,
                                 'stderr': result.stderr.decode(), 'wait': overflow}
        MATCHED['invoke'](docker, env, ['rm', name], stdout=name.encode() + b'\n')
        cases['overflow_guest'] = MATCHED['native_terminal'](connection, name, set())
    finally:
        connection.close()
        (output / 'docker-live-output.json').write_text(json.dumps({
            'cases': cases, 'unfinished_clients': failed,
        }, indent=2) + '\n')
