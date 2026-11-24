"""Evaluate frozen native coverage against matching release preflight and canary reports."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import runpy
import sys

HERE = Path(__file__).resolve().parent
PREFLIGHT = runpy.run_path(str(HERE / 'native-compatibility-preflight.py'))
SCRATCH = Path('/Volumes/ExternalSSD/dev_workspace/tmp')
MATRIX = ('lifecycle', 'images', 'builds', 'compose', 'control', 'storage_network', 'stress')


def read(directory, name):
    path = directory / name
    return json.loads(path.read_text()) if path.is_file() else {}


def lifecycle_failure(series, report, budget):
    if report.get('error'):
        return report['error']
    if report.get('recovered_containers') != []:
        return 'the frozen lifecycle runner did not verify its owned inventory'
    warmups, samples = series.get('warmups', []), series.get('samples', [])
    if len(warmups) != budget['warmups'] or len(samples) != budget['samples_per_session']:
        return 'the complete frozen lifecycle sample counts did not run'
    handles = set()
    for row in warmups + samples:
        if row.get('error') or row.get('cleanup_error'):
            return row.get('error') or row['cleanup_error']
        witness = row.get('guest_witness', {})
        handle = witness.get('conjet.native_handle')
        if (witness.get('conjet.backend') != 'jetstream-native-oci'
                or witness.get('conjet.guest_cleanup') != 'complete'
                or witness.get('exitCode') != str(row.get('exit_code'))
                or not handle or handle in handles):
            return 'a frozen lifecycle row lacks a unique native teardown witness'
        handles.add(handle)
    return None


def control_cases(report, budget):
    def succeeded(names, phases):
        counts = {'sample': budget['samples_per_session'], 'warmup': budget['warmups']}
        for name in names:
            rows = [row for row in report.get('operations', []) if row['scenario'] == name]
            if (not rows or any(row.get('error') is not None for row in rows)
                    or {row['phase'] for row in rows} != set(phases)
                    or any(sum(row['phase'] == phase for row in rows) != counts.get(phase, 1)
                           for phase in phases)):
                return False
        return True

    def destruction(events, ident, code, handle_set):
        if (not re.fullmatch(r'[0-9a-f]{12,64}', ident)
                or [event.get('Action') for event in events][-2:] != ['die', 'destroy']
                or any(event.get('Actor', {}).get('ID') != ident for event in events)):
            return False
        attributes = events[-2]['Actor'].get('Attributes', {})
        handle = attributes.get('conjet.native_handle', '')
        if (attributes.get('conjet.backend') != 'jetstream-native-oci'
                or attributes.get('conjet.guest_cleanup') != 'complete'
                or attributes.get('exitCode') != str(code)
                or not re.fullmatch(r'[0-9a-f]{32}', handle)
                or handle in handle_set):
            return False
        handle_set.add(handle)
        return True

    def identities(ident):
        for row in report['operations']:
            try:
                if row['scenario'] == 'inspect.one':
                    [state] = json.loads(row['stdout'])
                    if state['Id'] != ident or state['State']['Running'] is not True:
                        return False
                if (row['scenario'] == 'list.one'
                        and row['stdout'].splitlines() not in ([ident[:12]], [ident])):
                    return False
            except (ValueError, KeyError, TypeError):
                return False
        return True

    def attached(handles):
        identities = set()
        for row in report['operations']:
            if row['scenario'] != 'events.lifecycle':
                continue
            try:
                events = [json.loads(line) for line in row['stdout'].splitlines()]
                ident = next(arg.removeprefix('container=') for arg in row['argv']
                             if arg.startswith('container='))
                if ident in identities or not destruction(events, ident, 23, handles):
                    return False
            except (ValueError, KeyError, TypeError, StopIteration):
                return False
            identities.add(ident)
        return True

    handles = set()
    ident = report.get('persistent_id', '')
    if (report.get('error') or not destruction(report.get('persistent_events', []), ident, 137, handles)
            or not succeeded(('control-remove', 'fixture-leak-inventory'), ('cleanup',))):
        return []
    phase = ('warmup', 'sample')
    results = []
    if succeeded(('exec.streams', 'exec.api'), phase):
        results.append('exec')
    for name, operation in (('exec-large', 'exec.large-output'), ('exec-tty', 'exec.tty')):
        if succeeded((operation,), ('verification',)):
            results.append(name)
    if succeeded(('inspect.api', 'inspect.one', 'list.one'), phase) and identities(ident):
        results.append('inspect-list')
    if (succeeded(('attach.stdin-streams', 'logs.streams', 'events.lifecycle'), phase)
            and succeeded(('attach.disconnect', 'attach.disconnect-recovery'), ('verification',))
            and attached(handles)):
        results.append('attach')
    if succeeded(tuple(f'cp.{action}.{size}' for action in ('in', 'out') for size in (4096, 8388608)), phase):
        results.append('cp')
    return results


def storage_cases(report, budget):
    # The frozen program fills 16 MiB with 0x43 and replaces 128 blocks.
    trace = '7c04e324992d8c145ffa8101dea3c2799cda7ab8cbc4421c6b2f03239d5dbb9b'
    expected = budget['warmups'] + budget['samples_per_session']
    handles = set()

    def operations(name):
        return [row for row in report.get('operations', []) if row['scenario'] == name]

    def verified(name, *, readback=False, bind=False):
        rows = operations(name)
        if len(rows) != expected:
            return False
        phases = {phase: sum(row['phase'] == phase for row in rows)
                  for phase in ('warmup', 'sample', 'verification')}
        if phases != ({
            'warmup': 0, 'sample': 0, 'verification': expected,
        } if readback else {
            'warmup': budget['warmups'], 'sample': budget['samples_per_session'], 'verification': 0,
        }):
            return False
        for row in rows:
            witness = row.get('guest_witness', {})
            handle = witness.get('conjet.native_handle', '')
            if (row.get('error') is not None or row.get('exit_code') != 0
                    or witness.get('conjet.backend') != 'jetstream-native-oci'
                    or witness.get('conjet.guest_cleanup') != 'complete'
                    or witness.get('exitCode') != '0' or not re.fullmatch(r'[0-9a-f]{32}', handle)
                    or handle in handles):
                return False
            handles.add(handle)
            if readback:
                if row.get('stdout') != trace + '\n':
                    return False
            else:
                data = row.get('guest', {})
                if data.get('bytes') != 16 * 1024 * 1024 or data.get('trace') != trace:
                    return False
            if bind and (witness.get('conjet.bind_cleanup') != 'complete' or row.get('host_sha256') != trace):
                return False
        return True

    inventory = operations('fixture-leak-inventory')
    if (report.get('error') or len(inventory) != 1 or inventory[0].get('error') is not None
            or inventory[0].get('stdout') != ''):
        return []
    results = []
    if verified('storage.writable-layer'):
        results.append('writable-layer')
    if (verified('storage.volume') and verified('storage.volume.readback', readback=True)
            and all(len(operations(name)) == expected and
                    all(row.get('error') is None and row.get('exit_code') == 0 for row in operations(name))
                    for name in ('volume-create', 'volume-remove'))):
        results.append('named-volume')
    if verified('storage.bind', bind=True):
        results.append('bind')
    if sustained_service(report, budget):
        results.append('service')
    return results


def sustained_service(report, budget):
    rows = report.get('operations', [])
    service = [row for row in rows if row['scenario'].startswith('service')]
    if (report.get('error') or report.get('service_limits_matched') is not True
            or any(row.get('error') is not None for row in service)
            or report.get('windows_ns', {}).get('service.transaction', 0)
               < budget['steady_state_seconds'] * 1_000_000_000):
        return False
    for stage in ('dns', 'tcp_connect', 'redis_ping'):
        selected = [row for row in service if row['scenario'] == 'service.guest.' + stage]
        if (len(selected) != budget['samples_per_session'] + budget['warmups']
                or sum(row['phase'] == 'warmup' for row in selected) != budget['warmups']
                or any(row.get('elapsed_ns', 0) <= 0 for row in selected)):
            return False
    visits = [row.get('visits') for row in service if row['scenario'] == 'service.transaction']
    if not visits or visits != list(range(1, len(visits) + 1)):
        return False
    stats = [row for row in service if row['scenario'] == 'service-snapshot-stats']
    removed = [row for row in service if row['scenario'] == 'service-remove']
    if not all(len(matches) == 1 and matches[0].get('exit_code') == 0 for matches in (stats, removed)):
        return False
    try:
        metrics = [json.loads(line) for line in stats[0]['stdout'].splitlines()]
        return (len(metrics) == 2 and len({entry['Container'] for entry in metrics}) == 2
                and all(int(entry['PIDs']) > 0 and entry['MemUsage'].endswith(' / 128MiB')
                        and re.fullmatch(r'[0-9]+\.[0-9]{2}%', entry['CPUPerc']) for entry in metrics))
    except (ValueError, KeyError, TypeError):
        return False


def compose_cases(report, budget):
    if report.get('error'):
        return []
    projects = []
    group = []
    for row in report.get('operations', []):
        group.append(row)
        if row['scenario'] == 'compose-cleanup-networks':
            projects.append(group)
            group = []
    warmups = budget['warmups']
    if len(projects) != budget['samples_per_session'] + warmups:
        return []

    def operation(group, name):
        matches = [row for row in group if row['scenario'] == name]
        if len(matches) != 1 or matches[0].get('error') is not None:
            return None
        return matches[0]

    def cleanup(group):
        return all((row := operation(group, f'compose-cleanup-{kind}'))
                   and row.get('stdout') == ''
                   for kind in ('containers', 'volumes', 'networks'))

    def successful(group, phase, case, visits):
        row = operation(group, 'compose.' + case)
        if row is None or row.get('phase') != phase or row.get('exit_code') != 0:
            return False
        if case == 'scale' and row.get('dns_witness') is not True:
            return False
        if case == 'up':
            status = operation(row.get('witness', []), 'compose-redis-process')
            if status is None or status.get('exit_code') != 0:
                return False
            if not all(operation(group, f'service.{name}.cgroup') for name in ('app', 'redis')):
                return False
        if case == 'restart':
            ready = [sample for sample in group if sample['scenario'] == 'compose.restart-ready']
            if len(ready) != 2 or any(observed.get('error') is not None for observed in ready):
                return False
        return all(any(sample['scenario'] == 'compose.transaction'
                       and sample.get('visits') == expected and sample.get('error') is None
                       for sample in group) for expected in visits)

    cases = {
        'up': [1], 'no-change': [2], 'recreate': [3], 'scale': [4, 5], 'restart': [6, 7],
    }
    results = [
        case for case, visits in cases.items()
        if all(cleanup(rows) and successful(rows, 'warmup' if i < warmups else 'sample', case, visits)
               for i, rows in enumerate(projects))
    ]
    if all(cleanup(rows) and operation(rows, 'compose.down')
           and (logs := operation(rows, 'compose-logs'))
           and 'Ready to accept connections' in logs.get('stdout', '') for rows in projects):
        results.append('logs-down')
    return results


def stress_oom(report):
    rows = report.get('operations', [])
    pressure = [row for row in rows if row['scenario'].startswith('pressure-')]
    if report.get('error') or not pressure or any(row.get('error') is not None for row in pressure):
        return False
    outputs = {
        'pressure-guest-limits': '67108864 0\n',
        'pressure-oom-exit': '137\n',
        'pressure-oom-inspect': 'true\n',
        'pressure-survivor-before': 'active-before-oom',
        'pressure-survivor-after': 'active-before-oom',
        'pressure-recovery': 'pressure-recovered\n',
        'fixture-leak-inventory': '',
    }
    for name, expected in outputs.items():
        matching = [row for row in rows if row['scenario'] == name]
        if not matching or matching[-1].get('error') is not None or matching[-1].get('stdout') != expected:
            return False
    handles = set()
    for name, code in (('pressure-target-remove', '137'), ('pressure-survivor-remove', '137'),
                       ('pressure-recovery', '0')):
        matching = [row for row in pressure if row['scenario'] == name]
        if len(matching) != 1 or matching[0].get('exit_code') != 0:
            return False
        witness = matching[0].get('guest_witness', {})
        handle = witness.get('conjet.native_handle', '')
        if (witness.get('conjet.backend') != 'jetstream-native-oci'
                or witness.get('conjet.guest_cleanup') != 'complete' or witness.get('exitCode') != code
                or not re.fullmatch(r'[0-9a-f]{32}', handle) or handle in handles):
            return False
        handles.add(handle)
    return True


def stress_cancellation(report, concurrency):
    data = report.get('cancellation', {})
    cancelled, survivor = data.get('cancelled', []), data.get('survivor', '')
    if (data.get('error') or len(cancelled) != concurrency - 1
            or len(set([*cancelled, survivor])) != concurrency
            or any(not re.fullmatch(r'[0-9a-f]{64}', ident) for ident in [*cancelled, survivor])):
        return False
    rows = data.get('operations', [])
    if any(row.get('error') is not None or row.get('exit_code') != 0 for row in rows):
        return False
    operations = {row['scenario']: row.get('stdout') for row in rows if row['scenario'] != 'create'}
    content = 'active-data-through-cancellation'
    digest = hashlib.sha256(content.encode()).hexdigest()
    if (data.get('data_sha256') != digest or operations.get('inventory') != ''
            or operations.get('all-running') != ''.join(f'{ident} true\n' for ident in [survivor, *cancelled])
            or operations.get('survivor-running') != f'{survivor} true\n'
            or operations.get('survivor-before') != content
            or operations.get('survivor-after') != operations['survivor-before']
            or operations.get('cancelled-exits') != '137\n' * len(cancelled)
            or operations.get('recovery') != 'cancellation-recovered\n'):
        return False
    events = {}
    for event in data.get('events', []):
        events.setdefault(event['Actor']['ID'], []).append(event)
    recovery = set(events) - {*cancelled, survivor}
    if len(recovery) != 1 or set(events) != {*cancelled, survivor, *recovery}:
        return False
    handles = set()
    for ident, chain in events.items():
        if [event['Action'] for event in chain][-2:] != ['die', 'destroy']:
            return False
        died = chain[-2]['Actor']['Attributes']
        handle = died.get('conjet.native_handle', '')
        if (died.get('conjet.backend') != 'jetstream-native-oci'
                or died.get('conjet.guest_cleanup') != 'complete'
                or not re.fullmatch(r'[0-9a-f]{32}', handle) or handle in handles
                or (ident in recovery and (died.get('name') != data.get('recovery_name')
                                           or died.get('exitCode') != '0'))
                or (ident not in recovery and died.get('exitCode') != '137')):
            return False
        handles.add(handle)
    return True


def image_cases(report, budget):
    rows = report.get('operations', [])
    samples = budget['samples_per_session']
    warmups = budget['warmups']

    def completed(name, count, phases=False):
        items = [row for row in rows if row['scenario'] == name]
        return (len(items) == count and all(row.get('error') is None and row.get('exit_code') == 0
                                           for row in items)
                and (not phases or sum(row['phase'] == 'warmup' for row in items) == warmups))

    archive = ['alpine', 'node']
    public_pulls = all(completed(f'{image}.public-pull', 1)
                       and completed(f'{image}.cached-public-pull', samples + warmups, True)
                       for image in archive) and completed('registry-prepull', 1)
    cases = []
    if public_pulls:
        cases.append('public-pull')
    if completed('fixture-tag', 2 * (samples + warmups)):
        cases.append('tag')
    if all(completed(f'{image}.{step}', samples + warmups, True)
           for image in archive for step in ('save', 'remove-tag', 'warm-load', 'ready-to-run')):
        archives = [row for row in rows if row['scenario'].endswith('.save')]
        if all(row.get('bytes', 0) > 0 and re.fullmatch(r'[0-9a-f]{64}', row.get('sha256', ''))
               for row in archives):
            cases.append('save-load')
    return cases


def controlled_registry_cases(report, budget):
    operations = report.get('operations', [])
    rows = [row for row in operations if row['scenario'].startswith('registry')]
    if report.get('error') or any(row.get('error') is not None for row in rows):
        return []
    counts = budget['samples_per_session'] + budget['warmups']
    for name in ('registry-fixture-remove', 'registry-run-proof'):
        witnesses = [row for row in rows if row['scenario'] == name]
        if len(witnesses) != 2 * counts or any(row.get('exit_code') != 0 for row in witnesses):
            return []
    executions = [row.get('guest_witness', {}) for row in rows if row['scenario'] == 'registry-run-proof']
    handles = [witness.get('conjet.native_handle', '') for witness in executions]
    if (len(set(handles)) != len(handles)
            or any(not re.fullmatch(r'[0-9a-f]{32}', handle) for handle in handles)
            or any(witness.get('conjet.guest_cleanup') != 'complete'
                   or witness.get('conjet.backend') != 'jetstream-native-oci'
                   or witness.get('exitCode') != '0' for witness in executions)):
        return []
    cleanup = [row for row in rows if row['scenario'] == 'registry-container-inventory']
    if (len(cleanup) != 1 or cleanup[0].get('stdout') != ''
            or sum(row['scenario'] == 'registry-volume-remove' for row in rows) != 1):
        return []
    results = []
    for case, operation, witness in (
        ('registry-cold', 'first-pull', lambda row: row.get('cache_state') == 'complete config and layer transfer observed'),
        ('registry-warm', 'cached', lambda row: row.get('no_registry_get') is True),
    ):
        groups = [[row for row in rows if row['scenario'] == f'registry.{name}.{operation}']
                  for name in ('small', 'multilayer')]
        if all(len(group) == counts
               and sum(row['phase'] == 'warmup' for row in group) == budget['warmups']
               and all(row.get('exit_code') == 0 and witness(row) for row in group)
               for group in groups):
            results.append(case)
    return results


def build_cases(report, budget, images):
    if report.get('error') or report.get('input_source'):
        return []
    rows = report.get('operations', [])
    inventories = [row for row in rows if row['scenario'] == 'fixture-leak-inventory']
    if (len(inventories) != 1 or inventories[0].get('error') is not None
            or inventories[0].get('stdout') != ''):
        return []

    def clean(state):
        return (state.get('phase') == 'removed' and state.get('cleanup') == 'complete'
                and state.get('helper_failed') is False)

    def handle_id(handle):
        return (handle.get('boot_id', ''), handle.get('workload_id', ''))

    def valid_handle(handle):
        return all(re.fullmatch(r'[0-9a-f]{32}', value) for value in handle)

    builders = {}
    current = None
    for row in rows:
        scenario = row['scenario']
        if scenario == 'builder-create':
            name = row['argv'][row['argv'].index('--name') + 1]
            language = name.rsplit('-', 2)[-2]
            current = {}
            builders.setdefault(language, []).append(current)
        if current is not None:
            current.setdefault(scenario, []).append(row)
        if scenario == 'builder-remove':
            current = None

    def operation(builder, name):
        operations = builder.get(name, [])
        if len(operations) != 1 or operations[0].get('error') is not None:
            return {}
        return operations[0]

    def worker_handle(builder):
        backing = operation(builder, 'builder-backing').get('worker', {})
        handle = handle_id(backing.get('handle', {}))
        terminal = operation(builder, 'builder-remove').get('native_worker', {})
        bootstrap = operation(builder, 'builder-bootstrap').get('stdout', '')
        mounts = backing.get('mounts', [])
        if (not operation(builder, 'builder-create') or not valid_handle(handle)
                or not clean(terminal) or terminal.get('worker') is not True
                or operation(builder, 'builder-remove').get('exports_released') is not True
                or handle_id(terminal.get('handle', {})) != handle
                or not re.fullmatch(r'[0-9a-f]{64}', backing.get('id', ''))
                or backing.get('image') != images['buildkit']['ref']
                or backing.get('privileged') is not True
                or not re.search(r'^Driver:\s+docker-container$', bootstrap, re.MULTILINE)
                or not re.search(r'^BuildKit version:\s+' + re.escape(images['buildkit']['tag'])
                                 + r'$', bootstrap, re.MULTILINE)
                or not any(mount['Type'] == 'volume'
                           and mount['Destination'] == '/var/lib/buildkit'
                           and mount['Name'] == backing['name'] + '_state' for mount in mounts)
                or not operation(builder, 'preload-builder-bases')
                or not all(operation(builder, f'builder.cgroup.{point}') for point in ('after-preload', 'after-builds'))):
            return None
        return handle

    def valid_export(builder, language, change, worker, seen):
        prefix = f'{language}.{change}'
        export = operation(builder, prefix + '.build-export')
        load = operation(builder, prefix + '.load')
        canary = operation(builder, prefix + '.built-image-canary')
        expected = {'empty': 'source-one dep-one', 'unchanged': 'source-one dep-one',
                    'source': 'source-two dep-one', 'dependency': 'source-two dep-two'}
        count = ({'empty': 2, 'unchanged': 0, 'source': 1, 'dependency': 2} if language == 'node'
                 else {'empty': 1, 'unchanged': 0, 'source': 1, 'dependency': 1})
        witness = canary.get('guest_witness', {})
        handles = {witness.get('conjet.native_handle', '')}
        runs = export.get('native_runs')
        if (not isinstance(runs, list) or len(runs) != count[change]
                or export.get('archive_bytes', 0) <= 0
                or not re.fullmatch(r'[0-9a-f]{64}', export.get('archive_sha256', ''))
                or not re.fullmatch(r'sha256:[0-9a-f]{64}', export.get('config_digest', ''))
                or export.get('config_digest') != load.get('config_digest')
                or canary.get('stdout') != expected[change] + '\n'
                or witness.get('conjet.backend') != 'jetstream-native-oci'
                or witness.get('conjet.guest_cleanup') != 'complete'
                or witness.get('exitCode') != '0'):
            return False
        if change == 'unchanged':
            progress = export.get('stderr', '')
            cached = re.findall(r'^#(\d+) \[compiler [^\]]+\] RUN .+$', progress, re.MULTILINE)
            if (len(cached) != count['empty']
                    or any(f'#{step} CACHED' not in progress.splitlines() for step in cached)
                    or operation(builder, f'{language}.empty.build-export').get('config_digest')
                       != export['config_digest']):
                return False
        for run in runs:
            boot, ident = handle_id(run.get('handle', {}))
            snapshot = run.get('build_snapshot', {})
            if (boot != worker[0] or ident in handles or run.get('parent') != worker[1]
                    or not clean(run) or run.get('exec') != 'confirmed' or run.get('exit') != {'code': 0}
                    or not snapshot.get('live_worker') or not snapshot.get('bundle_policy')
                    or not snapshot.get('id') or not snapshot.get('inode') or not snapshot.get('device')):
                return False
            handles.add(ident)
        if (not all(re.fullmatch(r'[0-9a-f]{32}', handle) for handle in handles)
                or worker[1] in handles or handles & seen):
            return False
        seen.update(handles)
        return True

    results = []
    seen = set()
    languages = [report['build_language']] if report.get('build_language') else budget['workloads']
    for language in languages:
        samples = builders.get(language, [])
        if len(samples) != budget['samples_per_session']:
            continue
        workers = [worker_handle(builder) for builder in samples]
        if None in workers or len(set(workers)) != len(workers):
            continue
        if 'bootstrap' not in results:
            results.append('bootstrap')
        for change in ('empty', 'unchanged', 'source', 'dependency'):
            if all(valid_export(builder, language, change, worker, seen)
                   for builder, worker in zip(samples, workers, strict=True)):
                results.append(f'{language}/{change}')
    return results


def build_failure_cancel(report):
    witness = report.get('failure_cancellation', {})
    failed, active, terminal = (witness.get(key, {}) for key in ('failed', 'active', 'terminal'))
    worker = witness.get('worker', {})
    worker_id, boot = worker.get('workload_id'), worker.get('boot_id')
    if (witness.get('error') or not worker_id or not boot or witness.get('client_exit') != 130
            or not all(row.get('parent') == worker_id and row.get('handle', {}).get('boot_id') == boot
                       for row in (failed, active, terminal))
            or failed.get('handle') == terminal.get('handle')
            or active.get('handle') != terminal.get('handle')
            or active.get('phase') != 'running'):
        return False
    return (failed.get('exit') == {'code': 23} and terminal.get('exit') == {'signal': 9}
            and all(row.get('cleanup') == 'complete' and row.get('helper_failed') is False
                    for row in (failed, terminal))
            and any(row['scenario'] == 'build-failure' and row.get('exit_code') == 1
                    and row.get('error') is None and 'expected-build-failure' in row.get('stderr', '')
                    for row in report.get('operations', [])))


def public_build_bases(folder, language, images):
    sources = []
    with (folder / 'adapter.stderr').open() as trace:
        for line in trace:
            try:
                row = json.loads(line)
            except ValueError:
                continue
            if isinstance(row, dict) and row.get('event') == 'build_registry':
                sources.append(row)
    refs = [images['golang' if language == 'go' else language]['ref']]
    if language != 'node':
        refs.append(images['alpine']['ref'])
    for ref in refs:
        repository, digest = ref.removeprefix('docker.io/').split('@')
        transfers = [row for row in sources if row.get('repository') == repository]
        if (not any(row.get('manifest') is True and row.get('digest') == digest
                    and row.get('source') == 'public-https' for row in transfers)
                or not any(row.get('manifest') is True and row.get('digest') == digest
                           and row.get('bytes', 0) > 0 for row in transfers)
                or not any(row.get('manifest') is False and row.get('bytes', 0) > 4096
                           for row in transfers)):
            return False
    return True


def docker_build_api(report, witness):
    if witness.get('error') or witness.get('failure_tag_published'):
        return False
    rows = report.get('operations', [])
    if (any(row.get('error') is not None or row.get('exit_code') != 0 for row in rows)
            or sum(row['scenario'] == 'api-image-absent' and row.get('stdout') == '' for row in rows) != 2
            or sum(row['scenario'] == 'api-built-image' and row.get('stdout') == 'native-build-api\n'
                   for row in rows) != 1):
        return False
    owners = set()
    for kind, expected in (('failed', 23), ('ready', 0)):
        request = witness.get(kind, {})
        children = request.get('native', [])
        if request.get('status') != 200 or len(children) != 2:
            return False
        worker, run = sorted(children, key=lambda child: not child['worker'])
        owner = worker['handle']['workload_id']
        if (not worker['worker'] or run['worker'] or owner in owners or run['parent'] != owner
                or run['exit'] != {'code': expected} or run['exec'] != 'confirmed'
                or run['handle']['boot_id'] != worker['handle']['boot_id']
                or not all(child['phase'] == 'removed' and child['cleanup'] == 'complete'
                           and child['helper_failed'] is False for child in children)
                or not run.get('build_snapshot', {}).get('live_worker')):
            return False
        owners.add(owner)
    body = witness['failed'].get('body', [])
    terminal = witness.get('guest_witness', {})
    return (any('api-failure' in event.get('error', '') for event in body)
            and re.fullmatch(r'sha256:[0-9a-f]{64}', witness.get('image', '')) is not None
            and terminal.get('conjet.backend') == 'jetstream-native-oci'
            and terminal.get('conjet.guest_cleanup') == 'complete'
            and terminal.get('exitCode') == '0')


def direct_buildkit(report, data):
    direct = runpy.run_path(str(HERE / 'native-buildkit-direct.py'))
    if (data.get('error') or data.get('buildctl_sha256') != direct['CLIENT_SHA256']
            or data.get('version') != direct['CLIENT_VERSION']):
        return False
    rows = report.get('operations', [])
    if (any(row.get('error') is not None for row in rows)
            or sum(row['scenario'] == 'direct-absent' and row.get('exit_code') == 1 for row in rows) != 2
            or sum(row['scenario'] == 'direct-remove' and row.get('exit_code') == 0 for row in rows) != 1):
        return False
    fresh, cached = data.get('fresh', {}), data.get('cached', {})
    proof = hashlib.sha256(direct['PROOF']).hexdigest()
    for export in (fresh, cached):
        if export.get('code') != 0 or export.get('sha256') != proof:
            return False
    runs = fresh.get('runs', [])
    if (len(runs) != 1 or fresh.get('streams') != [True, True]
            or cached.get('runs') != [] or cached.get('cached') is not True):
        return False
    active, terminal = data.get('active', {}), data.get('terminal', {})
    worker, stopped = data.get('worker', {}), data.get('worker_terminal', {})
    if (active.get('handle') != terminal.get('handle') or active.get('phase') != 'running'
            or data.get('cancel_exit') not in (1, 130, -2) or data.get('cancel_export_absent') is not True
            or stopped.get('handle') != worker or stopped.get('worker') is not True
            or stopped.get('cleanup') != 'complete' or stopped.get('helper_failed') is not False):
        return False
    return all(row.get('parent') == worker.get('workload_id') and row.get('exec') == 'confirmed'
               and row.get('handle', {}).get('boot_id') == worker.get('boot_id')
               and row.get('exit') == exit_status and row.get('cleanup') == 'complete'
               and row.get('helper_failed') is False
               and row.get('build_snapshot', {}).get('live_worker') is True
               for row, exit_status in ((runs[0], {'code': 0}), (terminal, {'signal': 9})))


def evaluate(root, revision, release):
    manifest = PREFLIGHT['contract']()
    required = {case['id']: {
        'task': group['task'], 'status': 'FAIL', 'reason': 'missing qualified witness',
        'fixture': case['operation'], 'policy': group['effective_policy'],
        'expected': group['expected'], 'expected_cleanup': group['cleanup'],
    } for group in manifest['groups'] for case in group['cases']}
    if sum(len(group['cases']) for group in manifest['groups']) != len(required):
        raise ValueError('duplicate case in the frozen manifest')
    launch_artifacts = {name: digest for name, digest in release.items() if name != 'conjetd'}
    scenarios = json.loads((HERE / 'scenarios/docker-comparison-v1.json').read_text())
    lanes = {}

    def lane(name):
        if name not in lanes:
            folder = root / name / 'launcher'
            launcher = read(folder, 'launcher.json')
            digests = {Path(path).name: digest for path, digest in launcher.get('binary_sha256', {}).items()}
            verified = (launcher.get('revision') == revision
                        and all(digests.get(name) == digest for name, digest in launch_artifacts.items())
                        and launcher.get('passed') is True
                        and launcher.get('backend') == 'Conjet Native OCI'
                        and '--core-dynamic-memory' in launcher.get('vm_command', [])
                        and launcher.get('production_unchanged') is True
                        and launcher.get('native_session_removed') is True
                        and launcher.get('adapter_socket_removed') is True
                        and launcher.get('cleanup_errors') == []
                        and launcher.get('shutdown', {}).get('guest_cleanup') == 'complete'
                        and launcher.get('shutdown', {}).get('reclaim_failures') == 0)
            lanes[name] = (folder, verified)
        return lanes[name]

    def pass_case(case, reason, *names):
        if all(lane(name)[1] for name in names):
            required[case].update(status='PASS', reason=reason,
                                  evidence=[str(lane(name)[0]) for name in names])

    lifecycle_groups = {case: 'lifecycle-' + case.removeprefix('lifecycle/').replace('/', '-')
                        for case in required if case.startswith('lifecycle/')}
    sessions = [(suite, suite, None) for suite in MATRIX]
    sessions += [('lifecycle', name, case) for case, name in lifecycle_groups.items()]
    sessions += [('builds', f'builds-{language}', language)
                 for language in scenarios['suites']['builds']['workloads']]
    lifecycle_evidence = set()
    for suite, name, subgroup in sessions:
        folder, verified = lane(name)
        path = 'matrix/session.json'
        report = read(folder, path)
        failed = [row for row in report.get('operations', []) if row.get('error')]
        if not report:
            continue
        reason = report.get('error') or ('; '.join(dict.fromkeys(
            f"{row['scenario']}: {(row.get('stderr') or row['error']).strip()[:240]}"
            for row in failed)) if failed else 'required behavior needs a separate witness')
        if not verified:
            reason = 'release artifact or launcher cleanup could not be verified'
        for case, result in required.items():
            if (case == subgroup or subgroup is None and case.startswith(suite + '/')
                    or suite == 'builds' and subgroup and case.startswith(f'builds/{subgroup}/')):
                result.update(reason=reason, evidence=[str(folder / path)])
        if suite == 'lifecycle' and verified:
            for series in report.get('groups', []):
                case = 'lifecycle/{workload}/{network}/{lane}'.format(**series)
                if case not in lifecycle_groups or (subgroup is not None and case != subgroup):
                    raise ValueError(f'unexpected frozen lifecycle group: {case}')
                if case in lifecycle_evidence:
                    raise ValueError(f'duplicate frozen lifecycle evidence: {case}')
                lifecycle_evidence.add(case)
                failure = lifecycle_failure(series, report, scenarios['suites']['lifecycle'])
                if failure:
                    required[case].update(reason=failure, evidence=[str(folder / path)])
                else:
                    pass_case(case, 'all original lifecycle samples passed with native cleanup', name)
            for fixture, row in report.get('independent_alpine', {}).items():
                case = 'lifecycle/' + fixture
                if case not in required:
                    raise ValueError(f'unknown lifecycle fixture: {fixture}')
                witness = row.get('guest_witness', {})
                if subgroup in (None, case) and case not in lifecycle_evidence:
                    reason = 'the complete frozen lifecycle sample counts did not run'
                    if (witness.get('conjet.guest_cleanup') != 'complete'
                            or not witness.get('conjet.native_handle')):
                        reason = 'missing guest cleanup witness'
                    required[case].update(reason=row.get('error') or reason)
        if suite == 'stress' and verified:
            manifest_budget = scenarios['suites']['stress']
            count = manifest_budget['samples_per_session']
            warmups = manifest_budget['warmups']
            for concurrency in (1, 2, 4, 8):
                operation = f'stress.launch.concurrency-{concurrency}'
                rows = [row for row in report.get('operations', []) if row['scenario'] == operation]
                if (len(rows) == count + warmups and all(row['error'] is None for row in rows)
                        and sum(row['phase'] == 'sample' for row in rows) == count
                        and sum(row['phase'] == 'warmup' for row in rows) == warmups):
                    pass_case(f'stress/concurrency-{concurrency}',
                              f'{count} original runs and {warmups} warmups passed', suite)
            if stress_oom(report):
                pass_case('stress/oom-recover', 'kernel OOM, survivor and recovery verified with teardown', suite)
            if stress_cancellation(report, max(scenarios['concurrency'])):
                pass_case('stress/cancellation', 'active cancellations, surviving data and recovery verified', suite)
        if suite == 'control' and verified:
            for case in control_cases(report, scenarios['suites']['control']):
                pass_case(f'control/{case}', 'original control runs passed with native teardown', suite)
        if suite == 'builds' and verified:
            launcher = read(folder, 'launcher.json')
            if (not launcher.get('offline_oci_layouts') and not launcher.get('compatibility_build_bases')
                    and '--pinned-build-registry' in launcher.get('adapter_command', [])
                    and launcher.get('volume_lease_released') is True
                    and report.get('build_language') == subgroup):
                qualified = build_cases(report, scenarios['suites']['builds'], scenarios['images'])
                for case in qualified:
                    language = case.split('/', 1)[0]
                    if case == 'bootstrap' or public_build_bases(folder, language, scenarios['images']):
                        pass_case(f'builds/{case}', 'original public Buildx client, executor and cleanup verified', name)
                if 'bootstrap' in qualified and build_failure_cancel(report):
                    pass_case('builds/failure-cancel', 'failed and cancelled RUN generations verified with cleanup', name)
        if suite == 'compose' and verified:
            for case in compose_cases(report, scenarios['suites']['compose']):
                pass_case(f'compose/{case}', 'original Compose fixture and project cleanup verified', suite)
        if suite == 'storage_network' and verified:
            for case in storage_cases(report, scenarios['suites']['storage_network']):
                pass_case(f'storage_network/{case}', 'original storage cases verified data and teardown', suite)
        if suite == 'images' and verified:
            if not read(folder, 'launcher.json').get('offline_oci_layouts'):
                for case in image_cases(report, scenarios['suites']['images']):
                    pass_case(f'images/{case}', 'original image acquisition or archive canaries passed', name)
            for case in controlled_registry_cases(report, scenarios['suites']['images']):
                pass_case(f'images/{case}', 'original registry transfers, execution and removal verified', name)

    folder, verified = lane('registry-service')
    if verified:
        report = read(folder, 'matrix/session.json')
        for case in controlled_registry_cases(report, scenarios['suites']['images']):
            pass_case(f'images/{case}', 'original controlled registry transfer and cleanup verified', 'registry-service')

    folder, verified = lane('credentials')
    credentials = read(folder, 'native-credentials.json')
    if verified and credentials.get('passed'):
        cases = credentials.get('cases', {})
        rejected = ('unmapped_uid', 'unmapped_gid', 'unknown_user', 'unknown_group',
                    'privileged', 'added_capability')
        if all(cases.get(case, {}).get('expected_status') == 400
               and cases.get(case, {}).get('absent_after_rejection') is True
               for case in rejected):
            pass_case('credentials/reject', 'API denied invalid identity and privilege requests before admission',
                      'credentials')
        explicit = {
            'numeric-u': 1234, 'numeric-g': 4321, 'named-u': 65534, 'named-g': 65534,
            'named-group-u': 0, 'named-group-g': 65533,
            'numeric-primary-group-u': 65534, 'numeric-primary-group-g': 65534,
            'missing-numeric-u': 61234, 'missing-numeric-g': 0,
            'fixture-u': 65532, 'fixture-g': 65532,
        }
        if (all(cases.get(case, {}).get('stdout') == f'{identity}\n'
                and cases.get(case, {}).get('guest', {}).get('conjet.guest_cleanup') == 'complete'
                for case, identity in explicit.items())
                and all(cases.get('exec_named_inherited_' + flag, {}).get('stdout') == '65534\n'
                        for flag in ('u', 'g'))
                and cases.get('exec_named_witness', {}).get('conjet.guest_cleanup') == 'complete'):
            pass_case('credentials/explicit', 'numeric and named UID/GID semantics and inherited exec verified',
                      'credentials')
        defaults = credentials.get('image_defaults', {})
        if all(defaults.get(image, {}).get('exit') == 0
               and defaults[image].get('stdout') == '0:0\n16777216:4:50000:100000\n'
               and defaults[image].get('guest', {}).get('image') == descriptor['ref']
               and defaults[image]['guest'].get('conjet.guest_cleanup') == 'complete'
               and (image == 'alpine' or defaults[image].get('image_released') is True)
               for image, descriptor in scenarios['images'].items()):
            pass_case('credentials/default', 'all frozen images reported default IDs and effective cgroup limits',
                      'credentials')
        if all(cases.get(case, {}).get('conjet.guest_cleanup') == 'complete'
               for case in ('matched_cli', 'matched_api')):
            pass_case('regression/matched-identity',
                      'explicit 65532 CLI streams and API lifecycle retained verified cleanup', 'credentials')

    folder, verified = lane('dynamic-memory')
    memory = read(folder, 'native-core-memory-summary.json')
    if verified and memory.get('initial_reduced', {}).get('target_mib') == 448:
        if memory.get('expanded', {}).get('target_mib') == 2048:
            pass_case('memory/growth', 'Core grew from 448 to 2,048 MiB on workload demand', 'dynamic-memory')
        idle = memory.get('post_workload_reduced', {})
        if idle.get('target_mib') == 448 and idle.get('memory_ledger', {}).get('ok') is True:
            pass_case('memory/idle', 'Core returned to 448 MiB with verified ownership', 'dynamic-memory')

    folder, verified = lane('dynamic-pressure')
    pressure = read(folder, 'native-core-memory-summary.json')
    if verified and pressure.get('guest_pressure_only', {}).get('active_workloads') == 0:
        if pressure.get('pressure_only_expanded', {}).get('target_mib') == 2048:
            pass_case('memory/pressure', 'independent pressure restored capacity with zero workloads',
                      'dynamic-pressure')
        if pressure.get('expected_sha256') and pressure.get('guest_after_churn'):
            pass_case('memory/churn', 'active file checksum remained valid through release churn',
                      'dynamic-pressure')

    folder, verified = lane('registry')
    registry = read(folder, 'registry-checks.json').get('cases', {})
    if verified and {'hash', 'interrupt', 'tag_run', 'in_use_delete', 'remove_small'} <= registry.keys():
        pass_case('regression/registry-local', 'loopback registry fault, ownership and image runs passed', 'registry')
        if all(registry[case].get('code') == 1 for case in ('hash', 'interrupt')):
            pass_case('images/registry-faults', 'digest and interrupted transfers rejected with no partial store', 'registry')
        if (registry.get('shared_layer_run', {}).get('conjet.guest_cleanup') == 'complete'
                and registry['remove_small'].get('code') == 0):
            pass_case('images/shared-layer', 'shared content survived sibling removal and was reclaimed after final removal', 'registry')
    pass_case('regression/network', 'private bridge DNS and loopback publication canaries passed',
              'docker-network', 'published-port')
    pass_case('regression/controls', 'native concurrency, exec and streaming canaries passed',
              'concurrency', 'exec', 'streaming')
    folder, verified = lane('concurrency')
    controls = read(folder, 'docker-controls.json')
    executions = controls.get('guest_executions', [])
    statuses = (('graceful_status', '42'), ('kill_status', '137'), ('timeout_status', '137'))
    if (verified and len(executions) == 3
            and len({event.get('conjet.native_handle') for event in executions}) == 3
            and all(event.get('conjet.backend') == 'jetstream-native-oci'
                    and event.get('conjet.guest_cleanup') == 'complete' for event in executions)
            and all(controls.get(case, {}).get('stdout', '').strip() == status for case, status in statuses)
            and controls.get('timeout_remove', {}).get('code') == 0):
        pass_case('control/stop-kill-restart', 'three verified guest generations and escalation', 'concurrency')
    pass_case('regression/volume', 'owned volume write and recovery canaries passed across two boots',
              'volume-create', 'volume-inspect')
    pass_case('regression/native-compose', 'existing pinned native Compose project canary passed',
              'native-compose')
    folder, verified = lane('buildkit-direct')
    direct = read(folder, 'buildkit-direct.json')
    if verified and direct_buildkit(read(folder, 'matrix/session.json'), direct):
        pass_case('regression/buildkit-direct', 'pinned standalone BuildKit client verified export, cache and cancellation',
                  'buildkit-direct')
    elif verified and direct:
        required['regression/buildkit-direct'].update(
            reason=direct.get('error', 'direct BuildKit lacks a cache, export or native cleanup witness'),
            evidence=[str(folder / 'buildkit-direct.json')])

    folder, verified = lane('docker-build-api')
    current = read(folder, 'docker-build-api.json')
    if verified and docker_build_api(read(folder, 'matrix/session.json'), current):
        pass_case('builds/docker-build-api', 'native Docker API compiled the archive, ran it and verified teardown',
                  'docker-build-api')
    elif verified and current:
        required['builds/docker-build-api'].update(
            reason=current.get('error', 'Docker API build lacks its native generation or export witness'),
            evidence=[str(folder / 'docker-build-api.json')])
    response_path = folder.parent / 'response.json'
    response = read(folder.parent, response_path.name)
    if verified and response and response['status'] != 200:
        required['builds/docker-build-api'].update(
            reason=f"POST /v1.44/build returned HTTP {response['status']}: {response['body'].get('message', '')}",
            evidence=[str(response_path), str(folder)])

    passed = sum(item['status'] == 'PASS' for item in required.values())
    return {'scope': 'native-release-compatibility', 'revision': revision,
            'compatibility_manifest_sha256': hashlib.sha256(PREFLIGHT['MANIFEST'].read_bytes()).hexdigest(),
            'frozen_sources_sha256': manifest['sources'],
            'release_sha256': release, 'required': len(required), 'passed_cases': passed,
            'failed_cases': len(required) - passed, 'passed': passed == len(required),
            'cases': required}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--revision', required=True)
    args = parser.parse_args()
    root = args.evidence.resolve(strict=True)
    if not root.is_relative_to(SCRATCH):
        parser.error('evidence must be under ExternalSSD scratch')
    release = {}
    for line in (root / 'release-sha256.txt').read_text().splitlines():
        digest, path = line.split(maxsplit=1)
        name = Path(path).name
        if name in release or re.fullmatch(r'[0-9a-f]{64}', digest) is None:
            parser.error('invalid or duplicate release artifact digest')
        release[name] = digest
    if (release.keys() != {'conjet', 'conjetd', 'jetstream', 'conjet-launchd', 'conjet-memd', 'conjet-reclaimd'}
            or re.fullmatch(r'[0-9a-f]{40}', args.revision) is None):
        parser.error('expected the exact release executable inventory')
    summary = evaluate(root, args.revision, release)
    destination = root / 'compatibility-summary.json'
    destination.write_text(json.dumps(summary, indent=2) + '\n')
    print(f"{summary['passed_cases']} PASS / {summary['failed_cases']} FAIL. {destination}")
    return 0 if summary['passed'] else 1


if __name__ == '__main__':
    sys.exit(main())
