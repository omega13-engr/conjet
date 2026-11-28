"""Neutral workloads used by the live differential fixtures."""

from contextlib import contextmanager
import json
from urllib.parse import urlencode


try:
    from compatibility.workloads import API, ALPINE, ALPINE_PATH, ensure_alpine
except ModuleNotFoundError as error:
    if error.name != 'compatibility':
        raise
    from workloads import API, ALPINE, ALPINE_PATH, ensure_alpine


@contextmanager
def alpine(test, session):
    original, _ = session.request('GET', ALPINE_PATH + '/json')
    test.assertIn(original, (200, 404))
    try:
        ensure_alpine(session)
        yield ALPINE
    finally:
        if original == 404:
            removed, body = session.request('DELETE', ALPINE_PATH)
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
