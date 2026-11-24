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


def collect(endpoint, peer, docker, env, output, suite, *, lifecycle_group=None):
    contract()
    comparison = runpy.run_path(str(HERE / 'docker-comparison.py'))
    tools = comparison['TOOLS']
    manifest = comparison['contract']()
    config = Path(env['DOCKER_CONFIG'])
    fixture = output / 'matrix'
    fixture.mkdir(mode=0o700)
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
                matrix['run_matrix'](suite, manifest, report, fixture, docker, env,
                                     connection=connection)
    except (OSError, RuntimeError, ValueError, http.client.HTTPException,
            subprocess.SubprocessError) as error:
        report['error'] = str(error)
    finally:
        connection.close()
        comparison['save'](fixture / 'session.json', report)
