"""Exercise archive roundtrips through the isolated native Docker API."""

import hashlib
import json
from pathlib import Path
import runpy
import subprocess
import tarfile

HERE = Path(__file__).resolve().parent
MATCHED = runpy.run_path(str(HERE / 'native-docker-comparison.py'))
MANIFEST = json.loads((HERE / 'scenarios/docker-comparison-v1.json').read_text())
FIXTURE = Path('/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-008/common-image/image')


def collect(endpoint, peer, docker, env, output, store, *, node_roundtrip=False):
    scenario = json.loads((FIXTURE / 'scenario.json').read_text())
    original = FIXTURE / 'image.tar'
    if hashlib.sha256(original.read_bytes()).hexdigest() != MANIFEST['common_static_fixture']['archive_sha256']:
        raise RuntimeError('common archive differs from its frozen hash')
    connection = MATCHED['TOOLS']['UnixHTTP'](endpoint, peer)
    cases = {}
    handles = set()

    def call(label, argv, *, code=0, input_file=None):
        result = subprocess.run([*docker, *argv], env=env, input=input_file,
                                capture_output=True, timeout=45)
        cases[label] = {'argv': list(map(str, argv)), 'exit': result.returncode,
                        'stdout': result.stdout.decode(errors='replace'),
                        'stderr': result.stderr.decode(errors='replace')}
        if result.returncode != code:
            raise RuntimeError(f'Docker archive case {label} failed: {result.stderr[:250]!r}')
        return result.stdout

    def prove(label, tag, image_id, command):
        actual = call(label + '_inspect', ['image', 'inspect', '--format', '{{.Id}}', tag])
        if actual.decode().strip() != image_id:
            raise RuntimeError(f'Docker archive case {label} changed the config digest')
        name = 'cj-archive-' + label
        emitted = call(label + '_run', ['run', *MATCHED['FLAGS'], '--name', name, tag, *command])
        if emitted or cases[label + '_run']['stderr']:
            raise RuntimeError(f'Docker archive case {label} changed executable output')
        cases[label + '_cleanup'] = MATCHED['native_terminal'](connection, name, handles)

    def roundtrip(label, tag, image_id, command, archive_path):
        call(label + '_save', ['image', 'save', '--output', archive_path, tag])
        call(label + '_remove', ['image', 'rm', tag])
        if call(label + '_absent', ['image', 'ls', '--quiet', tag]):
            raise RuntimeError('image tag remained after removal')
        call(label + '_reload', ['image', 'load'], input_file=archive_path.read_bytes())
        prove(label + '_reloaded', tag, image_id, command)

    def node():
        fixture = MANIFEST['images']['node']
        tag = 'cj-archive-node:canary'
        saved = output / 'node.tar'
        call('node_pull', ['pull', '--platform', 'linux/arm64', fixture['ref']])
        call('node_tag', ['image', 'tag', fixture['ref'], tag])
        call('node_save', ['image', 'save', '--output', saved, tag])
        with saved.open('rb') as body:
            cases['node_archive'] = {'bytes': saved.stat().st_size,
                                     'sha256': hashlib.file_digest(body, 'sha256').hexdigest()}
        try:
            call('node_remove_tag', ['image', 'rm', tag])
            if call('node_tag_absent', ['image', 'ls', '--quiet', tag]):
                raise RuntimeError('Node image tag remained after removal')
            call('node_load', ['image', 'load', '--input', saved])
            config = call('node_loaded_inspect', ['image', 'inspect', '--format', '{{.Id}}', tag])
            if config.decode().strip() != fixture['config_digest']:
                raise RuntimeError('the loaded Node archive changed image identity')
            name = 'cj-archive-node-content'
            call('node_loaded_contents', ['run', *MATCHED['FLAGS'], '--name', name,
                                          '--entrypoint', '/bin/busybox', tag,
                                          'test', '-x', '/usr/local/bin/node'])
            connection.close()
            cases['node_cleanup'] = MATCHED['native_terminal'](connection, name, handles)
            name = 'cj-archive-node-entrypoint'
            value = call('node_entrypoint', ['run', *MATCHED['FLAGS'], '--name', name, tag,
                                              '/bin/busybox', 'echo', 'node-entrypoint-ready'])
            if value != b'node-entrypoint-ready\n':
                raise RuntimeError('the pinned Node entrypoint changed the selected command')
            cases['node_entrypoint_cleanup'] = MATCHED['native_terminal'](connection, name, handles)
            name = 'cj-archive-node-isolation'
            call('node_namespace_denied', ['run', *MATCHED['FLAGS'], '--name', name, tag,
                                            '/bin/busybox', 'unshare', '-n', '/bin/true'], code=1)
            if 'Operation not permitted' not in cases['node_namespace_denied']['stderr']:
                raise RuntimeError('the node workload did not report the namespace rejection')
            cases['node_namespace_cleanup'] = MATCHED['native_terminal'](connection, name, handles, code=1)
            name = 'cj-archive-node-runtime'
            value = call('node_runtime', ['run', '--rm', '--pull', 'never', '--network', 'none',
                                          '--name', name, tag, 'node', '-e', 'console.log("image-node")'])
            if value != b'image-node\n':
                raise RuntimeError('the archived Node workload returned different output')
            cases['node_runtime_cleanup'] = MATCHED['native_terminal'](connection, name, handles)
            call('node_final_remove_tag', ['image', 'rm', tag])
            call('node_remove_source', ['image', 'rm', fixture['ref']])
            if call('node_final_absent', ['image', 'ls', '--quiet', tag]):
                raise RuntimeError('the Node archive tag remained after final removal')
        finally:
            saved.unlink()

    try:
        tag = scenario['image']
        call('common_load', ['image', 'load', '--input', original])
        prove('common', tag, scenario['config_digest'], scenario['command'])
        roundtrip('common', tag, scenario['config_digest'], scenario['command'], output / 'common.tar')

        call('common_remove_for_corruption', ['image', 'rm', tag])
        before = sorted(p.name for p in (store / 'blobs/sha256').iterdir())
        damaged = bytearray(original.read_bytes())
        with tarfile.open(original) as tar:
            layer = tar.getmember('layer.tar')
        damaged[layer.offset_data + 1024] ^= 1
        call('corrupt_layer', ['image', 'load'], code=1, input_file=damaged)
        if 'diff ID mismatch' not in cases['corrupt_layer']['stderr'] + cases['corrupt_layer']['stdout']:
            raise RuntimeError('corrupt layer did not reach content verification')
        if (sorted(p.name for p in (store / 'blobs/sha256').iterdir()) != before
                or call('corrupt_alias_absent', ['image', 'ls', '--quiet', tag])):
            raise RuntimeError('a rejected archive published state')

        alpine = MANIFEST['images']['alpine']
        alpine_tag = 'cj-archive-alpine:canary'
        call('alpine_tag', ['image', 'tag', alpine['ref'], alpine_tag])
        roundtrip('alpine', alpine_tag, alpine['config_digest'], ['/bin/true'], output / 'alpine.tar')
        call('alpine_final_remove', ['image', 'rm', alpine_tag])
        if node_roundtrip:
            node()
    finally:
        connection.close()
        (output / 'archive-checks.json').write_text(json.dumps(cases, indent=2) + '\n')
