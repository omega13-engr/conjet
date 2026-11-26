"""Check the private native volume registry over the authenticated guest channel."""

import json
from pathlib import Path
import runpy


NATIVE = runpy.run_path(str(Path(__file__).with_name('native-oci-live-install.py')))
NAMES = [f'cj-volume-{number}' for number in range(8)]


def collect(session, vm_pid, output, phase):
    evidence = {}
    try:
        with NATIVE['channel'](session, vm_pid) as (stream, boot):
            evidence['boot_id'] = boot

            def volume(action, name=None, error=None, generation=boot):
                operation = {'action': action}
                if name is not None:
                    operation['name'] = name
                return NATIVE['exchange'](stream, 25, {
                    'boot_id': generation, 'budget_ms': 1500, 'operation': operation,
                }, 15 if error else 25, error)

            if phase == 'create':
                if volume('list')['volumes']:
                    raise RuntimeError('volume creation fixture requires an empty disk')
                evidence['created'] = [volume('create', name) for name in NAMES]
            evidence['inspected'] = [volume('inspect', name) for name in NAMES]
            if volume('list')['volumes'] != NAMES or any(
                    item['name'] != name or (item['guest_uid'], item['guest_gid'], item['mode'])
                    != (65532, 65532, 0o700) or item['inode'] <= 0
                    for name, item in zip(NAMES, evidence['inspected'])):
                raise RuntimeError('native volume registry identities differ from the fixture')
            evidence['bad_name'] = volume('create', '../outside', 'malformed')
            evidence['capacity'] = volume('create', 'ninth', 'capacity')
            old_boot = ('1' if boot[0] == '0' else '0') + boot[1:]
            evidence['stale'] = volume('list', error='stale_generation', generation=old_boot)
            if phase == 'remove':
                evidence['removed'] = [volume('remove', name) for name in NAMES]
                if volume('list')['volumes']:
                    raise RuntimeError('native volumes remained after fixture cleanup')
    finally:
        (output / 'native-volume-disk.json').write_text(json.dumps(evidence, indent=2) + '\n')
