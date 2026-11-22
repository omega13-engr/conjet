#!/usr/bin/env python3
"""Boot branch-built Conjet and run a disposable fixture on its private Docker API."""
import argparse
import hashlib
import json
import os
import runpy
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
    server = run(prefix + ['--host', endpoint, 'version',
                            '--format', '{{json .Server}}'], env=env)
    runtime = {pid: str(path) for pid, path in processes().items()
               if path.name in ('Conjet', 'conjetd', 'Conjet Core', 'conjet-network')}
    return {'current_context': current, 'endpoint': endpoint, 'server': json.loads(server),
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
    before = production()
    if before['endpoint'] == f'unix://{docker_socket}':
        raise RuntimeError('candidate overlaps production Docker')
    evidence = {'revision': run(['/usr/bin/git', '-C', REPO, 'rev-parse', 'HEAD']),
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
        if args.benchmark_output:
            benchmark = runpy.run_path(str(REPO / 'benchmarks/fresh-lifecycle.py'))
            benchmark['main']([
                '--engine', 'conjet', '--socket', str(docker_socket), '--config', str(docker_config),
                '--peer-pid', str(docker_peer), '--docker', str(DOCKER),
                '--output', str(args.benchmark_output), '--samples', str(args.benchmark_samples),
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--swift-bin', required=True, type=Path)
    parser.add_argument('--core', required=True, type=Path)
    parser.add_argument('--network-helper', required=True, type=Path)
    parser.add_argument('--image', default='alpine:3.22')
    parser.add_argument('--benchmark-output', type=Path, help='run the pinned fresh lifecycle benchmark')
    parser.add_argument('--benchmark-samples', type=int, default=100, help='samples per lane and network')
    parser.add_argument('--core-assets', type=Path, help='reuse verified ExternalSSD release downloads')
    parser.add_argument('--hold-seconds', type=int, choices=range(601), default=0,
                        metavar='0..600', help='keep the verified VM alive briefly for QA')
    args = parser.parse_args()
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
        session(args, root)
    except SessionInterrupted as error:
        print(f'Candidate interrupted by {error}', file=sys.stderr)
        return 128 + error.signum
    except (OSError, RuntimeError) as error:
        print(f'Candidate failed: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
