#!/usr/bin/env python3
"""Verify a bounded, single-layer Docker save archive without extracting its filesystem."""

import argparse
import gzip
import hashlib
import io
import json
import re
import tarfile
from pathlib import Path, PurePosixPath

SCRATCH = Path('/Volumes/ExternalSSD/dev_workspace/tmp')
MAX_ARCHIVE = 64 * 1024 * 1024
MAX_CONFIG = 64 * 1024
MAX_ENTRIES = 4096
SHA256 = re.compile(r'sha256:[0-9a-f]{64}')


def image_digest(body):
    return 'sha256:' + hashlib.sha256(body).hexdigest()


def member_name(name):
    path = PurePosixPath(name)
    if (path.is_absolute() or '..' in path.parts or '\x00' in name
            or len(name.encode()) > 1024):
        raise ValueError('unsafe image archive member path')
    return str(path)


def index(archive):
    entries = {}
    for item in archive:
        name = member_name(item.name)
        if name in entries or len(entries) >= MAX_ENTRIES:
            raise ValueError('duplicate or too many image archive entries')
        entries[name] = item
    return entries


def read_regular(archive, entries, key, bound):
    item = entries.get(member_name(key))
    if item is None or not item.isfile() or item.size > bound:
        raise ValueError('expected a bounded regular image archive member')
    with archive.extractfile(item) as stream:
        return stream.read(bound + 1)


def verify_rootfs(body):
    with tarfile.open(fileobj=io.BytesIO(body), mode='r:') as archive:
        entries = index(archive)
        for name, item in entries.items():
            if name == '.' and item.isdir():
                continue
            if name.split('/')[-1].startswith('.wh.') or item.mode & 0o6000:
                raise ValueError('whiteouts and set-ID entries are outside the staging subset')
            if not (item.isfile() or item.isdir() or item.issym() or item.islnk()):
                raise ValueError('unsupported rootfs entry type')
            for parent in PurePosixPath(name).parents:
                ancestor = entries.get(str(parent))
                if ancestor is not None and not ancestor.isdir():
                    raise ValueError('rootfs member descends through a non-directory')
            if item.islnk():
                target = entries.get(member_name(item.linkname))
                if target is None or not target.isfile():
                    raise ValueError('rootfs hard link must reference a regular file')
            if item.issym():
                # Absolute symlinks remain guest-root relative. Nothing here
                # resolves them on the host or creates host filesystem entries.
                link = PurePosixPath(item.linkname)
                depth = 0 if link.is_absolute() else len(PurePosixPath(name).parent.parts)
                for part in link.parts:
                    if part == link.anchor:
                        continue
                    depth += -1 if part == '..' else 1
                    if depth < 0:
                        raise ValueError('rootfs symlink target escapes the guest root')
        return len(entries)


def process_config(config):
    effective = config.get('config')
    if not isinstance(effective, dict):
        raise ValueError('missing OCI image process metadata')
    process = {key: effective.get(key) or [] for key in ('Entrypoint', 'Cmd', 'Env')}
    args = []
    for key, values in process.items():
        if not isinstance(values, list) or len(values) > 32:
            raise ValueError(f'invalid OCI {key}')
        for value in values:
            if not isinstance(value, str) or '\x00' in value or len(value.encode()) > 1024:
                raise ValueError(f'OCI {key} is out of bounds')
        args.extend(values)
    if sum(len(value.encode()) + 1 for value in args) > 8192:
        raise ValueError('OCI image process metadata exceeds its byte budget')
    for key, default in (('User', ''), ('WorkingDir', '/')):
        value = effective.get(key) or default
        if not isinstance(value, str) or len(value.encode()) > 1024 or '\x00' in value:
            raise ValueError(f'invalid OCI {key}')
        process[key] = value
    if not process['WorkingDir'].startswith('/') or '..' in PurePosixPath(process['WorkingDir']).parts:
        raise ValueError('OCI working directory must be absolute and rooted')
    return process


def admit(path, expected_config):
    if not SHA256.fullmatch(expected_config):
        raise ValueError('require a lowercase sha256 image config digest')
    if path.is_symlink() or not path.is_file() or path.stat().st_size > MAX_ARCHIVE:
        raise ValueError('expected a bounded regular Docker image archive')
    with tarfile.open(path, mode='r:') as archive:
        entries = index(archive)
        manifest = json.loads(read_regular(archive, entries, 'manifest.json', MAX_CONFIG))
        if not isinstance(manifest, list) or len(manifest) != 1:
            raise ValueError('require one image in a Docker save archive')
        entry = manifest[0]
        config_bytes = read_regular(archive, entries, entry['Config'], MAX_CONFIG)
        if image_digest(config_bytes) != expected_config:
            raise ValueError('image config digest mismatch')
        config = json.loads(config_bytes)
        if config.get('os') != 'linux' or config.get('architecture') != 'arm64':
            raise ValueError('expected Linux ARM64 image config')
        layer_paths = entry['Layers']
        diff_ids = config['rootfs']['diff_ids']
        if config['rootfs'].get('type') != 'layers' or len(layer_paths) != 1 or len(diff_ids) != 1:
            raise ValueError('only one image layer is supported by staging')
        layer = read_regular(archive, entries, layer_paths[0], MAX_ARCHIVE)
        if layer.startswith(b'\x1f\x8b'):
            with gzip.GzipFile(fileobj=io.BytesIO(layer)) as compressed:
                layer = compressed.read(MAX_ARCHIVE + 1)
        if len(layer) > MAX_ARCHIVE or image_digest(layer) != diff_ids[0]:
            raise ValueError('uncompressed rootfs size or diff ID mismatch')
        return {'config_digest': expected_config, 'diff_id': diff_ids[0],
                'rootfs_bytes': len(layer), 'rootfs_entries': verify_rootfs(layer),
                'process': process_config(config), 'platform': 'linux/arm64'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive', type=Path)
    parser.add_argument('--config-digest', required=True)
    args = parser.parse_args()
    if not args.archive.resolve().is_relative_to(SCRATCH):
        parser.error('expected Docker save archive under ExternalSSD scratch')
    try:
        print(json.dumps(admit(args.archive, args.config_digest), indent=2))
    except (ValueError, OSError, KeyError, TypeError, tarfile.TarError) as error:
        parser.error(str(error))


if __name__ == '__main__':
    main()
