from pathlib import Path
import runpy
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


if __name__ == '__main__':
    unittest.main()
