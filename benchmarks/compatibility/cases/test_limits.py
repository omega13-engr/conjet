"""Unimplemented conformance contracts; replace each failure with its real fixture."""
import unittest


class CompatibilityTests(unittest.TestCase):
    def test_cpu_quota(self):
        'DC-026: Quota is applied and sustained load shows throttling; removing quota preserves other limits.'
        self.fail('UNIMPLEMENTED DC-026; no runtime compatibility evidence')

    def test_cpu_affinity(self):
        'DC-027: Requested available CPUs constrain execution; invalid CPU sets are rejected atomically.'
        self.fail('UNIMPLEMENTED DC-027; no runtime compatibility evidence')

    def test_memory_oom(self):
        'DC-028: Hard limit triggers expected OOM state while sibling workload remains healthy.'
        self.fail('UNIMPLEMENTED DC-028; no runtime compatibility evidence')

    def test_reservation_swap(self):
        'DC-029: Reservation and memory-plus-swap combinations match reference cgroup behavior; unsupported settings are explicit.'
        self.fail('UNIMPLEMENTED DC-029; no runtime compatibility evidence')

    def test_pids_ulimits(self):
        'DC-030: Fork and file-open fixtures hit configured PID and descriptor limits without exhausting guest.'
        self.fail('UNIMPLEMENTED DC-030; no runtime compatibility evidence')

    def test_transactional_update(self):
        'DC-031: Invalid multi-field update leaves all previously effective limits unchanged.'
        self.fail('UNIMPLEMENTED DC-031; no runtime compatibility evidence')
