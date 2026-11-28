#!/usr/bin/env python3
"""Run the matrix against a disposable, rootful Docker Engine reference."""

import argparse
from contextlib import ExitStack
import json
import os
from pathlib import Path
import runpy
import signal
import subprocess
import tempfile
import time

from compatibility.egress import diagnose as diagnose_egress, public_ipv4
from compatibility.identity import DockerConnection, SCRATCH, production_sockets, sha256
from compatibility.run import record_lane


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--disk', required=True, type=Path)
    parser.add_argument('--docker-archive', required=True, type=Path)
    parser.add_argument('--evidence', required=True, type=Path)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--profile', choices=('single-host', 'swarm', 'advanced', 'all'))
    mode.add_argument('--direct-egress-ip', type=public_ipv4)
    args = parser.parse_args()
    for path in (args.disk, args.docker_archive, args.evidence):
        if path.resolve() != path or not path.is_relative_to(SCRATCH):
            parser.error('reference inputs and evidence must be canonical ExternalSSD paths')
    receipt = args.evidence
    if receipt.suffix != '.json' or any(receipt.with_suffix(suffix).exists()
           for suffix in ('.json', '.lima.log', '.dockerd.log', '.ssh.log')):
        parser.error('reference evidence must be a new .json path with no existing logs')
    lima = Path('/opt/homebrew/bin/limactl').resolve(strict=True)
    ssh = Path('/usr/bin/ssh')
    docker = Path('/opt/homebrew/bin/docker').resolve(strict=True)
    production = runpy.run_path(str(Path(__file__).with_name('native-fresh-buildx.py')))['production']
    archive = args.docker_archive
    archive_hash = sha256(archive)
    if archive_hash != 'a38c8a9ef6d17bce07499bfd3a3688542274769dc3b4f75c06ea2705fe65053e':
        parser.error('the reference requires the pinned Docker 29.10.1 archive')
    report = {'started': time.strftime('%FT%TZ', time.gmtime()), 'docker_archive_sha256': archive_hash}
    before = production()

    def interrupt(signum, _frame):
        raise KeyboardInterrupt(signal.Signals(signum).name)

    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, interrupt)

    def wait_ready(process, predicate, deadline, description):
        while not predicate():
            if process.poll() is not None or time.monotonic() >= deadline:
                raise RuntimeError(f'{description} failed to become ready (pid={process.pid}, exit={process.poll()})')
            time.sleep(0.25)

    def terminate(process, sig=signal.SIGTERM):
        if process is None or process.poll() is not None:
            return
        process.send_signal(sig)
        try:
            process.wait(10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(10)
            raise RuntimeError(f'process {process.pid} required forced termination')

    with ExitStack() as resources:
        root = Path(resources.enter_context(tempfile.TemporaryDirectory(dir=SCRATCH, prefix='cfr-')))
        lima_home = root / 'l'
        cache = root / 'cache'
        scratch = root / 'tmp'
        for d in (lima_home, cache, scratch):
            d.mkdir(mode=0o700)
        env = {'PATH': '/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin', 'HOME': str(root),
               'LIMA_HOME': str(lima_home), 'XDG_CACHE_HOME': str(cache), 'TMPDIR': str(scratch),
               'USER': os.environ['USER'], 'LOGNAME': os.environ['LOGNAME']}
        config = root / 'reference.yaml'
        config.write_text(f'''images:
- location: {json.dumps(str(args.disk))}
  arch: aarch64
  digest: "sha512:f42866fe22b4baf9f0ed4f81d620064f2a4b86b18b92bfe3aaaa40babf6819d39cbf0caaaad13f4ae3e7c9f82cbd78b0c8cabadd8bc737ce13578e61fa86970c"
arch: aarch64
vmType: vz
cpus: 2
memory: 4GiB
disk: 16GiB
mounts: []
containerd:
  system: false
  user: false
ssh:
  loadDotSSHPubKeys: false
portForwards:
- guestIP: 0.0.0.0
  proto: any
  ignore: true
  guestPortRange: [1, 65535]
''')
        report['lima_config_sha256'] = sha256(config)
        report['lima_sha256'] = sha256(lima)
        proc = daemon = proxy = None
        socket = root / 'd.sock'
        ssh_config = lima_home / 'r/ssh.config'
        run_path = '/run/conjet-docker.sock'
        remote_dir = '/tmp/cf-ref'

        def command(executable, *args, timeout=30, checked=True):
            return subprocess.run([executable, *args], env=env, text=True, capture_output=True,
                                  timeout=timeout, check=checked)

        def vm(*args, **opts):
            return command(lima, '--tty=false', *args, **opts)

        def guest(*args, **opts):
            return vm('shell', '--workdir', '/tmp', 'r', *args, **opts).stdout.strip()

        def lima_ready():
            events = lima_home / 'r/ha.stdout.log'
            if not events.is_file():
                return False
            complete_lines = events.read_text().rpartition('\n')[0]
            return any(json.loads(line).get('status', {}).get('running') is True
                       for line in complete_lines.splitlines())

        try:
            log = resources.enter_context(receipt.with_suffix('.lima.log').open('x'))
            proc = subprocess.Popen([lima, '--tty=false', 'start', '--foreground', '--timeout', '240s',
                                     '--name', 'r', config], env=env, stdout=log, stderr=log)
            wait_ready(proc, lima_ready, time.monotonic() + 255, 'Lima reference guest')
            guest('mkdir', '-m', '700', remote_dir)
            vm('copy', archive, f'r:{remote_dir}/docker.tgz', timeout=90)
            if guest('sha256sum', f'{remote_dir}/docker.tgz').split()[0] != archive_hash:
                raise RuntimeError('Docker archive changed while provisioning the private guest')
            guest('tar', '-xzf', f'{remote_dir}/docker.tgz', '-C', remote_dir)
            group = guest('id', '-gn')
            report['engine_sha256'] = guest('sha256sum', f'{remote_dir}/docker/dockerd').split()[0]
            report['kernel_release'] = guest('uname', '-r')
            report['kernel_sha256'] = guest('sudo', '-n', 'sha256sum',
                                           '/boot/vmlinuz-' + report['kernel_release']).split()[0]
            daemon_log = resources.enter_context(receipt.with_suffix('.dockerd.log').open('x'))
            daemon = subprocess.Popen([lima, '--tty=false', 'shell', '--workdir', '/tmp', 'r',
                'sudo', '-n', 'env', f'PATH={remote_dir}/docker:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin',
                f'{remote_dir}/docker/dockerd', '--host', f'unix://{run_path}', '--group', group,
                '--data-root', '/var/lib/conjet-reference/docker', '--exec-root', '/run/conjet-reference',
                '--pidfile', '/run/conjet-reference-dockerd.pid'], env=env, stdout=daemon_log, stderr=daemon_log)
            wait_ready(daemon, lambda: 'API listen on ' + run_path in receipt.with_suffix('.dockerd.log').read_text(),
                       time.monotonic() + 55, 'foreground dockerd')
            proxy_log = resources.enter_context(receipt.with_suffix('.ssh.log').open('x'))
            proxy = subprocess.Popen([ssh, '-F', ssh_config, '-o', 'ControlMaster=no', '-o', 'ControlPath=none',
                '-o', 'ExitOnForwardFailure=yes', '-N', '-L', f'{socket}:{run_path}', 'lima-r'],
                env=env, stdout=proxy_log, stderr=proxy_log)
            wait_ready(proxy, socket.is_socket, time.monotonic() + 12, 'SSH Unix forward')
            client = DockerConnection(socket, root, production_sockets(docker), proxy.pid)
            report['identity'] = client.capture(ssh)
            expected = {'Version': '29.10.1', 'ApiVersion': '1.57', 'Os': 'linux', 'Arch': 'arm64',
                        'KernelVersion': report['kernel_release'], 'platform': 'Docker Engine - Community'}
            if any(report['identity']['version'][key] != value for key, value in expected.items()):
                raise RuntimeError('unexpected reference Engine version')
            report['engine_version_command'] = guest(f'{remote_dir}/docker/dockerd', '--version')
            report['rootful'] = guest('sudo', '-n', 'stat', '-c', '%u', run_path) == '0'
            if not report['rootful']:
                raise RuntimeError('reference Docker socket is not root-owned')
            if args.profile:
                report['compatibility'] = record_lane(args.profile, client, ssh, report['identity'])
            if args.direct_egress_ip:
                config = root / 'docker-config'
                config.mkdir(mode=0o700)

                def docker_call(_label, *argv, timeout):
                    client.connect()
                    client.close()
                    return command(docker, '--config', config, '--host', f'unix://{socket}',
                                   *argv, timeout=timeout)

                report['docker_cli_sha256'] = sha256(docker)
                report['direct_egress'] = diagnose_egress(docker_call, args.direct_egress_ip)
                if client.capture(ssh) != report['identity']:
                    raise RuntimeError('reference Docker endpoint changed during the diagnostic')
        except BaseException as error:
            report['error'] = repr(error)
            raise
        finally:
            try:
                if daemon is not None and daemon.poll() is None:
                    pid = guest('sudo', '-n', 'cat', '/run/conjet-reference-dockerd.pid',
                                checked=False, timeout=10)
                    if pid.isdecimal() and int(pid) > 1:
                        guest('sudo', '-n', 'kill', '-TERM', pid, checked=False, timeout=15)
                if proxy is not None:
                    terminate(proxy)
                if daemon is not None:
                    daemon.wait(timeout=20)
            finally:
                if proc is not None:
                    vm('stop', 'r', timeout=80, checked=False)
                    terminate(proc)
                    vm('delete', 'r', timeout=35, checked=False)
                report['cleanup'] = {'vm_removed': not (lima_home / 'r').exists(),
                                     'children_reaped': all(p is None or p.poll() is not None
                                                           for p in (proc, daemon, proxy)),
                                     'production_unchanged': production() == before}
                report['passed'] = not report.get('error') and all(report['cleanup'].values())
                if args.profile:
                    lane = report.get('compatibility', {})
                    rows = lane.get('cases', {})
                    report['passed'] = (report['passed'] and lane.get('endpoint_verified_after') is True
                                        and bool(rows) and all(row['passed'] for row in rows.values()))
                with receipt.open('x') as stream:
                    json.dump(report, stream, indent=2)
                    stream.write('\n')
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
