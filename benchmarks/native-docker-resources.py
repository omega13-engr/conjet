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
                           *flags, image, '/bin/sleep', '1800']
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
        if observe()['active_workloads']:
            raise RuntimeError('rejected resource tests entered the guest')
    finally:
        (output / 'resource-checks.json').write_text(json.dumps(records, indent=2) + '\n')
