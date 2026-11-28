"""Interactive conformance fixtures and pending contracts."""

from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
import json
import time
import unittest
import uuid

from support import API, alpine, container, exec_command


class CompatibilityTests(unittest.TestCase):
    def test_attach_reconnect(self):
        'DC-015: StdinOnce false survives attach disconnect and reconnect without premature EOF.'
        session = self.compatibility
        name = 'conjet-attach-' + uuid.uuid4().hex
        command = (
            'while IFS= read -r line; do '
            'if [ "$line" = finish ]; then printf "done\n"; exit 23; fi; '
            'printf "echo:%s\n" "$line"; done; printf "unexpected-eof\n" >&2; exit 99'
        )

        @contextmanager
        def attach(path, retry=False):
            deadline = time.monotonic() + 3
            while True:
                peer = session.connection.peer(timeout=4)
                try:
                    peer.connect()
                    channel = peer.sock
                    channel.sendall((
                        f'POST {path}/attach?stream=true&stdin=true&stdout=true&stderr=true HTTP/1.1\r\n'
                        'Host: localhost\r\nConnection: Upgrade\r\nUpgrade: tcp\r\nContent-Length: 0\r\n\r\n'
                    ).encode())
                    with channel.makefile('rb', buffering=0) as wire:
                        status = wire.readline(512)
                        headers = {}
                        while True:
                            header = wire.readline(512)
                            if header == b'\r\n':
                                break
                            self.assertTrue(header.endswith(b'\r\n'), repr(header))
                            key, value = header.split(b':', 1)
                            headers[key.lower()] = value.strip()
                            self.assertLessEqual(len(headers), 32)
                        if not (retry and status.startswith(b'HTTP/1.1 409 ')
                                and time.monotonic() < deadline):
                            self.assertTrue(status.startswith(b'HTTP/1.1 101 '), repr(status))
                            self.assertEqual(headers.get(b'upgrade', b'').lower(), b'tcp')
                            yield channel, wire
                            return
                finally:
                    peer.close()
                time.sleep(0.025)

        def read_exact(wire, count):
            data = bytearray()
            while len(data) < count:
                piece = wire.read(count - len(data))
                self.assertTrue(piece, f'EOF after {len(data)}/{count} stream bytes')
                data.extend(piece)
            return bytes(data)

        def lines(wire, expected):
            out = bytearray()
            while len(out) < len(expected):
                header = read_exact(wire, 8)
                self.assertEqual(header[:4], b'\x01\0\0\0')
                size = int.from_bytes(header[4:], 'big')
                self.assertIn(size, range(1, 513))
                out.extend(read_exact(wire, size))
            self.assertEqual(bytes(out), expected)

        with alpine(self, session) as image, container(self, session, name, {
                'Image': image, 'Cmd': ['/bin/sh', '-c', command], 'Tty': False,
                'OpenStdin': True, 'StdinOnce': False, 'AttachStdin': True,
                'AttachStdout': True, 'AttachStderr': True, 'HostConfig': {'NetworkMode': 'none'},
        }) as (path, _):
            status, body = session.request('POST', path + '/start')
            self.assertEqual(status, 204, body)
            with attach(path) as (channel, wire):
                channel.sendall(b'first\n')
                lines(wire, b'echo:first\n')
            status, body = session.request('GET', path + '/json')
            self.assertEqual(status, 200, body)
            inspect = json.loads(body)
            self.assertIs(inspect['State']['Running'], True)
            self.assertIs(inspect['Config']['OpenStdin'], True)
            self.assertIs(inspect['Config']['StdinOnce'], False)
            with attach(path, retry=True) as (channel, wire):
                channel.sendall(b'second\nfinish\n')
                lines(wire, b'echo:second\ndone\n')
            status, body = session.request('POST', path + '/wait?condition=not-running')
            self.assertEqual(status, 200, body)
            self.assertEqual(json.loads(body)['StatusCode'], 23)
        session.record({'first': 'echo:first', 'second': 'echo:second',
                        'survived_disconnect': True, 'exit': 23})

    def test_tty_resize(self):
        'DC-016: TTY allocation and resize update guest dimensions; non-TTY stdout and stderr remain separate.'
        session = self.compatibility
        token = 'conjet-terminal-' + uuid.uuid4().hex[:16]
        height, width = 37, 119
        script = r'''
            test -t 1 && test -t 2 || exit 40
            exec 3<&1
            printf 'tty-stdout\n'
            printf 'tty-stderr\n' >&2
            i=0
            while [ "$i" -lt 120 ]; do
                size=$(stty size <&3 2>/dev/null) || exit 41
                if [ "$size" = "$1" ]; then
                    printf 'dimensions:%s\n' "$size"
                    exit 17
                fi
                i=$((i+1))
                sleep 0.05
            done
            exit 42
        '''

        with alpine(self, session) as image, container(self, session, token, {
                'Image': image, 'Cmd': ['/bin/sleep', '120'],
                'HostConfig': {'NetworkMode': 'none'},
        }) as (path, _):
            status, raw = session.request('POST', path + '/start')
            self.assertEqual(status, 204, raw)
            status, raw = session.request('POST', path + '/exec', {
                'Cmd': ['/bin/sh', '-c', script, 'fixture', f'{height} {width}'],
                'AttachStdout': True, 'AttachStderr': True, 'Tty': True,
            })
            self.assertEqual(status, 201, raw)
            identifier = API + '/exec/' + json.loads(raw)['Id']
            resize = identifier + f'/resize?h={height}&w={width}'

            def launch():
                peer = session.connection.peer(timeout=12)
                try:
                    peer.request('POST', identifier + '/start', json.dumps({'Tty': True, 'Detach': False}),
                                 {'Content-Type': 'application/json'})
                    with peer.getresponse() as response:
                        return response.status, response.read(4097)
                finally:
                    peer.close()

            with ThreadPoolExecutor(max_workers=1) as worker:
                attached = worker.submit(launch)
                deadline = time.monotonic() + 5
                while True:
                    status, raw = session.request('GET', identifier + '/json')
                    self.assertEqual(status, 200, raw)
                    if json.loads(raw)['Running']:
                        status, raw = session.request('POST', resize)
                        if status == 200:
                            break
                        self.assertIn(status, (404, 409), raw)
                    self.assertLess(time.monotonic(), deadline, raw)
                    self.assertFalse(attached.done(), attached.result() if attached.done() else None)
                    time.sleep(0.04)
                status, output = attached.result(timeout=10)
            self.assertEqual(status, 200, output)
            self.assertEqual(output, b'tty-stdout\r\ntty-stderr\r\n' +
                             f'dimensions:{height} {width}\r\n'.encode())
            status, raw = session.request('GET', identifier + '/json')
            self.assertEqual(status, 200, raw)
            terminal = json.loads(raw)
            self.assertIs(terminal['ProcessConfig']['tty'], True)
            self.assertIs(terminal['Running'], False)
            self.assertEqual(terminal['ExitCode'], 17)

            raw = exec_command(self, session, path, [
                '/bin/sh', '-c', 'test ! -t 1 && test ! -t 2 || exit 43; '
                'printf "split-stdout\n"; printf "split-stderr\n" >&2; exit 19',
            ])
            self.assertEqual(raw, (19, b'split-stdout\n', b'split-stderr\n'))
        session.record({'tty_dimensions': [height, width], 'combined_tty_output': True,
                        'split_non_tty_output': True, 'exec_exits': [17, 19]})

    def test_detach_keys(self):
        'DC-017: Detach sequence split across reads detaches without dropping ordinary input or stopping container.'
        self.fail('UNIMPLEMENTED DC-017; no runtime compatibility evidence')

    def test_websocket_attach(self):
        'DC-018: WebSocket masking, ping, close, backpressure and disconnect have bounded memory and correct stream behavior.'
        self.fail('UNIMPLEMENTED DC-018; no runtime compatibility evidence')
