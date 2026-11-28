"""Installed-product conformance fixtures and pending contracts."""

import hashlib
import json
from pathlib import Path
import subprocess
from tempfile import TemporaryDirectory
import unittest
import uuid

from support import API


class CompatibilityTests(unittest.TestCase):
    def test_help_no_effects(self):
        'DC-077: All help and version commands leave processes, Docker config, shell profiles and startup registrations unchanged.'
        self.fail('UNIMPLEMENTED DC-077; no runtime compatibility evidence')

    def test_socket_coexistence(self):
        'DC-078: Explicit test context remains isolated; startup and stop do not replace production socket or selected context.'
        session = self.compatibility
        docker = Path('/opt/homebrew/bin/docker')
        with docker.open('rb') as file:
            docker_sha = hashlib.file_digest(file, 'sha256').hexdigest()
        self.assertEqual(docker_sha, 'cb59cf76741a247388e6a84f8defa5054c12dcd5e05d84a3ed8638dac2f34077')
        root = session.connection.root
        token = uuid.uuid4().hex
        name = 'conjet-context-' + token
        volume = API + '/volumes/' + name
        labels = {'dev.conjet.fixture.context': token}
        host = 'unix://' + str(session.connection.endpoint)

        with TemporaryDirectory(dir=root) as scratch:
            docker_config = Path(scratch) / 'docker'
            docker_config.mkdir(mode=0o700)

            def cli(*arguments):
                connection = session.connection
                connection.connect()
                connection.close()
                result = subprocess.run(
                    [docker, '--config', docker_config, *arguments],
                    cwd=scratch, env={'HOME': scratch, 'PATH': '/usr/bin:/bin',
                                      'DOCKER_CONFIG': str(docker_config)},
                    capture_output=True, text=True, timeout=12,
                )
                connection.connect()
                connection.close()
                self.assertEqual(result.returncode, 0, result.stderr)
                return result.stdout.strip()

            def verify():
                self.assertEqual(cli('context', 'show'), name)
                self.assertEqual(cli('context', 'inspect', '--format', '{{.Endpoints.docker.Host}}', name), host)
                found = json.loads(cli('--context', name, 'volume', 'inspect', name))
                self.assertEqual(len(found), 1)
                self.assertEqual((found[0]['Name'], found[0]['Labels']), (name, labels))

            try:
                self.assertEqual(cli('context', 'show'), 'default')
                cli('context', 'create', name, '--docker', 'host=' + host)
                cli('context', 'use', name)
                status, raw = session.request('POST', API + '/volumes/create', {'Name': name, 'Labels': labels})
                self.assertEqual(status, 201, raw)
                verify()
                session.restart_engine()
                self.assertEqual('unix://' + str(session.connection.endpoint), host)
                verify()
                self.assertEqual(session.request('DELETE', volume)[0], 204)
                self.assertEqual(session.request('GET', volume)[0], 404)
                cli('context', 'use', 'default')
                cli('context', 'rm', name)
                self.assertEqual(cli('context', 'show'), 'default')
                contexts = cli('context', 'ls', '--format', '{{.Name}}').splitlines()
                self.assertEqual(contexts, ['default'])
            finally:
                status, raw = session.request('DELETE', volume)
                self.assertIn(status, (204, 404), raw)

        session.record({'docker_sha256': docker_sha, 'retained_selected_context': True,
                        'reattached_to_same_private_socket_path': True, 'verified_volume': True,
                        'context_removed': True})

    def test_upgrade_rollback(self):
        'DC-079: Installed candidate preserves supported data across upgrade and documented rollback using isolated copies.'
        self.fail('UNIMPLEMENTED DC-079; no runtime compatibility evidence')
