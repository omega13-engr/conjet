"""Extended Docker workloads for verified, launcher-owned sessions."""

from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import gzip
import hashlib
import http.client
import io
import json
import re
import runpy
import subprocess
import tarfile
import time
import uuid
from pathlib import Path
from urllib.parse import urlsplit
from urllib.request import ProxyHandler, build_opener

LABEL = 'dev.conjet.benchmark.session'


class Docker:
    def __init__(self, prefix, env, output, report):
        self.prefix = prefix
        self.env = env
        self.output = output
        self.report = report
        self.token = 'cjcmp-' + uuid.uuid4().hex[:12]
        self.report['operations'] = self.rows = []

    def call(self, scenario, args, *, timeout=90, expected=None, phase=None,
             expected_code=0, expected_stderr=None, stdin=None):
        argv = [str(arg) for arg in [*self.prefix, *args]]
        row = {'scenario': scenario, 'phase': phase, 'argv': argv, 'elapsed_ns': None,
               'error': None}
        self.rows.append(row)
        self.report['in_flight'] = scenario
        start = time.monotonic_ns()
        try:
            result = subprocess.run(argv, env=self.env, input=stdin, capture_output=True, timeout=timeout)
            row['elapsed_ns'] = time.monotonic_ns() - start
            row.update(exit_code=result.returncode, stdout=result.stdout[:8192].decode(errors='replace'),
                       stderr=result.stderr[:8192].decode(errors='replace'))
            if (result.returncode != expected_code or (expected is not None and result.stdout != expected)
                    or (expected_stderr is not None and result.stderr != expected_stderr)):
                raise RuntimeError(f'Docker returned {result.returncode} or failed the output canary')
            return result.stdout
        except subprocess.TimeoutExpired as error:
            row.update(error=str(error), timed_out=True)
            return None
        except (RuntimeError, OSError) as error:
            row['error'] = str(error)
            return None
        finally:
            if row['elapsed_ns'] is None:
                row['elapsed_ns'] = time.monotonic_ns() - start
            self.report.pop('in_flight', None)

    def inspect(self, image):
        data = self.call('fixture-image-inspect', ['image', 'inspect', image], phase='verification')
        if data is None:
            return None
        result = json.loads(data)[0]
        if result['Architecture'] != 'arm64' or result['Os'] != 'linux':
            self.rows[-1]['error'] = 'wrong fixture image platform'
            return None
        return result


def run_images(docker, manifest):
    budget = manifest['suites']['images']
    for name, command, canary in (
            ('alpine', ['/bin/echo', 'image-alpine'], b'image-alpine\n'),
            ('node', ['node', '-e', 'console.log("image-node")'], b'image-node\n')):
        image = manifest['images'][name]['ref']
        if docker.call(f'{name}.public-pull', ['pull', '--platform', 'linux/arm64', image],
                       timeout=budget['timeout_seconds'], phase='setup') is None:
            continue
        source = docker.inspect(image)
        if source is None or source['Id'] != manifest['images'][name]['config_digest']:
            docker.rows[-1]['error'] = 'image config digest does not match the frozen platform manifest'
            continue
        docker.rows[-1]['pinned_manifest_advertised'] = any(
            ref.endswith('@' + image.split('@')[1]) for ref in source.get('RepoDigests') or [])
        for repetition in range(budget['samples_per_session'] + budget['warmups']):
            phase = 'warmup' if repetition < budget['warmups'] else 'sample'
            tag = f'{docker.token}:{name}-{repetition}'
            archive = docker.output / f'{name}-{repetition}.tar'
            docker.call(f'{name}.cached-public-pull', ['pull', '--platform', 'linux/arm64', image],
                        timeout=budget['timeout_seconds'], phase=phase)
            if docker.call('fixture-tag', ['image', 'tag', image, tag], phase='setup') is None:
                continue
            try:
                if docker.call(f'{name}.save', ['image', 'save', '--output', archive, tag],
                               timeout=budget['timeout_seconds'], phase=phase) is None:
                    continue
                with archive.open('rb') as stream:
                    docker.rows[-1].update(bytes=archive.stat().st_size,
                                           sha256=hashlib.file_digest(stream, 'sha256').hexdigest())
                if docker.call(f'{name}.remove-tag', ['image', 'rm', tag], phase=phase) is None:
                    continue
                if docker.call(f'{name}.warm-load', ['image', 'load', '--input', archive],
                               timeout=budget['timeout_seconds'], phase=phase) is None:
                    continue
                checked = docker.inspect(tag)
                if checked is None or checked['Id'] != source['Id']:
                    docker.rows[-1]['error'] = 'loaded image identity differs from saved source'
                    continue
                docker.call(f'{name}.ready-to-run', [
                    'run', '--rm', '--pull', 'never', '--network', 'none', '--label',
                    f'{LABEL}={docker.token}', tag, *command], expected=canary, phase=phase)
            finally:
                archive.unlink(missing_ok=True)
                existing = docker.call('fixture-cleanup-inspect', ['image', 'ls', '--quiet', tag],
                                       phase='cleanup')
                if existing is None:
                    raise RuntimeError('could not inspect task-owned image cleanup')
                if existing and docker.call('fixture-cleanup-remove-tag', ['image', 'rm', tag],
                                            phase='cleanup') is None:
                    raise RuntimeError('could not remove task-owned image tag')

    run_registry(docker, manifest)


def archive_member(archive, name, data, mode=0o644):
    entry = tarfile.TarInfo(name)
    entry.size = len(data)
    entry.mode = mode
    archive.addfile(entry, io.BytesIO(data))


def registry_image(executable, size, layers, pair, repetition):
    parts = []
    diff_ids = []
    for index in range(layers):
        content = io.BytesIO()
        with tarfile.open(fileobj=content, mode='w') as archive:
            if index == 0:
                archive_member(archive, 'probe', executable, 0o555)
            seed = f'conjet-registry-v2:{size}:{layers}:{pair}:{repetition}:{index}'
            data = hashlib.shake_256(seed.encode()).digest(size)
            archive_member(archive, f'payload-{index}', data)
        body = content.getvalue()
        diff_ids.append('sha256:' + hashlib.sha256(body).hexdigest())
        parts.append(gzip.compress(body, mtime=0))
    config = json.dumps({'architecture': 'arm64', 'os': 'linux', 'config': {'Cmd': ['/probe']},
                         'rootfs': {'type': 'layers', 'diff_ids': diff_ids}},
                        sort_keys=True, separators=(',', ':')).encode()
    return config, parts


def registry_request(connection, method, path, expected, body=None, media_type=None):
    headers = {'Content-Type': media_type} if media_type else {}
    connection.request(method, path, body=body, headers=headers)
    response = connection.getresponse()
    data = response.read(8193)
    if response.status != expected or len(data) > 8192:
        connection.close()
        raise RuntimeError(f'owned registry {method} returned {response.status}: {data[:400]!r}')
    return response


def seed_registry(connection, address, repository, tag, config, layers):
    image_type = 'application/vnd.docker.distribution.manifest.v2+json'

    def blob(data, media_type):
        digest = 'sha256:' + hashlib.sha256(data).hexdigest()
        prefix = f'/v2/{repository}/blobs/uploads/'
        reply = registry_request(connection, 'POST', prefix, 202, b'')
        upload = urlsplit(reply.getheader('Location', ''))
        if ((upload.netloc and upload.netloc != address) or upload.scheme not in ('', 'http')
                or not upload.path.startswith(prefix) or not upload.path.removeprefix(prefix)):
            raise RuntimeError('registry returned an unexpected upload location')
        query = upload.query + '&' if upload.query else ''
        reply = registry_request(connection, 'PUT', upload.path + '?' + query + 'digest=' + digest,
                                 201, data, 'application/octet-stream')
        if reply.getheader('Docker-Content-Digest') != digest:
            raise RuntimeError('registry blob digest does not match uploaded bytes')
        return {'mediaType': media_type, 'digest': digest, 'size': len(data)}

    image = {'schemaVersion': 2, 'mediaType': image_type,
             'config': blob(config, 'application/vnd.docker.container.image.v1+json'),
             'layers': [blob(layer, 'application/vnd.docker.image.rootfs.diff.tar.gzip') for layer in layers]}
    body = json.dumps(image, separators=(',', ':')).encode()
    response = registry_request(connection, 'PUT', f'/v2/{repository}/manifests/{tag}', 201, body, image_type)
    manifest_id = 'sha256:' + hashlib.sha256(body).hexdigest()
    if response.getheader('Docker-Content-Digest') != manifest_id:
        raise RuntimeError('registry manifest digest does not match uploaded bytes')
    return manifest_id, image


def received_blobs(log, repository):
    matched = {}
    for line in log.splitlines():
        if 'http.request.method=GET ' not in line or not re.search(r'http\.response\.status=200(?:\s|$)', line):
            continue
        uri = re.search(r'http.request.uri="([^"]+)"', line)
        written = re.search(r'http.response.written=(\d+)', line)
        if not uri or not written or not uri[1].startswith(f'/v2/{repository}/blobs/'):
            continue
        digest = uri[1].rsplit('/', 1)[-1]
        matched[digest] = max(matched.get(digest, 0), int(written[1]))
    return matched


def run_registry(docker, manifest):
    budget = manifest['suites']['images']
    path = Path('/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-evidence/SPEED-008/common-image/image/workload')
    executable = path.read_bytes()
    if hashlib.sha256(executable).hexdigest() != manifest['common_static_fixture']['executable_sha256']:
        raise RuntimeError('controlled registry executable differs from the manifest')
    image = manifest['images']['registry']['ref']
    if docker.call('registry-prepull', ['pull', '--platform', 'linux/arm64', image], phase='setup') is None:
        return
    name = docker.token + '-registry'
    if docker.call('registry-start', ['run', '--rm', '-d', '--name', name, '--pull', 'never',
                  '--label', f'{LABEL}={docker.token}', '--publish', '127.0.0.1::5000', image],
                   phase='setup') is None:
        return
    connection = None
    try:
        address = docker.call('registry-port', ['port', name, '5000/tcp'], phase='verification')
        if address is None:
            return
        address = address.decode().strip()
        parsed = urlsplit('http://' + address)
        if parsed.hostname != '127.0.0.1' or parsed.port is None:
            docker.rows[-1]['error'] = 'owned registry did not publish a loopback port'
            return
        pair = json.loads((docker.output.parent / 'pair.json').read_text())['pair']
        if pair not in range(1, 6):
            raise ValueError('controlled registry requires a declared pair index')
        connection = http.client.HTTPConnection('127.0.0.1', parsed.port, timeout=10)
        deadline = time.monotonic() + 10
        while True:
            try:
                registry_request(connection, 'GET', '/v2/', 200)
                break
            except (OSError, RuntimeError, http.client.HTTPException):
                connection.close()
                if time.monotonic() >= deadline:
                    raise
                time.sleep(0.25)
        for label, size, layers in (('small', 64 * 1024, 1), ('multilayer', 1024 * 1024, 3)):
            for repetition in range(budget['samples_per_session'] + budget['warmups']):
                phase = 'warmup' if repetition < budget['warmups'] else 'sample'
                repository = f'{docker.token}/{label}'
                base, contents = registry_image(executable, size, layers, pair, repetition)
                manifest_id, descriptors = seed_registry(connection, address, repository, str(repetition), base, contents)
                expected = {item['digest']: item['size'] for item in [descriptors['config'], *descriptors['layers']]}
                reference = f'{address}/{repository}@{manifest_id}'
                try:
                    since = datetime.now(timezone.utc).isoformat()
                    if docker.call(f'registry.{label}.first-pull', ['pull', reference], phase=phase, timeout=180) is None:
                        continue
                    first = docker.rows[-1]
                    first.update(cache_state='no engine-side seed; transfer unknown', expected_registry_blobs=expected)
                    docker.call('registry-transfer-observation', ['logs', '--since', since, name],
                                phase='verification')
                    logs = docker.rows[-1]
                    returned = received_blobs(logs.get('stderr', '') + logs.get('stdout', ''), repository)
                    first['registry_blobs_returned'] = returned
                    if all(returned.get(digest) == length for digest, length in expected.items()):
                        first['cache_state'] = 'complete config and layer transfer observed'
                    checked = docker.inspect(reference)
                    if checked is None or checked['Id'] != descriptors['config']['digest']:
                        first['error'] = 'registry pull changed image identity'
                        continue
                    docker.call(f'registry.{label}.cached', ['pull', reference], phase=phase, timeout=180)
                    if docker.call('registry-run-proof', ['run', '--rm', '--pull', 'never', '--network',
                                   'none', '--label', f'{LABEL}={docker.token}', reference],
                                   phase='verification', expected=b'') is None:
                        first['error'] = 'registry runnable layers failed the canary'
                finally:
                    existing = docker.call('registry-fixture-inventory', ['image', 'ls', '--digests',
                                           '--format', '{{.Repository}}@{{.Digest}}', f'{address}/{repository}'],
                                           phase='cleanup')
                    if existing is None:
                        raise RuntimeError('could not verify registry fixture cleanup')
                    if reference.encode() in existing.splitlines() and docker.call(
                            'registry-fixture-remove', ['image', 'rm', reference], phase='cleanup') is None:
                        raise RuntimeError('could not remove registry fixture')
    finally:
        if connection is not None:
            connection.close()
        docker.call('registry-log', ['logs', '--tail', '100', name], phase='verification')
        if docker.call('registry-stop', ['stop', '--time', '2', name], phase='cleanup') is None:
            raise RuntimeError('could not stop the owned registry')



def descriptor_fields(text, key):
    return [value.strip() for name, _, value in (line.strip().partition(':') for line in text.splitlines())
            if name == key]


def prepare_files(language, directory):
    directory.mkdir()
    if language == 'go':
        sources = {
            'go.mod': 'module example.com/build\ngo 1.23\nrequire example.com/dep v0.0.0\nreplace example.com/dep => ./dep\n',
            'dep/go.mod': 'module example.com/dep\ngo 1.23\n',
            'dep/dep.go': 'package dep\nconst Word = "dep-one"\n',
            'main.go': ('package main\nimport ("fmt"; "example.com/dep")\n'
                        'func main(){fmt.Println("source-one", dep.Word)}\n'),
        }
        return sources, 'main.go', 'dep/dep.go', [
            'COPY go.mod ./', 'COPY dep ./dep', 'COPY main.go ./',
            'RUN CGO_ENABLED=0 GOPROXY=off GOTOOLCHAIN=local go build -trimpath -o /out ./',
        ]
    if language == 'rust':
        sources = {
            'Cargo.toml': ('[package]\nname="build_canary"\nversion="0.1.0"\nedition="2021"\n'
                           '[dependencies]\ndep={path="dep"}\n'),
            'dep/Cargo.toml': '[package]\nname="dep"\nversion="0.1.0"\nedition="2021"\n',
            'dep/src/lib.rs': 'pub const WORD: &str = "dep-one";\n',
            'src/main.rs': 'fn main(){println!("source-one {}", dep::WORD);}\n',
        }
        return sources, 'src/main.rs', 'dep/src/lib.rs', [
            'COPY Cargo.toml ./', 'COPY dep ./dep', 'COPY src ./src',
            'RUN cargo build --offline --release && cp target/release/build_canary /out',
        ]
    sources = {
        'package.json': '{"name":"build-canary","version":"1.0.0","private":true,"dependencies":{"dependency":"file:./dep"}}\n',
        'dep/package.json': '{"name":"dependency","version":"1.0.0","main":"index.js"}\n',
        'dep/index.js': 'module.exports = "dep-one";\n',
        'main.js': 'console.log("source-one", require("dependency"));\n',
    }
    return sources, 'main.js', 'dep/index.js', [
        'COPY package.json ./', 'COPY dep ./dep',
        'RUN npm install --offline --no-audit --no-fund --ignore-scripts --install-links',
        'COPY main.js ./', 'RUN mkdir /out && cp -R main.js node_modules /out/',
    ]


def build_context_args(build_bases, manifest, language):
    compiler = {'rust': 'rust', 'go': 'golang', 'node': 'node'}[language]
    runtime = 'node' if language == 'node' else 'alpine'
    if build_bases is None:
        return manifest['images'][compiler]['ref'], manifest['images'][runtime]['ref'], []
    root = build_bases.resolve(strict=True)
    if not root.is_relative_to(Path('/Volumes/ExternalSSD/dev_workspace/tmp')):
        raise ValueError('OCI build bases must be on ExternalSSD')
    contexts = []
    for alias, key in (('compiler-base', compiler), ('runtime-base', runtime)):
        layout = (root / key).resolve(strict=True)
        digest = manifest['images'][key]['ref'].split('@')[1]
        locator = layout / 'index.json'
        if not layout.is_relative_to(root) or locator.is_symlink():
            raise ValueError('OCI build base index must stay inside the bundle')
        index = json.loads(locator.read_bytes())
        if [row['digest'] for row in index['manifests']] != [digest]:
            raise ValueError('OCI build base index does not match the frozen manifest')
        contexts.extend(['--build-context', f'{alias}=oci-layout://{layout}@{digest}'])
    return 'compiler-base', 'runtime-base', contexts


def run_builds(docker, manifest, context, build_bases=None):
    budget = manifest['suites']['builds']
    for language in budget['workloads']:
        image, runtime, image_contexts = build_context_args(build_bases, manifest, language)
        for repetition in range(budget['samples_per_session']):
            builder = f'{docker.token}-{language}-{repetition}'
            pin = manifest['images']['buildkit']['ref']
            create = docker.call('builder-create', ['buildx', 'create', '--name', builder,
                                 '--driver', 'docker-container', '--driver-opt', f'image={pin}',
                                 context], phase='setup')
            if create is None:
                break
            directory = docker.output / builder
            tag = f'{docker.token}:{language}-{repetition}'
            try:
                details = docker.call('builder-bootstrap', ['buildx', 'inspect', '--bootstrap', builder],
                                      timeout=180, phase='setup')
                if details is None:
                    break
                report = details.decode()
                endpoint = 'unix://' + docker.report['endpoint']
                if (descriptor_fields(report, 'Driver') != ['docker-container']
                        or not set(descriptor_fields(report, 'Endpoint')).issubset({context, endpoint})
                        or not descriptor_fields(report, 'Endpoint')
                        or descriptor_fields(report, 'BuildKit version') != [manifest['images']['buildkit']['tag']]):
                    docker.rows[-1]['error'] = 'builder endpoint, driver or version did not match the manifest'
                    break
                state = docker.call('builder-backing', ['inspect', f'buildx_buildkit_{builder}0'],
                                    phase='verification')
                if state is None:
                    break
                mounts = json.loads(state)[0]['Mounts']
                owned = [mount for mount in mounts if mount['Destination'] == '/var/lib/buildkit'
                         and mount['Type'] == 'volume'
                         and mount['Name'] == f'buildx_buildkit_{builder}0_state']
                if len(owned) != 1:
                    docker.rows[-1]['error'] = 'builder does not own its designated cache volume'
                    break
                # A new builder has no application cache. Preload only base
                # images inside that builder, outside the measured interval.
                sources, source, dependency, actions = prepare_files(language, directory)
                dockerfile = directory / 'Dockerfile'
                dockerfile.write_text(f'FROM {image} AS compiler\nFROM {runtime}\nCOPY --from=compiler /etc/os-release /base-release\n')
                prefix = ['buildx', 'build', '--builder', builder, '--platform', 'linux/arm64',
                          '--network', 'none', '--progress', 'plain', *image_contexts]
                if docker.call('preload-builder-bases', [*prefix, '--output', 'type=cacheonly', directory],
                               timeout=budget['timeout_seconds'], phase='setup') is None:
                    break
                for path, content in sources.items():
                    target = directory / path
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_text(content)
                export = ('COPY --from=compiler /out /app\nCMD ["node","/app/main.js"]'
                          if language == 'node' else 'COPY --from=compiler /out /app\nCMD ["/app"]')
                dockerfile.write_text(f'FROM {image} AS compiler\nWORKDIR /src\n' +
                                      '\n'.join(actions) + f'\nFROM {runtime}\n' + export + '\n')
                for change, expected in (('empty', b'source-one dep-one\n'),
                                         ('unchanged', b'source-one dep-one\n'),
                                         ('source', b'source-two dep-one\n'),
                                         ('dependency', b'source-two dep-two\n')):
                    if change == 'source':
                        (directory / source).write_text(sources[source].replace('source-one', 'source-two'))
                    if change == 'dependency':
                        (directory / dependency).write_text(sources[dependency].replace('dep-one', 'dep-two'))
                    archive = docker.output / (builder + '.tar')
                    try:
                        if docker.call(f'{language}.{change}.build-export',
                                       [*prefix, '--tag', tag, '--output', f'type=docker,dest={archive}', directory],
                                       timeout=budget['timeout_seconds'], phase='sample') is None:
                            break
                        build = docker.rows[-1]
                        build['archive_bytes'] = archive.stat().st_size
                        if docker.call(f'{language}.{change}.load', ['image', 'load', '--input', archive],
                                       timeout=180, phase='sample') is None:
                            build['error'] = 'exported image failed to load'
                            break
                        load = docker.rows[-1]
                        if docker.call(f'{language}.{change}.built-image-canary',
                                       ['run', '--rm', '--network', 'none', '--pull', 'never',
                                              '--label', f'{LABEL}={docker.token}', tag],
                                       expected=expected, phase='verification') is None:
                            build['error'] = load['error'] = 'exported image failed its execution canary'
                            break
                    finally:
                        archive.unlink(missing_ok=True)
            finally:
                existing = docker.call('fixture-cleanup-inspect', ['image', 'ls', '--quiet', tag], phase='cleanup')
                if existing is None:
                    raise RuntimeError('could not verify task-owned build image cleanup')
                if existing and docker.call('fixture-image-remove', ['image', 'rm', tag], phase='cleanup') is None:
                    raise RuntimeError('could not remove task-owned build result')
                if docker.call('builder-remove', ['buildx', 'rm', builder], phase='cleanup') is None:
                    raise RuntimeError('could not remove task-owned builder')


APP = r"""
const http = require('http');
const net = require('net');
function redis(command) {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection(6379, 'redis', () => socket.write(command + '\r\n'));
    socket.setTimeout(1500, () => socket.destroy(new Error('redis timeout')));
    let data = '';
    socket.on('data', chunk => {
      data += chunk.toString();
      if (data.includes('\r\n')) {
        socket.destroy();
        if (data[0] === '-') reject(new Error(data));
        else resolve(data.trim());
      }
    });
    socket.once('error', reject);
    socket.once('end', () => reject(new Error('redis disconnected')));
  });
}
http.createServer(async (request, response) => {
  try {
    const cmd = request.url === '/health' ? 'PING' : 'INCR visits';
    const reply = await redis(cmd);
    response.end(process.env.PROOF + ' ' + reply);
  } catch {
    response.statusCode = 503;
    response.end('unavailable');
  }
}).listen(8080, '0.0.0.0');
"""


def compose_definition(manifest, proof):
    limits = manifest['service_limits']
    resource = {'mem_limit': limits['memory_bytes'], 'pids_limit': limits['pids'],
                'cpus': limits['cpu_millicores'] / 1000}
    ready = ("fetch('http://127.0.0.1:8080/health')"
             ".then(async r=>{if(!r.ok || !(await r.text()).endsWith(' +PONG'))process.exit(1)})"
             ".catch(()=>process.exit(1))")
    health = {'interval': '1s', 'timeout': '2s', 'retries': 12}
    return {'services': {
        'app': {**resource, 'image': manifest['images']['node']['ref'],
                'command': ['node', '-e', APP], 'environment': {'PROOF': proof},
                'ports': ['127.0.0.1::8080'],
                'depends_on': {'redis': {'condition': 'service_healthy'}},
                'healthcheck': {**health, 'test': ['CMD', 'node', '-e', ready]}},
        'redis': {**resource, 'image': manifest['images']['redis']['ref'],
                  'command': ['redis-server', '--appendonly', 'yes', '--appendfsync', 'always'],
                  'volumes': ['cache:/data'],
                  'healthcheck': {**health, 'test': ['CMD', 'redis-cli', 'ping']}}},
        'volumes': {'cache': {}}}


def published_endpoint(docker, prefix, index=1):
    port = docker.call('compose-published-port', [*prefix, 'port', '--index', str(index), 'app', '8080'],
                       phase='verification')
    if port is None:
        return None
    endpoint = urlsplit('http://' + port.decode().strip())
    if endpoint.hostname != '127.0.0.1' or endpoint.port is None:
        docker.rows[-1]['error'] = 'published port was not loopback scoped'
        return None
    return f'http://127.0.0.1:{endpoint.port}'


def read_response(reader, url):
    with reader.open(url, timeout=4) as response:
        if response.geturl() != url:
            raise ValueError('unexpected redirect in the application probe')
        return response.read(128).decode()


def transaction(docker, reader, url, proof, scenario='compose.transaction'):
    if url is None:
        return None
    url += '/transaction'
    start = time.monotonic_ns()
    try:
        body = read_response(reader, url)
        duration = time.monotonic_ns() - start
        marker, value = body.split(' :')
        if marker != proof:
            raise ValueError('application response from unexpected service')
        units = int(value)
        docker.rows.append({'scenario': scenario, 'phase': 'verification',
                            'endpoint': url, 'elapsed_ns': duration, 'visits': units, 'error': None})
        return units
    except (OSError, ValueError) as error:
        docker.rows.append({'scenario': scenario, 'phase': 'verification',
                            'elapsed_ns': None, 'error': str(error)})
        return None


def check_service_limits(docker, prefix, spec):
    verified = True
    for service in ('app', 'redis'):
        observed = docker.call(f'service.{service}.cgroup', [*prefix, 'exec', '-T', service, 'cat',
                               '/sys/fs/cgroup/memory.max', '/sys/fs/cgroup/pids.max',
                               '/sys/fs/cgroup/cpu.max'], phase='verification')
        if observed is None:
            verified = False
        elif not matches_cgroup_limits(observed, spec):
            docker.rows[-1]['error'] = 'effective cgroup limits differ from the requested service resources'
            verified = False
    return verified


def run_compose(docker, manifest):
    budget = manifest['suites']['compose']
    for image in ('node', 'redis'):
        if docker.call('compose-prepull', ['pull', '--platform', 'linux/arm64',
                       manifest['images'][image]['ref']], timeout=180, phase='setup') is None:
            return
    for repetition in range(budget['samples_per_session'] + budget['warmups']):
        phase = 'warmup' if repetition < budget['warmups'] else 'sample'
        proof = f'{docker.token}-{repetition}'
        definition = docker.output / f'{proof}.compose.json'
        definition.write_text(json.dumps(compose_definition(manifest, proof), indent=2))
        prefix = ['compose', '--project-name', proof, '--file', definition]
        up = ['up', '--detach', '--wait', '--wait-timeout', '35', '--pull', 'never']
        try:
            previous = 0
            for case, command, replicas in (
                    ('up', up, 1), ('no-change', up, 1),
                    ('recreate', [*up, '--force-recreate', '--no-deps', 'app'], 1),
                    ('scale', [*up, '--scale', 'app=2'], 2),
                    ('restart', ['restart', 'redis'], 2)):
                if docker.call(f'compose.{case}', [*prefix, *command], phase=phase,
                               timeout=budget['timeout_seconds']) is None:
                    break
                timed = docker.rows[-1]
                if case == 'up' and not check_service_limits(docker, prefix, manifest['service_limits']):
                    docker.report['service_limits_matched'] = False
                else:
                    docker.report.setdefault('service_limits_matched', True)
                for replica in range(1, replicas + 1):
                    endpoint = published_endpoint(docker, prefix, replica)
                    reader = build_opener(ProxyHandler({}))
                    if case == 'restart' and endpoint is not None:
                        # Read-only readiness is retryable. Never replay a
                        # transaction when its result might have been lost.
                        start = time.monotonic_ns()
                        deadline = time.monotonic() + 15
                        ready = False
                        while time.monotonic() < deadline:
                            try:
                                ready = read_response(reader, endpoint + '/health') == proof + ' +PONG'
                            except OSError:
                                pass
                            if ready:
                                break
                            time.sleep(0.2)
                        docker.rows.append({'scenario': 'compose.restart-ready', 'phase': phase,
                                            'elapsed_ns': time.monotonic_ns() - start,
                                            'error': None if ready else 'application did not recover'})
                        if not ready:
                            timed['error'] = 'application did not recover after restart'
                            break
                    observed = transaction(docker, reader, endpoint, proof)
                    if observed is None or observed != previous + 1:
                        docker.rows[-1]['error'] = 'did not observe the persisted transaction sequence'
                        timed['error'] = 'application transaction failed after this Compose command'
                        break
                    previous = observed
                else:
                    continue
                break
        finally:
            docker.call('compose-logs', [*prefix, 'logs', '--no-color'], phase='verification')
            if docker.call('compose.down', [*prefix, 'down', '--volumes', '--timeout', '2'],
                           phase=phase, timeout=budget['timeout_seconds']) is None:
                raise RuntimeError('could not tear down the owned Compose project')
            for kind, subcommand in [('containers', ['ps', '-aq']),
                                     ('volumes', ['volume', 'ls', '-q']),
                                     ('networks', ['network', 'ls', '-q'])]:
                remainder = docker.call(f'compose-cleanup-{kind}', [*subcommand, '--filter',
                                       f'label=com.docker.compose.project={proof}'], phase='cleanup')
                if remainder is None or remainder.strip():
                    raise RuntimeError(f'Compose project left resources: {kind}')


def lifecycle_event_order(data, identifier):
    actions = []
    for line in data.splitlines():
        event = json.loads(line)
        if event.get('Actor', {}).get('ID') != identifier:
            return False
        actions.append(event.get('Action'))
    expected = iter(('create', 'start', 'die', 'destroy'))
    next_action = next(expected)
    for action in actions:
        if action == next_action:
            next_action = next(expected, None)
    return next_action is None


def run_attach(docker, image, options, phase, index):
    name = f'{docker.token}-attach-{index}'
    since = datetime.now(timezone.utc).isoformat()
    created = docker.call('attach-create', ['create', '-i', '--name', name, *options, image,
                          'sh', '-c', 'read -r line || exit 91; printf "out:%s" "$line"; '
                          'printf "err:%s" "$line" >&2; exit 23'], phase='setup')
    if created is None:
        return
    removed = False
    try:
        if docker.call('attach-start', ['start', name], phase='setup') is None:
            return
        docker.call('attach.stdin-streams', ['attach', name], timeout=20, phase=phase,
                    stdin=b'attach-proof\n', expected=b'out:attach-proof', expected_stderr=b'err:attach-proof',
                    expected_code=23)
        docker.call('logs.streams', ['logs', name], phase=phase,
                    expected=b'out:attach-proof', expected_stderr=b'err:attach-proof')
        removed = docker.call('attach-remove', ['rm', name], phase='cleanup') is not None
        if not removed:
            return
        identifier = created.decode().strip()
        events = docker.call('events.lifecycle', ['events', '--since', since, '--until',
                             datetime.now(timezone.utc).isoformat(), '--filter', 'type=container',
                             '--filter', f'container={identifier}', '--format', '{{json .}}'],
                             timeout=15, phase=phase)
        if events is not None and not lifecycle_event_order(events, identifier):
            docker.rows[-1]['error'] = 'owned lifecycle events are missing or out of order'
    finally:
        if not removed and docker.call('attach-force-remove', ['rm', '-f', name], phase='cleanup') is None:
            raise RuntimeError('could not remove the owned attach container')


def control_api(docker, connection, workloads, api_version, identifier, phase):
    prefix = '/v' + api_version
    api = workloads['TOOLS']['api']

    def exec_canary():
        created = api(connection, 'POST', f'{prefix}/containers/{identifier}/exec', (201,), {
            'AttachStdout': True, 'AttachStderr': True, 'Tty': False, 'Cmd': [
                'sh', '-c', 'printf exec-out; printf exec-err >&2; exit 23']})
        exec_id = created['Id']
        if not re.fullmatch(r'[0-9a-f]{12,64}', exec_id):
            raise ValueError('API returned an invalid exec ID')
        path = f'{prefix}/exec/{exec_id}'
        streams = workloads['docker_streams'](connection, 'POST', path + '/start', {'Detach': False, 'Tty': False})
        state = api(connection, 'GET', path + '/json', (200,))
        return streams == (b'exec-out', b'exec-err') and state['ExitCode'] == 23 and not state['Running']

    def inspect_canary():
        state = api(connection, 'GET', f'{prefix}/containers/{identifier}/json', (200,))
        return state['Id'] == identifier and state['State']['Running']

    for case, action in [('exec.api', exec_canary), ('inspect.api', inspect_canary)]:
        start = time.monotonic_ns()
        error = None
        try:
            if not action():
                error = 'Docker API canary failed'
        except (OSError, http.client.HTTPException, RuntimeError, ValueError, KeyError) as failure:
            error = str(failure)
            connection.close()
        docker.rows.append({'scenario': case, 'phase': phase, 'error': error,
                            'elapsed_ns': time.monotonic_ns() - start})


def run_control(docker, manifest, connection):
    budget = manifest['suites']['control']
    image = manifest['images']['alpine']['ref']
    if docker.call('control-prepull', ['pull', '--platform', 'linux/arm64', image], phase='setup') is None:
        return
    target = f'{docker.token}-control'
    args = ['--network', 'none', '--label', f'{LABEL}={docker.token}']
    started = docker.call('control-start', ['run', '-d', '--name', target, *args, image, 'sleep', '1800'],
                          phase='setup')
    if started is None:
        return
    try:
        identifier = started.decode().strip()
        if not re.fullmatch(r'[0-9a-f]{12,64}', identifier):
            raise ValueError('client returned an invalid control container ID')
        workloads = runpy.run_path(str(Path(__file__).with_name('docker-comparison-workloads.py')))
        docker.call('exec.large-output', ['exec', target, 'dd', 'if=/dev/zero', 'bs=1024', 'count=128'],
                    expected=bytes(128 * 1024), phase='verification')
        docker.call('exec.tty', ['exec', '-t', target, 'sh', '-c', 'test -t 1 && printf tty-ok'],
                    expected=b'tty-ok', phase='verification')
        # A deliberately idle attach must time out without harming the owner.
        docker.call('attach.disconnect', ['attach', '--no-stdin', target], timeout=2,
                    phase='verification')
        if docker.rows[-1].get('timed_out'):
            docker.rows[-1].update(error=None, expected_disconnect=True)
            docker.call('attach.disconnect-recovery', ['exec', target, 'printf', 'still-running'],
                        expected=b'still-running', phase='verification')
        else:
            docker.rows[-1]['error'] = 'idle attach returned before the client disconnect deadline'
        for i in range(budget['samples_per_session'] + budget['warmups']):
            phase = 'warmup' if i < budget['warmups'] else 'sample'
            docker.call('exec.streams', ['exec', target, 'sh', '-c',
                        'printf exec-out; printf exec-err >&2; exit 23'],
                        phase=phase, expected=b'exec-out', expected_code=23, expected_stderr=b'exec-err')
            docker.call('inspect.one', ['inspect', target], phase=phase)
            docker.call('list.one', ['ps', '-aq', '--filter', f'label={LABEL}={docker.token}'], phase=phase)
            control_api(docker, connection, workloads, manifest['docker_api'], identifier, phase)
            run_attach(docker, image, args, phase, i)
            # File data is deterministic. Its transfers and integrity checks
            # are distinct from CLI execution timing.
            source = docker.output / 'control-input'
            restored = docker.output / 'control-output'
            for size in (4096, 8 * 1024 * 1024):
                source.write_bytes(b'conjet-control-1' * (size // 16))
                if docker.call(f'cp.in.{size}', ['cp', source, f'{target}:/tmp/control'],
                               phase=phase) is None:
                    continue
                if docker.call(f'cp.out.{size}', ['cp', f'{target}:/tmp/control', restored],
                               phase=phase) is None:
                    continue
                if hashlib.sha256(source.read_bytes()).digest() != hashlib.sha256(restored.read_bytes()).digest():
                    docker.rows[-1]['error'] = 'roundtrip SHA-256 mismatch'
                restored.unlink()
    finally:
        (docker.output / 'control-input').unlink(missing_ok=True)
        (docker.output / 'control-output').unlink(missing_ok=True)
        if docker.call('control-remove', ['rm', '-f', target], phase='cleanup') is None:
            raise RuntimeError('could not remove owned persistent container')


def run_matrix(mode, manifest, report, output, prefix, env, build_bases=None, connection=None):
    docker = Docker(prefix, env, output, report)
    context = {'conjet': 'conjet-speedup', 'kiri': 'kiri-speedup'}[report['engine']]
    actions = {
        'images': lambda: run_images(docker, manifest),
        'builds': lambda: run_builds(docker, manifest, context, build_bases),
        'compose': lambda: run_compose(docker, manifest),
        'control': lambda: run_control(docker, manifest, connection),
        'storage_network': lambda: run_storage(docker, manifest),
        'stress': lambda: run_stress(docker, manifest),
    }
    try:
        actions[mode]()
    finally:
        remaining = docker.call('fixture-leak-inventory',
                                ['ps', '-aq', '--filter', f'label={LABEL}={docker.token}'], phase='cleanup')
        if remaining is None:
            raise RuntimeError('could not verify task-owned container cleanup')
        for identifier in remaining.decode().splitlines():
            if not identifier or not all(c in '0123456789abcdef' for c in identifier):
                raise RuntimeError('engine returned an invalid ID for cleanup')
            if docker.call('fixture-recovered-container', ['rm', '-f', identifier], phase='cleanup') is None:
                raise RuntimeError('could not remove owned container')
        if remaining:
            raise RuntimeError('a workload left containers that required cleanup')


STORAGE = r"""
const fs = require('fs');
const crypto = require('crypto');
const bytes = 16 * 1024 * 1024;
const record = Buffer.alloc(4096, 0x43);
const buffer = Buffer.alloc(bytes, 0x43);
const measured = {};
const measure = (label, fn) => {
  const start = process.hrtime.bigint();
  fn();
  measured[label] = Number(process.hrtime.bigint() - start);
};
const path = '/dataset/test';
let fd;
measure('write_fsync', () => {
  fd = fs.openSync(path, 'wx+');
  let offset = 0;
  while (offset < bytes) offset += fs.writeSync(fd, buffer, offset, bytes - offset);
  fs.fsyncSync(fd);
  fs.closeSync(fd);
});
measure('read_sha256', () => {
  const read = fs.readFileSync(path);
  if (read.length !== bytes || !crypto.timingSafeEqual(
    crypto.createHash('sha256').update(read).digest(),
    crypto.createHash('sha256').update(buffer).digest())) throw new Error('data mismatch');
});
measure('random_read', () => {
  fd = fs.openSync(path, 'r');
  for (let i = 0; i < 1024; i++) {
    const contents = Buffer.alloc(4096);
    if (fs.readSync(fd, contents, 0, contents.length, ((i * 1031) & 4095) * 4096) !== 4096
        || !contents.equals(record)) throw new Error('random read canary mismatch');
  }
  fs.closeSync(fd);
});
measure('small_file_metadata', () => {
  for (let i = 0; i < 128; i++) fs.writeFileSync('/dataset/r' + i, record, {flag:'wx'});
  for (let i = 0; i < 128; i++) if (fs.statSync('/dataset/r' + i).size !== 4096) throw new Error('metadata mismatch');
});
console.log(JSON.stringify({bytes, measured, trace:crypto.createHash('sha256').update(buffer).digest('hex')}));
"""


def run_storage(docker, manifest):
    budget = manifest['suites']['storage_network']
    image = manifest['images']['node']['ref']
    if docker.call('storage-prepull', ['pull', '--platform', 'linux/arm64', image], phase='setup') is None:
        return
    for repetition in range(budget['samples_per_session'] + budget['warmups']):
        phase = 'warmup' if repetition < budget['warmups'] else 'sample'
        for store in ('writable-layer', 'volume', 'bind'):
            name = f'{docker.token}-{store}-{repetition}'
            host = docker.output / name
            mount = []
            if store == 'volume':
                if docker.call('volume-create', ['volume', 'create', '--label',
                               f'{LABEL}={docker.token}', name], phase='setup') is None:
                    continue
                mount = ['--mount', f'type=volume,source={name},target=/dataset']
            elif store == 'bind':
                host.mkdir()
                mount = ['--mount', f'type=bind,source={host},target=/dataset']
            try:
                result = docker.call(f'storage.{store}', [
                    'run', '--rm', '--pull', 'never', '--network', 'none',
                    '--label', f'{LABEL}={docker.token}', *mount, image, 'sh', '-c',
                    'mkdir -p /dataset && exec node -e "$1"', 'sh', STORAGE],
                    timeout=budget['timeout_seconds'], phase=phase)
                if result is not None:
                    data = json.loads(result)
                    docker.rows[-1]['guest'] = data
                    if data['bytes'] != 16 * 1024 * 1024:
                        docker.rows[-1]['error'] = 'unexpected sequential dataset size'
                    if store == 'bind':
                        check = host / 'test'
                        with check.open('rb') as stream:
                            digest = hashlib.file_digest(stream, 'sha256').hexdigest()
                        if digest != data['trace']:
                            docker.rows[-1]['error'] = 'host bind proof differs from guest proof'
                    if store == 'volume':
                        verify = ('const fs=require("fs"), crypto=require("crypto");'
                                  'const data=fs.readFileSync("/dataset/test");'
                                  'console.log(crypto.createHash("sha256").update(data).digest("hex"));')
                        if docker.call('storage.volume.readback', ['run', '--rm', '--pull', 'never',
                                       '--network', 'none', '--label', f'{LABEL}={docker.token}', *mount,
                                       image, 'node', '-e', verify], phase='verification',
                                       expected=(data['trace'] + '\n').encode()) is None:
                            docker.rows[-2]['error'] = 'new container did not recover the fsynced volume data'
            finally:
                if store == 'volume':
                    if docker.call('volume-remove', ['volume', 'rm', name], phase='cleanup') is None:
                        raise RuntimeError('storage fixture volume remained')
                if store == 'bind':
                    # The bind fixture creates only known one-level files.
                    for item in host.iterdir():
                        item.unlink()
                    host.rmdir()

    run_service(docker, manifest)


def run_service(docker, manifest):
    for image in ('node', 'redis'):
        if docker.call('service-prepull', ['pull', '--platform', 'linux/arm64',
                       manifest['images'][image]['ref']], timeout=180, phase='setup') is None:
            return
    proof = docker.token + '-service'
    definition = docker.output / (proof + '.compose.json')
    definition.write_text(json.dumps(compose_definition(manifest, proof), indent=2))
    prefix = ['compose', '--project-name', proof, '--file', definition]
    try:
        if docker.call('service-setup', [*prefix, 'up', '--detach', '--wait', '--wait-timeout', '35',
                                         '--pull', 'never'], timeout=120, phase='setup') is None:
            return
        endpoint = published_endpoint(docker, prefix)
        if endpoint is None:
            return
        docker.call('service-dns-and-tcp', [*prefix, 'exec', '-T', 'app', 'node', '-e',
                    "require('dns').lookup('redis', e=>{if(e)process.exit(1);"
                    "fetch('http://127.0.0.1:8080/health').then(r=>{if(!r.ok)process.exit(1)})"
                    ".catch(()=>process.exit(1));})"], phase='verification')
        docker.report['service_limits_matched'] = check_service_limits(docker, prefix, manifest['service_limits'])
        reader = build_opener(ProxyHandler({}))
        if read_response(reader, endpoint + '/health') != proof + ' +PONG':
            raise RuntimeError('service readiness response differs')
        begin = time.monotonic_ns()
        end = begin + manifest['suites']['storage_network']['steady_state_seconds'] * 1_000_000_000
        next_tick = begin
        expected = 1
        while time.monotonic_ns() < end:
            value = transaction(docker, reader, endpoint, proof, 'service.transaction')
            docker.rows[-1]['phase'] = 'sample'
            if value != expected:
                docker.rows[-1]['error'] = 'service acknowledged an unexpected transaction sequence'
                break
            expected += 1
            # Cap the offered rate at 100 fresh HTTP connections per second.
            next_tick += 10_000_000
            time.sleep(max(0, (next_tick - time.monotonic_ns()) / 1e9))
        docker.report.setdefault('windows_ns', {})['service.transaction'] = time.monotonic_ns() - begin
        ids = docker.call('service-container-ids', [*prefix, 'ps', '--quiet'], phase='verification')
        if ids:
            owned = ids.decode().splitlines()
            if len(owned) == 2 and all(re.fullmatch(r'[0-9a-f]{12,64}', item) for item in owned):
                docker.call('service-snapshot-stats', ['stats', '--no-stream', '--format', '{{json .}}',
                            *owned], phase='verification')
    finally:
        if docker.call('service-remove', [*prefix, 'down', '--volumes', '--timeout', '2'],
                       phase='cleanup', timeout=120) is None:
            raise RuntimeError('could not remove owned sustained service')


def matches_cgroup_limits(observed, limits):
    try:
        memory, pids, quota, period = map(int, observed.split())
    except ValueError:
        return False
    return (memory == limits['memory_bytes'] and pids == limits['pids']
            and period > 0 and quota * 1000 == limits['cpu_millicores'] * period)


def memory_limit_probe(docker, manifest):
    alpine = manifest['images']['alpine']['ref']
    node = manifest['images']['node']['ref']
    if docker.call('pressure-prepull', ['pull', '--platform', 'linux/arm64', node],
                   timeout=180, phase='setup') is None:
        return
    session = ['--network', 'none', '--label', f'{LABEL}={docker.token}', '--cpus', '0.5']
    survivor = f'{docker.token}-survivor'
    target = f'{docker.token}-limited'
    identity = docker.call('pressure-survivor-create', ['create', '--name', survivor, *session,
                           '--memory', '32m', '--pids-limit', '8', alpine, 'sh', '-c',
                           'printf active-before-oom >/tmp/canary; exec sleep 1800'], phase='setup')
    if identity is None:
        return
    try:
        if docker.call('pressure-survivor-start', ['start', survivor], phase='setup') is None:
            return
        marker = ['exec', survivor, 'cat', '/tmp/canary']
        if docker.call('pressure-survivor-before', marker, phase='verification',
                       expected=b'active-before-oom') is None:
            return
        created = docker.call('pressure-create', ['create', '--name', target, *session,
                              '--memory', '64m', '--pids-limit', '32', node, 'node', '-e',
                              'const retained=[]; for(let i=0;i<256;i++) '
                              'retained.push(Buffer.alloc(1024*1024, 0x6d)); process.exit(42)'], phase='setup')
        if created is None:
            return
        try:
            memory = docker.call('pressure-limit-inspect', ['inspect', '--format',
                                 '{{.HostConfig.Memory}}', target], phase='verification',
                                 expected=b'67108864\n')
            if memory is None or docker.call('pressure-start', ['start', target], phase='verification') is None:
                return
            docker.call('pressure-oom-exit', ['wait', target], timeout=20,
                        expected=b'137\n', phase='verification')
            docker.call('pressure-oom-inspect', ['inspect', '--format', '{{.State.OOMKilled}}', target],
                        expected=b'true\n', phase='verification')
            docker.call('pressure-survivor-after', marker, phase='verification', expected=b'active-before-oom')
        finally:
            if docker.call('pressure-target-remove', ['rm', '-f', target], phase='cleanup') is None:
                raise RuntimeError('could not clean up the memory-limited task container')
        docker.call('pressure-recovery', ['run', '--rm', *session, '--memory', '16m', '--pids-limit', '4',
                    alpine, '/bin/echo', 'pressure-recovered'], phase='verification',
                    expected=b'pressure-recovered\n')
    finally:
        if docker.call('pressure-survivor-remove', ['rm', '-f', survivor], phase='cleanup') is None:
            raise RuntimeError('could not clean up the active-data canary')


def run_stress(docker, manifest):
    budget = manifest['suites']['stress']
    image = manifest['images']['alpine']['ref']
    if docker.call('stress-prepull', ['pull', '--platform', 'linux/arm64', image], phase='setup') is None:
        return

    def execute(index):
        argv = [*docker.prefix, 'run', '--rm', '--pull', 'never', '--network', 'none',
                '--name', f'{docker.token}-{index}', '--label', f'{LABEL}={docker.token}',
                '--memory', '16777216', '--pids-limit', '4', '--cpus', '0.5', image, '/bin/echo', 'stress-ok']
        started = time.monotonic_ns()
        try:
            result = subprocess.run(argv, env=docker.env, capture_output=True, timeout=budget['timeout_seconds'])
            error = None if result.returncode == 0 and result.stdout == b'stress-ok\n' else (
                f'exit={result.returncode}; stderr={result.stderr[:300]!r}')
        except (OSError, subprocess.TimeoutExpired) as failure:
            error = str(failure)
        return {'argv': list(map(str, argv)), 'error': error, 'elapsed_ns': time.monotonic_ns() - started}

    for limit in manifest['concurrency']:
        group = f'stress.launch.concurrency-{limit}'
        for phase, count in [('warmup', budget['warmups']), ('sample', budget['samples_per_session'])]:
            begin = time.monotonic_ns()
            with ThreadPoolExecutor(max_workers=limit) as pool:
                for offset in range(0, count, limit):
                    batch = (f'{limit}-{phase}-{i}' for i in range(offset, min(offset + limit, count)))
                    for row in pool.map(execute, batch):
                        docker.rows.append({'scenario': group, 'phase': phase, **row})
            if phase == 'sample':
                docker.report.setdefault('windows_ns', {})[group] = time.monotonic_ns() - begin
    memory_limit_probe(docker, manifest)
