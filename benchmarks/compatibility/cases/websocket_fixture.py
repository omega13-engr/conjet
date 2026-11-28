"""Minimal binary WebSocket client for the owned Docker attach endpoint."""

import base64
from contextlib import contextmanager
import hashlib
import os
import struct
from urllib.parse import urlencode


GUID = b'258EAFA5-E914-47DA-95CA-C5AB0DC85B11'


@contextmanager
def open_attach(test, session, target, *, timeout=4):
    peer = session.connection.peer(timeout=timeout)
    try:
        peer.connect()
        channel = peer.sock
        query = urlencode({'stdin': '1', 'stdout': '1', 'stderr': '1', 'stream': '1', 'logs': '0'})
        key = base64.b64encode(os.urandom(16))
        channel.sendall(
            f'GET {target}/attach/ws?{query} HTTP/1.1\r\n'
            'Host: localhost\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n'
            'Origin: http://localhost\r\nSec-WebSocket-Version: 13\r\n'
            'Sec-WebSocket-Key: '.encode() + key + b'\r\n\r\n'
        )
        with channel.makefile('rb', buffering=0) as wire:
            status = wire.readline(512)
            test.assertTrue(status.startswith(b'HTTP/1.1 101 '), status)
            headers = {}
            for _ in range(32):
                line = wire.readline(512)
                if line == b'\r\n':
                    break
                test.assertTrue(line.endswith(b'\r\n'), line)
                name, value = line.split(b':', 1)
                headers[name.lower()] = value.strip()
            else:
                test.fail('WebSocket response exceeded its header bound')
            test.assertEqual(headers.get(b'upgrade', b'').lower(), b'websocket')
            test.assertEqual(headers.get(b'sec-websocket-accept'),
                             base64.b64encode(hashlib.sha1(key + GUID).digest()))
            yield channel, wire
    finally:
        peer.close()


def frame(opcode, payload, *, fin=True):
    first = (0x80 if fin else 0) | opcode
    size = len(payload)
    if size <= 125:
        header = bytes((first, 0x80 | size))
    elif size <= 65535:
        header = bytes((first, 0xfe)) + struct.pack('!H', size)
    else:
        header = bytes((first, 0xff)) + struct.pack('!Q', size)
    mask = os.urandom(4)
    return header + mask + bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))


def exact(test, wire, size):
    output = bytearray()
    while len(output) < size:
        chunk = wire.read(size - len(output))
        test.assertTrue(chunk, 'incomplete WebSocket frame')
        output.extend(chunk)
    return bytes(output)


def receive(test, wire):
    first, second = exact(test, wire, 2)
    test.assertEqual(first & 0xf0, 0x80)
    test.assertFalse(second & 0x80, 'server must not mask frames')
    size = second
    if size == 126:
        size = struct.unpack('!H', exact(test, wire, 2))[0]
        test.assertGreaterEqual(size, 126)
    elif size == 127:
        size = struct.unpack('!Q', exact(test, wire, 8))[0]
        test.assertGreater(size, 65535)
    test.assertLessEqual(size, 65536)
    return first & 0x0f, exact(test, wire, size)


def output(test, wire, expected):
    data = bytearray()
    while len(data) < len(expected):
        opcode, payload = receive(test, wire)
        test.assertIn(opcode, (1, 2))
        test.assertTrue(payload)
        data.extend(payload)
    test.assertEqual(bytes(data), expected)
