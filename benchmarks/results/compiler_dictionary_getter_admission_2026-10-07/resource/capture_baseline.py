#!/usr/bin/env python3
"""Capture the committed compiler pair before production edits; run only after root GO."""
from pathlib import Path
import argparse
import hashlib
import io
import json
import os
import signal
import subprocess
import tarfile
from datetime import datetime, timezone

PREP = Path(__file__).resolve().parent
ROOT = Path('<worktree:reader-cuts>').resolve()
OUT = PREP / 'baseline'
EXPECTED = PREP / 'prepared.json'
ENV = dict(os.environ, BLORP_CLI_C_OPTIMIZATION='-O2')
COMMANDS = []
EXPECTED_SHA = None


def sha(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as handle:
        for chunk in iter(lambda: handle.read(1048576), b''):
            digest.update(chunk)
    return digest.hexdigest()


def write_json(path, value):
    Path(path).write_text(json.dumps(value, indent=2) + '\n')


def git(*args):
    return subprocess.check_output(['git', *args], cwd=ROOT)


def generated_inputs():
    folder = ROOT / 'blorp/src/compiler/stage_01_generated_inputs'
    return {str(p.relative_to(ROOT)): sha(p) for p in sorted(folder.rglob('*')) if p.is_file()}


def verify_sources(expected):
    if EXPECTED_SHA is not None and sha(EXPECTED) != EXPECTED_SHA:
        raise SystemExit('Prepared baseline pins changed during construction.')
    if sha(__file__) != expected['controller_sha256']:
        raise SystemExit('Reviewed capture controller changed.')
    if git('rev-parse', 'HEAD').decode().strip() != expected['revision']:
        raise SystemExit('HEAD changed; capture is no longer the committed baseline.')
    if git('diff', expected['revision'], '--', *expected['production_paths']):
        raise SystemExit('Baseline production/build/harness inputs differ from the committed revision.')
    archive = git('archive', expected['revision'], *expected['production_paths'])
    if hashlib.sha256(archive).hexdigest() != expected['production_archive_sha256']:
        raise SystemExit('Committed production archive changed.')
    if sha(OUT / 'production.tar') != expected['production_archive_sha256']:
        raise SystemExit('Saved committed production archive changed.')
    if generated_inputs() != expected['generated_inputs']:
        raise SystemExit('Generated compiler inputs changed during baseline construction.')
    for name, pin in expected['binary_pins'].items():
        if sha(pin['live_path']) != pin['sha256'] or sha(pin['retained_path']) != pin['sha256']:
            raise SystemExit('Pinned baseline binary changed: ' + name)
    if sha(ROOT / 'benchmarks/self_compile/small.brp') != expected['small_sha256']:
        raise SystemExit('Small workload changed.')


def run(label, argv, expected, timeout=900):
    verify_sources(expected)
    print('STEP ' + label, flush=True)
    log = OUT / (label + '.log')
    started = datetime.now(timezone.utc).isoformat()
    with log.open('w') as stream:
        process = subprocess.Popen(argv, cwd=ROOT, env=ENV, stdout=stream,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        try:
            code = process.wait(timeout=timeout)
        except BaseException:
            try:
                os.killpg(process.pid, signal.SIGTERM)
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            except ProcessLookupError:
                process.wait()
            raise
    COMMANDS.append({'label': label, 'argv': argv, 'cwd': str(ROOT), 'exit': code,
                     'started_at_utc': started,
                     'ended_at_utc': datetime.now(timezone.utc).isoformat(), 'log': str(log)})
    write_json(OUT / 'capture-commands.json', COMMANDS)
    verify_sources(expected)
    if code:
        print(log.read_text()[-12000:], flush=True)
        raise SystemExit(code)
    return log.read_text()


def frozen_input_proof(path, revision):
    path = Path(path).resolve()
    if (path / '.complete').read_text().strip() != revision:
        raise SystemExit('Frozen input marker does not name the full committed revision.')
    archive = git('archive', revision, 'blorp', 'standard_library')
    with tarfile.open(fileobj=io.BytesIO(archive)) as bundle:
        files = [member for member in bundle.getmembers() if member.isfile()]
        tracked = {member.name for member in files}
        for member in files:
            item = path / member.name
            if not item.is_file() or item.read_bytes() != bundle.extractfile(member).read():
                raise SystemExit('Frozen archive mismatch: ' + member.name)
    actual = {str(p.relative_to(path)) for p in path.rglob('*') if p.is_file()}
    extras = {'.complete', 'blorp/src/compiler/stage_01_generated_inputs/embedded_std.brp'}
    if actual - tracked != extras:
        raise SystemExit('Frozen input contains unexpected files or lacks generated input.')
    entries = [(str(p.relative_to(path)), sha(p)) for p in sorted(path.rglob('*')) if p.is_file()]
    return {'path': str(path), 'revision': revision, 'tracked_files': len(files),
            'archive_sha256': hashlib.sha256(archive).hexdigest(),
            'tree_sha256': hashlib.sha256(json.dumps(entries).encode()).hexdigest(),
            'embedded_std_sha256': sha(path / 'blorp/src/compiler/stage_01_generated_inputs/embedded_std.brp'),
            'allowed_extra_files': sorted(extras)}


def parse_version(text):
    fields = {}
    for line in text.splitlines():
        key, separator, value = line.partition(': ')
        if separator:
            fields[key] = value
    return fields


def main():
    global EXPECTED_SHA
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run-capture', action='store_true', help='Use only after root GO.')
    args = parser.parse_args()
    if not args.run_capture:
        raise SystemExit('Prepared only; root GO is required before --run-capture.')
    expected = json.loads(EXPECTED.read_text())
    EXPECTED_SHA = sha(EXPECTED)
    if (OUT / 'CAPTURE_COMPLETE.json').exists():
        raise SystemExit('Capture already complete; preserve evidence rather than rebuilding.')
    verify_sources(expected)
    before = run('stage1-fresh-before', ['scripts/compiler-build-status'], expected, 120)
    if not before.startswith('FRESH'):
        raise SystemExit('Stage1 did not report FRESH at baseline construction.')
    generator = expected['binary_pins']['stage1']['retained_path']
    generator_version = run('stage1-generator-version', [generator, '--version'], expected, 30)
    run('baseline-stage2-setup', ['benchmarks/build_stage2_compiler', '--generator', generator,
        '--generated-c', str(OUT / 'baseline-main.c'), '--diagnostic-output',
        str(OUT / 'blorp-stage2-diagnostic'), str(OUT / 'blorp-stage2')], expected)
    pairs = {}
    for mode, name in [('normal', 'blorp-stage2'), ('diagnostic', 'blorp-stage2-diagnostic')]:
        binary = (OUT / name).resolve()
        version = run('baseline-' + mode + '-version', [str(binary), '--version'], expected, 30)
        pairs[mode] = {'path': str(binary), 'sha256': sha(binary), 'version': version,
                       'fields': parse_version(version), 'actual_compiler_stage': 2}
    normal = pairs['normal']['fields']; diagnostic = pairs['diagnostic']['fields']
    for field in ['commit', 'compiled_by', 'optimization', 'target', 'split', 'cc']:
        if not normal.get(field) or normal[field] == 'unknown' or normal[field] != diagnostic.get(field):
            raise SystemExit('Pair provenance incomplete or mismatched: ' + field)
    if normal.get('memory_diagnostics') != '0' or diagnostic.get('memory_diagnostics') != '1':
        raise SystemExit('Pair runtime diagnostics modes are not normal=0/diagnostic=1.')
    if normal['optimization'] != 'cli=-O2 runtime=-O2' or not normal['compiled_by'].startswith('self-'):
        raise SystemExit('Expected an O2 compiler body generated by the captured stage1.')
    write_json(OUT / 'stage2-pair-provenance.json', {'revision': expected['revision'],
        'generator_sha256': expected['binary_pins']['stage1']['sha256'],
        'generator_version': generator_version, 'generated_c_sha256': sha(OUT / 'baseline-main.c'),
        'body_object_sha256': sha(OUT / 'baseline-main.o'), 'pairs': pairs,
        'raw_harness_caveat': 'Outside-repo explicit pairs have compiler_rev unknown, freshness unknown and incidental compiler_stage=1; this captured construction proves actual stage 2. Raw metadata remains unchanged.'})
    frozen_path = run('freeze-committed-input', ['benchmarks/self_compile_measure', 'freeze',
        '--rev', expected['revision']], expected, 120).strip()
    frozen = frozen_input_proof(frozen_path, expected['revision'])
    write_json(OUT / 'frozen-input-provenance.json', frozen)
    after = run('stage1-fresh-after', ['scripts/compiler-build-status'], expected, 120)
    if not after.startswith('FRESH'):
        raise SystemExit('Stage1 is not FRESH after baseline pair construction.')
    verify_sources(expected)
    pins = {str(p.relative_to(OUT)): sha(p) for p in sorted(OUT.rglob('*')) if p.is_file()}
    write_json(OUT / 'CAPTURE_COMPLETE.json', {'revision': expected['revision'],
        'captured_at_utc': datetime.now(timezone.utc).isoformat(), 'file_pins': pins,
        'frozen_input': frozen, 'source_archive_sha256': expected['production_archive_sha256'],
        'controller_sha256': expected['controller_sha256'], 'prepared_sha256': EXPECTED_SHA,
        'test_edits_excluded_from_live_source_check': True, 'stage1_fresh_before_after': True,
        'native_processes_finished': True, 'measurement_status': 'Not measured; captured pair ready for three-sample self/small comparison.'})
    print('BASELINE_PAIR_CAPTURED; no baseline source checkout is needed after production edits.', flush=True)


if __name__ == '__main__':
    main()
