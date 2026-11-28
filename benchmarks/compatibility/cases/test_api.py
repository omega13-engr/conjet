"""API conformance fixtures and pending contracts."""
from datetime import datetime
import http.client
import json
import unittest
from urllib.parse import urlencode
import uuid


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
        self.fail('UNIMPLEMENTED DC-004; no runtime compatibility evidence')

    def test_network_connect_status(self):
        'DC-005: Node Testcontainers connects an alias network and resolves its peer successfully.'
        self.fail('UNIMPLEMENTED DC-005; no runtime compatibility evidence')

    def test_inspect_recreate(self):
        'DC-006: Recreate from inspect metadata and preserve mounts, ports, environment and labels.'
        self.fail('UNIMPLEMENTED DC-006; no runtime compatibility evidence')
