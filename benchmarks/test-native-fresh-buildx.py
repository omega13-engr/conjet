"""Regression check for execution of Linux probes copied from a macOS package."""

from pathlib import Path
import runpy
import stat
import tempfile
import unittest

HARNESS = runpy.run_path(str(Path(__file__).with_name('native-fresh-buildx.py')))


class PackagedProbeTests(unittest.TestCase):
    def test_private_probe_is_executable_and_packaged_resource_keeps_its_mode(self):
        with tempfile.TemporaryDirectory(dir=HARNESS['SCRATCH']) as directory:
            root = Path(directory)
            source = root / 'conjet-launchd-linux-arm64'
            fixture = root / 'probe'
            source.write_bytes(b'packaged guest bytes')
            source.chmod(0o644)

            HARNESS['copy_guest_probe'](root / 'Conjet Core', fixture)

            self.assertEqual(fixture.read_bytes(), source.read_bytes())
            self.assertEqual(stat.S_IMODE(fixture.stat().st_mode), 0o755)
            self.assertEqual(stat.S_IMODE(source.stat().st_mode), 0o644)


if __name__ == '__main__':
    unittest.main()
