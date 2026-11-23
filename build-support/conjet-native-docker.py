#!/usr/bin/env python3
"""Serve the isolated candidate's Docker API over one owned native OCI session."""

import argparse
import base64
import fcntl
from collections import deque
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler
import json
import os
from pathlib import Path
import re
import runpy
import signal
import socket
import socketserver
import struct
import threading
import time
from urllib.parse import parse_qs, unquote, urlsplit
import uuid

REPO = Path(__file__).resolve().parents[1]
WIRE = runpy.run_path(str(REPO / 'benchmarks/native-fresh-lifecycle.py'))
TOOLS = runpy.run_path(str(REPO / 'benchmarks/fresh-lifecycle.py'))
SCRATCH = WIRE['SCRATCH']
LIMITS = {'memory_bytes': 16777216, 'pids': 4, 'cpu_millicores': 500}
NAME = re.compile(r'[a-zA-Z0-9][a-zA-Z0-9_.-]{0,63}')


class Trace:
    """Bound diagnostic memory and keep payloads and credentials out of the trace."""

    def __init__(self):
        self.rows = deque(maxlen=16384)
        self.lock = threading.Lock()
        self.count = 0

    def mark(self, event, **fields):
        with self.lock:
            self.rows.append({'host_ns': time.monotonic_ns(), 'event': event,
                              'thread': threading.get_native_id(), **fields})
            self.count += 1

    def write(self, path):
        with path.open('x') as stream:
            json.dump({'dropped': self.count - len(self.rows), 'events': list(self.rows)}, stream)
            stream.write('\n')


class Rejected(ValueError):
    def __init__(self, message, status=400):
        super().__init__(message)
        self.status = status


class Native:
    def __init__(self, session, digest, trace=None):
        if (session.resolve() != session or not session.is_relative_to(SCRATCH)
                or not session.is_dir() or session.stat().st_mode & 0o077):
            raise Rejected('native session directory is not private')
        self.sock = session / 'native-launch.sock'
        key = (session / 'launch.key').read_bytes()
        if len(key) != 32:
            raise Rejected('native session key is invalid')
        identity = json.loads((session / 'native-session.json').read_text())
        self.pid = identity['pid']
        self.digest = digest
        self.trace = trace
        self.lock = threading.Lock()
        self.pending = None
        if identity['image_digest'] != digest:
            raise Rejected('staged OCI digest differs from the receipt')
        self.connection = socket.socket(socket.AF_UNIX)
        try:
            if trace:
                trace.mark('native_connect')
            self.connection.settimeout(10)
            self.connection.connect(str(self.sock))
            if self.connection.getsockopt(0, 2) != self.pid:
                raise Rejected('native socket peer changed')
            self.boot = WIRE['authenticate'](self.connection, key, 'native_oci_arm64_v1')
            status = self.call(self.connection, 20, {'budget_ms': 1000}, 20)
            if (status['boot_id'] != self.boot or status['image_digest'] != digest
                    or status['workload'] is not None):
                raise Rejected('native session must begin dedicated and idle')
            self.sequence = status['last_sequence']
        except BaseException:
            self.close()
            raise

    def close(self):
        with self.lock:
            if self.connection is not None:
                self.connection.close()
                self.connection = None

    @contextmanager
    def lease(self):
        with self.lock:
            if self.connection is None:
                raise RuntimeError('authenticated native channel is closed')
            try:
                yield self.connection
            except BaseException:
                # The peer may have committed the pending operation even if
                # its response was lost. Keep its identity and fail closed.
                self.connection.close()
                self.connection = None
                raise

    def call(self, channel, opcode, body, expected):
        kind, response = WIRE['call'](channel, opcode, body)
        if kind != expected:
            raise RuntimeError(f'native operation {opcode} rejected: {response}')
        return response

    def execute(self, process, cancellation):
        began = time.monotonic_ns()
        trace = self.trace
        with self.lease() as channel:
            if cancellation.is_set():
                return 137, b'', b'', {'cancelled_before_admission': True}
            self.sequence += 1
            self.pending = {'boot_id': self.boot, 'sequence': self.sequence, 'operation_id': uuid.uuid4().hex}
            request = {**self.pending, 'budget_ms': 1000, 'spec': process}
            if trace:
                trace.mark('native_launch_request', operation=request['operation_id'])
            state = self.call(channel, 8, request, 13)
            admitted = time.monotonic_ns()
            wait_calls = 0
            bound = time.monotonic() + 32
            handle = state['handle']
            if handle['boot_id'] != self.boot:
                raise RuntimeError('native guest incarnation changed')
            self.pending['handle'] = handle
            if trace:
                trace.mark('native_admitted', workload=handle['workload_id'])
            sent_cancel = False
            while state['cleanup'] != 'complete':
                if state['cleanup'] == 'failed' or time.monotonic() >= bound:
                    raise RuntimeError('native workload cleanup is unresolved')
                if cancellation.is_set() and not sent_cancel:
                    state = self.call(channel, 11, {'handle': handle, 'budget_ms': 1000}, 13)
                    if state['handle'] != handle:
                        raise RuntimeError('native cancellation returned a different workload')
                    sent_cancel = True
                    continue
                # Wait for the terminal revision. A short budget bounds the
                # time before we check for cancellation again.
                wait_calls += 1
                kind, result = WIRE['call'](channel, 10, {
                    'handle': handle, 'after_revision': 2**64 - 1, 'budget_ms': 100})
                if kind == 15 and result.get('code') == 'deadline_exceeded':
                    continue
                if kind != 13:
                    raise RuntimeError(f'native terminal wait rejected: {result}')
                if result['handle'] != handle:
                    raise RuntimeError('native wait returned a different workload')
                state = result
            terminal = time.monotonic_ns()
            if trace:
                trace.mark('native_cleanup_verified', wait_calls=wait_calls, exit=state['exit'])
            output = []
            for name in ('stdout', 'stderr'):
                data = bytearray()
                while True:
                    chunk = self.call(channel, 12, {'handle': handle, 'stream': name,
                                      'offset': len(data), 'max_bytes': 8192, 'budget_ms': 1000}, 14)
                    piece = base64.b64decode(chunk['data'], validate=True)
                    data.extend(piece)
                    if chunk['dropped_bytes'] or len(data) > 65536:
                        raise RuntimeError('OCI output exceeds the Docker adapter limit')
                    if chunk['eof']:
                        if trace:
                            trace.mark('native_stream_eof', stream=name, size=len(data))
                        break
                    if not piece:
                        raise RuntimeError('native output did not advance')
                output.append(bytes(data))
            state['adapter_timings_ns'] = {'authenticate': 0,
                                           'admit': admitted - began,
                                           'terminal': terminal - admitted,
                                           'output': time.monotonic_ns() - terminal}
            state['adapter_wait_calls'] = wait_calls
            if sent_cancel and state['exit'] is None and not state.get('helper_failed'):
                self.pending = None
                return 137, *output, state
            if state['exec'] != 'confirmed' or state.get('helper_failed'):
                raise RuntimeError('OCI exec was not confirmed after allocation')
            status = state['exit']
            self.pending = None
            return status.get('code', 128 + status.get('signal', 0)), *output, state


def env_map(config):
    if not isinstance(config, list) or len(config) > 32:
        raise Rejected('invalid environment list')
    result = {}
    for entry in config:
        if not isinstance(entry, str):
            raise Rejected('invalid environment entry')
        key, separator, value = entry.partition('=')
        if not separator or not re.fullmatch(r'[A-Za-z_][A-Za-z_0-9]*', key) or key in result:
            raise Rejected('environment requires explicit unique keys')
        result[key] = value
    return result


def make_process(data, image, metadata):
    conf = data.get('HostConfig') or {}
    expected = {'NetworkMode': 'none', 'Memory': LIMITS['memory_bytes'],
                'NanoCpus': LIMITS['cpu_millicores'] * 1000000, 'PidsLimit': LIMITS['pids']}
    if (data.get('Image') != image or data.get('User') != '65532:65532'
            or any(conf.get(key) != value for key, value in expected.items())):
        raise Rejected('require the staged image, --network none, fixed UID/GID and 16 MiB/4 PIDs/0.5 CPU')
    allowed = {'Image', 'User', 'Cmd', 'Entrypoint', 'Env', 'WorkingDir', 'HostConfig',
               'AttachStdout', 'AttachStderr', 'Labels', 'NetworkingConfig'}
    for name, value in data.items():
        if name not in allowed and value:
            raise Rejected(f'unsupported Docker option {name}')
    for name, value in conf.items():
        if name not in {*expected, 'AutoRemove', 'ConsoleSize', 'RestartPolicy', 'LogConfig', 'MemorySwappiness',
                        'CapDrop', 'SecurityOpt'} and value:
            raise Rejected(f'unsupported Docker HostConfig option {name}')
    if conf.get('CapDrop') not in (None, [], ['ALL']):
        raise Rejected('only dropping all capabilities is supported')
    if conf.get('SecurityOpt') not in (None, [], ['no-new-privileges'], ['no-new-privileges=true']):
        raise Rejected('only no-new-privileges is supported')
    if conf.get('MemorySwappiness') not in (None, -1):
        raise Rejected('explicit memory swappiness is unsupported')
    if conf.get('RestartPolicy', {}).get('Name') not in ('', 'no', None):
        raise Rejected('restart policies are unsupported')
    if (conf.get('LogConfig', {}).get('Type') not in ('', None)
            or conf.get('LogConfig', {}).get('Config')):
        raise Rejected('explicit log drivers are unsupported')
    layers = (data.get('NetworkingConfig') or {}).get('EndpointsConfig', {})
    if layers and (set(layers) != {'none'} or any(layers.get('none', {}).values())):
        raise Rejected('only the no-network endpoint is supported')
    defaults = metadata['process']
    entrypoint = defaults['Entrypoint'] if data.get('Entrypoint') is None else data['Entrypoint']
    cmd = defaults['Cmd'] if data.get('Cmd') is None else data['Cmd']
    if not isinstance(entrypoint, list) or not isinstance(cmd, list):
        raise Rejected('argv must be arrays')
    argv = entrypoint + cmd
    environment = env_map(defaults['Env'])
    environment.update(env_map(data.get('Env') or []))
    env = [f'{key}={value}' for key, value in environment.items()]
    cwd = data.get('WorkingDir') or defaults['WorkingDir']
    def absolute(path):
        return (isinstance(path, str) and path.startswith('/')
                and (path == '/' or all(part not in ('', '.', '..') for part in path.split('/')[1:])))

    if (not argv or len(argv) > 32 or len(env) > 32 or not absolute(argv[0]) or not absolute(cwd)
            or any(not isinstance(value, str) or '\0' in value or len(value.encode()) > 1024
                   for value in [*argv, *env, cwd])
            or sum(len(value.encode()) + 1 for value in [*argv, *env]) > 8192):
        raise Rejected('OCI argv/env/cwd exceed the supported bounds or lack an absolute path')
    return {'image_digest': metadata['config_digest'], 'argv': argv,
            'env': env, 'cwd': cwd, 'uid': 65532, 'gid': 65532, 'network': 'none', 'limits': LIMITS}


class Container:
    def __init__(self, name, data, process):
        self.id = uuid.uuid4().hex + uuid.uuid4().hex
        self.name = name or self.id[:12]
        self.data = data
        self.process = process
        self.auto_remove = bool(data['HostConfig'].get('AutoRemove'))
        self.cancellation = threading.Event()
        self.started = False
        self.removed = False
        self.code = None
        self.error = None
        self.stdout = self.stderr = b''


class Owner:
    def __init__(self, native, image, metadata, trace=None):
        self.native = native
        self.image = image
        self.metadata = metadata
        self.cv = threading.Condition()
        self.record = None
        self.history = deque(maxlen=4)
        self.events = deque(maxlen=16)
        self.worker = None
        self.poisoned = False
        self.trace = trace

    def event(self, action, item):
        if self.trace:
            self.trace.mark(action, container=item.id)
        attributes = {'name': item.name, 'image': self.image, 'conjet.backend': 'jetstream-native-oci'}
        if action == 'die':
            attributes.update({'exitCode': str(item.code),
                               'conjet.guest_cleanup': item.native.get('cleanup', 'not_admitted'),
                               'conjet.native_handle': item.native.get('handle', {}).get('workload_id', '')})
            attributes.update({f'conjet.timing.{key}': str(value) for key, value in
                               item.native.get('adapter_timings_ns', {}).items()})
            if 'adapter_wait_calls' in item.native:
                attributes['conjet.wait_calls'] = str(item.native['adapter_wait_calls'])
        self.events.append({'Type': 'container', 'Action': action,
                            'Actor': {'ID': item.id, 'Attributes': attributes},
                            'time': int(time.time()), 'timeNano': time.time_ns()})

    def create(self, name, data):
        if name and not NAME.fullmatch(name):
            raise Rejected('invalid container name')
        process = make_process(data, self.image, self.metadata)
        with self.cv:
            if self.record is not None or self.poisoned:
                raise Rejected('native OCI capacity is occupied or unresolved', 409)
            container = Container(name, data, process)
            self.record = container
            self.event('create', container)
            return container

    def lookup(self, identifier):
        with self.cv:
            for item in [self.record, *self.history]:
                if item and identifier in (item.id, item.id[:12], item.name):
                    return item
        raise Rejected('container was not found', 404)

    def start(self, item):
        with self.cv:
            if self.record is not item or item.started:
                raise Rejected('container has already been submitted or removed', 409)
            item.started = True
            self.worker = threading.Thread(target=self.run, args=(item,))
            self.worker.start()
            self.event('start', item)

    def run(self, item):
        if self.trace:
            self.trace.mark('worker_enter', container=item.id)
        try:
            code, stdout, stderr, native = self.native.execute(item.process, item.cancellation)
        except Exception as error:
            # Poison this session on an unknown terminal boundary. Never
            # execute a second container against unresolved guest ownership.
            with self.cv:
                self.poisoned = True
                item.code = 125
                item.error = str(error)
                self.cv.notify_all()
            return
        with self.cv:
            item.code, item.stdout, item.stderr = code, stdout, stderr
            item.native = native
            self.event('die', item)
            if item.auto_remove:
                self.retire(item)
            self.cv.notify_all()

    def retire(self, item):
        if not item.removed:
            item.removed = True
            self.history.appendleft(item)
            self.record = None
            self.event('destroy', item)
            self.cv.notify_all()

    def remove(self, item, force):
        with self.cv:
            if self.record is not item:
                raise Rejected('container was already removed', 404)
            if item.started and item.code is None:
                if not force:
                    raise Rejected('container is running', 409)
                item.cancellation.set()
                if not self.cv.wait_for(lambda: item.code is not None, 34):
                    raise Rejected('native cancellation did not reach a terminal state', 500)
            if item.error:
                raise Rejected('guest cleanup is unresolved', 500)
            self.retire(item)

    def wait(self, item, condition):
        if condition not in ('next-exit', 'not-running', 'removed'):
            raise Rejected('unsupported wait condition')
        with self.cv:
            if condition == 'not-running' and not item.started:
                return 0
            if not self.cv.wait_for(lambda: item.error or (
                    item.removed if condition == 'removed' else item.code is not None), 35):
                raise Rejected('wait deadline elapsed', 500)
            if item.error:
                raise Rejected(item.error, 500)
            return item.code or 0


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def setup(self):
        self.request.settimeout(38)
        super().setup()
        if self.server.owner.trace:
            self.connection_id = uuid.uuid4().hex
            self.server.owner.trace.mark('http_connect', connection=self.connection_id)

    def finish(self):
        super().finish()
        if hasattr(self, 'connection_id'):
            self.trace_mark('http_finish')

    def trace_mark(self, event, **fields):
        if self.server.owner.trace:
            self.server.owner.trace.mark(event, connection=self.connection_id, **fields)

    def log_message(self, *_):
        pass

    def reply(self, status, data=None, headers=None):
        buffer = json.dumps(data).encode() if data is not None else b''
        self.send_response(status)
        self.send_header('Content-Length', str(len(buffer)))
        self.send_header('API-Version', '1.44')
        self.send_header('Ostype', 'linux')
        if data is not None:
            self.send_header('Content-Type', 'application/json')
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        if buffer and self.command != 'HEAD':
            self.wfile.write(buffer)

    def body(self):
        try:
            count = int(self.headers.get('Content-Length', '0'))
        except ValueError as error:
            raise Rejected('invalid content length') from error
        if self.headers.get('Transfer-Encoding') or not 0 <= count <= 16384:
            raise Rejected('unsupported Docker request body framing')
        data = json.loads(self.rfile.read(count) or b'{}')
        if not isinstance(data, dict):
            raise Rejected('expected a Docker request object')
        return data

    def attach(self, item, query):
        if (query.get('stdin', ['0'])[0] not in ('0', 'false')
                or query.get('logs', ['0'])[0] not in ('0', 'false')):
            raise Rejected('stdin and attachment replay are unsupported')
        self.send_response(101)
        self.send_header('Connection', 'Upgrade')
        self.send_header('Upgrade', 'tcp')
        self.send_header('Content-Type', 'application/vnd.docker.multiplexed-stream')
        self.end_headers()
        self.trace_mark('attach_headers', container=item.id)
        self.close_connection = True
        owner = self.server.owner
        with owner.cv:
            owner.cv.wait_for(lambda: item.code is not None or item.removed, 35)
            streams = (item.stdout, item.stderr)
        for index, stream in enumerate(streams, 1):
            key = ('stdout', 'stderr')[index - 1]
            if not stream or query.get(key, ['1'])[0] in ('0', 'false'):
                continue
            self.wfile.write(struct.pack('>B3xI', index, len(stream)) + stream)
        self.trace_mark('attach_output_written', container=item.id)

    def inspect(self, item):
        if item.removed:
            raise Rejected('container was removed', 404)
        return {'Id': item.id, 'Name': '/' + item.name, 'Image': item.process['image_digest'],
                'Driver': 'jetstream-native-oci', 'Platform': 'linux', 'Path': item.process['argv'][0],
                'Args': item.process['argv'][1:],
                'State': {'Status': ('exited' if item.code is not None else 'running' if item.started else 'created'),
                          'Running': item.started and item.code is None, 'ExitCode': item.code or 0,
                          'Error': item.error or ''},
                'Config': {**item.data, 'Tty': False},
                'HostConfig': item.data['HostConfig'], 'NetworkSettings': {'Networks': {}}}

    def dispatch(self):
        owner = self.server.owner
        url = urlsplit(self.path)
        query = parse_qs(url.query)
        version = re.match(r'^/v([0-9]+\.[0-9]+)(?=/)', url.path)
        if version and version[1] != '1.44':
            raise Rejected('this native endpoint supports Docker API 1.44')
        path = url.path[version.end():] if version else url.path
        if path == '/_ping' and self.command in ('HEAD', 'GET'):
            if self.command == 'HEAD':
                self.reply(200)
            else:
                self.send_response(200)
                self.send_header('Content-Length', '2')
                self.send_header('API-Version', '1.44')
                self.send_header('Ostype', 'linux')
                self.end_headers()
                self.wfile.write(b'OK')
            return
        if path == '/version' and self.command == 'GET':
            self.reply(200, {'Version': '0.1.0', 'ApiVersion': '1.44', 'MinAPIVersion': '1.44',
                             'Os': 'linux', 'Arch': 'arm64', 'Platform': {'Name': 'Conjet Native OCI'}})
            return
        if path == '/containers/create' and self.command == 'POST':
            if set(query) - {'name', 'platform'} or query.get('platform', ['linux/arm64']) != ['linux/arm64']:
                raise Rejected('only the Linux ARM64 create query is supported')
            item = owner.create(query.get('name', [''])[0], self.body())
            self.reply(201, {'Id': item.id, 'Warnings': []})
            return
        if path.startswith('/images/') and path.endswith('/json') and self.command == 'GET':
            image = unquote(path[len('/images/'):-len('/json')])
            if image not in (owner.image, owner.metadata['config_digest']):
                raise Rejected('image is not staged', 404)
            self.reply(200, {'Id': owner.metadata['config_digest'], 'Os': 'linux',
                             'Architecture': 'arm64', 'Config': owner.metadata['process']})
            return
        if path == '/events' and self.command == 'GET' and not query:
            # Deliberately bounded snapshot. Time-filtered and continuously
            # streamed events are outside this experiment.
            with owner.cv:
                snapshot = list(owner.events)
            payload = b''.join(json.dumps(event).encode() + b'\n' for event in snapshot)
            self.send_response(200)
            self.send_header('Content-Length', str(len(payload)))
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(payload)
            return
        match = re.fullmatch(r'/containers/([A-Za-z0-9_.-]+)(?:/([a-z]+))?', path)
        if not match:
            raise Rejected('unsupported Docker API operation', 501)
        item = owner.lookup(match[1])
        action = match[2]
        if self.command == 'POST' and action == 'start':
            owner.start(item)
            self.reply(204, headers={'X-Conjet-Backend': 'jetstream-native-oci'})
        elif self.command == 'POST' and action == 'wait':
            condition = query.get('condition', ['not-running'])[0]
            if condition not in ('next-exit', 'not-running', 'removed'):
                raise Rejected('unsupported wait condition')
            # Docker registers its wait before sending start. Headers
            # acknowledge the subscription while the exit body stays pending.
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Connection', 'close')
            self.end_headers()
            self.trace_mark('wait_headers', container=item.id)
            self.close_connection = True
            try:
                result = {'StatusCode': owner.wait(item, condition), 'Error': None}
            except Rejected as error:
                result = {'StatusCode': 125, 'Error': {'Message': str(error)}}
            self.wfile.write(json.dumps(result).encode())
            self.trace_mark('wait_body_written', container=item.id, status=result['StatusCode'])
        elif self.command == 'POST' and action == 'attach':
            self.attach(item, query)
        elif self.command == 'GET' and action == 'json':
            with owner.cv:
                self.reply(200, self.inspect(item), headers={'X-Conjet-Backend': 'jetstream-native-oci'})
        elif self.command == 'DELETE' and action is None:
            if query.get('v', ['0'])[0] in ('1', 'true') or query.get('link', ['0'])[0] in ('1', 'true'):
                raise Rejected('volume and link removal are not supported')
            owner.remove(item, query.get('force', ['0'])[0] in ('1', 'true'))
            self.reply(204)
        else:
            raise Rejected('unsupported container operation', 501)

    def handle_docker_request(self):
        if self.server.owner.trace:
            self.trace_mark('http_request', method=self.command, path=urlsplit(self.path).path[:256])
        try:
            self.dispatch()
        except Rejected as error:
            self.reply(error.status, {'message': str(error)})
        except (ValueError, TypeError, KeyError, AttributeError):
            self.reply(400, {'message': 'invalid or unsupported Docker request'})
        except (BrokenPipeError, ConnectionResetError, TimeoutError):
            self.close_connection = True
        finally:
            if self.server.owner.trace:
                self.trace_mark('http_response', method=self.command)

    do_GET = handle_docker_request
    do_HEAD = handle_docker_request
    do_POST = handle_docker_request
    do_DELETE = handle_docker_request


class Server(socketserver.ThreadingUnixStreamServer):
    request_queue_size = 8

    def __init__(self, endpoint, owner):
        self.owner = owner
        self.admission = threading.BoundedSemaphore(8)
        self.timeout = 0.2
        super().__init__(str(endpoint), Handler)

    def process_request(self, request, client_address):
        if not self.admission.acquire(blocking=False):
            request.close()
            return
        try:
            super().process_request(request, client_address)
        except BaseException:
            self.admission.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.admission.release()

    def shutdown_request(self, request):
        super().shutdown_request(request)
        if self.owner.trace:
            self.owner.trace.mark('http_socket_closed')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--experimental', action='store_true', help=argparse.SUPPRESS)
    parser.add_argument('--native-session', required=True, type=Path)
    parser.add_argument('--receipt', required=True, type=Path)
    parser.add_argument('--image', required=True)
    parser.add_argument('--socket', required=True, type=Path)
    parser.add_argument('--trace', type=Path)
    args = parser.parse_args()
    endpoint = args.socket
    if (endpoint.parent.resolve(strict=True) != endpoint.parent
            or not endpoint.is_relative_to(SCRATCH) or endpoint.parent.stat().st_mode & 0o077
            or os.path.lexists(endpoint) or len(os.fsencode(endpoint)) >= 104):
        parser.error('Docker socket must be new in a private ExternalSSD directory')
    if (args.receipt.is_symlink() or not args.receipt.resolve().is_relative_to(SCRATCH)
            or not args.receipt.is_file() or args.receipt.stat().st_size > 65536
            or not re.fullmatch(r'[^@]+@sha256:[a-f0-9]{64}', args.image)):
        parser.error('require an immutable image reference and bounded ExternalSSD admission receipt')
    metadata = json.loads(args.receipt.read_text())
    if args.trace and (not args.trace.parent.resolve(strict=True).is_relative_to(SCRATCH)
                       or os.path.lexists(args.trace)):
        parser.error('trace must be a new file on ExternalSSD')
    trace = Trace() if args.trace else None
    stop = threading.Event()
    for signum in (signal.SIGTERM, signal.SIGINT):
        signal.signal(signum, lambda *_: stop.set())
    descriptor = os.open(args.native_session / 'admission.lock', os.O_WRONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor, 'w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        native = Native(args.native_session, metadata['config_digest'], trace)
        try:
            owner = Owner(native, args.image, metadata, trace)
            server = Server(endpoint, owner)
            try:
                endpoint.chmod(0o600)
                print(json.dumps({'socket': str(endpoint), 'boot_id': native.boot,
                                  'backend': 'jetstream-native-oci'}), flush=True)
                while not stop.is_set():
                    server.handle_request()
            finally:
                try:
                    with owner.cv:
                        if owner.record is not None:
                            owner.record.cancellation.set()
                        owner.cv.notify_all()
                    if owner.worker:
                        owner.worker.join(35)
                finally:
                    server.server_close()
                    endpoint.unlink(missing_ok=True)
        finally:
            native.close()
            if trace:
                trace.write(args.trace)


if __name__ == '__main__':
    main()
