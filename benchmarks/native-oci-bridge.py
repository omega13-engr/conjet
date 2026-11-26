"""Prove private DNS and TCP between real native OCI workloads."""

import base64
import json
from pathlib import Path
import runpy
import time


INSTALL = runpy.run_path(str(Path(__file__).with_name('native-oci-live-install.py')))


def collect(session, pid, output):
    cases = {}
    try:
        with INSTALL['channel'](session, pid) as (stream, boot):
            exchange = INSTALL['exchange']
            inspect = lambda: INSTALL['inspect'](stream)
            digest = inspect()['image_digest']

            def launch(argv, alias=None, error=None):
                state = inspect()
                request = INSTALL['launch_request'](state, digest, argv)
                if alias:
                    request['spec'].update(network='bridge', network_alias=alias)
                result = exchange(stream, 8, request, 15 if error else 13, error)
                if error and inspect()['last_sequence'] != state['last_sequence']:
                    raise RuntimeError('rejected network options reserved a launch sequence')
                return result['handle'] if not error else result

            def running(handle):
                until = time.monotonic() + 3
                while time.monotonic() < until:
                    state = exchange(stream, 9, {'handle': handle, 'budget_ms': 1000}, 13)
                    if state['phase'] == 'running':
                        return state
                    if state['phase'] in ('removed', 'cleanup_failed'):
                        cases['server_failure'] = INSTALL['terminal'](stream, handle)
                        break
                    time.sleep(0.02)
                raise RuntimeError(f'OCI service failed before it was running: {state}')

            def finish(handle, *, cancel=False, network=True):
                if cancel:
                    exchange(stream, 11, {'handle': handle, 'budget_ms': 1000}, 13)
                try:
                    state = INSTALL['terminal'](stream, handle)
                except RuntimeError:
                    cases['blocked_handle'] = handle
                    cases['active_at_failure'] = inspect()['active_workloads']
                    exchange(stream, 11, {'handle': handle, 'budget_ms': 1000}, 13)
                    cases['terminal_after_failure'] = INSTALL['terminal'](stream, handle)
                    raise
                if (state['cleanup'] != 'complete'
                        or state['network_cleanup'] != ('complete' if network else 'not_applicable')
                        or 'network_address' in state):
                    raise RuntimeError(f'guest teardown was not confirmed: {state}')
                return state

            argv = ['/bin/sh', '-c', 'exec /bin/busybox nc -l -p 8080 -e /bin/sh -c '
                                     '\'printf "HTTP/1.1 200 OK\\r\\nContent-Length: 16\\r\\n'
                                     'Connection: close\\r\\n\\r\\nprivate-oci-http"\'']
            service = launch(argv, 'service')
            cases['server'] = running(service)
            cases['duplicate_alias'] = launch(['/bin/true'], 'SeRvIcE', 'unsupported_option')
            cases['invalid_alias'] = launch(['/bin/true'], '../bad', 'unsupported_option')
            client_command = ['/bin/busybox', 'wget', '-O-', 'http://SeRvIcE:8080/proof']
            isolated_url = f'http://{cases["server"]["network_address"]}:8080/proof'
            isolated_command = ['/bin/busybox', 'wget', '-O-', isolated_url]
            cases['isolated'] = finish(launch(isolated_command), network=False)
            isolated_output = cases['isolated']['terminal_output']
            if (cases['isolated']['exit'] == {'code': 0} or isolated_output['stdout']['data']
                    or b'Operation not permitted' not in base64.b64decode(isolated_output['stderr']['data'])):
                raise RuntimeError(f'no-network isolation check failed: {cases["isolated"]}')
            cases['lookup'] = finish(launch(['/bin/busybox', 'nslookup', 'service', '198.18.0.1'], 'lookup'))
            if cases['lookup']['exit'] != {'code': 0}:
                raise RuntimeError(f'OCI nslookup failed: {cases["lookup"]}')
            for _ in range(2):
                connected = finish(launch(client_command, 'client'))
                cases.setdefault('requests', []).append(connected)
                response = base64.b64decode(connected['terminal_output']['stdout']['data'], validate=True)
                if connected['exit'] != {'code': 0} or response != b'private-oci-http':
                    cases['server_failure'] = INSTALL['terminal'](stream, service)
                    raise RuntimeError(f'OCI DNS or TCP transaction failed: {connected}')
                cases.setdefault('server_runs', []).append(finish(service))
                service = launch(argv, 'service')
                running(service)
            cases['server_cleanup'] = finish(service, cancel=True)
            absent_command = ['/bin/busybox', 'nslookup', 'service', '198.18.0.1']
            cases['absent'] = finish(launch(absent_command, 'client'))
            absent = cases['absent']['terminal_output']
            if (cases['absent']['exit'] == {'code': 0}
                    or b'NXDOMAIN' not in base64.b64decode(absent['stdout']['data'])
                    + base64.b64decode(absent['stderr']['data'])):
                raise RuntimeError(f'removed service still resolved: {cases["absent"]}')
            cases['active_after'] = inspect()['active_workloads']
            if cases['active_after']:
                raise RuntimeError('guest bridge fixture left active native workloads')
    finally:
        (output / 'oci-bridge.json').write_text(json.dumps(cases, indent=2) + '\n')
