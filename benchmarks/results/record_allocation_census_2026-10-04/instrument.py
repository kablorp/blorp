#!/usr/bin/env python3
"""Disposable maker-site allocation census. Never edits its input C/Core."""
import argparse
import hashlib
import json
import re
from pathlib import Path

def digest(data):
    return hashlib.sha256(data.encode()).hexdigest()

def instrument(source, core_text):
    marker = '===== after final =====\n'
    if core_text.count(marker) != 1:
        raise ValueError('require exactly one final Core observation from same emission')
    core = json.loads(core_text.split(marker, 1)[1])
    if core['kind'] != 'program':
        raise ValueError('not a Core program')
    catalog = {}
    for declaration in core['decls']:
        if declaration['kind'] == 'heap_record':
            name = declaration['name']
            if name in catalog:
                raise ValueError('duplicate/ambiguous Core heap-record name: ' + name)
            catalog[name] = declaration
    # Exact current emitter shape, not a name-prefix classifier. Ambiguous or
    # changed maker shapes fail closed below; tags join to the explicit catalog.
    maker = re.compile(r'(?P<ctype>\w+)\* __rec = \((?P=ctype)\*\)(?P<alloc>blorp_alloc\(sizeof\((?P=ctype)\)\));\s*BLORP_INSTALL_(?:TAG|TYPE)\(__rec, (?:\w+, )?(?P<tag>"(?:[^"\\]|\\.)*")\);')
    makers = {}
    by_name = {}
    for match in maker.finditer(source):
        name = json.loads(match['tag'])
        if name not in catalog:
            raise ValueError('unmatched emitted record maker: ' + name)
        if name in by_name:
            raise ValueError('duplicate/ambiguous emitted maker: ' + name)
        by_name[name] = match['ctype']
        makers[match.start('alloc')] = {'record': name, 'c_type': match['ctype'], 'core_loc': catalog[name]['loc']}
    # All catalog declarations must have exactly one emitted maker. A final
    # catalog containing nonemitted declarations is not silently accepted.
    missing = sorted(set(catalog) - set(by_name))
    if missing:
        raise ValueError('Core declarations without validated makers: ' + repr(missing))
    if len(set(by_name.values())) != len(by_name):
        raise ValueError('duplicate/ambiguous C record type')
    tokens = (t for t in re.finditer(r'/\*.*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|[A-Za-z_]\w*|\s+|.', source, re.S)
              if not t[0].isspace() and not t[0].startswith(('/*', '//')))
    sites = []
    changes = []
    for token in tokens:
        if token[0] != 'blorp_alloc':
            continue
        opening = next(tokens)
        if opening[0] != '(':
            continue  # e.g. &blorp_alloc used for diagnostic return-address offsets
        depth = 1
        while depth:
            closing = next(tokens)
            if closing[0] == 'blorp_alloc':
                raise ValueError('nested allocation calls require separate accounting')
            depth += (closing[0] == '(') - (closing[0] == ')')
        argument = source[opening.end():closing.start()]
        if re.fullmatch(r'\s*size_t\s+\w+\s*', argument):
            continue  # allocator definition/prototype, not a call
        site = len(sites)
        entry = {'site': site, 'offset': token.start(), 'line': source.count('\n', 0, token.start()) + 1, 'requested_size_expr': argument, 'classification': 'other_or_unclassified'}
        if token.start() in makers:
            entry.update(makers[token.start()])
            entry['classification'] = 'managed_record_maker'
        sites.append(entry)
        old = source[token.start():closing.end()]
        changes.append((token.start(), closing.end(), old, f's5_alloc(({argument}), {site})'))
    if len([s for s in sites if s['classification'] == 'managed_record_maker']) != len(catalog):
        raise ValueError('maker/direct-call census mismatch')
    rewritten = source
    for start, end, old, new in reversed(changes):
        rewritten = rewritten[:start] + new + rewritten[end:]
    # Invert every replacement by exact offset adjusted for prior replacements.
    inverse = rewritten
    shift = 0
    transformed = []
    for start, end, old, new in changes:
        transformed.append((start + shift, old, new))
        shift += len(new) - len(old)
    for start, old, new in reversed(transformed):
        assert inverse[start:start + len(new)] == new
        inverse = inverse[:start] + old + inverse[start + len(new):]
    if inverse != source:
        raise ValueError('inversion audit failed')
    preamble = '#include <stddef.h>\n#include <stdatomic.h>\nstatic void* s5_alloc(size_t, unsigned);\n'
    labels = '\n'.join('  ' + json.dumps(s.get('record', '<other/unclassified>')) + ',' for s in sites)
    record_flags = ','.join('1' if s['classification'] == 'managed_record_maker' else '0' for s in sites)
    tail = f'''
/* Disposable census: requested bytes, not malloc usable/backing bytes. */
static _Atomic unsigned long long s5_counts[{len(sites)}], s5_requested_bytes[{len(sites)}];
static const char* s5_labels[{len(sites)}] = {{
{labels}
}};
static const unsigned char s5_record_flags[{len(sites)}] = {{{record_flags}}};
static void* s5_alloc(size_t requested, unsigned site) {{
    void* result = blorp_alloc(requested);
    atomic_fetch_add_explicit(&s5_counts[site], 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&s5_requested_bytes[site], requested, memory_order_relaxed);
    return result;
}}
__attribute__((destructor)) static void s5_report(void) {{
    unsigned long long direct = 0, records = 0;
    for (unsigned i = 0; i < {len(sites)}; i++) {{
        unsigned long long count = atomic_load_explicit(&s5_counts[i], memory_order_relaxed);
        direct += count;
        if (s5_record_flags[i]) records += count;
        if (count) fprintf(stderr, "S5_SITE site=%u count=%llu requested_bytes=%llu type=%s\\n", i, count,
            atomic_load_explicit(&s5_requested_bytes[i], memory_order_relaxed), s5_labels[i]);
    }}
    blorp_MemStats stats = blorp_get_mem_stats();
    fprintf(stderr, "S5_TOTAL direct_alloc_calls=%llu record_maker_allocations=%llu managed_allocations=%ld boundary=process_destructor\\n", direct, records, stats.total_allocations);
}}
'''
    output = preamble + rewritten + tail
    return output, {'schema': 1, 'boundary': 'final Core declaration catalog from same emission', 'source_c_sha256': digest(source), 'core_sha256': digest(core_text), 'transformed_c_sha256': digest(output), 'inversion_audit': True, 'record_makers': len(catalog), 'sites': sites}

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('source_c', type=Path)
    parser.add_argument('final_core', type=Path)
    parser.add_argument('output_c', type=Path)
    parser.add_argument('mapping', type=Path)
    args = parser.parse_args()
    output, mapping = instrument(args.source_c.read_text(), args.final_core.read_text())
    args.output_c.write_text(output)
    args.mapping.write_text(json.dumps(mapping, indent=2) + '\n')
