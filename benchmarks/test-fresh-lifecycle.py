"""Focused tests for baseline accounting and recovery."""
import runpy
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

SCRIPT = Path(__file__).with_name('fresh-lifecycle.py')
ADAPTER = runpy.run_path(str(SCRIPT))


class FreshLifecycleTests(unittest.TestCase):
    def test_api_acknowledges_removal_without_claiming_cleanup(self):
        sample = ADAPTER['api_sample']
        caller = Mock(side_effect=[{'Id': 'abcd'}, None, {'StatusCode': 0}, None])
        with patch.dict(sample.__globals__, {'api': caller}):
            row = sample(Mock(), {'api_version': '1.41', 'image': 'fixture', 'command': ['true']},
                         'none', 'owned', 'token')
        self.assertIsNone(row['error'])
        self.assertIsNotNone(row['api_removed_ns'])
        self.assertIsNone(row['cleanup_complete_ns'])
        self.assertEqual(list(row['stages_ns']), ['create', 'start', 'wait', 'remove'])
        self.assertEqual([call.args[1] for call in caller.call_args_list],
                         ['POST', 'POST', 'POST', 'DELETE'])

    def test_lost_create_response_recovers_by_owned_name_without_retry(self):
        sample = ADAPTER['api_sample']
        caller = Mock(side_effect=[OSError('connection lost'), None])
        connection = Mock()
        with patch.dict(sample.__globals__, {'api': caller}):
            row = sample(connection, {'api_version': '1.41', 'image': 'fixture', 'command': ['true']},
                         'none', 'owned', 'token')
        self.assertEqual(row['error'], 'connection lost')
        self.assertIsNone(row['api_removed_ns'])
        self.assertEqual(caller.call_args.args[1:4],
                         ('DELETE', '/v1.41/containers/owned?force=true', (204, 404)))
        self.assertEqual(caller.call_count, 2)
        connection.close.assert_called_once()

    def test_failed_samples_count_in_throughput_denominator(self):
        summary = ADAPTER['summarize']([
            {'elapsed_ns': 200_000_000, 'error': None},
            {'elapsed_ns': 800_000_000, 'error': 'fixture failed'},
        ])
        self.assertEqual(summary['operations'], 2)
        self.assertEqual(summary['failures'], 1)
        self.assertEqual(summary['successes_per_second'], 1.0)
        self.assertEqual(summary['p99_ns'], 200_000_000)

    def test_session_cleanup_scopes_removal_to_verified_ids(self):
        cleanup = ADAPTER['cleanup_fixtures']
        container_id = 'a' * 64
        runner = Mock(side_effect=[container_id, container_id, ''])
        docker = ['docker', '--context', 'kiri-speedup']
        with patch.dict(cleanup.__globals__, {'run': runner}):
            self.assertEqual(cleanup(docker, {}, 'token'), [container_id])
        self.assertIn('label=dev.conjet.benchmark.session=token', runner.call_args_list[0].args[0])
        self.assertEqual(runner.call_args_list[1].args[0], docker + ['rm', '-f', container_id])

    def test_endpoint_outside_candidate_session_is_rejected(self):
        checks = SimpleNamespace(engine='conjet', socket=Path('/var/run/docker.sock'),
                                 config=Path('/tmp/docker'), peer_pid=1)
        with self.assertRaisesRegex(RuntimeError, 'outside the launcher session'):
            ADAPTER['verify_endpoint'](checks)


if __name__ == '__main__':
    unittest.main()
