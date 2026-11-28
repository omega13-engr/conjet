"""API conformance fixtures and pending contracts."""
from datetime import datetime
import hashlib
import http.client
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
from tempfile import TemporaryDirectory
import unittest
from urllib.parse import urlencode
import uuid

from support import API, alpine, container, exec_command


class CompatibilityTests(unittest.TestCase):
    def test_version_negotiation(self):
        'DC-001: Negotiate supported API versions; reject unsupported versions without mutation.'
        session = self.compatibility
        current = session.connection.server_version['ApiVersion']
        minimum = session.connection.server_version['MinAPIVersion']
        status, body = session.request('GET', '/version')
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)['ApiVersion'], current)
        self.assertEqual(json.loads(body)['MinAPIVersion'], minimum)

        ping = {}
        for label, path in (
                ('unversioned', '/_ping'),
                ('common', '/v1.44/_ping'),
                ('current', f'/v{current}/_ping'),
                ('minimum', f'/v{minimum}/_ping')):
            status, body = session.request('GET', path)
            self.assertEqual((status, body), (200, b'OK'), label)
            self.assertEqual(session.request('HEAD', path), (200, b''), label)
            ping[label] = status

        rejected = {}
        for label, version in (('old', '1.39'), ('new', '1.999')):
            name = 'conjet-version-' + uuid.uuid4().hex
            inspect = f'/v1.44/volumes/{name}'
            try:
                status, body = session.request('POST', f'/v{version}/volumes/create', {'Name': name})
                observed, _ = session.request('GET', inspect)
                self.assertEqual(observed, 404, f'unsupported {label} API mutated volume state')
                self.assertEqual(status, 400, label)
                self.assertTrue(json.loads(body).get('message'), label)
                rejected[label] = status
            finally:
                status, _ = session.request('DELETE', inspect)
                self.assertIn(status, (204, 404), f'could not clean up the {label} API probe')
        session.record({'ping': ping, 'rejected_versions': rejected})

    def test_response_contracts(self):
        'DC-002: Compare status codes, null versus absent fields, errors and filters with reference Docker.'
        session = self.compatibility
        collection = '/v1.44/volumes'
        token = uuid.uuid4().hex
        name = 'conjet-response-' + token
        volume = collection + '/' + name
        labels = {'dev.conjet.compatibility': token}

        def shape(mapping, field):
            return type(mapping[field]).__name__ if field in mapping else 'absent'

        try:
            created_status, raw = session.request('POST', collection + '/create',
                                                  {'Name': name, 'Labels': labels})
            self.assertEqual(created_status, 201)
            created = json.loads(raw)
            self.assertEqual(created['Name'], name)
            self.assertEqual(created['Labels'], labels)
            inspect_status, raw = session.request('GET', volume)
            self.assertEqual(inspect_status, 200)
            inspected = json.loads(raw)
            self.assertEqual(created.get('CreatedAt'), inspected.get('CreatedAt'))
            if 'CreatedAt' in created:
                self.assertIsNotNone(datetime.fromisoformat(created['CreatedAt']).utcoffset())

            query = urlencode({'filters': json.dumps({'label': [f'dev.conjet.compatibility={token}']})})
            list_status, raw = session.request('GET', collection + '?' + query)
            self.assertEqual(list_status, 200)
            listing = json.loads(raw)
            self.assertEqual([item['Name'] for item in listing['Volumes']], [name])

            invalid_status, raw = session.request('GET', collection + '?filters=invalid-json')
            self.assertGreaterEqual(invalid_status, 400)
            self.assertIsInstance(json.loads(raw)['message'], str)
            missing_status, raw = session.request('GET', volume + '-missing')
            self.assertEqual(missing_status, 404)
            self.assertIsInstance(json.loads(raw)['message'], str)
            session.record({
                'statuses': [created_status, inspect_status, list_status, invalid_status, missing_status],
                'creation_fields': {field: shape(created, field)
                                    for field in ('Options', 'CreatedAt', 'Status', 'ClusterVolume')},
                'list_warnings': shape(listing, 'Warnings'),
            })
        finally:
            removed, _ = session.request('DELETE', volume)
            self.assertIn(removed, (204, 404))

    def test_http_framing(self):
        'DC-003: Exercise chunked trailers, Expect, keepalive and Connection close without losing request boundaries.'
        session = self.compatibility
        connection = session.connection
        collection = '/v1.44/volumes'
        name = 'conjet-framing-' + uuid.uuid4().hex
        volume = collection + '/' + name
        body = json.dumps({'Name': name}).encode()

        def response(channel, method):
            with http.client.HTTPResponse(channel, method=method) as reply:
                reply.begin()
                data = reply.read(65537)
                self.assertLessEqual(len(data), 65536)
                return reply.status, data, reply.will_close

        try:
            # Use the launcher's authenticated socket for an ordinary streaming
            # create. Wait for the interim reply before supplying the chunks.
            connection.connect()
            channel = connection.sock
            channel.sendall(
                f'POST {collection}/create HTTP/1.1\r\n'
                'Host: localhost\r\nContent-Type: application/json\r\n'
                'Transfer-Encoding: chunked\r\nTrailer: X-Fixture\r\n'
                'Expect: 100-continue\r\n\r\n'.encode()
            )
            with channel.makefile('rb', buffering=0) as wire:
                self.assertTrue(wire.readline(512).startswith(b'HTTP/1.1 100 '))
                self.assertEqual(wire.readline(512), b'\r\n')
            for chunk in (body[:8], body[8:]):
                channel.sendall(f'{len(chunk):x}\r\n'.encode() + chunk + b'\r\n')
            channel.sendall(b'0\r\nX-Fixture: complete\r\n\r\n')
            created, data, close = response(channel, 'POST')
            self.assertEqual(created, 201)
            self.assertFalse(close)
            self.assertEqual(json.loads(data)['Name'], name)

            channel.sendall(f'GET {volume} HTTP/1.1\r\nHost: localhost\r\n\r\n'.encode())
            inspected, data, close = response(channel, 'GET')
            self.assertEqual(inspected, 200)
            self.assertFalse(close)
            self.assertEqual(json.loads(data)['Name'], name)

            channel.sendall(
                f'DELETE {volume} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n'.encode()
            )
            deleted, data, close = response(channel, 'DELETE')
            self.assertEqual((deleted, data, close), (204, b'', True))
            self.assertEqual(channel.recv(1), b'')
            session.record({'created': created, 'inspected': inspected, 'deleted': deleted})
        finally:
            connection.close()
            status, _ = session.request('DELETE', volume)
            self.assertIn(status, (204, 404))

    def test_exec_exit(self):
        'DC-004: Java and Python SDK exec returns complete stdout, stderr and integer terminal exit status.'
        session = self.compatibility
        connection = session.connection
        home = connection.root
        classpath_file = Path(os.environ['CONJET_COMPAT_DOCKER_JAVA_CLASSPATH']).resolve(strict=True)
        classpath = classpath_file.read_text().strip()
        jars = [Path(path).resolve(strict=True) for path in classpath.split(os.pathsep)]
        self.assertTrue(all(path.is_relative_to(classpath_file.parent) and path.suffix == '.jar'
                            for path in jars))
        self.assertIn('docker-java-core-3.7.1.jar', {path.name for path in jars})
        self.assertIn('docker-java-transport-httpclient5-3.7.1.jar', {path.name for path in jars})
        java = shutil.which('java')
        self.assertIsNotNone(java, 'docker-java fixture requires Java 11 or later')
        clients = Path(__file__).resolve().parents[1] / 'clients'
        endpoint = 'unix://' + str(connection.endpoint)
        commands = [
            "printf 'stdout-before\\n'; printf 'stderr-before\\n' >&2; "
            "sleep 0.1; printf 'stdout-end\\n'; printf 'stderr-end\\n' >&2; exit 0",
            r"head -c 70001 /dev/zero | tr '\000' O; "
            r"head -c 70003 /dev/zero | tr '\000' E >&2; exit 37",
        ]
        expected = [
            {'exit': 0, 'stdout': 'stdout-before\nstdout-end\n', 'stderr': 'stderr-before\nstderr-end\n'},
            {'exit': 37, 'stdout': 'O' * 70001, 'stderr': 'E' * 70003},
        ]
        name = 'conjet-sdk-exec-' + uuid.uuid4().hex
        with alpine(self, session) as image, container(self, session, name, {
                'Image': image, 'Cmd': ['/bin/sleep', '120'], 'HostConfig': {'NetworkMode': 'none'},
        }) as (path, identifier):
            status, body = session.request('POST', path + '/start')
            self.assertEqual(status, 204, body)

            # Both SDKs connect only while the owner-controlled socket retains
            # its verified identity. They receive an empty credential directory.
            with TemporaryDirectory(dir=home) as sdk_home:
                invocations = {
                    'docker-py': [sys.executable, '-B', str(clients / 'exec_probe.py'), endpoint,
                                  identifier, *commands],
                    'docker-java': [java, '-Duser.home=' + sdk_home, '-Djava.io.tmpdir=' + sdk_home,
                                    '-Djna.tmpdir=' + sdk_home, '-cp', classpath,
                                    str(clients / 'java/ExecProbe.java'), endpoint, sdk_home,
                                    identifier, *commands],
                }
                completed = {}
                for client, arguments in invocations.items():
                    with self.subTest(client=client):
                        connection.connect()
                        connection.close()
                        result = subprocess.run(
                            arguments, cwd=sdk_home, env={
                                'HOME': sdk_home, 'PATH': '/usr/bin:/bin', 'TMPDIR': sdk_home,
                                'DOCKER_CONFIG': sdk_home,
                            },
                            capture_output=True, timeout=22, check=False,
                        )
                        connection.connect()
                        connection.close()
                        self.assertEqual(result.returncode, 0, result.stderr.decode(errors='replace'))
                        observed = json.loads(result.stdout)
                        self.assertEqual(len(observed), len(expected))
                        for actual, target in zip(observed, expected):
                            self.assertIs(type(actual['exit']), int)
                            self.assertEqual(actual['exit'], target['exit'])
                            for stream in ('stdout', 'stderr'):
                                self.assertTrue(actual[stream] == target[stream],
                                                f'{stream} bytes differ for exit {target["exit"]}')
                        completed[client] = observed

        if len(completed) != len(invocations):
            return

        session.record({
            'clients': {'docker-py': '7.1.0', 'docker-java': '3.7.1'},
            'commands': [
                {'exit': outcome['exit'], **{
                    stream: hashlib.sha256(outcome[stream].encode()).hexdigest()
                    for stream in ('stdout', 'stderr')
                }}
                for outcome in completed['docker-py']
            ],
        })

    def test_network_connect_status(self):
        'DC-005: Node Testcontainers connects an alias network and resolves its peer successfully.'
        session = self.compatibility
        connection = session.connection
        package = Path(os.environ['CONJET_COMPAT_TESTCONTAINERS_PACKAGE']).resolve(strict=True)
        nodes = shutil.which('node')
        self.assertIsNotNone(nodes, 'network alias fixture requires Node.js')
        source = Path(__file__).resolve().parents[1] / 'clients/network_probe.cjs'
        name = 'conjet-testcontainers-' + uuid.uuid4().hex
        with alpine(self, session) as image, TemporaryDirectory(dir=connection.root) as node_home:
            try:
                connection.connect()
                connection.close()
                result = subprocess.run(
                    [nodes, str(source), str(package), str(connection.endpoint), image, name],
                    cwd=node_home, env={
                        'HOME': node_home, 'PATH': '/usr/bin:/bin', 'TMPDIR': node_home,
                        'DOCKER_CONFIG': node_home, 'DOCKER_HOST': 'unix://' + str(connection.endpoint),
                        'TESTCONTAINERS_RYUK_DISABLED': 'true', 'TESTCONTAINERS_REUSE_ENABLE': 'false',
                    },
                    capture_output=True, timeout=30, check=False,
                )
                connection.connect()
                connection.close()
                self.assertEqual(result.returncode, 0, result.stderr.decode(errors='replace'))
                observed = json.loads(result.stdout)
                self.assertEqual(observed, {'client': 'testcontainers-node/12.2.2', 'lookup': 'peer-ipv4'})
                for path in (f'/containers/{name}-client/json', f'/containers/{name}-peer/json',
                             f'/networks/{name}'):
                    self.assertEqual(session.request('GET', API + path)[0], 404, path)
            finally:
                for suffix in ('-client', '-peer'):
                    status, body = session.request('DELETE', API + f'/containers/{name}{suffix}?force=true')
                    self.assertIn(status, (204, 404), body)
                status, body = session.request('DELETE', API + '/networks/' + name)
                self.assertIn(status, (204, 404), body)
        session.record(observed)

    def test_inspect_recreate(self):
        'DC-006: Recreate from inspect metadata and preserve mounts, ports, environment and labels.'
        session = self.compatibility
        token = uuid.uuid4().hex
        name = 'conjet-inspect-' + token
        volume = API + '/volumes/' + name
        port = '8080/tcp'
        environment = 'CONJET_RECREATE_MARKER=' + token
        labels = {'dev.conjet.fixture': 'inspect-recreate'}
        mounts = [{'Type': 'volume', 'Source': name, 'Target': '/payload'}]
        ports = {port: [{'HostIp': '127.0.0.1', 'HostPort': ''}]}

        def inspect(path):
            status, body = session.request('GET', path + '/json')
            self.assertEqual(status, 200, body)
            data = json.loads(body)
            self.assertIs(data['State']['Running'], True)
            self.assertIn(environment, data['Config']['Env'])
            self.assertEqual(data['Config']['Labels'], labels)
            self.assertIn(port, data['Config']['ExposedPorts'])
            self.assertEqual(data['HostConfig']['PortBindings'], ports)
            values = [{field: mount[field] for field in ('Type', 'Name', 'Destination', 'RW')}
                      for mount in data['Mounts']]
            self.assertEqual(values, [{'Type': 'volume', 'Name': name,
                                       'Destination': '/payload', 'RW': True}])
            binding, = data['NetworkSettings']['Ports'][port]
            self.assertEqual(binding['HostIp'], '127.0.0.1')
            self.assertIn(int(binding['HostPort']), range(1, 65536))
            return data

        def start(path):
            status, body = session.request('POST', path + '/start')
            self.assertEqual(status, 204, body)

        with alpine(self, session) as image:
            try:
                status, body = session.request('POST', API + '/volumes/create', {'Name': name})
                self.assertEqual(status, 201, body)
                initial = {
                    'Image': image, 'Cmd': ['/bin/sleep', '120'], 'Env': [environment],
                    'Labels': labels, 'ExposedPorts': {port: {}},
                    'HostConfig': {'Mounts': mounts, 'PortBindings': ports},
                }
                with container(self, session, name, initial) as (path, original):
                    start(path)
                    metadata = inspect(path)
                    result = exec_command(self, session, path, ['/bin/sh', '-c',
                                          'printf %s "$CONJET_RECREATE_MARKER" >/payload/value'])
                    self.assertEqual(result, (0, b'', b''))

                config = metadata['Config']
                recreate = {field: config[field] for field in
                            ('Image', 'Cmd', 'Env', 'Labels', 'ExposedPorts')}
                recreate['HostConfig'] = {
                    'PortBindings': metadata['HostConfig']['PortBindings'],
                    'Mounts': [{'Type': mount['Type'], 'Source': mount['Name'],
                                'Target': mount['Destination'], 'ReadOnly': not mount['RW']}
                               for mount in metadata['Mounts']],
                }
                with container(self, session, name, recreate) as (path, recreated):
                    self.assertNotEqual(recreated, original)
                    start(path)
                    inspect(path)
                    result = exec_command(self, session, path, ['/bin/sh', '-c',
                                          'test "$(cat /payload/value)" = "$CONJET_RECREATE_MARKER" '
                                          '&& cat /payload/value'])
                    self.assertEqual(result, (0, token.encode(), b''))
            finally:
                status, body = session.request('DELETE', volume)
                self.assertIn(status, (204, 404), body)
        session.record({'mount_type': 'volume', 'read_write': True, 'published_port': port,
                        'published_host': '127.0.0.1', 'same_bytes': True,
                        'environment_preserved': True, 'labels': labels})
