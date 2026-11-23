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


def launch(stream, state, image_digest, argv, error=None):
    return exchange(stream, 8, {'boot_id': state['boot_id'], 'sequence': state['last_sequence'] + 1,
                               'operation_id': uuid.uuid4().hex, 'budget_ms': 1000,
                               'spec': {'image_digest': image_digest, 'argv': argv,
                                        'env': [], 'cwd': '/', 'uid': 65532, 'gid': 65532,
                                        'network': 'none',
                                        'limits': {'memory_bytes': 16777216, 'pids': 4,
                                                   'cpu_millicores': 500}}}, 15 if error else 13, error)


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
            raise RuntimeError('the original boot image no longer runs')
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
