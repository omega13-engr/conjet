"""Unimplemented conformance contracts; replace each failure with its real fixture."""
import unittest


class CompatibilityTests(unittest.TestCase):
    def test_version_negotiation(self):
        'DC-001: Negotiate supported API versions; reject unsupported versions without mutation.'
        self.fail('UNIMPLEMENTED DC-001; no runtime compatibility evidence')

    def test_response_contracts(self):
        'DC-002: Compare status codes, null versus absent fields, errors and filters with reference Docker.'
        self.fail('UNIMPLEMENTED DC-002; no runtime compatibility evidence')

    def test_http_framing(self):
        'DC-003: Exercise chunked trailers, Expect, keepalive and Connection close without losing request boundaries.'
        self.fail('UNIMPLEMENTED DC-003; no runtime compatibility evidence')

    def test_exec_exit(self):
        'DC-004: Java and Python SDK exec returns complete stdout, stderr and integer terminal exit status.'
        self.fail('UNIMPLEMENTED DC-004; no runtime compatibility evidence')

    def test_network_connect_status(self):
        'DC-005: Node Testcontainers connects an alias network and resolves its peer successfully.'
        self.fail('UNIMPLEMENTED DC-005; no runtime compatibility evidence')

    def test_inspect_recreate(self):
        'DC-006: Recreate from inspect metadata and preserve mounts, ports, environment and labels.'
        self.fail('UNIMPLEMENTED DC-006; no runtime compatibility evidence')
