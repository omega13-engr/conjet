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


if __name__ == '__main__':
    unittest.main()
