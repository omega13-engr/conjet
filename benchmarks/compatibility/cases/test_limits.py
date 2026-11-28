"""Resource-limit conformance fixtures and pending contracts."""

import json
import time
import unittest
import uuid

from support import API, alpine, container, demultiplex, exec_command


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
        session = self.compatibility
        name = 'conjet-memory-policy-' + uuid.uuid4().hex[:16]
        mib = 1024 * 1024
        memory, reservation = 48 * mib, 16 * mib
        initial = {'Memory': memory, 'MemoryReservation': reservation}

        def measure(path, wanted, controls):
            status, raw = session.request('GET', path + '/json')
            self.assertEqual(status, 200, raw)
            inspected = json.loads(raw)
            self.assertIs(inspected['State']['Running'], True)
            host = inspected['HostConfig']
            self.assertEqual({key: host.get(key, 0) for key in wanted}, wanted)
            code, stdout, stderr = exec_command(self, session, path, [
                '/bin/cat', '/sys/fs/cgroup/memory.max', '/sys/fs/cgroup/memory.low',
                '/sys/fs/cgroup/memory.swap.max',
            ])
            self.assertEqual((code, stderr), (0, b''))
            actual = stdout.decode().splitlines()
            self.assertEqual(actual, [str(value) for value in controls])
            return actual

        policies = {}
        with alpine(self, session) as image:
            for suffix, swap, expected_swap, cgroup_swap in (
                    ('default', None, 2 * memory, memory), ('disabled', memory, memory, 0),
                    ('finite', 80 * mib, 80 * mib, 32 * mib), ('unlimited', -1, -1, 'max')):
                settings = initial if swap is None else {**initial, 'MemorySwap': swap}
                with container(self, session, f'{name}-{suffix}', {
                        'Image': image, 'Cmd': ['/bin/sleep', '120'],
                        'HostConfig': {'NetworkMode': 'none', **settings},
                }) as (path, _):
                    status, raw = session.request('POST', path + '/start')
                    self.assertEqual(status, 204, raw)
                    policies[suffix] = measure(path, {**initial, 'MemorySwap': expected_swap},
                                               (memory, reservation, cgroup_swap))
                    if suffix == 'finite':
                        patch = {'MemoryReservation': 24 * mib, 'MemorySwap': 96 * mib}
                        status, raw = session.request('POST', path + '/update', patch)
                        self.assertEqual(status, 200, raw)
                        policies['updated'] = measure(path, {**initial, **patch},
                                                      (memory, 24 * mib, 48 * mib))
            with container(self, session, name + '-reservation-only', {
                    'Image': image, 'Cmd': ['/bin/sleep', '120'],
                    'HostConfig': {'NetworkMode': 'none', 'MemoryReservation': reservation},
            }) as (path, _):
                status, raw = session.request('POST', path + '/start')
                self.assertEqual(status, 204, raw)
                policies['reservation_only'] = measure(path, {'Memory': 0, 'MemorySwap': 0,
                                                        'MemoryReservation': reservation},
                                                      ('max', reservation, 'max'))

            for suffix, invalid in (('swap-below-memory', {**initial, 'MemorySwap': 32 * mib}),
                                    ('reservation-above-memory', {**initial, 'MemoryReservation': 64 * mib}),
                                    ('swap-without-memory', {'MemorySwap': 80 * mib})):
                invalid_name = f'{name}-{suffix}'
                path = API + '/containers/' + invalid_name
                try:
                    status, raw = session.request('POST', API + '/containers/create?name=' + invalid_name,
                                                  {'Image': image, 'HostConfig': {'NetworkMode': 'none', **invalid}})
                    self.assertIn(status, (400, 500), raw)
                    self.assertIsInstance(json.loads(raw)['message'], str)
                    self.assertEqual(session.request('GET', path + '/json')[0], 404)
                finally:
                    status, raw = session.request('DELETE', path + '?force=true')
                    self.assertIn(status, (204, 404), raw)
            path = API + '/containers/' + name + '-swappiness'
            try:
                status, raw = session.request('POST', API + '/containers/create?name='
                                              + name + '-swappiness', {
                    'Image': image, 'Cmd': ['/bin/sleep', '120'],
                    'HostConfig': {'NetworkMode': 'none', **initial, 'MemorySwappiness': 10},
                })
                self.assertIn(status, (201, 400, 500), raw)
                result = json.loads(raw)
                if status == 201:
                    self.assertTrue(any('swappiness' in message.lower()
                                        and 'support' in message.lower()
                                        for message in result['Warnings']), result)
                    status, raw = session.request('GET', path + '/json')
                    self.assertEqual(status, 200, raw)
                    self.assertIsNone(json.loads(raw)['HostConfig']['MemorySwappiness'])
                else:
                    self.assertIn('swappiness', result['message'].lower())
                    self.assertIn('unsupport', result['message'].lower())
                    self.assertEqual(session.request('GET', path + '/json')[0], 404)
            finally:
                status, raw = session.request('DELETE', path + '?force=true')
                self.assertIn(status, (204, 404), raw)
        session.record({'cgroup_memory_low_and_swap': policies,
                        'invalid_combinations_rejected': True,
                        'unavailable_swappiness_reported': True})

    def test_pids_ulimits(self):
        'DC-030: Fork and file-open fixtures hit configured PID and descriptor limits without exhausting guest.'
        session = self.compatibility
        name = 'conjet-ulimits-' + uuid.uuid4().hex
        pids, soft, hard = 8, 32, 48
        run = r'''
            i=0
            while [ "$i" -lt 12 ]; do
                sleep 30 &
                i=$((i+1))
                printf 'child %s\n' "$i"
            done
            wait
        '''
        descriptor_probe = r'''
            ulimit -Sn; ulimit -Hn
            i=0
            while [ "$i" -lt 64 ]; do
                printf '%s\n' "$i" > "/tmp/conjet-fd-$i" || exit 2
                i=$((i+1))
            done
            exec awk 'BEGIN {
                for (i=0; i<64; i++) {
                    path="/tmp/conjet-fd-" i;
                    if ((getline value < path) != 1) {print "opened", i; exit 0}
                    if (value != i) exit 2;
                }
                exit 3;
            }'
        '''

        with alpine(self, session) as image, container(self, session, name, {
                'Image': image, 'Cmd': ['/bin/sleep', '120'],
                'HostConfig': {'NetworkMode': 'none', 'PidsLimit': pids,
                               'Ulimits': [{'Name': 'nofile', 'Soft': soft, 'Hard': hard}]},
        }) as (path, _):
            status, raw = session.request('POST', path + '/start')
            self.assertEqual(status, 204, raw)
            status, raw = session.request('GET', path + '/json')
            self.assertEqual(status, 200, raw)
            config = json.loads(raw)['HostConfig']
            self.assertEqual(config['PidsLimit'], pids)
            self.assertIn({'Name': 'nofile', 'Soft': soft, 'Hard': hard}, config['Ulimits'])
            code, output, error = exec_command(self, session, path, [
                '/usr/bin/awk', '/^Max open files/{print $4, $5}', '/proc/1/limits',
            ])
            self.assertEqual((code, output, error), (0, f'{soft} {hard}\n'.encode(), b''))
            code, output, error = exec_command(self, session, path, ['/bin/sh', '-c', descriptor_probe])
            self.assertEqual((code, output, error), (0, f'{soft}\n{hard}\nopened {soft - 3}\n'.encode(), b''))

            with container(self, session, name + '-fork', {
                    'Image': image, 'Cmd': ['/bin/sh', '-c', run],
                    'HostConfig': {'NetworkMode': 'none', 'PidsLimit': pids},
            }) as (fork_path, _):
                status, raw = session.request('POST', fork_path + '/start')
                self.assertEqual(status, 204, raw)
                status, raw = session.request('POST', fork_path + '/wait?condition=not-running')
                self.assertEqual(status, 200, raw)
                self.assertNotEqual(json.loads(raw)['StatusCode'], 0)
                status, raw = session.request('GET', fork_path + '/logs?stdout=true&stderr=true')
                self.assertEqual(status, 200, raw)
                output, error = demultiplex(self, raw)
                self.assertEqual(output.splitlines(), [f'child {i}'.encode() for i in range(1, pids)])
                self.assertIn(b'Resource temporarily unavailable', error)
            code, output, error = exec_command(self, session, path, ['/bin/echo', 'healthy'])
            self.assertEqual((code, output, error), (0, b'healthy\n', b''))
        session.record({'pid_ceiling': pids, 'fork_denied_at_ceiling': True,
                        'nofile_soft': soft, 'nofile_hard': hard, 'file_open_denied': True})

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
