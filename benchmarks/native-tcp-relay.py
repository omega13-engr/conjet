"""Prove the bounded native TCP stream against workload-owned listeners."""

from contextlib import ExitStack
import hashlib
import json
from pathlib import Path
import runpy
import socket
import time


INSTALL = runpy.run_path(str(Path(__file__).with_name('native-oci-live-install.py')))


def collect(session, pid, output):
    cases = {}
    try:
        with INSTALL['channel'](session, pid) as (control, boot):
            exchange = INSTALL['exchange']
            end = INSTALL['terminal']
            ports = (8080, 8081)

            def workload(port):
                state = INSTALL['inspect'](control)
                cmd = ['/bin/sh', '-c',
                       f'exec /bin/busybox nc -l -p {port} -e /bin/sh -c '
                       '\'while IFS= read -r line; do last=$line; done; printf "%s\\n" "$last"\'']
                request = INSTALL['launch_request'](state, state['image_digest'], cmd)
                request['spec'].update(network='bridge', network_alias=f'relay-{port}')
                launched = exchange(control, 8, request, 13)
                handle = launched['handle']
                until = time.monotonic() + 3
                while time.monotonic() < until:
                    current = exchange(control, 9, {'handle': handle, 'budget_ms': 1000}, 13)
                    if current['phase'] == 'running':
                        return current
                    if current['phase'] in ('removed', 'cleanup_failed'):
                        break
                    time.sleep(0.02)
                raise RuntimeError(f'TCP fixture did not start: {current}')

            cases['services'] = [workload(port) for port in ports]
            handles = [row['handle'] for row in cases['services']]

            def dial(channel, handle, port, error=None):
                spec = {'handle': handle, 'port': port, 'budget_ms': 500}
                reply = exchange(channel, 24, spec, 15 if error else 24, error)
                if not error and reply != {'connected': True}:
                    raise RuntimeError(f'wrong acknowledgement: {reply}')
                return reply

            cases['invalid_port'] = dial(control, handles[0], 0, 'malformed')
            cases['stale'] = dial(control, {**handles[0], 'boot_id': '0' * 32}, ports[0], 'stale_generation')
            cases['refused'] = dial(control, handles[0], 9080, 'connection_refused')
            with ExitStack() as flows:
                relay = []
                for handle, port in zip(handles, ports):
                    channel, observed = flows.enter_context(INSTALL['channel'](session, pid))
                    if observed != boot:
                        raise RuntimeError('native guest boot changed during TCP relay')
                    dial(channel, handle, port)
                    relay.append(channel)
                cases['exhausted'] = dial(control, handles[0], ports[0], 'busy')
                # Close one client with no request. The sibling remains usable.
                relay[1].shutdown(socket.SHUT_RDWR)
                relay[1].close()
                payload = b'0123456789abcdef' * 8192 + b'\n'
                relay[0].settimeout(8)
                relay[0].sendall(payload)
                relay[0].shutdown(socket.SHUT_WR)
                received = bytearray()
                while len(received) <= len(payload):
                    chunk = relay[0].recv(8192)
                    if not chunk:
                        break
                    received.extend(chunk)
                cases['half_close'] = {'bytes': len(received),
                                       'expected_sha256': hashlib.sha256(payload).hexdigest(),
                                       'actual_sha256': hashlib.sha256(received).hexdigest()}
                if received != payload:
                    raise RuntimeError(f'half-close before exact response: {cases["half_close"]}')
            for handle in handles:
                current = end(control, handle)
                cases.setdefault('cleanup', []).append(current)
                if current['cleanup'] != 'complete' or current['network_cleanup'] != 'complete':
                    raise RuntimeError(f'Relay removed an unverified workload: {current}')
            cases['released_slots'] = dial(control, handles[0], ports[0], 'not_running')
    finally:
        (output / 'tcp-relay.json').write_text(json.dumps(cases, indent=2) + '\n')
