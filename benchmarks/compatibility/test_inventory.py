"""Fast tests for inventory integrity and fail-closed result accounting."""
import copy
import json
from pathlib import Path
import runpy
import unittest

HERE = Path(__file__).resolve().parent
RUNNER = runpy.run_path(str(HERE / 'run.py'))
MATRIX = json.loads((HERE / 'matrix.json').read_text())


class InventoryTests(unittest.TestCase):
    def test_every_contract_maps_to_a_test(self):
        RUNNER['validate'](MATRIX)

    def test_missing_method_rejected(self):
        matrix = copy.deepcopy(MATRIX)
        matrix['cases'][0]['test_name'] = 'test_missing'
        with self.assertRaisesRegex(ValueError, 'missing test method'):
            RUNNER['validate'](matrix)

    def test_duplicate_id_rejected(self):
        matrix = copy.deepcopy(MATRIX)
        matrix['cases'].append(matrix['cases'][0])
        with self.assertRaisesRegex(ValueError, 'duplicate case ID'):
            RUNNER['validate'](matrix)

    def test_path_escape_rejected(self):
        matrix = copy.deepcopy(MATRIX)
        matrix['cases'][0]['test_file'] = '../native-compatibility-gate.py'
        with self.assertRaisesRegex(ValueError, 'escaping'):
            RUNNER['validate'](matrix)

    def test_skips_and_expected_failures_block_qualification(self):
        result = unittest.TestResult()
        result.testsRun = 1
        self.assertTrue(RUNNER['qualified'](result, 1))
        for field in ('skipped', 'expectedFailures', 'unexpectedSuccesses'):
            setattr(result, field, [('case', 'reason')])
            self.assertFalse(RUNNER['qualified'](result, 1))
            setattr(result, field, [])
        self.assertFalse(RUNNER['qualified'](result, 2))
        self.assertFalse(RUNNER['qualified'](result, 0))


if __name__ == '__main__':
    unittest.main()
