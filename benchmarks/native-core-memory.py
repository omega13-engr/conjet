"""Check Core telemetry against a fresh native workload on its private guest."""

import json
from pathlib import Path
import runpy


MATCHED = runpy.run_path(str(Path(__file__).with_name('native-docker-comparison.py')))


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
