"""Unimplemented conformance contracts; replace each failure with its real fixture."""
import unittest


class CompatibilityTests(unittest.TestCase):
    def test_amd64(self):
        'DC-085: Foreign-platform pull, build and execution use emulation correctly or fail explicitly before execution.'
        self.fail('UNIMPLEMENTED DC-085; no runtime compatibility evidence')

    def test_plugins(self):
        'DC-086: Each advertised volume, network and logging plugin contract passes lifecycle and failure tests.'
        self.fail('UNIMPLEMENTED DC-086; no runtime compatibility evidence')

    def test_gpu_cdi(self):
        'DC-087: Advertised GPU or CDI devices perform a real workload; unavailable hardware is not reported as supported.'
        self.fail('UNIMPLEMENTED DC-087; no runtime compatibility evidence')

    def test_rootless_checkpoint(self):
        'DC-088: Rootless and checkpoint restore require separate declared capability fixtures; unsupported modes remain explicit.'
        self.fail('UNIMPLEMENTED DC-088; no runtime compatibility evidence')
