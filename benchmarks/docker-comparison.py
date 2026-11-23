#!/usr/bin/env python3
"""Run serial Docker comparison sessions using the two isolated launchers."""

import argparse
from contextlib import ExitStack
import fcntl
import json
import os
from pathlib import Path
import runpy
import shutil
import signal
import subprocess
import sys
import time
from types import SimpleNamespace

REPO = Path(__file__).resolve().parents[1]
SCRATCH = Path('/Volumes/ExternalSSD/dev_workspace/tmp')
MANIFEST = REPO / 'benchmarks/scenarios/docker-comparison-v1.json'
TOOLS = runpy.run_path(str(REPO / 'benchmarks/fresh-lifecycle.py'))
DOCKER = Path('/opt/homebrew/bin/docker')
PLUGINS = Path('/opt/homebrew/lib/docker/cli-plugins')
KIRI_ROOT = SCRATCH / 'conjet-speedup-kiri'


def contract():
    document = json.loads(MANIFEST.read_text())
    if document['schema_version'] != 1:
        raise RuntimeError('unsupported comparison manifest')
    return document


def save(path, result):
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(result, indent=2) + '\n')
    temporary.replace(path)


def private_path(path):
    if not path.is_absolute() or not path.parent.resolve().is_relative_to(SCRATCH):
        raise ValueError(f'expected ExternalSSD output path: {path}')
    return path


def holders(path):
    result = subprocess.run(['/usr/sbin/lsof', '-Fpcn', str(path)], text=True,
                            capture_output=True, timeout=10)
    if result.stderr or result.returncode not in (0, 1):
        raise RuntimeError('could not verify disk holders: ' + result.stderr.strip())
    return [int(row[1:]) for row in result.stdout.splitlines() if row.startswith('p')]


def configure_clients(directory, manifest, resources):
    clients = {'docker': DOCKER, 'buildx': PLUGINS / 'docker-buildx',
               'compose': PLUGINS / 'docker-compose'}
    for name, path in clients.items():
        if TOOLS['file_hash'](path) != manifest['clients'][name]['sha256']:
            raise RuntimeError(f'pinned {name} executable changed: {path}')
    plugin_dir = directory / 'cli-plugins'
    if not plugin_dir.exists() and not plugin_dir.is_symlink():
        plugin_dir.mkdir()
        resources.callback(plugin_dir.rmdir)
    if plugin_dir.is_symlink() or plugin_dir.resolve() != plugin_dir:
        raise RuntimeError('unexpected private Docker plugin directory')
    for name in ('buildx', 'compose'):
        target = clients[name].resolve(strict=True)
        link = plugin_dir / f'docker-{name}'
        if not os.path.lexists(link):
            link.symlink_to(target)
            resources.callback(link.unlink)
        if not link.is_symlink() or link.resolve(strict=True) != target:
            raise RuntimeError(f'unexpected private {name} executable')
    return {name: str(path.resolve()) for name, path in clients.items()}


def vm_disks(engine, config, vm_paths):
    if engine == 'kiri':
        disks = [KIRI_ROOT / 'data/vm/data.img']
    else:
        disks = [Path(value) for name, value in vm_paths.items()
                 if name.lower().endswith('diskpath')]
    if not disks:
        raise RuntimeError('no VM backing disks were identified')
    for disk in disks:
        if not disk.is_file() or disk.resolve() != disk or not disk.is_relative_to(config.parent):
            raise RuntimeError(f'unsafe VM backing path: {disk}')
        if not disk.is_relative_to(SCRATCH):
            raise RuntimeError(f'VM disk outside ExternalSSD: {disk}')
    return disks


def observed_disks(engine, peer, disks):
    observations = {}
    for disk in disks:
        deadline = time.monotonic() + 8
        while True:
            owners = holders(disk)
            if owners or time.monotonic() >= deadline:
                break
            time.sleep(0.25)
        executables = {pid: str(TOOLS['current_executable'](pid)) for pid in owners}
        if engine == 'kiri':
            allowed = executables and all(pid == peer or Path(path).name == 'com.apple.Virtualization.VirtualMachine'
                                          for pid, path in executables.items())
        else:
            allowed = peer in executables and all(pid == peer for pid in executables)
        if not allowed:
            raise RuntimeError(f'unverified VM disk holders for {disk}: {executables}')
        observations[str(disk)] = {'holders': executables, 'bytes': disk.stat().st_size,
                                   'allocated_bytes': disk.stat().st_blocks * 512}
    return observations


def run_suite(engine, endpoint, config, peer, output, mode, vm_paths=None, group=None):
    """Called by the launcher after it has proved its own runtime identity."""
    output = private_path(output)
    output.mkdir(mode=0o700)
    manifest = contract()
    report = {'mode': mode, 'engine': engine, 'endpoint': str(endpoint), 'peer_pid': peer,
              'manifest_sha256': TOOLS['file_hash'](MANIFEST),
              'selected_group': group,
              'harness_revision': TOOLS['run'](['/usr/bin/git', '-C', REPO, 'rev-parse', 'HEAD']),
              'passed': False}
    resources = ExitStack()
    peer_args = SimpleNamespace(engine=engine, socket=endpoint, config=config, peer_pid=peer, docker=DOCKER)
    try:
        docker, env, executable = TOOLS['verify_endpoint'](peer_args)
        report['engine_sha256'] = TOOLS['file_hash'](executable)
        if engine == 'kiri' and report['engine_sha256'] != manifest['participants']['kiri']['executable_sha256']:
            raise RuntimeError('official Kiri executable differs from the manifest')
        report['clients'] = configure_clients(config, manifest, resources)
        env['DOCKER_API_VERSION'] = manifest['docker_api']
        env['TMPDIR'] = str(config.parent / 'tmp')
        connection = TOOLS['UnixHTTP'](endpoint, peer)
        try:
            report['server'] = TOOLS['api'](connection, 'GET', '/version', (200,))
            if engine == 'kiri':
                versions = {entry['Name']: entry['Version'] for entry in report['server'].get('Components', [])}
                if report['server'].get('Platform', {}).get('Name') != 'Kiri' or versions.get('Kiri') != '0.2.2':
                    raise RuntimeError('unexpected server behind Kiri endpoint')
            elif report['server'].get('Platform', {}).get('Name') == 'Kiri':
                raise RuntimeError('candidate endpoint unexpectedly identifies as Kiri')
            version = '/v' + manifest['docker_api']
            info = TOOLS['api'](connection, 'GET', version + '/info', (200,))
            report['guest'] = {key: info.get(key) for key in
                               ('Architecture', 'NCPU', 'MemTotal', 'KernelVersion', 'Driver',
                                'OperatingSystem', 'CgroupVersion', 'DockerRootDir', 'DefaultRuntime')}
            disks = vm_disks(engine, config, vm_paths or {})
            if engine == 'kiri':
                # Kiri can answer metadata from the daemon before the guest
                # exists. Start it with pinned work outside the timing window.
                image = manifest['images']['alpine']['ref']
                TOOLS['run'](docker + ['pull', '--platform', manifest['platform'], image], env, timeout=180)
                output_text = TOOLS['run'](docker + ['run', '--rm', '--network', 'none', '--pull', 'never',
                                                    image, '/bin/echo', 'comparison-ready'], env)
                if output_text != 'comparison-ready':
                    raise RuntimeError('Kiri guest startup canary failed')
            report['vm_backing'] = observed_disks(engine, peer, disks)
            report['host_before'] = TOOLS['sample_host'](peer_args, output / 'footprint-before.json')
            report['backend'] = ('official Kiri 0.2.2' if engine == 'kiri' else 'Conjet Core Docker/containerd')
            if mode != 'preflight':
                adapter = runpy.run_path(str(REPO / 'benchmarks/docker-comparison-workloads.py'))
                adapter['run_workloads'](mode, manifest, report, output, connection, docker, env, group)
        finally:
            connection.close()
        report['host_after'] = TOOLS['sample_host'](peer_args, output / 'footprint-after.json')
        report['passed'] = True
    except BaseException as error:
        report['error'] = str(error) or type(error).__name__
        raise
    finally:
        try:
            resources.close()
        except OSError as error:
            report['passed'] = False
            report['client_cleanup_error'] = str(error)
            raise
        finally:
            save(output / 'session.json', report)


def wait_for_launcher(process, budget):
    try:
        return process.wait(timeout=budget)
    except (KeyboardInterrupt, subprocess.TimeoutExpired):
        if process.poll() is None:
            process.send_signal(signal.SIGTERM)
            # Let the launcher own shutdown. SIGKILL would skip its finally block.
            process.wait(timeout=90)
        raise


def validate_cleanup(engine, metadata):
    if not metadata.get('production_unchanged'):
        raise RuntimeError('launcher did not verify production preservation')
    if engine == 'kiri':
        if not metadata.get('daemon_stopped') or not metadata.get('socket_removed'):
            raise RuntimeError('official launcher failed cleanup')
        disks = [KIRI_ROOT / 'data/vm/data.img']
    else:
        disks = [Path(value) for name, value in metadata.get('vm_paths', {}).items()
                 if name.lower().endswith('diskpath') and Path(value).is_file()]
        if any(Path(path).exists() for path in metadata.get('remaining_sockets', [])):
            raise RuntimeError('candidate launcher left a socket')
        if metadata.get('graceful_stop_error') or metadata.get('forced_cleanup'):
            raise RuntimeError('candidate required forced cleanup')
    if any(holders(disk) for disk in disks):
        raise RuntimeError('engine still holds VM backing after shutdown')


def run_pair(args, output, order):
    production = runpy.run_path(str(REPO / 'build-support/run-conjet-speedup.py'))['production']
    for engine in order:
        report = output / engine
        launcher = REPO / f'build-support/run-{engine}-speedup.py'
        command = [sys.executable, str(launcher), '--comparison-output', str(report),
                   '--comparison-mode', args.mode]
        if args.group:
            command += ['--comparison-group', args.group]
        if engine == 'conjet':
            command += ['--image', contract()['images']['alpine']['ref']]
            for name in ('swift_bin', 'core', 'network_helper', 'core_assets'):
                command += ['--' + name.replace('_', '-'), str(getattr(args, name))]
        before = production()
        started = time.time()
        record = {'command': command, 'production_before': before, 'load_before': os.getloadavg()}
        with (output / f'{engine}.log').open('w+') as log:
            with subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT,
                                  start_new_session=True) as process:
                try:
                    record['exit_code'] = wait_for_launcher(process, args.timeout)
                finally:
                    try:
                        log.seek(0)
                        if engine == 'conjet':
                            prefix = 'Candidate artifacts: '
                            line = log.readline().strip()
                            root = Path(line.removeprefix(prefix))
                            if line.startswith(prefix) and root.parent == SCRATCH and root.name.startswith('cs-'):
                                result = root / 'session.json'
                                if result.is_file() and not result.is_symlink():
                                    metadata = json.loads(result.read_text())
                                    record['launcher'] = metadata
                                    validate_cleanup(engine, metadata)
                                    shutil.rmtree(root)
                        else:
                            result = KIRI_ROOT / 'last-session.json'
                            if result.is_file() and result.stat().st_mtime >= started:
                                metadata = json.loads(result.read_text())
                                record['launcher'] = metadata
                                validate_cleanup(engine, metadata)
                    finally:
                        record['production_after'] = production()
                        record['load_after'] = os.getloadavg()
                        save(output / f'{engine}-launcher.json', record)
        if record.get('exit_code') or 'launcher' not in record or record['production_after'] != before:
            raise RuntimeError(f'{engine} failed qualification or cleanup; see {output}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--mode', choices=('preflight', 'pilot', 'probes', 'lifecycle'), default='preflight')
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--pair', type=int, choices=range(1, 6), default=1)
    parser.add_argument('--timeout', type=int, default=900)
    lifecycle = contract()['suites']['lifecycle']
    parser.add_argument('--group', choices=[f'{workload}/{network}/{lane}'
                         for workload in lifecycle['workloads']
                         for network in lifecycle['networks'] for lane in ('api', 'cli')],
                        help='run one complete lifecycle group per paired session')
    for name in ('swift-bin', 'core', 'network-helper', 'core-assets'):
        parser.add_argument('--' + name, required=True, type=Path)
    args = parser.parse_args()
    if args.group and args.mode != 'lifecycle':
        parser.error('--group is only valid with lifecycle mode')
    for name in ('swift_bin', 'core', 'network_helper', 'core_assets'):
        path = getattr(args, name).resolve(strict=True)
        if not path.is_relative_to(SCRATCH):
            parser.error(f'{name} must be on ExternalSSD')
        setattr(args, name, path)
    if not Path('/Volumes/ExternalSSD').is_mount():
        parser.error('ExternalSSD is not mounted')
    output = private_path(args.output)
    output.mkdir(mode=0o700)
    lock_path = SCRATCH / '.conjet-docker-comparison.lock'
    descriptor = os.open(lock_path, os.O_CREAT | os.O_NOFOLLOW | os.O_WRONLY, 0o600)
    with os.fdopen(descriptor, 'w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        signal.signal(signal.SIGTERM, lambda *_: signal.raise_signal(signal.SIGINT))
        order = contract()['session_order'][args.pair - 1]
        save(output / 'pair.json', {'order': order, 'mode': args.mode, 'pair': args.pair})
        run_pair(args, output, order)


if __name__ == '__main__':
    main()
