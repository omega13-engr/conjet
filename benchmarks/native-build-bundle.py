"""Verify bounded BuildKit OCI policy intake on an isolated snapshot disk."""

import json
from pathlib import Path
import runpy


NATIVE = runpy.run_path(str(Path(__file__).with_name('native-oci-live-install.py')))
POLICY = '65a0504290aa0fed601cf5f19b860b77d1ba682595b92c69b8909bfc4cfd4224'
BAD = {
    'wrongroot': 'build bundle paths do not match the snapshot',
    'writemount': 'unsupported BuildKit OCI preset',
    'extraadmin': 'unsupported BuildKit OCI preset',
    'badnamespace': 'unsupported BuildKit OCI preset',
    'badseccomp': 'unsupported BuildKit OCI preset',
    'badargv': 'build process violates native launch limits',
    'fileowner': 'native build config has invalid ownership, location, or size',
    'worldwrite': 'native build config has invalid ownership, location, or size',
    'tooLarge': 'native build config has invalid ownership, location, or size',
    'filelink': 'native build config is unavailable',
}


def collect(session, vm_pid, output):
    evidence = {}
    try:
        with NATIVE['channel'](session, vm_pid) as (stream, boot):
            def query(name, *, verify_bundle=True, error=None):
                return NATIVE['exchange'](stream, 26, {
                    'boot_id': boot, 'budget_ms': 1000, 'id': name,
                    'verify_bundle': verify_bundle,
                }, 15 if error else 26, error)

            identity = query('verified', verify_bundle=False)
            verified = query('verified')
            evidence['verified'] = verified
            if verified != {'snapshot': identity, 'policy_sha256': POLICY, 'mount_count': 10}:
                raise RuntimeError('bundle reply differs from the pinned policy witness')
            evidence['rejected'] = {}
            for name, message in BAD.items():
                rejected = query(name, error='unsupported_option')
                evidence['rejected'][name] = rejected
                if rejected.get('message') != message:
                    raise RuntimeError(f'{name} failed at an unexpected policy boundary')
    finally:
        (output / 'native-build-bundle.json').write_text(json.dumps(evidence, indent=2) + '\n')
