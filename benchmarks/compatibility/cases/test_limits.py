"""Resource-limit conformance fixtures and pending contracts."""

import json
import time
import unittest
import uuid

from support import API, alpine, container, exec_command


class CompatibilityTests(unittest.TestCase):
    def test_cpu_quota(self):
        'DC-026: Quota is applied and sustained load shows throttling; removing quota preserves other limits.'
        session = self.compatibility
        period, quota = 80_000, 8_000
        memory, pids = 32 * 1024 * 1024, 16
        limits = {'CpuPeriod': period, 'CpuQuota': quota, 'Memory': memory, 'PidsLimit': pids}

        def usage(path):
            status, raw = session.request('GET', path + '/stats?stream=false&one-shot=true')
            self.assertEqual(status, 200, raw)
            stats = json.loads(raw)
            self.assertEqual(stats['memory_stats']['limit'], memory)
            return (stats['cpu_stats']['throttling_data'],
                    stats['cpu_stats']['cpu_usage']['total_usage'])

        def inspect_host_config(path, expected):
            status, raw = session.request('GET', path + '/json')
            self.assertEqual(status, 200, raw)
            inspected = json.loads(raw)
            self.assertIs(inspected['State']['Running'], True)
            self.assertEqual({field: inspected['HostConfig'][field] for field in expected}, expected)

        with alpine(self, session) as image, container(self, session, 'conjet-quota-' + uuid.uuid4().hex, {
                'Image': image, 'Cmd': ['/bin/sh', '-c', 'while :; do :; done'],
                'HostConfig': {'NetworkMode': 'none', **limits},
        }) as (path, _):
            status, raw = session.request('POST', path + '/start')
            self.assertEqual(status, 204, raw)
            inspect_host_config(path, limits)
            initial, _ = usage(path)
            deadline = time.monotonic() + 3
            while True:
                throttled, _ = usage(path)
                if throttled['throttled_periods'] - initial['throttled_periods'] >= 4:
                    break
                self.assertLess(time.monotonic(), deadline, throttled)
                time.sleep(0.15)
            self.assertGreater(throttled['throttled_time'], initial['throttled_time'])
            status, raw = session.request('POST', path + '/update', {'CpuQuota': -1})
            self.assertEqual(status, 200, raw)
            inspect_host_config(path, {**limits, 'CpuQuota': -1})
            released, released_cpu = usage(path)
            time.sleep(1)
            loaded, loaded_cpu = usage(path)
            self.assertGreater(loaded_cpu - released_cpu, 100_000_000)
            self.assertEqual(loaded['throttled_periods'], released['throttled_periods'])
            self.assertEqual(loaded['throttled_time'], released['throttled_time'])
        session.record({'period_us': period, 'quota_us': quota, 'sustained_throttling': True,
                        'quota_removed_under_load': True, 'memory_and_pids_preserved': True})

    def test_cpu_affinity(self):
        'DC-027: Requested available CPUs constrain execution; invalid CPU sets are rejected atomically.'
        session = self.compatibility
        name = 'conjet-affinity-' + uuid.uuid4().hex
        memory, pids = 32 * 1024 * 1024, 16
        status, raw = session.request('GET', API + '/info')
        self.assertEqual(status, 200, raw)
        cpus = json.loads(raw)['NCPU']
        self.assertGreaterEqual(cpus, 2)
        unavailable = f'1,{cpus}'

        def verify(path, expected):
            status, raw = session.request('GET', path + '/json')
            self.assertEqual(status, 200, raw)
            inspected = json.loads(raw)
            self.assertIs(inspected['State']['Running'], True)
            host = inspected['HostConfig']
            self.assertEqual((host['CpusetCpus'], host['Memory'], host['PidsLimit']),
                             (expected, memory, pids))
            code, output, error = exec_command(self, session, path, [
                '/usr/bin/awk', '/^Cpus_allowed_list:/{print $2}',
                '/proc/1/status', '/proc/self/status',
            ])
            self.assertEqual((code, output, error),
                             (0, (expected + '\n' + expected + '\n').encode(), b''))

        with alpine(self, session) as image:
            config = {'Image': image, 'Cmd': ['/bin/sleep', '120'],
                      'HostConfig': {'NetworkMode': 'none', 'Memory': memory, 'PidsLimit': pids,
                                     'CpusetCpus': '1'}}
            invalid = {**config, 'HostConfig': {**config['HostConfig'], 'CpusetCpus': unavailable}}
            try:
                status, raw = session.request('POST', API + '/containers/create?name=' + name + '-invalid',
                                              invalid)
                self.assertIn(status, (400, 500), raw)
                self.assertIsInstance(json.loads(raw)['message'], str)
                self.assertEqual(session.request('GET', API + '/containers/' + name + '-invalid/json')[0],
                                 404)
            finally:
                status, raw = session.request('DELETE', API + '/containers/' + name + '-invalid?force=1')
                self.assertIn(status, (204, 404), raw)

            with container(self, session, name, config) as (path, _):
                status, raw = session.request('POST', path + '/start')
                self.assertEqual(status, 204, raw)
                verify(path, '1')
                status, raw = session.request('POST', path + '/update',
                                              {'CpusetCpus': unavailable, 'PidsLimit': 20})
                self.assertIn(status, (400, 500), raw)
                self.assertIsInstance(json.loads(raw)['message'], str)
                verify(path, '1')
                status, raw = session.request('POST', path + '/update', {'CpusetCpus': '0'})
                self.assertEqual(status, 200, raw)
                verify(path, '0')
        session.record({'process_and_exec_cpu': 1, 'invalid_create_rejected': True,
                        'invalid_update_preserved_cgroup': True, 'updated_process_and_exec_cpu': 0})

    def test_memory_oom(self):
        'DC-028: Hard limit triggers expected OOM state while sibling workload remains healthy.'
        session = self.compatibility
        token = 'conjet-limit-' + uuid.uuid4().hex
        memory = 16 * 1024 * 1024
        allocation = (
            'BEGIN {part="a"; for (i=0;i<20;i++) part=part part; '
            'for (i=0;i<64;i++) blocks[i]=sprintf("%03d%s",i,part); '
            'print length(blocks[63])}'
        )

        def start(path):
            status, body = session.request('POST', path + '/start')
            self.assertEqual(status, 204, body)

        def sibling_alive(path):
            status, body = session.request('GET', path + '/json')
            self.assertEqual(status, 200, body)
            self.assertIs(json.loads(body)['State']['Running'], True)
            result = exec_command(self, session, path, ['/bin/echo', 'sibling-alive'])
            self.assertEqual(result, (0, b'sibling-alive\n', b''))

        with alpine(self, session) as image, container(self, session, token + '-control', {
                'Image': image, 'Cmd': ['/bin/sleep', '120'], 'HostConfig': {'NetworkMode': 'none'},
        }) as (sibling, sibling_id):
            start(sibling)
            sibling_alive(sibling)
            with container(self, session, token + '-bounded', {
                    'Image': image, 'Cmd': ['/bin/sh', '-c',
                        'awk "$1"; result=$?; sleep 0.5; exit "$result"', 'fixture', allocation],
                    'HostConfig': {'NetworkMode': 'none', 'Memory': memory, 'MemorySwap': memory},
            }) as (limited, limited_id):
                self.assertNotEqual(limited_id, sibling_id)
                start(limited)
                status, raw = session.request('POST', limited + '/wait?condition=not-running')
                self.assertEqual(status, 200, raw)
                self.assertEqual(json.loads(raw)['StatusCode'], 137)
                deadline = time.monotonic() + 3
                while True:
                    status, raw = session.request('GET', limited + '/json')
                    self.assertEqual(status, 200, raw)
                    inspected = json.loads(raw)
                    # Docker's OOM monitor may notify after the task exit.
                    if inspected['State']['OOMKilled'] is True or time.monotonic() >= deadline:
                        break
                    time.sleep(0.03)
                self.assertEqual(inspected['Id'], limited_id)
                self.assertEqual(inspected['HostConfig']['Memory'], memory)
                self.assertIs(inspected['State']['OOMKilled'], True)
                self.assertIs(inspected['State']['Running'], False)
                self.assertEqual(inspected['State']['ExitCode'], 137)
            sibling_alive(sibling)
        session.record({'memory_bytes': memory, 'oom_killed': True, 'exit': 137,
                        'sibling_healthy_before_and_after': True})

    def test_reservation_swap(self):
        'DC-029: Reservation and memory-plus-swap combinations match reference cgroup behavior; unsupported settings are explicit.'
        self.fail('UNIMPLEMENTED DC-029; no runtime compatibility evidence')

    def test_pids_ulimits(self):
        'DC-030: Fork and file-open fixtures hit configured PID and descriptor limits without exhausting guest.'
        self.fail('UNIMPLEMENTED DC-030; no runtime compatibility evidence')

    def test_transactional_update(self):
        'DC-031: Invalid multi-field update leaves all previously effective limits unchanged.'
        session = self.compatibility
        name = 'conjet-update-' + uuid.uuid4().hex
        limits = {'Memory': 32 * 1024 * 1024, 'PidsLimit': 16, 'NanoCpus': 250_000_000}
        increased = 48 * 1024 * 1024

        def assert_limits(path, wanted):
            status, raw = session.request('GET', path + '/json')
            self.assertEqual(status, 200, raw)
            actual = json.loads(raw)
            self.assertIs(actual['State']['Running'], True)
            self.assertEqual({field: actual['HostConfig'][field] for field in wanted}, wanted)
            status, raw = session.request('GET', path + '/stats?stream=false&one-shot=true')
            self.assertEqual(status, 200, raw)
            self.assertEqual(json.loads(raw)['memory_stats']['limit'], wanted['Memory'])

        with alpine(self, session) as image, container(self, session, name, {
                'Image': image, 'Cmd': ['/bin/sleep', '120'],
                'HostConfig': {'NetworkMode': 'none', **limits},
        }) as (path, _):
            status, raw = session.request('POST', path + '/start')
            self.assertEqual(status, 204, raw)
            assert_limits(path, limits)
            status, raw = session.request('POST', path + '/update', {
                'Memory': increased, 'PidsLimit': 20, 'CpuPeriod': 100,
            })
            self.assertIn(status, (400, 500), raw)
            self.assertIsInstance(json.loads(raw)['message'], str)
            assert_limits(path, limits)
            status, raw = session.request('POST', path + '/update', {'Memory': increased})
            self.assertEqual(status, 200, raw)
            assert_limits(path, {**limits, 'Memory': increased})
        session.record({'invalid_update_rejected': True, 'old_limits_preserved': True,
                        'valid_update_memory': increased, 'unrelated_limits_retained': True})
