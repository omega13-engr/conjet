"""Inventory checks and explicit, fail-closed expanded compatibility execution."""

import argparse
import ast
import hashlib
import http.client
import json
import os
from pathlib import Path
import re
import signal
import time
import unittest

if __package__:
    from .identity import SCRATCH, sha256
    from .workloads import ensure_alpine
else:
    from identity import SCRATCH, sha256
    from workloads import ensure_alpine

HERE = Path(__file__).resolve().parent
MATRIX = HERE / 'matrix.json'
RUNNER_FILES = ('run.py', 'identity.py', 'workloads.py')
RESOURCE_LISTS = {
    'containers': ('/containers/json?all=1', None, 'Id'),
    'images': ('/images/json?all=1', None, 'Id'),
    'networks': ('/networks', None, 'Id'),
    'volumes': ('/volumes', 'Volumes', 'Name'),
}


def validate(matrix, root=HERE):
    seen = set()
    targets = set()
    for case in matrix['cases']:
        if case['id'] in seen:
            raise ValueError('duplicate case ID: ' + case['id'])
        seen.add(case['id'])
        target = (case['test_file'], case['test_name'])
        if target in targets:
            raise ValueError('duplicate test target: ' + case['id'])
        targets.add(target)
        if case['profile'] not in ('single-host', 'swarm', 'advanced'):
            raise ValueError('unknown profile: ' + case['id'])
        path = (root / case['test_file']).resolve()
        if not path.is_relative_to(root.resolve()) or not path.is_file():
            raise ValueError('missing or escaping test file: ' + case['id'])
        for file in case.get('support_files', ()):
            support = (root / file).resolve()
            if not support.is_relative_to(root.resolve()) or not support.is_file():
                raise ValueError('missing or escaping support file: ' + case['id'])
        tree = ast.parse(path.read_text())
        classes = [node for node in tree.body if isinstance(node, ast.ClassDef)
                   and node.name == 'CompatibilityTests']
        if len(classes) != 1 or not any(
                isinstance(node, ast.FunctionDef) and node.name == case['test_name']
                for node in classes[0].body):
            raise ValueError('missing test method: ' + case['id'])
        restarts = case.get('required_restarts', 0)
        if type(restarts) is not int or not 0 <= restarts <= 8:
            raise ValueError('invalid restart count: ' + case['id'])
        if not case['acceptance'].strip():
            raise ValueError('missing acceptance: ' + case['id'])
    if not seen:
        raise ValueError('empty matrix')


def qualified(result, expected):
    return (expected > 0 and result.testsRun == expected and result.wasSuccessful()
            and not result.skipped and not result.expectedFailures
            and not result.unexpectedSuccesses)


def selection(profile):
    matrix = json.loads(MATRIX.read_text())
    validate(matrix)
    return [case for case in matrix['cases'] if profile == 'all' or case['profile'] == profile]


def load_tests():
    # Discovery loads repository-owned test modules; no commands come from the manifest.
    discovered = unittest.TestLoader().discover(str(HERE / 'cases'), pattern='test_*.py')
    return {test.id().rsplit('.', 2)[0] + '.' + test._testMethodName: test
            for module in discovered for cls in module for test in cls}


class CaseSession:
    def __init__(self, connection, restart=None):
        self.connection = connection
        self._restart = restart
        self.restarts = 0
        self.observation = None

    def restart_engine(self):
        if self._restart is None:
            raise RuntimeError('launcher did not provide verified engine restart')
        self.connection = self._restart()
        self.restarts += 1

    def request(self, method, path, body=None):
        payload = json.dumps(body).encode() if body is not None else None
        headers = {'Content-Type': 'application/json'} if payload is not None else {}
        try:
            self.connection.request(method, path, body=payload, headers=headers)
            with self.connection.getresponse() as response:
                data = response.read(1024 * 1024 + 1)
                if len(data) > 1024 * 1024:
                    raise RuntimeError('compatibility response exceeds 1 MiB')
                return response.status, data
        finally:
            self.connection.close()

    def record(self, observation):
        if self.observation is not None or not observation:
            raise ValueError('a case must record one non-empty observation')
        self.observation = json.loads(json.dumps(observation, allow_nan=False))

    def resources(self):
        inventory = {}
        api_version = self.connection.server_version['ApiVersion']
        for kind, (path, envelope, key) in RESOURCE_LISTS.items():
            status, body = self.request('GET', f'/v{api_version}{path}')
            if status != 200:
                raise RuntimeError(f'cannot verify {kind} cleanup: HTTP {status}')
            items = json.loads(body)
            if envelope:
                items = items[envelope]
                if items is None:
                    items = []
            if not isinstance(items, list):
                raise RuntimeError(f'invalid {kind} inventory')
            if kind == 'images':
                inventory[kind] = sorted(
                    (item[key], sorted(item.get('RepoTags') or []), sorted(item.get('RepoDigests') or []))
                    for item in items
                )
            elif kind == 'networks':
                fields = ('Name', 'Driver', 'Scope', 'Internal', 'Attachable', 'Ingress',
                          'EnableIPv6', 'IPAM', 'Options', 'Labels')
                inventory[kind] = sorted((item[key], {field: item.get(field) for field in fields})
                                         for item in items)
            else:
                inventory[kind] = sorted(item[key] for item in items)
        return inventory


def ignore_engine_bridge_recreation(inventory):
    networks = sorted(
        ('default-bridge' if metadata['Name'] == metadata['Driver'] == 'bridge'
         and metadata['Scope'] == 'local' else identifier, metadata)
        for identifier, metadata in inventory['networks']
    )
    return {**inventory, 'networks': networks}


def execute_case(test, connection, timeout, restart=None):
    session = CaseSession(connection, restart)
    row = {'passed': False, 'cleanup': False}
    started = time.monotonic()

    def expired(_signum, _frame):
        raise TimeoutError('compatibility case deadline exceeded')

    previous = signal.signal(signal.SIGALRM, expired)
    test.compatibility = session
    baseline = None
    try:
        signal.setitimer(signal.ITIMER_REAL, timeout)
        baseline = session.resources()
        result = unittest.TestResult()
        test.run(result)
        row['passed'] = qualified(result, 1) and session.observation is not None
        row['details'] = {
            name: [message for _, message in getattr(result, name)]
            for name in ('failures', 'errors', 'skipped', 'expectedFailures')
        }
        row['observation'] = session.observation
    except (Exception, KeyboardInterrupt) as error:
        row['error'] = f'{type(error).__name__}: {error}'
        if isinstance(error, KeyboardInterrupt):
            row['interrupted'] = True
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous)
        try:
            if baseline is not None:
                after = session.resources()
                row['cleanup'] = after == baseline
                if session.restarts and not row['cleanup']:
                    # Dockerd rebuilds the system bridge on restart. Compare
                    # its full configuration and every custom network ID.
                    row['cleanup'] = (ignore_engine_bridge_recreation(after)
                                      == ignore_engine_bridge_recreation(baseline))
                    if row['cleanup']:
                        row['engine_managed_bridge_recreated'] = True
                if not row['cleanup']:
                    row['resources'] = {'before': baseline, 'after': after}
        except (ValueError, KeyError, OSError, http.client.HTTPException, RuntimeError) as error:
            row['cleanup_error'] = str(error)
        row['passed'] = row['passed'] and row['cleanup']
        row['elapsed_seconds'] = time.monotonic() - started
    return row


def case_hash(case):
    files = [case['test_file'], *case.get('support_files', ())]
    if len(files) == 1:
        return sha256(HERE / files[0])
    manifest = {file: sha256(HERE / file) for file in files}
    return hashlib.sha256(json.dumps(manifest, sort_keys=True).encode()).hexdigest()


def runner_hashes():
    return {file: sha256(HERE / file) for file in RUNNER_FILES}


def same_engine_new_peer(before, after):
    old, new = before['endpoint'], after['endpoint']
    return (all(new[key] == old[key] for key in ('path', 'peer_path', 'peer_sha256'))
            and new['peer_pid'] != old['peer_pid']
            and after['version'] == before['version'])


def record_lane(profile, connection, executable, identity, timeout=60, restart_engine=None):
    matrix = sha256(MATRIX)
    harness = runner_hashes()
    selected = selection(profile)
    if not selected or not 0 < timeout <= 3600:
        raise ValueError('a non-empty profile and bounded case timeout are required')
    fixtures = {case['id']: case_hash(case) for case in selected}
    tests = load_tests()
    rows = {}
    start = connection.capture(executable)
    if start != identity:
        raise RuntimeError('Docker endpoint changed before running the compatibility lane')
    live = start
    # Pull the immutable workload once per disposable lane. In-memory case
    # inventories still verify every resource relative to their own baseline.
    seeded = ensure_alpine(CaseSession(connection))
    transitions = []

    def restart():
        nonlocal connection, live
        if connection.capture(executable) != live:
            raise RuntimeError('Docker endpoint changed before the fixture restart')
        previous = live
        connection = restart_engine()
        live = connection.capture(executable)
        if not same_engine_new_peer(previous, live):
            raise RuntimeError('restart did not restore the same engine in a new process')
        transitions.append({'case': case['id'], 'before': previous, 'after': live})
        return connection

    for case in selected:
        key = Path(case['test_file']).stem + '.' + case['test_name']
        fixture = fixtures[case['id']]
        if case_hash(case) != fixture:
            raise RuntimeError(f"fixture changed before running {case['id']}")
        prior_restarts = len(transitions)
        row = execute_case(tests[key], connection, timeout, restart if restart_engine else None)
        count = len(transitions) - prior_restarts
        if count != case.get('required_restarts', 0):
            row['passed'] = False
            row['restart_error'] = f"expected {case.get('required_restarts', 0)} verified restarts, got {count}"
        row['fixture_sha256'] = fixture
        rows[case['id']] = row
        if row.get('interrupted') or not row['cleanup']:
            break
    if (matrix != sha256(MATRIX) or harness != runner_hashes()
            or any(case_hash(case) != fixtures[case['id']] for case in selected)):
        raise RuntimeError('compatibility harness changed while running the lane')
    return {'profile': profile, 'matrix_sha256': matrix, 'harness_sha256': harness, 'cases': rows,
            'seeded_alpine': seeded, 'restarts': transitions, 'endpoint_verified_after': connection.capture(executable) == live}


def compare(profile, candidate, reference):
    selected = selection(profile)
    expected = {case['id']: case_hash(case) for case in selected}
    matrix = sha256(MATRIX)
    harness = runner_hashes()
    receipt = {'matrix_sha256': matrix, 'harness_sha256': harness, 'profile': profile,
               'cases': {}, 'passed': False}
    for report in (candidate, reference):
        lane = report.get('compatibility', {})
        if (lane.get('profile') != profile or lane.get('matrix_sha256') != matrix
                or lane.get('harness_sha256') != harness
                or lane.get('endpoint_verified_after') is not True
                or set(lane.get('cases', {})) != expected.keys()):
            raise ValueError('missing or mismatched compatibility lane')
        for key, fixture in expected.items():
            if lane['cases'][key].get('fixture_sha256') != fixture:
                raise ValueError(f'fixture identity changed for {key}')
    left, right = (report['identity'] for report in (candidate, reference))
    if (left['endpoint']['path'] == right['endpoint']['path']
            or left['endpoint']['peer_sha256'] == right['endpoint']['peer_sha256']
            or left['version'].get('platform') != 'Conjet Native OCI'
            or right['version'].get('platform') != 'Docker Engine - Community'
            or left['version']['Arch'] != right['version']['Arch']
            or left['version']['Os'] != 'linux' or right['version']['Os'] != 'linux'):
        raise ValueError('expected distinct Conjet and full Docker Engine identities on the same Linux architecture')
    if (candidate.get('runtime_cleanup') is not True or candidate.get('production_unchanged') is not True
            or any(reference.get('cleanup', {}).get(key) is not True
                   for key in ('vm_removed', 'children_reaped', 'production_unchanged'))):
        raise ValueError('launcher cleanup evidence is incomplete')
    artifacts = {
        'candidate': {
            'app': candidate['app_executable_sha256'],
            'engine': candidate['sha256']['Conjet Core'],
            'guest': candidate['sha256']['conjet-launchd-linux-arm64'],
            'kernel': candidate['native_artifacts']['NativeCore/Image'],
        },
        'reference': {'engine': reference['engine_sha256'], 'kernel': reference['kernel_sha256']},
    }
    if (artifacts['candidate']['engine'] != left['endpoint']['peer_sha256']
            or any(not re.fullmatch(r'[a-f0-9]{64}', digest)
                   for role in artifacts.values() for digest in role.values())):
        raise ValueError('launcher artifact identity is incomplete or mismatched')
    receipt['identities'] = {'candidate': left, 'reference': right}
    receipt['artifacts'] = artifacts
    restart_counts = []
    receipt['restarts'] = {}
    for role, report in (('candidate', candidate), ('reference', reference)):
        transitions = report['compatibility'].get('restarts', [])
        latest = report['identity']
        counts = {}
        for transition in transitions:
            key, before, after = (transition[field] for field in ('case', 'before', 'after'))
            if key not in expected or before != latest or not same_engine_new_peer(before, after):
                raise ValueError('unexpected restart evidence for ' + role)
            counts[key] = counts.get(key, 0) + 1
            latest = after
        restart_counts.append(counts)
        receipt['restarts'][role] = transitions

    for case in selected:
        key = case['id']
        a, b = (report['compatibility']['cases'][key] for report in (candidate, reference))
        observations = [json.dumps(row.get('observation'), sort_keys=True, allow_nan=False)
                        for row in (a, b)]
        receipt['cases'][key] = {
            'passed': (a.get('passed') is True and b.get('passed') is True
                       and all(counts.get(key, 0) == case.get('required_restarts', 0)
                               for counts in restart_counts)
                       and a.get('cleanup') is True and b.get('cleanup') is True
                       and bool(a.get('observation')) and observations[0] == observations[1]),
            'candidate': a, 'reference': b,
        }
    receipt['passed'] = (bool(expected) and candidate.get('passed') is True
                         and reference.get('passed') is True
                         and all(row['passed'] for row in receipt['cases'].values()))
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='validate inventory only; no compatibility claim')
    parser.add_argument('--profile', choices=('single-host', 'swarm', 'advanced', 'all'))
    parser.add_argument('--candidate', type=Path)
    parser.add_argument('--reference', type=Path)
    parser.add_argument('--evidence', type=Path)
    args = parser.parse_args()
    if args.check:
        print(f"Inventory valid: {len(selection('all'))} mapped contracts; runtime qualification NOT performed")
        return 0
    if not args.profile or not all((args.candidate, args.reference, args.evidence)):
        parser.error('runtime qualification requires a profile, both launcher receipts and a new evidence path')
    output = args.evidence.resolve()
    if not output.is_relative_to(SCRATCH):
        parser.error('write evidence under ExternalSSD scratch')
    files = {'candidate': args.candidate, 'reference': args.reference}
    os.umask(0o077)
    with output.open('x') as stream:
        receipt = {'passed': False}
        try:
            inputs = {name: path.read_bytes() for name, path in files.items()}
            receipt = compare(args.profile, **{name: json.loads(raw) for name, raw in inputs.items()})
            receipt['receipts'] = {name: {'path': str(files[name]), 'sha256': hashlib.sha256(raw).hexdigest()}
                                   for name, raw in inputs.items()}
        except (OSError, ValueError, KeyError, TypeError, AttributeError) as error:
            receipt['error'] = str(error)
        json.dump(receipt, stream, indent=2)
        stream.write('\n')
    return 0 if receipt['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
