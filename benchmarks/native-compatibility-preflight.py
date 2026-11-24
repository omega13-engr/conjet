"""Capture frozen compatibility failures from the launcher-owned native endpoint."""

from contextlib import ExitStack
import hashlib
import http.client
import json
from pathlib import Path
import runpy
import subprocess
import uuid

HERE = Path(__file__).resolve().parent
MANIFEST = HERE / 'scenarios/native-compatibility-v1.json'


def contract():
    frozen = json.loads(MANIFEST.read_text())
    if frozen['schema_version'] != 1:
        raise ValueError('unrecognized native compatibility manifest')
    for source, digest in frozen['sources'].items():
        path = HERE.parent / source
        with path.open('rb') as stream:
            if hashlib.file_digest(stream, 'sha256').hexdigest() != digest:
                raise ValueError(f'frozen comparison source changed: {source}')
    return frozen


def alpine_cases(workload, manifest, connection, docker, env):
    matched = runpy.run_path(str(HERE / 'native-docker-comparison.py'))
    limits = manifest['lifecycle_limits']
    image = manifest['images']['alpine']['ref']
    fixtures = {
        'alpine-true': (limits, image, ['/bin/true'], 0, b'', b''),
        'alpine-stream-exit': (limits, image, ['/bin/sh', '-c',
            'printf docker-stdout; printf docker-stderr >&2; exit 23'],
            23, b'docker-stdout', b'docker-stderr'),
    }
    token = uuid.uuid4().hex[:10]
    rows = {}
    handles = set()
    try:
        for name, spec in fixtures.items():
            for network in manifest['suites']['lifecycle']['networks']:
                for transport in ('api', 'cli'):
                    row = workload['sample'](connection, docker, env, spec, network,
                                             transport, token, len(rows) + 1)
                    rows[f'{name}/{network}/{transport}'] = row
                    if row['error'] is None:
                        try:
                            row['guest_witness'] = matched['native_terminal'](
                                connection, row['name'], handles, spec[3])
                        except (RuntimeError, OSError, http.client.HTTPException) as error:
                            row['error'] = str(error)
                            connection.close()
    finally:
        recovered = workload['TOOLS']['cleanup_fixtures'](docker, env, token)
    if recovered:
        raise RuntimeError('independent Alpine cases left owned containers')
    return rows


def qualified_lifecycle(workload, manifest, report, fixture, connection, docker, env, group):
    matched = runpy.run_path(str(HERE / 'native-docker-comparison.py'))
    run = workload['run_workloads']
    sample = run.__globals__['sample']
    handles = set()

    def with_cleanup(connection, docker, env, spec, network, lane, token, index):
        row = sample(connection, docker, env, spec, network, lane, token, index)
        if row['error'] is None:
            try:
                row['guest_witness'] = matched['native_terminal'](connection, row['name'], handles, spec[3])
            except (RuntimeError, OSError, http.client.HTTPException) as error:
                row['error'] = str(error)
                connection.close()
        return row

    # This canary is untimed qualification. Leave the frozen comparison
    # runner and its timing boundary intact.
    run.__globals__['sample'] = with_cleanup
    try:
        run('lifecycle', manifest, report, fixture, connection, docker, env, selected_group=group)
    finally:
        run.__globals__['sample'] = sample


def event_snapshot(connection, api_version):
    connection.request('GET', f'/v{api_version}/events')
    with connection.getresponse() as response:
        raw = response.read(65537)
        if response.status != 200 or len(raw) > 65536:
            raise RuntimeError('native event snapshot was unavailable')
    return map(json.loads, raw.splitlines())


def qualified_control(matrix, manifest, report, fixture, connection, docker, env):
    run = matrix['run_matrix']
    driver = run.__globals__['Docker']

    class PrepareWitness(driver):
        def call(self, scenario, args, **options):
            result = super().call(scenario, args, **options)
            if scenario == 'control-start' and result:
                report['persistent_id'] = result.decode().strip()
            if scenario == 'control-remove' and result is not None:
                report['persistent_events'] = [
                    event for event in event_snapshot(connection, manifest['docker_api'])
                    if event['Actor']['ID'] == report['persistent_id']
                ]
            return result

    run.__globals__['Docker'] = PrepareWitness
    try:
        run('control', manifest, report, fixture, docker, env, connection=connection)
    finally:
        run.__globals__['Docker'] = driver


def qualified_storage(matrix, manifest, report, fixture, connection, docker, env):
    run = matrix['run_matrix']
    driver = run.__globals__['Docker']
    handles = set()
    scenario_names = {
        'storage.writable-layer', 'storage.volume', 'storage.volume.readback', 'storage.bind',
    }

    class StorageWitness(driver):
        def call(self, scenario, args, **options):
            result = super().call(scenario, args, **options)
            if result is None or scenario not in scenario_names:
                return result
            row = self.rows[-1]
            try:
                events = [
                    event for event in event_snapshot(connection, manifest['docker_api'])
                    if event['Actor']['Attributes'].get(matrix['LABEL']) == self.token
                ]
                if [event['Action'] for event in events[-2:]] != ['die', 'destroy']:
                    raise RuntimeError('native storage workload was not removed')
                died, destroyed = events[-2:]
                witness = died['Actor']['Attributes']
                handle = witness.get('conjet.native_handle')
                if (died['Actor']['ID'] != destroyed['Actor']['ID']
                        or witness.get('conjet.backend') != 'jetstream-native-oci'
                        or witness.get('conjet.guest_cleanup') != 'complete'
                        or (scenario == 'storage.bind' and witness.get('conjet.bind_cleanup') != 'complete')
                        or witness.get('exitCode') != '0' or not handle or handle in handles):
                    raise RuntimeError('native storage workload did not confirm its own cleanup')
                handles.add(handle)
                row['guest_witness'] = witness
                if scenario == 'storage.bind':
                    declaration = args[args.index('--mount') + 1]
                    fields = dict(part.split('=', 1) for part in declaration.split(','))
                    source = Path(fields['source']).resolve(strict=True)
                    if not source.is_relative_to(fixture):
                        raise RuntimeError('native storage source escaped its fixture directory')
                    with (source / 'test').open('rb') as mounted:
                        row['host_sha256'] = hashlib.file_digest(mounted, 'sha256').hexdigest()
                return result
            except (OSError, RuntimeError, ValueError, KeyError, http.client.HTTPException) as error:
                row['error'] = str(error)
                connection.close()
                return None

    run.__globals__['Docker'] = StorageWitness
    try:
        run('storage_network', manifest, report, fixture, docker, env, connection=connection)
    finally:
        run.__globals__['Docker'] = driver


def qualified_compose(matrix, manifest, report, fixture, connection, docker, env):
    run = matrix['run_matrix']
    driver = run.__globals__['Docker']

    class ComposeWitness(driver):
        def call(self, scenario, args, **options):
            result = super().call(scenario, args, **options)
            if scenario == 'compose.scale' and result is not None:
                row = self.rows[-1]
                project = args[args.index('--project-name') + 1]
                row['dns_witness'] = self.dns_witness(project)
                return result
            if scenario != 'compose.up':
                return result
            row = self.rows[-1]
            project = args[args.index('--project-name') + 1]
            redis = f'{project}-redis-1'
            if result is None:
                for service in ('redis', 'app'):
                    super().call('compose-failed-service-logs',
                                 ['logs', f'{project}-{service}-1'],
                                 phase='verification', timeout=5)
            probe = self.probe
            running = probe(row, 'compose-redis-running',
                            ['inspect', '--format', '{{.State.Running}}', redis])
            if running == b'true\n':
                status = probe(row, 'compose-redis-process', ['exec', redis, 'cat', '/proc/1/status'])
                if status is not None:
                    expected = {'Uid': ['999'] * 4, 'Gid': ['1000'] * 4, 'Groups': [],
                                'CapEff': ['0000000000000000'], 'NoNewPrivs': ['1']}
                    fields = {}
                    for line in status.decode().splitlines():
                        key, _, value = line.partition(':')
                        if key in expected:
                            fields[key] = value.split()
                    if fields != expected:
                        row['witness'][-1]['error'] = 'Redis process identity differs from the pinned image'
            return result

        def probe(self, row, label, args):
            result = super().call(label, args, phase='verification', timeout=5)
            row.setdefault('witness', []).append(self.rows.pop())
            return result

        def dns_witness(self, project):
            row = self.rows[-1]
            instances = [f'{project}-app-1', f'{project}-app-2']
            owned = self.probe(row, 'compose-replica-ips', ['inspect', *instances])
            if owned is None:
                return False
            addresses = [
                entry['NetworkSettings']['Networks'][f'{project}_default']['IPAddress']
                for entry in json.loads(owned)
            ]
            code = ("const dns=require('node:dns').promises;"
                    "Promise.all(process.argv.slice(1).map(name=>dns.resolve4(name)))"
                    ".then(answers=>console.log(JSON.stringify(answers)))"
                    ".catch(error=>{console.error(error.message);process.exitCode=1})")
            result = self.probe(row, 'compose-live-dns',
                                ['exec', instances[0], 'node', '-e', code, 'app', *instances])
            if result is None:
                return False
            service, *individual = json.loads(result)
            return (len(set(addresses)) == 2 and set(service) == set(addresses)
                    and individual == [[ip] for ip in addresses])

    run.__globals__['Docker'] = ComposeWitness
    try:
        run('compose', manifest, report, fixture, docker, env, connection=connection)
    finally:
        run.__globals__['Docker'] = driver


def qualified_stress(matrix, manifest, report, fixture, connection, docker, env):
    run = matrix['run_matrix']
    driver = run.__globals__['Docker']
    ids = {}
    handles = set()
    terminal_operations = {
        'pressure-target-remove': ('pressure-create', 137),
        'pressure-survivor-remove': ('pressure-survivor-create', 137),
        'pressure-recovery': (None, 0),
    }

    class StressWitness(driver):
        def call(self, scenario, args, **options):
            result = super().call(scenario, args, **options)
            if result is None:
                return result
            if scenario in ('pressure-create', 'pressure-survivor-create'):
                ids[scenario] = result.decode().strip()
            if scenario not in terminal_operations:
                return result
            row = self.rows[-1]
            origin, code = terminal_operations[scenario]
            try:
                events = [
                    event for event in event_snapshot(connection, manifest['docker_api'])
                    if event['Actor']['Attributes'].get(matrix['LABEL']) == self.token
                    and (origin is None or event['Actor']['ID'] == ids[origin])
                ]
                if [event['Action'] for event in events[-2:]] != ['die', 'destroy']:
                    raise RuntimeError('native stress generation was not removed')
                died, destroyed = events[-2:]
                witness = died['Actor']['Attributes']
                handle = witness.get('conjet.native_handle')
                if (died['Actor']['ID'] != destroyed['Actor']['ID']
                        or witness.get('conjet.backend') != 'jetstream-native-oci'
                        or witness.get('conjet.guest_cleanup') != 'complete'
                        or witness.get('exitCode') != str(code) or not handle or handle in handles):
                    raise RuntimeError('native stress workload did not confirm its own cleanup')
                handles.add(handle)
                row['guest_witness'] = witness
            except (OSError, RuntimeError, ValueError, KeyError, http.client.HTTPException) as error:
                row['error'] = str(error)
                connection.close()
            return result

    run.__globals__['Docker'] = StressWitness
    try:
        run('stress', manifest, report, fixture, docker, env, connection=connection)
    finally:
        run.__globals__['Docker'] = driver


def collect(endpoint, peer, docker, env, output, suite, *, lifecycle_group=None):
    contract()
    comparison = runpy.run_path(str(HERE / 'docker-comparison.py'))
    tools = comparison['TOOLS']
    manifest = comparison['contract']()
    config = Path(env['DOCKER_CONFIG'])
    fixture = output / 'matrix'
    fixture.mkdir(mode=0o700, exist_ok=suite == 'storage_network')
    if fixture.resolve(strict=True) != fixture or fixture.stat().st_mode & 0o077:
        raise RuntimeError('the frozen matrix requires a private fixture directory')
    # The original controlled registry uses this index to seed fixture bytes.
    comparison['save'](output / 'pair.json', {'pair': 1, 'scope': 'compatibility-preflight'})
    report = {'engine': 'conjet', 'backend': 'jetstream-native-oci',
              'endpoint': str(endpoint), 'peer_pid': peer,
              'scope': 'compatibility-preflight', 'mode': suite}
    connection = tools['UnixHTTP'](endpoint, peer)
    try:
        with ExitStack() as resources:
            report['clients'] = comparison['configure_clients'](config, manifest, resources)
            env = dict(env, DOCKER_API_VERSION=manifest['docker_api'])
            if suite == 'lifecycle':
                workload = runpy.run_path(str(HERE / 'docker-comparison-workloads.py'))
                try:
                    qualified_lifecycle(workload, manifest, report, fixture, connection,
                                        docker, env, lifecycle_group)
                except (OSError, RuntimeError, ValueError, http.client.HTTPException,
                        subprocess.SubprocessError) as error:
                    report['error'] = str(error)
                if not report.get('groups'):
                    # A missing common archive does not prevent independent
                    # correctness probes through the same frozen runner.
                    report['independent_alpine'] = alpine_cases(
                        workload, manifest, connection, docker, env)
            else:
                matrix = runpy.run_path(str(HERE / 'docker-comparison-matrix.py'))
                if suite == 'control':
                    qualified_control(matrix, manifest, report, fixture, connection, docker, env)
                elif suite == 'storage_network':
                    qualified_storage(matrix, manifest, report, fixture, connection, docker, env)
                elif suite == 'compose':
                    qualified_compose(matrix, manifest, report, fixture, connection, docker, env)
                elif suite == 'stress':
                    qualified_stress(matrix, manifest, report, fixture, connection, docker, env)
                else:
                    matrix['run_matrix'](suite, manifest, report, fixture, docker, env,
                                         connection=connection)
    except (OSError, RuntimeError, ValueError, http.client.HTTPException,
            subprocess.SubprocessError) as error:
        report['error'] = str(error)
    finally:
        connection.close()
        comparison['save'](fixture / 'session.json', report)
