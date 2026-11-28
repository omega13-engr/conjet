"""Storage conformance fixtures and pending contracts."""

import hashlib
import json
import unittest
import uuid

from support import API, alpine, container, exec_command


class CompatibilityTests(unittest.TestCase):
    def test_volume_in_use(self):
        'DC-043: Force removal of a volume referenced by running or stopped container is refused and checksum survives.'
        session = self.compatibility
        name = 'conjet-volume-use-' + uuid.uuid4().hex
        volume = API + '/volumes/' + name
        data = b'owned-volume-checksum\n'
        checksum = hashlib.sha256(data).hexdigest().encode()

        def assert_retained(path):
            rejected, raw = session.request('DELETE', volume + '?force=true')
            self.assertEqual(rejected, 409, raw)
            self.assertIsInstance(json.loads(raw)['message'], str)
            status, raw = session.request('GET', volume)
            self.assertEqual(status, 200, raw)
            self.assertEqual(json.loads(raw)['Name'], name)
            if path is not None:
                outcome = exec_command(self, session, path, ['/usr/bin/sha256sum', '/data/value'])
                self.assertEqual(outcome, (0, checksum + b'  /data/value\n', b''))

        with alpine(self, session) as image:
            try:
                status, body = session.request('POST', API + '/volumes/create', {'Name': name})
                self.assertEqual(status, 201, body)
                config = {'Image': image, 'Cmd': ['/bin/sleep', '120'], 'HostConfig': {
                    'NetworkMode': 'none',
                    'Mounts': [{'Type': 'volume', 'Source': name, 'Target': '/data'}],
                }}
                with container(self, session, name, config) as (path, identifier):
                    start_status, body = session.request('POST', path + '/start')
                    self.assertEqual(start_status, 204, body)
                    outcome = exec_command(self, session, path, ['/bin/sh', '-c',
                                           "printf '%s\\n' 'owned-volume-checksum' >/data/value"])
                    self.assertEqual(outcome, (0, b'', b''))
                    assert_retained(path)
                    self.assertEqual(session.request('POST', path + '/stop?t=1')[0], 204)
                    status, body = session.request('GET', path + '/json')
                    self.assertEqual(status, 200, body)
                    stopped = json.loads(body)
                    self.assertIs(stopped['State']['Running'], False)
                    self.assertEqual(stopped['Id'], identifier)
                    assert_retained(None)
                    start_status, body = session.request('POST', path + '/start')
                    self.assertEqual(start_status, 204, body)
                    assert_retained(path)
                    self.assertEqual(session.request('POST', path + '/start')[0], 304)
                self.assertEqual(session.request('DELETE', volume)[0], 204)
                self.assertEqual(session.request('GET', volume)[0], 404)
            finally:
                status, body = session.request('DELETE', volume)
                self.assertIn(status, (204, 404), body)

        session.record({'running_delete': 409, 'stopped_delete': 409,
                        'retained_checksum': checksum.decode(), 'removed_after_container': True})

    def test_volume_copyup(self):
        'DC-044: Named and anonymous volume population, nocopy, UID and mode match reference behavior.'
        self.fail('UNIMPLEMENTED DC-044; no runtime compatibility evidence')

    def test_archive_ownership(self):
        'DC-045: Copy in and out preserve expected UID, GID, mode, links and directory-content semantics.'
        self.fail('UNIMPLEMENTED DC-045; no runtime compatibility evidence')

    def test_host_file_events(self):
        'DC-046: Host create, atomic save, rename and delete emit events and trigger application reload.'
        self.fail('UNIMPLEMENTED DC-046; no runtime compatibility evidence')

    def test_host_permissions(self):
        'DC-047: Parallel non-root creates and renames preserve permission semantics without intermittent EACCES.'
        self.fail('UNIMPLEMENTED DC-047; no runtime compatibility evidence')

    def test_filesystem_metadata(self):
        'DC-048: Exercise xattrs, hardlinks, sparse files, locking and fsync on supported mount types.'
        self.fail('UNIMPLEMENTED DC-048; no runtime compatibility evidence')

    def test_mount_paths(self):
        'DC-049: Bind ExternalSSD paths with spaces and Unicode; distinguish host case sensitivity from guest volume behavior.'
        self.fail('UNIMPLEMENTED DC-049; no runtime compatibility evidence')

    def test_tmpfs_options(self):
        'DC-050: Tmpfs size, UID, GID and mode apply even when image target directory is absent.'
        session = self.compatibility
        name = 'conjet-tmpfs-' + uuid.uuid4().hex[:16]
        target = '/conjet-ephemeral/cache'
        options = 'size=65536,uid=1201,gid=1301,mode=0710'
        mount = {target: options}

        def start(path):
            status, raw = session.request('POST', path + '/start')
            self.assertEqual(status, 204, raw)

        def inspect_mount(path):
            status, raw = session.request('GET', path + '/json')
            self.assertEqual(status, 200, raw)
            detail = json.loads(raw)
            self.assertIs(detail['State']['Running'], True)
            self.assertEqual(detail['HostConfig']['Tmpfs'], mount)
            result = exec_command(self, session, path, ['/bin/busybox', 'stat', '-c', '%u:%g:%a', target])
            self.assertEqual(result, (0, b'1201:1301:710\n', b''))
            result = exec_command(self, session, path, [
                '/bin/sh', '-c', r'df -kP "$1" | awk "NR == 2 { print \$2, \$6 }"', 'fixture', target,
            ])
            self.assertEqual(result, (0, f'64 {target}\n'.encode(), b''))

        with alpine(self, session) as image:
            spec = {'Image': image, 'Cmd': ['/bin/sleep', '120']}
            with container(self, session, name + '-control', {
                    **spec, 'HostConfig': {'NetworkMode': 'none'},
            }) as (path, _):
                start(path)
                self.assertEqual(exec_command(self, session, path, [
                    '/bin/sh', '-c', 'test ! -e "$1"', 'fixture', target,
                ]), (0, b'', b''))

            with container(self, session, name, {
                    **spec, 'HostConfig': {'NetworkMode': 'none', 'ReadonlyRootfs': True, 'Tmpfs': mount},
            }) as (path, _):
                start(path)
                inspect_mount(path)
                result = exec_command(self, session, path, [
                    '/bin/sh', '-c', 'dd if=/dev/zero of="$1/payload" bs=1024 count=64 2>/dev/null '
                    '&& wc -c < "$1/payload"', 'fixture', target,
                ])
                self.assertEqual(result, (0, b'65536\n', b''))
                code, _, error = exec_command(self, session, path, [
                    '/bin/sh', '-c', 'dd if=/dev/zero of="$1/payload" '
                    'bs=1024 count=1 seek=64 conv=notrunc', 'fixture', target,
                ])
                self.assertNotEqual(code, 0)
                self.assertIn(b'No space left on device', error)
                status, raw = session.request('POST', path + '/stop?t=1')
                self.assertEqual(status, 204, raw)
                start(path)
                inspect_mount(path)
                self.assertEqual(exec_command(self, session, path, [
                    '/bin/sh', '-c', 'test ! -e "$1/payload"', 'fixture', target,
                ]), (0, b'', b''))
        session.record({'tmpfs_mode': '0710', 'uid': 1201, 'gid': 1301,
                        'size_bytes': 65536, 'enospc': True, 'empty_after_restart': True})
