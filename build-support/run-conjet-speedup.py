#!/usr/bin/env python3
"""Run the isolated Conjet native Docker candidate in the foreground."""
import argparse
from contextlib import ExitStack
import errno
import fcntl
import hashlib
import json
import os
import re
import runpy
import select
import shutil
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path

SSD = Path('/Volumes/ExternalSSD')
SCRATCH = SSD / 'dev_workspace/tmp'
REPO = Path(__file__).resolve().parents[1]
CONTEXT = 'conjet-speedup'
DOCKER = Path('/opt/homebrew/bin/docker')
VOLUME_DIAGNOSTICS = ('volume-disk', 'mounted-volume', 'compose', 'build-snapshot', 'build-bundle')
CORE_DIAGNOSTICS = ('dynamic-memory', 'dynamic-pressure', 'admission-trace', 'pending-watch',
                    'resources', 'sustained-service', 'copy', *VOLUME_DIAGNOSTICS)


class SessionInterrupted(KeyboardInterrupt):
    def __init__(self, signum):
        super().__init__(signal.Signals(signum).name)
        self.signum = signum


def run(args, *, env=None, timeout=30):
    result = subprocess.run(args, env=env, timeout=timeout, check=False,
                            text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(f'{args[0]} exited {result.returncode}: {result.stderr.strip()}')
    return result.stdout.strip()


def import_assets(args, env):
    with subprocess.Popen(args, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          text=True) as proc:
        try:
            _, stderr = proc.communicate(timeout=600)
        except (KeyboardInterrupt, subprocess.TimeoutExpired):
            if proc.poll() is None:
                # Swift can launch gzip in a separate process group during import.
                # Freeze the CLI so it cannot spawn more children during cleanup.
                proc.send_signal(signal.SIGSTOP)
                try:
                    for row in run(['/bin/ps', '-axo', 'pid=,ppid=']).splitlines():
                        child, parent = map(int, row.split())
                        if parent == proc.pid:
                            try:
                                os.kill(child, signal.SIGKILL)
                            except ProcessLookupError:
                                pass
                finally:
                    proc.kill()
                    proc.wait(timeout=10)
            raise
        if proc.returncode:
            raise RuntimeError(f'Core asset import exited {proc.returncode}: {stderr.strip()}')


def processes():
    lines = run(['/bin/ps', '-axo', 'pid=,comm=']).splitlines()
    return {int(pid): Path(path).resolve() for pid, path in
            (line.strip().split(maxsplit=1) for line in lines)}


def fingerprint(path):
    if path.is_symlink():
        return {'symlink': os.readlink(path)}
    if path.is_file():
        with path.open('rb') as stream:
            return {'sha256': hashlib.file_digest(stream, 'sha256').hexdigest()}
    if path.is_socket():
        info = path.stat()
        return {'device': info.st_dev, 'inode': info.st_ino}
    return None


def production():
    home = Path.home()
    config = home / '.docker'
    files = [config / 'config.json', home / '.ssh/config',
             home / 'Library/Application Support/Conjet/runtime-environment.json',
             Path('/var/run/docker.sock'), home / '.docker/run/docker.sock']
    for folder, pattern in [(config / 'contexts/meta', '*/meta.json'),
                            (config / 'buildx', '*'),
                            (home / 'Library/LaunchAgents', '*.plist'),
                            (Path('/etc/resolver'), '*')]:
        files.extend(sorted(folder.glob(pattern)))
    prefix = [DOCKER, '--config', config]
    env = {'PATH': '/usr/bin:/bin', 'HOME': str(home)}
    current = run(prefix + ['context', 'show'], env=env)
    endpoint = run(prefix + ['context', 'inspect', current,
                              '--format', '{{.Endpoints.docker.Host}}'], env=env)
    if not endpoint.startswith('unix://'):
        raise RuntimeError('expected a local production Docker endpoint')
    endpoint_path = Path(endpoint.removeprefix('unix://'))
    if not endpoint_path.is_absolute():
        raise RuntimeError('expected an absolute production Docker socket')
    runtime = {pid: str(path) for pid, path in processes().items()
               if path.name in ('Conjet', 'conjetd', 'Conjet Core', 'conjet-network')}
    files.append(endpoint_path)
    server = None
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as probe:
        probe.settimeout(1)
        try:
            probe.connect(str(endpoint_path))
        except OSError as error:
            if runtime or error.errno not in (errno.ENOENT, errno.ECONNREFUSED):
                raise
        else:
            server = json.loads(run(prefix + ['--host', endpoint, 'version',
                                              '--format', '{{json .Server}}'], env=env))
    return {'current_context': current, 'endpoint': endpoint, 'server': server,
            'processes': runtime, 'files': {str(path): fingerprint(path) for path in files}}


def daemon_request(endpoint, pid, command, timeout=3):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(timeout)
        client.connect(str(endpoint))
        # Darwin LOCAL_PEERPID. Authenticate each connection before sending a command.
        peer = client.getsockopt(0, 2)
        if peer != pid:
            raise RuntimeError(f'unexpected daemon peer PID {peer}, expected {pid}')
        request = {'command': command, 'parameters': {}, 'arguments': []}
        client.sendall(json.dumps(request).encode() + b'\n')
        with client.makefile('rb') as stream:
            response = json.loads(stream.readline(1024 * 1024))
    if not response.get('ok'):
        raise RuntimeError(response.get('message', f'{command} failed'))
    return response


def stage(source, destination):
    source = source.resolve(strict=True)
    if not source.is_relative_to(SCRATCH) or not source.is_file() or not os.access(source, os.X_OK):
        raise RuntimeError(f'expected an executable built under {SCRATCH}: {source}')
    shutil.copy2(source, destination)
    return fingerprint(destination)['sha256']


def vm_paths(manifest, profile, endpoint):
    if manifest['dockerSocketPath'] != str(endpoint):
        raise RuntimeError('guest Docker endpoint differs from the reserved endpoint')
    paths = {}
    for key, value in manifest.items():
        if key.endswith('Path') and value:
            path = Path(value)
            if not path.is_absolute() or not path.resolve().is_relative_to(profile):
                raise RuntimeError(f'VM asset outside isolated profile: {key}')
            paths[key] = str(path)
    return paths


def stop_owned(proc, endpoint, binaries, evidence):
    if proc is not None and proc.poll() is None:
        try:
            daemon_request(endpoint, proc.pid, 'stop', timeout=30)
            # Wake accept() so the daemon can observe its shutdown flag.
            try:
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as wake:
                    wake.settimeout(1)
                    wake.connect(str(endpoint))
            except (FileNotFoundError, ConnectionRefusedError):
                pass
            proc.wait(timeout=10)
        except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
            evidence['graceful_stop_error'] = str(error)
            if proc.poll() is None:
                proc.kill()
                proc.wait(timeout=10)
    # Each executable path is unique to this run, even if a child reparented.
    remaining = {pid: path for pid, path in processes().items()
                 if path.parent == binaries}
    if remaining:
        evidence['forced_cleanup'] = {pid: str(path) for pid, path in remaining.items()}
        for pid, path in remaining.items():
            if processes().get(pid) == path:
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
        deadline = time.monotonic() + 5
        while any(path.parent == binaries for path in processes().values()):
            if time.monotonic() >= deadline:
                raise RuntimeError('staged processes remain after cleanup')
            time.sleep(0.1)


def session(args, root):
    runtime = root / 'h'
    profile = runtime / 'profiles/speedup'
    sockets = profile / 'run'
    daemon_socket = sockets / 'conjetd.sock'
    docker_socket = sockets / 'docker.sock'
    if max(len(os.fsencode(endpoint)) for endpoint in (daemon_socket, docker_socket)) >= 104:
        raise RuntimeError('session path exceeds the macOS Unix socket limit')
    binaries = root / 'bin'
    docker_config = root / 'docker'
    for path in (binaries, sockets, docker_config, root / 'tmp'):
        path.mkdir(parents=True, mode=0o700)
    (profile / 'config.toml').write_text(
        '[vm]\ncpus = 2\nmemory_mib = 2048\nbackend = "hvf-experimental"\n'
        'enable_host_mounts = false\nenable_removable_host_mounts = false\n'
        '[ssh]\nenabled = false\nallow_tcp_fallback = false\n'
        '[network]\negress_mode = "host"\n'
    )
    cli, daemon, core, network = [binaries / name for name in
                                  ('conjet', 'conjetd', 'Conjet Core', 'conjet-network')]
    hashes = {target.name: stage(source, target) for source, target in
              zip((args.swift_bin / 'conjet', args.swift_bin / 'conjetd',
                   args.core, args.network_helper), (cli, daemon, core, network))}
    (binaries / 'docker').symlink_to(DOCKER.resolve(strict=True))
    env = {
        'HOME': str(root), 'PATH': f'{binaries}:/usr/bin:/bin', 'TMPDIR': str(root / 'tmp'),
        'DOCKER_CONFIG': str(docker_config), 'CONJET_HOME': str(runtime),
        'CONJET_PROFILE': 'speedup', 'CONJET_CORE_VMM_PATH': str(core),
        'CONJET_NETWORK_HELPER_PATH': str(network), 'CONJET_DISABLE_MENU_BAR_APP': '1',
        'CONJET_DISABLE_BACKGROUND_SERVICE_REGISTRATION': '1',
    }
    if args.retained_trace:
        env['CONJET_DOCKER_TRANSPORT_TRACE'] = '1'
    if args.retained_event_wake:
        env['CONJET_DOCKER_EVENT_WAKE'] = '1'
    before = production()
    if before['endpoint'] == f'unix://{docker_socket}':
        raise RuntimeError('candidate overlaps production Docker')
    evidence = {'revision': run(['/usr/bin/git', '-C', REPO, 'rev-parse', 'HEAD']),
                'retained_event_wake': args.retained_event_wake,
                'tracked_diff_sha256': hashlib.sha256(
                    run(['/usr/bin/git', '-C', REPO, 'diff', '--binary', 'HEAD']).encode()
                ).hexdigest(),
                'fixture_image': args.image,
                'binary_sha256': hashes, 'root': str(root), 'context': CONTEXT,
                'production_before': before, 'load_before': os.getloadavg(),
                'cpus': 2, 'memory_mib': 2048, 'passed': False}
    proc = None
    try:
        asset_dir = profile / 'state/vm'
        fetch_args = [cli, 'vm', 'fetch-conjet-core', '--json']
        if args.core_assets:
            asset_dir.mkdir(parents=True)
            for key, suffix in [('image', '-docker.raw.gz'), ('kernel', '-Image')]:
                files = list(args.core_assets.glob(f'conjet-core-v*{suffix}'))
                if len(files) != 1:
                    raise RuntimeError(f'expected one cached release {key}')
                source = files[0]
                checksum = Path(f'{source}.sha512sum')
                sidecar = Path(f'{source}.json')
                for asset in (source, checksum, sidecar):
                    if asset.resolve(strict=True) != asset or not asset.is_file():
                        raise RuntimeError(f'expected a regular release file: {asset}')
                    shutil.copy2(asset, asset_dir / asset.name)
                with (asset_dir / source.name).open('rb') as stream:
                    digest = hashlib.file_digest(stream, 'sha512').hexdigest()
                if digest != checksum.read_text().split()[0]:
                    raise RuntimeError(f'cached release checksum mismatch: {source}')
                fetch_args += [f'--{key}', asset_dir / source.name]
        import_assets(fetch_args, env)
        manifest = json.loads((asset_dir / 'manifest.json').read_text())
        evidence['vm_paths'] = vm_paths(manifest, profile, docker_socket)
        with (root / 'daemon.stderr.log').open('w') as log:
            proc = subprocess.Popen([daemon, '--serve'], env=env, stdout=log, stderr=log)
        deadline = time.monotonic() + 10
        while not daemon_socket.is_socket():
            if proc.poll() is not None or time.monotonic() >= deadline:
                raise RuntimeError('staged daemon did not bind its private socket')
            time.sleep(0.1)
        daemon_request(daemon_socket, proc.pid, 'ping')
        if processes().get(proc.pid) != daemon:
            raise RuntimeError('unexpected daemon executable')
        output = run([cli, 'vm', 'start', '--wait-docker', '--json'], env=env, timeout=900)
        (root / 'vm-start.json').write_text(output + '\n')
        manifest = json.loads((profile / 'state/vm/manifest.json').read_text())
        evidence['vm_paths'] = vm_paths(manifest, profile, docker_socket)
        live = processes()
        if live.get(proc.pid) != daemon or core not in live.values() or network not in live.values():
            raise RuntimeError('staged daemon, VMM, or network helper missing')
        evidence['candidate_processes'] = {pid: str(path) for pid, path in live.items()
                                           if path.parent == binaries}
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.settimeout(3)
            client.connect(str(docker_socket))
            docker_peer = client.getsockopt(0, 2)
        if live.get(docker_peer) != core:
            raise RuntimeError(f'Docker is not served by the staged VMM: PID {docker_peer}')
        evidence['docker_peer_pid'] = docker_peer
        prefix = [DOCKER, '--config', docker_config]
        expected = f'unix://{docker_socket}'
        actual = run(prefix + ['context', 'inspect', CONTEXT,
                               '--format', '{{.Endpoints.docker.Host}}'], env=env)
        if actual != expected or not docker_socket.is_socket():
            raise RuntimeError(f'private Docker endpoint mismatch: {actual}')
        prefix += ['--context', CONTEXT]
        evidence['docker_endpoint'] = actual
        evidence['docker_server'] = json.loads(run(prefix + ['version', '--format', '{{json .Server}}'], env=env))
        evidence['smoke'] = run(prefix + ['run', '--rm', '--network', 'none',
                                          args.image, 'echo', 'conjet-speedup-ok'], env=env, timeout=180)
        if evidence['smoke'] != 'conjet-speedup-ok':
            raise RuntimeError('unexpected fixture output')
        print(evidence['smoke'], flush=True)
        if args.retained_trace_output:
            profile = runpy.run_path(str(REPO / 'benchmarks/retained-docker-trace.py'))
            profile['collect'](docker_socket, docker_config, docker_peer, DOCKER,
                               args.retained_trace_output, args.benchmark_scenario,
                               args.benchmark_archive, args.retained_trace,
                               args.retained_trace and not args.retained_host_only, args.benchmark_samples)
        if args.comparison_output:
            comparison = runpy.run_path(str(REPO / 'benchmarks/docker-comparison.py'))
            comparison['run_suite']('conjet', docker_socket, docker_config, docker_peer,
                                    args.comparison_output, args.comparison_mode, evidence['vm_paths'],
                                    args.comparison_group, args.comparison_build_bases)
        if args.benchmark_output:
            benchmark = runpy.run_path(str(REPO / 'benchmarks/fresh-lifecycle.py'))
            benchmark['main']([
                '--engine', 'conjet', '--socket', str(docker_socket), '--config', str(docker_config),
                '--peer-pid', str(docker_peer), '--docker', str(DOCKER),
                '--output', str(args.benchmark_output), '--samples', str(args.benchmark_samples),
                *(['--scenario', str(args.benchmark_scenario), '--archive', str(args.benchmark_archive)]
                  if args.benchmark_scenario else []),
            ])
            evidence['benchmark_output'] = str(args.benchmark_output)
        if args.hold_seconds:
            time.sleep(args.hold_seconds)
        evidence['passed'] = True
    except (Exception, KeyboardInterrupt) as error:
        evidence['error'] = str(error) or type(error).__name__
        raise
    finally:
        try:
            stop_owned(proc, daemon_socket, binaries, evidence)
            evidence['remaining_sockets'] = [str(path) for path in sockets.iterdir()
                                             if stat.S_ISSOCK(path.lstat().st_mode)]
            for path in evidence['remaining_sockets']:
                Path(path).unlink()
            evidence['production_after'] = production()
            evidence['load_after'] = os.getloadavg()
            evidence['production_unchanged'] = evidence['production_after'] == before
            evidence['passed'] &= (evidence['production_unchanged']
                                   and 'graceful_stop_error' not in evidence
                                   and 'forced_cleanup' not in evidence)
        except Exception as error:
            evidence['cleanup_error'] = str(error)
            evidence['passed'] = False
            raise
        finally:
            (root / 'session.json').write_text(json.dumps(evidence, indent=2) + '\n')
    if not evidence['passed']:
        raise RuntimeError('session cleanup or production observation failed')


def await_ready(process, timeout):
    if select.select([process.stdout], [], [], timeout)[0]:
        line = process.stdout.readline()
        if line:
            return json.loads(line)
    raise RuntimeError('owned candidate process did not report readiness')


def stop_child(process, timeout):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
            raise RuntimeError('candidate process required forced cleanup')
    return process.returncode


def audit_native_boot(directory, guest, helpers=(), markers=()):
    """Read the boot archive manifest without recording its private payloads."""
    root = 'etc/conjet/oci-root'
    allowed_top_level = {
        'dev', 'dev/console', 'dev/null', 'dev/zero', 'proc', 'sys', 'run', 'run/conjet',
        'etc', 'etc/conjet', 'init', 'etc/conjet/launch.key',
        'etc/conjet/native-oci-image', 'etc/conjet/native-oci-hardlinks.json',
        root,
    }
    entries = set()
    expected_executables = {'init': guest, **dict(zip(
        ('etc/conjet/conjet-memd', 'etc/conjet/conjet-reclaimd'), helpers))}
    observed_executables = {}
    allowed_top_level.update(expected_executables)
    allowed_top_level.update(markers)
    with (directory / 'init.cpio').open('rb') as archive:
        while True:
            header = archive.read(110)
            if len(header) != 110 or header[:6] != b'070701':
                raise RuntimeError('invalid native boot archive header')
            size = int(header[54:62], 16)
            name_size = int(header[94:102], 16)
            if not 1 <= name_size <= 4096:
                raise RuntimeError('invalid native boot entry name size')
            encoded = archive.read(name_size)
            if len(encoded) != name_size or not encoded.endswith(b'\0'):
                raise RuntimeError('invalid native boot entry name')
            name = encoded[:-1].decode()
            archive.seek(-archive.tell() % 4, os.SEEK_CUR)
            if name == 'TRAILER!!!':
                if size or archive.read(1):
                    raise RuntimeError('unexpected bytes after native boot archive')
                break
            if (name in entries or {'..', '.', ''}.intersection(name.split('/'))
                    or name.split('/')[-1] in {'dockerd', 'containerd', 'containerd-shim',
                                               'containerd-shim-runc-v2', 'runc'}
                    or not (name in allowed_top_level or name.startswith(root + '/'))):
                raise RuntimeError(f'unexpected native boot entry {name!r}')
            entries.add(name)
            if name in expected_executables:
                source = expected_executables[name]
                if size != source.stat().st_size or size > 4 * 1024 * 1024:
                    raise RuntimeError(f'unexpected executable size for {name}')
                observed_executables[name] = hashlib.sha256(archive.read(size)).hexdigest()
            else:
                archive.seek(size, os.SEEK_CUR)
            archive.seek(-archive.tell() % 4, os.SEEK_CUR)
    if (observed_executables != {name: fingerprint(source)['sha256']
                                for name, source in expected_executables.items()}
            or root not in entries
            or not set(markers).issubset(entries)):
        raise RuntimeError('native boot archive does not match the trusted guest and OCI fixture')
    disk = directory / 'blank.raw'
    if disk.stat().st_size != 16 * 1024 * 1024:
        raise RuntimeError('unexpected native boot data disk')
    with disk.open('rb') as source:
        if any(chunk.strip(b'\0') for chunk in iter(lambda: source.read(1024 * 1024), b'')):
            raise RuntimeError('unexpected data in native boot block device')
    return {'supervisor_sha256': observed_executables['init'], 'archive_entry_count': len(entries),
            'supervisor_executables': observed_executables,
            'supervisor_root_entries': sorted(entries & allowed_top_level),
            'blank_block_bytes': disk.stat().st_size}


def native_session(args, root):
    before = production()
    output = args.native_evidence
    output.mkdir(mode=0o700)
    adapter = REPO / 'build-support/conjet-native-docker.py'
    python_owner = args.docker_owner == 'python'
    cli = args.swift_bin / 'conjet'
    config = root / 'docker'
    config.mkdir(mode=0o700)
    endpoint = root / 'docker.sock'
    env = {'PATH': '/usr/bin:/bin', 'HOME': str(root), 'DOCKER_CONFIG': str(config),
           'TMPDIR': str(root), 'CONJET_CORE_VMM_PATH': str(args.core)}
    docker = [DOCKER, '--config', config]
    host = f'unix://{endpoint}'
    report = {'passed': False, 'context': CONTEXT, 'endpoint': host, 'production_before': before,
              'revision': run(['/usr/bin/git', '-C', REPO, 'rev-parse', 'HEAD']),
              'load_before': os.getloadavg()}
    vm = bridge = directory = None
    registry_scope = ExitStack()
    registry = None
    helpers = (args.native_memd, args.native_reclaimd) if args.native_memd else ()
    pressure_fixture = args.diagnostics == 'dynamic-pressure'
    volume_disk = args.native_volume_disk
    dynamic_memory = bool(helpers) and args.diagnostics != 'memory-telemetry'
    markers = []
    try:
        if host == before['endpoint']:
            raise RuntimeError('candidate endpoint overlaps production')
        assets = [cli, args.core, args.native_kernel, args.native_guest, args.native_package,
                  args.native_receipt, DOCKER, *helpers]
        if python_owner:
            assets.append(adapter)
        if args.native_compose_cli:
            assets.append(args.native_compose_cli)
        report['binary_sha256'] = {str(path): fingerprint(path.resolve(strict=True))['sha256'] for path in assets}
        kernel_hash = args.native_kernel.with_name(args.native_kernel.name + '.sha512sum').read_text().split()[0]
        vm_command = [cli, 'native', 'docker-boot', '--scratch', SCRATCH,
                      '--kernel', args.native_kernel, '--kernel-sha512', kernel_hash,
                      '--guest-init', args.native_guest, '--oci-package', args.native_package,
                      '--sha256', report['binary_sha256'][str(args.native_package)]]
        if helpers:
            vm_command += ['--guest-memd', helpers[0], '--guest-reclaimd', helpers[1]]
        if dynamic_memory:
            vm_command.append('--core-dynamic-memory')
            markers.append('etc/conjet/native-core-admission')
        if args.native_bind_storage:
            bind_root = output / 'matrix'
            bind_root.mkdir(mode=0o700)
            vm_command.append('--bind-filesystem')
            markers.append('dev/fuse')
        if args.diagnostics == 'admission-trace' or args.native_latency_trace:
            vm_command.append('--trace-core-admission')
            markers.append('etc/conjet/native-core-latency-trace')
        if args.native_admission_wake:
            vm_command += ['--core-admission-wake', args.native_admission_wake]
        if args.native_discovery_ms:
            vm_command += ['--core-discovery-ms', args.native_discovery_ms]
        if args.native_discovery_mode:
            vm_command += ['--core-discovery-mode', args.native_discovery_mode]
        if args.native_evaluation_mode:
            vm_command += ['--core-evaluation-mode', args.native_evaluation_mode]
        if pressure_fixture:
            vm_command.append('--core-pressure-fixture')
            markers.append('etc/conjet/native-core-pressure-fixture')
        if volume_disk:
            vm_command += ['--volume-disk', volume_disk]
            markers.append('etc/conjet/native-volume')
            info = volume_disk.stat()
            report['volume_disk'] = {'path': str(volume_disk), 'device': info.st_dev, 'inode': info.st_ino}
        if args.diagnostics in ('build-snapshot', 'build-bundle'):
            vm_command.append('--build-snapshot-disk')
            markers.append('etc/conjet/native-build-snapshot')
        if args.native_disk_images:
            vm_command.append('--disk-image-store')
            markers.append('etc/conjet/native-image-store-disk')
        report['vm_command'] = list(map(str, vm_command))
        with (output / 'vmm.stderr').open('w') as log:
            vm = subprocess.Popen(vm_command, env=env, stdin=subprocess.DEVNULL,
                                  stdout=subprocess.PIPE, stderr=log, text=True)
        ready = await_ready(vm, 30)
        candidate = Path(ready['session'])
        if (ready['pid'] != vm.pid or processes().get(vm.pid) != args.core
                or candidate.parent != SCRATCH or not candidate.name.startswith('cn-')
                or candidate.is_symlink() or candidate.stat().st_mode & 0o077):
            raise RuntimeError('unexpected native VM ownership')
        directory = candidate
        report['vmm_pid'] = vm.pid
        report['native_session'] = str(directory)
        if dynamic_memory or args.diagnostics in ('control', 'memory-telemetry'):
            report['native_boot_audit'] = audit_native_boot(
                directory, args.native_guest, helpers, markers)
        if args.diagnostics == 'oci-import':
            diagnostic = runpy.run_path(str(REPO / 'benchmarks/native-oci-live-install.py'))
            config_digest = json.loads(args.import_receipt.read_text())['config_digest']
            boot = diagnostic['preflight'](directory, vm.pid, config_digest, output)
            package_hash = fingerprint(args.import_package)['sha256']
            install = [args.core, 'native', 'docker-install', '--session', directory,
                       '--package', args.import_package, '--sha256', package_hash]
            if args.import_disk_package:
                install.append('--disk-package')
            report['install_command'] = list(map(str, install))
            report['install'] = json.loads(run(install, env=env, timeout=195 if args.import_disk_package else 60))
            if report['install']['boot_id'] != boot:
                raise RuntimeError('image was installed into a different boot')
            diagnostic['postflight'](directory, vm.pid, config_digest, boot, output)
            diagnostic['verify_guest_overlap'](directory, vm.pid, config_digest, boot, output)
            diagnostic['verify_live_output'](directory, vm.pid, config_digest, boot, output)
            diagnostic['verify_guest_exec'](directory, vm.pid, config_digest, boot, output)
        run(docker + ['context', 'create', CONTEXT, '--docker', f'host={host}'], env=env)
        if run(docker + ['context', 'inspect', CONTEXT, '--format', '{{.Endpoints.docker.Host}}'], env=env) != host:
            raise RuntimeError('private native Docker context endpoint mismatch')
        docker += ['--context', CONTEXT]
        bridge_command = [sys.executable, adapter] if python_owner else [args.core, 'native', 'docker-serve']
        bridge_command += ['--native-session', directory, '--receipt', args.import_receipt or args.native_receipt,
                           '--image', args.image, '--socket', endpoint]
        if args.native_bind_storage:
            bridge_command += ['--bind-root', bind_root]
        if not python_owner:
            store = root / 'image-store'
            store.mkdir(mode=0o700)
            if store.resolve(strict=True) != store or store.stat().st_dev != SCRATCH.stat().st_dev:
                raise RuntimeError('native image store does not have the expected ExternalSSD backing')
            bridge_command += ['--image-store', store]
            report['image_store'] = str(store)
            if args.native_boot_layout:
                bridge_command += ['--boot-layout', args.native_boot_layout]
            if args.native_public_images:
                bridge_command.append('--pinned-public-registry')
            for layout in args.offline_oci_layout:
                bridge_command += ['--seed-layout', layout]
            if args.offline_oci_layout:
                report['offline_oci_layouts'] = [str(layout) for layout in args.offline_oci_layout]
        if args.diagnostics == 'registry':
            registry_test = runpy.run_path(str(REPO / 'benchmarks/native-docker-registry.py'))
            registry = registry_scope.enter_context(registry_test['Registry'](args.registry_fixtures).serve())
            bridge_command += ['--registry', registry.authority]
            report['registry'] = registry.authority
        if args.diagnostics == 'trace':
            bridge_command += ['--trace', output / 'adapter-trace.json']
        if args.diagnostics in ('compose', 'registry'):
            bridge_command.append('--trace-requests')
        report['adapter_command'] = list(map(str, bridge_command))
        report['docker_owner'] = args.docker_owner
        with (output / 'adapter.stderr').open('w') as log:
            bridge = subprocess.Popen(bridge_command, env=env, stdin=subprocess.DEVNULL,
                                      stdout=subprocess.PIPE, stderr=log, text=True)
        ready = await_ready(bridge, 10)
        if not python_owner and processes().get(bridge.pid) != args.core:
            raise RuntimeError('unexpected Rust Docker owner executable')
        with socket.socket(socket.AF_UNIX) as probe:
            probe.settimeout(3)
            probe.connect(str(endpoint))
            if (probe.getsockopt(0, 2) != bridge.pid or ready['socket'] != str(endpoint)
                    or ready['backend'] != 'jetstream-native-oci'):
                raise RuntimeError('unexpected private Docker endpoint ownership')
        report['adapter_pid'] = bridge.pid
        version = json.loads(run(docker + ['version', '--format', '{{json .Server}}'], env=env))
        if version['Platform']['Name'] != 'Conjet Native OCI':
            raise RuntimeError('native endpoint reported the wrong backend')
        report['backend'] = version['Platform']['Name']
        print(f'Native Docker ready: {host}', flush=True)
        if args.diagnostics:
            if registry is not None:
                registry_test['collect'](endpoint, bridge.pid, docker, env, output, registry, store)
            elif args.diagnostics == 'concurrency':
                diagnostic = runpy.run_path(str(REPO / 'benchmarks/native-docker-concurrency.py'))
                diagnostic['collect'](endpoint, bridge.pid, docker, env, output, directory, vm.pid)
            elif args.diagnostics == 'concurrency-loss':
                diagnostic = runpy.run_path(str(REPO / 'benchmarks/native-docker-concurrency.py'))
                diagnostic['collect_loss'](endpoint, bridge.pid, output, directory, vm.pid)
            elif args.diagnostics == 'streaming':
                diagnostic = runpy.run_path(str(REPO / 'benchmarks/native-docker-streaming.py'))
                diagnostic['collect'](endpoint, bridge.pid, docker, env, output)
            elif args.diagnostics == 'exec':
                diagnostic = runpy.run_path(str(REPO / 'benchmarks/native-docker-exec.py'))
                diagnostic['collect'](endpoint, bridge.pid, docker, env, output, directory, vm.pid)
            elif args.diagnostics == 'copy':
                diagnostic = runpy.run_path(str(REPO / 'benchmarks/native-docker-copy.py'))
                diagnostic['collect'](endpoint, bridge.pid, docker, env, output, directory, vm.pid)
            elif args.diagnostics == 'credentials':
                diagnostic = runpy.run_path(str(REPO / 'benchmarks/native-docker-credentials.py'))
                diagnostic['collect'](endpoint, bridge.pid, docker, env, output)
            elif args.diagnostics == 'resources':
                diagnostic = runpy.run_path(str(REPO / 'benchmarks/native-docker-resources.py'))
                diagnostic['collect'](endpoint, bridge.pid, docker, env, output, directory, vm.pid)
            elif args.diagnostics == 'sustained-service':
                diagnostic = runpy.run_path(str(REPO / 'benchmarks/native-docker-resources.py'))
                diagnostic['collect_sustained'](endpoint, bridge.pid, docker, env, output, directory, vm.pid)
            elif args.diagnostics == 'archive':
                diagnostic = runpy.run_path(str(REPO / 'benchmarks/native-docker-archive.py'))
                diagnostic['collect'](endpoint, bridge.pid, docker, env, output, store,
                                      node_roundtrip=args.native_disk_images and args.native_public_images)
            elif args.diagnostics == 'public-images':
                diagnostic = runpy.run_path(str(REPO / 'benchmarks/native-public-images.py'))
                diagnostic['collect'](endpoint, bridge.pid, docker, env, output,
                                      disk_store=store if args.native_disk_images else None)
            elif args.diagnostics == 'compatibility-preflight':
                diagnostic = runpy.run_path(str(REPO / 'benchmarks/native-compatibility-preflight.py'))
                diagnostic['collect'](endpoint, bridge.pid, docker, env, output, args.compatibility_suite,
                                      lifecycle_group=args.compatibility_lifecycle_group)
            elif args.diagnostics == 'guest-bridge':
                diagnostic = runpy.run_path(str(REPO / 'benchmarks/native-oci-bridge.py'))
                diagnostic['collect'](directory, vm.pid, output)
            elif args.diagnostics == 'docker-network':
                diagnostic = runpy.run_path(str(REPO / 'benchmarks/native-docker-network.py'))
                diagnostic['collect'](endpoint, bridge.pid, docker, env, output, directory, vm.pid,
                                      routed=args.native_routed_bridge)
            elif args.diagnostics == 'tcp-relay':
                diagnostic = runpy.run_path(str(REPO / 'benchmarks/native-tcp-relay.py'))
                diagnostic['collect'](directory, vm.pid, output)
            elif args.diagnostics == 'published-port':
                diagnostic = runpy.run_path(str(REPO / 'benchmarks/native-docker-published-port.py'))
                diagnostic['collect'](endpoint, bridge.pid, docker, env, output, directory, vm.pid)
            elif args.diagnostics in ('memory-telemetry', 'dynamic-memory', 'dynamic-pressure'):
                diagnostic = runpy.run_path(str(REPO / 'benchmarks/native-core-memory.py'))
                if dynamic_memory:
                    diagnostic['check_growth'](
                        endpoint, bridge.pid, directory, vm.pid, output, docker, env, pressure_fixture)
                else:
                    diagnostic['collect'](endpoint, bridge.pid, directory, vm.pid, output)
            elif args.diagnostics == 'volume-disk':
                diagnostic = runpy.run_path(str(REPO / 'benchmarks/native-volume-disk.py'))
                diagnostic['collect'](directory, vm.pid, output, args.volume_phase)
            elif args.diagnostics == 'mounted-volume':
                diagnostic = runpy.run_path(str(REPO / 'benchmarks/native-docker-volumes.py'))
                diagnostic['collect'](endpoint, bridge.pid, directory, vm.pid,
                                      output, args.volume_phase, docker, env, target=args.volume_target or '/data')
            elif args.diagnostics == 'compose':
                diagnostic = runpy.run_path(str(REPO / 'benchmarks/native-docker-compose.py'))
                diagnostic['collect'](endpoint, bridge.pid, output, docker, env, args.native_compose_cli)
            elif args.diagnostics == 'build-snapshot':
                diagnostic = runpy.run_path(str(REPO / 'benchmarks/native-build-snapshot.py'))
                diagnostic['collect'](directory, vm.pid, output)
            elif args.diagnostics == 'build-bundle':
                diagnostic = runpy.run_path(str(REPO / 'benchmarks/native-build-bundle.py'))
                diagnostic['collect'](directory, vm.pid, output)
            elif args.diagnostics == 'pending-watch':
                diagnostic = runpy.run_path(str(REPO / 'benchmarks/native-core-watch.py'))
                diagnostic['collect'](directory, vm.pid, output)
            elif args.diagnostics in ('oci', 'oci-import'):
                oci = runpy.run_path(str(REPO / 'benchmarks/native-oci-two-layer.py'))
                oci['collect'](endpoint, bridge.pid, docker, env, output, args.image)
                if args.diagnostics == 'oci-import':
                    if stop_child(bridge, 45) != 0:
                        raise RuntimeError('Rust Docker owner did not stop before image removal check')
                    diagnostic['verify_removal'](directory, vm.pid, config_digest, boot, output)
            else:
                diagnostic = runpy.run_path(str(REPO / 'benchmarks/native-docker-diagnostic.py'))
                diagnostic['collect'](endpoint, bridge.pid, docker, env, output)
        elif args.matched_output:
            probe = runpy.run_path(str(REPO / 'benchmarks/native-core-memory.py'))['controller_snapshot']
            report['core_memory_before_timing'] = probe(directory, vm.pid)
            bench = runpy.run_path(str(REPO / 'benchmarks/native-docker-comparison.py'))
            bench['measure']('native', endpoint, bridge.pid, docker, env, args.matched_output,
                             args.matched_samples, vm.pid, lane=args.native_latency_lane,
                             latency_trace=args.native_latency_trace)
            report['core_memory_after_timing'] = probe(directory, vm.pid)
            if args.native_latency_idle:
                idle = {'core_before': report['core_memory_after_timing']}
                report['idle_window'] = idle
                def host_activity():
                    return run(['/bin/ps', '-p', f'{vm.pid},{bridge.pid}', '-o', 'pid=,time=,rss='])
                idle['host_before'] = host_activity()
                idle['h0_ns'] = time.clock_gettime_ns(time.CLOCK_MONOTONIC)
                time.sleep(8)
                idle['h1_ns'] = time.clock_gettime_ns(time.CLOCK_MONOTONIC)
                idle['host_after'] = host_activity()
                idle['core_after'] = probe(directory, vm.pid)
        if args.docker_args:
            command = docker + args.docker_args
            child = subprocess.Popen(command, env=env)
            try:
                report['docker_exit'] = child.wait(timeout=120)
            finally:
                stop_child(child, 3)
        elif not args.matched_output and not args.diagnostics:
            smoke = run(docker + ['run', '--rm', '--pull', 'never', '--network', 'none',
                                  '--user', '65532:65532', '--memory', '16m', '--pids-limit', '4',
                                  '--cpus', '0.5', args.image, '/bin/echo', 'conjet-native-ok'], env=env)
            if smoke != 'conjet-native-ok':
                raise RuntimeError('native smoke output mismatch')
            print(smoke, flush=True)
        if args.hold_seconds:
            time.sleep(args.hold_seconds)
        report['passed'] = True
    except BaseException as error:
        report['error'] = str(error) or type(error).__name__
        raise
    finally:
        cleanup = []
        for label, process in [('adapter', bridge), ('vmm', vm)]:
            if process is None:
                continue
            try:
                if label == 'vmm' and directory is not None and process.poll() is None:
                    run([cli, 'native', 'docker-stop', '--session', directory], env=env, timeout=12)
                    process.wait(timeout=12)
                    report['shutdown'] = json.loads(process.stdout.readline())
                    if report['shutdown'].get('guest_cleanup') != 'complete' or report['shutdown'].get('reclaim_failures') != 0:
                        cleanup.append('native VM did not verify guest reclamation')
                if stop_child(process, 45 if label == 'adapter' else 15) != 0:
                    cleanup.append(f'{label} exited {process.returncode}')
            except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
                cleanup.append(f'{label}: {error}')
                try:
                    stop_child(process, 15)
                except (OSError, RuntimeError, subprocess.SubprocessError) as failure:
                    cleanup.append(f'{label}: {failure}')
            finally:
                process.stdout.close()
        report['native_session_removed'] = directory is None or not directory.exists()
        report['adapter_socket_removed'] = not os.path.lexists(endpoint)
        if volume_disk and report.get('volume_disk'):
            try:
                with volume_disk.open('rb') as disk:
                    info = os.fstat(disk.fileno())
                    if (info.st_dev, info.st_ino) != (report['volume_disk']['device'], report['volume_disk']['inode']):
                        raise RuntimeError('native volume disk identity changed')
                    fcntl.flock(disk, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    report['volume_lease_released'] = True
            except (OSError, RuntimeError) as error:
                cleanup.append(f'volume lease: {error}')
        try:
            registry_scope.close()
            if registry is not None:
                report['registry_stopped'] = True
        except RuntimeError as error:
            cleanup.append(str(error))
        report['cleanup_errors'] = cleanup
        try:
            report['production_after'] = production()
            report['production_unchanged'] = report['production_after'] == before
        finally:
            report['passed'] &= (report.get('production_unchanged', False) and not cleanup
                                 and report['native_session_removed'] and report['adapter_socket_removed'])
            report['load_after'] = os.getloadavg()
            (output / 'launcher.json').write_text(json.dumps(report, indent=2) + '\n')
    if not report['passed']:
        raise RuntimeError(f'native candidate did not verify cleanup; see {output}')
    return report.get('docker_exit', 0)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--swift-bin', required=True, type=Path)
    parser.add_argument('--core', required=True, type=Path)
    parser.add_argument('--legacy-baseline', action='store_true', help='explicit historical Docker/containerd lane')
    parser.add_argument('--network-helper', type=Path)
    parser.add_argument('--native-public-images', action='store_true',
                        help='use the frozen Docker Hub image pins in the private native store')
    parser.add_argument('--native-disk-images', action='store_true',
                        help='stage native image transfers on the leased private volume filesystem')
    parser.add_argument('--import-disk-package', action='store_true',
                        help='use the v2 package format for the staged OCI import diagnostic')
    for name in ('native-kernel', 'native-guest', 'native-package', 'native-receipt', 'native-evidence', 'matched-output',
                 'native-memd', 'native-reclaimd', 'native-volume-disk', 'native-compose-cli',
                 'import-package', 'import-receipt', 'registry-fixtures', 'native-boot-layout'):
        parser.add_argument('--' + name, type=Path)
    parser.add_argument('--matched-samples', type=int, choices=range(1, 2001), default=2000, metavar='1..2000')
    parser.add_argument('--diagnostics', choices=('trace', 'control', 'oci', 'oci-import', 'registry',
                                                  'concurrency', 'concurrency-loss', 'streaming', 'exec', 'credentials', 'archive',
                                                  'public-images', 'resources', 'sustained-service', 'copy',
                                                  'guest-bridge', 'docker-network', 'tcp-relay', 'published-port',
                                                  'memory-telemetry', 'dynamic-memory', 'dynamic-pressure',
                                                  'volume-disk', 'mounted-volume', 'admission-trace', 'compose',
                                                  'build-snapshot', 'build-bundle', 'pending-watch', 'compatibility-preflight'),
                        help='run native-only diagnostic canaries')
    parser.add_argument('--compatibility-suite',
                        choices=('lifecycle', 'images', 'registry-service', 'builds', 'compose', 'control',
                                 'storage_network', 'stress'))
    parser.add_argument('--compatibility-lifecycle-group',
                        help='run one complete frozen lifecycle group in its own Core boot')
    parser.add_argument('--native-bind-storage', action='store_true')
    parser.add_argument('--native-routed-bridge', action='store_true')
    parser.add_argument('--offline-oci-layout', type=Path, action='append', default=[])
    parser.add_argument('--docker-owner', choices=('rust', 'python'), default='rust',
                        help='use the Rust owner or the Python A/B reference')
    parser.add_argument('--volume-phase', choices=('create', 'inspect', 'remove'))
    parser.add_argument('--volume-target', choices=('/data', '/dataset', '/var/lib/registry'))
    parser.add_argument('--native-admission-wake', choices=('poll', 'event'))
    parser.add_argument('--native-latency-trace', action='store_true')
    parser.add_argument('--native-latency-lane', choices=('api', 'cli'))
    parser.add_argument('--native-discovery-ms', choices=('30', '5'))
    parser.add_argument('--native-discovery-mode', choices=('poll', 'watch'))
    parser.add_argument('--native-evaluation-mode', choices=('tick', 'wake'))
    parser.add_argument('--native-latency-idle', action='store_true')
    parser.add_argument('--image', default='alpine:3.22')
    parser.add_argument('--comparison-output', type=Path)
    parser.add_argument('--comparison-group')
    parser.add_argument('--comparison-build-bases', type=Path)
    parser.add_argument('--comparison-mode', choices=('preflight', 'pilot', 'probes', 'lifecycle', 'images', 'builds', 'compose', 'control',
                                                         'storage_network', 'stress'), default='preflight')
    parser.add_argument('--benchmark-output', type=Path, help='run the pinned fresh lifecycle benchmark')
    parser.add_argument('--retained-trace-output', type=Path)
    parser.add_argument('--retained-trace', action='store_true')
    parser.add_argument('--retained-event-wake', action='store_true')
    parser.add_argument('--retained-host-only', action='store_true')
    parser.add_argument('--benchmark-samples', type=int, default=100, help='samples per lane and network')
    parser.add_argument('--benchmark-scenario', type=Path, help='use a staged lifecycle scenario')
    parser.add_argument('--benchmark-archive', type=Path, help='load the scenario image into the private runtime')
    parser.add_argument('--core-assets', type=Path, help='reuse verified ExternalSSD release downloads')
    parser.add_argument('--hold-seconds', type=int, choices=range(601), default=0,
                        metavar='0..600', help='keep the verified VM alive briefly for QA')
    parser.add_argument('docker_args', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if bool(args.compatibility_suite) != (args.diagnostics == 'compatibility-preflight'):
        parser.error('select one frozen suite for the native compatibility preflight')
    if args.native_bind_storage and (
            args.compatibility_suite != 'storage_network' or args.docker_owner != 'rust'):
        parser.error('bind storage requires the isolated native storage suite')
    if args.native_routed_bridge and args.diagnostics != 'docker-network':
        parser.error('select the routed bridge only for the network diagnostic')
    if args.offline_oci_layout and (
            args.compatibility_suite not in ('registry-service', 'builds', 'compose', 'storage_network', 'stress')
            or not args.native_public_images or not args.native_disk_images
            or any(layout.resolve(strict=True) != layout or not layout.is_relative_to(SCRATCH)
                   for layout in args.offline_oci_layout)):
        parser.error('offline layouts require frozen native runtime diagnostics and canonical ExternalSSD sources')
    if args.compatibility_lifecycle_group:
        scenarios = json.loads((REPO / 'benchmarks/scenarios/native-compatibility-v1.json').read_text())
        groups = {case['id'].removeprefix('lifecycle/') for group in scenarios['groups']
                  if group['suite'] == 'lifecycle' for case in group['cases']}
        if (args.compatibility_suite != 'lifecycle'
                or args.compatibility_lifecycle_group not in groups):
            parser.error('select a frozen lifecycle group with the lifecycle compatibility suite')
    if args.docker_args[:1] == ['--']:
        args.docker_args.pop(0)
    native_assets = ('native_kernel', 'native_guest', 'native_package', 'native_receipt')
    if (args.matched_output or args.diagnostics in (*CORE_DIAGNOSTICS, 'memory-telemetry',
                                                   'compatibility-preflight', 'archive', 'public-images')
            or args.native_memd or args.native_reclaimd):
        if not (args.native_memd and args.native_reclaimd and args.docker_owner == 'rust'):
            parser.error('native timing and memory canaries require both static Core helpers and the Rust owner')
        native_assets += ('native_memd', 'native_reclaimd')
    if args.native_admission_wake and (not args.native_memd or args.diagnostics == 'memory-telemetry'):
        parser.error('admission wake comparison requires the native Core governor')
    if args.native_latency_lane and not args.matched_output:
        parser.error('latency lane requires matched output')
    if args.native_latency_trace and not (args.native_memd and
            (args.matched_output or args.diagnostics in ('dynamic-memory', 'dynamic-pressure'))):
        parser.error('collect native latency traces only with matched timing or Core memory canaries')
    if args.native_discovery_ms and not args.native_latency_trace:
        parser.error('alternate discovery cadence requires the isolated latency tracer')
    if args.native_discovery_mode and (not args.native_memd or args.diagnostics == 'memory-telemetry'):
        parser.error('pending discovery mode requires the native Core governor')
    if args.native_evaluation_mode and (not args.native_memd or args.diagnostics == 'memory-telemetry'):
        parser.error('evaluation mode requires the native Core governor')
    if args.diagnostics == 'pending-watch' and args.native_discovery_mode != 'poll':
        parser.error('the wire watch probe needs the private watcher slot free')
    if args.native_latency_idle and not (args.matched_output and args.native_latency_trace):
        parser.error('an idle latency window requires matched traced timing')
    if args.native_disk_images and (
            args.diagnostics not in ('archive', 'oci-import', 'public-images', 'compatibility-preflight')
            or args.legacy_baseline or not args.native_memd or args.docker_owner != 'rust'):
        parser.error('the disk image store requires a private native Core image diagnostic')
    if args.diagnostics in VOLUME_DIAGNOSTICS or args.native_disk_images:
        if (not args.native_volume_disk
                or args.native_volume_disk.resolve(strict=True) != args.native_volume_disk):
            parser.error('volume diagnostics require a canonical private disk path')
        if (args.diagnostics in ('volume-disk', 'mounted-volume')) != bool(args.volume_phase):
            parser.error('only volume disk and mount diagnostics require a phase')
        if args.diagnostics == 'mounted-volume' and args.volume_phase == 'remove':
            parser.error('mounted volume diagnostics recover and remove in the inspect phase')
        native_assets += ('native_volume_disk',)
    elif args.native_volume_disk or args.volume_phase:
        parser.error('a private volume disk and phase require volume diagnostics')
    if args.volume_target and args.diagnostics != 'mounted-volume':
        parser.error('select a target only for the owned mounted-volume diagnostic')
    if args.diagnostics == 'compose':
        if not args.native_compose_cli:
            parser.error('Compose diagnostics require the pinned CLI on ExternalSSD')
        native_assets += ('native_compose_cli',)
    elif args.native_compose_cli:
        parser.error('a Compose CLI requires Compose diagnostics')
    if args.import_disk_package and (args.diagnostics != 'oci-import' or not args.native_disk_images):
        parser.error('packed OCI import requires the private disk image store and OCI import diagnostic')
    if args.diagnostics == 'oci-import':
        if not (args.import_package and args.import_receipt and args.docker_owner == 'rust'):
            parser.error('OCI import diagnostics require the Rust owner and a staged package and receipt')
        native_assets += ('import_package', 'import_receipt')
    elif args.import_package or args.import_receipt:
        parser.error('import package and receipt require OCI import diagnostics')
    if args.diagnostics == 'registry':
        if not (args.registry_fixtures and args.docker_owner == 'rust'):
            parser.error('registry diagnostics require the Rust owner and pinned registry fixtures')
        native_assets += ('registry_fixtures',)
    elif args.registry_fixtures:
        parser.error('registry fixtures require registry diagnostics')
    if args.native_boot_layout:
        if args.legacy_baseline or args.docker_owner != 'rust' or args.diagnostics == 'oci-import':
            parser.error('the boot layout requires the native Rust owner and boot image')
        native_assets += ('native_boot_layout',)
    elif args.diagnostics == 'archive':
        parser.error('archive diagnostics require the pinned boot OCI layout')
    if args.native_public_images and (args.legacy_baseline or args.docker_owner != 'rust'):
        parser.error('frozen public images require the private native Rust owner')
    if args.diagnostics == 'public-images' and not args.native_public_images:
        parser.error('public image diagnostics require the frozen Docker Hub source')
    if (bool(args.benchmark_scenario) != bool(args.benchmark_archive)
            or (args.benchmark_scenario and not (args.benchmark_output or args.retained_trace_output))):
        parser.error('a staged scenario requires benchmark output and an image archive')
    if args.retained_host_only and not args.retained_trace:
        parser.error('host-only mode requires retained transport tracing')
    if args.retained_trace_output or args.retained_trace:
        if (not args.legacy_baseline or not args.retained_trace_output or args.benchmark_output
                or args.comparison_output or not args.benchmark_scenario
                or not 1 <= args.benchmark_samples <= 24):
            parser.error('retained trace requires its own baseline boot, pinned archive and 1–24 samples')
        destination = args.retained_trace_output
        resolved = destination.parent.resolve(strict=True) / destination.name
        if not resolved.is_relative_to(SCRATCH) or os.path.lexists(resolved):
            parser.error('retained trace output must be a new ExternalSSD directory')
        args.retained_trace_output = resolved
    if args.retained_event_wake and not args.legacy_baseline:
        parser.error('event wake is limited to the isolated retained Docker profile')
    if not args.image or args.image.startswith('-'):
        parser.error('image must be a Docker image reference')
    if not SSD.is_mount() or SCRATCH.resolve() != SCRATCH:
        parser.error('expected the designated scratch directory on mounted ExternalSSD')
    if args.core_assets:
        args.core_assets = args.core_assets.resolve(strict=True)
        if not args.core_assets.is_relative_to(SCRATCH):
            parser.error('cached release assets must be on designated ExternalSSD scratch')
    if any(key in os.environ for key in ('DOCKER_HOST', 'DOCKER_CONTEXT', 'BUILDX_BUILDER')):
        parser.error('unset inherited Docker endpoint and builder overrides before running')
    if args.legacy_baseline:
        if not args.network_helper or args.docker_args or args.diagnostics or args.docker_owner != 'rust' or args.matched_output or args.native_evidence or any(
                getattr(args, name) for name in native_assets):
            parser.error('legacy baseline requires its network helper and accepts no native options')
    else:
        if args.diagnostics and (args.matched_output or args.docker_args):
            parser.error('run diagnostics separately from qualification or a custom workload')
        if args.diagnostics == 'trace' and args.docker_owner != 'python':
            parser.error('request Python reference tracing with --docker-owner python')
        if (args.diagnostics in ('concurrency', 'concurrency-loss', 'streaming', 'exec', 'credentials',
                                 'compatibility-preflight',
                                 'guest-bridge', 'docker-network', 'tcp-relay', 'published-port')
                and args.docker_owner != 'rust'):
            parser.error('selected native Docker diagnostics require the Rust owner')
        if any((args.network_helper, args.core_assets, args.benchmark_output, args.comparison_output)):
            parser.error('legacy settings require --legacy-baseline')
        if not args.native_evidence or not all(getattr(args, name) for name in native_assets):
            parser.error('native candidate requires kernel, guest, package, receipt and evidence paths')
        if not re.fullmatch(r'[^@]+@sha256:[0-9a-f]{64}', args.image):
            parser.error('native candidate requires a pinned image reference')
        if args.docker_args and (args.docker_args[0].startswith('-') or args.docker_args[0] in ('context', 'buildx')):
            parser.error('pass a Docker workload subcommand without endpoint or context overrides')
        for name in ('swift_bin', 'core', *native_assets):
            asset = getattr(args, name).resolve(strict=True)
            if not asset.is_relative_to(SCRATCH):
                parser.error(f'{name} must reside on ExternalSSD')
            setattr(args, name, asset)
        for name in ('native_evidence', 'matched_output'):
            dest = getattr(args, name)
            if dest is not None:
                target = dest.parent.resolve(strict=True) / dest.name
                if not target.is_relative_to(SCRATCH) or os.path.lexists(target):
                    parser.error(f'{name} must be a new ExternalSSD directory')
                setattr(args, name, target)
        if args.matched_output == args.native_evidence:
            parser.error('benchmark and launcher evidence require distinct directories')
    root = Path(tempfile.mkdtemp(prefix='cs-', dir=SCRATCH))
    print(f'Candidate artifacts: {root}', flush=True)

    def interrupt(signum, _frame):
        # Ignore repeat interrupts once cleanup begins.
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        raise SessionInterrupted(signum)

    signal.signal(signal.SIGINT, interrupt)
    signal.signal(signal.SIGTERM, interrupt)
    try:
        if args.legacy_baseline:
            session(args, root)
        else:
            return native_session(args, root)
    except SessionInterrupted as error:
        print(f'Candidate interrupted by {error}', file=sys.stderr)
        return 128 + error.signum
    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
        print(f'Candidate failed: {error}', file=sys.stderr)
        return 1
    finally:
        if not args.legacy_baseline:
            shutil.rmtree(root)
    return 0


if __name__ == '__main__':
    sys.exit(main())
