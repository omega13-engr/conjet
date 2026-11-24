"""Capture frozen compatibility failures from the launcher-owned native endpoint."""

from contextlib import ExitStack
import hashlib
import http.client
import io
import json
from pathlib import Path
import re
import runpy
import signal
import subprocess
import tarfile
import time
from urllib.parse import quote, urlencode
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


def qualified_registry(matrix, manifest, report, fixture, connection, docker, env, suite):
    run = matrix['run_matrix']
    driver = run.__globals__['Docker']
    handles = set()

    class RegistryWitness(driver):
        registry_name = None

        def call(self, scenario, args, **options):
            cached = scenario in ('registry.small.cached', 'registry.multilayer.cached')
            if cached:
                repository = args[-1].split('/', 1)[1].split('@', 1)[0]
                before = self.registry_reads(repository)
            result = super().call(scenario, args, **options)
            row = self.rows[-1]
            if result is None:
                return result
            if scenario == 'registry-start':
                self.registry_name = args[args.index('--name') + 1]
            if cached:
                after = self.registry_reads(repository)
                if before is None or after is None or not before:
                    row['error'] = 'registry cache transfer could not be observed'
                elif after != before:
                    row['error'] = 'cached image triggered another registry GET'
                else:
                    row['no_registry_get'] = True
                row['registry_gets_before'] = before
                row['registry_gets_after'] = after
            if scenario == 'registry-run-proof':
                try:
                    events = [
                        event for event in event_snapshot(connection, manifest['docker_api'])
                        if event['Actor']['Attributes'].get(matrix['LABEL']) == self.token
                        and event['Actor']['Attributes'].get('image') == args[-1]
                    ]
                    if [event['Action'] for event in events[-2:]] != ['die', 'destroy']:
                        raise RuntimeError('registry workload did not reach native teardown')
                    witness = events[-2]['Actor']['Attributes']
                    handle = witness.get('conjet.native_handle')
                    if (events[-1]['Actor']['ID'] != events[-2]['Actor']['ID']
                            or witness.get('conjet.backend') != 'jetstream-native-oci'
                            or witness.get('conjet.guest_cleanup') != 'complete'
                            or witness.get('exitCode') != '0' or not handle or handle in handles):
                        raise RuntimeError('registry workload cleanup identity was invalid')
                    handles.add(handle)
                    row['guest_witness'] = witness
                except (OSError, RuntimeError, ValueError, KeyError, http.client.HTTPException) as error:
                    row['error'] = str(error)
                    connection.close()
            return result

        def registry_reads(self, repository):
            result = super().call('registry-cache-observation',
                                  ['logs', '--tail', '24', self.registry_name],
                                  phase='verification', output_limit=32768)
            if result is None:
                return None
            row = self.rows[-1]
            lines = (row.get('stdout', '') + row.get('stderr', '')).splitlines()
            return sorted(line for line in lines if 'http.request.method=GET ' in line
                          and f'http.request.uri="/v2/{repository}/' in line)

    if suite == 'registry-service':
        runner = RegistryWitness(docker, env, fixture, report)
        matrix['run_registry'](runner, manifest)
    else:
        run.__globals__['Docker'] = RegistryWitness
        try:
            run('images', manifest, report, fixture, docker, env, connection=connection)
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
    cancel_stress(driver, matrix['LABEL'], manifest, report, fixture, connection, docker, env)


def cancel_stress(driver, label, manifest, report, fixture, connection, docker, env):
    witness = {}
    runner = driver(docker, env, fixture, witness)
    report['cancellation'] = witness
    image = manifest['images']['alpine']['ref']
    common = ['--network', 'none', '--pull', 'never', '--label', f'{label}={runner.token}',
              '--memory', '16777216', '--pids-limit', '4', '--cpus', '0.5']
    source = b'active-data-through-cancellation'
    owned = []

    def call(name, args, **options):
        result = runner.call(name, args, phase='verification', **options)
        if result is None:
            raise RuntimeError(f'concurrent cancellation: {name} failed')
        return result

    try:
        for index in range(max(manifest['concurrency'])):
            ident = call('create', ['create', *common, '--name', f'{runner.token}-{index}',
                         image, '/bin/sh', '-c', 'printf %s "$1" >/tmp/owned; exec sleep 120',
                         'sh', source.decode()]).decode().strip()
            if len(ident) != 64 or not all(ch in '0123456789abcdef' for ch in ident) or ident in owned:
                raise RuntimeError('concurrent cancellation returned an invalid container identity')
            owned.append(ident)
        call('start', ['start', *owned])
        state = ['inspect', '--format', '{{.Id}} {{.State.Running}}']
        call('all-running', [*state, *owned],
             expected=''.join(f'{ident} true\n' for ident in owned).encode())
        survivor, *cancelled = owned
        readback = ['exec', survivor, 'cat', '/tmp/owned']
        call('survivor-before', readback, expected=source)
        call('kill', ['kill', '--signal', 'KILL', *cancelled])
        call('cancelled-exits', ['wait', *cancelled], expected=b'137\n' * len(cancelled))
        call('remove-cancelled', ['rm', *cancelled])
        call('survivor-running', [*state, survivor], expected=f'{survivor} true\n'.encode())
        verified = call('survivor-after', readback, expected=source)
        call('remove-survivor', ['rm', '-f', survivor])
        call('recovery', ['run', '--name', runner.token + '-recovery', '--rm', *common,
                          image, '/bin/echo', 'cancellation-recovered'],
             expected=b'cancellation-recovered\n')
        connection.close()
        events = [event for event in event_snapshot(connection, manifest['docker_api'])
                  if event['Actor']['Attributes'].get(label) == runner.token]
        witness.update(cancelled=cancelled, survivor=survivor, events=events,
                       data_sha256=hashlib.sha256(verified).hexdigest(),
                       recovery_name=runner.token + '-recovery')
    except (KeyError, OSError, RuntimeError, ValueError, http.client.HTTPException) as error:
        witness['error'] = str(error)
    finally:
        remaining = runner.call('inventory', ['ps', '-aq', '--filter', f'label={label}={runner.token}'],
                                phase='cleanup')
        if remaining != b'':
            for ident in (remaining.decode().splitlines() if remaining is not None else owned):
                if 12 <= len(ident) <= 64 and all(ch in '0123456789abcdef' for ch in ident):
                    runner.call('recover-owned', ['rm', '-f', ident], phase='cleanup')
            witness['error'] = witness.get('error', 'concurrent cancellation left owned workloads')


def build_state_reader(session, vm_pid):
    native = runpy.run_path(str(HERE / 'native-oci-live-install.py'))

    def state():
        with native['channel'](session, vm_pid) as (stream, boot):
            result = native['exchange'](stream, 20, {'budget_ms': 1000, 'include_builds': True}, 20)
            if result['boot_id'] != boot:
                raise RuntimeError('build witness belongs to another Core boot')
            return result

    return state


def qualified_builds(matrix, manifest, report, fixture, connection, docker, env,
                     session, vm_pid, build_bases):
    state = build_state_reader(session, vm_pid)
    run = matrix['run_matrix']
    driver = run.__globals__['Docker']
    api = '/v' + manifest['docker_api']

    def get(path, expected):
        connection.close()
        connection.request('GET', api + path)
        with connection.getresponse() as response:
            body = response.read(65537)
            if len(body) > 65536:
                raise RuntimeError('build API witness exceeded its response limit')
            parsed = json.loads(body)
            if response.status != expected:
                detail = parsed.get('message', '')
                raise RuntimeError(f'build API witness expected {expected} for {path}, got {response.status} {detail}')
        return parsed

    class BuildWitness(driver):
        worker = None
        expected_image = None

        def runs_since(self, before):
            return [child for child in state()['builds'] if child['sequence'] > before
                    and child['parent'] == self.worker['workload_id']]

        def run_cursor(self):
            return max((child['sequence'] for child in self.runs_since(0)), default=0)

        def call(self, scenario, args, **options):
            export = scenario.endswith('.build-export')
            if export:
                before = self.run_cursor()
            result = super().call(scenario, args, **options)
            if result is None:
                return result
            row = self.rows[-1]
            try:
                if scenario == 'builder-backing':
                    [docker_worker] = json.loads(result)
                    [guest_worker] = [child for child in state()['builds']
                                      if child['worker'] and child['phase'] == 'running']
                    self.worker = guest_worker['handle']
                    self.exported_configs = set()
                    row['worker'] = {
                        'handle': self.worker, 'id': docker_worker['Id'],
                        'name': str(args[1]), 'image': docker_worker['Config']['Image'],
                        'privileged': docker_worker['HostConfig']['Privileged'],
                        'mounts': docker_worker['Mounts'],
                    }
                elif export:
                    row['native_runs'] = self.runs_since(before)
                    archive = Path(next(arg.removeprefix('type=docker,dest=') for arg in map(str, args)
                                        if arg.startswith('type=docker,dest=')))
                    tag = args[args.index('--tag') + 1]
                    with archive.open('rb') as stream:
                        row['archive_sha256'] = hashlib.file_digest(stream, 'sha256').hexdigest()
                    with tarfile.open(archive, 'r:') as tar:
                        [exported] = json.load(tar.extractfile('manifest.json'))
                        if exported['RepoTags'] != [tag]:
                            raise RuntimeError('build archive exported a different image tag')
                        config = tar.getmember(exported['Config'])
                        if not config.isfile() or config.size > 1024 * 1024:
                            raise RuntimeError('build archive contains an invalid image config')
                        row['config_digest'] = 'sha256:' + hashlib.file_digest(
                            tar.extractfile(config), 'sha256').hexdigest()
                    self.expected_image = tag, row['config_digest']
                elif scenario.endswith('.load'):
                    tag, digest = self.expected_image
                    image = get('/images/' + quote(tag, safe='') + '/json', 200)
                    if (image['Id'], image['Architecture'], image['Os']) != (digest, 'arm64', 'linux'):
                        raise RuntimeError('loaded build image differs from its exported ARM64 config')
                    row['config_digest'] = image['Id']
                    self.exported_configs.add(image['Id'])
                elif scenario.endswith('.built-image-canary'):
                    connection.close()
                    die, destroy = [event for event in event_snapshot(connection, manifest['docker_api'])
                                    if event['Actor']['Attributes'].get(matrix['LABEL']) == self.token][-2:]
                    if (die['Action'], destroy['Action']) != ('die', 'destroy') or (
                            die['Actor']['ID'] != destroy['Actor']['ID']):
                        raise RuntimeError('export canary lacks its own native teardown')
                    row['guest_witness'] = die['Actor']['Attributes']
                elif scenario == 'builder-remove' and self.worker:
                    name = 'buildx_buildkit_' + str(args[-1]) + '0'
                    get('/containers/' + name + '/json', 404)
                    get('/volumes/' + name + '_state', 404)
                    [terminal] = [child for child in state()['builds'] if child['handle'] == self.worker]
                    row['native_worker'] = terminal
                    remaining = {image['Id'] for image in get('/images/json', 200)}
                    row['exports_released'] = not remaining.intersection(self.exported_configs)
                    if not row['exports_released']:
                        raise RuntimeError('build archive backing remained after the last tag was removed')
                    self.worker = None
                elif (scenario == 'builder.cgroup.after-builds' and self.worker
                      and str(args[1]).endswith('-node-00') and build_bases is None):
                    build_failure_cancellation(self, manifest)
            except (KeyError, OSError, RuntimeError, StopIteration, TypeError, ValueError,
                    http.client.HTTPException, tarfile.TarError) as error:
                row['error'] = str(error)
                connection.close()
                return None
            return result

    run.__globals__['Docker'] = BuildWitness
    try:
        run('builds', manifest, report, fixture, docker, env, build_bases=build_bases, connection=connection)
    finally:
        run.__globals__['Docker'] = driver


def build_failure_cancellation(driver, manifest):
    worker = driver.worker
    builder = driver.token + '-node-0'
    fixture = driver.output / (builder + '-cancellation')
    fixture.mkdir(mode=0o700)
    data = driver.report['failure_cancellation'] = {'worker': worker}
    dockerfile = fixture / 'Dockerfile'
    image = manifest['images']['node']['ref']
    prefix = ['buildx', 'build', '--builder', builder, '--platform', 'linux/arm64',
              '--network', 'none', '--progress', 'plain', '--no-cache',
              '--output', 'type=cacheonly', fixture]
    try:
        dockerfile.write_text(f'FROM {image}\nRUN printf expected-build-failure >&2; exit 23\n')
        before = driver.run_cursor()
        result = driver.call('build-failure', prefix, phase='verification', timeout=90, expected_code=1)
        if result is None:
            raise RuntimeError('Buildx did not report the failing RUN')
        [failed] = driver.runs_since(before)
        data['failed'] = failed
        if failed['exit'] != {'code': 23} or failed['cleanup'] != 'complete':
            raise RuntimeError('failed RUN lacked its native exit or cleanup')

        command = ("console.log('cancel-run-active'); console.error('cancel-run-stderr'); "
                   "setTimeout(() => process.exit(91), 28000)")
        dockerfile.write_text(f'FROM {image}\nRUN ' + json.dumps(['/usr/local/bin/node', '-e', command]) + '\n')
        before = driver.run_cursor()
        stderr = fixture / 'cancel.stderr'
        with (fixture / 'cancel.stdout').open('wb') as output, stderr.open('wb') as errors:
            with subprocess.Popen([*driver.prefix, *prefix], env=driver.env,
                                  stdin=subprocess.DEVNULL, stdout=output, stderr=errors) as child:
                try:
                    until = time.monotonic() + 24
                    while time.monotonic() < until and child.poll() is None:
                        progress = stderr.read_bytes()
                        if all(re.search(rb'^#\d+ [0-9.]+ ' + marker + rb'\r?$', progress, re.MULTILINE)
                               for marker in (b'cancel-run-active', b'cancel-run-stderr')):
                            [active] = driver.runs_since(before)
                            if active['phase'] != 'running':
                                raise RuntimeError('cancellation marker did not come from an active RUN')
                            data['active'] = active
                            break
                        time.sleep(0.05)
                    else:
                        raise RuntimeError('Buildx did not stream both markers from a live RUN')
                    child.send_signal(signal.SIGINT)
                    data['client_exit'] = child.wait(timeout=12)
                    until = time.monotonic() + 10
                    while time.monotonic() < until:
                        [terminal] = driver.runs_since(before)
                        if terminal['handle'] != active['handle']:
                            raise RuntimeError('cancellation changed the native RUN generation')
                        if terminal['cleanup'] == 'complete':
                            data['terminal'] = terminal
                            break
                        time.sleep(0.05)
                    else:
                        raise RuntimeError('cancelled RUN did not confirm cleanup')
                finally:
                    if child.poll() is None:
                        child.kill()
                        child.wait(timeout=5)
    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
        data['error'] = str(error)


def qualified_build_api(matrix, manifest, report, fixture, connection, docker, env, session, vm_pid):
    state = build_state_reader(session, vm_pid)
    runner = matrix['Docker'](docker, env, fixture, report)
    image = manifest['images']['alpine']['ref']
    token = 'cj-api-' + uuid.uuid4().hex[:12]
    canary = b'native-build-api\n'
    tag = token + ':ready'
    bad_tag = token + ':failure'
    result = {}
    report['docker_build_api'] = result
    used_handles = set()

    def request(name, target, instructions):
        before = {row['handle']['workload_id'] for row in state()['builds']}
        buffer = io.BytesIO()
        with tarfile.open(fileobj=buffer, mode='w') as archive:
            for path, content in [('Dockerfile', instructions.encode()), ('marker', canary)]:
                entry = tarfile.TarInfo(path)
                entry.size = len(content)
                archive.addfile(entry, io.BytesIO(content))
        connection.close()
        connection.timeout = 300
        query = urlencode({'t': target, 'platform': 'linux/arm64', 'networkmode': 'none', 'version': 1})
        connection.request('POST', f"/v{manifest['docker_api']}/build?{query}", buffer.getvalue(),
                           {'Content-Type': 'application/x-tar', 'Connection': 'close'})
        with connection.getresponse() as response:
            raw = response.read(128 * 1024 + 1)
            if len(raw) > 128 * 1024:
                raise RuntimeError('native Docker build response exceeds its expected bound')
            current = {'status': response.status, 'body': [json.loads(line) for line in raw.splitlines()]}
            result[name] = current
        connection.close()
        connection.timeout = 20
        current['native'] = [row for row in state()['builds'] if row['handle']['workload_id'] not in before]
        return current

    try:
        request('failed', bad_tag, f'FROM {image}\nRUN printf api-failure >&2; exit 23\n')
        ready = request('ready', tag, f'FROM {image}\nCOPY marker /marker\n'
                        'RUN cat /marker >/built\nCMD ["/bin/cat", "/built"]\n')
        if ready['status'] != 200 or not any(item.get('stream') == f'Loaded image: {tag}\n'
                                              for item in ready['body']):
            raise RuntimeError('native Docker build did not publish the exported archive')
        inspected = runner.inspect(tag)
        if inspected is None:
            raise RuntimeError('native Docker build result is missing')
        result['image'] = inspected['Id']
        started = runner.call('api-built-image', ['run', '--rm', '--name', token, '--pull', 'never',
                              '--network', 'none', tag], expected=canary, phase='verification')
        if started is None:
            raise RuntimeError('native Docker API image failed its canary')
        terminal = runpy.run_path(str(HERE / 'native-docker-comparison.py'))['native_terminal']
        result['guest_witness'] = terminal(connection, token, used_handles)
    except (KeyError, OSError, RuntimeError, ValueError, http.client.HTTPException) as error:
        result['error'] = str(error)
    finally:
        connection.close()
        for target in (tag, bad_tag):
            existing = runner.call('api-image-inventory', ['image', 'ls', '--quiet', target], phase='cleanup')
            if existing and target == bad_tag:
                result['failure_tag_published'] = True
            if existing:
                runner.call('api-image-remove', ['image', 'rm', target], phase='cleanup')
            runner.call('api-image-absent', ['image', 'ls', '--quiet', target], expected=b'', phase='cleanup')
        comparison = runpy.run_path(str(HERE / 'docker-comparison.py'))
        comparison['save'](fixture.parent / 'docker-build-api.json', result)


def collect(endpoint, peer, docker, env, output, suite, *, lifecycle_group=None,
            build_bases=None, build_language=None, build_api=False, direct_tools=None,
            session=None, vm_pid=None):
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
    if build_bases is not None:
        if suite != 'builds':
            raise ValueError('OCI build bases require the builds suite')
        report['input_source'] = 'verified-oci-layout'
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
                elif suite in ('images', 'registry-service'):
                    qualified_registry(matrix, manifest, report, fixture, connection, docker, env, suite)
                elif suite == 'storage_network':
                    qualified_storage(matrix, manifest, report, fixture, connection, docker, env)
                elif suite == 'compose':
                    qualified_compose(matrix, manifest, report, fixture, connection, docker, env)
                elif suite == 'stress':
                    qualified_stress(matrix, manifest, report, fixture, connection, docker, env)
                elif suite == 'builds':
                    if build_api:
                        qualified_build_api(matrix, manifest, report, fixture, connection, docker, env,
                                            session, vm_pid)
                    elif direct_tools:
                        direct = runpy.run_path(str(HERE / 'native-buildkit-direct.py'))
                        runner = matrix['Docker'](docker, env, fixture, report)
                        direct['collect'](runner, manifest, build_state_reader(session, vm_pid), *direct_tools)
                    else:
                        if build_language:
                            manifest['suites']['builds']['workloads'] = [build_language]
                            report['build_language'] = build_language
                        qualified_builds(matrix, manifest, report, fixture, connection, docker, env,
                                         session, vm_pid, build_bases)
    except (OSError, RuntimeError, ValueError, http.client.HTTPException,
            subprocess.SubprocessError) as error:
        report['error'] = str(error)
    finally:
        connection.close()
        comparison['save'](fixture / 'session.json', report)
