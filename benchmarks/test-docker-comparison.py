from contextlib import ExitStack
from hashlib import sha256
import json
import os
import runpy
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
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

    def test_configures_private_client_copies_and_checks_their_pins(self):
        with tempfile.TemporaryDirectory(dir=SCRATCH) as directory:
            root = Path(directory)
            client_root = root / 'clients'
            config = root / 'config'
            client_root.mkdir(mode=0o700)
            config.mkdir(mode=0o700)
            filenames = {'docker': 'docker', 'buildx': 'docker-buildx', 'compose': 'docker-compose'}
            manifest = {'clients': {}}
            for name, filename in filenames.items():
                path = client_root / filename
                data = name.encode()
                path.write_bytes(data)
                path.chmod(0o500)
                manifest['clients'][name] = {'sha256': sha256(data).hexdigest()}
            with patch.dict(os.environ, {'CONJET_BENCHMARK_CLIENTS': str(client_root)}):
                with ExitStack() as resources:
                    selected = MODULE['configure_clients'](config, manifest, resources)
                    self.assertEqual(selected, {name: str(client_root / filename)
                                                for name, filename in filenames.items()})
                    for filename in ('docker-buildx', 'docker-compose'):
                        self.assertEqual((config / 'cli-plugins' / filename).resolve(),
                                         client_root / filename)
                self.assertFalse((config / 'cli-plugins').exists())
                manifest['clients']['docker']['sha256'] = '0' * 64
                with ExitStack() as resources:
                    with self.assertRaisesRegex(RuntimeError, 'pinned docker executable changed'):
                        MODULE['configure_clients'](config, manifest, resources)
                (client_root / 'docker').unlink()
                (client_root / 'docker').symlink_to(client_root / 'docker-buildx')
                with self.assertRaisesRegex(RuntimeError, 'expected a frozen benchmark executable'):
                    MODULE['client_paths']()

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
