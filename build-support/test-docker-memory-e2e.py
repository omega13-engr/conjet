#!/usr/bin/env python3
"""Prevent compression or missing telemetry from masquerading as memory return."""

import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location(
    "memory_e2e", Path(__file__).with_name("run-docker-memory-e2e.py"))
suite = importlib.util.module_from_spec(spec)
spec.loader.exec_module(suite)
MIB = 1024 * 1024


def sample(rss, footprint, compressed):
    return {"host_memory": {"resident_bytes": rss * MIB,
                            "physical_footprint_bytes": footprint * MIB,
                            "compressed_bytes": compressed * MIB}}


class MemoryReturnTests(unittest.TestCase):
    def test_compressing_pages_does_not_count_as_return(self):
        evidence = suite.return_evidence(sample(1024, 1024, 0), sample(512, 1024, 512))
        self.assertFalse(suite.memory_returned(evidence, 256 * MIB))

    def test_releasing_pages_counts_as_return(self):
        evidence = suite.return_evidence(sample(1024, 1100, 76), sample(512, 570, 58))
        self.assertTrue(suite.memory_returned(evidence, 256 * MIB))

    def test_net_release_is_counted_when_remaining_pages_are_compressed(self):
        evidence = suite.return_evidence(sample(2000, 2000, 0), sample(1000, 1500, 500))
        self.assertTrue(suite.memory_returned(evidence, 256 * MIB))
        self.assertEqual(evidence["resident_plus_compressed_drop_bytes"], 500 * MIB)

    def test_clean_rss_drop_cannot_hide_compressed_growth(self):
        evidence = suite.return_evidence(sample(2000, 1000, 0), sample(1500, 1200, 500))
        self.assertFalse(suite.memory_returned(evidence, 256 * MIB))

    def test_missing_accounting_is_not_treated_as_zero(self):
        before = sample(1024, 1024, 0)
        after = sample(512, 512, 0)
        del after["host_memory"]["compressed_bytes"]
        with self.assertRaisesRegex(AssertionError, "requires compressed_bytes"):
            suite.return_evidence(before, after)


if __name__ == "__main__":
    unittest.main()
