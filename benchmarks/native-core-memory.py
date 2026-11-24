"""Check Core telemetry against a fresh native workload on its private guest."""

import hashlib
import json
from pathlib import Path
import runpy
import socket
import subprocess
import time


MATCHED = runpy.run_path(str(Path(__file__).with_name('native-docker-comparison.py')))
NATIVE = runpy.run_path(str(Path(__file__).with_name('native-oci-live-install.py')))


def check_admission_replays(session, vm_pid):
    with NATIVE['channel'](session, vm_pid) as (stream, boot):
        state = NATIVE['inspect'](stream)
        handle = state['workload']['handle']
        request = {'boot_id': boot, 'budget_ms': 1000, 'core_only': True,
                   'core_grant': {'workload_id': handle['workload_id'], 'sequence': state['last_sequence']}}
        wrong_boot = ('1' if boot[0] == '0' else '0') + boot[1:]
        call = NATIVE['exchange']
        mismatch = {**request['core_grant'], 'sequence': state['last_sequence'] + 1}
        return {
            'old_boot': call(stream, 19, {**request, 'boot_id': wrong_boot}, 15, 'stale_generation'),
            'reused_workload_id': call(stream, 19, {**request, 'core_grant': mismatch}, 15, 'stale_generation'),
            'duplicate_grant': call(stream, 19, request, 15, 'not_pending'),
        }


def check_expired_admission(session, vm_pid):
    with NATIVE['channel'](session, vm_pid) as (stream, boot):
        state = NATIVE['inspect'](stream)
        request = NATIVE['launch_request'](state, state['image_digest'], ['/bin/true'])
        # A reduced balloon cannot converge to 2 GiB in this admission budget.
        request['budget_ms'] = 10
        call = NATIVE['exchange']
        submitted = call(stream, 8, request, 13)
        terminal = NATIVE['terminal'](stream, submitted['handle'])
        if (terminal['exec'] != 'failed' or terminal['exit'] is not None
                or terminal['cleanup'] != 'complete'):
            raise RuntimeError('expired admission executed or retained guest resources')
        report = call(stream, 19, {'boot_id': boot, 'budget_ms': 1000, 'core_only': True}, 19)
        if report['core_admission'] != {'owned': 0, 'pending': []}:
            raise RuntimeError('expired request remained in the Core ownership ledger')
        return terminal


def collect(endpoint, owner_pid, session, vm_pid, output):
    api = MATCHED['TOOLS']['api']
    connection = MATCHED['TOOLS']['UnixHTTP']
    docker = connection(endpoint, owner_pid)
    memory = connection(session / 'memory.sock', vm_pid)
    prefix = MATCHED['PREFIX']
    name = 'cjdiag-core-memory'
    container = prefix + '/containers/' + name
    evidence = {}

    def sample(label, active):
        metrics = api(memory, 'GET', '/conjet-memory-metrics', (200,))
        evidence[label] = metrics
        if (not metrics['mem_available_known'] or metrics['mem_available'] <= 0
                or not metrics['service_cgroup_telemetry_complete']
                or metrics['service_cgroup_cgroup_id'] <= 0
                or not metrics['daemon_cgroup_populated']
                or metrics['active_workloads'] != active
                or bool(metrics['container_memory_current']) != bool(active)):
            raise RuntimeError(f'unexpected {label} native Core telemetry')
        return metrics['service_cgroup_cgroup_id']

    try:
        initial_service = sample('idle', 0)
        api(docker, 'POST', prefix + '/containers/create?name=' + name, (201,), {
            'Image': MATCHED['IMAGE']['ref'], 'User': MATCHED['USER'],
            'Cmd': ['/bin/busybox', 'sleep', '30'], 'HostConfig': MATCHED['HOST_CONFIG'],
        })
        api(docker, 'POST', container + '/start', (204,))
        active_service = sample('active', 1)
        api(docker, 'DELETE', container + '?force=true', (204,))
        removed_service = sample('removed', 0)
        if not initial_service == active_service == removed_service:
            raise RuntimeError('service cgroup identity changed during a container lifecycle')
        if (session / 'unused.sock').exists():
            raise RuntimeError('native session exposed a retained Docker bridge')
    finally:
        docker.close()
        memory.close()
        (output / 'native-memory-telemetry.json').write_text(json.dumps(evidence, indent=2) + '\n')


def check_growth(endpoint, owner_pid, session, vm_pid, output, client, env):
    api = MATCHED['TOOLS']['api']
    docker = MATCHED['TOOLS']['UnixHTTP'](endpoint, owner_pid)
    memory = MATCHED['TOOLS']['UnixHTTP'](session / 'memory.sock', vm_pid)
    prefix = MATCHED['PREFIX']
    name = 'cjdiag-memory-canary'
    container = prefix + '/containers/' + name
    sample_path = session / 'memory-control.sock'
    outcome = {}
    started = time.monotonic()

    def sample(label, log):
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as channel:
            channel.settimeout(3)
            channel.connect(str(sample_path))
            if channel.getsockopt(0, 2) != vm_pid:
                raise RuntimeError('Core memory controller peer PID changed')
            channel.sendall(b'{"command":"metrics"}\n')
            with channel.makefile('rb') as reply:
                metrics = json.loads(reply.readline(65536))
        log.write(json.dumps({'stage': label, 'elapsed_seconds': time.monotonic() - started,
                              'metrics': metrics}) + '\n')
        log.flush()
        if (not metrics['ok'] or not metrics['core_memory']['enabled']
                or not metrics['memory_ledger']['ok'] or metrics['balloon']['reclaim_failures']):
            raise RuntimeError('Core policy or backing ledger failed verification')
        return metrics

    def wait(label, log, predicate, seconds):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            metrics = sample(label, log)
            if predicate(metrics):
                outcome[label] = metrics
                return metrics
            time.sleep(0.15)
        raise RuntimeError(f'Core memory did not reach {label} in {seconds} seconds')

    def reduced(metrics):
        return (metrics['target_mib'] == metrics['core_memory']['idle_target_mib']
                < metrics['configured_mib'] and metrics['target_pages'] > 0
                and metrics['balloon']['actual_pages'] == metrics['target_pages']
                and metrics['balloon']['balloon_owned_reclaimed_bytes'] > 0
                and metrics['memory_ledger']['balloon_owned_bytes'] > 0)

    def expanded(metrics):
        return (metrics['target_mib'] == metrics['configured_mib'] and metrics['target_pages'] == 0
                and metrics['balloon']['actual_pages'] == 0
                and metrics['memory_ledger']['balloon_owned_bytes'] == 0
                and metrics['core_memory']['workload_expansions'] > 0)

    handles = set()
    blocks = 4096
    pattern = b'0' * 1023 + b'1'
    digest = hashlib.sha256(pattern * blocks).hexdigest()
    path = '/tmp/conjet-memory-canary'
    command = (f'n=0; while [ "$n" -lt {blocks} ]; do printf "%01024d" 1; n=$((n+1)); '
               f'done >{path}; printf ready; exec /bin/busybox sleep 8')
    expected = f'{digest}  {path}\n'.encode()
    try:
        with (output / 'native-core-memory.jsonl').open('x') as log:
            outcome['boot'] = sample('boot', log)
            wait('initial_reduced', log, reduced, 25)
            api(docker, 'POST', prefix + '/containers/create?name=' + name, (201,), {
                'Image': MATCHED['IMAGE']['ref'], 'User': MATCHED['USER'],
                'Cmd': ['/bin/sh', '-ec', command], 'HostConfig': MATCHED['HOST_CONFIG'],
            })
            api(docker, 'POST', container + '/start', (204,))
            wait('expanded', log, expanded, 8)
            deadline = time.monotonic() + 2
            while True:
                outcome['guest_during'] = api(memory, 'GET', '/conjet-memory-metrics', (200,))
                if outcome['guest_during']['active_workloads'] == 1 or time.monotonic() >= deadline:
                    break
                time.sleep(0.05)
            if outcome['guest_during']['active_workloads'] != 1:
                outcome['canary_inspect'] = api(docker, 'GET', container + '/json', (200,))['State']
                diagnostic = subprocess.run([*client, 'logs', name], env=env, capture_output=True,
                                            timeout=3, text=True)
                outcome['canary_log'] = {'exit': diagnostic.returncode,
                                         'stdout': diagnostic.stdout, 'stderr': diagnostic.stderr}
                raise RuntimeError('memory canary did not own a live guest cgroup after growth')
            outcome['grant_replays'] = check_admission_replays(session, vm_pid)
            checksum = [*client, 'exec', name, '/bin/busybox', 'sha256sum', path]
            deadline = time.monotonic() + 3
            while True:
                result = subprocess.run(checksum, env=env, capture_output=True, timeout=3)
                if (result.returncode, result.stdout, result.stderr) == (0, expected, b''):
                    break
                if time.monotonic() >= deadline:
                    raise RuntimeError('the active canary did not write the expected bytes')
                time.sleep(0.05)
            for index in range(12):
                churn = f'cjdiag-memory-churn-{index}'
                MATCHED['lifecycle'](docker, churn, {})
                MATCHED['native_terminal'](docker, churn, handles)
                if not expanded(sample('churn', log)):
                    raise RuntimeError('capacity left the configured target during launch churn')
            MATCHED['invoke'](client, env, ['exec', name, '/bin/busybox', 'sha256sum', path],
                              stdout=expected)
            result = api(docker, 'POST', container + '/wait?condition=not-running', (200,))
            if result != {'StatusCode': 0, 'Error': None}:
                raise RuntimeError(f'memory workload failed: {result}')
            MATCHED['invoke'](client, env, ['logs', name], stdout=b'ready')
            api(docker, 'DELETE', container, (204,))
            outcome['canary_witness'] = MATCHED['native_terminal'](docker, name, handles)
            outcome['expected_sha256'] = digest
            wait('post_workload_reduced', log, reduced, 25)
            outcome['expired_admission'] = check_expired_admission(session, vm_pid)
    finally:
        docker.close()
        memory.close()
        (output / 'native-core-memory-summary.json').write_text(json.dumps(outcome, indent=2) + '\n')
