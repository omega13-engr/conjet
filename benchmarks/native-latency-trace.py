"""Join native lifecycle traces while keeping guest and host clocks separate."""

import argparse
from collections import defaultdict
import json
from pathlib import Path
import statistics


GUEST_STAGES = (
    ('pending_discovery', None, 'observed'),
    ('observed_to_grant', 'observed', 'granted'),
    ('grant_to_intent', 'granted', 'intent_recorded'),
    ('intent_to_helper', 'intent_recorded', 'helper_spawned'),
    ('helper_to_child', 'helper_spawned', 'child_created'),
    ('child_to_exec', 'child_created', 'exec_confirmed'),
    ('exec_to_exit_witness', 'exec_confirmed', 'cleaning'),
    ('exit_to_output_drain', 'cleaning', 'helper_reaped_output_drained'),
    ('drain_to_intent_clear', 'helper_reaped_output_drained', 'intent_completed'),
    ('intent_clear_to_verified_cleanup', 'intent_completed', 'removed'),
    ('cleanup_to_wait_reply', 'removed', 'terminal_reply'),
)


def span(first, last):
    if not isinstance(first, int) or not isinstance(last, int) or not 0 <= first <= last:
        raise ValueError('missing or unordered stage timestamps')
    return last - first


def host_rows(path):
    observations = defaultdict(list)
    grants = defaultdict(list)
    summaries = []
    for line in path.read_text().splitlines():
        if not line.startswith('{'):
            continue
        row = json.loads(line)
        if row.get('event') == 'core_trace_summary':
            summaries.append(row)
        elif row.get('event') in ('core_observation', 'core_admission'):
            key = (row['boot_id'], row['id'], row['sequence'])
            target = observations if row['event'] == 'core_observation' else grants
            target[key].append(row)
    if len(summaries) != 1 or summaries[0]['lost']:
        raise ValueError('missing trace summary or trace overflow')
    if summaries[0]['rows'] != sum(map(len, observations.values())) + sum(map(len, grants.values())):
        raise ValueError('trace record count mismatch')
    return observations, grants, summaries[0]


def join(sample, observations, grants):
    trace = sample['latency_trace']
    handle = sample['guest_witness']['conjet.native_handle']
    key = (trace['boot_id'], handle, trace['sequence'])
    attempts = grants.get(key, [])
    if len(attempts) != 1 or not attempts[0]['accepted']:
        raise ValueError('expected one accepted grant for the workload')
    approval = attempts[0]
    selected = [event for event in observations.get(key, []) if event['h1_ns'] == approval['h1_ns']]
    if len(selected) != 1:
        raise ValueError('grant lacks a unique matching observation')
    observed = selected[0]
    guest = trace['guest_phase_ns']
    spans = {name: span(guest[start] if start else 0, guest[end])
             for name, start, end in GUEST_STAGES}
    spans.update({
        'observation_round_trip': span(observed['h0_ns'], observed['h1_ns']),
        'discovery_publish_to_approval': span(approval['h1_ns'], approval['h2_ns']),
        'approval_to_grant_send': span(approval['h2_ns'], approval['h3_ns']),
        'grant_round_trip': approval['reply_ns'],
        'host_terminal_to_lifecycle_end': span(trace['h4_ns'], sample['h5_ns']),
        'api_wait': sample['stages_ns'].get('wait'),
        'lifecycle': sample['elapsed_ns'],
    })
    return {'key': key, 'owned': observed['owned'], 'pending': observed['pending'],
            'observations': len(observations[key]), 'spans_ns': spans}


def percentiles(values):
    if len(values) < 2:
        return {name: values[0] if values else None for name in ('p50', 'p95', 'p99')}
    points = statistics.quantiles(values, n=100, method='inclusive')
    return {f'p{p}': round(points[p - 1]) for p in (50, 95, 99)}


def collect(session, host):
    observations, grants, summary = host_rows(host)
    source = json.loads(session.read_text())
    report = {'host_trace': summary, 'lanes': {}, 'passed': bool(source['passed'])}
    if not source['latency_trace']:
        raise ValueError('session did not enable latency tracing')
    seen = set()
    for name, data in source['lanes'].items():
        lane = {'samples': [], 'warmups': [], 'failures': []}
        report['lanes'][name] = lane
        for phase in ('samples', 'warmups'):
            for sample in data[phase]:
                try:
                    if sample['error']:
                        raise ValueError(sample['error'])
                    row = join(sample, observations, grants)
                    if row['key'] in seen:
                        raise ValueError('duplicate workload witness')
                    seen.add(row['key'])
                    lane[phase].append(row)
                except (KeyError, ValueError) as error:
                    lane['failures'].append({'name': sample['name'], 'phase': phase, 'error': str(error)})
        report['passed'] &= not lane['failures']
        columns = defaultdict(list)
        for sample in lane['samples']:
            for field, value in sample['spans_ns'].items():
                if value is not None:
                    columns[field].append(value)
        lane['percentiles_ns'] = {field: percentiles(values) for field, values in columns.items()}
        if len(columns['lifecycle']) > 1 and statistics.variance(columns['lifecycle']):
            lane['lifecycle_correlations'] = {
                field: round(statistics.correlation(values, columns['lifecycle']), 3)
                for field, values in columns.items()
                if field != 'lifecycle' and len(values) > 1 and statistics.variance(values)
            }
    report['unmatched_host_workloads'] = sorted((set(observations) | set(grants)) - seen)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('session', 'host', 'output'):
        parser.add_argument(name, type=Path)
    args = parser.parse_args()
    report = collect(args.session, args.host)
    with args.output.open('x') as stream:
        json.dump(report, stream, indent=2)
        stream.write('\n')
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
