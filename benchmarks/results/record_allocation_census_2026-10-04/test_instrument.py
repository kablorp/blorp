import copy
import importlib.util
import json
import pathlib
import unittest

root = pathlib.Path(__file__).parent
spec = importlib.util.spec_from_file_location('instrument', root / 'instrument.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
source = (root / 'oracle.normal.c').read_text()
raw = (root / 'oracle.core').read_text()
program = json.loads(raw.split('===== after final =====\n')[1])

def core_text(program):
    return '===== after final =====\n' + json.dumps(program)

class JoinTests(unittest.TestCase):
    def test_current_emission_inversion_and_coverage(self):
        output, mapping = module.instrument(source, raw)
        self.assertTrue(mapping['inversion_audit'])
        self.assertEqual(mapping['record_makers'], 7)
        self.assertEqual(len(mapping['sites']), 90)
        # Wrapper delegate appears once and was inserted after source rewrite.
        self.assertEqual(output.count('void* result = blorp_alloc(requested);'), 1)

    def test_same_tag_distinct_source_or_generic_declaration_rejected(self):
        for generic in (False, True):
            changed = copy.deepcopy(program)
            duplicate = copy.deepcopy(next(d for d in changed['decls'] if d['kind'] == 'heap_record'))
            duplicate['loc'] = {'kind': 'known', 'file': '/different/module.brp'}
            if generic:
                duplicate['type_params'] = ['T']
            changed['decls'].append(duplicate)
            with self.assertRaisesRegex(ValueError, 'duplicate/ambiguous Core'):
                module.instrument(source, core_text(changed))

    def test_unmatched_tag_rejected(self):
        changed = source.replace('"FreshScalar"', '"NotInCore"')
        with self.assertRaisesRegex(ValueError, 'unmatched emitted record maker'):
            module.instrument(changed, raw)

    def test_duplicate_maker_rejected(self):
        start = source.index('brp_ty1* __rec')
        end = source.index('\n', source.index('BLORP_INSTALL_TAG', start))
        with self.assertRaisesRegex(ValueError, 'duplicate/ambiguous emitted maker'):
            module.instrument(source + '\n' + source[start:end], raw)

    def test_lexical_non_calls_are_ignored(self):
        extras = '\n/* blorp_alloc(9) */\n// blorp_alloc(8)\nconst char* s5_string = "blorp_alloc(7)";\nvoid* blorp_alloc(size_t size);\nvoid* s5_address = (void*)&blorp_alloc;\n'
        _, mapping = module.instrument(source + extras, raw)
        self.assertEqual(len(mapping['sites']), 90)

    def test_non_json_c_tag_escape_rejected(self):
        changed = source.replace('"FreshScalar"', '"Fresh\\x53calar"')
        with self.assertRaises(ValueError):
            module.instrument(changed, raw)

if __name__ == '__main__':
    unittest.main()
