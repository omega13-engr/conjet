"""Unimplemented conformance contracts; replace each failure with its real fixture."""
import json
import unittest
import uuid

from support import API, alpine, container, exec_command


class CompatibilityTests(unittest.TestCase):
    def test_amd64(self):
        'DC-085: Foreign-platform pull, build and execution use emulation correctly or fail explicitly before execution.'
        self.fail('UNIMPLEMENTED DC-085; no runtime compatibility evidence')

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
