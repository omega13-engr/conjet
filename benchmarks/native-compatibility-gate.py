"""Evaluate frozen native coverage against matching release preflight and canary reports."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import runpy
import sys

HERE = Path(__file__).resolve().parent
PREFLIGHT = runpy.run_path(str(HERE / 'native-compatibility-preflight.py'))
SCRATCH = Path('/Volumes/ExternalSSD/dev_workspace/tmp')
MATRIX = ('lifecycle', 'images', 'builds', 'compose', 'control', 'storage_network', 'stress')


def read(directory, name):
    path = directory / name
    return json.loads(path.read_text()) if path.is_file() else {}


def evaluate(root, revision, release):
    manifest = PREFLIGHT['contract']()
    required = {case['id']: {
        'task': group['task'], 'status': 'FAIL', 'reason': 'missing qualified witness',
        'fixture': case['operation'], 'policy': group['effective_policy'],
        'expected': group['expected'], 'expected_cleanup': group['cleanup'],
    } for group in manifest['groups'] for case in group['cases']}
    if sum(len(group['cases']) for group in manifest['groups']) != len(required):
        raise ValueError('duplicate case in the frozen manifest')
    launch_artifacts = {name: digest for name, digest in release.items() if name != 'conjetd'}
    lanes = {}

    def lane(name):
        if name not in lanes:
            folder = root / name / 'launcher'
            launcher = read(folder, 'launcher.json')
            digests = {Path(path).name: digest for path, digest in launcher.get('binary_sha256', {}).items()}
            verified = (launcher.get('revision') == revision
                        and all(digests.get(name) == digest for name, digest in launch_artifacts.items())
                        and launcher.get('passed') is True
                        and launcher.get('backend') == 'Conjet Native OCI'
                        and '--core-dynamic-memory' in launcher.get('vm_command', [])
                        and launcher.get('production_unchanged') is True
                        and launcher.get('native_session_removed') is True
                        and launcher.get('adapter_socket_removed') is True
                        and launcher.get('cleanup_errors') == []
                        and launcher.get('shutdown', {}).get('guest_cleanup') == 'complete'
                        and launcher.get('shutdown', {}).get('reclaim_failures') == 0)
            lanes[name] = (folder, verified)
        return lanes[name]

    def pass_case(case, reason, *names):
        if all(lane(name)[1] for name in names):
            required[case].update(status='PASS', reason=reason,
                                  evidence=[str(lane(name)[0]) for name in names])

    for suite in MATRIX:
        folder, verified = lane(suite)
        path = 'matrix/session.json'
        report = read(folder, path)
        failed = [row for row in report.get('operations', []) if row.get('error')]
        if not report:
            continue
        reason = report.get('error') or ('; '.join(dict.fromkeys(
            f"{row['scenario']}: {(row.get('stderr') or row['error']).strip()[:240]}"
            for row in failed)) if failed else 'required behavior needs a separate witness')
        if not verified:
            reason = 'release artifact or launcher cleanup could not be verified'
        for case, result in required.items():
            if case.startswith(suite + '/'):
                result.update(reason=reason, evidence=[str(folder / path)])
        if suite == 'lifecycle' and verified:
            for fixture, row in report.get('independent_alpine', {}).items():
                case = 'lifecycle/' + fixture
                if case not in required:
                    raise ValueError(f'unknown lifecycle fixture: {fixture}')
                witness = row.get('guest_witness', {})
                if (row.get('error') is None and witness.get('conjet.guest_cleanup') == 'complete'
                        and witness.get('conjet.native_handle')):
                    pass_case(case, 'original Alpine fixture passed with verified guest cleanup', suite)
                else:
                    required[case].update(reason=row.get('error') or 'missing guest cleanup witness')
        if suite == 'stress' and verified:
            manifest_budget = json.loads((HERE / 'scenarios/docker-comparison-v1.json').read_text())['suites']['stress']
            count = manifest_budget['samples_per_session']
            warmups = manifest_budget['warmups']
            for concurrency in (1, 2, 4, 8):
                operation = f'stress.launch.concurrency-{concurrency}'
                rows = [row for row in report.get('operations', []) if row['scenario'] == operation]
                if (len(rows) == count + warmups and all(row['error'] is None for row in rows)
                        and sum(row['phase'] == 'sample' for row in rows) == count
                        and sum(row['phase'] == 'warmup' for row in rows) == warmups):
                    pass_case(f'stress/concurrency-{concurrency}',
                              f'{count} original runs and {warmups} warmups passed', suite)

    folder, verified = lane('credentials')
    credentials = read(folder, 'native-credentials.json')
    if verified and credentials.get('passed'):
        pass_case('credentials/reject', 'API denied unmapped IDs, privileged create and capability addition',
                  'credentials')
        required['credentials/default'].update(reason='Alpine default passed; remaining pinned images lack release evidence',
                                               evidence=[str(folder)])
        required['credentials/explicit'].update(reason='numeric pairs passed; account lookup is unqualified',
                                                evidence=[str(folder)])
        cases = credentials.get('cases', {})
        if all(cases.get(case, {}).get('conjet.guest_cleanup') == 'complete'
               for case in ('matched_cli', 'matched_api')):
            pass_case('regression/matched-identity',
                      'explicit 65532 CLI streams and API lifecycle retained verified cleanup', 'credentials')

    folder, verified = lane('dynamic-memory')
    memory = read(folder, 'native-core-memory-summary.json')
    if verified and memory.get('initial_reduced', {}).get('target_mib') == 448:
        if memory.get('expanded', {}).get('target_mib') == 2048:
            pass_case('memory/growth', 'Core grew from 448 to 2,048 MiB on workload demand', 'dynamic-memory')
        idle = memory.get('post_workload_reduced', {})
        if idle.get('target_mib') == 448 and idle.get('memory_ledger', {}).get('ok') is True:
            pass_case('memory/idle', 'Core returned to 448 MiB with verified ownership', 'dynamic-memory')

    folder, verified = lane('dynamic-pressure')
    pressure = read(folder, 'native-core-memory-summary.json')
    if verified and pressure.get('guest_pressure_only', {}).get('active_workloads') == 0:
        if pressure.get('pressure_only_expanded', {}).get('target_mib') == 2048:
            pass_case('memory/pressure', 'independent pressure restored capacity with zero workloads',
                      'dynamic-pressure')
        if pressure.get('expected_sha256') and pressure.get('guest_after_churn'):
            pass_case('memory/churn', 'active file checksum remained valid through release churn',
                      'dynamic-pressure')

    folder, verified = lane('registry')
    registry = read(folder, 'registry-checks.json').get('cases', {})
    if verified and {'hash', 'interrupt', 'tag_run', 'in_use_delete', 'remove_small'} <= registry.keys():
        pass_case('regression/registry-local', 'loopback registry fault, ownership and image runs passed', 'registry')
    pass_case('regression/network', 'private bridge DNS and loopback publication canaries passed',
              'docker-network', 'published-port')
    pass_case('regression/controls', 'native concurrency, exec and streaming canaries passed',
              'concurrency', 'exec', 'streaming')
    pass_case('regression/volume', 'owned volume write and recovery canaries passed across two boots',
              'volume-create', 'volume-inspect')
    pass_case('regression/native-compose', 'existing pinned native Compose project canary passed',
              'native-compose')

    folder, verified = lane('docker-build-api')
    response_path = folder.parent / 'response.json'
    response = read(folder.parent, response_path.name)
    if verified and response and response['status'] != 200:
        required['builds/docker-build-api'].update(
            reason=f"POST /v1.44/build returned HTTP {response['status']}: {response['body'].get('message', '')}",
            evidence=[str(response_path), str(folder)])

    passed = sum(item['status'] == 'PASS' for item in required.values())
    return {'scope': 'native-release-compatibility', 'revision': revision,
            'compatibility_manifest_sha256': hashlib.sha256(PREFLIGHT['MANIFEST'].read_bytes()).hexdigest(),
            'frozen_sources_sha256': manifest['sources'],
            'release_sha256': release, 'required': len(required), 'passed_cases': passed,
            'failed_cases': len(required) - passed, 'passed': passed == len(required),
            'cases': required}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--revision', required=True)
    args = parser.parse_args()
    root = args.evidence.resolve(strict=True)
    if not root.is_relative_to(SCRATCH):
        parser.error('evidence must be under ExternalSSD scratch')
    release = {}
    for line in (root / 'release-sha256.txt').read_text().splitlines():
        digest, path = line.split(maxsplit=1)
        name = Path(path).name
        if name in release or re.fullmatch(r'[0-9a-f]{64}', digest) is None:
            parser.error('invalid or duplicate release artifact digest')
        release[name] = digest
    if (release.keys() != {'conjet', 'conjetd', 'jetstream', 'conjet-launchd', 'conjet-memd', 'conjet-reclaimd'}
            or re.fullmatch(r'[0-9a-f]{40}', args.revision) is None):
        parser.error('expected the exact release executable inventory')
    summary = evaluate(root, args.revision, release)
    destination = root / 'compatibility-summary.json'
    destination.write_text(json.dumps(summary, indent=2) + '\n')
    print(f"{summary['passed_cases']} PASS / {summary['failed_cases']} FAIL. {destination}")
    return 0 if summary['passed'] else 1


if __name__ == '__main__':
    sys.exit(main())
