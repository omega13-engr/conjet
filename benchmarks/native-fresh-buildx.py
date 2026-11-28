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
import urllib.request
from pathlib import Path

from compatibility.egress import diagnose as diagnose_egress, public_ipv4
from compatibility.identity import DockerConnection, production_sockets
from compatibility.run import record_lane

HERE = Path(__file__).resolve().parent
FIXTURE = HERE / 'fixtures/fresh-buildx'
LAUNCH = runpy.run_path(str(HERE.parent / 'build-support/run-conjet-speedup.py'))
SCRATCH = LAUNCH['SCRATCH']


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def copy_guest_probe(core, destination):
    # The packaged Linux binary is a read-only macOS resource. BuildKit's COPY
    # preserves modes, so make the private fixture executable inside Linux.
    shutil.copyfile(core.with_name('conjet-launchd-linux-arm64'), destination)
    destination.chmod(0o755)


def production():
    home = Path.home()
    docker = home / '.docker'
    profiles = [home / name for name in ('.zprofile', '.zshrc', '.bash_profile', '.bashrc', '.profile')]
    files = [*profiles, docker / 'config.json', *docker.glob('contexts/meta/*/meta.json'),
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
    if args.memory_mib != 2048:
        (home / 'config.toml').write_text(
            f'[vm]\nruntime = "native-docker"\nprofile = "docker-compatibility"\ndisk_gib = 16\ncpus = 2\nmemory_mib = {args.memory_mib}\nbackend = "hvf-experimental"\n')
    report['configured_memory_mib'] = args.memory_mib
    report['endpoint'] = host
    report['app_version'] = plistlib.loads(
        (app / 'Contents/Info.plist').read_bytes())['CFBundleShortVersionString']
    report['sha256'] = {path.name: digest(path) for path in (
        args.docker, args.buildx, args.compose, tools / 'conjet', daemon, core,
        core.with_name('conjet-launchd-linux-arm64'))}

    command_logs = args.evidence.with_suffix('.logs')
    command_logs.mkdir(mode=0o700)

    def call(label, argv, *, checked=True, timeout=180, updates=None):
        then = time.monotonic()
        stdout_path = command_logs / f'{label}.stdout'
        stderr_path = command_logs / f'{label}.stderr'
        failure = None
        with stdout_path.open('w') as out, stderr_path.open('w') as err:
            with subprocess.Popen(argv, env={**env, **(updates or {})}, stdout=out,
                                  stderr=err, text=True, start_new_session=True) as command:
                try:
                    command.wait(timeout=timeout)
                except (subprocess.TimeoutExpired, KeyboardInterrupt) as error:
                    failure = error
                    try:
                        os.killpg(command.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    command.wait(timeout=10)
        stdout = stdout_path.read_text(errors='replace')
        stderr = stderr_path.read_text(errors='replace')
        result = subprocess.CompletedProcess(argv, command.returncode, stdout, stderr)
        report['calls'][label] = {'argv': list(map(str, argv)), 'exit': result.returncode,
                                  'elapsed_seconds': time.monotonic() - then,
                                  'stdout': result.stdout, 'stderr': result.stderr,
                                  'stdout_path': str(stdout_path), 'stderr_path': str(stderr_path)}
        print(f'{label}: exit {result.returncode} ({time.monotonic() - then:.2f}s)', flush=True)
        if failure is not None:
            raise failure
        if checked and result.returncode:
            raise RuntimeError(f'{label} failed: {result.stderr.strip()}')
        return result

    def docker(label, *argv, **options):
        return call(label, [args.docker, '--config', config, '--context', 'cjb', *argv], **options)

    def runtime_checks(image):
        binds = home / 'run/native-data/binds/runtime-check'
        for name in ('data', 'keys', 'skills'):
            (binds / name).mkdir(parents=True)
            (binds / name / 'marker').write_text(name + '\n')
        mount_args = []
        for name in ('data', 'keys', 'skills'):
            mount_args += ['--mount', f'type=bind,source={binds / name},target=/app/{name}']
        try:
            docker('multi-bind-port-start', 'run', '--detach', '--name', 'cjb-runtime',
                '--network', 'bridge', '--publish', '127.0.0.1::8787', '--publish', '127.0.0.1::8788',
                '--health-cmd', 'test -f /app/data/index.html', '--health-timeout', '3s',
                '--health-interval', '1s', *mount_args, image,
                '/probe', '--serve-bind-http')
            deadline = time.monotonic() + 30
            while True:
                runtime_state = json.loads(docker('multi-bind-port-inspect', 'inspect', 'cjb-runtime').stdout)[0]
                if runtime_state['State'].get('Health', {}).get('Status') == 'healthy':
                    break
                if not runtime_state['State']['Running'] or time.monotonic() >= deadline:
                    docker('multi-bind-port-logs', 'logs', 'cjb-runtime', checked=False)
                    raise RuntimeError('multi-bind workload exited or did not become healthy')
                time.sleep(1)
            for target in ('8787/tcp', '8788/tcp'):
                port = runtime_state['NetworkSettings']['Ports'][target][0]['HostPort']
                with urllib.request.urlopen(f'http://127.0.0.1:{port}/', timeout=5) as response:
                    if response.status != 200 or response.read(1024) != b'data\nkeys\nskills\n':
                        raise RuntimeError('multiple ports or bind mounts returned incorrect content')
            if (binds / 'data/index.html').read_bytes() != b'data\nkeys\nskills\n':
                raise RuntimeError('guest bind write was not visible on the host')
            report['multiple_bind_ports_health'] = True
        finally:
            docker('multi-bind-port-remove', 'rm', '--force', 'cjb-runtime', checked=False)

    def start():
        LAUNCH['daemon_request'](control, proc.pid, 'vm-start', timeout=90)
        deadline = time.monotonic() + 15
        while not endpoint.is_socket():
            if time.monotonic() >= deadline:
                raise RuntimeError('private Docker socket did not appear')
            time.sleep(0.05)
        pid = peer_pid(endpoint)
        if LAUNCH['processes']().get(pid) != core:
            raise RuntimeError('private Docker socket does not belong to the staged Core')
        return pid

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
        adapter_pid = start()
        if args.identity_only or args.compatibility_profile or args.direct_egress_ip:
            client = DockerConnection(endpoint, root, production_sockets(args.docker), adapter_pid)
            report['identity'] = client.capture(core)
        call('context', [args.docker, '--config', config, '--host', host,
                         'context', 'create', 'cjb', '--docker', f'host={host}'])
        server = docker('docker-version', 'version', '--format', '{{json .}}')
        if 'Conjet Native OCI' not in server.stdout:
            raise RuntimeError('expected the packaged Native Docker engine')
        capacity = docker('configured-capacity', 'info', '--format', '{{.MemTotal}}')
        if int(capacity.stdout.strip()) != args.memory_mib * 1024 * 1024:
            raise RuntimeError('Docker API reports a different guest memory ceiling')
        docker('buildx-version', 'buildx', 'version')
        docker('compose-version', 'compose', 'version')
        if args.identity_only or args.compatibility_profile:
            report['app_executable_sha256'] = digest(app / 'Contents/MacOS/Conjet')
            native_core = core.parent / 'NativeCore'
            report['native_artifacts'] = {
                str(path.relative_to(core.parent)): digest(path)
                for path in sorted(native_core.rglob('*')) if path.is_file()
            }
            if args.compatibility_profile:
                def restart_engine():
                    LAUNCH['daemon_request'](control, proc.pid, 'vm-stop', timeout=30)
                    return DockerConnection(endpoint, root, client.forbidden, start())

                lane = record_lane(args.compatibility_profile, client, core, report['identity'],
                                   restart_engine=restart_engine)
                report['compatibility'] = lane
                report['passed'] = (lane['endpoint_verified_after'] and bool(lane['cases'])
                                    and all(row['passed'] for row in lane['cases'].values()))
            else:
                report['passed'] = True
            return
        if args.direct_egress_ip:
            report['direct_egress'] = diagnose_egress(docker, args.direct_egress_ip)
            report['passed'] = client.capture(core) == report['identity']
            return
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
        if args.tags_only:
            docker('tags-pull', 'pull', 'alpine:3.21')
            original = json.loads(docker('tags-original', 'image', 'inspect', 'alpine:3.21').stdout)[0]['Id']
            docker('tags-alias', 'tag', 'alpine:3.21', 'conjet-tag-check:local')
            LAUNCH['daemon_request'](control, proc.pid, 'vm-stop', timeout=60)
            start()
            restored = json.loads(docker('tags-restored', 'image', 'inspect', 'conjet-tag-check:local').stdout)[0]['Id']
            if original != restored:
                raise RuntimeError('image tag changed identity across engine restart')
            if docker('tags-run', 'run', '--rm', 'conjet-tag-check:local', '/bin/echo', 'tag-restored').stdout != 'tag-restored\n':
                raise RuntimeError('restored image tag did not execute')
            docker('tags-remove', 'image', 'rm', 'conjet-tag-check:local')
            LAUNCH['daemon_request'](control, proc.pid, 'vm-stop', timeout=60)
            start()
            missing = docker('tags-removed', 'image', 'inspect', 'conjet-tag-check:local', checked=False)
            if missing.returncode == 0:
                raise RuntimeError('removed image tag reappeared after engine restart')
            remaining = json.loads(docker('tags-retained-source', 'image', 'inspect', 'alpine:3.21').stdout)[0]['Id']
            if remaining != original:
                raise RuntimeError('removing an alias lost the original image')
            report['passed'] = True
            return
        if args.postgres_only:
            pinned = 'postgres:16-alpine@sha256:f2f98726820d0342055351c6e9d36e705f5bfffb3dd53ff556325114b08afb6d'
            docker('postgres-pull', 'pull', pinned, timeout=300)
            image = json.loads(docker('postgres-image', 'image', 'inspect', pinned).stdout)[0]
            if 'docker.io/library/postgres@' + pinned.split('@')[1] not in image['RepoDigests']:
                raise RuntimeError('PostgreSQL pull lost the verified index identity')
            docker('postgres-version', 'run', '--rm', '--network', 'none', pinned, 'postgres', '--version')
            docker('postgres-volume', 'volume', 'create', 'cjb-pgdata')
            try:
                docker('postgres-start', 'run', '--detach', '--name', 'cjb-postgres', '--network', 'none',
                       '--mount', 'type=volume,source=cjb-pgdata,target=/var/lib/postgresql/data',
                       '--env', 'POSTGRES_PASSWORD=isolated-test-only', '--env', 'POSTGRES_USER=conjet_fixture',
                       '--env', 'POSTGRES_DB=conjet_fixture', '--health-cmd', 'pg_isready -U conjet_fixture -d conjet_fixture',
                       '--health-timeout', '3s', '--health-interval', '1s', pinned)
                deadline = time.monotonic() + 90
                while True:
                    state = json.loads(docker('postgres-state', 'inspect', 'cjb-postgres').stdout)[0]['State']
                    if state.get('Health', {}).get('Status') == 'healthy':
                        break
                    if not state['Running'] or time.monotonic() >= deadline:
                        docker('postgres-logs', 'logs', 'cjb-postgres', checked=False)
                        raise RuntimeError('PostgreSQL did not become healthy')
                    time.sleep(1)
                docker('postgres-write', 'exec', 'cjb-postgres', 'psql', '-U', 'conjet_fixture', '-d', 'conjet_fixture',
                       '-v', 'ON_ERROR_STOP=1', '-c', "CREATE TABLE conjet_canary(v text); INSERT INTO conjet_canary VALUES ('persisted');")
                docker('postgres-restart', 'restart', 'cjb-postgres')
                deadline = time.monotonic() + 30
                while True:
                    result = docker('postgres-read', 'exec', 'cjb-postgres', 'psql', '-U', 'conjet_fixture', '-d', 'conjet_fixture',
                                    '-Atc', 'SELECT v FROM conjet_canary', checked=False)
                    if result.returncode == 0 and result.stdout.strip() == 'persisted':
                        break
                    if time.monotonic() >= deadline:
                        raise RuntimeError('PostgreSQL canary did not survive restart')
                    time.sleep(1)
                report['passed'] = True
            finally:
                removed = docker('postgres-remove', 'rm', '--force', 'cjb-postgres', checked=False)
                volume_removed = docker('postgres-volume-remove', 'volume', 'rm', 'cjb-pgdata', checked=False)
                if removed.returncode or volume_removed.returncode:
                    report['passed'] = False
                    raise RuntimeError('PostgreSQL container or volume cleanup failed')
            return
        docker('create', 'buildx', 'create', '--driver', 'docker-container', '--name', 'fresh', 'cjb')
        bootstrap = docker('bootstrap', 'buildx', 'inspect', 'fresh', '--bootstrap', checked=False)
        if bootstrap.returncode and not args.expect_baseline:
            docker('bootstrap-worker-log', 'logs', 'buildx_buildkit_fresh0', checked=False)
            docker('bootstrap-worker-state', 'inspect', 'buildx_buildkit_fresh0', '--format', '{{json .State}}', checked=False)
            raise RuntimeError('builder bootstrap failed')
        if args.policy_only or args.runtime_only or args.relay_only:
            fixture = root / 'policy'
            fixture.mkdir()
            copy_guest_probe(core, fixture / 'probe')
            (fixture / 'Dockerfile').write_text('FROM alpine:3.21\nCOPY probe /probe\nCMD ["/probe", "--verify-build-policy"]\n')
            if args.relay_only:
                with (fixture / 'Dockerfile').open('a') as recipe:
                    recipe.write('RUN /probe --verify-build-relay-capacity\n')
            docker('policy-build', 'buildx', 'build', '--builder', 'fresh', '--load',
                   '--tag', 'conjet-policy:local', fixture)
            docker('policy-run', 'run', '--rm', 'conjet-policy:local')
            if args.runtime_only:
                runtime_checks('conjet-policy:local')
            report['passed'] = True
            return
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
        streaming = root / 'streaming'
        shutil.copytree(FIXTURE / 'streaming', streaming)
        copy_guest_probe(core, streaming / 'conjet-policy-probe')
        with (streaming / 'Dockerfile').open('a') as fixture:
            fixture.write("\nRUN : '" + "x" * (12 * 1024) + "'; printf conjet-long-command-ok\n")
        streamed = docker('frontend-streaming-build', 'buildx', 'build', '--builder', 'fresh',
                          '--progress', 'plain', '--load', '--tag', 'conjet-buildx-stream:local',
                          streaming, timeout=240)
        if not any(line.endswith(' conjet-stream-complete') and 'RUN ' not in line
                   for line in (streamed.stdout + streamed.stderr).splitlines()):
            raise RuntimeError('long frontend build did not deliver its final output marker')
        if not any(line.endswith(' conjet-build-policy-ok') and 'RUN ' not in line
                   for line in (streamed.stdout + streamed.stderr).splitlines()):
            raise RuntimeError('build policy probe did not pass')
        if report['calls']['frontend-streaming-build']['elapsed_seconds'] < 60:
            raise RuntimeError('long RUN fixture did not exercise its duration')
        if docker('frontend-streaming-run', 'run', '--rm', 'conjet-buildx-stream:local').stdout != 'first\nsecond\n':
            raise RuntimeError('parallel frontend stages did not retain both results')
        policy = docker('ordinary-container-policy', 'run', '--rm', 'conjet-buildx-stream:local', '/probe', '--verify-build-policy')
        if policy.stdout.strip() != 'conjet-build-policy-ok':
            raise RuntimeError('ordinary Docker container policy probe failed')
        dropped = docker('ordinary-drop-all', 'run', '--rm', '--cap-drop', 'ALL',
                         'conjet-buildx-stream:local', 'sh', '-c', "awk '/^CapEff:/ {print $2}' /proc/self/status")
        if dropped.stdout.strip() != '0000000000000000':
            raise RuntimeError('CapDrop ALL did not remove the default capabilities')
        runtime_checks('conjet-buildx-stream:local')
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
        (cancel / 'Dockerfile').write_text(
            'FROM alpine:3.21\nRUN echo conjet-cancel-recovered > /recovered\n')
        docker('cancel-recovery-build', 'buildx', 'build', '--builder', 'fresh', '--load',
               '--tag', 'conjet-buildx-recovery:local', cancel)
        recovered = docker('cancel-recovery-run', 'run', '--rm',
                           'conjet-buildx-recovery:local', 'cat', '/recovered')
        if recovered.stdout != 'conjet-cancel-recovered\n':
            raise RuntimeError('a fresh RUN did not recover after cancellation on the same engine')

        LAUNCH['daemon_request'](control, proc.pid, 'vm-stop', timeout=60)
        start()
        docker('restart-bootstrap', 'buildx', 'inspect', 'fresh', '--bootstrap')
        docker('restart-build', *compose, 'build', '--builder', 'fresh', **bake)
        if docker('restart-run', *compose, 'run', '--rm', '-T', 'smoke').stdout != 'conjet-buildx-ok\n':
            raise RuntimeError('Compose run failed after private runtime restart')
        docker('docker-buildkit-build', 'build', '--builder', 'fresh', '--load',
               '--tag', 'conjet-docker-buildkit:local', FIXTURE / 'smoke')
        if docker('docker-buildkit-run', 'run', '--rm', 'conjet-docker-buildkit:local').stdout != 'conjet-buildx-ok\n':
            raise RuntimeError('Docker BuildKit build returned unexpected output')
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
        ready_path = home / 'logs/native-boot.jsonl'
        if ready_path.is_file():
            try:
                ready = json.loads(ready_path.read_text().splitlines()[-1])
                session = Path(ready['session'])
                if session.parent != home / 'run' or LAUNCH['processes']().get(ready['pid']) != core:
                    raise RuntimeError('diagnostic session ownership changed')
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as channel:
                    channel.settimeout(3)
                    channel.connect(str(session / 'memory-control.sock'))
                    if channel.getsockopt(0, 2) != ready['pid']:
                        raise RuntimeError('diagnostic memory controller ownership changed')
                    channel.sendall(b'{"command":"metrics"}\n')
                    with channel.makefile('rb') as stream:
                        report['final_memory_metrics'] = json.loads(stream.readline(65536))
                call('final-native-status', [core, 'native', '--experimental', 'status', '--session', session], checked=False)
            except (OSError, ValueError, KeyError, RuntimeError) as error:
                report['diagnostic_error'] = str(error)
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
    parser.add_argument('--memory-mib', type=int, default=2048, choices=range(512, 8193))
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--expect-baseline', action='store_true')
    mode.add_argument('--identity-only', action='store_true')
    mode.add_argument('--direct-egress-ip', type=public_ipv4)
    mode.add_argument('--compatibility-profile', choices=('single-host', 'swarm', 'advanced', 'all'))
    mode.add_argument('--memory-only', action='store_true')
    mode.add_argument('--policy-only', action='store_true')
    mode.add_argument('--runtime-only', action='store_true')
    mode.add_argument('--relay-only', action='store_true')
    mode.add_argument('--postgres-only', action='store_true')
    mode.add_argument('--tags-only', action='store_true')
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
    return int(args.compatibility_profile is not None and not report['passed'])


if __name__ == '__main__':
    raise SystemExit(main())
