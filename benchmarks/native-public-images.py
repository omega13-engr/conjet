"""Check the strict frozen Docker Hub source on the isolated native endpoint."""

import json
from pathlib import Path
import runpy
import subprocess

HERE = Path(__file__).resolve().parent
MATCHED = runpy.run_path(str(HERE / 'native-docker-comparison.py'))
MANIFEST = json.loads((HERE / 'scenarios/docker-comparison-v1.json').read_text())
# Config descriptor in the verified frozen Registry image manifest.
REGISTRY_CONFIG = 'sha256:33eeff39e0aaabe61ca826fd7502396183462451be0783133e1a8fa944fc7350'


def collect(endpoint, peer, docker, env, output):
    cases = {}
    connection = MATCHED['TOOLS']['UnixHTTP'](endpoint, peer)

    def call(name, argv, code=0):
        result = subprocess.run([*docker, *argv], env=env, capture_output=True, timeout=45)
        cases[name] = {'argv': list(argv), 'exit': result.returncode,
                       'stdout': result.stdout.decode(errors='replace'),
                       'stderr': result.stderr.decode(errors='replace')}
        if result.returncode != code:
            raise RuntimeError(f'frozen public image check {name} failed: {result.stderr[:250]!r}')
        return cases[name]['stdout']

    try:
        fixture = MANIFEST['images']['registry']
        pin = fixture['ref']
        other = pin[:-1] + ('0' if pin[-1] != '0' else '1')
        call('wrong_digest', ['pull', '--platform', 'linux/arm64', other], 1)
        if 'outside the frozen' not in cases['wrong_digest']['stderr']:
            raise RuntimeError('the frozen source did not reject an unrelated digest')
        call('wrong_platform', ['pull', '--platform', 'linux/amd64', pin], 1)
        call('pinned_pull', ['pull', '--platform', 'linux/arm64', pin])
        metadata = json.loads(call('pinned_inspect', ['image', 'inspect', pin]))[0]
        if (metadata['Id'] != REGISTRY_CONFIG or metadata['Architecture'] != 'arm64'
                or pin not in metadata['RepoDigests']):
            raise RuntimeError('the public image differs from its frozen identity')
        call('cached_pull', ['pull', '--platform', 'linux/arm64', pin])
        name = 'cj-public-registry'
        call('pinned_contents', ['run', *MATCHED['FLAGS'], '--name', name,
                                 '--entrypoint', '/bin/busybox', pin, 'test', '-x', '/bin/registry'])
        cases['native_cleanup'] = MATCHED['native_terminal'](connection, name, set())
        call('pinned_remove', ['image', 'rm', pin])

        redis = MANIFEST['images']['redis']['ref']
        call('redis_pull', ['pull', '--platform', 'linux/arm64', redis])
        name = 'cj-public-redis-home'
        mode = call('redis_home', ['run', *MATCHED['FLAGS'], '--name', name,
                                   '--entrypoint', '/bin/busybox', redis,
                                   'stat', '-c', '%a:%u:%g', '/home/redis'])
        if mode.strip() != '2755:999:1000':
            raise RuntimeError(f'the Redis home mode or mapped owner changed: {mode!r}')
        cases['redis_native_cleanup'] = MATCHED['native_terminal'](connection, name, set())
        call('redis_remove', ['image', 'rm', redis])
    finally:
        connection.close()
        (output / 'public-image-checks.json').write_text(json.dumps(cases, indent=2) + '\n')
