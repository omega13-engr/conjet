"""Unimplemented conformance contracts; replace each failure with its real fixture."""
import unittest


class CompatibilityTests(unittest.TestCase):
    def test_dockerfile(self):
        'DC-060: Test each pinned Dockerfile instruction and flag through separate parametrized fixtures, including multi-stage and ignore rules.'
        self.fail('UNIMPLEMENTED DC-060; no runtime compatibility evidence')

    def test_cache_invalidation(self):
        'DC-061: Unchanged, source-only and dependency changes reuse only valid cache; outputs have expected checksums.'
        self.fail('UNIMPLEMENTED DC-061; no runtime compatibility evidence')

    def test_secret_ssh(self):
        'DC-062: Secret and SSH sessions work; secret material is absent from final image, history and exported cache.'
        self.fail('UNIMPLEMENTED DC-062; no runtime compatibility evidence')

    def test_drivers(self):
        'DC-063: Qualify default docker and docker-container drivers separately with explicit capability reporting.'
        self.fail('UNIMPLEMENTED DC-063; no runtime compatibility evidence')

    def test_outputs(self):
        'DC-064: Load, OCI, local and registry outputs preserve identity; built image is immediately inspectable and runnable.'
        self.fail('UNIMPLEMENTED DC-064; no runtime compatibility evidence')

    def test_cancel_concurrent(self):
        'DC-065: Concurrent builds plus cancellation clean mounts and processes without corrupting cache or sibling build.'
        self.fail('UNIMPLEMENTED DC-065; no runtime compatibility evidence')

    def test_contexts_bake(self):
        'DC-066: Named and remote contexts, cache import/export and Bake targets produce expected artifacts.'
        self.fail('UNIMPLEMENTED DC-066; no runtime compatibility evidence')
