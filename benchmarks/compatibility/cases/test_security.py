"""Security conformance fixtures and pending contracts."""

import base64
import hashlib
import json
from pathlib import Path
import subprocess
from tempfile import TemporaryDirectory
import unittest
import uuid

from support import API, alpine, container, demultiplex, exec_command


def compile_probe(test, connection, filename, checksum):
    clang = Path('/Applications/Xcode.app/Contents/Developer/Toolchains/'
                 'XcodeDefault.xctoolchain/usr/bin/clang')
    lld = (Path.home() / '.rustup/toolchains/stable-aarch64-apple-darwin'
           / 'lib/rustlib/aarch64-apple-darwin/bin/rust-lld')
    tools = (
        (clang, 'ee029330bf58ab6e481385f4237cc54602eaa8b81526242e5c5ab5b76e8c5a7e'),
        (lld, 'f719ec5b06dcf9ec5f8e4dc2a5032a72c6469ba4e195c17011090d10b4229c5c'),
    )
    for tool, expected in tools:
        with tool.open('rb') as source:
            test.assertEqual(hashlib.file_digest(source, 'sha256').hexdigest(), expected, tool)
    source = Path(__file__).resolve().parents[1] / 'fixtures' / filename
    with TemporaryDirectory(dir=connection.root) as scratch:
        root = Path(scratch)
        obj, executable = root / 'probe.o', root / 'probe'
        for command in (
                [clang, '--target=aarch64-linux-musl', '-c', source, '-o', obj],
                [lld, '-flavor', 'gnu', '-m', 'aarch64linux', '--build-id=none', '-static',
                 '-s', '-o', executable, obj]):
            compiled = subprocess.run(command, cwd=root, env={'HOME': scratch,
                                       'PATH': '/usr/bin:/bin'}, capture_output=True,
                                      text=True, timeout=10)
            test.assertEqual(compiled.returncode, 0, compiled.stderr)
        payload = executable.read_bytes()
        test.assertEqual(hashlib.sha256(payload).hexdigest(), checksum)
        return base64.b64encode(payload).decode()

class CompatibilityTests(unittest.TestCase):
    def test_cap_drop(self):
        'DC-019: Drop ALL; inspect capability sets and prove a capability-dependent operation fails.'
        session = self.compatibility
        prefix = 'conjet-capdrop-' + uuid.uuid4().hex
        capability_keys = {'CapInh:', 'CapPrm:', 'CapEff:', 'CapBnd:', 'CapAmb:'}

        def check(image, drop):
            host = {'NetworkMode': 'none'}
            if drop:
                host['CapDrop'] = ['ALL']
            name = prefix + ('-dropped' if drop else '-control')
            config = {'Image': image, 'Cmd': ['/bin/sleep', '120'], 'HostConfig': host}
            with container(self, session, name, config) as (path, _):
                self.assertEqual(session.request('POST', path + '/start')[0], 204)
                code, output, errors = exec_command(self, session, path, [
                    '/usr/bin/awk', '/^Cap(Inh|Prm|Eff|Bnd|Amb):/ {print $1, $2}', '/proc/self/status',
                ])
                self.assertEqual((code, errors), (0, b''))
                capabilities = {key: int(value, 16)
                                for key, value in (line.split() for line in output.decode().splitlines())}
                self.assertEqual(capabilities.keys(), capability_keys)
                code, output, errors = exec_command(self, session, path, [
                    '/bin/sh', '-c', 'touch /tmp/fixture-owner && chown 12345:12345 /tmp/fixture-owner',
                ])
                self.assertEqual(output, b'')
                if drop:
                    self.assertEqual(set(capabilities.values()), {0})
                    self.assertEqual(code, 1)
                    self.assertIn(b'Operation not permitted', errors)
                else:
                    self.assertTrue(capabilities['CapEff:'] & 1)
                    self.assertEqual((code, errors), (0, b''))
                outcome = exec_command(self, session, path,
                                       ['/bin/sh', '-c', 'stat -c %u:%g /tmp/fixture-owner'])
                self.assertEqual(outcome, (0, b'0:0\n' if drop else b'12345:12345\n', b''))

        with alpine(self, session) as image:
            check(image, False)
            check(image, True)
        session.record({'zero_capability_sets': sorted(capability_keys),
                        'chown_control': 'changed-owner', 'chown_dropped': 'denied'})

    def test_cap_add(self):
        'DC-020: Add NET_ADMIN in a private network namespace; permitted operation succeeds without unrelated capabilities.'
        session = self.compatibility
        name = 'conjet-net-admin-' + uuid.uuid4().hex[:16]
        address = b'192.0.2.21/32'
        cmd = ['/bin/busybox', 'ip', 'addr', 'add', address.decode(), 'dev', 'lo']
        show = ['/bin/busybox', 'ip', '-4', 'addr', 'show', 'dev', 'lo']
        capability_keys = {'CapInh:', 'CapPrm:', 'CapEff:', 'CapBnd:', 'CapAmb:'}

        def state(path):
            status, raw = session.request('GET', path + '/json')
            self.assertEqual(status, 200, raw)
            self.assertIs(json.loads(raw)['State']['Running'], True)
            return json.loads(raw)['HostConfig']

        def observe(path):
            code, output, errors = exec_command(self, session, path, [
                '/usr/bin/awk', '/^Cap(Inh|Prm|Eff|Bnd|Amb):/ {print $1, $2}',
                '/proc/1/status', '/proc/self/status',
            ])
            self.assertEqual((code, errors), (0, b''))
            lines = output.decode().splitlines()
            self.assertEqual(len(lines), 10)
            values = []
            for start in (0, 5):
                caps = {key: int(value, 16)
                        for key, value in (line.split() for line in lines[start:start + 5])}
                self.assertEqual(caps.keys(), capability_keys)
                values.append(caps)
            self.assertEqual(values[0], values[1])
            return values[0]

        with alpine(self, session) as image:
            settings = {'Image': image, 'Cmd': ['/bin/sleep', '120']}
            base = {'NetworkMode': 'none', 'CapDrop': ['ALL']}
            with container(self, session, name + '-only', {
                    **settings, 'HostConfig': {**base, 'CapAdd': ['NET_ADMIN']},
            }) as (positive, _), container(self, session, name + '-control', {
                    **settings, 'HostConfig': base,
            }) as (negative, _):
                for path in (positive, negative):
                    status, raw = session.request('POST', path + '/start')
                    self.assertEqual(status, 204, raw)
                host = state(positive)
                self.assertEqual([cap.removeprefix('CAP_') for cap in host['CapAdd']], ['NET_ADMIN'])
                self.assertEqual(observe(positive), {
                    'CapInh:': 0, 'CapPrm:': 1 << 12, 'CapEff:': 1 << 12,
                    'CapBnd:': 1 << 12, 'CapAmb:': 0,
                })
                self.assertEqual(set(observe(negative).values()), {0})
                self.assertEqual(exec_command(self, session, positive, cmd), (0, b'', b''))
                code, output, errors = exec_command(self, session, positive, show)
                self.assertEqual((code, errors), (0, b''))
                self.assertIn(address, output)
                code, output, errors = exec_command(self, session, negative, show)
                self.assertEqual((code, errors), (0, b''))
                self.assertNotIn(address, output)
                code, output, errors = exec_command(self, session, negative, cmd)
                self.assertNotEqual(code, 0)
                self.assertIn(b'Operation not permitted', errors)
                code, output, errors = exec_command(self, session, positive, [
                    '/bin/sh', '-c', 'touch /tmp/fixture-owner && chown 12345:12345 /tmp/fixture-owner',
                ])
                self.assertNotEqual(code, 0)
                self.assertIn(b'Operation not permitted', errors)
        session.record({'effective_capabilities': ['NET_ADMIN'], 'private_link_change': True,
                        'control_link_unchanged': True, 'unrelated_chown_denied': True})

    def test_read_only(self):
        'DC-021: Rootfs write fails while writable named volume succeeds.'
        session = self.compatibility
        name = 'conjet-readonly-' + uuid.uuid4().hex
        volume = API + '/volumes/' + name
        canary = b'writable-volume-canary'
        digest = hashlib.sha256(canary).hexdigest()
        with alpine(self, session) as image:
            try:
                status, body = session.request('POST', API + '/volumes/create', {'Name': name})
                self.assertEqual(status, 201, body)
                config = {'Image': image, 'Cmd': ['/bin/sleep', '120'],
                          'HostConfig': {'NetworkMode': 'none', 'ReadonlyRootfs': True,
                                         'Mounts': [{'Type': 'volume', 'Source': name, 'Target': '/data'}]}}
                with container(self, session, name, config) as (path, _):
                    status, body = session.request('POST', path + '/start')
                    self.assertEqual(status, 204, body)
                    status, body = session.request('GET', path + '/json')
                    self.assertEqual(status, 200, body)
                    self.assertIs(json.loads(body)['HostConfig']['ReadonlyRootfs'], True)
                    result = exec_command(self, session, path,
                                          ['/bin/sh', '-c', 'printf test >/tmp/owned-file'])
                    self.assertNotEqual(result[0], 0)
                    self.assertEqual(result[1], b'')
                    self.assertIn(b'Read-only file system', result[2])
                    result = exec_command(self, session, path, [
                        '/bin/sh', '-c',
                        'test ! -e /tmp/owned-file && printf %s "$1" >/data/proof && sha256sum /data/proof',
                        'conjet-fixture', canary.decode(),
                    ])
                    self.assertEqual(result, (0, digest.encode() + b'  /data/proof\n', b''))
            finally:
                status, body = session.request('DELETE', volume)
                self.assertIn(status, (204, 404), body)
        session.record({'root_write': 'EROFS', 'volume_checksum': digest})

    def test_no_new_privileges(self):
        'DC-022: Kernel NoNewPrivs is set and a controlled setuid elevation is denied.'
        session = self.compatibility
        connection = session.connection
        name = 'conjet-no-privs-' + uuid.uuid4().hex[:16]
        checksum = '83bc5382718ef77495eab41820adfc583c72aafe3e9e615951b98ada10e52b50'
        data = compile_probe(self, connection, 'dc022-euid.S', checksum)

        with alpine(self, session) as image, container(self, session, name, {
                'Image': image, 'Cmd': ['/bin/sleep', '120'],
                'HostConfig': {'NetworkMode': 'none', 'SecurityOpt': ['no-new-privileges:true']},
        }) as (path, _):
            status, raw = session.request('POST', path + '/start')
            self.assertEqual(status, 204, raw)
            setup = exec_command(self, session, path, ['/bin/sh', '-c',
                'printf %s "$1" | base64 -d >/tmp/suid-probe && '
                'cp /tmp/suid-probe /tmp/plain-probe && '
                'chmod 4755 /tmp/suid-probe && chmod 755 /tmp/plain-probe',
                'fixture', data])
            self.assertEqual(setup, (0, b'', b''))
            flags = exec_command(self, session, path, [
                '/usr/bin/awk', '/^NoNewPrivs:/{print $2}', '/proc/1/status',
            ])
            self.assertEqual(flags, (0, b'1\n', b''))
            stats = exec_command(self, session, path, [
                '/bin/busybox', 'stat', '-c', '%u:%g:%a', '/tmp/suid-probe', '/tmp/plain-probe',
            ])
            self.assertEqual(stats, (0, b'0:0:4755\n0:0:755\n', b''))
            probes = exec_command(self, session, path, ['/bin/busybox', 'su', '-s', '/bin/sh', '-c',
                r'id -u && awk "/^NoNewPrivs:/{print \$2}" /proc/self/status && '
                '/tmp/plain-probe && /tmp/suid-probe', 'nobody',
            ])
            self.assertEqual(probes, (0, b'65534\n1\n', b''))
        session.record({'no_new_privileges': True, 'setid_file_mode': '4755',
                        'effective_uid_preserved': 65534, 'neutral_probe_sha256': checksum})

    def test_seccomp(self):
        'DC-023: Configured syscall allow and deny behavior matches policy; unsupported profiles fail before start.'
        session = self.compatibility
        name = 'conjet-seccomp-' + uuid.uuid4().hex[:16]
        supported = {
            'defaultAction': 'SCMP_ACT_ALLOW', 'architectures': ['SCMP_ARCH_AARCH64'],
            'syscalls': [{'names': ['uname'], 'action': 'SCMP_ACT_ERRNO', 'errnoRet': 1}],
        }

        def profile(data):
            return 'seccomp=' + json.dumps(data, separators=(',', ':'))

        def start(path):
            status, raw = session.request('POST', path + '/start')
            self.assertEqual(status, 204, raw)

        data = compile_probe(self, session.connection, 'dc023-uname.S',
                             '7036343e64dc599d09c0a0b9152e2773d9f4992ed193a3c1d5fdc9f355def097')
        fragments = [data[index:index + 480] for index in range(0, len(data), 480)]
        install = 'printf %s "$@" | base64 -d >/tmp/syscall-probe && chmod 755 /tmp/syscall-probe'
        expected_stdout = b'allowed\n'
        with alpine(self, session) as image:
            for label, options, expected in (('control', [], 0), ('restricted', [profile(supported)], 40)):
                host = {'NetworkMode': 'none', 'SecurityOpt': options}
                with container(self, session, f'{name}-{label}', {
                        'Image': image, 'HostConfig': host,
                        'Cmd': ['/bin/sh', '-c', install + ' && printf "allowed\n" && exec /tmp/syscall-probe',
                                'fixture', *fragments],
                }) as (path, _):
                    start(path)
                    status, raw = session.request('POST', path + '/wait?condition=not-running')
                    self.assertEqual(status, 200, raw)
                    self.assertEqual(json.loads(raw)['StatusCode'], expected)
                    status, raw = session.request('GET', path + '/logs?stdout=true&stderr=true')
                    self.assertEqual(status, 200, raw)
                    self.assertEqual(demultiplex(self, raw), (expected_stdout, b''))

                with container(self, session, f'{name}-{label}-exec', {
                        'Image': image, 'HostConfig': host, 'Cmd': ['/bin/sleep', '120'],
                }) as (path, _):
                    start(path)
                    self.assertEqual(exec_command(self, session, path,
                                                  ['/bin/sh', '-c', install, 'fixture', *fragments]),
                                     (0, b'', b''))
                    self.assertEqual(exec_command(self, session, path, ['/tmp/syscall-probe']),
                                     (expected, b'', b''))

            invalid_name = name + '-invalid'
            path = API + '/containers/' + invalid_name
            marker = b'invalid-profile-executed'
            try:
                invalid = {**supported, 'defaultAction': 'SCMP_ACT_UNKNOWN_FIXTURE'}
                config = {'Image': image, 'Cmd': ['/bin/echo', marker.decode()],
                          'HostConfig': {'NetworkMode': 'none', 'SecurityOpt': [profile(invalid)]}}
                status, raw = session.request('POST', API + '/containers/create?name=' + invalid_name, config)
                self.assertIn(status, (201, 400, 500), raw)
                if status == 201:
                    status, raw = session.request('POST', path + '/start')
                    self.assertIn(status, (400, 500), raw)
                    self.assertRegex(json.loads(raw)['message'].lower(), r'seccomp|action')
                    status, observed = session.request('GET', path + '/logs?stdout=true')
                    self.assertIn(status, (200, 404), observed)
                    self.assertNotIn(marker, observed)
                else:
                    self.assertRegex(json.loads(raw)['message'].lower(), r'seccomp|action')
                    self.assertEqual(session.request('GET', path + '/json')[0], 404)
            finally:
                status, raw = session.request('DELETE', path + '?force=true')
                self.assertIn(status, (204, 404), raw)
        session.record({'allowed_operation': 'echo', 'denied_syscall': 'uname',
                        'errno': 'EPERM', 'invalid_profile_blocked_before_exec': True})

    def test_namespace_sharing(self):
        'DC-024: Verify private, host and container PID and IPC modes against guest identities without contaminating supervisor namespaces.'
        self.fail('UNIMPLEMENTED DC-024; no runtime compatibility evidence')

    def test_privileged_devices(self):
        'DC-025: Verify supported privileged and device access remains within VM boundary; unsupported requests fail explicitly.'
        self.fail('UNIMPLEMENTED DC-025; no runtime compatibility evidence')
