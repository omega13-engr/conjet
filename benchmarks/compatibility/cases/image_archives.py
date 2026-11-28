"""Neutral Docker image archives assembled from the verified Alpine base."""

import hashlib
import io
import json
import tarfile
from urllib.parse import quote, urlencode

from support import API, container, demultiplex

LIMIT = 16 * 1024 * 1024


def transfer(test, session, method, path, payload=None):
    peer = session.connection.peer(timeout=20)
    try:
        headers = {'Content-Type': 'application/x-tar'} if payload is not None else {}
        peer.request(method, path, payload, headers)
        with peer.getresponse() as response:
            data = response.read(LIMIT + 1)
            test.assertLessEqual(len(data), LIMIT)
            return response.status, data
    finally:
        peer.close()


def saved(test, session, *names):
    route = API + '/images/get?' + urlencode([('names', name) for name in names])
    status, raw = transfer(test, session, 'GET', route)
    test.assertEqual(status, 200, raw[:1024])
    return raw


def records(test, payload):
    with tarfile.open(fileobj=io.BytesIO(payload), mode='r:*') as archive:
        def read(name):
            item = archive.getmember(name)
            test.assertTrue(item.isfile())
            test.assertLessEqual(item.size, LIMIT)
            return archive.extractfile(item).read()

        listing = json.loads(read('manifest.json'))
        return [(item, read(item['Config']), [read(path) for path in item['Layers']])
                for item in listing]


def variant(base_config, marker):
    config = json.loads(base_config)
    config['config'].update({'Cmd': ['/bin/echo', marker], 'Entrypoint': []})
    return json.dumps(config, sort_keys=True, separators=(',', ':')).encode()


def build_archive(configs, layers):
    """All named variants reference the same immutable filesystem layers."""
    result = io.BytesIO()
    with tarfile.open(fileobj=result, mode='w', format=tarfile.USTAR_FORMAT) as archive:
        def append(name, data):
            member = tarfile.TarInfo(name)
            member.mode = 0o644
            member.size = len(data)
            archive.addfile(member, io.BytesIO(data))

        shared = [f'shared-{i}/layer.tar' for i in range(len(layers))]
        for name, layer in zip(shared, layers, strict=True):
            append(name, layer)
        manifest = []
        for tag, config in configs.items():
            name = hashlib.sha256(config).hexdigest() + '.json'
            append(name, config)
            manifest.append({'Config': name, 'Layers': shared, 'RepoTags': [tag]})
        append('manifest.json', json.dumps(manifest, separators=(',', ':')).encode())
    return result.getvalue()


def image_path(name):
    return API + '/images/' + quote(name, safe='')


def load(test, session, payload):
    status, raw = transfer(test, session, 'POST', API + '/images/load?quiet=false', payload)
    test.assertEqual(status, 200, raw[:1024])
    rows = [json.loads(row) for row in raw.splitlines() if row.strip()]
    test.assertTrue(rows)
    test.assertFalse(any(row.get('error') or row.get('errorDetail') for row in rows), rows)
    return rows


def inspect(test, session, name):
    status, raw = session.request('GET', image_path(name) + '/json')
    test.assertEqual(status, 200, raw)
    return json.loads(raw)


def clean(test, session, name):
    status, raw = session.request('GET', image_path(name) + '/json')
    if status == 404:
        return
    test.assertEqual(status, 200, raw)
    detail = json.loads(raw)
    status, raw = session.request('DELETE', image_path(name))
    test.assertEqual(status, 200, raw)
    test.assertEqual(session.request('GET', image_path(name) + '/json')[0], 404)
    # The native store exposes untagged local imports at their manifest digest.
    # Docker may delete the last untagged image as part of removing the tag.
    for reference in detail.get('RepoDigests') or ():
        if reference.startswith('conjet.local/archive@'):
            status, raw = session.request('DELETE', image_path(reference))
            test.assertIn(status, (200, 404), raw)


def runnable(test, session, container_name, image, marker):
    with container(test, session, container_name, {
            'Image': image, 'HostConfig': {'NetworkMode': 'none'},
    }) as (path, _):
        status, raw = session.request('POST', path + '/start')
        test.assertEqual(status, 204, raw)
        status, raw = session.request('POST', path + '/wait?condition=not-running')
        test.assertEqual(status, 200, raw)
        test.assertEqual(json.loads(raw)['StatusCode'], 0)
        status, raw = session.request('GET', path + '/logs?stdout=true&stderr=true')
        test.assertEqual(status, 200, raw)
        test.assertEqual(demultiplex(test, raw), ((marker + '\n').encode(), b''))
