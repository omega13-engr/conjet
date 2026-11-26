"""Generate and verify the native two-layer OCI staging fixture."""

import argparse
import base64
import gzip
import hashlib
import io
import json
from pathlib import Path
import runpy
import subprocess
import tarfile


HERE = Path(__file__).resolve().parent
MATCHED = runpy.run_path(str(HERE / 'native-docker-comparison.py'))
SCRATCH = MATCHED['TOOLS']['SCRATCH']
PINNED = HERE / 'scenarios/native-oci-two-layer-v1.json'
BASE_SHA256 = '7e002bd9c01ad6b50c34c1df8c13975ed422fe9484780870e3ac1439548161eb'
LAYERS = {
    'lower': [
        ('fixture', 'directory', '', b''),
        ('fixture/opaque', 'directory', '', b''),
        ('fixture/opaque/hidden', 'file', '', b'hidden\n'),
        ('fixture/replaced', 'file', '', b'original\n'),
        ('fixture/removed', 'file', '', b'removed\n'),
    ],
    'upper': [
        ('fixture/.wh.removed', 'file', '', b''),
        ('fixture/opaque/.wh..wh..opq', 'file', '', b''),
        ('fixture/opaque/visible', 'file', '', b'visible\n'),
        ('fixture/replaced', 'file', '', b'replaced\n'),
        ('fixture/hard', 'hardlink', 'fixture/replaced', b''),
        ('fixture/sym', 'symlink', 'replaced', b''),
    ],
}
TYPES = {'directory': tarfile.DIRTYPE, 'file': tarfile.REGTYPE, 'hardlink': tarfile.LNKTYPE,
         'symlink': tarfile.SYMTYPE, 'character': tarfile.CHRTYPE}


def digest(data):
    return 'sha256:' + hashlib.sha256(data).hexdigest()


def entries(fixture):
    return [{'path': name, 'kind': kind, 'target': target, 'data': base64.b64encode(data).decode(),
             'mode': 0o755 if kind == 'directory' else 0o644, 'uid': 65532, 'gid': 65532}
            for name, kind, target, data in fixture]


def tar(records):
    stream = io.BytesIO()
    with tarfile.open(fileobj=stream, mode='w', format=tarfile.USTAR_FORMAT) as archive:
        for record in records:
            item = tarfile.TarInfo(record['path'])
            item.type = TYPES[record['kind']]
            item.linkname = record['target']
            item.uid, item.gid, item.mode = record['uid'], record['gid'], record['mode']
            data = base64.b64decode(record['data'], validate=True)
            item.size = len(data)
            archive.addfile(item, io.BytesIO(data))
    return stream.getvalue()


def serialize(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':')).encode()


def layout(directory, layers, *, wrong_diff=False):
    blobs = directory / 'blobs/sha256'
    blobs.mkdir(parents=True)

    def store(content, media):
        reference = digest(content)
        path = blobs / reference[7:]
        if not path.exists():
            path.write_bytes(content)
        return {'digest': reference, 'size': len(content), 'mediaType': media}

    def compress(layer):
        output = io.BytesIO()
        with gzip.GzipFile(filename='', fileobj=output, mode='wb', mtime=0, compresslevel=0) as stream:
            stream.write(layer)
        return output.getvalue()

    diff_ids = [digest(layer) for layer in layers]
    if wrong_diff:
        diff_ids[-1] = 'sha256:' + '0' * 64
    config = store(serialize({'os': 'linux', 'architecture': 'arm64',
                              'rootfs': {'type': 'layers', 'diff_ids': diff_ids},
                              'config': {'Env': ['PATH=/bin:/usr/bin'], 'Cmd': ['/bin/true']}}),
                   'application/vnd.oci.image.config.v1+json')
    descriptors = [store(compress(layer), 'application/vnd.oci.image.layer.v1.tar+gzip')
                   for layer in layers]
    manifest = store(serialize({'schemaVersion': 2, 'config': config, 'layers': descriptors}),
                     'application/vnd.oci.image.manifest.v1+json')
    return {'manifest_digest': manifest['digest'], 'config_digest': config['digest'],
            'layers': [layer['digest'] for layer in descriptors], 'diff_ids': diff_ids}


def stage(vmm, source, manifest, output):
    return subprocess.run([vmm, 'native', 'docker-stage', '--layout', source,
                           '--manifest-digest', manifest, '--output', output],
                          capture_output=True, timeout=30, check=False, text=True)


def generate(base, output, vmm):
    if MATCHED['TOOLS']['file_hash'](base) != BASE_SHA256:
        raise ValueError('verified Alpine base package differs from the frozen fixture')
    output.mkdir(mode=0o700)
    lower = tar(json.loads(base.read_text())['records'] + entries(LAYERS['lower']))
    upper = tar(entries(LAYERS['upper']))
    source = output / 'layout'
    identity = layout(source, [lower, upper])
    pinned = json.loads(PINNED.read_text())
    if identity != pinned:
        raise ValueError(f'two-layer identity differs from the frozen fixture: {identity}')
    staged = stage(vmm, source, identity['manifest_digest'], output / 'staged')
    staged.check_returncode()
    (output / 'staging.json').write_text(staged.stdout)
    negative = {
        'member-escape': (tar(entries([('../escape', 'file', '', b'x')])), False, 'entry path'),
        'symlink-escape': (tar(entries([('fixture/escape', 'symlink', '../../escape', b'')])),
                           False, 'escapes the guest root'),
        'hardlink-escape': (tar(entries([('fixture/escape', 'hardlink', '../escape', b'')])),
                            False, 'entry path'),
        'link-through-symlink': (tar(entries([('fixture/sym', 'symlink', 'opaque', b''),
                                             ('fixture/sym/escape', 'file', '', b'x')])),
                                 False, 'traverses a non-directory'),
        'dangling-hardlink': (tar(entries([('fixture/invalid', 'hardlink', 'fixture/missing', b'')])),
                              False, 'does not resolve'),
        'bad-whiteout': (tar(entries([('fixture/.wh.removed', 'file', '', b'nonempty')])),
                         False, 'malformed OCI whiteout'),
        'bad-checksum': (b'x' + upper[1:], False, 'checksum'),
        'bad-trailer': (upper[:-1] + b'x', False, 'malformed OCI tar trailer'),
        'unsafe-entry': (tar(entries([('fixture/character', 'character', '', b'')])),
                         False, 'unsupported OCI tar entry type'),
        'diff-id': (upper, True, 'diff ID mismatch'),
    }
    results = {}
    for name, (layer, wrong_diff, expected) in negative.items():
        case = output / name
        # No dynamic executable is needed to reject an invalid second layer.
        fixture = layout(case, [tar(entries(LAYERS['lower'])), layer], wrong_diff=wrong_diff)
        target = output / f'{name}-unexpected'
        failed = stage(vmm, case, fixture['manifest_digest'], target)
        if failed.returncode == 0 or expected not in failed.stderr or target.exists():
            raise RuntimeError(f'{name} did not fail closed: {failed.stderr}')
        results[name] = failed.stderr.strip()
    for name, key in (('config-hash', 'config_digest'), ('layer-hash', 'layers'),
                      ('manifest-hash', 'manifest_digest')):
        case = output / name
        fixture = layout(case, [tar(entries(LAYERS['lower'])), upper])
        reference = fixture[key]
        if isinstance(reference, list):
            reference = reference[-1]
        blob = case / 'blobs/sha256' / reference[7:]
        original = blob.read_bytes()
        blob.write_bytes(original[:-1] + bytes([original[-1] ^ 1]))
        target = output / f'{name}-unexpected'
        failed = stage(vmm, case, fixture['manifest_digest'], target)
        if failed.returncode == 0 or 'OCI blob digest mismatch' not in failed.stderr or target.exists():
            raise RuntimeError(f'{name} did not fail closed: {failed.stderr}')
        results[name] = failed.stderr.strip()
    failed = stage(vmm, source, identity['manifest_digest'], output / 'staged')
    if failed.returncode == 0 or 'cannot publish' not in failed.stderr:
        raise RuntimeError('staging unexpectedly replaced its existing output')
    results['existing-output'] = failed.stderr.strip()
    (output / 'negative-checks.json').write_text(json.dumps(results, indent=2) + '\n')


def collect(endpoint, peer, docker, env, output, image):
    tools = MATCHED['TOOLS']
    connection = tools['UnixHTTP'](endpoint, peer)
    seen = set()
    checks = {}

    def run(name, command, stdout=None):
        args = [*docker, 'run', *MATCHED['FLAGS'], '--name', name, image, *command]
        child = subprocess.run(args, env=env, capture_output=True, timeout=30)
        if child.returncode or child.stderr or (stdout is not None and child.stdout != stdout):
            raise RuntimeError(f'{name} failed: {child.returncode} {child.stdout[:200]!r} {child.stderr[:200]!r}')
        witness = MATCHED['native_terminal'](connection, name, seen)
        checks[name] = {'stdout': child.stdout.decode(), 'witness': witness}
        return child.stdout

    try:
        version = tools['api'](connection, 'GET', '/version', (200,))
        if version['Platform']['Name'] != 'Conjet Native OCI':
            raise RuntimeError('unexpected endpoint for native OCI fixture')
        found = run('cjlayer-inodes', ['/bin/busybox', 'stat', '-c', '%i',
                                       '/fixture/replaced', '/fixture/hard'])
        numbers = found.splitlines()
        if len(numbers) != 2 or numbers[0] != numbers[1] or not numbers[0].isdigit():
            raise RuntimeError('hard links did not share an inode')
        run('cjlayer-mutation', ['/bin/sh', '-c',
                                 'test ! -e /fixture/removed && test ! -e /fixture/opaque/hidden && '
                                 'test -L /fixture/sym && printf changed >/fixture/hard && '
                                 'test -f /fixture/opaque/visible && printf cache >/fixture/cache && '
                                 '/bin/busybox cat /fixture/replaced /fixture/hard /fixture/sym'],
            b'changedchangedchanged')
        run('cjlayer-immutable', ['/bin/sh', '-c',
                                  'test ! -e /fixture/cache && test ! -e /fixture/removed && '
                                  'test ! -e /fixture/opaque/hidden && '
                                  '/bin/busybox cat /fixture/replaced /fixture/hard /fixture/sym '
                                  '/fixture/opaque/visible'], b'replaced\nreplaced\nreplaced\nvisible\n')
    finally:
        connection.close()
        (output / 'layer-checks.json').write_text(json.dumps(checks, indent=2) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base-package', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--vmm', required=True, type=Path)
    args = parser.parse_args()
    if not (args.output.parent.resolve(strict=True).is_relative_to(SCRATCH)
            and args.base_package.resolve(strict=True).is_relative_to(SCRATCH)
            and args.vmm.resolve(strict=True).is_relative_to(SCRATCH)):
        parser.error('fixtures and build must reside on ExternalSSD')
    generate(args.base_package, args.output, args.vmm)
