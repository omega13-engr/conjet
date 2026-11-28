"""Production socket refusal and live Unix peer identity tests."""

from contextlib import contextmanager
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import unittest

from identity import DockerConnection, SCRATCH


@unittest.skipUnless(sys.platform == 'darwin' and SCRATCH.is_dir(),
                     'requires Darwin Unix peer credentials and ExternalSSD')
class EndpointIdentityTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(self.enterContext(tempfile.TemporaryDirectory(prefix='id-', dir=SCRATCH)))
        self.path = self.root / 'd.sock'
        self.executable = Path(subprocess.check_output(
            ['/bin/ps', '-p', str(os.getpid()), '-o', 'comm='], text=True).strip())
        self.version = {'Version': 'fixture', 'ApiVersion': '1.47', 'Os': 'linux',
                        'Arch': 'arm64', 'KernelVersion': 'fixture'}

    @contextmanager
    def listener(self):
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
            listener.bind(str(self.path))
            listener.listen()
            yield listener
        self.path.unlink(missing_ok=True)

    def test_capture_requires_live_peer_and_checks_the_socket_inode(self):
        with self.listener() as listener:
            def respond():
                with listener.accept()[0] as channel:
                    channel.settimeout(5)
                    request = channel.recv(4096)
                    if request.startswith(b'GET /version HTTP/'):
                        body = json.dumps(self.version).encode()
                        channel.sendall(b'HTTP/1.1 200 OK\r\nContent-Length: ' +
                                        str(len(body)).encode() + b'\r\n\r\n' + body)

            server = threading.Thread(target=respond)
            server.start()
            try:
                client = DockerConnection(self.path, self.root, set(), os.getpid())
                result = client.capture(self.executable)
                self.assertEqual(result['version'], self.version)
                self.assertEqual(result['endpoint']['inode'], self.path.stat().st_ino)
                self.assertEqual(result['endpoint']['peer_pid'], os.getpid())
                peer = client.peer(timeout=2)
                self.assertEqual(peer.server_version, client.server_version)
            finally:
                server.join(timeout=6)
            self.path.rename(self.root / 'retired.sock')
            with self.listener():
                with self.assertRaisesRegex(RuntimeError, 'changed after identity'):
                    client.connect()
                with self.assertRaisesRegex(RuntimeError, 'changed after identity'):
                    peer.connect()

    def test_an_unverified_connection_cannot_open_a_peer(self):
        client = DockerConnection(self.path, self.root, set(), os.getpid())
        with self.assertRaisesRegex(RuntimeError, 'capture the Docker endpoint'):
            client.peer()

    def test_wrong_peer_refused_before_transmitting_http(self):
        with self.listener() as listener:
            with self.assertRaisesRegex(RuntimeError, 'launcher PID'):
                DockerConnection(self.path, self.root, set(), os.getpid() + 1).connect()
            listener.settimeout(5)
            with listener.accept()[0] as channel:
                channel.settimeout(5)
                self.assertEqual(channel.recv(1), b'')

    def test_forbidden_production_and_symlink_paths_are_refused(self):
        default = Path('/var/run/docker.sock')
        forbidden = {self.path, default}
        alias = self.root / 'alias.sock'
        alias.symlink_to(self.path)
        with self.listener():
            for path in (default, self.path, alias):
                with self.subTest(path=path):
                    with self.assertRaisesRegex(ValueError, 'outside its private session'):
                        DockerConnection(path, self.root, forbidden, os.getpid()).connect()

    def test_session_directory_has_to_be_private(self):
        self.root.chmod(0o755)
        with self.assertRaisesRegex(ValueError, 'private session directory'):
            DockerConnection(self.path, self.root, set(), os.getpid())


if __name__ == '__main__':
    unittest.main()
