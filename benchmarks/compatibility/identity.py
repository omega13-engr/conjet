"""Capture and verify launcher-owned Docker endpoint and binary identities."""

from dataclasses import asdict, dataclass
import hashlib
import http.client
import json
import os
from pathlib import Path
import socket
import stat
import subprocess

SCRATCH = Path('/Volumes/ExternalSSD/dev_workspace/tmp')
MAX_VERSION_BYTES = 65536


def sha256(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def private_directory(path):
    if path.resolve(strict=True) != path or not path.is_dir() or not path.is_relative_to(SCRATCH):
        raise ValueError(f'expected a canonical ExternalSSD directory: {path}')
    info = path.stat()
    if path == SCRATCH or info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) & 0o077:
        raise ValueError(f'expected a private session directory: {path}')
    return path


def production_sockets(docker):
    home = Path.home()
    config = home / '.docker'
    contexts = subprocess.run(
        [docker, '--config', config, 'context', 'ls', '--format', '{{.DockerEndpoint}}'],
        env={'PATH': '/usr/bin:/bin', 'HOME': str(home)},
        timeout=10, check=True, text=True, capture_output=True,
    ).stdout.splitlines()
    return {Path('/var/run/docker.sock'), home / '.docker/run/docker.sock',
            home / '.conjet/run/docker.sock',
            *(Path(value.removeprefix('unix://')) for value in contexts if value.startswith('unix://'))}


def socket_stat(path, root, forbidden):
    if path in forbidden or not path.is_relative_to(root) or path.resolve() != path:
        raise ValueError(f'Docker socket is outside its private session: {path}')
    info = path.lstat()
    if info.st_uid != os.geteuid() or not stat.S_ISSOCK(info.st_mode):
        raise ValueError(f'expected an owned Docker socket: {path}')
    return info


@dataclass(frozen=True)
class EndpointIdentity:
    path: str
    peer_pid: int
    peer_path: str
    peer_sha256: str
    device: int
    inode: int


class DockerConnection(http.client.HTTPConnection):
    def __init__(self, path, root, forbidden, expected_pid, *, timeout=5):
        super().__init__('localhost', timeout=timeout)
        self.endpoint = path
        self.root = private_directory(root)
        self.forbidden = {path.resolve() for path in forbidden} | forbidden
        if expected_pid <= 1:
            raise ValueError('an owned Docker peer PID is required')
        self.expected_pid = expected_pid
        self.identity = None
        self.server_version = None

    def peer(self, *, timeout=None):
        if self.identity is None or self.server_version is None:
            raise RuntimeError('capture the Docker endpoint before opening another connection')
        connection = DockerConnection(self.endpoint, self.root, self.forbidden, self.expected_pid,
                                      timeout=self.timeout if timeout is None else timeout)
        connection.identity = self.identity
        connection.server_version = self.server_version.copy()
        return connection

    def connect(self):
        before = socket_stat(self.endpoint, self.root, self.forbidden)
        channel = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            channel.settimeout(self.timeout)
            channel.connect(str(self.endpoint))
            if channel.getsockopt(0, 2) != self.expected_pid:  # Darwin LOCAL_PEERPID
                raise RuntimeError('Docker socket peer does not match the launcher PID')
            after = socket_stat(self.endpoint, self.root, self.forbidden)
            if (before.st_dev, before.st_ino) != (after.st_dev, after.st_ino):
                raise RuntimeError('Docker socket changed while connecting')
            if self.identity and (after.st_dev, after.st_ino) != (self.identity.device,
                                                                 self.identity.inode):
                raise RuntimeError('Docker socket changed after identity capture')
        except BaseException:
            channel.close()
            raise
        self.sock = channel

    def capture(self, expected_executable):
        executable = Path(subprocess.run(
            ['/bin/ps', '-p', str(self.expected_pid), '-o', 'comm='], check=True,
            capture_output=True, text=True, timeout=10,
        ).stdout.strip()).resolve(strict=True)
        if executable != expected_executable.resolve(strict=True):
            raise RuntimeError('Docker peer executable does not match the launcher artifact')
        info = socket_stat(self.endpoint, self.root, self.forbidden)
        witness = EndpointIdentity(str(self.endpoint), self.expected_pid, str(executable),
                                   sha256(executable), info.st_dev, info.st_ino)
        if self.identity and self.identity != witness:
            raise RuntimeError('Docker endpoint identity changed')
        self.identity = witness
        try:
            self.request('GET', '/version')
            with self.getresponse() as reply:
                raw = reply.read(MAX_VERSION_BYTES + 1)
                if reply.status != 200 or len(raw) > MAX_VERSION_BYTES:
                    raise RuntimeError('Docker endpoint did not return a bounded server version')
            version = json.loads(raw)
            fields = ('Version', 'ApiVersion', 'Os', 'Arch')
            if not isinstance(version, dict) or any(
                    not isinstance(version.get(field), str) or not version[field] for field in fields
                ):
                raise RuntimeError('Docker endpoint returned an incomplete server version')
            for field in ('MinAPIVersion', 'KernelVersion'):
                if field in version:
                    if not isinstance(version[field], str) or not version[field]:
                        raise RuntimeError(f'Docker endpoint returned an invalid {field}')
                    fields += (field,)
            observed = {field: version[field] for field in fields}
            platform = version.get('Platform')
            if isinstance(platform, dict) and isinstance(platform.get('Name'), str):
                observed['platform'] = platform['Name']
            self.server_version = observed
            return {'endpoint': asdict(witness), 'version': observed}
        finally:
            self.close()
