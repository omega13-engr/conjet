"""Lifecycle conformance fixtures and pending contracts."""
from concurrent.futures import ThreadPoolExecutor
from contextlib import ExitStack
import hashlib
import json
from threading import Barrier
import time
import unittest
from urllib.parse import quote, urlencode
import uuid

from support import API, alpine, container, exec_command


class CompatibilityTests(unittest.TestCase):
    def test_durable_container(self):
        'DC-007: Write a checksum to a container layer; restart engine; start same container and verify bytes and metadata.'
        session = self.compatibility
        token = uuid.uuid4().hex
        name = 'conjet-durable-container-' + token
        label = {'dev.conjet.fixture': 'durable-container'}
        content = b'container-rootfs-canary\n'
        checksum = hashlib.sha256(content).hexdigest().encode()

        def start(path):
            status, raw = session.request('POST', path + '/start')
            self.assertEqual(status, 204, raw)

        with alpine(self, session) as image, container(self, session, name, {
                'Image': image, 'Cmd': ['/bin/sleep', '120'], 'Labels': label,
                'HostConfig': {'NetworkMode': 'none'},
        }) as (path, identifier):
            start(path)
            result = exec_command(self, session, path, ['/bin/sh', '-c',
                                  "printf '%s\\n' container-rootfs-canary >/tmp/canary; sync"])
            self.assertEqual(result, (0, b'', b''))
            status, raw = session.request('POST', path + '/stop?t=1')
            self.assertEqual(status, 204, raw)
            session.restart_engine()
            status, raw = session.request('GET', path + '/json')
            self.assertEqual(status, 200, raw)
            inspect = json.loads(raw)
            self.assertEqual(inspect['Id'], identifier)
            self.assertEqual(inspect['Name'], '/' + name)
            self.assertEqual(inspect['Config']['Labels'], label)
            self.assertIs(inspect['State']['Running'], False)
            start(path)
            result = exec_command(self, session, path, ['/bin/sh', '-c', 'sha256sum /tmp/canary'])
            self.assertEqual(result, (0, checksum + b'  /tmp/canary\n', b''))
        session.record({'layer_sha256': checksum.decode(), 'same_container': True, 'labels': label})

    def test_durable_tags(self):
        'DC-008: Local image aliases resolve to the same image after engine restart.'
        session = self.compatibility
        repository = 'conjet-durable-tags-' + uuid.uuid4().hex
        image_path = API + '/images/'
        alias_paths = [image_path + repository + ':' + tag for tag in ('first', 'second')]

        def inspect(path):
            status, raw = session.request('GET', path + '/json')
            self.assertEqual(status, 200, raw)
            return json.loads(raw)

        with alpine(self, session) as reference:
            source = image_path + quote(reference, safe='')
            original = inspect(source)['Id']
            try:
                for tag in ('first', 'second'):
                    tagged, raw = session.request('POST', source + '/tag?' + urlencode({
                        'repo': repository, 'tag': tag,
                    }))
                    self.assertEqual(tagged, 201, raw)
                for path in alias_paths:
                    self.assertEqual(inspect(path)['Id'], original)

                session.restart_engine()
                for path in alias_paths:
                    self.assertEqual(inspect(path)['Id'], original)
                self.assertEqual(inspect(source)['Id'], original)
                with container(self, session, repository, {
                        'Image': repository + ':first', 'Cmd': ['/bin/echo', 'tag-restored'],
                        'HostConfig': {'NetworkMode': 'none'},
                }) as (path, _):
                    self.assertEqual(session.request('POST', path + '/start')[0], 204)
                    status, raw = session.request('POST', path + '/wait?condition=not-running')
                    self.assertEqual(status, 200, raw)
                    self.assertEqual(json.loads(raw)['StatusCode'], 0)
                    status, raw = session.request('GET', path + '/logs?stdout=true&follow=false')
                    self.assertEqual(status, 200, raw)
                    self.assertEqual(raw, b'\x01\0\0\0\0\0\0\x0dtag-restored\n')

                self.assertEqual(session.request('DELETE', alias_paths[1])[0], 200)
                session.restart_engine()
                self.assertEqual(session.request('GET', alias_paths[1] + '/json')[0], 404)
                self.assertEqual(inspect(alias_paths[0])['Id'], original)
                self.assertEqual(inspect(source)['Id'], original)
            finally:
                for path in alias_paths:
                    status, raw = session.request('DELETE', path)
                    self.assertIn(status, (200, 404), raw)
        session.record({'both_aliases_restored': True, 'alias_executed': True,
                        'deleted_alias_stayed_absent': True, 'original_image_retained': True})

    def test_restart_policy(self):
        'DC-009: Verify no, always, unless-stopped and on-failure across exit, explicit stop and engine restart.'
        session = self.compatibility
        name = 'conjet-restart-' + uuid.uuid4().hex
        volume = API + '/volumes/' + name
        cases = (
            ('no', 'no', 0, 1),
            ('always', 'always', 0, 1),
            ('unless-stopped', 'unless-stopped', 0, 1),
            ('unless-running', 'unless-stopped', 0, 1),
            ('on-failure', 'on-failure', 1, 2),
        )
        command = (
            'file=/data/"$1"; attempts=0; '
            'if [ -f "$file" ]; then attempts=$(cat "$file"); fi; '
            'attempts=$((attempts+1)); printf "%s\\n" "$attempts" >"$file"; '
            'if [ "$attempts" -le "$2" ]; then exit 37; fi; exec sleep 120'
        )

        def inspect(path):
            status, raw = session.request('GET', path + '/json')
            self.assertEqual(status, 200, raw)
            return json.loads(raw)

        def wait(path, target, restarts=None):
            deadline = time.monotonic() + 8
            while True:
                current = inspect(path)
                state = current['State']
                if (state['Status'] == target
                        and (restarts is None or current['RestartCount'] == restarts)):
                    return current
                if time.monotonic() >= deadline:
                    self.fail(f'{path} did not reach {target}: {state!r}, restarts={current["RestartCount"]!r}')
                time.sleep(0.04)

        def attempts(path, key, count):
            result = exec_command(self, session, path, ['/bin/cat', '/data/' + key])
            self.assertEqual(result, (0, f'{count}\n'.encode(), b''))

        with alpine(self, session) as image:
            try:
                status, raw = session.request('POST', API + '/volumes/create', {'Name': name})
                self.assertEqual(status, 201, raw)
                with ExitStack() as workloads:
                    paths = {}
                    for key, policy, retries, failures in cases:
                        path, identifier = workloads.enter_context(container(self, session, name + '-' + key, {
                            'Image': image, 'Cmd': ['/bin/sh', '-c', command, 'fixture', key, str(failures)],
                            'HostConfig': {
                                'NetworkMode': 'none',
                                'Mounts': [{'Type': 'volume', 'Source': name, 'Target': '/data'}],
                                'RestartPolicy': {'Name': policy, 'MaximumRetryCount': retries},
                            },
                        }))
                        paths[key] = (path, identifier)
                        status, raw = session.request('POST', path + '/start')
                        self.assertEqual(status, 204, raw)

                    for key, expected_retries in (('no', 0), ('on-failure', 1)):
                        model = wait(paths[key][0], 'exited', expected_retries)
                        self.assertEqual(model['State']['ExitCode'], 37)
                    for key in ('always', 'unless-stopped', 'unless-running'):
                        path = paths[key][0]
                        wait(path, 'running', 1)
                        attempts(path, key, 2)
                    for key in ('always', 'unless-stopped'):
                        status, raw = session.request('POST', paths[key][0] + '/stop?t=1')
                        self.assertEqual(status, 204, raw)
                    time.sleep(0.35)
                    for key in ('always', 'unless-stopped'):
                        wait(paths[key][0], 'exited', 1)

                    session.restart_engine()
                    for key in ('always', 'unless-running'):
                        path, identifier = paths[key]
                        self.assertEqual(wait(path, 'running')['Id'], identifier)
                        attempts(path, key, 3)
                    for key in ('no', 'unless-stopped', 'on-failure'):
                        path, identifier = paths[key]
                        self.assertEqual(wait(path, 'exited')['Id'], identifier)
            finally:
                status, raw = session.request('DELETE', volume)
                self.assertIn(status, (204, 404), raw)
        session.record({'no': 'stayed-exited', 'on_failure': 'one-retry-stayed-exited',
                        'always': 'resumed-after-restart', 'unless_stopped': 'stayed-stopped',
                        'unless_running': 'resumed-after-restart'})

    def test_signal_init(self):
        'DC-010: PID 1 receives configured stop signal; init reaps zombies; timeout escalates and reports exit correctly.'
        self.fail('UNIMPLEMENTED DC-010; no runtime compatibility evidence')

    def test_pause_update(self):
        'DC-011: Pause freezes progress; unpause resumes; resource update preserves unrelated configuration.'
        self.fail('UNIMPLEMENTED DC-011; no runtime compatibility evidence')

    def test_name_races(self):
        'DC-012: Concurrent create with one name admits one owner; failed start releases only its owned resources.'
        session = self.compatibility
        api = '/v1.44'
        token = uuid.uuid4().hex
        reference = ('docker.io/library/alpine@sha256:'
                     'e233f2058b0628266762f745a2c17e623b418e0090f47d223909d1f9a7d4367e')
        repository, digest = reference.split('@')
        config_digest = 'sha256:062964a69725bb96611dae2ac911a5a1ab3f8d32fe6f096f267d77f09e55a99c'
        image_path = api + '/images/' + quote(reference, safe='')
        name = 'conjet-race-' + token
        failed = name + '-failed'
        names = [name, failed]
        containers = api + '/containers/'
        image_present, _ = session.request('GET', image_path + '/json')
        self.assertIn(image_present, (200, 404))
        gate = Barrier(2)

        def create(client, name, executable):
            return client.request('POST', containers + 'create?' + urlencode({'name': name}), {
                'Image': reference, 'Cmd': [executable], 'HostConfig': {'NetworkMode': 'none'},
            })

        def compete():
            peer = type(session)(session.connection.peer())
            gate.wait(timeout=5)
            return create(peer, name, '/bin/true')

        try:
            if image_present == 404:
                query = urlencode({'fromImage': repository, 'tag': digest, 'platform': 'linux/arm64'})
                pull = type(session)(session.connection.peer(timeout=25))
                self.assertEqual(pull.request('POST', api + '/images/create?' + query)[0], 200)
            status, data = session.request('GET', image_path + '/json')
            self.assertEqual(status, 200)
            inspected = json.loads(data)
            self.assertIn(inspected['Id'], (config_digest, digest))
            self.assertEqual(inspected['Architecture'], 'arm64')
            self.assertTrue(any(item.rsplit('@', 1)[-1] == digest
                                for item in inspected['RepoDigests']))

            with ThreadPoolExecutor(max_workers=2) as pool:
                racers = [pool.submit(compete) for _ in range(2)]
                results = [race.result(timeout=10) for race in racers]
            self.assertEqual(sorted(status for status, _ in results), [201, 409])
            winner = next(json.loads(data)['Id'] for status, data in results if status == 201)

            self.assertEqual(create(session, failed, '/conjet-nonexistent-fixture')[0], 201)
            status, _ = session.request('POST', containers + failed + '/start')
            if status == 204:
                waited, data = session.request('POST', containers + failed + '/wait?condition=not-running')
                self.assertEqual(waited, 200)
                self.assertNotEqual(json.loads(data)['StatusCode'], 0)
            else:
                self.assertGreaterEqual(status, 400)
            self.assertEqual(session.request('DELETE', containers + failed + '?force=true')[0], 204)
            self.assertEqual(session.request('GET', containers + failed + '/json')[0], 404)

            status, data = session.request('GET', containers + name + '/json')
            self.assertEqual(status, 200)
            self.assertEqual(json.loads(data)['Id'], winner)
            self.assertEqual(session.request('POST', containers + name + '/start')[0], 204)
            status, data = session.request('POST', containers + name + '/wait?condition=not-running')
            self.assertEqual(status, 200)
            self.assertEqual(json.loads(data)['StatusCode'], 0)
            session.record({'create_statuses': [201, 409], 'failed_start_removed': True,
                            'retained_winner_exit': 0})
        finally:
            removed = [session.request('DELETE', containers + item + '?force=true')[0] for item in names]
            if image_present == 404:
                removed.append(session.request('DELETE', image_path)[0])
            self.assertTrue(all(status in (200, 204, 404) for status in removed), removed)

    def test_lost_guest_reply(self):
        'DC-013: Drop a guest reply; request times out and unrelated info and cancellation remain responsive.'
        self.fail('UNIMPLEMENTED DC-013; no runtime compatibility evidence')

    def test_disk_full_recovery(self):
        'DC-014: Fill isolated disk during write and pull; reclaim owned data; restart and verify recovery and original checksums.'
        self.fail('UNIMPLEMENTED DC-014; no runtime compatibility evidence')
