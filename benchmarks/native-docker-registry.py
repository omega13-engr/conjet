"""Serve and verify the pinned registry fixtures for native Docker image ownership."""

import argparse
from collections import Counter
from contextlib import contextmanager
import gzip
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
from pathlib import Path
import runpy
import subprocess
import threading
from urllib.parse import quote


HERE = Path(__file__).resolve().parent
OCI = runpy.run_path(str(HERE / 'native-oci-two-layer.py'))
MATCHED = OCI['MATCHED']
TOOLS = MATCHED['TOOLS']
REPOSITORY = 'conjet-fixtures'
PINNED = HERE / 'scenarios/native-oci-registry-v1.json'


def generate(source, directory):
    multi = json.loads(OCI['PINNED'].read_text())
    directory.mkdir(mode=0o700)
    lower = source / 'blobs/sha256' / multi['layers'][0][7:]
    if OCI['digest'](lower.read_bytes()) != multi['layers'][0]:
        raise RuntimeError('base layer differs from the frozen fixture')
    small = OCI['layout'](directory / 'small', [gzip.decompress(lower.read_bytes())])
    if small != json.loads(PINNED.read_text())['small']:
        raise RuntimeError('small image differs from the frozen registry fixture')
    if small['layers'][0] != multi['layers'][0]:
        raise RuntimeError('small and multilayer registry fixture lost its shared layer')
    for manifest in (multi['manifest_digest'], multi['config_digest'], *multi['layers']):
        original = source / 'blobs/sha256' / manifest[7:]
        data = original.read_bytes()
        if OCI['digest'](data) != manifest:
            raise RuntimeError('multilayer blob differs from its pinned identity')
        (directory / 'small/blobs/sha256' / manifest[7:]).write_bytes(data)
    (directory / 'fixtures.json').write_text(json.dumps({'small': small, 'multi': multi}, indent=2) + '\n')


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def setup(self):
        self.request.settimeout(4)
        super().setup()

    def log_message(self, *_):
        pass

    def do_GET(self):
        data = self.server.registry.content.get(self.path)
        if data is None:
            self.send_error(404)
            return
        receipt = self.server.registry
        mode = receipt.mode if self.path.endswith(receipt.failure_blob) else None
        receipt.requests.append({'path': self.path, 'bytes': len(data), 'fault': mode})
        self.send_response(200)
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Connection', 'close')
        self.end_headers()
        if mode == 'hash':
            data = data[:-1] + bytes([data[-1] ^ 1])
        elif mode == 'interrupt':
            data = data[:len(data) // 2]
        self.wfile.write(data)


class Registry:
    def __init__(self, fixtures):
        self.identities = json.loads((fixtures / 'fixtures.json').read_text())
        self.failure_blob = self.identities['multi']['layers'][-1]
        self.mode = None
        self.requests = []
        self.content = {}
        for fixture in self.identities.values():
            for key, digests in (('manifests', [fixture['manifest_digest']]),
                                 ('blobs', [fixture['config_digest'], *fixture['layers']])):
                for digest in digests:
                    data = (fixtures / 'small/blobs/sha256' / digest[7:]).read_bytes()
                    if OCI['digest'](data) != digest:
                        raise RuntimeError('registry fixture content changed')
                    self.content[f'/v2/{REPOSITORY}/{key}/{digest}'] = data

    @contextmanager
    def serve(self):
        with HTTPServer(('127.0.0.1', 0), Handler) as server:
            server.registry = self
            self.authority = f'127.0.0.1:{server.server_port}'
            worker = threading.Thread(target=server.serve_forever, kwargs={'poll_interval': 0.1})
            worker.start()
            try:
                yield self
            finally:
                server.shutdown()
                worker.join(5)
                if worker.is_alive():
                    raise RuntimeError('task-owned fixture registry did not stop')

    def image(self, name):
        return f'{self.authority}/{REPOSITORY}@{self.identities[name]["manifest_digest"]}'


def collect(endpoint, peer, docker, env, evidence, registry, store):
    connection = TOOLS['UnixHTTP'](endpoint, peer)
    small, multi = (registry.image(name) for name in ('small', 'multi'))
    cases = {}

    def docker_call(*commands):
        return subprocess.run([*docker, *commands], env=env, capture_output=True, text=True, timeout=60)

    def check(label, *commands, exit_code=0, message=None):
        result = docker_call(*commands)
        cases[label] = {'argv': commands, 'code': result.returncode,
                        'stdout': result.stdout, 'stderr': result.stderr}
        if result.returncode != exit_code or (message and message not in result.stderr + result.stdout):
            raise RuntimeError(f'Docker registry canary {label} failed: {cases[label]}')
        return result.stdout

    def inventory():
        return sorted(path.name for path in (store / 'blobs/sha256').iterdir())

    def pkg(name):
        manifest = registry.identities[name]['manifest_digest']
        return store / 'images' / manifest[7:] / 'package.json'

    try:
        if TOOLS['api'](connection, 'GET', '/version', (200,))['Platform']['Name'] != 'Conjet Native OCI':
            raise RuntimeError('wrong endpoint for native registry suite')
        check('allowlist', 'pull', multi.replace(registry.authority, '127.0.0.1:1'), exit_code=1,
              message='allowlisted registry')
        check('immutable_only', 'pull', f'{registry.authority}/{REPOSITORY}:latest', exit_code=1,
              message='immutable SHA-256 digest')
        for fault, message in (('hash', 'digest mismatch'), ('interrupt', 'transfer was interrupted')):
            registry.mode = fault
            check(fault, 'pull', '--platform', 'linux/arm64', multi, exit_code=1, message=message)
            if inventory() or any((store / 'images').iterdir()):
                raise RuntimeError('failed pull left an image or a partial blob')
        registry.mode = None
        check('cold_pull', 'pull', '--platform', 'linux/arm64', multi)
        resolved = check('inspect', 'image', 'inspect', '--format', '{{.Id}}', multi).strip()
        if resolved != registry.identities['multi']['config_digest']:
            raise RuntimeError('Docker inspect returned a different image config')
        snapshot = pkg('multi').stat()
        requests = len(registry.requests)
        check('cached_pull', 'pull', '--platform', 'linux/arm64', multi)
        if len(registry.requests) != requests or pkg('multi').stat().st_ino != snapshot.st_ino:
            raise RuntimeError('cached pull repeated a transfer or extraction')
        check('small_pull', 'pull', '--platform', 'linux/arm64', small)
        lower = registry.identities['small']['layers'][0]
        hits = Counter(item['path'].rsplit('/', 1)[-1] for item in registry.requests[requests:])
        if hits[lower]:
            raise RuntimeError('shared layer was downloaded twice')
        OCI['collect'](endpoint, peer, docker, env, evidence, multi)
        tag = 'cj-native-registry:qualified'
        check('tag', 'image', 'tag', multi, tag)
        tagged = json.loads(check('tag_inspect', 'image', 'inspect', tag))[0]
        if tagged['Id'] != resolved or tag not in tagged['RepoTags'] or multi not in tagged['RepoDigests']:
            raise RuntimeError('tag did not resolve to the immutable source image')
        if check('tag_inventory', 'image', 'ls', '--quiet', '--no-trunc', tag).strip() != resolved:
            raise RuntimeError('exact tag inventory did not return the source image ID')
        check('tag_protects_manifest', 'image', 'rm', multi, exit_code=1, message='image has local tags')
        name = 'cj-pull-tag'
        MATCHED['invoke'](docker, env, ['run', *MATCHED['FLAGS'], '--name', name, tag, '/bin/true'])
        cases['tag_run'] = MATCHED['native_terminal'](connection, name, set())
        check('untag', 'image', 'rm', tag)
        check('untagged_inspect', 'image', 'inspect', tag, exit_code=1)
        if check('untagged_inventory', 'image', 'ls', '--quiet', tag):
            raise RuntimeError('untagged alias remained in the image inventory')
        name = 'cj-pull-use'
        check('in_use_create', 'create', *MATCHED['FLAGS'], '--name', name, multi, '/bin/busybox', 'sleep', '30')
        check('in_use_start', 'start', name)
        check('in_use_delete', 'image', 'rm', multi, exit_code=1, message='image is referenced')
        check('in_use_remove', 'rm', '--force', name)
        check('remove_multi', 'image', 'rm', multi)
        upper = registry.identities['multi']['layers'][-1]
        if lower[7:] not in inventory() or upper[7:] in inventory():
            raise RuntimeError('image removal miscounted shared and exclusive layers')
        match = TOOLS['api'](connection, 'GET',
                             MATCHED['PREFIX'] + '/images/' + quote(small, safe='') + '/json', (200,))
        if match['Id'] != registry.identities['small']['config_digest']:
            raise RuntimeError('removing one image affected its shared-layer sibling')
        MATCHED['invoke'](docker, env, ['run', *MATCHED['FLAGS'], '--name', 'cj-pull-small', small, '/bin/true'])
        cases['shared_layer_run'] = MATCHED['native_terminal'](connection, 'cj-pull-small', set())
        check('remove_small', 'image', 'rm', small)
        if inventory() or any((store / 'images').iterdir()):
            raise RuntimeError('image store did not release its final owned content')
    finally:
        connection.close()
        (evidence / 'registry-checks.json').write_text(json.dumps({
            'store': str(store), 'authority': registry.authority, 'identities': registry.identities,
            'cases': cases, 'requests': registry.requests,
        }, indent=2) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--layout', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    if not (args.layout.resolve(strict=True).is_relative_to(TOOLS['SCRATCH'])
            and args.output.parent.resolve(strict=True).is_relative_to(TOOLS['SCRATCH'])):
        parser.error('registry layout and output must reside on ExternalSSD')
    generate(args.layout, args.output)
