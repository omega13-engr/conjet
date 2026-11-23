#!/usr/bin/env python3
"""Summarize measured session rows while keeping coverage and failures visible."""

import argparse
from collections import defaultdict
import json
import math
from pathlib import Path
import random
import statistics


def percentiles(values):
    data = sorted(values)
    return {f'p{p}_ns': data[math.ceil(p * len(data) / 100) - 1] if data else None
            for p in (50, 95, 99)}


def paired_interval(pairs, *, resamples=10000, seed=615026):
    """Bootstrap paired session ratios. A single session provides no interval."""
    if len(pairs) < 5 or any(min(left, right) <= 0 for left, right in pairs):
        return None
    ratios = [math.log(left / right) for left, right in pairs]
    rng = random.Random(seed)
    draws = sorted(math.exp(statistics.mean(rng.choices(ratios, k=len(ratios))))
                   for _ in range(resamples))
    return {'paired_sessions': len(pairs), 'ratio': math.exp(statistics.mean(ratios)),
            'ci95': [draws[math.ceil(0.025 * len(draws)) - 1],
                     draws[math.ceil(0.975 * len(draws)) - 1]]}


def summarized_samples(rows, window=None):
    success = [row['elapsed_ns'] for row in rows if row.get('error') is None
               and isinstance(row.get('elapsed_ns'), int)]
    summary = {'samples': len(rows), 'failures': len(rows) - len(success), **percentiles(success)}
    if window and window > 0:
        summary['successes_per_second'] = len(success) * 1e9 / window
    return summary


def summarize(path):
    data = json.loads(path.read_text())
    result = {key: data.get(key) for key in ('engine', 'backend', 'mode', 'passed', 'error',
                                            'selected_group', 'harness_revision', 'guest',
                                            'host_before', 'host_after', 'engine_sha256',
                                            'manifest_sha256', 'vm_backing', 'clients')}
    result['source'] = str(path)
    groups = {}
    for group in data.get('groups', []):
        label = '/'.join(group[key] for key in ('workload', 'network', 'lane'))
        groups[label] = summarized_samples(group['samples'], group.get('measured_wall_ns'))
        groups[label]['warmup_failures'] = sum(row.get('error') is not None for row in group['warmups'])
    rows = defaultdict(list)
    for row in data.get('operations', []):
        rows[row['scenario']].append(row)
    for name, operations in rows.items():
        samples = [row for row in operations if row.get('phase') == 'sample']
        if samples:
            groups[name] = summarized_samples(samples, data.get('windows_ns', {}).get(name))
            groups[name]['warmup_failures'] = sum(row.get('phase') == 'warmup' and
                                                   row.get('error') is not None for row in operations)
            if name.endswith('.first-pull'):
                groups[name]['verified_registry_transfers'] = sum(
                    row.get('cache_state') == 'complete config and layer transfer observed' for row in samples)
    result['groups'] = groups
    result['operation_failures'] = [
        {'scenario': row['scenario'], 'phase': row.get('phase'), 'error': row['error']}
        for row in data.get('operations', []) if row.get('error') is not None]
    return result


def paired_intervals(paths, mode):
    contract = json.loads((Path(__file__).parent / 'scenarios/docker-comparison-v1.json').read_bytes())
    budget = contract['suites'][mode]['samples_per_session']
    case = defaultdict(dict)
    for path in paths:
        result = summarize(path)
        parent = path.parent.parent
        if result['mode'] != mode or not (parent / 'pair.json').is_file():
            continue
        pairing = json.loads((parent / 'pair.json').read_text())
        pair = pairing['pair']
        expected = ['conjet', 'kiri'] if pair % 2 else ['kiri', 'conjet']
        if pair not in range(1, 6) or pairing['mode'] != mode or pairing['order'] != expected:
            raise ValueError('report has inconsistent pairing metadata')
        for label, details in result['groups'].items():
            if mode == 'images' and not label.startswith('registry.'):
                continue
            if (not result['passed'] or details['samples'] != budget or details['failures']
                    or details['warmup_failures'] or result['engine'] not in expected or result['operation_failures']
                    or (label.endswith('.first-pull') and details.get('verified_registry_transfers') != budget)):
                continue
            key = (pair, result['engine'])
            if key in case[label]:
                raise ValueError('duplicate qualifying engine and pair index')
            case[label][key] = (parent.resolve(), result, details)
    output = {}
    for label, accepted in case.items():
        values = []
        identities = {'conjet': set(), 'kiri': set()}
        for pair in range(1, 6):
            left = accepted.get((pair, 'conjet'))
            right = accepted.get((pair, 'kiri'))
            if left is None or right is None:
                continue
            if left[0] != right[0] or left[1]['manifest_sha256'] != right[1]['manifest_sha256']:
                raise ValueError('qualifying engines must share their pair root and manifest')
            for engine, run in (('conjet', left[1]), ('kiri', right[1])):
                identities[engine].add((run['manifest_sha256'], run['engine_sha256'], run['harness_revision']))
            values.append(pair)
        output[label] = {'complete_pairs': values}
        if any(len(identity) > 1 for identity in identities.values()):
            output[label]['excluded_from_interval'] = 'mixed revision, executable or manifest'
        for percentile in ('p50_ns', 'p99_ns'):
            pairs = [(accepted[(pair, 'conjet')][2][percentile], accepted[(pair, 'kiri')][2][percentile])
                     for pair in values]
            output[label][percentile] = (None if 'excluded_from_interval' in output[label]
                                         else paired_interval(pairs))
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--paired-lifecycle', action='store_true',
                        help='compute ratios only for complete paired lifecycle rows')
    parser.add_argument('--paired-images', action='store_true',
                        help='compute ratios for controlled registry rows with verified transfer evidence')
    parser.add_argument('sessions', nargs='+', type=Path)
    args = parser.parse_args()
    for path in args.sessions:
        if not path.resolve(strict=True).is_relative_to(Path('/Volumes/ExternalSSD/dev_workspace/tmp')):
            parser.error('sessions must reside on ExternalSSD')
    result = {'sessions': [summarize(path) for path in args.sessions]}
    if args.paired_lifecycle:
        result['paired_lifecycle'] = paired_intervals(args.sessions, 'lifecycle')
    if args.paired_images:
        result['paired_images'] = paired_intervals(args.sessions, 'images')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
