#!/usr/bin/env python3
"""Build and measure a disposable census from freshly paired final Core/C.

Generate compiler.normal.c and compiler.final.core together first. The caller
must keep the checkout unchanged between emission and this command. No
production files or other worktrees are modified.
"""
import argparse
import gzip
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess

REPO = Path(__file__).resolve().parents[3]
PREVIOUS = REPO / 'benchmarks/results/record_allocation_census_2026-10-04'


def load(name, path):
    loader = importlib.machinery.SourceFileLoader(name, str(path))
    spec = importlib.util.spec_from_loader(name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


def counts(mapping, stderr):
    """Reject unknown, duplicate, mislabeled or unreconciled observed sites."""
    observed = {}
    site_matches = list(re.finditer(r'^S5_SITE site=(\d+) count=(\d+) requested_bytes=(\d+) type=(.*)$', stderr, re.M))
    if len(site_matches) != sum(line.startswith('S5_SITE') for line in stderr.splitlines()):
        raise ValueError('malformed allocation site line')
    for match in site_matches:
        site, count, requested = map(int, match.groups()[:3])
        if site >= len(mapping['sites']) or site in observed:
            raise ValueError('unknown or duplicate allocation site')
        expected = mapping['sites'][site].get('record', '<other/unclassified>')
        if match[4] != expected:
            raise ValueError('allocation site/type mismatch')
        observed[site] = (count, requested)
    totals = re.findall(r'^S5_TOTAL direct_alloc_calls=(\d+) record_maker_allocations=(\d+) managed_allocations=(\d+) boundary=process_destructor$', stderr, re.M)
    if len(totals) != 1 or sum(line.startswith('S5_TOTAL') for line in stderr.splitlines()) != 1:
        raise ValueError('missing or duplicate process endpoint')
    direct, records, managed = map(int, totals[0])
    rows = [{**site, 'count': observed.get(site['site'], (0, 0))[0],
             'requested_bytes': observed.get(site['site'], (0, 0))[1]}
            for site in mapping['sites']]
    makers = [row for row in rows if row['classification'] == 'managed_record_maker']
    if (sum(row['count'] for row in rows) != direct
            or sum(row['count'] for row in makers) != records
            or len(makers) != mapping['record_makers']
            or not 0 <= records <= direct <= managed):
        raise ValueError('allocation totals do not reconcile')
    return rows, {'direct_body_allocations': direct, 'record_maker_allocations': records,
                  'global_managed_allocations': managed,
                  'external_runtime_or_other_residual': managed - direct,
                  'maker_catalog_count': len(makers),
                  'executed_maker_count': sum(row['count'] > 0 for row in makers),
                  'top20_by_count': sorted(makers, key=lambda row: row['count'], reverse=True)[:20]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output_dir', type=Path)
    args = parser.parse_args()
    output = args.output_dir.resolve()
    os.environ['BLORP_CLI_C_OPTIMIZATION'] = '-O2'
    recipe = load('stage2_recipe', REPO / 'benchmarks/build_stage2_compiler')
    recipe.check_bin_blorp_fresh()
    revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=REPO, text=True).strip()
    source_paths = ['blorp/src', 'standard_library/src', 'Makefile', 'blorp/build/bootstrap.env']
    subprocess.run(['git', 'diff', '--quiet', 'HEAD', '--', *source_paths], cwd=REPO, check=True)
    instrument = load('record_instrument', PREVIOUS / 'instrument.py')
    # Avoid inheriting diagnostic modes that change the measured boundary.
    cleared = ('BLORP_MEMORY_STATS', 'BLORP_LEAK_CHECK', 'BLORP_TYPECHECK_BODY_METRICS',
               'BLORP_CORE_LOWERING_TYPE_METRICS', 'BLORP_PERCEUS_ENGINE_METRICS')
    environment = {key: value for key, value in os.environ.items() if key not in cleared}
    environment['BLORP_MEMORY_STATS'] = '1'
    commands = []

    def portable(value):
        if isinstance(value, str):
            return value.replace(str(REPO), '$REPO').replace(str(output), '$OUTPUT')
        if isinstance(value, list):
            return [portable(item) for item in value]
        if isinstance(value, dict):
            return {key: portable(item) for key, item in value.items()}
        return value

    def run(label, command, stats=False):
        print(label, flush=True)
        result = subprocess.run([str(arg) for arg in command], cwd=REPO,
                                env=environment if stats else None,
                                capture_output=True, text=True, timeout=900)
        (output / (label + '.stdout')).write_text(result.stdout)
        (output / (label + '.stderr')).write_text(result.stderr)
        commands.append({'label': label, 'argv': portable([str(arg) for arg in command]),
                         'stats': stats, 'exit': result.returncode})
        if result.returncode:
            raise RuntimeError(label + ' failed: ' + result.stderr[-2000:])
        return result

    source = (output / 'compiler.normal.c').read_text()
    core = (output / 'compiler.final.core').read_text()
    mapping_path = output / 'compiler.mapping.json'
    # An existing census can be reused only against this exact emission pair.
    if mapping_path.exists():
        mapping = json.loads(mapping_path.read_text())
        if (mapping['source_c_sha256'] != instrument.digest(source)
                or mapping['core_sha256'] != instrument.digest(core)
                or mapping['transformed_c_sha256'] != recipe.sha256_file(output / 'compiler.instrumented.c')
                or not mapping['inversion_audit']):
            raise ValueError('stale instrumented emission')
    else:
        transformed, mapping = instrument.instrument(source, core)
        (output / 'compiler.instrumented.c').write_text(transformed)
        mapping_path.write_text(json.dumps(mapping, indent=2) + '\n')
    # The control adds a nonallocating endpoint report to the same body. This
    # permits exact global allocation comparison at the census's boundary.
    (output / 'compiler.control.c').write_text(source + '''
__attribute__((destructor)) static void census_control_report(void) {
    blorp_MemStats stats = blorp_get_mem_stats();
    fprintf(stderr, "S5_CONTROL managed_allocations=%ld boundary=process_destructor\\n", stats.total_allocations);
}
''')
    del source, core
    recipe.prepare_runtime(1)
    native_recipe = recipe.make_recipe('compile-prepared-blorp-cli', 1)
    for name in ('control', 'instrumented'):
        obj = output / ('compiler.' + name + '.o')
        binary = output / ('compiler.' + name)
        run('compile-' + name, recipe.extract_compile_command(native_recipe, output / ('compiler.' + name + '.c'), obj))
        run('link-' + name, recipe.extract_link_command(native_recipe, obj, binary))
        recipe.verify_binary_mode(binary, 1)
        run('version-' + name, [binary, '--version'])
    for name in ('control', 'instrumented'):
        run('self-' + name, [output / ('compiler.' + name), 'compile', '--std-dir',
                            'standard_library/src', '--no-format', '--no-embed-runtime',
                            '-o', output / ('target.' + name + '.c'), 'blorp/src/main.brp'], True)
    if (output / 'target.control.c').read_bytes() != (output / 'target.instrumented.c').read_bytes():
        raise ValueError('instrumentation changed emitted C')
    rows, ranking = counts(mapping, (output / 'self-instrumented.stderr').read_text())
    control = re.findall(r'^S5_CONTROL managed_allocations=(\d+) boundary=process_destructor$',
                         (output / 'self-control.stderr').read_text(), re.M)
    if len(control) != 1 or int(control[0]) != ranking['global_managed_allocations']:
        raise ValueError('instrumentation changed global managed allocation count')
    runtime = recipe.runtime_object_from_recipe(native_recipe)
    if revision != subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=REPO, text=True).strip():
        raise ValueError('source revision changed during measurement')
    subprocess.run(['git', 'diff', '--quiet', 'HEAD', '--', *source_paths], cwd=REPO, check=True)
    metadata = {'source_revision': revision, 'tree': subprocess.check_output(['git', 'rev-parse', 'HEAD^{tree}'], cwd=REPO, text=True).strip(),
                'commands': commands, 'environment_cleared': list(cleared),
                'environment_set': {'BLORP_MEMORY_STATS': '1', 'BLORP_CLI_C_OPTIMIZATION': '-O2'},
                'inversion_audit': mapping['inversion_audit'], 'emitted_c_identical': True,
                'control_allocations_identical': True, 'hashes': {
                    name: recipe.sha256_file(output / name) for name in
                    ('compiler.normal.c', 'compiler.final.core', 'compiler.instrumented.c',
                     'compiler.mapping.json', 'compiler.control.c', 'compiler.control',
                     'compiler.instrumented', 'target.control.c', 'target.instrumented.c',
                     'self-control.stderr', 'self-instrumented.stderr')},
                'generator_sha256': recipe.sha256_file(REPO / 'bin/blorp'),
                'runtime_sha256': recipe.sha256_file(runtime),
                'instrumenter_sha256': recipe.sha256_file(PREVIOUS / 'instrument.py')}
    (output / 'invocations.json').write_text(json.dumps(metadata, indent=2) + '\n')
    (output / 'ranking.json').write_text(json.dumps(portable(ranking), indent=2) + '\n')
    with gzip.GzipFile(str(output / 'sites.json.gz'), 'wb', mtime=0) as handle:
        handle.write(json.dumps(portable(rows), separators=(',', ':')).encode())
    print(json.dumps({key: value for key, value in ranking.items() if key != 'top20_by_count'}, indent=2))


if __name__ == '__main__':
    main()
