import json
import runpy
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

MODULE = runpy.run_path(str(Path(__file__).with_name('docker-comparison.py')))
SCRATCH = MODULE['SCRATCH']


class ComparisonSafetyTests(unittest.TestCase):
    def test_rejects_non_launcher_endpoints_before_connecting(self):
        args = SimpleNamespace(engine='conjet', socket=Path('/var/run/docker.sock'),
                               config=Path.home() / '.docker', peer_pid=1, docker=Path('docker'))
        with self.assertRaisesRegex(RuntimeError, 'outside the launcher session'):
            MODULE['TOOLS']['verify_endpoint'](args)
        args.engine = 'kiri'
        with self.assertRaisesRegex(RuntimeError, 'outside its managed session'):
            MODULE['TOOLS']['verify_endpoint'](args)

    def test_manifest_alternates_and_retains_lifecycle_budget(self):
        manifest = MODULE['contract']()
        expected = [('conjet', 'kiri'), ('kiri', 'conjet')]
        for index, pair in enumerate(manifest['session_order']):
            self.assertEqual(tuple(pair), expected[index % 2])
        lane = manifest['suites']['lifecycle']
        self.assertGreaterEqual(lane['sessions'], 5)
        self.assertGreaterEqual(lane['sessions'] * lane['samples_per_session'], 10000)

    def test_timeout_lets_owned_launcher_save_partial_evidence(self):
        with tempfile.TemporaryDirectory(dir=SCRATCH) as directory:
            state = Path(directory) / 'worker.json'
            command = [
                sys.executable, '-c',
                'import pathlib, signal, time, sys\n'
                'p = pathlib.Path(sys.argv[1])\n'
                'def stop(*_):\n'
                '    p.write_text(\'{"terminated": true}\')\n'
                '    sys.exit(143)\n'
                'signal.signal(signal.SIGTERM, stop)\n'
                'print("ready", flush=True)\n'
                'time.sleep(10)\n', str(state)]
            with subprocess.Popen(command, stdout=subprocess.PIPE, text=True) as process:
                self.assertEqual(process.stdout.readline().strip(), 'ready')
                with self.assertRaises(subprocess.TimeoutExpired):
                    MODULE['wait_for_launcher'](process, 0.05)
                self.assertEqual(process.poll(), 143)
            self.assertEqual(json.loads(state.read_text()), {'terminated': True})


if __name__ == '__main__':
    unittest.main()
