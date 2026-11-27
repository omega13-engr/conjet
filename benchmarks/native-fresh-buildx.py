#!/usr/bin/env python3
"""Qualify stock Buildx and Compose against a fresh package on macOS."""

import argparse
import hashlib
import http.client
import json
import os
import plistlib
import runpy
import shutil
import signal
import socket
import subprocess
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
FIXTURE = HERE / 'fixtures/fresh-buildx'
LAUNCH = runpy.run_path(str(HERE.parent / 'build-support/run-conjet-speedup.py'))
SCRATCH = LAUNCH['SCRATCH']


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def production():
    home = Path.home()
    docker = home / '.docker'
    files = [docker / 'config.json', *docker.glob('contexts/meta/*/meta.json'),
             *docker.glob('buildx/instances/*'), home / '.ssh/config',
             *home.glob('Library/LaunchAgents/*.plist'),
             home / 'Library/Application Support/Conjet/runtime-environment.json',
             home / '.conjet/run/docker.sock', docker / 'run/docker.sock',
             Path('/var/run/docker.sock')]
    processes = LAUNCH['processes']()
    return {
        'files': {str(file): LAUNCH['fingerprint'](file) for file in files},
        'processes': {pid: str(path) for pid, path in processes.items()
                      if path.name in ('Conjet', 'conjetd', 'Conjet Core', 'conjet-network')},
    }


def peer_pid(path):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(5)
        client.connect(str(path))
        return client.getsockopt(0, 2)


def pull_boundary(path):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(30)
        client.connect(str(path))
        client.sendall(
            b'POST /images/create?fromImage=moby%2Fbuildkit&tag=buildx-stable-1 HTTP/1.1\r\n'
            b'Host: docker\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'
        )
        reply = http.client.HTTPResponse(client)
        reply.begin()
        return {'status': reply.status, 'body': reply.read(65536).decode()}


def qualify(args, root, report):
    app = root / 'Conjet.app'
    shutil.copytree(args.app, app, symlinks=True)
    tools = app / 'Contents/Resources/ConjetTools'
    daemon = tools / 'conjetd'
    core = tools / 'ConjetCoreVMM/Conjet Core'
    home = root / 'h'
    config = root / 'docker'
    plugins = config / 'cli-plugins'
    tmp = root / 'tmp'
    for path in (home, plugins, tmp):
        path.mkdir(parents=True, mode=0o700)
    for key in ('buildx', 'compose'):
        (plugins / f'docker-{key}').symlink_to(getattr(args, key))
    endpoint = home / 'run/docker.sock'
    control = home / 'run/conjetd.sock'
    host = f'unix://{endpoint}'
    env = {'HOME': str(home), 'CONJET_HOME': str(home), 'DOCKER_CONFIG': str(config),
           'DOCKER_HOST': host, 'TMPDIR': str(tmp), 'PATH': '/opt/homebrew/bin:/usr/bin:/bin',
           'CONJET_DISABLE_MENU_BAR_APP': '1', 'CONJET_DISABLE_BACKGROUND_SERVICE_REGISTRATION': '1'}
    report['endpoint'] = host
    report['app_version'] = plistlib.loads(
        (app / 'Contents/Info.plist').read_bytes())['CFBundleShortVersionString']
    report['sha256'] = {path.name: digest(path) for path in (
        args.docker, args.buildx, args.compose, tools / 'conjet', daemon, core,
        core.with_name('conjet-launchd-linux-arm64'))}

    def call(label, argv, *, checked=True, timeout=180, updates=None):
        then = time.monotonic()
        with subprocess.Popen(argv, env={**env, **(updates or {})}, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, text=True, start_new_session=True) as command:
            try:
                stdout, stderr = command.communicate(timeout=timeout)
            except (subprocess.TimeoutExpired, KeyboardInterrupt):
                try:
                    os.killpg(command.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                command.wait(timeout=10)
                raise
        result = subprocess.CompletedProcess(argv, command.returncode, stdout, stderr)
        report['calls'][label] = {'argv': list(map(str, argv)), 'exit': result.returncode,
                                  'elapsed_seconds': time.monotonic() - then,
                                  'stdout': result.stdout, 'stderr': result.stderr}
        print(f'{label}: exit {result.returncode} ({time.monotonic() - then:.2f}s)', flush=True)
        if checked and result.returncode:
            raise RuntimeError(f'{label} failed: {result.stderr.strip()}')
        return result

    def docker(label, *argv, **options):
        return call(label, [args.docker, '--config', config, '--context', 'cjb', *argv], **options)

    def start():
        LAUNCH['daemon_request'](control, proc.pid, 'vm-start', timeout=90)
        deadline = time.monotonic() + 15
        while not endpoint.is_socket():
            if time.monotonic() >= deadline:
                raise RuntimeError('private Docker socket did not appear')
            time.sleep(0.05)
        if LAUNCH['processes']().get(peer_pid(endpoint)) != core:
            raise RuntimeError('private Docker socket does not belong to the staged Core')

    before = production()
    proc = None
    try:
        with (root / 'daemon.log').open('w') as log:
            proc = subprocess.Popen([daemon, '--serve'], env=env, stdout=log, stderr=log)
        deadline = time.monotonic() + 10
        while not control.is_socket():
            if proc.poll() is not None or time.monotonic() >= deadline:
                raise RuntimeError('private daemon did not start')
            time.sleep(0.05)
        start()
        call('context', [args.docker, '--config', config, '--host', host,
                         'context', 'create', 'cjb', '--docker', f'host={host}'])
        server = docker('docker-version', 'version', '--format', '{{json .}}')
        if 'Conjet Native OCI' not in server.stdout:
            raise RuntimeError('expected the packaged Native Docker engine')
        docker('buildx-version', 'buildx', 'version')
        docker('compose-version', 'compose', 'version')
        if args.memory_only:
            ready = json.loads((home / 'logs/native-boot.jsonl').read_text().splitlines()[0])
            session = Path(ready['session'])
            if session.parent != home / 'run' or LAUNCH['processes']().get(ready['pid']) != core:
                raise RuntimeError('Core memory socket does not belong to the private boot')
            memory = runpy.run_path(str(HERE / 'native-core-memory.py'))
            client = [args.docker, '--config', config, '--context', 'cjb']
            try:
                memory['check_growth'](endpoint, peer_pid(endpoint), session, ready['pid'], root, client, env)
            finally:
                report['memory'] = {path.name: json.loads(path.read_text())
                                    for path in root.glob('native-core-memory-summary.json')}
            report['passed'] = True
            return
        private_plugin = home / 'run/native-data/build-client/cli-plugins/docker-buildx'
        if private_plugin.is_file():
            report['private_buildx_sha256'] = digest(private_plugin)
        if args.expect_private_build_unavailable:
            if private_plugin.is_file():
                raise RuntimeError('the staged runtime accepted the unusable Buildx plugin')
            missing = docker('unavailable-private-build', 'build', '--network', 'none',
                             '--tag', 'conjet-buildx-direct:local', FIXTURE / 'smoke',
                             checked=False, updates={'DOCKER_BUILDKIT': '0'})
            if missing.returncode == 0 or 'Install both and restart this Conjet profile' not in missing.stderr:
                raise RuntimeError('unavailable private build omitted the capability diagnostic')
            report['passed'] = True
            return
        report['fresh_images'] = docker('fresh-images', 'image', 'ls', '--format', 'json').stdout.splitlines()
        if report['fresh_images']:
            raise RuntimeError('the private runtime did not start with an empty listed image store')
        docker('create', 'buildx', 'create', '--driver', 'docker-container', '--name', 'fresh', 'cjb')
        bootstrap = docker('bootstrap', 'buildx', 'inspect', 'fresh', '--bootstrap', checked=False)
        if bootstrap.returncode == 0 and not args.expect_baseline:
            docker('scratch-control', 'buildx', 'build', '--builder', 'fresh', '--load',
                   '--tag', 'conjet-buildx-scratch:local', FIXTURE / 'scratch')
        compose = ['compose', '--file', FIXTURE / 'smoke/compose.yaml', '--project-name', 'cjb',
                   '--ansi', 'never', '--progress', 'plain']
        bake = {'updates': {'COMPOSE_BAKE': 'true'}}
        build = docker('compose-build', *compose, 'build', '--builder', 'fresh', checked=False, **bake)
        if args.expect_baseline:
            report['pull_boundary'] = pull_boundary(endpoint)
            if (bootstrap.returncode == 0 or build.returncode == 0
                    or report['pull_boundary']['status'] != 400
                    or 'expected an immutable SHA-256 digest' not in bootstrap.stderr
                    or 'expected an immutable SHA-256 digest' not in report['pull_boundary']['body']):
                raise RuntimeError('baseline failed to reproduce the immutable-digest error')
            report['baseline_reproduced'] = True
            return
        if bootstrap.returncode or build.returncode:
            raise RuntimeError(f'default builder failed: {bootstrap.stderr.strip()} {build.stderr.strip()}')
        if docker('compose-run', *compose, 'run', '--rm', '-T', 'smoke').stdout != 'conjet-buildx-ok\n':
            raise RuntimeError('Compose run returned unexpected output')
        warm = docker('warm-rebuild', *compose, 'build', '--builder', 'fresh', **bake)
        if 'CACHED' not in warm.stderr + warm.stdout:
            raise RuntimeError('warm build did not report cache reuse')
        copy = root / 'copy'
        shutil.copytree(FIXTURE / 'copy', copy)
        for label, output in [('copy-initial', 'before\n'), ('copy-rebuild', 'after\n')]:
            (copy / 'input.txt').write_text(output)
            docker(label, 'buildx', 'build', '--builder', 'fresh', '--load', '--tag',
                   'conjet-buildx-copy:local', copy)
            if docker(f'{label}-run', 'run', '--rm', 'conjet-buildx-copy:local').stdout != output:
                raise RuntimeError('COPY build did not reflect its input')
        failed = root / 'failed'
        failed.mkdir()
        (failed / 'Dockerfile').write_text('FROM alpine:3.21\nRUN exit 37\n')
        failure = docker('failed-run', 'buildx', 'build', '--builder', 'fresh', '--progress', 'plain',
                         '--load', '--tag', 'conjet-buildx-failed:local', failed, checked=False)
        if not failure.returncode or 'exit code: 37' not in failure.stderr:
            raise RuntimeError('a failed RUN did not fail the build')
        if docker('failed-image', 'image', 'inspect', 'conjet-buildx-failed:local',
                  checked=False).returncode == 0:
            raise RuntimeError('a failed RUN published an image')

        cancel = root / 'cancel'
        cancel.mkdir()
        (cancel / 'Dockerfile').write_text(
            'FROM alpine:3.21\nRUN echo conjet-cancel-started; exec sleep 60\n')
        argv = [args.docker, '--config', config, '--context', 'cjb', 'buildx', 'build',
                '--builder', 'fresh', '--progress', 'plain', '--load', '--tag',
                'conjet-buildx-cancel:local', cancel]
        then = time.monotonic()
        output = root / 'cancel.log'
        with output.open('w') as log, subprocess.Popen(
            argv, env=env, stdout=log, stderr=log, start_new_session=True
        ) as build:
            try:
                while not any(line.endswith(' conjet-cancel-started') and 'RUN ' not in line
                              for line in output.read_text().splitlines()):
                    if build.poll() is not None or time.monotonic() - then > 25:
                        raise RuntimeError('cancellation fixture did not reach RUN')
                    time.sleep(0.05)
                os.killpg(build.pid, signal.SIGINT)
                build.wait(timeout=10)
            finally:
                if build.poll() is None:
                    os.killpg(build.pid, signal.SIGKILL)
                    build.wait(timeout=10)
                report['calls']['cancel'] = {'argv': list(map(str, argv)), 'exit': build.returncode,
                                             'elapsed_seconds': time.monotonic() - then,
                                             'output': output.read_text()}
        if build.returncode == 0 or docker('cancelled-image', 'image', 'inspect',
                                           'conjet-buildx-cancel:local', checked=False).returncode == 0:
            raise RuntimeError('a cancelled solve published an image')

        LAUNCH['daemon_request'](control, proc.pid, 'vm-stop', timeout=60)
        start()
        docker('restart-bootstrap', 'buildx', 'inspect', 'fresh', '--bootstrap')
        docker('restart-build', *compose, 'build', '--builder', 'fresh', **bake)
        if docker('restart-run', *compose, 'run', '--rm', '-T', 'smoke').stdout != 'conjet-buildx-ok\n':
            raise RuntimeError('Compose run failed after private runtime restart')
        docker('remove-builder', 'buildx', 'rm', 'fresh')
        if docker('workers-after-remove', 'ps', '-a', '-q').stdout:
            raise RuntimeError('builder cleanup left a container')
        if docker('volumes-after-remove', 'volume', 'ls', '-q').stdout:
            raise RuntimeError('builder cleanup left a volume')

        if report.get('private_buildx_sha256') != report['sha256']['docker-buildx']:
            raise RuntimeError('private build client did not use the explicitly selected Buildx plugin')
        docker('tagged-pull', 'pull', '--platform', 'linux/arm64', 'alpine:3.21')
        rejected = docker('unrelated-privileged', 'create', '--privileged', '--name',
                          'buildx_buildkit_invalid0', 'alpine:3.21', checked=False)
        if rejected.returncode == 0 or 'require a verified BuildKit worker' not in rejected.stderr:
            raise RuntimeError('an unrelated privileged container was not rejected at the worker boundary')
        docker('direct-build', 'build', '--network', 'none', '--tag', 'conjet-buildx-direct:local',
               FIXTURE / 'smoke', updates={'DOCKER_BUILDKIT': '0'})
        if docker('direct-run', 'run', '--rm', 'conjet-buildx-direct:local').stdout != 'conjet-buildx-ok\n':
            raise RuntimeError('direct build returned an unexpected image')
        report['passed'] = True
    finally:
        serial = next(iter(home.glob("run/cn-*/serial.log")), None)
        if serial and serial.is_file():
            with serial.open('rb') as stream:
                stream.seek(max(0, serial.stat().st_size - 65536))
                report['guest_serial_tail'] = stream.read(65536).decode(errors='replace')
        try:
            try:
                if proc is not None:
                    LAUNCH['stop_owned'](proc, control, tools, report)
            finally:
                LAUNCH['stop_owned'](None, control, core.parent, report)
            leftovers = [path for path in LAUNCH['processes']().values() if path.is_relative_to(app)]
            if leftovers or endpoint.is_socket() or control.is_socket():
                raise RuntimeError(f'private runtime leaked processes or sockets: {leftovers}')
            boot_log = home / 'logs/native-boot.jsonl'
            if boot_log.is_file():
                records = [json.loads(line) for line in boot_log.read_text().splitlines()]
                shutdown = next((record for record in reversed(records)
                                 if record.get('event') == 'shutdown'), {})
                report['shutdown'] = shutdown
                if shutdown.get('guest_cleanup') != 'complete' or shutdown.get('reclaim_failures') != 0:
                    raise RuntimeError('Core did not verify a clean guest shutdown')
            report['runtime_cleanup'] = not any(
                key in report for key in ('forced_cleanup', 'graceful_stop_error'))
            report['production_unchanged'] = production() == before
            if not report['runtime_cleanup'] or not report['production_unchanged']:
                raise RuntimeError('cleanup or production verification failed')
        finally:
            logs = home / 'logs'
            report['runtime_logs'] = {file.name: file.read_text(errors='replace')[-20000:]
                                      for file in [root / 'daemon.log', *logs.glob('native-*.log'), *logs.glob('native-*.jsonl')]
                                      if file.is_file()}


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', required=True, type=lambda path: Path(path).resolve(strict=True))
    parser.add_argument('--evidence', required=True, type=Path)
    for key in ('docker', 'buildx', 'compose'):
        parser.add_argument(f'--{key}', required=True, type=lambda path: Path(path).resolve(strict=True))
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--expect-baseline', action='store_true')
    mode.add_argument('--memory-only', action='store_true')
    mode.add_argument('--expect-private-build-unavailable', action='store_true')
    args = parser.parse_args()
    args.evidence = args.evidence.resolve()
    if not args.evidence.is_relative_to(SCRATCH) or args.evidence.exists():
        parser.error('choose a new evidence file under ExternalSSD scratch')
    report = {'calls': {}, 'passed': False}

    def interrupt(signum, _):
        raise KeyboardInterrupt(signal.Signals(signum).name)

    signal.signal(signal.SIGTERM, interrupt)
    try:
        with tempfile.TemporaryDirectory(prefix='bx-', dir=SCRATCH) as root:
            qualify(args, Path(root), report)
    except (Exception, KeyboardInterrupt) as error:
        report['error'] = str(error)
        report['passed'] = False
        raise
    finally:
        args.evidence.write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
