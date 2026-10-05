"""Narrow structural oracle for the retained final-Core JSON dump."""
import json
import sys
from copy import deepcopy
from pathlib import Path

program = json.loads(next(line for line in Path(sys.argv[1]).read_text().splitlines() if line.startswith('{')))
functions = {decl['name']: decl for decl in program['decls'] if decl['kind'] == 'function'}
native = functions.get('memory__read_native_memory_counter')
assert native is not None, 'missing private scalar native reader'
integer = {'kind': 'named', 'name': 'Int', 'args': []}
assert [param['type'] for param in native['params']] == [integer]
assert native['return_type'] == integer
assert native['body']['call_kind']['kind'] == 'direct_runtime'
assert native['body']['call_kind']['call']['name'] == 'blorp_read_memory_counter'
assert native['body']['args'][0]['type'] == integer
assert native['body']['args'][0]['var']['id'] == native['params'][0]['name']['id']
public = functions['memory__read_memory_counter']['body']
assert public['call_kind']['name'] == 'memory__read_native_memory_counter'
assert public['call_kind']['def_id'] == native['def_id']
assert public['args'][0]['call_kind']['name'] == 'memory__memory_counter_tag'
assert public['args'][0]['call_kind']['def_id'] == functions['memory__memory_counter_tag']['def_id']
assert public['args'][0]['type'] == integer
encoder = functions['memory__memory_counter_tag']['body']
assert encoder['kind'] == 'constructor_match'
counter = next(decl for decl in program['decls'] if decl['name'] == 'memory__MemoryCounter')
assert counter['kind'] == 'enum'
assert counter['loc']['file'] == '<embedded:memory>'
# Explicit native contract, never the declaration's ordinal/tag values.
expected = {
    'ManagedAllocations': 0, 'ManagedReleases': 1, 'LiveManagedObjects': 2,
    'ManagedBytes': 3, 'ManagedBytesAvailable': 4, 'AllocatorBytesInUse': 5,
    'AllocatorBytesAvailable': 6, 'BackingMallocEvents': 7, 'RawMallocEvents': 8,
    'RawCallocEvents': 9, 'RawReallocEvents': 10, 'RawAlignedEvents': 11,
    'CleanupScratchEvents': 12, 'FiberMapEvents': 13, 'OracleStatsActive': 14,
    'MemoryStatsActive': 15,
}
constructors = {variant['def_id']: variant['name'] for variant in counter['variants']}
assert len(constructors) == 16 and set(constructors.values()) == set(expected)
cases = deepcopy(encoder['cases'])
if '--tamper' in sys.argv[2:]:
    # Negative control changes only a disposable in-memory copy, never raw Core.
    target = next(case for case in cases if constructors[case['test']['variant']['def_id']] == 'ManagedAllocations')
    target['body']['expr']['literal']['value'] = '1'
assert len(cases) == 16
seen = set()
for case in cases:
    variant = case['test']['variant']
    assert variant['kind'] == 'by_id'
    identity = variant['def_id']
    assert identity in constructors and identity not in seen
    seen.add(identity)
    expression = case['body']['expr']
    assert expression['kind'] == 'literal' and expression['type'] == integer
    literal = expression['literal']
    assert literal['kind'] == 'int'
    name = constructors[identity]
    assert int(literal['value']) == expected[name], f'wrong native mapping for {name}'
assert seen == set(constructors)
print('PASS: exact 16 constructor IDs -> native literals; encoder -> Int reader -> native long reader')
