"""Observe public DNS and direct HTTP independently in disposable containers."""

from ipaddress import IPv4Address
import re
from pathlib import Path

from .identity import sha256

IMAGE = ('docker.io/library/alpine@sha256:'
         'e233f2058b0628266762f745a2c17e623b418e0090f47d223909d1f9a7d4367e')
HOSTNAME = 'example.com'


def public_ipv4(value):
    address = IPv4Address(value)
    if not address.is_global:
        raise ValueError('the diagnostic requires a public IPv4 address')
    return address


def diagnose(docker, address):
    """Run an identical pinned BusyBox probe on the default and none networks."""
    docker('egress-pull', 'pull', '--platform', 'linux/arm64', IMAGE, timeout=60)
    results = {}
    for network in ('bridge', 'none'):
        commands = {
            'dns': 'timeout 6 nslookup "$1"; printf "\nprobe-exit:%s\n" "$?"',
            'direct_http': r'''{ timeout 6 wget -Y off -S --spider -T 4 --header "Host: $1" "http://$2/";
                printf '\nprobe-exit:%s\n' "$?"; } 2>&1 | head -c 4096''',
        }
        for stage, script in commands.items():
            result = docker(
                f'egress-{network}-{stage}', 'run', '--rm', '--pull', 'never', '--network', network,
                IMAGE, '/bin/sh', '-c', script, 'fixture', HOSTNAME, str(address), timeout=20,
            )
            output, marker, code = result.stdout.rpartition('\nprobe-exit:')
            if result.returncode != 0 or not marker or not code.strip().isdecimal():
                raise RuntimeError(f'{network} {stage} did not execute the in-container probe')
            status = int(code.strip())
            observed = (
                status == 0 and re.search(r'^Name:\s*example\.com\.?\s*$', output, re.M) is not None
                if stage == 'dns' else re.search(r'^[ \t]*HTTP/1\.[01] [1-5][0-9]{2}\b', output, re.M) is not None
            )
            results.setdefault(network, {})[stage] = {
                'observed': observed, 'guest_exit_status': status,
                'stdout': output, 'stderr': result.stderr,
            }
    return {'image': IMAGE, 'hostname': HOSTNAME, 'direct_ipv4': str(address),
            'fixture_sha256': sha256(Path(__file__)), 'results': results}
