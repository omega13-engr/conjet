#!/usr/bin/env python3
"""Opt-in correctness checks against an explicitly selected disposable Docker VM.

This never selects the user's default Docker context or prunes unrelated resources.
Host bind tests intentionally fail until Jetstream supplies real filesystem sharing.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--docker-socket', required=True)
    parser.add_argument('--qa-root', type=Path, required=True)
    args = parser.parse_args()
    if not Path(args.docker_socket).is_socket():
        parser.error('--docker-socket must identify the disposable runtime socket')
    args.qa_root.mkdir(parents=True, exist_ok=True)
    scratch = Path(tempfile.mkdtemp(prefix='compat-', dir=args.qa_root))
    prefix = 'conjet-compat-' + uuid.uuid4().hex[:10]
    environment = {key: os.environ[key] for key in ('PATH', 'HOME', 'LANG', 'TMPDIR') if key in os.environ}
    environment['DOCKER_CONFIG'] = str(scratch / 'docker-config')
    (scratch / 'docker-config').mkdir()
    containers, volumes, networks = [], [], []
    results, cleanup_errors = [], []

    def docker(*arguments, check=True):
        result = subprocess.run(['docker', '--host', 'unix://' + args.docker_socket, *arguments],
                                env=environment, capture_output=True, text=True, timeout=120)
        if check and result.returncode:
            raise RuntimeError(result.stderr.strip() or result.stdout.strip())
        return result

    def check(name, function):
        try:
            function()
            results.append({'name': name, 'ok': True})
        except Exception as error:
            results.append({'name': name, 'ok': False, 'error': str(error)})

    def run(image, *command, options=()):
        name = prefix + '-' + str(len(containers))
        containers.append(name)
        return docker('run', '--rm', '--name', name, *options, image, *command).stdout.strip()

    def named_volume():
        volume = prefix + '-data'
        volumes.append(volume)
        docker('volume', 'create', volume)
        run('alpine:3.22', 'sh', '-ec', 'echo retained >/data/proof', options=('-v', volume + ':/data'))
        assert run('alpine:3.22', 'cat', '/data/proof', options=('-v', volume + ':/data:ro')) == 'retained'

    def bridge_dns():
        network, name = prefix + '-net', prefix + '-server'
        networks.append(network)
        containers.append(name)
        docker('network', 'create', network)
        docker('run', '-d', '--name', name, '--network', network, 'alpine:3.22', 'sleep', '120')
        run('alpine:3.22', 'nslookup', name, options=('--network', network))

    def bind_mounts():
        shared = scratch / 'host directory with spaces'
        shared.mkdir()
        (shared / 'proof').write_text('host-first')
        mount = 'type=bind,src=' + str(shared) + ',dst=/data'
        assert run('alpine:3.22', 'cat', '/data/proof', options=('--mount', mount)) == 'host-first'
        run('alpine:3.22', 'sh', '-ec', 'echo guest-write >/data/proof; mv /data/proof /data/renamed; ln -s renamed /data/link', options=('--mount', mount))
        assert (shared / 'renamed').read_text().strip() == 'guest-write'
        assert (shared / 'link').is_symlink()
        (shared / 'renamed').write_text('host-updated')
        assert run('alpine:3.22', 'cat', '/data/link', options=('--mount', mount)) == 'host-updated'
        run('alpine:3.22', 'sh', '-ec', '! echo forbidden >/data/renamed', options=('--mount', mount + ',readonly'))
        assert (shared / 'renamed').read_text() == 'host-updated'
        assert run('alpine:3.22', 'cat', '/proof', options=('--mount', 'type=bind,src=' + str(shared / 'renamed') + ',dst=/proof,readonly')) == 'host-updated'
        run('alpine:3.22', 'rm', '/data/link', '/data/renamed', options=('--mount', mount))
        assert not (shared / 'renamed').exists()

    def https():
        run('alpine:3.22', 'wget', '-qO', '/dev/null', 'https://example.com')

    try:
        check('named-volume-persistence', named_volume)
        check('bridge-container-dns', bridge_dns)
        check('container-https', https)
        check('host-bind-file-directory-rw-readonly-symlink-rename-delete', bind_mounts)
    finally:
        for kind, names in [('container', containers), ('volume', volumes), ('network', networks)]:
            for name in reversed(names):
                try:
                    result = docker(kind, 'rm', *(['-f'] if kind == 'container' else []), name, check=False)
                    if result.returncode and 'No such' not in result.stderr:
                        cleanup_errors.append(result.stderr.strip())
                except Exception as error:
                    cleanup_errors.append(str(error))
        shutil.rmtree(scratch)
        report = {'results': results, 'cleanupErrors': cleanup_errors}
        (args.qa_root / 'runtime-compatibility.json').write_text(json.dumps(report, indent=2) + '\n')
        for result in results:
            if not result['ok']:
                print(result['name'] + ': ' + result['error'])
        for error in cleanup_errors:
            print('Cleanup: ' + error)
    return int(bool(cleanup_errors) or any(not result['ok'] for result in results))


if __name__ == '__main__':
    raise SystemExit(main())
