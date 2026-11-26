"""Collect serial native-only diagnostic samples with normal CLI API negotiation."""

import argparse
from collections import Counter
import json
from pathlib import Path
import runpy
from statistics import median
import time
from urllib.parse import quote


MATCHED = runpy.run_path(str(Path(__file__).with_name('native-docker-comparison.py')))
CANARIES = {
    'true': (['/bin/true'], 0, b'', b''),
    'streams': (['/bin/sh', '-c', 'printf matched-out; printf matched-err >&2; exit 23'],
                23, b'matched-out', b'matched-err'),
}


def collect_output_checks(connection, docker, env, directory, handles):
    tools = MATCHED['TOOLS']
    image = MATCHED['IMAGE']['ref']
    prefix = MATCHED['PREFIX']
    full_stream = 'n=0; while [ "$n" -lt 64 ]; do printf "%01024d" 0; n=$((n+1)); done'
    expected = b'0' * 65536
    checks = {}
    for size in (65535, 65536):
        name = f'cjdiag-boundary-{size}'
        command = full_stream if size == 65536 else full_stream.replace(
            '-lt 64', '-lt 63') + '; printf "%01023d" 0'
        MATCHED['invoke'](docker, env, ['run', *MATCHED['FLAGS'], '--name', name, image,
                                        '/bin/sh', '-c', command], stdout=expected[:size])
        checks[name] = MATCHED['native_terminal'](connection, name, handles)
    for case in ('overflow', 'slow-reader', 'disconnect'):
        name = 'cjdiag-' + case
        path = prefix + '/containers/' + name
        command = {'overflow': full_stream + '; printf x',
                   'slow-reader': full_stream + '; { ' + full_stream + '; } >&2',
                   'disconnect': full_stream}[case]
        tools['api'](connection, 'POST', prefix + '/containers/create?name=' + name, (201,), {
            'Image': image, 'User': MATCHED['USER'], 'Cmd': ['/bin/sh', '-c', command],
            'HostConfig': MATCHED['HOST_CONFIG']})
        attach = None
        response = None
        try:
            if case != 'overflow':
                attach = tools['UnixHTTP'](connection.endpoint, connection.pid)
                attach.request('POST', path + '/attach?stream=1&stdout=1&stderr=1')
                response = attach.getresponse()
                if response.status != 101:
                    raise RuntimeError(f'{case} attach upgrade failed')
                if case == 'disconnect':
                    response.close()
                    attach.close()
            tools['api'](connection, 'POST', path + '/start', (204,))
            wait = tools['api'](connection, 'POST', path + '/wait?condition=not-running', (200,))
            if case == 'overflow':
                expected_wait = {'StatusCode': 125, 'Error': {
                    'Message': 'OCI output exceeds the Docker adapter limit'}}
            else:
                expected_wait = {'StatusCode': 0, 'Error': None}
            if wait != expected_wait:
                raise RuntimeError(f'{case} returned unexpected wait status: {wait}')
            tools['api'](connection, 'DELETE', path, (204,))
            checks[name] = {'wait': wait, 'witness': MATCHED['native_terminal'](connection, name, handles)}
            # Confirm a subsequent real launch completes even if the earlier
            # attach client has left all of its output unread.
            MATCHED['lifecycle'](connection, name + '-reuse', {})
            checks[name]['reuse'] = MATCHED['native_terminal'](connection, name + '-reuse', handles)
        finally:
            if response is not None:
                response.close()
            if attach is not None:
                attach.close()
    (directory / 'output-checks.json').write_text(json.dumps(checks, indent=2) + '\n')


def collect_contract_checks(connection, directory):
    api = MATCHED['TOOLS']['api']
    prefix = MATCHED['PREFIX']
    name = 'cjdiag-contract'
    path = prefix + '/containers/' + name
    create = prefix + '/containers/create?name=' + name
    config = {'Image': MATCHED['IMAGE']['ref'], 'User': MATCHED['USER'],
              'Cmd': ['/bin/busybox', 'sleep', '30'], 'HostConfig': MATCHED['HOST_CONFIG']}
    checks = {}
    checks['wrong_api'] = api(connection, 'GET', '/v1.50/version', (400,))
    checks['missing_container'] = api(connection, 'GET', path + '/json', (404,))
    checks['unsupported_bind'] = api(connection, 'POST', create, (400,), {
        **config, 'HostConfig': {**config['HostConfig'], 'Binds': ['/invalid:/invalid']}})
    checks['unsupported_api'] = api(connection, 'POST', prefix + '/build', (501,))
    checks['invalid_object'] = api(connection, 'POST', create, (400,), [])
    item = api(connection, 'POST', create, (201,), config)
    inspect = api(connection, 'GET', path + '/json', (200,))
    if inspect['Id'] != item['Id'] or inspect['State']['Status'] != 'created':
        raise RuntimeError('inspect did not reflect the created container')
    checks['inspect_created'] = inspect['State']
    capacity = api(connection, 'GET', '/version', (200,)).get('ConjetContainerCapacity', 1)
    for index in range(capacity - 1):
        api(connection, 'POST', create + f'-extra-{index}', (201,), config)
    checks['capacity'] = api(connection, 'POST', create + '-other', (409,), config)
    for index in range(capacity - 1):
        api(connection, 'DELETE', path + f'-extra-{index}', (204,))
    api(connection, 'POST', path + '/start', (204,))
    checks['duplicate_start'] = api(connection, 'POST', path + '/start', (409,))
    checks['running_removal_without_force'] = api(connection, 'DELETE', path, (409,))
    time.sleep(0.15)
    api(connection, 'DELETE', path + '?force=true', (204,))
    checks['inspect_removed'] = api(connection, 'GET', path + '/json', (404,))
    connection.request('GET', prefix + '/events')
    response = connection.getresponse()
    events = [json.loads(line) for line in response.read(65537).splitlines()]
    owned = [event for event in events if event['Actor']['ID'] == item['Id']]
    if [event['Action'] for event in owned] != ['create', 'start', 'die', 'destroy']:
        raise RuntimeError('cancel did not complete exactly one lifecycle')
    witness = owned[2]['Actor']['Attributes']
    if (witness['conjet.backend'] != 'jetstream-native-oci' or witness['conjet.guest_cleanup'] != 'complete'
            or not witness['conjet.native_handle'] or witness['exitCode'] == '0'):
        raise RuntimeError('forced removal lacks a cancelled native workload witness')
    checks['cancelled'] = witness
    (directory / 'contract-checks.json').write_text(json.dumps(checks, indent=2) + '\n')


def collect(endpoint, peer, docker, env, directory):
    tools = MATCHED['TOOLS']
    manifest = MATCHED['MANIFEST']
    image = MATCHED['IMAGE']
    if tools['file_hash'](Path(docker[0])) != manifest['clients']['docker']['sha256']:
        raise RuntimeError('diagnostic Docker client differs from the frozen version')
    connection = tools['UnixHTTP'](endpoint, peer)
    handles = set()
    try:
        version = tools['api'](connection, 'GET', '/version', (200,))
        loaded = tools['api'](connection, 'GET',
                              MATCHED['PREFIX'] + '/images/' + quote(image['ref'], safe='') + '/json', (200,))
        if (version['Platform']['Name'] != 'Conjet Native OCI' or loaded['Id'] != image['config_digest']
                or loaded['Architecture'] != 'arm64'):
            raise RuntimeError('diagnostic endpoint or fixture differs from the native contract')
        with (directory / 'client.jsonl').open('x') as samples:
            for index in range(44):
                if index == 4:
                    # An idle period longer than the native I/O timeout
                    # exercises connection reuse outside a request deadline.
                    time.sleep(11)
                for fixture, (argv, code, stdout, stderr) in CANARIES.items():
                    for lane in ('api', 'cli'):
                        name = f'cjdiag-{fixture}-{lane}-{index}'
                        stages = {}
                        began = time.monotonic_ns()
                        witness = error = None
                        try:
                            if lane == 'api':
                                MATCHED['lifecycle'](connection, name, stages, argv=argv, code=code)
                            else:
                                MATCHED['invoke'](docker, env, ['run', *MATCHED['FLAGS'], '--name', name,
                                                                image['ref'], *argv],
                                                  code=code, stdout=stdout, stderr=stderr)
                            ended = time.monotonic_ns()
                            witness = MATCHED['native_terminal'](connection, name, handles, code)
                        except Exception as failure:
                            ended = time.monotonic_ns()
                            error = str(failure)
                            raise
                        finally:
                            samples.write(json.dumps({'name': name, 'lane': lane, 'fixture': fixture,
                                                      'warmup': index < 4, 'host_begin_ns': began,
                                                      'host_end_ns': ended, 'api_stages_ns': stages,
                                                      'guest_witness': witness, 'error': error}) + '\n')
                            samples.flush()
        if 'conjet.output_calls' in witness:
            collect_output_checks(connection, docker, env, directory, handles)
        collect_contract_checks(connection, directory)
    finally:
        connection.close()


def summarize(directory):
    rows = [json.loads(line) for line in (directory / 'client.jsonl').read_text().splitlines()]
    trace = directory / 'adapter-trace.json'
    events = []
    if trace.exists():
        data = json.loads(trace.read_text())
        if data['dropped']:
            raise RuntimeError('diagnostic trace overflowed')
        events = data['events']
    summary = {}
    for lane in ('api', 'cli'):
        for fixture in CANARIES:
            sample = [row for row in rows if row['lane'] == lane and row['fixture'] == fixture
                      and not row['warmup']]
            if len(sample) != 40 or any(row['error'] or not row['guest_witness'] for row in sample):
                raise RuntimeError('diagnostic samples are incomplete or lack guest witnesses')
            group = summary[f'{lane}/{fixture}'] = {
                'samples': len(sample),
                'elapsed_median_ns': median(row['host_end_ns'] - row['host_begin_ns'] for row in sample),
                'native_median_ns': {stage: median(int(row['guest_witness'][f'conjet.timing.{stage}'])
                                                  for row in sample)
                                     for stage in ('authenticate', 'admit', 'terminal', 'output')},
                'wait_calls': dict(Counter(row['guest_witness']['conjet.wait_calls'] for row in sample)),
            }
            if 'conjet.output_calls' in sample[0]['guest_witness']:
                group['output_calls'] = dict(Counter(row['guest_witness']['conjet.output_calls']
                                                     for row in sample))
            if lane == 'api':
                group['api_median_ns'] = {stage: median(row['api_stages_ns'][stage] for row in sample)
                                          for stage in ('create', 'start', 'wait', 'remove')}
            if not events:
                continue
            counts = Counter()
            spans = []
            for row in sample:
                began, ended = row['host_begin_ns'], row['host_end_ns']
                sliced = [event for event in events if began <= event['host_ns'] <= ended]
                points = {event['event']: event['host_ns'] for event in sliced}
                requests = [event for event in sliced if event['event'] == 'http_request']
                if lane == 'cli' and not any(request['path'] == '/_ping' for request in requests):
                    raise RuntimeError('CLI trace is missing API negotiation')
                connections = {request['connection'] for request in requests}
                threads = {request['thread'] for request in requests}
                counts[(len(requests), len(connections), len(threads),
                        sum(event['event'] == 'worker_enter' for event in sliced),
                        sum(event['event'] == 'native_connect' for event in sliced))] += 1
                spans.append({
                    'client_start_to_first_request': requests[0]['host_ns'] - began,
                    'first_request_to_create': points['create'] - requests[0]['host_ns'],
                    'create_to_start': points['start'] - points['create'],
                    'worker_entry_to_start_event': points['start'] - points['worker_enter'],
                    'worker_entry_to_verified_cleanup': points['native_cleanup_verified'] - points['worker_enter'],
                    'verified_cleanup_to_owner_exit': points['die'] - points['native_cleanup_verified'],
                    'owner_exit_to_client_completion': ended - points['die'],
                })
                if lane == 'cli':
                    attach = next(event for event in sliced if event['event'] == 'attach_headers')
                    eof = next(event for event in sliced if event['event'] == 'http_socket_closed'
                               and event['thread'] == attach['thread'] and event['host_ns'] >= attach['host_ns'])
                    spans[-1].update({
                        'owner_exit_to_attach_socket_close': eof['host_ns'] - points['die'],
                        'owner_exit_to_wait_body_written': points['wait_body_written'] - points['die'],
                        'last_attach_or_wait_to_cli_exit': ended - max(eof['host_ns'], points['wait_body_written']),
                    })
            group['request_connection_thread_worker_auth_counts'] = [
                {'counts': list(key), 'samples': value} for key, value in sorted(counts.items())]
            group['trace_median_ns'] = {key: median(span[key] for span in spans) for key in spans[0]}
    return summary


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directories', nargs='+', type=Path)
    args = parser.parse_args()
    print(json.dumps({directory.name: summarize(directory) for directory in args.directories}, indent=2))
