"""Schema inventory coverage and mapping contract tests."""

import unittest

from schema_inventory import coverage, inventory


class SchemaInventoryTests(unittest.TestCase):
    def test_enumerates_operations_parameters_and_nested_fields(self):
        document = {
            'paths': {
                '/fixture': {
                    'post': {
                        'parameters': [{'name': 'force'}],
                        'requestBody': {'content': {}},
                    },
                },
            },
            'properties': {
                'a/b~c': {'items': {'patternProperties': {'^x-': {'additionalProperties': True}}}},
                'default': {'properties': {'mode': {}}},
            },
            'example': {'properties': {'fictional': {'type': 'string'}}},
        }
        rows = inventory(document, {'/paths/~1fixture/post': ['DC-001']}, {'DC-001'})
        self.assertEqual(rows, {
            '/paths/~1fixture/post': {'kind': 'operation', 'planned_cases': ['DC-001']},
            '/paths/~1fixture/post/parameters/0': {'kind': 'parameter', 'planned_cases': []},
            '/paths/~1fixture/post/requestBody': {'kind': 'request_body', 'planned_cases': []},
            '/properties/a~1b~0c': {'kind': 'properties', 'planned_cases': []},
            '/properties/a~1b~0c/items/patternProperties/^x-': {
                'kind': 'patternProperties', 'planned_cases': [],
            },
            '/properties/a~1b~0c/items/patternProperties/^x-/additionalProperties': {
                'kind': 'map_values', 'planned_cases': [],
            },
            '/properties/default': {'kind': 'properties', 'planned_cases': []},
            '/properties/default/properties/mode': {'kind': 'properties', 'planned_cases': []},
        })

    def test_stale_pointer_and_unknown_contract_are_rejected(self):
        schema = {'properties': {'known': {}}}
        with self.assertRaisesRegex(ValueError, 'outside the schema'):
            inventory(schema, {'/properties/old': ['DC-001']}, {'DC-001'})
        with self.assertRaisesRegex(ValueError, 'unknown case IDs'):
            inventory(schema, {'/properties/known': ['DC-002']}, {'DC-001'})

    def test_platform_exclusions_keep_the_row_and_require_a_reason(self):
        schema = {'properties': {'platform_only': {}}}
        path = '/properties/platform_only'
        rows = inventory(schema, {}, {'DC-001'}, {path: 'Windows only'})
        self.assertEqual(rows[path]['platform_exclusion'], 'Windows only')
        with self.assertRaisesRegex(ValueError, 'requires a reason'):
            inventory(schema, {}, {'DC-001'}, {path: ''})
        with self.assertRaisesRegex(ValueError, 'requires a reason'):
            inventory(schema, {}, {'DC-001'}, {path: ['DC-001']})
        with self.assertRaisesRegex(ValueError, 'must not overlap'):
            inventory(schema, {path: ['DC-001']}, {'DC-001'}, {path: 'Windows only'})

    def test_response_headers_and_transitive_shared_fields_keep_their_operations(self):
        document = {
            'paths': {'/fixtures/{id}': {
                'parameters': [{'name': 'id'}],
                'get': {'responses': {'200': {
                    'headers': {'X-Version': {'type': 'string'}},
                    'schema': {'$ref': '#/definitions/A~1B'},
                }}},
                'delete': {'responses': {'204': {}}},
            }},
            'definitions': {'A/B': {'properties': {
                'default': {'$ref': '#/definitions/Child'},
            }}, 'Child': {'properties': {
                'name': {'type': 'string', 'example': {'$ref': 'not-a-schema'}},
                'parent': {'$ref': '#/definitions/A~1B'},
            }}},
        }
        rows = inventory(document, {}, set())
        self.assertEqual(coverage(document, rows), {'unmapped': 9, 'unmapped_with_operation': 9})
        prefix = '/paths/~1fixtures~1{id}'
        self.assertEqual(rows[f'{prefix}/get/responses/200/headers/X-Version']['kind'],
                         'response_header')
        self.assertEqual(rows['/definitions/Child/properties/name']['related_operations'], [prefix + '/get'])
        self.assertEqual(rows[prefix + '/parameters/0']['related_operations'],
                         [prefix + '/delete', prefix + '/get'])


if __name__ == '__main__':
    unittest.main()
