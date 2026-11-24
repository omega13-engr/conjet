"""Verify Docker resource values against the native workload's actual cgroup."""

from contextlib import closing
import json
from pathlib import Path
import runpy
import subprocess
import time


HERE = Path(__file__).resolve().parent
MATCHED = runpy.run_path(str(HERE / 'native-docker-comparison.py'))
GUEST = runpy.run_path(str(HERE / 'native-oci-live-install.py'))
FROZEN = json.loads((HERE / 'scenarios/docker-comparison-v1.json').read_text())


def collect(endpoint, peer, docker, env, output, session, vm_pid):
    records = {}

    def call(args, expected=0):
        result = subprocess.run([*docker, *args], env=env, capture_output=True, text=True, timeout=12)
        if result.returncode != expected:
            raise RuntimeError(f'Docker resource check {args} returned {result.returncode}: {result.stderr}')
        return result.stdout

    def observe():
        with GUEST['channel'](session, vm_pid) as (guest, boot):
            return GUEST['exchange'](guest, 19, {'boot_id': boot, 'budget_ms': 1000}, 19)

    try:
        cases = [
            ('defaults', [], (0, 0, 0), ('max', 'max', 'max 100000')),
            ('partial', ['--memory', '32m', '--pids-limit', '-1'],
             (32 * 1024**2, -1, 0), ('33554432', 'max', 'max 100000')),
        ]
        for name in ('lifecycle', 'service'):
            spec = FROZEN[f'{name}_limits']
            memory, pids, cpu = spec['memory_bytes'], spec['pids'], spec['cpu_millicores']
            cases.append((name,
                          ['--memory', str(memory), '--pids-limit', str(pids), '--cpus', str(cpu / 1000)],
                          (memory, pids, cpu * 1_000_000), (str(memory), str(pids), f'{cpu * 100} 100000')))
        image = FROZEN['images']['alpine']['ref']
        with closing(MATCHED['TOOLS']['UnixHTTP'](endpoint, peer)) as connection:
            for case, flags, requested, limits in cases:
                name = 'cj-resource-' + case
                request = ['run', '-d', '--network', 'none', '--pull', 'never', '--name', name,
                           *flags, image, 'sleep', '1800']
                call(request)
                record = records[case] = {'argv': request}
                try:
                    deadline = time.monotonic() + 3
                    while time.monotonic() < deadline:
                        active = observe()['active_workloads']
                        if (len(active) == 1 and active[0]['phase'] == 'running'
                                and active[0].get('effective_limits')):
                            break
                        time.sleep(0.025)
                    else:
                        raise RuntimeError(f'{case} never acquired an observable running cgroup')
                    record['guest'] = active[0]
                    config = json.loads(call(['inspect', name]))[0]['HostConfig']
                    record['host_limits'] = [config[key] for key in ('Memory', 'PidsLimit', 'NanoCpus')]
                    effective = active[0]['effective_limits']
                    if (tuple(record['host_limits']) != requested
                            or tuple(effective[key] for key in ('memory_max', 'pids_max', 'cpu_max')) != limits):
                        raise RuntimeError(f'{case} reported resource policy differs from the kernel')
                finally:
                    call(['rm', '--force', name])
                record['cleanup'] = MATCHED['native_terminal'](connection, name, set(), code=137)
                if observe()['active_workloads']:
                    raise RuntimeError('removed resource test still owns a guest cgroup')
        call(['create', '--network', 'none', '--memory', '257m', image, '/bin/true'], expected=1)
        call(['create', '--network', 'none', '--pids-limit', '65', image, '/bin/true'], expected=1)
        call(['create', '--network', 'none', image, 'bin/sleep', '1800'], expected=1)
        if observe()['active_workloads']:
            raise RuntimeError('rejected resource tests entered the guest')
    finally:
        (output / 'resource-checks.json').write_text(json.dumps(records, indent=2) + '\n')


def collect_sustained(endpoint, peer, docker, env, output, session, vm_pid):
    name = 'cj-sustained-service'
    image = FROZEN['images']['alpine']['ref']
    report = {'commands': {}}

    def call(label, *args):
        result = subprocess.run([*docker, *args], env=env, capture_output=True, text=True, timeout=12)
        report['commands'][label] = {'argv': args, 'exit': result.returncode,
                                     'stdout': result.stdout, 'stderr': result.stderr}
        if result.returncode:
            raise RuntimeError(f'{label} failed: {result.stderr}')
        return result.stdout

    def snapshot():
        with GUEST['channel'](session, vm_pid) as (guest, _boot):
            return GUEST['inspect'](guest)['active_workloads']

    try:
        started = time.monotonic()
        limits = FROZEN['lifecycle_limits']
        call('start', 'run', '--detach', '--name', name, '--network', 'none', '--pull', 'never',
             '--memory', str(limits['memory_bytes']), '--pids-limit', str(limits['pids']),
             '--cpus', str(limits['cpu_millicores'] / 1000), image,
             '/bin/sh', '-c', "printf 'sustained\n' >/tmp/marker; printf 'ready\n'; exec /bin/sleep 1800")
        try:
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                active = snapshot()
                if len(active) == 1 and active[0]['phase'] == 'running':
                    break
                time.sleep(0.025)
            else:
                raise RuntimeError('the service never entered its running guest generation')
            report['before'] = active[0]
            if call('initial_data', 'exec', name, '/bin/cat', '/tmp/marker') != 'sustained\n':
                raise RuntimeError('the initial service data differs')
            while time.monotonic() - started < 36:
                time.sleep(0.1)
            report['elapsed_seconds'] = time.monotonic() - started
            report['after'] = snapshot()
            if (len(report['after']) != 1 or report['after'][0]['phase'] != 'running'
                    or report['after'][0]['handle'] != active[0]['handle']):
                raise RuntimeError('the original guest generation stopped before the service check')
            if call('late_data', 'exec', name, '/bin/cat', '/tmp/marker') != 'sustained\n':
                raise RuntimeError('the late service data differs')
            if call('late_logs', 'logs', name) != 'ready\n':
                raise RuntimeError('the service logs differ after the former timeout')
        finally:
            call('cancel', 'rm', '--force', name)
        with closing(MATCHED['TOOLS']['UnixHTTP'](endpoint, peer)) as connection:
            report['cleanup'] = MATCHED['native_terminal'](connection, name, set(), code=137)
        report['remaining'] = snapshot()
        if report['remaining']:
            raise RuntimeError('the canceled service still owns guest resources')
    finally:
        (output / 'sustained-service.json').write_text(json.dumps(report, indent=2) + '\n')
