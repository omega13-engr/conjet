#!/usr/bin/env python3
"""Run official Kiri for one foreground Docker command, then stop it.

Test data stays on ExternalSSD. Kiri's own settings/logs remain in ~/.kiri.
This is operational separation, not a security sandbox for hostile containers.
"""
import argparse
import fcntl
import hashlib
import json
import os
import runpy
import signal
import socket
import subprocess
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
ROOT = Path('/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-kiri')
APP = REPO / '.speedup/tools/kiri-0.2.2/Kiri.app'
CONTEXT = 'kiri-speedup'


def command(args, **kwargs):
    return subprocess.run(args, check=True, text=True, capture_output=True,
                          timeout=kwargs.pop('timeout', 30), **kwargs)


def production_snapshot():
    files = [Path.home() / '.docker/config.json',
             Path.home() / 'Library/Application Support/Conjet/runtime-environment.json']
    files += sorted((Path.home() / '.docker/contexts/meta').glob('*/meta.json'))
    files += sorted((Path.home() / 'Library/LaunchAgents').glob('*.plist'))
    files += [Path('/etc/resolver/kiri.local')]
    hashes = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() if p.exists() else None
              for p in files}
    rows = command(['/bin/ps', '-axo', 'pid=,comm=']).stdout.splitlines()
    processes = [r.strip() for r in rows if r.split() and
                 Path(r.split(maxsplit=1)[1]).name in ('conjetd', 'Conjet', 'Conjet Core', 'conjet-network')]
    return {'config_hashes': hashes, 'processes': processes}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--smoke', action='store_true', help='pull Alpine and run an ephemeral container')
    parser.add_argument('--comparison-output', type=Path)
    parser.add_argument('--comparison-group')
    parser.add_argument('--comparison-mode', choices=('preflight', 'pilot', 'probes', 'lifecycle', 'images', 'builds', 'compose', 'control',
                                                         'storage_network', 'stress'), default='preflight')
    parser.add_argument('--benchmark-output', type=Path, help='run the pinned fresh lifecycle benchmark')
    parser.add_argument('--benchmark-samples', type=int, default=100, help='samples per lane and network')
    parser.add_argument('--benchmark-scenario', type=Path, help='use a staged lifecycle scenario')
    parser.add_argument('--benchmark-archive', type=Path, help='load the scenario image into the private runtime')
    parser.add_argument('docker_args', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if (bool(args.benchmark_scenario) != bool(args.benchmark_archive)
            or (args.benchmark_scenario and not args.benchmark_output)):
        parser.error('a staged scenario requires benchmark output and an image archive')
    if not APP.exists():
        parser.error(f'official Kiri app missing: {APP}')
    if not Path('/Volumes/ExternalSSD').is_mount():
        parser.error('ExternalSSD is not mounted')
    if ROOT.is_symlink():
        parser.error('QA root must not be a symlink')
    ROOT.mkdir(mode=0o700, parents=True, exist_ok=True)
    lock = (ROOT / 'session.lock').open('a')
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    if command(['/bin/ps', '-axo', 'comm=']).stdout.splitlines().count(str(APP / 'Contents/MacOS/kiri')):
        parser.error('Kiri already running; refusing concurrent state access')
    for row in command(['/bin/ps', '-axo', 'comm=']).stdout.splitlines():
        if Path(row.strip()).name == 'kiri':
            parser.error('another Kiri process is running')
    if (Path.home() / 'Kiri').exists():
        parser.error('existing Finder Kiri path requires manual review before shutdown/unmount')
    for port, kind in [(18080, socket.SOCK_STREAM), (18443, socket.SOCK_STREAM),
                       (53535, socket.SOCK_DGRAM)]:
        with socket.socket(socket.AF_INET, kind) as probe:
            probe.bind(('0.0.0.0', port))
    for name in ('data', 'docker-config', 'logs', 'tmp'):
        owned = ROOT / name
        owned.mkdir(mode=0o700, exist_ok=True)
        if owned.resolve(strict=True) != owned or not owned.is_dir():
            parser.error(f'expected private Kiri directory: {owned}')
    endpoint = ROOT / 'docker.sock'
    if endpoint.exists():
        parser.error(f'existing socket requires ownership review: {endpoint}')
    env = os.environ.copy()
    for key in list(env):
        if key.startswith(('KIRI_', 'DOCKER_', 'BUILDX_', 'CONJET_')):
            del env[key]
    env.update(KIRI_DATA_DIR=str(ROOT / 'data'), KIRI_SOCKET=str(endpoint),
               DOCKER_CONFIG=str(ROOT / 'docker-config'), KIRI_NO_FINDER='1',
               KIRI_HTTP_PORT='18080', KIRI_HTTPS_PORT='18443',
               KIRI_CPUS='2', KIRI_MEMORY_MIB='2048', TMPDIR=str(ROOT / 'tmp'))
    docker = str(APP / 'Contents/Resources/bin/docker')
    prefix = [docker, '--config', env['DOCKER_CONFIG'], '--context', CONTEXT]
    command(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(APP)])
    before = production_snapshot()
    result = {'production_before': before, 'root': str(ROOT), 'context': CONTEXT,
              'version': '0.2.2', 'cpus': 2, 'memory_mib': 2048, 'passed': False}
    proc = None
    interrupted = False

    def stop_signal(signum, frame):
        nonlocal interrupted
        if not interrupted:
            interrupted = True
            raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, stop_signal)
    signal.signal(signal.SIGINT, stop_signal)
    try:
        with (ROOT / 'logs/daemon.log').open('w') as log:
            proc = subprocess.Popen([str(APP / 'Contents/MacOS/kiri'), 'daemon'],
                                    env=env, stdout=log, stderr=log)
            result['daemon_pid'] = proc.pid
            print(f'Started session-owned Kiri PID {proc.pid}; data: {ROOT / "data"}', flush=True)
            deadline = time.monotonic() + 120
            while time.monotonic() < deadline:
                if proc.poll() is not None:
                    raise RuntimeError(f'Kiri exited {proc.returncode}; see {ROOT / "logs/daemon.log"}')
                try:
                    ready = command([docker, '--host', f'unix://{endpoint}', 'version',
                                     '--format', '{{json .Server}}'], env=env, timeout=3)
                    result['server'] = json.loads(ready.stdout)
                    if result['server'].get('Platform', {}).get('Name') != 'Kiri':
                        raise RuntimeError('endpoint is not Kiri')
                    versions = {c['Name']: c['Version'] for c in result['server'].get('Components', [])}
                    if versions.get('Kiri') != '0.2.2':
                        raise RuntimeError('unexpected Kiri version')
                    break
                except (subprocess.SubprocessError, json.JSONDecodeError):
                    time.sleep(0.2)
            else:
                raise RuntimeError('Kiri readiness timed out')
            inspect = subprocess.run(prefix[:-2] + ['context', 'inspect', CONTEXT],
                                     check=False, env=env, capture_output=True, text=True, timeout=10)
            if inspect.returncode == 0:
                actual = json.loads(inspect.stdout)[0]['Endpoints']['docker']['Host']
                if actual != f'unix://{endpoint}':
                    raise RuntimeError('private context points to unexpected endpoint')
            else:
                command(prefix[:-2] + ['context', 'create', CONTEXT, '--docker',
                                      f'host=unix://{endpoint}'], env=env)
            if args.smoke:
                output = command(prefix + ['run', '--rm', '--network', 'none',
                                           'alpine:3.22', 'echo', 'kiri-speedup-ok'],
                                 env=env, timeout=180)
                if output.stdout.strip() != 'kiri-speedup-ok':
                    raise RuntimeError('unexpected smoke result')
                result['smoke'] = output.stdout.strip()
                print(output.stdout, end='', flush=True)
            if args.comparison_output:
                comparison = runpy.run_path(str(REPO / 'benchmarks/docker-comparison.py'))
                comparison['run_suite']('kiri', endpoint, Path(env['DOCKER_CONFIG']), proc.pid,
                                        args.comparison_output, args.comparison_mode,
                                        group=args.comparison_group)
            if args.benchmark_output:
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                    client.settimeout(3)
                    client.connect(str(endpoint))
                    if client.getsockopt(0, 2) != proc.pid:  # Darwin LOCAL_PEERPID
                        raise RuntimeError('Docker socket is outside the owned Kiri process')
                benchmark = runpy.run_path(str(REPO / 'benchmarks/fresh-lifecycle.py'))
                benchmark['main']([
                    '--engine', 'kiri', '--socket', str(endpoint), '--config', env['DOCKER_CONFIG'],
                    '--peer-pid', str(proc.pid), '--docker', '/opt/homebrew/bin/docker',
                    '--output', str(args.benchmark_output), '--samples', str(args.benchmark_samples),
                    *(['--scenario', str(args.benchmark_scenario), '--archive', str(args.benchmark_archive)]
                      if args.benchmark_scenario else []),
                ])
                result['benchmark_output'] = str(args.benchmark_output)
            requested = args.docker_args
            if requested[:1] == ['--']:
                requested = requested[1:]
            if requested:
                # Global Docker options are forbidden: they could redirect the command.
                if requested[0].startswith('-') or requested[0] in ('context', 'buildx'):
                    raise ValueError('pass a Docker workload subcommand, without endpoint/context overrides')
                output = command(prefix + requested, env=env, timeout=600)
                print(output.stdout, end='', flush=True)
            result['passed'] = True
    finally:
        if proc is not None and proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=30)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=10)
                result['forced_kill'] = True
                result['passed'] = False
        result['production_after'] = production_snapshot()
        result['production_unchanged'] = result['production_after'] == before
        result['daemon_stopped'] = proc is None or proc.poll() is not None
        result['socket_removed'] = not endpoint.exists()
        result['passed'] &= result['production_unchanged'] and result['socket_removed']
        (ROOT / 'last-session.json').write_text(json.dumps(result, indent=2) + '\n')
        print(f'Session evidence: {ROOT / "last-session.json"}', flush=True)
        if not result['production_unchanged']:
            raise RuntimeError('production snapshot changed; inspect evidence before continuing')
    if not result['passed']:
        raise RuntimeError('session cleanup did not pass')


if __name__ == '__main__':
    main()
