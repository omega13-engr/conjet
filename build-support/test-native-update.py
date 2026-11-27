"""Exercise the built CLI's bundled-Core update response in isolated homes."""
import json
import os
from pathlib import Path
import subprocess
import signal
import tempfile
import unittest

CLI = os.environ.get('CONJET_TEST_CLI')
SCRATCH = Path(os.environ.get('CONJET_TEST_SCRATCH', '/Volumes/ExternalSSD/dev_workspace/tmp'))


class NativeUpdateTests(unittest.TestCase):
    def setUp(self):
        if not CLI or not Path(CLI).is_file():
            self.fail('CONJET_TEST_CLI must point to the built CLI')
        self.tmp = tempfile.TemporaryDirectory(prefix='conjet-update-test-', dir=SCRATCH)
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        self.config = self.home / 'config.toml'
        self.config.write_text('[vm]\nruntime = "native-docker"\n')
        self.env = {**os.environ, 'CONJET_HOME': str(self.home), 'CONJET_PROFILE': 'default'}

    def invoke(self, *args):
        before = self.config.read_bytes()
        process = subprocess.Popen([CLI, 'update', *args], env=self.env,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   text=True, start_new_session=True)
        try:
            stdout, stderr = process.communicate(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.communicate()
            raise
        result = subprocess.CompletedProcess(process.args, process.returncode, stdout, stderr)
        self.assertEqual(before, self.config.read_bytes())
        self.assertFalse((self.home / 'run/conjetd.sock').exists())
        self.assertFalse((self.home / 'run/docker.sock').exists())
        self.assertFalse((self.home / 'run/native-data').exists())
        return result

    def test_plain_update_is_successful_guidance(self):
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('no separate VM image update is performed', result.stdout)
        self.assertIn('brew upgrade --cask conjet', result.stdout)
        self.assertEqual(result.stderr, '')

    def test_json_does_not_claim_update_or_version_check(self):
        result = self.invoke('--json')
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertIs(payload['ok'], True)
        self.assertIs(payload['updated'], False)
        self.assertIs(payload['updateCheckPerformed'], False)

    def test_mutating_options_are_not_silently_ignored(self):
        for args in [('--force',), ('--restart',), ('--image', '/missing.img')]:
            with self.subTest(args=args):
                result = self.invoke(*args)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('cannot update Core assets separately', result.stderr)

    def test_invalid_options_still_fail(self):
        for args in [('--unknown',), ('--restart', '--no-restart')]:
            with self.subTest(args=args):
                self.assertNotEqual(self.invoke(*args).returncode, 0)


if __name__ == '__main__':
    unittest.main()
