"""Enumerate pinned Docker operations and schema fields with explicit mapping gaps."""

import argparse
import json
import os
from pathlib import Path
import subprocess
from urllib.parse import unquote

from identity import SCRATCH, sha256
from run import HERE, selection

METHODS = {'get', 'post', 'put', 'patch', 'delete', 'head', 'options', 'trace'}
PROPERTIES = {'properties', 'patternProperties'}
SCHEMA_MAPS = {'additionalProperties', 'unevaluatedProperties'}
EXAMPLE_KEYS = {'example', 'examples', 'default', 'enum', 'const'}
ENGINE_DEFINITIONS = {'engine-1.44.yaml': '/definitions', 'engine-1.57.yaml': '/components/schemas'}


def pointer(parent, token):
    return parent + '/' + str(token).replace('~', '~0').replace('/', '~1')


def entries(document):
    discovered = {}
    for path, operations in document.get('paths', {}).items():
        path_pointer = pointer('/paths', path)
        for method in operations.keys() & METHODS:
            operation = pointer(path_pointer, method)
            discovered[operation] = 'operation'
            for status, response in operations[method].get('responses', {}).items():
                response_pointer = pointer(operation + '/responses', status)
                discovered[response_pointer] = 'response'
                for header in response.get('headers', {}):
                    discovered[pointer(response_pointer + '/headers', header)] = 'response_header'

    def walk(node, location):
        if isinstance(node, dict):
            for key, value in node.items():
                path = pointer(location, key)
                if key == 'parameters' and isinstance(value, list):
                    for index in range(len(value)):
                        discovered[pointer(path, index)] = 'parameter'
                elif key == 'requestBody' and isinstance(value, dict):
                    discovered[path] = 'request_body'
                elif key in PROPERTIES and isinstance(value, dict):
                    for name, schema in value.items():
                        field = pointer(path, name)
                        discovered[field] = key
                        walk(schema, field)
                    continue
                elif key in SCHEMA_MAPS and (value is True or isinstance(value, dict)):
                    discovered[path] = 'map_values'
                # Documentation and sample objects can themselves contain
                # schema keywords. They are not schema declarations.
                if key not in EXAMPLE_KEYS:
                    walk(value, path)
        elif isinstance(node, list):
            for index, value in enumerate(node):
                walk(value, pointer(location, index))

    walk(document, '')
    return discovered


def operation_uses(document):
    """Resolve each operation's shared schema dependencies, including circular references."""
    def references(node):
        if isinstance(node, dict):
            target = node.get('$ref')
            if isinstance(target, str):
                yield target
            for key, child in node.items():
                if key in PROPERTIES and isinstance(child, dict):
                    for schema in child.values():
                        yield from references(schema)
                elif key not in EXAMPLE_KEYS:
                    yield from references(child)
        elif isinstance(node, list):
            for child in node:
                yield from references(child)

    def resolve(target):
        value = document
        for part in target.split('/')[1:]:
            key = part.replace('~1', '/').replace('~0', '~')
            value = value[int(key)] if isinstance(value, list) else value[key]
        return value

    uses = {}
    for path, item in document.get('paths', {}).items():
        path_pointer = pointer('/paths', path)
        for method in item.keys() & METHODS:
            operation = pointer(path_pointer, method)
            pending = list(references([item.get('parameters', []), item[method]]))
            seen = set()
            while pending:
                ref = pending.pop()
                if not ref.startswith('#/'):
                    raise ValueError(f'unsupported schema reference for {operation}: {ref}')
                target = unquote(ref[1:])
                if target not in seen:
                    seen.add(target)
                    uses.setdefault(target, set()).add(operation)
                    pending.extend(references(resolve(target)))
    return uses


def inventory(document, mappings, case_ids, exclusions=None):
    exclusions = exclusions or {}
    discovered = entries(document)
    unmatched = (mappings.keys() | exclusions.keys()) - discovered.keys()
    if unmatched:
        raise ValueError(f'mappings point outside the schema: {sorted(unmatched)}')
    if mappings.keys() & exclusions.keys() or any(
            not isinstance(reason, str) or not reason.strip() for reason in exclusions.values()):
        raise ValueError('an exclusion requires a reason and must not overlap a planned case')
    for path, ids in mappings.items():
        if not ids or set(ids) - case_ids:
            raise ValueError(f'missing or unknown case IDs for {path}: {ids}')
    rows = {path: {'kind': kind, 'planned_cases': mappings.get(path, [])}
            for path, kind in sorted(discovered.items())}
    for path, reason in exclusions.items():
        rows[path]['platform_exclusion'] = reason
    return rows


def coverage(document, rows):
    uses = operation_uses(document)
    for path, row in rows.items():
        routes = set()
        parent = path
        while parent:
            if parent in rows and rows[parent]['kind'] == 'operation':
                routes.add(parent)
            routes.update(uses.get(parent, ()))
            parent = parent.rpartition('/')[0]
        if path.startswith('/paths/') and '/parameters/' in path:
            path_item = path.split('/')[2]
            prefix = f'/paths/{path_item}/'
            if path.startswith(prefix + 'parameters/'):
                routes.update(route for route, entry in rows.items()
                              if entry['kind'] == 'operation' and route.startswith(prefix))
        if routes:
            row['related_operations'] = sorted(routes)
    uncovered = [row for row in rows.values()
                 if not row['planned_cases'] and not row.get('platform_exclusion')]
    return {'unmapped': len(uncovered),
            'unmapped_with_operation': sum('related_operations' in row for row in uncovered)}


def load_schema(path, source):
    if sha256(path) != source['sha256']:
        raise ValueError(f'schema hash mismatch: {path}')
    if path.suffix == '.yaml':
        converted = subprocess.run(['yq', '-o=json', '.', path], check=True, text=True,
                                   timeout=15, capture_output=True)
        document = json.loads(converted.stdout)
        if document['info']['version'] != source['version']:
            raise ValueError(f'unexpected Engine API version: {path}')
        return document
    return json.loads(path.read_text())


def mappings_for(spec, name):
    document_cases = spec['planned_cases'].get(name, {})
    definitions = ENGINE_DEFINITIONS.get(name)
    if not definitions:
        return document_cases
    return {
        **spec['engine_operations'],
        **{definitions + path: cases for path, cases in spec['engine_fields'].items()},
        **document_cases,
    }


def exclusions_for(spec, name):
    definitions = ENGINE_DEFINITIONS.get(name)
    if definitions:
        return {definitions + path: reason for path, reason in spec['engine_exclusions'].items()}
    return spec['platform_exclusions'].get(name, {})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--inputs', type=Path, required=True)
    parser.add_argument('--evidence', type=Path, required=True)
    args = parser.parse_args()
    for path in (args.inputs, args.evidence):
        if path.resolve() != path or not path.is_relative_to(SCRATCH):
            parser.error('use canonical ExternalSSD paths')
    manifest = HERE / 'schema-sources.json'
    spec = json.loads(manifest.read_text())
    case_ids = {case['id'] for case in selection('all')}
    receipt = {'manifest_sha256': sha256(manifest), 'schemas': {}, 'complete': False}
    os.umask(0o077)
    with args.evidence.open('x') as stream:
        try:
            for name, source in spec['sources'].items():
                document = load_schema(args.inputs / name, source)
                rows = inventory(document, mappings_for(spec, name), case_ids, exclusions_for(spec, name))
                receipt['schemas'][name] = {
                    'source': source, 'entries': rows,
                    **coverage(document, rows),
                }
            receipt['complete'] = all(source['entries'] and not source['unmapped']
                                      for source in receipt['schemas'].values())
        except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
            receipt['error'] = str(error)
        json.dump(receipt, stream, indent=2)
        stream.write('\n')
    return 0 if receipt['complete'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
