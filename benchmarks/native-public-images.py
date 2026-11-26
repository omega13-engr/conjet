"""Check the strict frozen Docker Hub source on the isolated native endpoint."""

import json
from pathlib import Path
import runpy
import subprocess
import time

HERE = Path(__file__).resolve().parent
MATCHED = runpy.run_path(str(HERE / 'native-docker-comparison.py'))
MANIFEST = json.loads((HERE / 'scenarios/docker-comparison-v1.json').read_text())
# Config descriptor in the verified frozen Registry image manifest.
REGISTRY_CONFIG = 'sha256:33eeff39e0aaabe61ca826fd7502396183462451be0783133e1a8fa944fc7350'
DISK_IMAGES = {
    'node': ('sha256:fd6e7c5e242aaf648004a761573a2b930792eb46b1be852862b595dfdaa11b36', '/usr/local/bin/node'),
    'golang': ('sha256:86d0141523af0456aa5567ae706da18c0040743a39ea7c41b90bfc40d000507c', '/usr/local/go/bin/go'),
    'rust': ('sha256:62b512f5e21696e50ac3cc0cb5ed5eaf38a79a54930924e19a52e374691339cf', '/usr/local/cargo/bin/rustc'),
}


def collect(endpoint, peer, docker, env, output, *, disk_store=None):
    cases = {}
    connection = MATCHED['TOOLS']['UnixHTTP'](endpoint, peer)

    def call(name, argv, code=0, timeout=45):
        start = time.monotonic()
        result = subprocess.run([*docker, *argv], env=env, capture_output=True, timeout=timeout)
        cases[name] = {'argv': list(argv), 'exit': result.returncode,
                       'elapsed_seconds': time.monotonic() - start,
                       'stdout': result.stdout.decode(errors='replace'),
                       'stderr': result.stderr.decode(errors='replace')}
        if result.returncode != code:
            raise RuntimeError(f'frozen public image check {name} failed: {result.stderr[:250]!r}')
        return cases[name]['stdout']

    def terminal(name):
        # Staging a large image can outlast the idle Docker HTTP connection.
        connection.close()
        return MATCHED['native_terminal'](connection, name, set())

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
        cases['native_cleanup'] = terminal(name)
        call('pinned_remove', ['image', 'rm', pin])

        redis = MANIFEST['images']['redis']['ref']
        call('redis_pull', ['pull', '--platform', 'linux/arm64', redis])
        name = 'cj-public-redis-home'
        mode = call('redis_home', ['run', *MATCHED['FLAGS'], '--name', name,
                                   '--entrypoint', '/bin/busybox', redis,
                                   'stat', '-c', '%a:%u:%g', '/home/redis'])
        if mode.strip() != '2755:999:1000':
            raise RuntimeError(f'the Redis home mode or mapped owner changed: {mode!r}')
        cases['redis_native_cleanup'] = terminal(name)
        call('redis_remove', ['image', 'rm', redis])

        if disk_store:
            for key, (config, executable) in DISK_IMAGES.items():
                ref = MANIFEST['images'][key]['ref']
                call(f'{key}_pull', ['pull', '--platform', 'linux/arm64', ref], timeout=180)
                metadata = json.loads(call(f'{key}_inspect', ['image', 'inspect', ref]))[0]
                if (metadata['Id'] != config or metadata['Architecture'] != 'arm64'
                        or ref not in metadata['RepoDigests']):
                    raise RuntimeError(f'the public {key} image differs from its frozen identity')
                package = disk_store / 'images' / ref.split('@sha256:', 1)[1] / 'package.cjoci'
                cases[f'{key}_package_bytes'] = package.stat().st_size
                call(f'{key}_cached_pull', ['pull', '--platform', 'linux/arm64', ref])
                name = f'cj-public-{key}-contents'
                args = ['stat', '-c', '%a:%u:%g', '/home/node'] if key == 'node' else ['test', '-x', executable]
                result = call(f'{key}_contents', ['run', *MATCHED['FLAGS'], '--name', name,
                                                     '--entrypoint', '/bin/busybox', ref, *args])
                if key == 'node' and result.strip() != '2755:1000:1000':
                    raise RuntimeError(f'the Node home mode or mapped owner changed: {result!r}')
                cases[f'{key}_native_cleanup'] = terminal(name)
                call(f'{key}_remove', ['image', 'rm', ref])
            remnants = [str(item.relative_to(disk_store))
                        for folder in ('images', 'blobs/sha256')
                        for item in (disk_store / folder).iterdir()]
            cases['host_store_remnants'] = remnants
            if remnants:
                raise RuntimeError('the private image store still holds retired entries')
    finally:
        connection.close()
        (output / 'public-image-checks.json').write_text(json.dumps(cases, indent=2) + '\n')
