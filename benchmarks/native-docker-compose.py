"""Exercise a pinned Compose client against only the isolated native endpoint."""

import hashlib
import json
from pathlib import Path
import runpy
import socket
import subprocess


HERE = Path(__file__).resolve().parent
SCENARIO = HERE / 'scenarios/native-compose-v1.yaml'
MATCHED = runpy.run_path(str(HERE / 'native-docker-comparison.py'))


def collect(endpoint, owner_pid, output, docker, env, compose_cli):
    stage = Path(env['HOME'])
    plugin_dir = Path(env['DOCKER_CONFIG']) / 'cli-plugins'
    plugin_dir.mkdir(mode=0o700)
    (plugin_dir / 'docker-compose').symlink_to(compose_cli)
    compose = ['compose', '--project-directory', stage, '--project-name', 'cj-native-compose',
               '--file', SCENARIO, '--ansi', 'never', '--progress', 'plain', '--parallel', '1']
    with compose_cli.open('rb') as source:
        evidence = {'compose_sha256': hashlib.file_digest(source, 'sha256').hexdigest(),
                    'fixture_sha256': hashlib.sha256(SCENARIO.read_bytes()).hexdigest(), 'calls': []}

    def call(argv, *, checked=True, timeout=25):
        completed = subprocess.run([*docker, *argv], env=env, capture_output=True,
                                   text=True, timeout=timeout)
        evidence['calls'].append({'argv': list(map(str, argv)), 'exit': completed.returncode,
                                  'stdout': completed.stdout, 'stderr': completed.stderr})
        if checked and completed.returncode:
            raise RuntimeError(f'Compose fixture failed at {argv[-1]}: {completed.stderr.strip()}')
        return completed.stdout

    def run(*args, **kwargs):
        return call([*compose, *args], **kwargs)

    def assert_empty(conn, path):
        result = MATCHED['TOOLS']['api'](conn, 'GET', MATCHED['PREFIX'] + path, (200,))
        if result:
            raise RuntimeError(f'Compose cleanup left objects at {path}')

    def service_response(port):
        with socket.create_connection(('127.0.0.1', port), timeout=3) as client:
            client.sendall(b'GET /proof HTTP/1.1\r\nHost: local\r\nConnection: close\r\n\r\n')
            client.shutdown(socket.SHUT_WR)
            with client.makefile('rb') as stream:
                reply = stream.read(512)
        if reply != (b'HTTP/1.1 200 OK\r\nContent-Length: 13\r\nConnection: close\r\n\r\n'
                     b'compose-proof'):
            raise RuntimeError(f'Compose loopback response was incorrect: {reply!r}')
        return reply.decode()

    conn = MATCHED['TOOLS']['UnixHTTP'](endpoint, owner_pid)
    try:
        version = call(['compose', 'version', '--short']).strip()
        if version.removeprefix('v') != '5.8.0':
            raise RuntimeError(f'Compose fixture requires 5.8.0, found {version}')
        run('config', '--quiet')
        call(['volume', 'create', 'cj-compose-data'])
        call(['network', 'create', '--internal', 'cj-compose-private'])
        run('up', '--wait', '--wait-timeout', '15', '--pull', 'never')
        dns = run('exec', '-T', 'reader', '/bin/busybox', 'nslookup', 'writer')
        if 'writer' not in dns or '198.18.0.' not in dns:
            raise RuntimeError(f'Compose reader did not resolve writer: {dns!r}')
        logs = run('logs', '--no-color')
        if 'writer-ready' not in logs or 'reader-ready' not in logs:
            raise RuntimeError('Compose logs omitted a service marker')
        mapping = run('port', 'writer', '8080').strip()
        if not mapping.startswith('127.0.0.1:'):
            raise RuntimeError(f'Compose published beyond loopback: {mapping!r}')
        port = int(mapping.rsplit(':', 1)[1])
        evidence['published_response'] = service_response(port)
        run('restart', '--timeout', '2', 'writer')
        if run('exec', '-T', 'writer', '/bin/busybox', 'cat', '/data/witness') != 'compose-proof':
            raise RuntimeError('Compose restart lost named volume data')
        run('down', '--timeout', '2')
        assert_empty(conn, '/containers/json?all=1')
        call(['network', 'rm', 'cj-compose-private'])
        call(['volume', 'rm', 'cj-compose-data'])
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
            probe.settimeout(1)
            if probe.connect_ex(('127.0.0.1', port)) == 0:
                raise RuntimeError('Compose cleanup left a published port')
        evidence['passed'] = True
    finally:
        conn.close()
        (output / 'native-compose.json').write_text(json.dumps(evidence, indent=2) + '\n')
