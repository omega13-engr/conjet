"""Unimplemented conformance contracts; replace each failure with its real fixture."""
import io
import json
import tarfile
import unittest
from urllib.parse import urlencode
import uuid

import image_archives
from support import API, alpine, container, demultiplex, exec_command


class CompatibilityTests(unittest.TestCase):
    def test_amd64(self):
        'DC-085: Foreign-platform pull, build and execution use emulation correctly or fail explicitly before execution.'
        session = self.compatibility
        short = 'conjet-foreign-' + uuid.uuid4().hex[:12]
        image_name = 'docker.io/library/alpine'
        digest = 'sha256:4d889c14e7d5a73929ab00be2ef8ff22437e7cbc545931e52554a7b00e123d8b'
        config = 'sha256:3cb067eab609612d81b4d82ff8ad71d73482bb3059a87b642d7e14f0ed659cde'
        reference = image_name + '@' + digest
        tagged = short + ':local'
        marker = b'neutral-foreign-architecture'
        platform = 'linux/amd64'

        def refused(raw):
            detail = raw.decode(errors='replace').lower()
            self.assertRegex(detail, r'exec format error|no matching manifest|does not match the specified platform'
                                      r'|only (?:the )?linux arm64|unsupported.*(?:platform|architecture)'
                                      r'|(?:platform|architecture).*unsupported')

        def output_has_error(raw):
            rows = [json.loads(line) for line in raw.splitlines() if line.strip()]
            self.assertTrue(rows, raw)
            return any(row.get('error') or row.get('errorDetail') for row in rows)

        def run_foreign(image, expected_available):
            alias = short + ('-built' if image == tagged else '-pulled')
            target = API + '/containers/' + alias
            route = API + '/containers/create?' + urlencode({'name': alias, 'platform': platform})
            try:
                status, raw = session.request('POST', route, {
                    'Image': image, 'Cmd': ['/bin/sh', '-c', 'printf "%s\n" "$1"; uname -m',
                                            'fixture', marker.decode()],
                    'HostConfig': {'NetworkMode': 'none'},
                })
                if status != 201:
                    refused(raw)
                    self.assertEqual(session.request('GET', target + '/json')[0], 404)
                    return
                self.assertTrue(expected_available)
                status, raw = session.request('POST', target + '/start')
                if status != 204:
                    refused(raw)
                    status, detail = session.request('GET', target + '/json')
                    self.assertEqual(status, 200, detail)
                    self.assertIs(json.loads(detail)['State']['Running'], False)
                    code, output = session.request('GET', target + '/logs?stdout=true&stderr=true')
                    self.assertIn(code, (200, 404), output)
                    self.assertNotIn(marker, output)
                    return
                status, raw = session.request('POST', target + '/wait?condition=not-running')
                self.assertEqual(status, 200, raw)
                exit_code = json.loads(raw)['StatusCode']
                status, raw = session.request('GET', target + '/logs?stdout=true&stderr=true')
                self.assertEqual(status, 200, raw)
                stdout, stderr = demultiplex(self, raw)
                if exit_code == 0:
                    self.assertEqual((stdout, stderr), (marker + b'\nx86_64\n', b''))
                else:
                    # Some daemon versions acknowledge Start after the OCI
                    # shim starts, then report the kernel exec failure via logs.
                    status, raw = session.request('GET', target + '/json')
                    self.assertEqual(status, 200, raw)
                    state = json.loads(raw)['State']
                    self.assertIs(state['Running'], False)
                    self.assertEqual(state['ExitCode'], exit_code)
                    self.assertNotIn(marker, stdout + stderr)
                    refused(stderr + state.get('Error', '').encode())
            finally:
                status, raw = session.request('DELETE', target + '?force=true')
                self.assertIn(status, (204, 404), raw)

        original, _ = session.request('GET', image_archives.image_path(reference) + '/json')
        self.assertIn(original, (200, 404))
        try:
            query = {'fromImage': image_name, 'tag': digest, 'platform': platform}
            pull = type(session)(session.connection.peer(timeout=80))
            status, raw = pull.request('POST', API + '/images/create?' + urlencode(query))
            available = status == 200 and not output_has_error(raw)
            if available:
                details = image_archives.inspect(self, session, reference)
                self.assertEqual((details['Os'], details['Architecture']), ('linux', 'amd64'))
                self.assertIn(details['Id'], (digest, config))
                self.assertTrue(any(ref.endswith('@' + digest) for ref in details['RepoDigests']))
            else:
                refused(raw)
                self.assertEqual(session.request('GET', image_archives.image_path(reference) + '/json')[0],
                                 404)
            run_foreign(reference, available)

            context = io.BytesIO()
            with tarfile.open(fileobj=context, mode='w', format=tarfile.USTAR_FORMAT) as tar:
                dockerfile = (f'FROM {reference}\n'
                              'RUN test "$(uname -m)" = x86_64 && echo verified-foreign-build\n').encode()
                entry = tarfile.TarInfo('Dockerfile')
                entry.mode, entry.size = 0o644, len(dockerfile)
                tar.addfile(entry, io.BytesIO(dockerfile))
            query = {'t': tagged, 'platform': platform, 'version': '1',
                     'networkmode': 'none', 'rm': '1', 'forcerm': '1', 'nocache': '1'}
            status, raw = image_archives.transfer(self, session, 'POST',
                API + '/build?' + urlencode(query), context.getvalue())
            built = status == 200 and not output_has_error(raw)
            if built:
                self.assertIn(b'verified-foreign-build', raw)
                details = image_archives.inspect(self, session, tagged)
                self.assertEqual((details['Os'], details['Architecture']), ('linux', 'amd64'))
                run_foreign(tagged, True)
            else:
                refused(raw)
                self.assertEqual(session.request('GET', image_archives.image_path(tagged) + '/json')[0],
                                 404)
        finally:
            image_archives.clean(self, session, tagged)
            if original == 404:
                status, raw = session.request('DELETE', image_archives.image_path(reference))
                self.assertIn(status, (200, 404), raw)
        session.record({'requested_platform': platform, 'pinned_foreign_manifest': digest,
                        'foreign_pull_identity_or_explicit_refusal': True,
                        'foreign_execution_or_explicit_refusal': True,
                        'foreign_build_or_explicit_refusal': True})

    def test_plugins(self):
        'DC-086: Each advertised volume, network and logging plugin contract passes lifecycle and failure tests.'
        self.fail('UNIMPLEMENTED DC-086; no runtime compatibility evidence')

    def test_gpu_cdi(self):
        'DC-087: Advertised GPU or CDI devices perform a real workload; unavailable hardware is not reported as supported.'
        session = self.compatibility
        name = 'conjet-accelerator-' + uuid.uuid4().hex[:16]
        marker = b'neutral-device-workload'
        status, raw = session.request('GET', API + '/info')
        self.assertEqual(status, 200, raw)
        info = json.loads(raw)
        runtime_names = {key.lower() for key in (info.get('Runtimes') or {})}
        self.assertTrue(runtime_names.isdisjoint({'nvidia', 'rocm'}), runtime_names)
        self.assertFalse(info.get('GPUDevices') or info.get('Accelerators'), info.keys())

        with alpine(self, session) as image:
            command = ['/bin/echo', marker.decode()]
            for kind, request in (
                    ('gpu', {'Driver': 'nvidia', 'Count': 1, 'Capabilities': [['gpu']]}),
                    ('cdi', {'Driver': 'cdi', 'DeviceIDs': [f'fixture.example/gpu={name}']})):
                alias = f'{name}-{kind}'
                base = API + '/containers/' + alias
                try:
                    status, raw = session.request('POST', API + '/containers/create?name=' + alias, {
                        'Image': image, 'Cmd': command, 'HostConfig': {
                            'NetworkMode': 'none', 'DeviceRequests': [request],
                        },
                    })
                    self.assertIn(status, (201, 400, 403, 500, 501), raw)
                    if status == 201:
                        status, raw = session.request('POST', base + '/start')
                        self.assertIn(status, (400, 403, 500, 501), raw)
                        detail = json.loads(raw)['message'].lower()
                        status, raw = session.request('GET', base + '/json')
                        self.assertEqual(status, 200, raw)
                        state = json.loads(raw)['State']
                        self.assertIs(state['Running'], False)
                        self.assertTrue(state['StartedAt'].startswith('0001-01-01'))
                        status, raw = session.request('GET', base + '/logs?stdout=true&stderr=true')
                        self.assertIn(status, (200, 404), raw)
                        self.assertNotIn(marker, raw)
                    else:
                        detail = json.loads(raw)['message'].lower()
                        self.assertEqual(session.request('GET', base + '/json')[0], 404)
                    self.assertRegex(detail, r'device|nvidia|cdi')
                    self.assertRegex(detail, r'unsupported|not supported|could not select|unresolv|not found')
                finally:
                    status, raw = session.request('DELETE', base + '?force=true')
                    self.assertIn(status, (204, 404), raw)

            with container(self, session, name + '-cpu', {
                    'Image': image, 'Cmd': ['/bin/sleep', '120'],
                    'HostConfig': {'NetworkMode': 'none'},
            }) as (path, _):
                status, raw = session.request('POST', path + '/start')
                self.assertEqual(status, 204, raw)
                self.assertEqual(exec_command(self, session, path, command), (0, marker + b'\n', b''))
        session.record({'accelerators_advertised': False, 'missing_gpu_refused_before_start': True,
                        'missing_cdi_device_refused_before_start': True, 'cpu_control': marker.decode()})

    def test_rootless_checkpoint(self):
        'DC-088: Rootless and checkpoint restore require separate declared capability fixtures; unsupported modes remain explicit.'
        self.fail('UNIMPLEMENTED DC-088; no runtime compatibility evidence')
