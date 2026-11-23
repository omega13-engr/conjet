"""Run generation, transfer and image-lifetime checks on a private OCI boot."""

import base64
from contextlib import contextmanager
import hashlib
import json
from pathlib import Path
import runpy
import socket
import time
import uuid


WIRE = runpy.run_path(str(Path(__file__).with_name('native-fresh-lifecycle.py')))


@contextmanager
def channel(session, pid):
    with socket.socket(socket.AF_UNIX) as stream:
        stream.settimeout(3)
        stream.connect(str(session / 'native-launch.sock'))
        if stream.getsockopt(0, 2) != pid:
            raise RuntimeError('native import peer identity changed')
        yield stream, WIRE['authenticate'](stream, (session / 'launch.key').read_bytes(), 'native_oci_arm64_v1')


def exchange(stream, opcode, body, kind, error=None):
    actual, reply = WIRE['call'](stream, opcode, body)
    if actual != kind or (error and reply.get('code') != error):
        raise RuntimeError(f'native import check expected {kind}/{error}, got {actual}/{reply}')
    return reply


def image(stream, boot, operation, *, error=None):
    return exchange(stream, 21, {'boot_id': boot, 'budget_ms': 1000, 'operation': operation},
                    15 if error else 21, error)


def inspect(stream):
    return exchange(stream, 20, {'budget_ms': 1000}, 20)


def preflight(session, pid, digest, output):
    report = {}
    payload = b'x'
    package_digest = 'sha256:' + hashlib.sha256(payload).hexdigest()
    transfer = uuid.uuid4().hex
    begin = {'action': 'begin', 'transfer': transfer, 'config_digest': digest,
             'package_digest': package_digest, 'size': len(payload)}
    write = {'action': 'write', 'transfer': transfer, 'offset': 0,
             'data': base64.b64encode(payload).decode()}
    with channel(session, pid) as (stream, boot):
        report['boot_id'] = boot
        report['stale_generation'] = image(stream, '0' * 32, begin, error='stale_generation')
        report['capacity'] = image(stream, boot, {**begin, 'size': 64 * 1024**2 + 1}, error='capacity')
        image(stream, boot, {**begin, 'package_digest': 'sha256:' + '0' * 64})
        report['offset'] = image(stream, boot, {**write, 'offset': 1}, error='malformed')
        image(stream, boot, write)
        report['digest'] = image(stream, boot, {'action': 'commit', 'transfer': transfer}, error='integrity')
        image(stream, boot, begin)
        image(stream, boot, write)
        with channel(session, pid) as (other, second_boot):
            if second_boot != boot:
                raise RuntimeError('guest boot changed during observed transfer')
            report['lease_busy'] = image(other, boot, begin, error='busy')
            report['foreign_lease'] = image(other, boot, {'action': 'abort', 'transfer': transfer},
                                            error='not_found')
    with channel(session, pid) as (stream, boot):
        if boot != report['boot_id']:
            raise RuntimeError('guest boot changed across reconnect')
        deadline = time.monotonic() + 2
        while True:
            kind, reply = WIRE['call'](stream, 21, {'boot_id': boot, 'budget_ms': 1000, 'operation': begin})
            if kind == 21 and reply['offset'] == 0:
                break
            if kind != 15 or reply['code'] != 'busy' or time.monotonic() >= deadline:
                raise RuntimeError(f'disconnect did not release the transfer: {reply}')
            time.sleep(0.01)
        report['aborted_retry'] = image(stream, boot, {'action': 'abort', 'transfer': transfer})
        if inspect(stream)['installed_images']:
            raise RuntimeError('partial transfer made an OCI image runnable')
    (output / 'installation-negatives.json').write_text(json.dumps(report, indent=2) + '\n')
    return report['boot_id']


def launch_request(state, image_digest, argv):
    return {'boot_id': state['boot_id'], 'sequence': state['last_sequence'] + 1,
            'operation_id': uuid.uuid4().hex, 'budget_ms': 1000,
            'spec': {'image_digest': image_digest, 'argv': argv,
                     'env': [], 'cwd': '/', 'uid': 65532, 'gid': 65532, 'network': 'none',
                     'limits': {'memory_bytes': 16777216, 'pids': 4, 'cpu_millicores': 500}}}


def launch(stream, state, image_digest, argv, error=None):
    return exchange(stream, 8, launch_request(state, image_digest, argv), 15 if error else 13, error)


def terminal(stream, handle):
    return exchange(stream, 10, {'handle': handle, 'after_revision': 2**64 - 1,
                                'budget_ms': 2500, 'terminal_output': True}, 13)


def postflight(session, pid, digest, expected_boot, output):
    with channel(session, pid) as (stream, boot):
        if boot != expected_boot:
            raise RuntimeError('native installation rebooted the guest')
        state = inspect(stream)
        if [entry['config_digest'] for entry in state['installed_images']] != [digest]:
            raise RuntimeError('installed guest image is missing or duplicated')
        original = launch(stream, state, state['image_digest'], ['/bin/true'])
        original = terminal(stream, original['handle'])
        if original['cleanup'] != 'complete' or original['exit'] != {'code': 0}:
            raise RuntimeError(f'the original boot image no longer runs: {original}')
        scopes = []
        for _ in range(2):
            imported = launch(stream, inspect(stream), digest, ['/bin/busybox', 'sleep', '30'])
            handle = imported['handle']
            deadline = time.monotonic() + 2
            while True:
                active = exchange(stream, 19, {'budget_ms': 1000, 'boot_id': boot}, 19)['active']
                if active and active['sample_valid'] and active['populated'] and active['paths']['overlay_present']:
                    break
                if time.monotonic() >= deadline:
                    raise RuntimeError('populated OCI cgroup or overlay was not observed')
                time.sleep(0.01)
            if not all(str(value).endswith(handle['workload_id'])
                       for key, value in active['paths'].items() if key != 'overlay_present'):
                raise RuntimeError('active OCI paths are not qualified by the workload ID')
            scopes.append(active)
            removal = image(stream, boot, {'action': 'remove', 'config_digest': digest}, error='busy')
            exchange(stream, 11, {'handle': handle, 'budget_ms': 1000}, 13)
            imported = terminal(stream, handle)
            if imported['cleanup'] != 'complete':
                raise RuntimeError('cancelled imported image did not verify cleanup')
        if scopes[0]['paths'] == scopes[1]['paths']:
            raise RuntimeError('two OCI workloads acquired the same resource paths')
        failed = launch(stream, inspect(stream), digest, ['/bin/cj-not-present'])
        failed = terminal(stream, failed['handle'])
        if failed['exec'] == 'confirmed' or failed['cleanup'] != 'complete':
            raise RuntimeError('failed OCI exec did not reclaim its own paths')
        state = inspect(stream)
    result = {'boot_id': boot, 'original_boot_image': original, 'remove_while_active': removal,
              'cancelled_imported_image': imported, 'image_store': state['installed_images'],
              'active_scopes': scopes, 'failed_exec': failed}
    (output / 'installation-lifecycle.json').write_text(json.dumps(result, indent=2) + '\n')


def verify_removal(session, pid, digest, expected_boot, output):
    with channel(session, pid) as (stream, boot):
        if boot != expected_boot:
            raise RuntimeError('native image removal used a different boot')
        removed = image(stream, boot, {'action': 'remove', 'config_digest': digest})
        state = inspect(stream)
        rejected = launch(stream, state, digest, ['/bin/true'], error='unsupported_option')
        after = inspect(stream)
        if (removed['state'] != 'removed' or after['installed_images']
                or after['last_sequence'] != state['last_sequence']):
            raise RuntimeError('removed OCI image remained runnable or allocated a workload')
        original = launch(stream, after, state['image_digest'], ['/bin/true'])
        original = terminal(stream, original['handle'])
        if original['cleanup'] != 'complete' or original['exit'] != {'code': 0}:
            raise RuntimeError('the original OCI image failed after removing the imported root')
    result = {'boot_id': boot, 'removed': removed, 'rejected': rejected, 'boot_image': original}
    (output / 'installation-removal.json').write_text(json.dumps(result, indent=2) + '\n')


def verify_guest_overlap(session, pid, digest, expected_boot, output):
    samples = []
    with channel(session, pid) as (stream, boot):
        if boot != expected_boot:
            raise RuntimeError('guest concurrency checked the wrong boot')
        for count in (1, 2, 4, 8):
            requests, ownership = [], []
            for _ in range(count):
                request = launch_request(inspect(stream), digest, ['/bin/busybox', 'sleep', '30'])
                requests.append(request)
                ownership.append(exchange(stream, 8, request, 13))
            handles = [item['handle'] for item in ownership]
            ids = {handle['workload_id'] for handle in handles}
            if len(ids) != count:
                raise RuntimeError('concurrent admission reused a workload identity')
            deadline = time.monotonic() + 5
            while True:
                observed = exchange(stream, 19, {'budget_ms': 1000, 'boot_id': boot}, 19)['active_workloads']
                populated = {row['handle']['workload_id'] for row in observed
                             if row['sample_valid'] and row['populated'] and row['paths']['overlay_present']}
                if populated == ids:
                    break
                if time.monotonic() >= deadline:
                    raise RuntimeError(f'guest did not populate {count} concurrent workloads: {observed}')
                time.sleep(0.02)
            if len({row['paths']['overlay'] for row in observed}) != count:
                raise RuntimeError('overlapping OCI workloads shared a writable path')
            exhausted = None
            replay = exchange(stream, 8, requests[0], 13)
            conflict = exchange(stream, 8, {**requests[0], 'operation_id': uuid.uuid4().hex},
                                15, 'id_conflict')
            if replay['handle'] != handles[0] or inspect(stream)['last_sequence'] != requests[-1]['sequence']:
                raise RuntimeError('exact replay changed OCI admission ownership')
            if count == 8:
                state = inspect(stream)
                exhausted = launch(stream, state, digest, ['/bin/true'], error='busy')
                if inspect(stream)['last_sequence'] != state['last_sequence']:
                    raise RuntimeError('failed ninth admission reserved a sequence')
            receipts = []
            while handles:
                handle = handles.pop()
                exchange(stream, 11, {'handle': handle, 'budget_ms': 1000}, 13)
                finished = terminal(stream, handle)
                if finished['cleanup'] != 'complete':
                    raise RuntimeError('overlapping OCI workload did not verify cleanup')
                receipts.append(finished)
                if {row['handle']['workload_id'] for row in inspect(stream)['active_workloads']} != {
                        entry['workload_id'] for entry in handles}:
                    raise RuntimeError('cancellation affected another active workload')
            samples.append({'count': count, 'observed': observed, 'exhausted': exhausted,
                            'replay': replay, 'conflict': conflict, 'receipts': receipts})
    (output / 'guest-overlap.json').write_text(json.dumps(samples, indent=2) + '\n')


def verify_live_output(session, pid, digest, expected_boot, output):
    cases = {}
    try:
        with channel(session, pid) as (stream, boot):
            if boot != expected_boot:
                raise RuntimeError('live output checked the wrong guest boot')
            command = ['/bin/sh', '-c',
                       'printf live-out; printf live-err >&2; exec /bin/busybox sleep 10']
            item = launch(stream, inspect(stream), digest, command)
            handle = item['handle']

            def read(name, cursor, *, budget=1000, error=None):
                return exchange(stream, 12, {'handle': handle, 'stream': name, 'offset': cursor,
                                             'max_bytes': 8192, 'budget_ms': budget, 'follow': True},
                                15 if error else 14, error)

            for name, payload in (('stdout', b'live-out'), ('stderr', b'live-err')):
                event = read(name, 0)
                if (base64.b64decode(event['data'], validate=True) != payload or event['eof']
                        or event['dropped_bytes'] or event['next_offset'] != len(payload)):
                    raise RuntimeError(f'wrong live output on {name}: {event}')
                cases[name] = event
                cases[name + '_idle'] = read(name, event['next_offset'], budget=30,
                                             error='deadline_exceeded')
            exchange(stream, 11, {'handle': handle, 'budget_ms': 1000}, 13)
            live_terminal = terminal(stream, handle)
            if live_terminal['cleanup'] != 'complete':
                raise RuntimeError('live-output fixture did not verify guest cleanup')
            for name in ('stdout', 'stderr'):
                end = read(name, cases[name]['next_offset'])
                if not end['eof'] or end['data'] or end['dropped_bytes']:
                    raise RuntimeError(f'wrong EOF after terminal cleanup: {end}')
                cases[name + '_eof'] = end
            command = ['/bin/sh', '-c',
                       'n=0; while [ "$n" -lt 65 ]; do printf "%01024d" 0; n=$((n+1)); done']
            flood = launch(stream, inspect(stream), digest, command)
            finished = terminal(stream, flood['handle'])
            if (finished['cleanup'] != 'complete' or finished['exit'] != {'code': 0}
                    or finished['terminal_output']['stdout']['dropped_bytes'] != 1024):
                raise RuntimeError('unread bounded output did not drain or reclaim the workload')
            cases['unread_overflow'] = finished
    finally:
        (output / 'guest-live-output.json').write_text(json.dumps(cases, indent=2) + '\n')


def verify_guest_exec(session, pid, digest, expected_boot, output):
    cases = {}
    try:
        with channel(session, pid) as (stream, boot):
            if boot != expected_boot:
                raise RuntimeError('native exec used the wrong boot')
            workload = launch(stream, inspect(stream), digest, ['/bin/sh', '-c',
                'printf exec-shared >/fixture/cj-exec-proof; exec /bin/busybox sleep 20'])
            handle = workload['handle']
            deadline = time.monotonic() + 3
            while True:
                running = exchange(stream, 9, {'handle': handle, 'budget_ms': 1000}, 13)
                if running['phase'] == 'running':
                    break
                if time.monotonic() >= deadline:
                    raise RuntimeError(f'guest exec target did not reach running: {running}')
                time.sleep(0.02)
            time.sleep(0.15)

            def run(label, argv, code=0, stdout=b'', stderr=b'', *, budget=2000, error=None):
                result = exchange(stream, 22, {'handle': handle, 'budget_ms': budget, 'argv': argv},
                                  15 if error else 22, error)
                cases[label] = result
                if error is None:
                    observed = (result['exit_code'], base64.b64decode(result['stdout']['data']),
                                base64.b64decode(result['stderr']['data']))
                    if observed != (code, stdout, stderr):
                        raise RuntimeError(f'native exec {label} returned {observed!r}')

            run('shared_root', ['/bin/busybox', 'cat', '/fixture/cj-exec-proof'], stdout=b'exec-shared')
            run('identity', ['/bin/busybox', 'id', '-u'], stdout=b'65532\n')
            run('streams_and_exit', ['/bin/sh', '-c', 'printf a; printf b >&2; exit 23'],
                23, b'a', b'b')
            run('missing_target', ['/bin/cj-missing-exec'], 127)
            run('invalid_target', ['../relative'], error='invalid_spec')
            run('exec_timeout', ['/bin/busybox', 'sleep', '8'], budget=150, error='deadline_exceeded')
            run('after_failure', ['/bin/busybox', 'cat', '/fixture/cj-exec-proof'], stdout=b'exec-shared')
            exchange(stream, 11, {'handle': handle, 'budget_ms': 1000}, 13)
            if terminal(stream, handle)['cleanup'] != 'complete':
                raise RuntimeError('native exec target did not reclaim its resources')
            run('removed_target', ['/bin/true'], error='not_running')
    finally:
        (output / 'guest-exec.json').write_text(json.dumps(cases, indent=2) + '\n')
