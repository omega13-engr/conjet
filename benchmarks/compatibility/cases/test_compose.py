"""Compose conformance fixtures and pending contracts."""

from datetime import datetime
import hashlib
import json
from pathlib import Path
import subprocess
from tempfile import TemporaryDirectory
import unittest
import uuid

from support import ALPINE, API, exec_command


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
        session = self.compatibility
        connection = session.connection
        project = 'conjet-limits-' + uuid.uuid4().hex[:12]
        alias = f'{project}-worker-1'
        path = API + '/containers/' + alias
        memory, reservation, swap = 48 * 1024 * 1024, 16 * 1024 * 1024, 80 * 1024 * 1024
        file_name = 'compose-limits.yaml'
        fixture = f'''services:
  worker:
    image: "{ALPINE}"
    pull_policy: never
    network_mode: none
    command: ["/bin/sleep", "120"]
    cap_drop: ["ALL"]
    cap_add: ["NET_ADMIN"]
    cpuset: "1"
    memswap_limit: "80M"
    deploy:
      resources:
        limits:
          cpus: "0.250"
          memory: "48M"
          pids: 16
        reservations:
          memory: "16M"
'''
        with TemporaryDirectory(dir=connection.root) as scratch:
            root = Path(scratch)
            (root / file_name).write_text(fixture)
            call = compose_command(self, connection, root, project, ('-f', file_name))
            try:
                up = call('up', '--detach', '--wait', '--wait-timeout', '10')
                self.assertEqual(up.returncode, 0, up.stderr)
                status, raw = session.request('GET', path + '/json')
                self.assertEqual(status, 200, raw)
                inspected = json.loads(raw)
                self.assertIs(inspected['State']['Running'], True)
                expected = {'Memory': memory, 'MemoryReservation': reservation,
                            'MemorySwap': swap, 'NanoCpus': 250_000_000,
                            'PidsLimit': 16, 'CpusetCpus': '1'}
                actual = inspected['HostConfig']
                self.assertEqual({field: actual[field] for field in expected}, expected)
                self.assertEqual([cap.removeprefix('CAP_') for cap in actual['CapAdd']], ['NET_ADMIN'])
                controls = ['memory.max', 'memory.low', 'memory.swap.max', 'cpu.max',
                            'pids.max', 'cpuset.cpus.effective']
                code, output, error = exec_command(self, session, path, [
                    '/bin/cat', *('/sys/fs/cgroup/' + key for key in controls),
                ])
                self.assertEqual((code, error), (0, b''))
                output = output.decode().splitlines()
                self.assertEqual(output, [str(memory), str(reservation), str(swap - memory),
                                          '25000 100000', '16', '1'])
                code, capability, error = exec_command(self, session, path, [
                    '/usr/bin/awk', '/^CapEff:/{print $2}', '/proc/1/status',
                ])
                self.assertEqual((code, error), (0, b''))
                self.assertEqual(int(capability.strip(), 16), 1 << 12)
            finally:
                try:
                    down = call('down', '--timeout', '0')
                    self.assertEqual(down.returncode, 0, down.stderr)
                    self.assertEqual(session.request('GET', path + '/json')[0], 404)
                finally:
                    status, raw = session.request('DELETE', path + '?force=true')
                    self.assertIn(status, (204, 404), raw)

        session.record({'compose_resources': expected, 'cgroup_values': dict(zip(controls, output)),
                        'effective_capabilities': ['NET_ADMIN']})

    def test_secrets_configs(self):
        'DC-070: File and supported environment sources mount with correct targets and access; missing sources fail before start.'
        self.fail('UNIMPLEMENTED DC-070; no runtime compatibility evidence')

    def test_lifecycle_scale(self):
        'DC-071: Scale, recreate, restart, orphan removal and down preserve or remove resources according to flags.'
        session = self.compatibility
        connection = session.connection
        project = 'conjet-lifecycle-' + uuid.uuid4().hex[:12]
        worker_one, worker_two, orphan = (
            f'{project}-worker-1', f'{project}-worker-2', f'{project}-retired-1',
        )
        volume_path = API + f'/volumes/{project}_state'
        marker = b'compose-retained-bytes\n'
        base = f'''services:
  worker:
    image: "{ALPINE}"
    pull_policy: never
    network_mode: none
    command: ["/bin/sleep", "120"]
    volumes: ["state:/data"]
'''
        removed_service = f'''  retired:
    image: "{ALPINE}"
    pull_policy: never
    network_mode: none
    command: ["/bin/sleep", "120"]
'''
        volumes = 'volumes:\n  state:\n'

        def path(name):
            return API + '/containers/' + name

        def inspect(name, running=True):
            status, raw = session.request('GET', path(name) + '/json')
            if not running:
                self.assertEqual(status, 404, raw)
                return None
            self.assertEqual(status, 200, raw)
            data = json.loads(raw)
            self.assertIs(data['State']['Running'], True)
            return data

        def read_marker(name):
            self.assertEqual(exec_command(self, session, path(name), ['/bin/cat', '/data/marker']),
                             (0, marker, b''))

        with TemporaryDirectory(dir=connection.root) as scratch:
            root = Path(scratch)
            file = root / 'compose.yaml'
            file.write_text(base + removed_service + volumes)
            call = compose_command(self, connection, root, project, ('-f', file))

            def completed(*args):
                result = call(*args)
                self.assertEqual(result.returncode, 0, result.stderr)
                return result

            def up(*args):
                completed('up', '--detach', '--wait', '--wait-timeout', '10', *args)

            try:
                up('--scale', 'worker=2')
                first, second = inspect(worker_one), inspect(worker_two)
                self.assertNotEqual(first['Id'], second['Id'])
                inspect(orphan)
                write = exec_command(self, session, path(worker_one), ['/bin/sh', '-c',
                    'printf "%s\n" compose-retained-bytes > /data/marker'])
                self.assertEqual(write, (0, b'', b''))
                read_marker(worker_two)

                up('--scale', 'worker=1')
                self.assertEqual(inspect(worker_one)['Id'], first['Id'])
                inspect(worker_two, False)
                completed('restart', '--timeout', '0', 'worker')
                restarted = inspect(worker_one)
                self.assertEqual(restarted['Id'], first['Id'])
                self.assertGreater(datetime.fromisoformat(restarted['State']['StartedAt']),
                                   datetime.fromisoformat(first['State']['StartedAt']))
                read_marker(worker_one)

                file.write_text(base + volumes)
                up('--force-recreate', '--remove-orphans')
                recreated = inspect(worker_one)
                self.assertNotEqual(recreated['Id'], first['Id'])
                inspect(orphan, False)
                read_marker(worker_one)

                completed('down', '--timeout', '0')
                inspect(worker_one, False)
                self.assertEqual(session.request('GET', volume_path)[0], 200)
                up()
                read_marker(worker_one)
                completed('down', '--volumes', '--timeout', '0')
                inspect(worker_one, False)
                self.assertEqual(session.request('GET', volume_path)[0], 404)
            finally:
                try:
                    completed('down', '--volumes', '--remove-orphans', '--timeout', '0')
                finally:
                    for name in (worker_one, worker_two, orphan):
                        status, raw = session.request('DELETE', path(name) + '?force=true')
                        self.assertIn(status, (204, 404), raw)
                    status, raw = session.request('DELETE', volume_path)
                    self.assertIn(status, (204, 404), raw)

        session.record({'scales': [2, 1], 'restart_preserved_id': True, 'recreated_with_new_id': True,
                        'orphan_removed': True, 'volume_on_down': 'kept',
                        'volume_on_down_with_volumes': 'removed', 'persisted_bytes': marker.decode()})

    def test_watch_hooks(self):
        'DC-072: Supported watch and lifecycle hooks execute in correct order; failures and unsupported configuration are explicit.'
        self.fail('UNIMPLEMENTED DC-072; no runtime compatibility evidence')

    def test_build_pull_policy(self):
        'DC-073: Up build and pull policy select correct artifact; project build secrets and additional contexts function.'
        self.fail('UNIMPLEMENTED DC-073; no runtime compatibility evidence')
