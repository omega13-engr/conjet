"""Check diagnostic input scope and guest execution evidence."""

from pathlib import Path
from subprocess import CompletedProcess
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from compatibility.egress import diagnose, public_ipv4


class EgressTests(unittest.TestCase):
    def test_reports_dns_and_http_separately_by_network(self):
        def docker(label, *argv, timeout):
            self.assertIn('linux/arm64' if label == 'egress-pull' else '--network', argv)
            self.assertGreater(timeout, 0)
            output = {
                'egress-bridge-dns': 'Name: example.com\n\nprobe-exit:0\n',
                'egress-bridge-direct_http': 'HTTP/1.1 200 OK\r\n\nprobe-exit:0\n',
            }.get(label, '\nprobe-exit:1\n')
            return CompletedProcess(argv, 0, output, '')

        result = diagnose(docker, public_ipv4('1.1.1.1'))['results']
        self.assertTrue(result['bridge']['dns']['observed'])
        self.assertTrue(result['bridge']['direct_http']['observed'])
        self.assertFalse(result['none']['dns']['observed'])
        self.assertFalse(result['none']['direct_http']['observed'])

    def test_requires_guest_marker_and_public_ipv4(self):
        with self.assertRaises(ValueError):
            public_ipv4('127.0.0.1')
        with self.assertRaisesRegex(RuntimeError, 'did not execute'):
            diagnose(lambda _label, *args, **_: CompletedProcess(args, 0, '', ''),
                     public_ipv4('1.1.1.1'))
