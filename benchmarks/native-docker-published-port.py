"""Check authenticated native port publication on task-owned loopback."""

from contextlib import closing
import json
from pathlib import Path
import runpy
import socket
import subprocess
import time


HERE = Path(__file__).resolve().parent
MATCHED = runpy.run_path(str(HERE / 'native-docker-comparison.py'))
INSTALL = runpy.run_path(str(HERE / 'native-oci-live-install.py'))
REQUEST = b'GET /proof HTTP/1.1\r\nHost: local\r\nConnection: close\r\n\r\n'
RESPONSE = b'HTTP/1.1 200 OK\r\nContent-Length: 16\r\nConnection: close\r\n\r\nnative-published'
SERVICE = ['/bin/sh', '-c', 'exec /bin/busybox nc -l -p 8080 -e /bin/sh -c '
           '\'while IFS= read -r line; do :; done; '
           'printf "HTTP/1.1 200 OK\\r\\nContent-Length: 16\\r\\nConnection: close\\r\\n\\r\\nnative-published"\'']


def collect(endpoint, peer, docker, env, output, session, pid):
    tools = MATCHED['TOOLS']
    network = 'cj-loopback'
    image = MATCHED['IMAGE']['ref']
    flags = [network if value == 'none' else value for value in MATCHED['FLAGS'][1:]]
    cases = {}

    def call(label, argv, *, code=0, stderr=None):
        result = subprocess.run([*docker, *argv], env=env, capture_output=True, timeout=10)
        cases[label] = {'argv': argv, 'exit': result.returncode, 'stdout': result.stdout.decode(),
                        'stderr': result.stderr.decode()}
        if result.returncode != code or stderr and stderr not in result.stderr:
            raise RuntimeError(f'port fixture {label} failed: {cases[label]}')
        return result.stdout

    def create(label, name, host_port='', command=SERVICE, *, code=0, stderr=None):
        return call(label, ['create', *flags, '--name', name, '-p',
                            f'127.0.0.1:{host_port}:8080', image, *command],
                    code=code, stderr=stderr)

    def mapped(name, label):
        until = time.monotonic() + 3
        while time.monotonic() < until:
            result = json.loads(call(label, ['inspect', name]))[0]
            bindings = result['NetworkSettings']['Ports'].get('8080/tcp')
            if bindings:
                if len(bindings) != 1 or bindings[0]['HostIp'] != '127.0.0.1':
                    raise RuntimeError(f'unexpected publication metadata: {bindings}')
                return int(bindings[0]['HostPort'])
            time.sleep(0.02)
        raise RuntimeError(f'did not observe an active listener for {name}')

    def response(port):
        with socket.create_connection(('127.0.0.1', port), timeout=3) as client:
            client.sendall(REQUEST)
            client.shutdown(socket.SHUT_WR)
            payload = bytearray()
            while len(payload) <= len(RESPONSE):
                data = client.recv(8192)
                if not data:
                    break
                payload.extend(data)
            return bytes(payload)

    def verify_closed(port):
        try:
            with socket.create_connection(('127.0.0.1', port), timeout=1):
                raise RuntimeError('removed mapping still accepted a TCP connection')
        except ConnectionRefusedError:
            return True

    try:
        with closing(tools['UnixHTTP'](endpoint, peer)) as api:
            if tools['api'](api, 'GET', '/version', (200,))['Platform']['Name'] != 'Conjet Native OCI':
                raise RuntimeError('wrong Docker endpoint for port publication')
        call('network_create', ['network', 'create', '--internal', network])
        call('reject_wildcard', ['create', *flags, '-p', '0.0.0.0::8080', image, '/bin/true'],
             code=1, stderr=b'requires 127.0.0.1')
        with socket.socket() as occupied:
            occupied.bind(('127.0.0.1', 0))
            occupied.listen()
            create('bind_conflict', 'conflict', occupied.getsockname()[1], code=1,
                   stderr=b'loopback port is already in use')
        none = ['/bin/busybox', 'sleep', '25']
        create('create_unlistening', 'unlistening', command=none)
        call('start_unlistening', ['start', 'unlistening'])
        port = mapped('unlistening', 'inspect_unlistening')
        with socket.create_connection(('127.0.0.1', port), timeout=3) as client:
            try:
                received = client.recv(1)
            except ConnectionResetError:
                received = b''
            cases['refused_guest'] = not received
            if received:
                raise RuntimeError('refused guest target produced data')
        call('remove_unlistening', ['rm', '--force', 'unlistening'])
        cases['refused_socket_closed'] = verify_closed(port)
        create('create_service', 'application')
        call('start_service', ['start', 'application'])
        port = mapped('application', 'inspect_service')
        result = response(port)
        cases['half_close_response'] = result.decode()
        if result != RESPONSE:
            raise RuntimeError(f'published port lost HTTP response integrity: {result!r}')
        wait = call('wait_service', ['wait', 'application'])
        if wait != b'0\n':
            raise RuntimeError(f'HTTP fixture exited with status {wait!r}')
        call('restart_service', ['restart', 'application'])
        if mapped('application', 'inspect_restarted') != port:
            raise RuntimeError('restart changed the allocated host port')
        with socket.create_connection(('127.0.0.1', port), timeout=3) as abandoned:
            abandoned.sendall(REQUEST)
            abandoned.close()
        call('wait_after_disconnect', ['wait', 'application'])
        call('restart_for_removal', ['restart', 'application'])
        if mapped('application', 'inspect_removal_target') != port:
            raise RuntimeError('restarted removal target changed port')
        with socket.create_connection(('127.0.0.1', port), timeout=3) as active:
            active.sendall(REQUEST)
            call('remove_while_connected', ['rm', '--force', 'application'])
            try:
                received = active.recv(1)
            except ConnectionResetError:
                received = b''
            if received:
                raise RuntimeError('old connection survived removal')
        cases['listener_closed'] = verify_closed(port)
        create('reuse_port', 'replacement', port)
        call('start_replacement', ['start', 'replacement'])
        if mapped('replacement', 'inspect_replacement') != port or response(port) != RESPONSE:
            raise RuntimeError('the prior port could not be reused for a new workload')
        call('remove_replacement', ['rm', '--force', 'replacement'])
        cases['replacement_listener_closed'] = verify_closed(port)
        create('create_first_replica', 'first')
        alternate = [*SERVICE[:-1], SERVICE[-1].replace('native-published', 'native-replica-2')]
        create('create_second_replica', 'second', command=alternate)
        call('start_replicas', ['start', 'first', 'second'])
        first = mapped('first', 'inspect_first_replica')
        second = mapped('second', 'inspect_second_replica')
        if first == second:
            raise RuntimeError('different workloads shared one loopback port')
        create('conflict_with_replica', 'conflict', first, code=1,
               stderr=b'loopback port is already in use')
        if response(first) != RESPONSE:
            raise RuntimeError('first published replica lost its response')
        call('remove_first_replica', ['rm', '--force', 'first'])
        cases['first_replica_closed'] = verify_closed(first)
        if response(second) != RESPONSE.replace(b'native-published', b'native-replica-2'):
            raise RuntimeError('second published replica lost its response')
        call('remove_second_replica', ['rm', '--force', 'second'])
        cases['second_replica_closed'] = verify_closed(second)
        call('network_remove', ['network', 'rm', network])
        with INSTALL['channel'](session, pid) as (guest, _):
            cases['guest_after'] = INSTALL['inspect'](guest)['active_workloads']
            if cases['guest_after']:
                raise RuntimeError('published port suite left native workloads')
    finally:
        (output / 'docker-published-port.json').write_text(json.dumps(cases, indent=2) + '\n')
