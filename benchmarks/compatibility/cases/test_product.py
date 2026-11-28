"""Installed-product conformance fixtures and pending contracts."""

import hashlib
import json
import os
import plistlib
from pathlib import Path
import subprocess
from tempfile import TemporaryDirectory
import unittest
import uuid

from support import API


class CompatibilityTests(unittest.TestCase):
    def test_help_no_effects(self):
        'DC-077: All help and version commands leave processes, Docker config, shell profiles and startup registrations unchanged.'
        session = self.compatibility
        connection = session.connection
        docker = Path('/opt/homebrew/bin/docker')
        plugins_source = Path('/opt/homebrew/lib/docker/cli-plugins')
        with TemporaryDirectory(dir=connection.root) as scratch:
            root = Path(scratch)
            config = root / 'docker'
            plugins = config / 'cli-plugins'
            plugins.mkdir(parents=True)
            for plugin in ('docker-buildx', 'docker-compose'):
                (plugins / plugin).symlink_to(plugins_source / plugin)
            for profile in ('.zshrc', '.bashrc', '.profile'):
                (root / profile).write_text('# private fixture profile\n')

            def private_files():
                fingerprints = {}
                for path in root.rglob('*'):
                    info = path.lstat()
                    if path.is_symlink():
                        value = os.readlink(path)
                    elif path.is_file():
                        value = hashlib.sha256(path.read_bytes()).hexdigest()
                    else:
                        value = None
                    fingerprints[str(path.relative_to(root))] = (info.st_mode, info.st_ino, value)
                return fingerprints

            def call(command, expected):
                connection.connect()
                connection.close()
                try:
                    result = subprocess.run(command, cwd=root, env={
                        'HOME': scratch, 'PATH': '/opt/homebrew/bin:/usr/bin:/bin',
                        'DOCKER_CONFIG': str(config), 'CONJET_HOME': str(root / 'conjet-state'),
                    }, capture_output=True, text=True, timeout=6)
                except subprocess.TimeoutExpired:
                    self.fail(f'help/version command did not return: {Path(command[0]).name} {command[1:]}')
                connection.connect()
                connection.close()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(expected, result.stdout)

            host = 'unix://' + str(connection.endpoint)
            command = [docker, '--config', config, '--host', host]
            before = private_files()
            if connection.server_version['platform'] == 'Conjet Native OCI':
                core = Path(connection.identity.peer_path)
                tools = core.parent.parent
                cli = tools / 'conjet'
                daemon = tools / 'conjetd'
                package = plistlib.loads((tools.parents[1] / 'Info.plist').read_bytes())
                version = 'Conjet ' + package['CFBundleShortVersionString']
                call([daemon, '--help'], 'Usage: conjetd')
                call([daemon, '--version'], version)
                call([cli, '--profile', 'compat-probe', '--version'], version)
                call([cli, '--profile', 'compat-probe', '--help'], 'Usage:')
                for topic in ('doctor', 'ssh', 'key', 'ssh-key', 'status', 'core', 'start', 'stop',
                              'restart', 'update', 'shell', 'vm', 'run', 'compose', 'docker',
                              'memory', 'mem', 'sync', 'project', 'power', 'profile', 'port', 'network'):
                    call([cli, topic, '--help'], 'Usage:')
                call([cli, 'native', '--help'], 'Usage:')
            for arguments, expected in (
                    (['--help'], 'Usage:'),
                    (['--version'], '29.10.1'),
                    (['buildx', '--help'], 'Usage:'),
                    (['buildx', 'version'], 'v0.39.1'),
                    (['compose', '--help'], 'Usage:'),
                    (['compose', 'version', '--short'], '5.8.0')):
                call([*command, *arguments], expected)
            self.assertEqual(private_files(), before)

        session.record({'help_and_version_returned': True, 'private_profile_files_unchanged': True,
                        'pinned_clients': {'docker': '29.10.1', 'buildx': '0.39.1', 'compose': '5.8.0'}})

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
