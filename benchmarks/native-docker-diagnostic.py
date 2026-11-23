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
