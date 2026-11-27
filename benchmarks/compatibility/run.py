"""Inventory checks and explicit, fail-closed expanded compatibility execution."""

import argparse
import ast
import json
from pathlib import Path
import unittest

HERE = Path(__file__).resolve().parent


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
        tree = ast.parse(path.read_text())
        classes = [node for node in tree.body if isinstance(node, ast.ClassDef)
                   and node.name == 'CompatibilityTests']
        if len(classes) != 1 or not any(
                isinstance(node, ast.FunctionDef) and node.name == case['test_name']
                for node in classes[0].body):
            raise ValueError('missing test method: ' + case['id'])
        if not case['acceptance'].strip():
            raise ValueError('missing acceptance: ' + case['id'])
    if not seen:
        raise ValueError('empty matrix')


def qualified(result, expected):
    return (expected > 0 and result.testsRun == expected and result.wasSuccessful()
            and not result.skipped and not result.expectedFailures
            and not result.unexpectedSuccesses)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='validate inventory only; no compatibility claim')
    parser.add_argument('--profile', choices=('single-host', 'swarm', 'advanced', 'all'))
    args = parser.parse_args()
    matrix = json.loads((HERE / 'matrix.json').read_text())
    validate(matrix)
    if args.check:
        print(f"Inventory valid: {len(matrix['cases'])} mapped contracts; runtime qualification NOT performed")
        return 0
    if not args.profile:
        parser.error('choose --check or an explicit --profile')
    selected = [case for case in matrix['cases']
                if args.profile == 'all' or case['profile'] == args.profile]
    # Discovery loads repository-owned test modules; no commands come from the manifest.
    discovered = unittest.TestLoader().discover(str(HERE / 'cases'), pattern='test_*.py')
    tests = {test.id().rsplit('.', 2)[0] + '.' + test._testMethodName: test
             for module in discovered for cls in module for test in cls}
    suite = unittest.TestSuite()
    for case in selected:
        key = Path(case['test_file']).stem + '.' + case['test_name']
        suite.addTest(tests[key])
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    return 0 if qualified(result, len(selected)) else 1


if __name__ == '__main__':
    raise SystemExit(main())
