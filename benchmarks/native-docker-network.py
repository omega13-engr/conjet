"""Exercise the built-in and private bridge scopes through pinned clients."""

from concurrent.futures import ThreadPoolExecutor
from contextlib import closing
import json
from pathlib import Path
import runpy
import subprocess
import time
import uuid


HERE = Path(__file__).resolve().parent
MATCHED = runpy.run_path(str(HERE / 'native-docker-comparison.py'))
INSTALL = runpy.run_path(str(HERE / 'native-oci-live-install.py'))
WORKLOAD = runpy.run_path(str(HERE / 'docker-comparison-workloads.py'))
FROZEN = json.loads((HERE / 'scenarios/docker-comparison-v1.json').read_text())


def collect(endpoint, peer, docker, env, output, session, pid, *, routed=False):
    tools = MATCHED['TOOLS']
    image = MATCHED['IMAGE']['ref']
    net = 'cj-private'
    network_mode = [] if routed else ['--internal']
    base = [net if value == 'none' else value for value in MATCHED['FLAGS'][1:]]
    cases = {}

    def call(label, args, *, code=0, stdout=None, stderr=None):
        result = subprocess.run([*docker, *args], env=env, capture_output=True, timeout=10)
        cases[label] = {'args': args, 'exit': result.returncode,
                        'stdout': result.stdout.decode(errors='replace'),
                        'stderr': result.stderr.decode(errors='replace')}
        if (result.returncode != code or stdout is not None and result.stdout != stdout
                or stderr is not None and stderr not in result.stderr):
            raise RuntimeError(f'Docker bridge check {label} failed: {cases[label]}')
        return result.stdout

    def attached(name, network=net):
        until = time.monotonic() + 3
        while time.monotonic() < until:
            stats = json.loads(call('inspect_' + name, ['inspect', name]))[0]
            access = stats['NetworkSettings']['Networks'].get(network)
            if access and access['IPAddress']:
                return access
            time.sleep(0.02)
        raise RuntimeError(f'Docker inspect did not confirm attached peer: {name}')

    try:
        with closing(tools['UnixHTTP'](endpoint, peer)) as api:
            if tools['api'](api, 'GET', '/version', (200,))['Platform']['Name'] != 'Conjet Native OCI':
                raise RuntimeError('wrong Docker network endpoint')
        builtin = json.loads(call('inspect_builtin', ['network', 'inspect', 'bridge']))[0]
        if (builtin['Name'] != 'bridge' or builtin['Driver'] != 'bridge'
                or builtin['IPAM']['Config'] != [{'Subnet': '198.18.1.0/28', 'Gateway': '198.18.1.1'}]):
            raise RuntimeError(f'wrong built-in bridge metadata: {builtin}')
        call('reject_remove_builtin', ['network', 'rm', 'bridge'], code=1, stderr=b'cannot be removed')
        call('reject_non_bridge_driver', ['network', 'create', '--driver', 'host', 'invalid-network'],
             code=1, stderr=b'native networking requires the bridge driver')
        identifier = call('create_bridge', ['network', 'create', *network_mode, net]).decode().strip()
        inspected = json.loads(call('inspect_bridge', ['network', 'inspect', identifier]))[0]
        if inspected['Id'] != identifier or inspected['Internal'] == routed or inspected['Driver'] != 'bridge':
            raise RuntimeError(f'wrong bridge metadata: {inspected}')
        call('reject_second_bridge', ['network', 'create', '--internal', 'other-net'],
             code=1, stderr=b'occupied')
        server = 'cj-server'
        call('create_server', ['create', *base, '--name', server, '--network-alias', 'service',
                               '--network-alias', 'instance',
                               image, '/bin/sh', '-c', 'exec /bin/busybox nc -l -p 8080 -e /bin/sh -c '
                               '\'printf "HTTP/1.1 200 OK\\r\\nContent-Length: 16\\r\\n'
                               'Connection: close\\r\\n\\r\\nprivate-oci-http"\''])
        call('reject_duplicate_alias', ['create', *base, '--network-alias', 'INSTANCE',
                                        image, '/bin/true'], code=1, stderr=b'already owned')
        call('start_server', ['start', server], stdout=b'cj-server\n')
        server_address = attached(server)
        if server_address['Aliases'] != ['service', 'instance'] or server_address['NetworkID'] != identifier:
            raise RuntimeError(f'missing server alias or network identity: {server_address}')
        implicit = base.copy()
        index = implicit.index('--network')
        del implicit[index:index + 2]
        observer_default = 'cj-default-observer'
        call('create_builtin_peer', ['create', *implicit, '--name', observer_default, image,
                                     '/bin/busybox', 'sleep', '25'])
        call('start_builtin_peer', ['start', observer_default])
        builtin_address = attached(observer_default, 'bridge')
        if (builtin_address['NetworkID'] != builtin['Id']
                or not builtin_address['IPAddress'].startswith('198.18.1.')
                or not server_address['IPAddress'].startswith('198.18.0.')):
            raise RuntimeError('built-in and custom workloads lacked distinct address scopes')
        for scope, expected in (('bridge', {observer_default}), (net, {server})):
            endpoints = json.loads(call('inspect_endpoints_' + scope, ['network', 'inspect', scope]))[0]['Containers']
            if {entry['Name'] for entry in endpoints.values()} != expected:
                raise RuntimeError('bridge endpoint inventory crossed namespace scopes')
        builtin_flags = ['bridge' if value == net else value for value in base]
        call('built_in_resolver', ['run', '--rm', *builtin_flags, image,
                                  '/bin/busybox', 'cat', '/etc/resolv.conf'],
             stdout=b'nameserver 198.18.1.1\n')
        call('no_cross_network_dns', ['run', '--rm', *builtin_flags, image,
                                      '/bin/busybox', 'nslookup', 'instance', '198.18.1.1'], code=1)
        if 'NXDOMAIN' not in cases['no_cross_network_dns']['stdout']:
            raise RuntimeError('custom alias resolved on the separate built-in bridge')
        call('remove_builtin_peer', ['rm', '--force', observer_default])
        call('secondary_dns_alias', ['run', '--rm', *base, '--network-alias', 'probe',
                                    image, '/bin/busybox', 'nslookup', 'instance', '198.18.0.1'])
        if server_address['IPAddress'] not in cases['secondary_dns_alias']['stdout']:
            raise RuntimeError('secondary alias resolved to a different endpoint')
        call('reject_remove_busy', ['network', 'rm', net], code=1, stderr=b'attached')
        call('application_transaction', ['run', '--rm', *base, '--network-alias', 'client',
                                         image, '/bin/busybox', 'wget', '-qO-', 'http://service:8080/proof'],
             stdout=b'private-oci-http')
        call('wait_server', ['wait', server], stdout=b'0\n')
        call('remove_server', ['rm', server], stdout=b'cj-server\n')
        for alias in ('service', 'instance'):
            call(f'removed_{alias}_dns', ['run', '--rm', *base, '--network-alias', 'probe',
                                        image, '/bin/busybox', 'nslookup', alias, '198.18.0.1'],
                 code=1)
            if 'NXDOMAIN' not in cases[f'removed_{alias}_dns']['stdout']:
                raise RuntimeError(f'removed alias still resolves: {alias}')
        no_network = ['none' if value == net else value for value in base]
        observer = 'cj-observer'
        call('create_observer', ['create', *no_network, '--name', observer, image,
                                 '/bin/busybox', 'sleep', '25'])
        call('connect_before_start', ['network', 'connect', '--alias', 'observer', net, observer])
        call('start_observer', ['start', observer], stdout=b'cj-observer\n')
        old = attached(observer)
        call('disconnect_running', ['network', 'disconnect', net, observer])
        detached = json.loads(call('inspect_detached', ['inspect', observer]))[0]
        if detached['NetworkSettings']['Networks'] or not detached['State']['Running']:
            raise RuntimeError('network disconnect changed the container lifecycle')
        call('verify_disconnected_dns', ['run', '--rm', *base, '--network-alias', 'probe',
                                         image, '/bin/busybox', 'nslookup', 'observer', '198.18.0.1'],
             code=1)
        if 'NXDOMAIN' not in cases['verify_disconnected_dns']['stdout']:
            raise RuntimeError('detached alias remained resolvable')
        call('reconnect_running', ['network', 'connect', '--alias', 'observer2', net, observer])
        new = attached(observer)
        if old['IPAddress'] != new['IPAddress'] or new['Aliases'] != ['observer2']:
            raise RuntimeError('address reuse or live alias metadata failed')
        call('verify_reconnected_dns', ['run', '--rm', *base, '--network-alias', 'probe',
                                        image, '/bin/busybox', 'nslookup', 'observer2', '198.18.0.1'])
        if new['IPAddress'] not in cases['verify_reconnected_dns']['stdout']:
            raise RuntimeError('reconnected alias resolved to the wrong address')
        companion = 'cj-companion'
        call('create_companion', ['create', *base, '--name', companion, image,
                                  '/bin/busybox', 'sleep', '25'])
        call('start_companion', ['start', companion], stdout=b'cj-companion\n')
        attached(companion)
        both = json.loads(call('inspect_both', ['network', 'inspect', net]))[0]['Containers']
        if {entry['Name'] for entry in both.values()} != {observer, companion}:
            raise RuntimeError('bridge inspection omitted a live endpoint')
        with ThreadPoolExecutor(max_workers=2) as peers:
            finished = [peers.submit(call, 'remove_' + name, ['rm', '--force', name],
                                     stdout=(name + '\n').encode())
                        for name in (observer, companion)]
            for removal in finished:
                removal.result()
        call('remove_bridge', ['network', 'rm', net], stdout=b'cj-private\n')
        call('inspect_removed', ['network', 'inspect', net], code=1, stderr=b'not found')
        second = call('recreate_bridge', ['network', 'create', *network_mode, net]).decode().strip()
        if second == identifier:
            raise RuntimeError('new bridge reused the old network identity')
        call('run_on_recreated_bridge', ['run', '--rm', *base, image, '/bin/true'], stdout=b'')
        call('remove_recreated_bridge', ['network', 'rm', net], stdout=b'cj-private\n')
        cases['frozen_lifecycle_canaries'] = frozen_canaries(endpoint, peer, docker, env)
        with INSTALL['channel'](session, pid) as (guest, _boot):
            cases['guest_after'] = INSTALL['inspect'](guest)
            if cases['guest_after']['active_workloads']:
                raise RuntimeError('finished network fixture still owns guest workloads')
    finally:
        (output / 'docker-network.json').write_text(json.dumps(cases, indent=2) + '\n')


def frozen_canaries(endpoint, peer, docker, env):
    common = WORKLOAD['COMMON']
    fixture = json.loads((common / 'scenario.json').read_text())
    archive = common / 'image.tar'
    if WORKLOAD['TOOLS']['file_hash'](archive) != FROZEN['common_static_fixture']['archive_sha256']:
        raise RuntimeError('common Docker archive differs from the frozen manifest')
    WORKLOAD['require'](WORKLOAD['cli'](docker, env, ['load', '--input', str(archive)], 120))
    metadata = json.loads(WORKLOAD['require'](WORKLOAD['cli'](docker, env, ['image', 'inspect', fixture['image']])))[0]
    if metadata['Id'] != FROZEN['common_static_fixture']['config_digest']:
        raise RuntimeError('wrong frozen common image identity')
    image = FROZEN['images']['alpine']['ref']
    limits = FROZEN['lifecycle_limits']
    fixtures = {
        'alpine-true': (limits, image, ['/bin/true'], 0, b'', b''),
        'alpine-stream-exit': (limits, image, ['/bin/sh', '-c',
            'printf docker-stdout; printf docker-stderr >&2; exit 23'], 23, b'docker-stdout', b'docker-stderr'),
        'common-static': (limits, fixture['image'], fixture['command'], 0, b'', b''),
    }
    rows = {}
    handles = set()
    token = uuid.uuid4().hex[:10]
    with closing(MATCHED['TOOLS']['UnixHTTP'](endpoint, peer)) as connection:
        try:
            for name, spec in fixtures.items():
                for network in FROZEN['suites']['lifecycle']['networks']:
                    for lane in ('api', 'cli'):
                        key = f'{name}/{network}/{lane}'
                        row = WORKLOAD['sample'](connection, docker, env, spec, network, lane, token, len(rows) + 1)
                        if row['error']:
                            raise RuntimeError(f'frozen lifecycle canary {key}: {row["error"]}')
                        row['guest_witness'] = MATCHED['native_terminal'](connection, row['name'], handles, spec[3])
                        rows[key] = row
        finally:
            if WORKLOAD['TOOLS']['cleanup_fixtures'](docker, env, token):
                raise RuntimeError('frozen lifecycle canaries left an owned container')
            WORKLOAD['require'](WORKLOAD['cli'](docker, env, ['image', 'rm', fixture['image']]))
    return rows
