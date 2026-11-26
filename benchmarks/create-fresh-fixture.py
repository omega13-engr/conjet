#!/usr/bin/env python3
"""Package one static ARM64 Linux executable for the three runtime adapters."""

import argparse
import hashlib
import io
import json
import tarfile
from pathlib import Path

SCRATCH = Path('/Volumes/ExternalSSD/dev_workspace/tmp')


def encode(document):
    return json.dumps(document, separators=(',', ':'), sort_keys=True).encode()


def digest(data):
    return hashlib.sha256(data).hexdigest()


def append(archive, name, data=None, mode=0o555, owner=0):
    member = tarfile.TarInfo(name)
    member.mode = mode
    member.uid = member.gid = owner
    if data is None:
        member.type = tarfile.DIRTYPE
        archive.addfile(member)
    else:
        member.size = len(data)
        archive.addfile(member, io.BytesIO(data))


def create(executable, output):
    workload = executable.read_bytes()
    if (len(workload) > 4 * 1024 * 1024 or workload[:6] != b'\x7fELF\x02\x01'
            or workload[16:20] != b'\x02\x00\xb7\x00'):
        raise ValueError('expected a bounded ARM64 ELF64 executable')
    layer = io.BytesIO()
    with tarfile.open(fileobj=layer, mode='w', format=tarfile.USTAR_FORMAT) as tar:
        append(tar, 'bin')
        append(tar, 'bin/probe', workload)
        append(tar, 'work', mode=0o755, owner=65532)
        append(tar, 'work/immutable', b'verified fixture\n', 0o644)
    layer = layer.getvalue()
    config = encode({
        'architecture': 'arm64', 'os': 'linux',
        'config': {'Cmd': ['/bin/probe'], 'WorkingDir': '/work', 'User': '65532:65532', 'Env': []},
        'rootfs': {'type': 'layers', 'diff_ids': ['sha256:' + digest(layer)]},
    })
    config_name = digest(config) + '.json'
    tag = 'conjet-speedup-fixture:' + digest(config)[:16]
    manifest = encode({
        'schemaVersion': 2, 'mediaType': 'application/vnd.oci.image.manifest.v1+json',
        'config': {'mediaType': 'application/vnd.oci.image.config.v1+json',
                   'digest': 'sha256:' + digest(config), 'size': len(config)},
        'layers': [{'mediaType': 'application/vnd.oci.image.layer.v1.tar',
                    'digest': 'sha256:' + digest(layer), 'size': len(layer)}],
        'annotations': {'dev.conjet.fixture.workload.sha256': digest(workload)},
    })
    output.mkdir(mode=0o700)
    archive = output / 'image.tar'
    with tarfile.open(archive, mode='w', format=tarfile.USTAR_FORMAT) as tar:
        append(tar, config_name, config)
        append(tar, 'layer.tar', layer)
        append(tar, 'manifest.json', encode([{
            'Config': config_name, 'RepoTags': [tag], 'Layers': ['layer.tar'],
        }]))
    (output / 'oci-manifest.json').write_bytes(manifest)
    (output / 'workload').write_bytes(workload)
    scenario = {
        'api_version': '1.44', 'image': tag, 'platform': 'linux/arm64', 'command': ['/bin/probe'],
        'workload_sha256': digest(workload), 'archive_sha256': digest(archive.read_bytes()),
        'config_digest': 'sha256:' + digest(config), 'manifest_digest': 'sha256:' + digest(manifest),
        'container_limits': {'memory_bytes': 16 * 1024 * 1024, 'pids': 4, 'cpu_millicores': 500},
        'networks': ['none', 'bridge'], 'lanes': ['api', 'cli'], 'warmups_per_lane': 10,
    }
    (output / 'scenario.json').write_bytes(encode(scenario) + b'\n')
    print(json.dumps(scenario, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('executable', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    if args.executable.is_symlink() or not args.executable.is_file() or not args.executable.resolve().is_relative_to(SCRATCH):
        parser.error('executable must be a regular file under designated ExternalSSD scratch')
    if args.output.exists() or not args.output.is_absolute() or not args.output.parent.resolve().is_relative_to(SCRATCH):
        parser.error('output must be a new directory under designated ExternalSSD scratch')
    create(args.executable, args.output)


if __name__ == '__main__':
    main()
