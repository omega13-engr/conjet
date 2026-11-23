#!/usr/bin/env python3
"""Fetch the frozen ARM64 build bases into private, digest-verified OCI layouts."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import signal
import tempfile
from urllib.parse import urlencode, urlsplit
from urllib.request import HTTPRedirectHandler, ProxyHandler, Request, build_opener

SCRATCH = Path('/Volumes/ExternalSSD/dev_workspace/tmp')
MANIFEST = Path(__file__).resolve().parent / 'scenarios/docker-comparison-v1.json'
BASES = ('alpine', 'rust', 'golang', 'node')
IMAGE = 'application/vnd.oci.image.manifest.v1+json'
DOCKER_IMAGE = 'application/vnd.docker.distribution.manifest.v2+json'


class RegistryRedirect(HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, msg, headers, newurl):
        target = urlsplit(newurl)
        if target.scheme != 'https' or target.username is not None:
            raise ValueError('registry download redirected outside HTTPS')
        redirect = super().redirect_request(request, fp, code, msg, headers, newurl)
        if redirect is not None and target.netloc != urlsplit(request.full_url).netloc:
            redirect.remove_header('Authorization')
        return redirect


def download(reader, url, destination, digest, limit, headers=None):
    if not re.fullmatch(r'sha256:[0-9a-f]{64}', digest):
        raise ValueError('invalid registry digest')
    actual = hashlib.sha256()
    size = 0
    with reader.open(Request(url, headers=headers or {}), timeout=120) as response, destination.open('xb') as out:
        while block := response.read(1024 * 1024):
            size += len(block)
            if size > limit:
                raise ValueError('registry data exceeded the allowed size')
            actual.update(block)
            out.write(block)
    if f'sha256:{actual.hexdigest()}' != digest:
        raise ValueError('registry data did not match the pinned digest')
    return size


def stage_base(reader, destination, entry):
    match = re.fullmatch(r'docker\.io/([a-z0-9/-]+)@(sha256:[0-9a-f]{64})', entry['ref'])
    if not match:
        raise ValueError('build base must be an immutable Docker Hub reference')
    name, digest = match.groups()
    scope = urlencode({'service': 'registry.docker.io', 'scope': f'repository:{name}:pull'})
    with reader.open('https://auth.docker.io/token?' + scope, timeout=30) as response:
        token = json.loads(response.read(65536))['token']
    headers = {'Authorization': 'Bearer ' + token}
    registry = f'https://registry-1.docker.io/v2/{name}'
    blobs = destination / 'blobs/sha256'
    blobs.mkdir(parents=True)
    manifest_path = blobs / digest[7:]
    manifest_size = download(reader, f'{registry}/manifests/{digest}', manifest_path, digest, 65536,
                             {**headers, 'Accept': f'{IMAGE}, {DOCKER_IMAGE}'})
    manifest = json.loads(manifest_path.read_bytes())
    if manifest['mediaType'] not in (IMAGE, DOCKER_IMAGE) or manifest['schemaVersion'] != 2:
        raise ValueError('expected a pinned platform image manifest')
    descriptors = [manifest['config'], *manifest['layers']]
    for descriptor in descriptors:
        blob = descriptor['digest']
        if not re.fullmatch(r'sha256:[0-9a-f]{64}', blob) or not 0 <= descriptor['size'] <= 2**30:
            raise ValueError('invalid build base descriptor')
        path = blobs / blob[7:]
        if not path.exists():
            size = download(reader, f'{registry}/blobs/{blob}', path, blob, descriptor['size'], headers)
            if size != descriptor['size']:
                raise ValueError('build base blob size does not match its descriptor')
    config = json.loads((blobs / manifest['config']['digest'][7:]).read_bytes())
    if (config['os'], config['architecture']) != ('linux', 'arm64'):
        raise ValueError('build base is not Linux ARM64')
    if entry.get('config_digest', manifest['config']['digest']) != manifest['config']['digest']:
        raise ValueError('build base config does not match its frozen pin')
    (destination / 'oci-layout').write_text('{"imageLayoutVersion":"1.0.0"}\n')
    (destination / 'index.json').write_text(json.dumps({'schemaVersion': 2, 'manifests': [{
        'mediaType': manifest['mediaType'], 'digest': digest, 'size': manifest_size,
        'platform': {'os': 'linux', 'architecture': 'arm64'},
    }]}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    parent = args.output.parent.resolve(strict=True)
    if not parent.is_relative_to(SCRATCH) or args.output.exists() or args.output.is_symlink():
        parser.error('output must be a new ExternalSSD directory')
    manifest = json.loads(MANIFEST.read_bytes())
    reader = build_opener(ProxyHandler({}), RegistryRedirect())
    signal.signal(signal.SIGTERM, lambda *_: signal.raise_signal(signal.SIGINT))
    work = Path(tempfile.mkdtemp(prefix='oci-build-bases-', dir=parent))
    try:
        for base in BASES:
            stage_base(reader, work / base, manifest['images'][base])
            print(f'Verified pinned base: {base}', flush=True)
        work.rename(args.output)
    finally:
        if work.exists():
            shutil.rmtree(work)


if __name__ == '__main__':
    main()
