"""Unimplemented conformance contracts; replace each failure with its real fixture."""
import unittest


class CompatibilityTests(unittest.TestCase):
    def test_durable_container(self):
        'DC-007: Write a checksum to a container layer; restart engine; start same container and verify bytes and metadata.'
        self.fail('UNIMPLEMENTED DC-007; no runtime compatibility evidence')

    def test_durable_tags(self):
        'DC-008: Local image aliases resolve to the same image after engine restart.'
        self.fail('UNIMPLEMENTED DC-008; no runtime compatibility evidence')

    def test_restart_policy(self):
        'DC-009: Verify no, always, unless-stopped and on-failure across exit, explicit stop and engine restart.'
        self.fail('UNIMPLEMENTED DC-009; no runtime compatibility evidence')

    def test_signal_init(self):
        'DC-010: PID 1 receives configured stop signal; init reaps zombies; timeout escalates and reports exit correctly.'
        self.fail('UNIMPLEMENTED DC-010; no runtime compatibility evidence')

    def test_pause_update(self):
        'DC-011: Pause freezes progress; unpause resumes; resource update preserves unrelated configuration.'
        self.fail('UNIMPLEMENTED DC-011; no runtime compatibility evidence')

    def test_name_races(self):
        'DC-012: Concurrent create with one name admits one owner; failed start releases only its owned resources.'
        self.fail('UNIMPLEMENTED DC-012; no runtime compatibility evidence')

    def test_lost_guest_reply(self):
        'DC-013: Drop a guest reply; request times out and unrelated info and cancellation remain responsive.'
        self.fail('UNIMPLEMENTED DC-013; no runtime compatibility evidence')

    def test_disk_full_recovery(self):
        'DC-014: Fill isolated disk during write and pull; reclaim owned data; restart and verify recovery and original checksums.'
        self.fail('UNIMPLEMENTED DC-014; no runtime compatibility evidence')
