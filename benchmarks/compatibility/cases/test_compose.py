"""Compose conformance fixtures and pending contracts."""

from datetime import datetime
import hashlib
import json
from pathlib import Path
import subprocess
from tempfile import TemporaryDirectory
import unittest
import uuid

from support import ALPINE, API


DOCKER = Path('/opt/homebrew/bin/docker')
COMPOSE = Path('/opt/homebrew/lib/docker/cli-plugins/docker-compose')
DOCKER_SHA256 = 'cb59cf76741a247388e6a84f8defa5054c12dcd5e05d84a3ed8638dac2f34077'
COMPOSE_SHA256 = '429abdc8a6c39bb9cdf218203cae37414a38525c70dd7b0bd8c57ead5b552184'


def compose_command(test, connection, root, project, options):
    for client, expected in ((DOCKER, DOCKER_SHA256), (COMPOSE, COMPOSE_SHA256)):
        with client.open('rb') as source:
            test.assertEqual(hashlib.file_digest(source, 'sha256').hexdigest(), expected, client)
    config = root / 'docker-config'
    plugins = config / 'cli-plugins'
    plugins.mkdir(parents=True, exist_ok=True)
    plugin = plugins / 'docker-compose'
    if not plugin.is_symlink():
        plugin.symlink_to(COMPOSE)
    test.assertEqual(plugin.resolve(strict=True), COMPOSE.resolve(strict=True))

    def call(*args):
        connection.connect()
        connection.close()
        cmd = [DOCKER, '--config', config, '--host', 'unix://' + str(connection.endpoint),
               'compose', '--project-name', project, *options]
        result = subprocess.run([*cmd, *args], cwd=root, env={
            'HOME': str(root), 'PATH': '/usr/bin:/bin', 'DOCKER_CONFIG': str(config),
        }, capture_output=True, text=True, timeout=18)
        connection.connect()
        connection.close()
        return result

    return call


class CompatibilityTests(unittest.TestCase):
    def test_config_resolution(self):
        'DC-067: Overrides, interpolation, env files, profiles, includes and relative paths match pinned official Compose processing.'
        session = self.compatibility
        connection = session.connection
        with TemporaryDirectory(dir=connection.root) as scratch:
            root = Path(scratch)
            (root / 'compose.yaml').write_text('''include:
  - ./included/child.yaml
services:
  web:
    image: "${FIXTURE_IMAGE:?fixture image required}"
    env_file:
      - ./web.env
    environment:
      MERGED: base
      INTERPOLATED: "${FIXTURE_VALUE:-fallback}"
    volumes:
      - ./data:/payload
  diagnostics:
    image: "${FIXTURE_IMAGE}"
    profiles: [debug]
''')
            (root / 'override.yaml').write_text('''services:
  web:
    environment:
      MERGED: override
      ADDED: from-override
''')
            (root / 'web.env').write_text('FROM_ENV_FILE=web-file\nMERGED=env-file\n')
            (root / 'project.env').write_text('FIXTURE_IMAGE=alpine:3.22\nFIXTURE_VALUE=from-project\n')
            (root / 'data').mkdir()
            child = root / 'included'
            child.mkdir()
            (child / 'assets').mkdir()
            (child / 'child.env').write_text('INCLUDED_ENV=child-file\n')
            (child / 'child.yaml').write_text('''services:
  included:
    image: alpine:3.22
    env_file: ./child.env
    volumes:
      - ./assets:/assets:ro
''')

            options = ('-f', 'compose.yaml', '-f', 'override.yaml')
            call_with_env = compose_command(self, connection, root, 'conjet-fixture-config',
                                            (*options, '--env-file', 'project.env'))
            call_without_env = compose_command(self, connection, root, 'conjet-fixture-config',
                                               options)

            def call(*args, use_env=True):
                return (call_with_env if use_env else call_without_env)(*args)

            def model(*args):
                result = call(*args, 'config', '--format', 'json')
                self.assertEqual(result.returncode, 0, result.stderr)
                return json.loads(result.stdout)['services']

            profiles = call('config', '--profiles')
            self.assertEqual(profiles.returncode, 0, profiles.stderr)
            self.assertEqual(profiles.stdout.splitlines(), ['debug'])
            default = model()
            enabled = model('--profile', 'debug')
            self.assertEqual(set(default), {'web', 'included'})
            self.assertEqual(set(enabled), set(default) | {'diagnostics'})
            self.assertEqual({name: enabled[name] for name in default}, default)
            self.assertEqual(enabled['diagnostics']['profiles'], ['debug'])
            self.assertTrue(all(spec['image'] == 'alpine:3.22' for spec in enabled.values()))
            web = enabled['web']['environment']
            self.assertEqual(web, {'ADDED': 'from-override', 'FROM_ENV_FILE': 'web-file',
                                   'INTERPOLATED': 'from-project', 'MERGED': 'override'})
            self.assertEqual(enabled['included']['environment'], {'INCLUDED_ENV': 'child-file'})
            binds = {}
            for name in ('web', 'included'):
                mount, = enabled[name]['volumes']
                self.assertEqual(mount['type'], 'bind')
                self.assertTrue(Path(mount['source']).is_absolute())
                binds[name] = (str(Path(mount['source']).relative_to(root)), mount['target'],
                               mount.get('read_only', False))
            self.assertEqual(binds, {'web': ('data', '/payload', False),
                                     'included': ('included/assets', '/assets', True)})
            rejected = call('config', '--format', 'json', use_env=False)
            self.assertNotEqual(rejected.returncode, 0)
            self.assertIn('fixture image required', rejected.stderr)

        session.record({'compose_sha256': COMPOSE_SHA256, 'profile': 'debug',
                        'default_services': sorted(default), 'enabled_services': sorted(enabled),
                        'binds': binds, 'merged_environment': web,
                        'missing_required_value_rejected': True})

    def test_health_dependencies(self):
        'DC-068: Started, healthy and completed dependencies plus up wait enforce actual readiness and failure semantics.'
        session = self.compatibility
        connection = session.connection
        project = 'conjet-health-' + uuid.uuid4().hex[:12]
        compose_file = f'''x-base: &base
  image: "{ALPINE}"
  pull_policy: never
  network_mode: none
services:
  anchor:
    <<: *base
    command: ["/bin/sleep", "120"]
  gate:
    <<: *base
    command: ["/bin/sh", "-c", "sleep 1; echo ready >/data/gate; exec sleep 120"]
    volumes: ["shared:/data"]
    depends_on:
      anchor:
        condition: service_started
    healthcheck:
      test: ["CMD-SHELL", "test -s /data/gate"]
      interval: 250ms
      timeout: 500ms
      retries: 12
  job:
    <<: *base
    command: ["/bin/sh", "-c", "test -s /data/gate || exit 41; echo complete >/data/job"]
    volumes: ["shared:/data"]
    depends_on:
      gate:
        condition: service_healthy
  app:
    <<: *base
    command: ["/bin/sh", "-c", "test -s /data/job || exit 42; echo active >/data/app; exec sleep 120"]
    volumes: ["shared:/data"]
    depends_on:
      job:
        condition: service_completed_successfully
    healthcheck:
      test: ["CMD-SHELL", "test -s /data/app"]
      interval: 250ms
      timeout: 500ms
      retries: 12
volumes:
  shared:
'''
        unhealthy = f'''x-base: &base
  image: "{ALPINE}"
  pull_policy: never
  network_mode: none
services:
  gate:
    <<: *base
    command: ["/bin/sleep", "120"]
    healthcheck:
      test: ["CMD-SHELL", "exit 1"]
      interval: 250ms
      timeout: 500ms
      retries: 2
  app:
    <<: *base
    command: ["/bin/sleep", "120"]
    depends_on:
      gate:
        condition: service_healthy
'''
        failed_job = f'''x-base: &base
  image: "{ALPINE}"
  pull_policy: never
  network_mode: none
services:
  job:
    <<: *base
    command: ["/bin/sh", "-c", "exit 41"]
  app:
    <<: *base
    command: ["/bin/sleep", "120"]
    depends_on:
      job:
        condition: service_completed_successfully
'''

        def inspect(suffix, service, absent_ok=False):
            name = f'{project}{suffix}-{service}-1'
            status, raw = session.request('GET', API + '/containers/' + name + '/json')
            if absent_ok and status == 404:
                return {'Running': False}
            self.assertEqual(status, 200, raw)
            return json.loads(raw)['State']

        with TemporaryDirectory(dir=connection.root) as scratch:
            root = Path(scratch)
            for suffix, fixture in (('', compose_file), ('-health', unhealthy), ('-job', failed_job)):
                file = root / ('compose' + suffix + '.yaml')
                file.write_text(fixture)
                call = compose_command(self, connection, root, project + suffix, ('-f', file))
                try:
                    launched = call('up', '--detach', '--wait', '--wait-timeout', '12')
                    if not suffix:
                        self.assertEqual(launched.returncode, 0, launched.stderr)
                        anchor, gate, job, app = (inspect(suffix, service)
                                                  for service in ('anchor', 'gate', 'job', 'app'))
                        self.assertIs(anchor['Running'], True)
                        self.assertEqual(gate['Health']['Status'], 'healthy')
                        self.assertEqual((job['ExitCode'], job['Status']), (0, 'exited'))
                        self.assertEqual(app['Health']['Status'], 'healthy')
                        for first, second in ((anchor['StartedAt'], gate['StartedAt']),
                                              (job['FinishedAt'], app['StartedAt'])):
                            first_stamp, second_stamp = map(datetime.fromisoformat, (first, second))
                            self.assertGreaterEqual(first_stamp.year, 2000)
                            self.assertLessEqual(first_stamp, second_stamp)
                    else:
                        self.assertNotEqual(launched.returncode, 0, launched.stderr)
                        self.assertIs(inspect(suffix, 'app', absent_ok=True)['Running'], False)
                        if suffix == '-health':
                            self.assertIn('unhealthy', launched.stderr)
                            self.assertEqual(inspect(suffix, 'gate')['Health']['Status'], 'unhealthy')
                        else:
                            self.assertIn('41', launched.stderr)
                            self.assertEqual(inspect(suffix, 'job')['ExitCode'], 41)
                finally:
                    owned = [API + f'/containers/{project}{suffix}-{service}-1'
                             for service in ('anchor', 'gate', 'job', 'app')]
                    volume = API + f'/volumes/{project}_shared'
                    try:
                        down = call('down', '--volumes', '--timeout', '0')
                        self.assertEqual(down.returncode, 0, down.stderr)
                        for path in owned:
                            self.assertEqual(session.request('GET', path + '/json')[0], 404)
                        if not suffix:
                            self.assertEqual(session.request('GET', volume)[0], 404)
                    finally:
                        for path in owned:
                            status, raw = session.request('DELETE', path + '?force=true')
                            self.assertIn(status, (204, 404), raw)
                        if not suffix:
                            status, raw = session.request('DELETE', volume)
                            self.assertIn(status, (204, 404), raw)

        session.record({'started_dependency': True, 'healthy_dependency': True,
                        'completed_dependency': True, 'wait_observed_health': True,
                        'unhealthy_dependency_blocked_start': True, 'failed_job_blocked_start': True})

    def test_resource_fields(self):
        'DC-069: Compose limits, reservations and capabilities reach actual cgroup and process state; no silent ineffective settings.'
        self.fail('UNIMPLEMENTED DC-069; no runtime compatibility evidence')

    def test_secrets_configs(self):
        'DC-070: File and supported environment sources mount with correct targets and access; missing sources fail before start.'
        self.fail('UNIMPLEMENTED DC-070; no runtime compatibility evidence')

    def test_lifecycle_scale(self):
        'DC-071: Scale, recreate, restart, orphan removal and down preserve or remove resources according to flags.'
        self.fail('UNIMPLEMENTED DC-071; no runtime compatibility evidence')

    def test_watch_hooks(self):
        'DC-072: Supported watch and lifecycle hooks execute in correct order; failures and unsupported configuration are explicit.'
        self.fail('UNIMPLEMENTED DC-072; no runtime compatibility evidence')

    def test_build_pull_policy(self):
        'DC-073: Up build and pull policy select correct artifact; project build secrets and additional contexts function.'
        self.fail('UNIMPLEMENTED DC-073; no runtime compatibility evidence')
