import json
from pathlib import Path
import runpy
import tempfile
import unittest

SUMMARY = runpy.run_path(str(Path(__file__).with_name('docker-comparison-summary.py')))


class StatisticsTests(unittest.TestCase):
    def test_nearest_rank_retains_tail_and_reports_failures(self):
        rows = [{'elapsed_ns': n, 'error': None} for n in range(1, 101)]
        rows.append({'elapsed_ns': 200, 'error': 'timeout'})
        result = SUMMARY['summarized_samples'](rows, 10**9)
        self.assertEqual(result, {'samples': 101, 'failures': 1, 'p50_ns': 50,
                                  'p95_ns': 95, 'p99_ns': 99, 'successes_per_second': 100.0})

    def test_bootstrap_uses_at_least_five_paired_sessions(self):
        metric = SUMMARY['paired_interval']
        self.assertIsNone(metric([(2, 1)] * 4))
        self.assertEqual(metric([(2, 1)] * 5, resamples=100),
                         {'paired_sessions': 5, 'ratio': 2.0, 'ci95': [2.0, 2.0]})

    def test_setup_failure_survives_summary_without_timed_samples(self):
        with tempfile.TemporaryDirectory(dir='/Volumes/ExternalSSD/dev_workspace/tmp') as work:
            path = Path(work) / 'session.json'
            path.write_text(json.dumps({'operations': [
                {'scenario': 'builder-bootstrap', 'phase': 'setup', 'error': 'timed out'},
                {'scenario': 'build', 'phase': 'warmup', 'error': 'canary mismatch'},
                {'scenario': 'build', 'phase': 'sample', 'error': None, 'elapsed_ns': 30},
            ]}))
            summary = SUMMARY['summarize'](path)
        self.assertEqual(summary['groups']['build']['warmup_failures'], 1)
        self.assertEqual(summary['operation_failures'][0]['scenario'], 'builder-bootstrap')

    def test_registry_cold_pair_requires_a_transfer_witness_for_every_sample(self):
        with tempfile.TemporaryDirectory(dir='/Volumes/ExternalSSD/dev_workspace/tmp') as work:
            root = Path(work)
            (root / 'pair.json').write_text(json.dumps({'pair': 1, 'mode': 'images', 'order': ['conjet', 'kiri']}))
            paths = []
            for engine in ('conjet', 'kiri'):
                path = root / engine / 'session.json'
                path.parent.mkdir()
                rows = [{'scenario': 'registry.small.first-pull', 'phase': 'sample', 'elapsed_ns': 100,
                         'cache_state': 'complete config and layer transfer observed'} for _ in range(5)]
                if engine == 'kiri':
                    rows[0]['cache_state'] = 'transfer unknown'
                path.write_text(json.dumps({'mode': 'images', 'engine': engine, 'passed': True, 'operations': rows}))
                paths.append(path)
            results = SUMMARY['paired_intervals'](paths, 'images')
        self.assertEqual(results['registry.small.first-pull']['complete_pairs'], [])


if __name__ == '__main__':
    unittest.main()
