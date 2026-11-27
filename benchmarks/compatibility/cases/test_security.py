"""Unimplemented conformance contracts; replace each failure with its real fixture."""
import unittest


class CompatibilityTests(unittest.TestCase):
    def test_cap_drop(self):
        'DC-019: Drop ALL; inspect capability sets and prove a capability-dependent operation fails.'
        self.fail('UNIMPLEMENTED DC-019; no runtime compatibility evidence')

    def test_cap_add(self):
        'DC-020: Add NET_ADMIN in a private network namespace; permitted operation succeeds without unrelated capabilities.'
        self.fail('UNIMPLEMENTED DC-020; no runtime compatibility evidence')

    def test_read_only(self):
        'DC-021: Rootfs write fails while writable named volume succeeds.'
        self.fail('UNIMPLEMENTED DC-021; no runtime compatibility evidence')

    def test_no_new_privileges(self):
        'DC-022: Kernel NoNewPrivs is set and a controlled setuid elevation is denied.'
        self.fail('UNIMPLEMENTED DC-022; no runtime compatibility evidence')

    def test_seccomp(self):
        'DC-023: Configured syscall allow and deny behavior matches policy; unsupported profiles fail before start.'
        self.fail('UNIMPLEMENTED DC-023; no runtime compatibility evidence')

    def test_namespace_sharing(self):
        'DC-024: Verify private, host and container PID and IPC modes against guest identities without contaminating supervisor namespaces.'
        self.fail('UNIMPLEMENTED DC-024; no runtime compatibility evidence')

    def test_privileged_devices(self):
        'DC-025: Verify supported privileged and device access remains within VM boundary; unsupported requests fail explicitly.'
        self.fail('UNIMPLEMENTED DC-025; no runtime compatibility evidence')
