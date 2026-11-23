import json
from pathlib import Path
import runpy
import tarfile
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
MATRIX = runpy.run_path(str(HERE / 'docker-comparison-matrix.py'))
MANIFEST = json.loads((HERE / 'scenarios/docker-comparison-v1.json').read_text())
SCRATCH = Path('/Volumes/ExternalSSD/dev_workspace/tmp')


class WorkloadTests(unittest.TestCase):
    def test_registry_fixture_has_same_identity_for_both_engine_tags(self):
        with tempfile.TemporaryDirectory(dir=SCRATCH) as temporary:
            root = Path(temporary)
            registry = MATRIX['registry_image']
            left = registry(root / 'left.tar', 'localhost:5000/case:one', b'canary', 1024, 3, 1)
            right = registry(root / 'right.tar', 'localhost:5001/case:one', b'canary', 1024, 3, 1)
            self.assertEqual(left, right)
            with tarfile.open(root / 'left.tar') as archive:
                config = json.load(archive.extractfile(left[7:] + '.json'))
                self.assertEqual(config['rootfs']['type'], 'layers')
                self.assertEqual(len(config['rootfs']['diff_ids']), 3)
                self.assertEqual(config['architecture'], 'arm64')

    def test_registry_transfer_requires_an_owned_successful_get(self):
        log = (
            'http.request.method=GET http.request.uri="/v2/owner/small/blobs/sha256:aa" '
            'http.response.status=200 http.response.written=31\n'
            'http.request.method=HEAD http.request.uri="/v2/owner/small/blobs/sha256:bb" '
            'http.response.status=200 http.response.written=12\n'
            'http.request.method=GET http.request.uri="/v2/other/small/blobs/sha256:cc" '
            'http.response.status=200 http.response.written=42\n'
        )
        self.assertEqual(MATRIX['received_blobs'](log, 'owner/small'), {'sha256:aa': 31})

    def test_build_inputs_separate_source_and_local_dependency(self):
        with tempfile.TemporaryDirectory(dir=SCRATCH) as temporary:
            for language in ('go', 'node', 'rust'):
                sources, source, dependency, actions = MATRIX['prepare_files'](
                    language, Path(temporary) / language)
                self.assertIn('source-one', sources[source])
                self.assertIn('dep-one', sources[dependency])
                self.assertNotEqual(source, dependency)
                self.assertTrue(any(step.startswith('RUN ') for step in actions))

    def test_compose_uses_pinned_images_and_loopback_dynamic_ports(self):
        model = MATRIX['compose_definition'](MANIFEST, 'proof')
        app = model['services']['app']
        cache = model['services']['redis']
        self.assertEqual(app['image'], MANIFEST['images']['node']['ref'])
        self.assertEqual(cache['image'], MANIFEST['images']['redis']['ref'])
        self.assertEqual(app['ports'], ['127.0.0.1::8080'])
        self.assertEqual(app['depends_on']['redis']['condition'], 'service_healthy')
        self.assertEqual(cache['volumes'], ['cache:/data'])

    def test_event_order_ignores_extra_actions_but_requires_owned_lifecycle(self):
        check = MATRIX['lifecycle_event_order']

        def stream(actions, identifier='owned'):
            return '\n'.join(json.dumps({'Action': action, 'Actor': {'ID': identifier}})
                             for action in actions)

        self.assertTrue(check(stream(('create', 'attach', 'start', 'die', 'destroy')), 'owned'))
        self.assertFalse(check(stream(('create', 'die', 'start', 'destroy')), 'owned'))
        self.assertFalse(check(stream(('create', 'start', 'die', 'destroy'), 'other'), 'owned'))

    def test_cgroup_limits_require_numeric_cpu_quota_and_use_the_observed_period(self):
        check = MATRIX['matches_cgroup_limits']
        limits = MANIFEST['service_limits']
        self.assertTrue(check(b'134217728\n64\n10000 20000\n', limits))
        self.assertFalse(check(b'134217728\n64\nmax 100000\n', limits))
        self.assertFalse(check(b'134217728\n64\n25000 100000\n', limits))

    def test_build_named_context_requires_the_original_pinned_manifest(self):
        with tempfile.TemporaryDirectory(dir=SCRATCH) as temporary:
            root = Path(temporary)
            for name in ('alpine', 'rust'):
                layout = root / name
                layout.mkdir()
                pin = MANIFEST['images'][name]['ref'].split('@')[1]
                (layout / 'index.json').write_text(json.dumps({'manifests': [{'digest': pin}]}))
            compiler, runtime, args = MATRIX['build_context_args'](root, MANIFEST, 'rust')
            self.assertEqual((compiler, runtime), ('compiler-base', 'runtime-base'))
            self.assertIn('compiler-base=oci-layout://' + str(root / 'rust') + '@' + pin, args)
            (root / 'rust/index.json').write_text('{"manifests":[{"digest":"wrong"}]}')
            with self.assertRaisesRegex(ValueError, 'frozen manifest'):
                MATRIX['build_context_args'](root, MANIFEST, 'rust')


if __name__ == '__main__':
    unittest.main()
