"""Storage conformance fixtures and pending contracts."""

import hashlib
import io
import json
import tarfile
import unittest
import uuid

import image_archives
from guest_probe import compile_probe
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
        session = self.compatibility
        prefix = 'conjet-volume-seed-' + uuid.uuid4().hex[:10]
        mount_dir = '/conjet-volume-seed'
        image_tag = prefix + ':local'
        canary = b'neutral-volume-copyup'
        digest = hashlib.sha256(canary).hexdigest().encode()
        created = set()

        def start(path):
            status, raw = session.request('POST', path + '/start')
            self.assertEqual(status, 204, raw)

        def verify(path):
            geometry = exec_command(self, session, path, [
                '/bin/busybox', 'stat', '-c', '%u:%g:%a', mount_dir, mount_dir + '/seed',
            ])
            self.assertEqual(geometry, (0, b'1201:1301:751\n1202:1302:640\n', b''))
            result = exec_command(self, session, path, ['/usr/bin/sha256sum', mount_dir + '/seed'])
            self.assertEqual(result, (0, digest + ('  ' + mount_dir + '/seed\n').encode(), b''))

        def spec(source=None, nocopy=False):
            mount = {'Type': 'volume', 'Target': mount_dir}
            if source is not None:
                mount['Source'] = source
            if nocopy:
                mount['VolumeOptions'] = {'NoCopy': True}
            return {'Image': image_tag, 'Cmd': ['/bin/sleep', '120'],
                    'HostConfig': {'NetworkMode': 'none', 'Mounts': [mount]}}

        with alpine(self, session) as image:
            (_, config_bytes, layers), = image_archives.records(
                self, image_archives.saved(self, session, image),
            )
            added = io.BytesIO()
            with tarfile.open(fileobj=added, mode='w', format=tarfile.USTAR_FORMAT) as archive:
                root = tarfile.TarInfo(mount_dir[1:])
                root.type, root.mode, root.uid, root.gid = tarfile.DIRTYPE, 0o751, 1201, 1301
                archive.addfile(root)
                seed = tarfile.TarInfo(mount_dir[1:] + '/seed')
                seed.size, seed.mode, seed.uid, seed.gid = len(canary), 0o640, 1202, 1302
                archive.addfile(seed, io.BytesIO(canary))
            layer = added.getvalue()
            config = json.loads(config_bytes)
            config['rootfs']['diff_ids'].append('sha256:' + hashlib.sha256(layer).hexdigest())
            config['history'].append({'created_by': 'neutral fixture data'})
            payload = image_archives.build_archive(
                {image_tag: json.dumps(config, sort_keys=True, separators=(',', ':')).encode()},
                [*layers, layer],
            )
            try:
                image_archives.load(self, session, payload)
                named = prefix + '-named'
                empty = prefix + '-nocopy'
                for volume in (named, empty):
                    status, raw = session.request('POST', API + '/volumes/create', {'Name': volume})
                    self.assertEqual(status, 201, raw)
                    created.add(volume)
                with container(self, session, prefix + '-named-use', spec(named)) as (path, _):
                    start(path)
                    verify(path)
                    result = exec_command(self, session, path, ['/bin/sh', '-c',
                        'printf persistent > "$1/modified"', 'fixture', mount_dir])
                    self.assertEqual(result, (0, b'', b''))
                with container(self, session, prefix + '-prepopulated', spec(named)) as (path, _):
                    start(path)
                    verify(path)
                    result = exec_command(self, session, path, ['/bin/cat', mount_dir + '/modified'])
                    self.assertEqual(result, (0, b'persistent', b''))
                with container(self, session, prefix + '-anonymous', spec()) as (path, _):
                    status, raw = session.request('GET', path + '/json')
                    self.assertEqual(status, 200, raw)
                    mount, = json.loads(raw)['Mounts']
                    name = mount['Name']
                    self.assertTrue(name)
                    self.assertNotIn(name, created)
                    created.add(name)
                    start(path)
                    verify(path)
                with container(self, session, prefix + '-no-copy', spec(empty, nocopy=True)) as (path, _):
                    start(path)
                    result = exec_command(self, session, path, [
                        '/bin/sh', '-c', 'test ! -e "$1/seed" && stat -c "%u:%g:%a" "$1"',
                        'fixture', mount_dir,
                    ])
                    self.assertEqual(result, (0, b'0:0:755\n', b''))
            finally:
                for volume in sorted(created):
                    status, raw = session.request('DELETE', API + '/volumes/' + volume)
                    self.assertIn(status, (204, 404), raw)
                image_archives.clean(self, session, image_tag)
        session.record({'named_copyup': True, 'anonymous_copyup': True, 'no_copy_empty': True,
                        'preexisting_volume_preserved': True, 'root_owner_mode': '1201:1301:751',
                        'file_owner_mode': '1202:1302:640', 'preloaded_file_sha256': digest.decode()})

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
        session = self.compatibility
        prefix = 'conjet-fs-metadata-' + uuid.uuid4().hex[:10]
        volume = API + '/volumes/' + prefix
        checksum = 'd232e11aa1d3fd4973d917cec0e9f794c114015f858583945bcb338a0742b2ee'
        probe = compile_probe(self, session.connection, 'dc048-filesystem.S', checksum)
        expected_hash = hashlib.sha256(b'\0' * 1048576 + b'ok').hexdigest().encode()

        def start(path):
            status, raw = session.request('POST', path + '/start')
            self.assertEqual(status, 204, raw)

        def verify(path, root):
            code, stdout, stderr = exec_command(self, session, path, [
                '/bin/sh', '-c', 'stat -c "%i %s %b %h" "$1/metadata-sparse" "$1/metadata-link" '
                '&& sha256sum "$1/metadata-link"', 'fixture', root,
            ])
            self.assertEqual((code, stderr), (0, b''))
            first, second, digest = stdout.splitlines()
            self.assertEqual(first, second)
            _, size, blocks, links = map(int, first.split())
            self.assertEqual(size, 1048578)
            self.assertEqual(links, 2)
            self.assertGreater(blocks, 0)
            self.assertLess(blocks * 512, size)
            self.assertEqual(digest.split()[0], expected_hash)

        with alpine(self, session) as image:
            try:
                status, raw = session.request('POST', API + '/volumes/create', {'Name': prefix})
                self.assertEqual(status, 201, raw)
                with container(self, session, prefix, {
                        'Image': image, 'Cmd': ['/bin/sleep', '120'],
                        'HostConfig': {
                            'NetworkMode': 'none',
                            'Mounts': [{'Type': 'volume', 'Source': prefix, 'Target': '/data'}],
                            'Tmpfs': {'/conjet-meta-tmp': 'size=4194304,mode=0755'},
                        },
                }) as (path, _):
                    start(path)
                    install = exec_command(self, session, path, [
                        '/bin/sh', '-c', 'printf %s "$1" | base64 -d >/tmp/metadata-probe '
                        '&& chmod 0755 /tmp/metadata-probe', 'fixture', probe,
                    ])
                    self.assertEqual(install, (0, b'', b''))
                    code, release, error = exec_command(self, session, path, ['/bin/uname', '-r'])
                    self.assertEqual((code, error), (0, b''))
                    major, minor, _ = release.decode().split('.', 2)
                    tmpfs_has_user_xattrs = (int(major), int(minor)) >= (6, 6)
                    for root in ('/tmp', '/data', '/conjet-meta-tmp'):
                        with self.subTest(mount=root):
                            # Linux 6.6 added tmpfs user xattrs. The probe
                            # verifies EOPNOTSUPP on set and get on older tmpfs,
                            # then still runs the link, lock and fsync checks.
                            expected = 20 if root == '/conjet-meta-tmp' and not tmpfs_has_user_xattrs else 0
                            self.assertEqual(
                                exec_command(self, session, path, ['/tmp/metadata-probe', root]),
                                (expected, b'', b''),
                            )
                            verify(path, root)
                    status, raw = session.request('POST', path + '/stop?t=1')
                    self.assertEqual(status, 204, raw)
                    start(path)
                    verify(path, '/data')
            finally:
                status, raw = session.request('DELETE', volume)
                self.assertIn(status, (204, 404), raw)
        session.record({'mounts': ['private-overlay', 'named-volume', 'tmpfs'],
                        'xattr_visible_via_hardlink': True, 'tmpfs_xattr_checked_for_kernel': True,
                        'independent_lock_contention': True,
                        'file_and_directory_fsync': True, 'named_volume_checksum_after_restart':
                        expected_hash.decode(), 'neutral_probe_sha256': checksum})

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
