"""Qualify Core pending watches on a private guest using periodic approval."""

import json
from pathlib import Path
import runpy
import secrets
import time


HERE = Path(__file__).parent
NATIVE = runpy.run_path(str(HERE / 'native-oci-live-install.py'))
MEMORY = runpy.run_path(str(HERE / 'native-core-memory.py'))
WIRE = NATIVE['WIRE']


def collect(session, vm_pid, output):
    report = {}
    call = NATIVE['exchange']
    channel = NATIVE['channel']
    try:
        deadline = time.monotonic() + 25
        while True:
            capacity = MEMORY['controller_snapshot'](session, vm_pid)
            if capacity['target_mib'] == 448 and capacity['target_pages'] == 409600:
                report['capacity_before_admission'] = capacity
                break
            if time.monotonic() >= deadline:
                raise RuntimeError('watch probe did not start from converged reduced capacity')
            time.sleep(0.05)

        with channel(session, vm_pid) as (control, boot):
            body = {'boot_id': boot, 'budget_ms': 30, 'core_only': True, 'watch_pending': True}
            report['old_boot'] = call(control, 19, {**body, 'boot_id': '0' * 32}, 15, 'stale_generation')
            report['bad_budget'] = call(control, 19, {**body, 'budget_ms': 31}, 15, 'malformed')
            report['invalid_scope'] = call(control, 19, {**body, 'core_only': False}, 15, 'malformed')
            report['mixed_grant'] = call(control, 19, {
                **body, 'core_grant': {'workload_id': '0' * 32, 'sequence': 1},
            }, 15, 'malformed')
            with channel(session, vm_pid) as (watcher, watch_boot), channel(session, vm_pid) as (other, _):
                if watch_boot != boot:
                    raise RuntimeError('watch and launch were authenticated to different boots')
                first, second = secrets.token_bytes(16), secrets.token_bytes(16)
                started = time.monotonic_ns()
                WIRE['send'](watcher, 19, body, first)
                WIRE['send'](other, 19, body, second)
                replies = [WIRE['receive'](watcher, first), WIRE['receive'](other, second)]
                report['idle_and_overload'] = {'replies': replies, 'elapsed_ns': time.monotonic_ns() - started}
                kinds = sorted(kind for kind, _ in replies)
                if (kinds != [15, 19] or report['idle_and_overload']['elapsed_ns'] < 20_000_000
                        or any(reply.get('code') != 'busy' if kind == 15
                               else reply['core_admission'] != {'owned': 0, 'pending': []}
                               for kind, reply in replies)):
                    raise RuntimeError('only one idle watch should block until the reconciliation timeout')

                cursor = secrets.token_bytes(16)
                WIRE['send'](watcher, 19, body, cursor)
                pending = []
                for _ in range(2):
                    state = NATIVE['inspect'](control)
                    request = NATIVE['launch_request'](state, state['image_digest'], ['/bin/true'])
                    accepted = call(control, 8, request, 13)
                    repeated = call(control, 8, request, 13)
                    if accepted['handle'] != repeated['handle']:
                        raise RuntimeError('admission replay allocated another workload')
                    pending.append((accepted['handle'], request['sequence']))
                kind, observed = WIRE['receive'](watcher, cursor)
                report['watch_before_launch'] = (kind, observed)
                first_id = pending[0][0]['workload_id']
                if kind != 19 or not any(item['workload_id'] == first_id
                                         for item in observed['core_admission']['pending']):
                    raise RuntimeError('new pending demand did not wake its armed watcher')
                joined = call(watcher, 19, body, 19)
                report['watch_after_launches'] = joined
                expected = [{'workload_id': handle['workload_id'], 'sequence': sequence}
                            for handle, sequence in pending]
                if joined['core_admission'] != {'owned': 2, 'pending': expected}:
                    raise RuntimeError('authoritative watch did not coalesce both accepted requests')

                report['cancelled'] = []
                report['late_grants'] = []
                for handle, sequence in pending:
                    call(control, 11, {'handle': handle, 'budget_ms': 1000}, 13)
                    terminal = NATIVE['terminal'](control, handle)
                    report['cancelled'].append(terminal)
                    if terminal['cleanup'] != 'complete' or terminal['exec'] != 'failed':
                        raise RuntimeError('cancelled pending workload reached exec or leaked ownership')
                    late = {'workload_id': handle['workload_id'], 'sequence': sequence}
                    report['late_grants'].append(call(control, 19, {
                        'boot_id': boot, 'budget_ms': 30, 'core_only': True, 'core_grant': late,
                    }, 15, 'not_pending'))

            with channel(session, vm_pid) as (abandoned, _):
                WIRE['send'](abandoned, 19, body, secrets.token_bytes(16))
            time.sleep(0.05)
            with channel(session, vm_pid) as (reconnected, current):
                snapshot = call(reconnected, 19, body, 19)
                report['reconnected'] = snapshot
                if current != boot or snapshot['core_admission'] != {'owned': 0, 'pending': []}:
                    raise RuntimeError('watch reconnect failed to reconcile the same empty boot')
        report['passed'] = True
    finally:
        (output / 'pending-watch.json').write_text(json.dumps(report, indent=2) + '\n')
