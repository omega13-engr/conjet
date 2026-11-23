import gzip
import io
import json
from pathlib import Path
import runpy
import tarfile
import tempfile
import unittest

OCI = runpy.run_path(str(Path(__file__).with_name('oci-image-admission.py')))


def archive_bytes(entries):
    body = io.BytesIO()
    with tarfile.open(fileobj=body, mode='w') as archive:
        for name, data in entries.items():
            item = tarfile.TarInfo(name)
            item.size = len(data)
            archive.addfile(item, io.BytesIO(data))
    return body.getvalue()


class OCIImageAdmissionTests(unittest.TestCase):
    def admit_image(self, rootfs, *, expected=None, staged=None):
        digest = OCI['image_digest']
        config = json.dumps({'architecture': 'arm64', 'os': 'linux',
                             'rootfs': {'type': 'layers', 'diff_ids': [digest(rootfs)]},
                             'config': {'Cmd': ['/bin/sh'], 'Env': ['PATH=/bin'],
                                        'WorkingDir': '/work', 'User': '65532:65532'}}).encode()
        tar = archive_bytes({
            'manifest.json': b'[{"Config":"config.json","Layers":["rootfs.tar.gz"]}]',
            'config.json': config, 'rootfs.tar.gz': gzip.compress(staged or rootfs),
        })
        with tempfile.TemporaryDirectory(dir=OCI['SCRATCH']) as temporary:
            path = Path(temporary) / 'image.tar'
            path.write_bytes(tar)
            return OCI['admit'](path, expected or digest(config))

    def test_validates_linux_arm64_rootfs_and_process_metadata(self):
        result = self.admit_image(archive_bytes({'bin/sh': b'fixture'}))
        self.assertEqual(result['platform'], 'linux/arm64')
        self.assertEqual(result['process']['User'], '65532:65532')
        self.assertEqual(result['process']['Cmd'], ['/bin/sh'])
        self.assertEqual(result['rootfs_entries'], 1)

    def test_rejects_config_and_uncompressed_layer_digest_mismatch(self):
        good = archive_bytes({'bin/sh': b'fixture'})
        with self.assertRaisesRegex(ValueError, 'config digest'):
            self.admit_image(good, expected='sha256:' + '0' * 64)
        with self.assertRaisesRegex(ValueError, 'diff ID'):
            self.admit_image(good, staged=archive_bytes({'bin/sh': b'changed'}))

    def test_rejects_non_rooted_member_paths(self):
        with self.assertRaisesRegex(ValueError, 'unsafe image archive member path'):
            self.admit_image(archive_bytes({'../outside': b'fixture'}))


if __name__ == '__main__':
    unittest.main()
