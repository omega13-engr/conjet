"""Pinned inputs shared by the disposable Docker lanes."""

import json
from urllib.parse import quote, urlencode


API = '/v1.44'
ALPINE_REPOSITORY = 'docker.io/library/alpine'
ALPINE_DIGEST = 'sha256:e233f2058b0628266762f745a2c17e623b418e0090f47d223909d1f9a7d4367e'
ALPINE = ALPINE_REPOSITORY + '@' + ALPINE_DIGEST
ALPINE_CONFIG = 'sha256:062964a69725bb96611dae2ac911a5a1ab3f8d32fe6f096f267d77f09e55a99c'
ALPINE_PATH = API + '/images/' + quote(ALPINE, safe='')


def ensure_alpine(session):
    status, data = session.request('GET', ALPINE_PATH + '/json')
    if status == 404:
        query = urlencode({'fromImage': ALPINE_REPOSITORY, 'tag': ALPINE_DIGEST,
                           'platform': 'linux/arm64'})
        pull = type(session)(session.connection.peer(timeout=80))
        status, data = pull.request('POST', API + '/images/create?' + query)
        if status != 200:
            raise RuntimeError(f'pinned Alpine pull failed: HTTP {status} {data!r}')
        status, data = session.request('GET', ALPINE_PATH + '/json')
    if status != 200:
        raise RuntimeError(f'pinned Alpine inspection failed: HTTP {status} {data!r}')
    details = json.loads(data)
    if (details['Id'] not in (ALPINE_CONFIG, ALPINE_DIGEST)
            or details['Architecture'] != 'arm64'
            or not any(item.rsplit('@', 1)[-1] == ALPINE_DIGEST for item in details['RepoDigests'])):
        raise RuntimeError('pinned Alpine image identity does not match the neutral workload')
    return {'reference': ALPINE, 'architecture': details['Architecture'], 'image_id': details['Id']}
