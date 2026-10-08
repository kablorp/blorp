#!/usr/bin/env python3
"""Read-only checks of fresh census artifacts and current-emission oracle joins.

Use --oracle-dir for oracle.normal.c, oracle.final.core and oracle.{normal,
instrumented}.n{4,5}.{stdout,stderr}. Native generation/build remains explicit
in the retained command log; this verifier never builds or edits production.
"""
import argparse
import copy
import gzip
import json
from pathlib import Path
import re

from measure import counts, load, PREVIOUS


def rejected(operation):
    try:
        operation()
    except ValueError:
        return
    raise AssertionError('malformed observation or ambiguous join accepted')


def check_parser():
    mapping = {'sites': [dict(site=0, classification='managed_record_maker', record='Box'),
                         dict(site=1, classification='other_or_unclassified')], 'record_makers': 1}
    valid = ('S5_SITE site=0 count=2 requested_bytes=64 type=Box\n'
             'S5_SITE site=1 count=3 requested_bytes=60 type=<other/unclassified>\n'
             'S5_TOTAL direct_alloc_calls=5 record_maker_allocations=2 managed_allocations=7 boundary=process_destructor\n')
    assert counts(mapping, valid)[1]['external_runtime_or_other_residual'] == 2
    malformed = [valid + valid.splitlines()[0] + '\n', valid.replace('site=1', 'site=9'),
                 valid.replace('type=Box', 'type=Other'), valid.replace('direct_alloc_calls=5', 'direct_alloc_calls=6'),
                 valid.replace('record_maker_allocations=2', 'record_maker_allocations=3'),
                 valid.replace('managed_allocations=7', 'managed_allocations=4'),
                 '\n'.join(valid.splitlines()[:-1]), valid + valid.splitlines()[-1] + '\n',
                 valid.replace('process_destructor', 'after_compile'),
                 valid + 'S5_SITE site=0 count=0 malformed\n', valid + 'S5_SITE noise\n',
                 valid + 'S5_TOTAL malformed\n']
    for text in malformed:
        rejected(lambda: counts(mapping, text))
    return len(malformed)


def check_oracle(directory, instrument):
    source = (directory / 'oracle.normal.c').read_text()
    core = (directory / 'oracle.final.core').read_text()
    transformed, mapping = instrument.instrument(source, core)
    assert mapping['inversion_audit']
    assert transformed.count('void* result = blorp_alloc(requested);') == 1
    program = json.loads(core.split('===== after final =====\n')[1])
    records = [item for item in program['decls'] if item['kind'] == 'heap_record']
    changed = copy.deepcopy(program)
    changed['decls'].append(copy.deepcopy(records[0]))
    rejected(lambda: instrument.instrument(source, '===== after final =====\n' + json.dumps(changed)))
    name = next(item['name'] for item in records if item['name'] == 'FreshScalar')
    rejected(lambda: instrument.instrument(source.replace(json.dumps(name), '"NotInCore"'), core))
    maker = re.search(r'\w+\* __rec = \(\w+\*\)blorp_alloc\(sizeof\(\w+\)\);\s*BLORP_INSTALL_(?:TAG|TYPE)\([^;]+;', source)
    assert maker
    rejected(lambda: instrument.instrument(source + '\n' + maker[0], core))
    rejected(lambda: instrument.instrument(source.replace('"FreshScalar"', '"Fresh\\x53calar"'), core))
    extras = '\n/* blorp_alloc(9) */\n// blorp_alloc(8)\nconst char* probe="blorp_alloc(7)";\nvoid* blorp_alloc(size_t size);\nvoid* address=(void*)&blorp_alloc;\n'
    assert len(instrument.instrument(source + extras, core)[1]['sites']) == len(mapping['sites'])
    for rounds, expected in ((4, '40\n18\n18\n'), (5, '55\n20\n22\n')):
        prefix = directory / f'oracle.instrumented.n{rounds}'
        assert prefix.with_suffix(prefix.suffix + '.stdout').read_text() == expected
        assert (directory / f'oracle.normal.n{rounds}.stdout').read_text() == expected
        rows, totals = counts(mapping, prefix.with_suffix(prefix.suffix + '.stderr').read_text())
        by_record = {row['record']: row['count'] for row in rows if row['classification'] == 'managed_record_maker'}
        for shape, count in (('Fresh', rounds), ('Unique', 1), ('Shared', 2)):
            for representation in ('Scalar', 'Managed'):
                assert by_record[shape + representation] == count
        assert totals['global_managed_allocations'] == totals['direct_body_allocations']
    return dict(direct_sites=len(mapping['sites']), record_makers=mapping['record_makers'], oracle_bounds=[4, 5])


def check_census(directory):
    mapping = json.loads((directory / 'compiler.mapping.json').read_text())
    instrument = load('census_instrument', PREVIOUS / 'instrument.py')
    for filename, key in (('compiler.normal.c', 'source_c_sha256'),
                          ('compiler.final.core', 'core_sha256'),
                          ('compiler.instrumented.c', 'transformed_c_sha256')):
        assert instrument.digest((directory / filename).read_text()) == mapping[key]
    assert mapping['inversion_audit']
    rows, ranking = counts(mapping, (directory / 'self-instrumented.stderr').read_text())
    assert [row['site'] for row in rows] == list(range(len(rows)))
    if (directory / 'sites.json.gz').exists():
        retained = json.loads(gzip.decompress((directory / 'sites.json.gz').read_bytes()))
        assert [(r['site'], r['count'], r['requested_bytes']) for r in rows] == [(r['site'], r['count'], r['requested_bytes']) for r in retained]
    if (directory / 'ranking.json').exists():
        retained_ranking = json.loads((directory / 'ranking.json').read_text())
        for key, value in ranking.items():
            if key != 'top20_by_count':
                assert value == retained_ranking[key]
        assert [(r['site'], r['count']) for r in ranking['top20_by_count']] == [(r['site'], r['count']) for r in retained_ranking['top20_by_count']]
    control = re.findall(r'^S5_CONTROL managed_allocations=(\d+) boundary=process_destructor$', (directory / 'self-control.stderr').read_text(), re.M)
    assert len(control) == 1 and int(control[0]) == ranking['global_managed_allocations']
    assert (directory / 'target.control.c').read_bytes() == (directory / 'target.instrumented.c').read_bytes()
    return {key: value for key, value in ranking.items() if key != 'top20_by_count'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--oracle-dir', type=Path)
    parser.add_argument('--census-dir', type=Path)
    options = parser.parse_args()
    result = {'parser_negative_cases': check_parser()}
    if options.oracle_dir:
        result['oracle'] = check_oracle(options.oracle_dir, load('oracle_instrument', PREVIOUS / 'instrument.py'))
    if options.census_dir:
        result['census'] = check_census(options.census_dir)
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
