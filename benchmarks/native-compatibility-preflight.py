"""Capture frozen compatibility failures from the launcher-owned native endpoint."""

from contextlib import ExitStack
import hashlib
import http.client
import json
from pathlib import Path
import runpy
import subprocess

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


def collect(endpoint, peer, docker, env, output, suite):
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
                workload['run_workloads'](suite, manifest, report, fixture, connection, docker, env)
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
