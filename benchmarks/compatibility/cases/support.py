"""Neutral workloads used by the live differential fixtures."""

from contextlib import contextmanager
import json
from urllib.parse import quote, urlencode


ALPINE = ('docker.io/library/alpine@sha256:'
          'e233f2058b0628266762f745a2c17e623b418e0090f47d223909d1f9a7d4367e')
API = '/v1.44'


@contextmanager
def alpine(test, session):
    repository, digest = ALPINE.split('@')
    config_digest = 'sha256:062964a69725bb96611dae2ac911a5a1ab3f8d32fe6f096f267d77f09e55a99c'
    image_path = API + '/images/' + quote(ALPINE, safe='')
    original, _ = session.request('GET', image_path + '/json')
    test.assertIn(original, (200, 404))
    try:
        if original == 404:
            query = urlencode({'fromImage': repository, 'tag': digest, 'platform': 'linux/arm64'})
            pull = type(session)(session.connection.peer(timeout=25))
            test.assertEqual(pull.request('POST', API + '/images/create?' + query)[0], 200)
        status, data = session.request('GET', image_path + '/json')
        test.assertEqual(status, 200, data)
        inspected = json.loads(data)
        test.assertIn(inspected['Id'], (config_digest, digest))
        test.assertEqual(inspected['Architecture'], 'arm64')
        test.assertTrue(any(item.rsplit('@', 1)[-1] == digest for item in inspected['RepoDigests']))
        yield ALPINE
    finally:
        if original == 404:
            removed, body = session.request('DELETE', image_path)
            test.assertIn(removed, (200, 404), body)


@contextmanager
def container(test, session, name, specification):
    path = API + '/containers/' + name
    try:
        status, data = session.request('POST', API + '/containers/create?' + urlencode({'name': name}),
                                       specification)
        test.assertEqual(status, 201, data)
        yield path, json.loads(data)['Id']
    finally:
        status, data = session.request('DELETE', path + '?force=true')
        test.assertIn(status, (204, 404), data)


def exec_command(test, session, container_path, command):
    status, data = session.request('POST', container_path + '/exec', {
        'Cmd': command, 'AttachStdout': True, 'AttachStderr': True, 'Tty': False,
    })
    test.assertEqual(status, 201, data)
    path = API + '/exec/' + json.loads(data)['Id']
    status, data = session.request('POST', path + '/start', {'Detach': False, 'Tty': False})
    test.assertEqual(status, 200, data)
    streams = {1: bytearray(), 2: bytearray()}
    offset = 0
    while offset < len(data):
        header = data[offset:offset + 8]
        test.assertEqual(len(header), 8)
        stream = header[0]
        test.assertIn(stream, streams)
        test.assertEqual(header[1:4], b'\0' * 3)
        size = int.from_bytes(header[4:], 'big')
        offset += 8
        test.assertLessEqual(offset + size, len(data))
        streams[stream].extend(data[offset:offset + size])
        offset += size
    status, data = session.request('GET', path + '/json')
    test.assertEqual(status, 200, data)
    inspected = json.loads(data)
    test.assertIs(inspected['Running'], False)
    test.assertIs(type(inspected['ExitCode']), int)
    return inspected['ExitCode'], bytes(streams[1]), bytes(streams[2])
