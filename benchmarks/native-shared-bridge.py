#!/usr/bin/env python3
"""Run the scoped shared bridge proof in a disposable Jetstream guest."""

import argparse
import json
from pathlib import Path
import runpy
import subprocess
import tempfile


REPO = Path(__file__).resolve().parent.parent
TOOLS = runpy.run_path(str(REPO / 'build-support/run-conjet-speedup.py'))
MARKER = 'conjet-launchd verified shared bridge TCP, rollback, address reuse and isolated teardown'
DNS_MARKER = 'conjet-launchd verified live DNS aliases, duplicate rejection and removal on peer detach'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('cli', 'vmm', 'kernel', 'guest', 'output'):
        parser.add_argument(f'--{name}', type=Path, required=True)
    args = parser.parse_args()
    root = TOOLS['SCRATCH']
    args.output = args.output.absolute()
    if args.output.parent.resolve() != args.output.parent or not args.output.is_relative_to(root):
        parser.error('evidence must be under the ExternalSSD scratch root')
    for name in ('cli', 'vmm', 'kernel', 'guest'):
        source = getattr(args, name).resolve(strict=True)
        if not source.is_relative_to(root) or source.stat().st_dev != root.stat().st_dev:
            parser.error(f'{name} must be backed by ExternalSSD scratch')
        setattr(args, name, source)
    args.output.mkdir(mode=0o700)
    report = {
        'passed': False,
        'revision': TOOLS['run'](['/usr/bin/git', '-C', REPO, 'rev-parse', 'HEAD']),
        'artifacts': {str(path): TOOLS['fingerprint'](path)
                      for path in (args.cli, args.vmm, args.kernel, args.guest)},
    }
    before = TOOLS['production']()
    directory = None
    try:
        with tempfile.TemporaryDirectory(prefix='cb-', dir=root) as owned:
            directory = Path(owned)
            disk = directory / 'guest.raw'
            with disk.open('xb') as stream:
                stream.truncate(16 * 1024 * 1024)
            initrd = directory / 'init.cpio.gz'
            bootstrap = directory / 'bootstrap'
            bootstrap.mkdir(mode=0o700)
            env = {'HOME': owned, 'CONJET_HOME': owned, 'DOCKER_CONFIG': str(directory / 'docker'),
                   'TMPDIR': owned, 'PATH': '/usr/bin:/bin'}
            build = [args.cli, 'vm', 'build-initramfs', '--init', args.guest, '--output', initrd]
            report['initramfs_command'] = list(map(str, build))
            subprocess.run(build, env=env, check=True, capture_output=True, timeout=15)
            serial = args.output / 'guest.serial.log'
            manifest = {
                'name': 'native-shared-bridge-proof', 'architecture': 'arm64',
                'bootLoaderKind': 'linuxKernel', 'kernelPath': str(args.kernel),
                'initialRamdiskPath': str(initrd), 'rootDiskPath': str(disk),
                'bootstrapSharePath': str(bootstrap), 'serialLogPath': str(serial),
                'dockerSocketPath': str(directory / 'unused.sock'), 'source': 'isolated bridge proof',
                'kernelCommandLine': 'console=ttyAMA0 rdinit=/init --check-shared-bridge quiet',
            }
            manifest_path = directory / 'manifest.json'
            manifest_path.write_text(json.dumps(manifest))
            command = [args.vmm, 'boot', '--manifest', manifest_path, '--memory-mib', '512',
                       '--cpus', '2', '--max-exits', str(2**64 - 1), '--max-runtime-ms', '15000',
                       '--host-tick-ms', '25', '--airgap', '--early-console-only', '--json']
            report['boot_command'] = list(map(str, command))
            with (args.output / 'vmm.json').open('w') as stdout, \
                    (args.output / 'vmm.stderr').open('w') as stderr:
                result = subprocess.run(command, env=env, stdout=stdout, stderr=stderr, timeout=30)
            report['vmm_exit'] = result.returncode
            boot = json.loads((args.output / 'vmm.json').read_text())
            report['guest_marker'] = MARKER in boot['console_output']
            report['dns_marker'] = DNS_MARKER in boot['console_output']
            report['no_guest_nic'] = any(stage['name'] == 'virtio-runtime'
                                         and '0 net backend(s)' in stage['detail']
                                         for stage in boot['stages'])
            report['guest_shutdown'] = boot['message']
            if (not all(report[key] for key in ('guest_marker', 'dns_marker', 'no_guest_nic'))
                    or result.returncode
                    or report['guest_shutdown'] != 'guest requested PSCI SYSTEM_OFF'):
                raise RuntimeError(f'shared bridge proof failed: {args.output}')
            report['passed'] = True
    finally:
        report['owned_scratch_removed'] = directory is not None and not directory.exists()
        report['production_unchanged'] = before == TOOLS['production']()
        report['passed'] &= report['owned_scratch_removed'] and report['production_unchanged']
        (args.output / 'launcher.json').write_text(json.dumps(report, indent=2) + '\n')
    if not report['passed']:
        raise RuntimeError(f'unverified shared bridge cleanup: {args.output}')


if __name__ == '__main__':
    main()
