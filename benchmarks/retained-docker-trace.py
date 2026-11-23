"""Correlate host VSOCK phases with Docker lifecycle events on an owned endpoint."""

import argparse
import json
from pathlib import Path
import runpy
import socket
import subprocess
from threading import Event, Thread
import time
from urllib.parse import urlencode
import uuid


HELPER = runpy.run_path(str(Path(__file__).with_name('fresh-lifecycle.py')))
LABEL = HELPER['SESSION_LABEL']


class DockerEvents:
    def __init__(self, endpoint, peer, prefix, token, expected):
        self.connection = HELPER['UnixHTTP'](endpoint, peer)
        self.query = prefix + '/events?' + urlencode({'filters': json.dumps({
            'type': {'container': True}, 'label': {f'{LABEL}={token}': True}})})
        self.expected = expected
        self.submitted = Event()
        self.socket = None
        self.error = None
        self.rows = []
        self.thread = Thread(target=self.receive, name='retained-dockerd-events')

    def receive(self):
        try:
            self.connection.connect()
            self.socket = self.connection.sock
            self.connection.request('GET', self.query)
            self.submitted.set()
            response = self.connection.getresponse()
            if response.status != 200:
                raise RuntimeError(f'Docker event request failed with {response.status}')
            with response:
                destroyed = 0
                while destroyed < self.expected and len(self.rows) < 256:
                    line = response.readline(8193)
                    if not line or len(line) > 8192:
                        break
                    event = json.loads(line)
                    self.rows.append(event)
                    destroyed += event['Action'] == 'destroy'
                if destroyed != self.expected:
                    raise RuntimeError(f'expected {self.expected} Docker destroy events, got {destroyed}')
        except Exception as error:
            self.error = error
        finally:
            self.submitted.set()
            self.connection.close()

    def start(self):
        self.thread.start()
        if not self.submitted.wait(timeout=5) or self.error:
            raise RuntimeError(f'Docker event subscription failed: {self.error}')

    def finish(self):
        self.thread.join(timeout=8)
        if self.thread.is_alive() or self.error:
            raise RuntimeError(f'Docker event subscription incomplete: {self.error}')

    def close(self):
        if self.thread.is_alive() and self.socket:
            try:
                self.socket.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
        if self.thread.ident is not None:
            self.thread.join(timeout=25)
            if self.thread.is_alive():
                raise RuntimeError('Docker event observer failed to stop')


def collect(endpoint, config, peer, client, output, scenario_path, archive, trace, guest_observers, count):
    args = argparse.Namespace(engine='conjet', socket=endpoint, config=config, peer_pid=peer, docker=client)
    docker, env, _ = HELPER['verify_endpoint'](args)
    scenario = json.loads(scenario_path.read_text())
    if HELPER['file_hash'](archive) != scenario['archive_sha256']:
        raise RuntimeError('wrong retained Docker trace archive')
    HELPER['run'](docker + ['load', '--input', archive], env, timeout=120)
    image_id = HELPER['run'](docker + ['image', 'inspect', scenario['image'], '--format', '{{.Id}}'], env)
    if image_id != scenario['config_digest']:
        raise RuntimeError('wrong trace image identity')
    output.mkdir(mode=0o700)
    token = uuid.uuid4().hex
    prefix = '/v' + scenario['api_version']
    rows = []
    report = {'passed': False, 'rows': rows, 'trace': trace, 'guest_observers': guest_observers,
              'host_clock': 'Python monotonic_ns', 'guest_event_clock': 'Docker guest wall timeNano',
              'fixture_sha256': scenario['archive_sha256'], 'image_id': image_id,
              'client_sha256': HELPER['file_hash'](client)}
    observer = f'cj-ctr-{token}'
    observer_id = None
    docker_events = DockerEvents(endpoint, peer, prefix, token, count + 4) if guest_observers else None

    def request(method, route, expected, body=None, tag=None):
        connection = HELPER['UnixHTTP'](endpoint, peer)
        headers = {'Connection': 'close'}
        if tag is not None:
            headers['X-Conjet-Benchmark-Trace'] = tag
        try:
            if body is not None:
                headers['Content-Type'] = 'application/json'
            connection.request(method, prefix + route, body=None if body is None else json.dumps(body),
                               headers=headers)
            response = connection.getresponse()
            payload = response.read(HELPER['MAX_RESPONSE_BYTES'] + 1)
            if response.status != expected or len(payload) > HELPER['MAX_RESPONSE_BYTES']:
                raise RuntimeError(f'retained Docker operation returned status {response.status}')
            return payload
        finally:
            connection.close()

    try:
        if guest_observers:
            observe_command = ['create', '--name', observer, '--pull', 'never', '--network', 'none',
                               '--memory', '128m', '--pids-limit', '32', '--cpus', '0.5',
                               '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges',
                               '--user', '0:0', '--read-only',
                               '--mount', 'type=bind,source=/run/containerd/containerd.sock,target=/run/containerd/containerd.sock,readonly',
                               '--mount', 'type=bind,source=/usr/bin/ctr,target=/usr/bin/ctr,readonly',
                               '--mount', 'type=bind,source=/lib/ld-linux-aarch64.so.1,target=/lib/ld-linux-aarch64.so.1,readonly',
                               '--mount', 'type=bind,source=/lib/aarch64-linux-gnu/libc.so.6,target=/lib/aarch64-linux-gnu/libc.so.6,readonly',
                               '--entrypoint', '/usr/bin/ctr', scenario['image'],
                               '--address', '/run/containerd/containerd.sock', '--namespace', 'moby',
                               'events', 'topic=="/tasks/start"', 'topic=="/tasks/exit"']
            report['observer_command'] = observe_command
            observer_id = HELPER['run'](docker + observe_command, env)
            HELPER['run'](docker + ['start', observer_id], env)
            docker_events.start()
        for index in range(count + 4):
            name = f'cj-trace-{token}-{index}'
            row = {'warmup': index < 4, 'name': name, 'stages_ns': {}, 'tags': {}}
            rows.append(row)

            def sample(stage, method, route, expected, body=None):
                tag = None
                if stage in ('start', 'wait') and not row['warmup']:
                    tag = uuid.uuid4().hex
                    row['tags'][stage] = tag
                start = time.monotonic_ns()
                try:
                    return request(method, route, expected, body, tag)
                finally:
                    row['stages_ns'][stage] = time.monotonic_ns() - start

            limits = scenario['container_limits']
            create = sample('create', 'POST', '/containers/create?' + urlencode({'name': name}), 201, {
                'Image': scenario['image'], 'Cmd': scenario['command'], 'Labels': {LABEL: token},
                'HostConfig': {'NetworkMode': 'none', 'Memory': limits['memory_bytes'],
                               'PidsLimit': limits['pids'], 'NanoCpus': limits['cpu_millicores'] * 1_000_000,
                               'CapDrop': ['ALL'], 'SecurityOpt': ['no-new-privileges']},
            })
            ident = json.loads(create)['Id']
            row['container_id'] = ident
            if len(ident) != 64 or any(digit not in '0123456789abcdef' for digit in ident):
                raise RuntimeError('invalid trace container identity')
            route = '/containers/' + ident
            sample('start', 'POST', route + '/start', 204)
            status = json.loads(sample('wait', 'POST', route + '/wait?condition=not-running', 200))
            row['exit'] = status['StatusCode']
            if status['StatusCode'] != 0 or status.get('Error'):
                raise RuntimeError('trace fixture exited unsuccessfully')
            sample('remove', 'DELETE', route, 204)
        if guest_observers:
            owned = {row['container_id'] for row in rows}
            observer_status = json.loads(HELPER['run'](
                docker + ['inspect', '--format', '{{json .State}}', observer_id], env))
            report['observer_state'] = {key: observer_status[key] for key in ('Status', 'ExitCode', 'Error')}
            logs = subprocess.run(docker + ['logs', observer_id], env=env, capture_output=True,
                                  text=True, timeout=10, check=True)
            if len(logs.stdout) + len(logs.stderr) > HELPER['MAX_RESPONSE_BYTES']:
                raise RuntimeError('bounded containerd observer output exceeded')
            report['observer_stderr'] = logs.stderr
            by_task = {}
            for line in logs.stdout.splitlines():
                utc, namespace, topic, payload = line.split(' ', 6)[3:]
                task = json.loads(payload)
                ident = task.get('container_id')
                if utc != 'UTC' or namespace != 'moby' or ident not in owned:
                    continue
                by_task.setdefault(ident, []).append({
                    'topic': topic, 'guest_wall_timestamp': ' '.join(line.split(' ', 3)[:3])})
            report['guest_containerd_events'] = by_task
            docker_events.finish()
            by_container = {}
            for event in docker_events.rows:
                ident = event['Actor']['ID']
                if ident not in owned:
                    raise RuntimeError('trace returned a foreign Docker event')
                by_container.setdefault(ident, []).append(
                    {'action': event['Action'], 'guest_time_ns': event['timeNano']})
            report['guest_events'] = by_container
            for row in rows:
                actions = {event['action'] for event in by_container.get(row['container_id'], [])}
                if not {'create', 'start', 'die', 'destroy'} <= actions:
                    raise RuntimeError(f'incomplete Docker lifecycle event trace: {row["name"]}')
                topics = {event['topic'] for event in by_task.get(row['container_id'], [])}
                if not row['warmup'] and not {'/tasks/start', '/tasks/exit'} <= topics:
                    raise RuntimeError(f'incomplete containerd lifecycle trace: {row["name"]}')
        report['passed'] = True
    finally:
        try:
            try:
                try:
                    if docker_events:
                        docker_events.close()
                finally:
                    if observer_id:
                        HELPER['run'](docker + ['rm', '--force', observer_id], env)
                        report['observer_removed'] = True
            finally:
                report['recovered_after_abort'] = HELPER['cleanup_fixtures'](docker, env, token)
        finally:
            (output / 'retained-trace.json').write_text(json.dumps(report, indent=2) + '\n')
