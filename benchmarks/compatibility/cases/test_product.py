"""Unimplemented conformance contracts; replace each failure with its real fixture."""
import unittest


class CompatibilityTests(unittest.TestCase):
    def test_help_no_effects(self):
        'DC-077: All help and version commands leave processes, Docker config, shell profiles and startup registrations unchanged.'
        self.fail('UNIMPLEMENTED DC-077; no runtime compatibility evidence')

    def test_socket_coexistence(self):
        'DC-078: Explicit test context remains isolated; startup and stop do not replace production socket or selected context.'
        self.fail('UNIMPLEMENTED DC-078; no runtime compatibility evidence')

    def test_upgrade_rollback(self):
        'DC-079: Installed candidate preserves supported data across upgrade and documented rollback using isolated copies.'
        self.fail('UNIMPLEMENTED DC-079; no runtime compatibility evidence')
