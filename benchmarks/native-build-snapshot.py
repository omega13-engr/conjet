"""Qualify a borrowed native snapshot independently of BuildKit runtime verbs."""

import base64
import json
from pathlib import Path
import runpy
import time


NATIVE = runpy.run_path(str(Path(__file__).with_name('native-oci-live-install.py')))
BUNDLE = 'snapshotcanary'


def collect(session, vm_pid, output):
    evidence = {}
    try:
        with NATIVE['channel'](session, vm_pid) as (stream, boot):
            call = NATIVE['exchange']

            def inspect(bundle, error=None, generation=boot):
                return call(stream, 26, {'boot_id': generation, 'budget_ms': 1000,
                                         'id': bundle}, 15 if error else 26, error)

            snapshot = inspect(BUNDLE)
            evidence['snapshot'] = snapshot
            evidence['invalid_path'] = inspect('../external', 'malformed')
            evidence['symlink'] = inspect('alias', 'not_found')
            stale_boot = ('1' if boot[0] == '0' else '0') + boot[1:]
            evidence['stale_boot'] = inspect(BUNDLE, 'stale_generation', stale_boot)

            def request(mode, identity=snapshot):
                state = NATIVE['inspect'](stream)
                body = NATIVE['launch_request'](state, state['image_digest'], ['/bin/probe', mode])
                body['spec']['build_snapshot'] = identity
                return body

            stale = request('verify', {**snapshot, 'inode': snapshot['inode'] + 1})
            evidence['stale_inode'] = call(stream, 8, stale, 15, 'stale_generation')
            incompatible = request('verify')
            incompatible['spec']['volume'] = {'name': 'ordinary', 'inode': 1, 'read_only': False}
            evidence['incompatible_mount'] = call(stream, 8, incompatible, 15, 'invalid_spec')

            submitted = call(stream, 8, request('hold'), 13)
            handle = submitted['handle']
            deadline = time.monotonic() + 4
            while True:
                state = call(stream, 9, {'handle': handle, 'budget_ms': 1000}, 13)
                if state['phase'] == 'running':
                    break
                if state['cleanup'] != 'pending' or time.monotonic() >= deadline:
                    evidence['failed_state'] = state
                    evidence['failed_output'] = NATIVE['terminal'](stream, handle)
                    raise RuntimeError('borrowed snapshot workload did not begin')
                time.sleep(0.03)
            output_chunk = call(stream, 12, {'handle': handle, 'budget_ms': 1000,
                                             'stream': 'stdout', 'offset': 0, 'max_bytes': 128,
                                             'follow': True}, 14)
            if base64.b64decode(output_chunk['data']) != b'wrote snapshot\n':
                raise RuntimeError('borrowed snapshot write was not confirmed')
            evidence['busy'] = call(stream, 8, request('verify'), 15, 'busy')
            call(stream, 11, {'handle': handle, 'budget_ms': 1000, 'signal': 9}, 13)
            terminal = NATIVE['terminal'](stream, handle)
            if terminal['cleanup'] != 'complete' or terminal['build_snapshot'] != snapshot:
                raise RuntimeError('cancelled snapshot did not retain ownership through cleanup')
            evidence['cancelled'] = terminal

            reopened = call(stream, 8, request('verify'), 13)
            result = NATIVE['terminal'](stream, reopened['handle'])
            if (result['cleanup'] != 'complete' or result['build_snapshot'] != snapshot
                    or result['exit']['code'] != 0
                    or base64.b64decode(result['terminal_output']['stdout']['data'])
                    != b'persisted snapshot\n'):
                raise RuntimeError('the same snapshot did not preserve written data')
            evidence['reopened'] = result
    finally:
        (output / 'native-build-snapshot.json').write_text(json.dumps(evidence, indent=2) + '\n')
