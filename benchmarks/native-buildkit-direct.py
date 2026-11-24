"""Qualify the pinned standalone BuildKit client against the native worker."""

import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import time

CLIENT_SHA256 = '452bc230f7ae2cdf63372d2922cef49005b15c1642c7c15122c2c1aa9d583c79'
CLIENT_VERSION = 'buildctl github.com/moby/buildkit v0.23.2 40b2ede0ac0a37030f9959b4a28e9c6c8ea036e7'
PROOF = b'native build snapshot proof\n'


def collect(runner, manifest, state, client, probe):
    directory = runner.output / 'buildkit-direct'
    directory.mkdir(mode=0o700)
    data = {'buildctl_sha256': CLIENT_SHA256}
    name = runner.token + '-direct'
    worker = f'buildx_buildkit_{name}0'
    client_env = dict(runner.env, PATH=f'{Path(runner.prefix[0]).parent}:/usr/bin:/bin')
    compiler = manifest['images']['buildkit']['ref']

    def run(*argv, timeout=60):
        return subprocess.run(argv, env=client_env, timeout=timeout, capture_output=True, text=True)

    def solve(dest):
        return [client, '--addr', f'docker-container://{worker}?context=conjet-speedup',
                'build', '--frontend=dockerfile.v0', '--local', f'context={directory}',
                '--local', f'dockerfile={directory}', '--progress=plain',
                '--output', f'type=local,dest={dest}']

    def runs():
        return {record['handle']['workload_id']: record for record in state()['builds']
                if record['parent'] == data['worker']['workload_id']}

    try:
        with client.open('rb') as executable:
            if hashlib.file_digest(executable, 'sha256').hexdigest() != CLIENT_SHA256:
                raise RuntimeError('standalone BuildKit client differs from the release')
        version = run(client, '--version')
        if version.returncode != 0 or version.stdout.strip() != CLIENT_VERSION:
            raise RuntimeError('standalone BuildKit client version differs')
        data['version'] = version.stdout.strip()
        target = directory / 'probe'
        shutil.copyfile(probe, target)
        target.chmod(0o755)
        (directory / 'seed').mkdir()
        (directory / 'seed' / '.keep').touch()
        dockerfile = directory / 'Dockerfile'
        spec = ('FROM scratch AS build\nCOPY probe /bin/probe\n'
                'COPY --chown=65532:65532 seed /output\nUSER 65532:65532\n'
                'RUN --network=none ["/bin/probe", "%s"]\n'
                'FROM scratch\nCOPY --from=build /output/proof /proof\n')
        dockerfile.write_text(spec % 'write')
        if runner.call('direct-create', ['buildx', 'create', '--name', name, '--driver',
                       'docker-container', '--driver-opt', f'image={compiler}', 'conjet-speedup'],
                       phase='setup') is None:
            raise RuntimeError('could not create the direct BuildKit worker')
        if runner.call('direct-bootstrap', ['buildx', 'inspect', '--bootstrap', name],
                       phase='setup', timeout=180) is None:
            raise RuntimeError('could not bootstrap the direct BuildKit worker')
        [record] = [record for record in state()['builds'] if record['worker'] and record['phase'] == 'running']
        data['worker'] = record['handle']

        def export(boundary):
            before = runs()
            destination = runner.output / ('direct-' + boundary)
            result = run(*solve(destination), timeout=120)
            evidence = data[boundary] = {'code': result.returncode,
                                        'runs': [row for ident, row in runs().items() if ident not in before]}
            (directory / (boundary + '.stdout')).write_text(result.stdout)
            (directory / (boundary + '.stderr')).write_text(result.stderr)
            evidence['streams'] = [bool(re.search(r'^#\d+ [0-9.]+ ' + mark + r'$', result.stderr, re.MULTILINE))
                                   for mark in ('native-direct-stdout', 'native-direct-stderr')]
            evidence['cached'] = bool(re.search(r'^#\d+ CACHED$', result.stderr, re.MULTILINE))
            if result.returncode != 0 or (destination / 'proof').read_bytes() != PROOF:
                raise RuntimeError('standalone BuildKit export differed from the guest proof')
            evidence['sha256'] = hashlib.sha256((destination / 'proof').read_bytes()).hexdigest()

        export('fresh')
        export('cached')
        dockerfile.write_text(spec % 'hold')
        previous = runs()
        stderr = directory / 'cancel.stderr'
        with stderr.open('wb') as errors, (directory / 'cancel.stdout').open('wb') as output:
            with subprocess.Popen(solve(runner.output / 'direct-cancelled'), env=client_env,
                                  stdin=subprocess.DEVNULL, stdout=output, stderr=errors,
                                  start_new_session=True) as child:
                try:
                    until = time.monotonic() + 20
                    while time.monotonic() < until and child.poll() is None:
                        if re.search(rb'^#\d+ [0-9.]+ native-direct-stdout$', stderr.read_bytes(), re.MULTILINE):
                            [active] = [row for ident, row in runs().items() if ident not in previous]
                            if active['phase'] != 'running':
                                raise RuntimeError('standalone BuildKit cancellation has no active RUN')
                            data['active'] = active
                            break
                        time.sleep(0.05)
                    else:
                        raise RuntimeError('standalone BuildKit RUN did not stream its marker')
                    child.send_signal(signal.SIGINT)
                    data['cancel_exit'] = child.wait(timeout=12)
                    until = time.monotonic() + 10
                    while time.monotonic() < until:
                        terminal = runs().get(active['handle']['workload_id'], {})
                        if terminal.get('cleanup') == 'complete':
                            data['terminal'] = terminal
                            break
                        time.sleep(0.05)
                    else:
                        raise RuntimeError('standalone BuildKit cancellation did not clean up the RUN')
                finally:
                    if child.poll() is None:
                        os.killpg(child.pid, signal.SIGKILL)
                        child.wait(timeout=5)
        data['cancel_export_absent'] = not (runner.output / 'direct-cancelled' / 'proof').exists()
    except (KeyError, OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
        data['error'] = str(error)
    finally:
        removed = runner.call('direct-remove', ['buildx', 'rm', name], phase='cleanup')
        if removed is not None and 'worker' in data:
            [terminal] = [row for row in state()['builds'] if row['handle'] == data['worker']]
            data['worker_terminal'] = terminal
        for resource in (['inspect', worker], ['volume', 'inspect', worker + '_state']):
            runner.call('direct-absent', resource, phase='cleanup', expected_code=1)
        (runner.output.parent / 'buildkit-direct.json').write_text(json.dumps(data, indent=2) + '\n')
