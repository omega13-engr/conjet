"""Verify the matrix gate independently of an installed engine."""

import copy
import time
import unittest
from unittest.mock import patch

import run


class DifferentialTests(unittest.TestCase):
    def setUp(self):
        self.case = run.selection('all')[0]
        self.enterContext(patch.object(run, 'selection', return_value=[self.case]))
        engine = 'a' * 64
        kernel = 'b' * 64
        row = {'passed': True, 'cleanup': True, 'observation': {'status': 200},
               'fixture_sha256': run.case_hash(self.case)}
        lane = {'profile': 'all', 'matrix_sha256': run.sha256(run.MATRIX),
                'harness_sha256': run.runner_hashes(), 'endpoint_verified_after': True,
                'cases': {self.case['id']: row}}
        self.candidate = {
            'identity': {'endpoint': {'path': '/private/conjet.sock', 'peer_sha256': engine},
                         'version': {'platform': 'Conjet Native OCI', 'Arch': 'arm64', 'Os': 'linux'}},
            'compatibility': lane, 'runtime_cleanup': True, 'production_unchanged': True, 'passed': True,
            'app_executable_sha256': engine,
            'sha256': {'Conjet Core': engine, 'conjet-launchd-linux-arm64': engine},
            'native_artifacts': {'NativeCore/Image': kernel},
        }
        self.reference = {
            'identity': {'endpoint': {'path': '/private/reference.sock', 'peer_sha256': 'c' * 64},
                         'version': {'platform': 'Docker Engine - Community', 'Arch': 'arm64',
                                     'Os': 'linux'}},
            'compatibility': copy.deepcopy(lane), 'kernel_sha256': kernel, 'engine_sha256': engine,
            'passed': True,
            'cleanup': {'vm_removed': True, 'children_reaped': True, 'production_unchanged': True},
        }

    def compare(self):
        return run.compare('all', self.candidate, self.reference)

    def row(self):
        return self.reference['compatibility']['cases'][self.case['id']]

    def test_matching_observations_pass(self):
        self.assertTrue(self.compare()['passed'])

    def test_mismatch_fails_even_when_both_lanes_pass(self):
        self.row()['observation']['status'] = 204
        self.assertFalse(self.compare()['passed'])

    def test_json_booleans_and_numbers_do_not_compare_as_equal(self):
        self.candidate['compatibility']['cases'][self.case['id']]['observation'] = {'value': True}
        self.row()['observation'] = {'value': 1}
        self.assertFalse(self.compare()['passed'])

    def test_missing_case_is_rejected(self):
        self.reference['compatibility']['cases'].clear()
        with self.assertRaisesRegex(ValueError, 'missing or mismatched'):
            self.compare()

    def test_changed_fixture_is_rejected(self):
        self.row()['fixture_sha256'] = 'a' * 64
        with self.assertRaisesRegex(ValueError, 'fixture identity changed'):
            self.compare()

    def test_wrong_endpoint_is_rejected(self):
        self.reference['identity']['endpoint'] = self.candidate['identity']['endpoint']
        with self.assertRaisesRegex(ValueError, 'distinct Conjet and full Docker Engine'):
            self.compare()

    def test_mismatched_candidate_artifact_is_rejected(self):
        self.candidate['sha256']['Conjet Core'] = 'e' * 64
        with self.assertRaisesRegex(ValueError, 'artifact identity'):
            self.compare()

    def test_missing_launcher_cleanup_is_rejected(self):
        self.reference['cleanup'].pop('children_reaped')
        with self.assertRaisesRegex(ValueError, 'cleanup evidence'):
            self.compare()

    def test_failed_launcher_cannot_become_a_pass(self):
        self.reference['passed'] = False
        self.assertFalse(self.compare()['passed'])

    def test_pass_requires_an_observation_and_per_case_cleanup(self):
        for data in ({'observation': None}, {'cleanup': False}):
            with self.subTest(data=data), patch.dict(self.row(), data):
                self.assertFalse(self.compare()['passed'])


class LaneCaseTests(unittest.TestCase):
    def execute_fixture(self, run_test, *, timeout=1, before=(), after=()):
        fixture = unittest.FunctionTestCase(run_test)
        with patch.object(run.CaseSession, 'resources', side_effect=[before, after]):
            return run.execute_case(fixture, None, timeout)

    def test_timeout_records_failure_and_checks_cleanup(self):
        row = self.execute_fixture(lambda: time.sleep(1), timeout=0.02)
        self.assertFalse(row['passed'])
        self.assertTrue(row['cleanup'])
        self.assertIn('deadline exceeded', row['details']['errors'][0])

    def test_interruption_records_failure_and_checks_cleanup(self):
        def interrupt():
            raise KeyboardInterrupt('fixture')

        row = self.execute_fixture(interrupt)
        self.assertFalse(row['passed'])
        self.assertTrue(row['interrupted'])
        self.assertTrue(row['cleanup'])

    def test_skip_and_missing_observation_fail(self):
        def skip():
            raise unittest.SkipTest('fixture')

        self.assertFalse(self.execute_fixture(skip)['passed'])
        self.assertFalse(self.execute_fixture(lambda: None)['passed'])

    def test_unsettled_resources_fail_cleanup(self):
        row = self.execute_fixture(lambda: None, before=('original',), after=('original', 'leaked'))
        self.assertFalse(row['cleanup'])
        self.assertIn('leaked', row['resources']['after'])


if __name__ == '__main__':
    unittest.main()
