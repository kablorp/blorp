#!/usr/bin/env python3
"""Use sealed pre-edit compiler products for a matched enabling-cost comparison."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import re
import shutil
import signal
import subprocess
import time
from datetime import datetime, timezone
import seal_reused_baseline as seal
import verify_baseline as baseline

PREP = Path(__file__).resolve().parent
ROOT = seal.ROOT
OUT = PREP / 'comparison'
CONFIG = PREP / 'candidate.json'
CAPTURE_SHA = '3cd26b9a7a8bf551c973c4f02007d464b146fce9d2cfc674ab1ad6debf6a0109'
REV = '2ee201fb5cb74e8a7b4f3d068a143d8d71dd2bad'
BOUNDARY = ['blorp/src/compiler/stage_10_backend/emit.brp',
            'blorp/test/test_compiler/test_stage_10_backend/test_core_emit.brp',
            'scripts/check-magic-spellings.allowlist']
ALLOWED_PRODUCTION = {BOUNDARY[0], BOUNDARY[2]}
ENV = dict(os.environ, BLORP_CLI_C_OPTIMIZATION='-O2')
BUSY = re.compile(r'(?:^|\s)(?:\S*/)?(?:scripts/(?:test|compiler-check|compiler-fixpoint|premerge-gate)|benchmarks/(?:self_compile_measure|build_stage2_compiler)|blorp(?:-stage2|-stage2-diagnostic)?|clang(?:-\d+)?|make)(?:\s|$)')
COMMANDS = []
PAIR_PROVENANCE_SHA = None
MEASUREMENT_PINS = {}
MEASUREMENT_MANIFEST_SHA = None


def sha(path):
    return seal.sha(path)


def write_json(path, value):
    Path(path).write_text(json.dumps(value, indent=2) + '\n')


def git(*args):
    return seal.git(*args)


def patch_sha(paths):
    return hashlib.sha256(git('diff', '--binary', REV, '--', *paths)).hexdigest()


def verify_baseline():
    return baseline.verify()


def generated_inputs():
    folder = ROOT / 'blorp/src/compiler/stage_01_generated_inputs'
    return {str(path.relative_to(ROOT)): sha(path) for path in sorted(folder.rglob('*')) if path.is_file()}


def baseline_allowlist():
    import tarfile
    with tarfile.open(PREP / 'production.tar') as bundle:
        return bundle.extractfile('scripts/check-magic-spellings.allowlist').read()


def verify_allowlist_delta():
    rows = {
        b'compiler/stage_10_backend/emit.brp\treader\tends_with\temit_ranked_tensor_checked_get_call_from_values\t"_f32"\t1\telse if name.ends_with("_f32"):\n',
        b'compiler/stage_10_backend/emit.brp\treader\tends_with\temit_ranked_tensor_checked_get_call_from_values\t"_f64"\t1\tif name.ends_with("_f64"):\n',
    }
    before = baseline_allowlist()
    lines = before.splitlines(keepends=True)
    if any(lines.count(row) != 1 for row in rows):
        raise SystemExit('The two audited baseline allowlist rows are not exact/unique.')
    expected = b''.join(line for line in lines if line not in rows)
    if (ROOT / BOUNDARY[2]).read_bytes() != expected:
        raise SystemExit('Allowlist must remove exactly the two audited suffix rows; no other change.')


def candidate_state(proof):
    # Compare to the actual post-dictionary byte inventory, not raw HEAD:
    # dictionary source/tests/allowlist and existing docs are accepted baseline work.
    head = git('rev-parse', 'HEAD').decode().strip()
    if head != REV:
        raise SystemExit('HEAD moved from agreed2ee; retain proof and seek coordinator guidance.')
    paths = proof['production_paths']
    if git('ls-files', '--others', '--exclude-standard', '--', *paths).strip():
        raise SystemExit('Untracked production/build/harness input requires explicit review.')
    tracked = [path for path in git('ls-files', '-z', '--', *paths).decode().split('\0') if path]
    generated = generated_inputs()
    inventory = {path: sha(ROOT / path) for path in sorted(set(tracked) | set(generated))}
    before = json.loads((PREP / 'production-file-hashes.json').read_text())
    if set(inventory) != set(before):
        raise SystemExit('Compiler/build/harness file set changed outside the bounded cut.')
    changed = {path for path in before if inventory[path] != before[path]}
    if not changed <= ALLOWED_PRODUCTION | set(proof['generated_inputs']):
        raise SystemExit('Production/build/harness delta exceeds emitter/allowlist scope: ' + repr(sorted(changed)))
    if generated.keys() != proof['generated_inputs'].keys():
        raise SystemExit('Generated input file set changed.')
    embedded = 'blorp/src/compiler/stage_01_generated_inputs/embedded_std.brp'
    if generated[embedded] != proof['generated_inputs'][embedded]:
        raise SystemExit('Generated stdlib changed despite unchanged stdlib production.')
    if BOUNDARY[0] not in changed:
        raise SystemExit('Final emitter candidate has no production change.')
    verify_allowlist_delta()
    if sha(ROOT / 'benchmarks/self_compile/small.brp') != proof['small_sha256']:
        raise SystemExit('Local small workload changed from the captured baseline.')
    tracked_all = [path for path in git('ls-files', '-z').decode().split('\0') if path]
    untracked = [path for path in git('ls-files', '--others', '--exclude-standard', '-z').decode().split('\0') if path]
    full_tracked = {path: sha(ROOT / path) if (ROOT / path).is_file() else None for path in tracked_all}
    untracked_all = {path: sha(ROOT / path) for path in untracked}
    test_before = {path: value for path, value in json.loads((PREP / 'test-document-file-hashes.json').read_text()).items() if path.startswith('blorp/test/')}
    test_now = {path: value for path, value in (full_tracked | untracked_all).items() if path.startswith('blorp/test/')}
    test_changed = {path for path in test_before.keys() | test_now.keys() if test_before.get(path) != test_now.get(path)}
    if not test_changed <= {BOUNDARY[1]}:
        raise SystemExit('Test delta exceeds owning emitter suite: ' + repr(sorted(test_changed)))
    return {
        'head_revision': head,
        'baseline_production_archive_sha256': proof['production_archive_sha256'],
        'production_changed_from_post_dictionary_baseline': sorted(changed),
        'production_file_hashes': inventory,
        'boundary_file_hashes': {path: sha(ROOT / path) for path in BOUNDARY},
        'boundary_patch_vs_input_revision_sha256': patch_sha(BOUNDARY),
        'production_patch_vs_input_revision_sha256': patch_sha(paths),
        'full_tracked_file_hashes': full_tracked,
        'full_tracked_patch_vs_input_revision_sha256': hashlib.sha256(git('diff', '--binary', REV)).hexdigest(),
        'test_tree_patch_vs_input_revision_sha256': patch_sha(['blorp/test']),
        'untracked_file_hashes': untracked_all,
        'untracked_test_file_hashes': {path: value for path, value in untracked_all.items() if path.startswith('blorp/test/')},
        'untracked_document_file_hashes': {path: value for path, value in untracked_all.items() if path.startswith(('docs/', 'benchmarks/results/'))},
        'preserved_architecture_draft_hashes': {path: sha(ROOT / path) if (ROOT / path).exists() else None for path in ['docs/README.md', 'docs/MODULE_RESOLUTION_DESIGN.md']},
        'generator_path': str((ROOT / 'bin/blorp').resolve()),
        'generator_sha256': sha(ROOT / 'bin/blorp'),
        'generated_inputs': generated,
    }


def dependency_pins():
    return {name: sha(PREP / name) for name in ['verify_baseline.py', 'seal_reused_baseline.py', 'GENERATOR_RETAINED.json']}


def external_native():
    lines = subprocess.check_output(['ps', '-axo', 'pid=,ppid=,args='], text=True).splitlines()
    processes = {}
    for line in lines:
        fields = line.strip().split(None, 2)
        if len(fields) == 3:
            processes[int(fields[0])] = (int(fields[1]), fields[2])
    ignored = set(); current = os.getpid()
    while current in processes and current not in ignored:
        ignored.add(current); current = processes[current][0]
    descendants = {os.getpid()}
    while True:
        expanded = descendants | {pid for pid, (parent, _) in processes.items() if parent in descendants}
        if expanded == descendants:
            break
        descendants = expanded
    return [{'pid': pid, 'command': command} for pid, (_, command) in processes.items()
            if pid not in ignored | descendants and BUSY.search(command)]


def run(label, argv, config, config_sha, proof, observe=False, timeout=900):
    verify_state(config, config_sha, proof)
    print('STEP ' + label, flush=True)
    log = OUT / (label + '.log'); seen = {}
    started = datetime.now(timezone.utc).isoformat()
    if observe:
        seen.update({entry['pid']: entry for entry in external_native()})
    with log.open('w') as stream:
        process = subprocess.Popen(argv, cwd=ROOT, env=ENV, stdout=stream,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        deadline = time.monotonic() + timeout
        try:
            while process.poll() is None:
                if time.monotonic() > deadline:
                    raise TimeoutError('Native command timeout: ' + label)
                if observe:
                    seen.update({entry['pid']: entry for entry in external_native()})
                time.sleep(1)
        except BaseException:
            try:
                os.killpg(process.pid, signal.SIGTERM); process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL); process.wait()
            except ProcessLookupError:
                process.wait()
            raise
    if observe:
        seen.update({entry['pid']: entry for entry in external_native()})
    COMMANDS.append({'label': label, 'argv': argv, 'cwd': str(ROOT), 'exit': process.returncode,
        'started_at_utc': started, 'ended_at_utc': datetime.now(timezone.utc).isoformat(),
        'log': str(log), 'external_native_activity': list(seen.values()),
        'activity_policy': 'Observed background work is documented, not rejected; repository minimum-of-runs applies.' if observe else None})
    write_json(OUT / 'resource-commands.json', COMMANDS)
    verify_state(config, config_sha, proof)
    if process.returncode:
        print(log.read_text()[-12000:], flush=True)
        raise SystemExit(process.returncode)
    return log.read_text()


def verify_state(config, config_sha, proof):
    verify_baseline()
    if sha(CONFIG) != config_sha or sha(__file__) != config['controller_sha256']:
        raise SystemExit('Reviewed candidate configuration/controller changed.')
    if dependency_pins() != config['dependency_pins']:
        raise SystemExit('Reviewed baseline verifier dependencies changed.')
    if candidate_state(proof) != config['candidate_state']:
        raise SystemExit('Reviewed candidate source/generated input/generator changed.')
    retained_generator = OUT / 'captured-candidate-stage1'
    if retained_generator.exists() and sha(retained_generator) != config['candidate_state']['generator_sha256']:
        raise SystemExit('Retained candidate generator changed.')
    if (OUT / 'stage2-pair-provenance.json').exists():
        if PAIR_PROVENANCE_SHA is None or sha(OUT / 'stage2-pair-provenance.json') != PAIR_PROVENANCE_SHA:
            raise SystemExit('Candidate pair provenance changed.')
        pairs = json.loads((OUT / 'stage2-pair-provenance.json').read_text())
        for item in pairs.values():
            if sha(item['path']) != item['sha256']:
                raise SystemExit('Candidate paired compiler changed.')
    verify_measurement_pins()


def verify_measurement_pins():
    if not MEASUREMENT_PINS:
        return
    if sha(OUT / 'measurement-pins.json') != MEASUREMENT_MANIFEST_SHA:
        raise SystemExit('Validated measurement pin manifest changed.')
    for pins in MEASUREMENT_PINS.values():
        for item in pins.values():
            if sha(item['path']) != item['sha256']:
                raise SystemExit('Previously validated measurement JSON/C changed: ' + item['path'])


def pin_validated_outputs(role, program, pins):
    global MEASUREMENT_MANIFEST_SHA
    key = role + '-' + program
    if key in MEASUREMENT_PINS:
        raise SystemExit('Validated measurement pins must not be recaptured.')
    for item in pins.values():
        if sha(item['path']) != item['sha256']:
            raise SystemExit('Measurement changed between validation and pinning: ' + item['path'])
    MEASUREMENT_PINS[key] = pins
    write_json(OUT / 'measurement-pins.json', MEASUREMENT_PINS)
    MEASUREMENT_MANIFEST_SHA = sha(OUT / 'measurement-pins.json')


def validate_record(role, program, pair, frozen):
    json_path = OUT / f'resource-{role}-{program}.json'
    raw_json = json_path.read_bytes()
    record = json.loads(raw_json)
    if record['schema'] != 2 or record['program'] != program or record['input_rev'] != REV:
        raise SystemExit('Wrong measurement schema/program/input revision.')
    if Path(record['input_dir']).resolve() != Path(frozen['path']).resolve():
        raise SystemExit('Canonical frozen input path differs.')
    samples = record['instructions_retired']['samples']
    if record['samples'] != 3 or len(samples) != 3 or record['instructions_retired']['min'] != min(samples):
        raise SystemExit('Expected exactly three valid normal instruction samples.')
    for number in [record['total_allocations'], record['output_bytes'], *samples]:
        if isinstance(number, bool) or not isinstance(number, int) or number <= 0:
            raise SystemExit('Missing positive allocation/instruction/output evidence.')
    for mode, path_key, hash_key, toolchain_key, diagnostics in [
        ('normal', 'compiler_path', 'compiler_sha256', 'toolchain', '0'),
        ('diagnostic', 'diagnostic_compiler_path', 'diagnostic_compiler_sha256', 'diagnostic_toolchain', '1')]:
        if Path(record[path_key]).resolve() != Path(pair[mode]['path']).resolve() or record[hash_key] != pair[mode]['sha256']:
            raise SystemExit('Measured compiler differs from captured paired authority.')
        tools = record[toolchain_key]
        if tools['memory_diagnostics'] != diagnostics or tools['optimization'] != 'cli=-O2 runtime=-O2':
            raise SystemExit('Compiler mode or optimization differs.')
        for field in ['cc_version', 'commit', 'compiled_by', 'target', 'split', 'cc']:
            if tools.get(field) in [None, '', 'unknown']:
                raise SystemExit('Missing toolchain field: ' + field)
        fields = parse_version(pair[mode]['version'])
        for field in ['commit', 'compiled_by', 'optimization', 'target', 'split', 'cc', 'memory_diagnostics']:
            if tools[field] != fields.get(field):
                raise SystemExit('Raw measured header differs from exact retained pair: ' + field)
        if tools['compiled_by'] != 'self-2ee201fb5cb7':
            raise SystemExit('Expected exact self-2ee stage2 header; no stamp normalization.')
    for field in ['cc_version', 'commit', 'compiled_by', 'optimization', 'target', 'split', 'cc']:
        if record['toolchain'][field] != record['diagnostic_toolchain'][field]:
            raise SystemExit('Normal/diagnostic toolchains differ: ' + field)
    output = OUT / f'resource-{role}-{program}.c'
    output_sha = sha(output)
    if output_sha != record['output_sha256'] or output.stat().st_size != record['output_bytes']:
        raise SystemExit('Retained whole-C output differs from its raw record.')
    if record['c_optimization'] != '-O2':
        raise SystemExit('Harness optimization differs.')
    return record, {
        'json': {'path': str(json_path.resolve()), 'sha256': hashlib.sha256(raw_json).hexdigest()},
        'c': {'path': str(output.resolve()), 'sha256': output_sha},
    }


def check_budget(program, baseline, candidate):
    for field in ['cc_version', 'compiled_by', 'optimization', 'target', 'split', 'cc']:
        if baseline['toolchain'][field] != candidate['toolchain'][field]:
            raise SystemExit('Baseline/candidate toolchain mismatch: ' + field)
    result = {'program': program, 'input_revision': REV, 'actual_compiler_stage': 2,
              'generated_c_identical': baseline['output_sha256'] == candidate['output_sha256'], 'metrics': {}}
    for name in ['total_allocations', 'instructions_retired']:
        before = baseline[name]['min'] if name == 'instructions_retired' else baseline[name]
        after = candidate[name]['min'] if name == 'instructions_retired' else candidate[name]
        result['metrics'][name] = {'baseline': before, 'candidate': after,
            'delta_percent': (after - before) / before * 100, 'within_0_5_percent_ceiling': after * 200 <= before * 201}
    for role, record in [('baseline', baseline), ('candidate', candidate)]:
        samples = record['instructions_retired']['samples']
        result[role + '_instruction_samples'] = {'samples': samples, 'min': min(samples), 'max': max(samples),
            'spread_percent_of_min': (max(samples) - min(samples)) / min(samples) * 100}
    write_json(OUT / f'resource-summary-{program}.json', result)
    print(json.dumps(result), flush=True)
    if not result['generated_c_identical'] or any(not item['within_0_5_percent_ceiling'] for item in result['metrics'].values()):
        raise SystemExit('Identity or enabling cost ceiling failed; retain evidence and report.')


def parse_version(text):
    fields = {}
    for line in text.splitlines():
        key, separator, value = line.partition(': ')
        if separator:
            fields[key] = value
    return fields


def main():
    global PAIR_PROVENANCE_SHA
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check-template', action='store_true')
    parser.add_argument('--pin-candidate', action='store_true', help='Read-only pin after final production/review/gates; no native command.')
    parser.add_argument('--run-comparison', action='store_true', help='Use only after reviewed candidate/configuration and root GO.')
    args = parser.parse_args()
    if sum([args.check_template, args.pin_candidate, args.run_comparison]) != 1:
        parser.error('Select exactly one mode.')
    proof = verify_baseline()
    if args.check_template:
        print('TEMPLATE_READY; sealed baseline and canonical frozen path validated; this mode does not evaluate candidate pins or start native commands.')
        return
    if args.pin_candidate:
        if CONFIG.exists():
            raise SystemExit('Candidate pins already exist; preserve rather than overwrite.')
        write_json(CONFIG, {'revision': REV, 'capture_sha256': CAPTURE_SHA, 'controller_sha256': sha(__file__),
            'boundary_paths': BOUNDARY, 'dependency_pins': dependency_pins(),
            'candidate_state': candidate_state(proof),
            'authorization': 'This is a read-only pin; independent review and root GO are still required for native comparison.'})
        print('CANDIDATE_PINNED; no native command started.')
        return
    config = json.loads(CONFIG.read_text()); config_sha = sha(CONFIG)
    if config['revision'] != REV or config['capture_sha256'] != CAPTURE_SHA or config['boundary_paths'] != BOUNDARY:
        raise SystemExit('Candidate pin authority differs from this template.')
    if OUT.exists() and any(OUT.iterdir()):
        raise SystemExit('Existing comparison payloads must be preserved; no automatic retry/overwrite.')
    OUT.mkdir(parents=True, exist_ok=True)
    verify_state(config, config_sha, proof)
    before = run('candidate-fresh-before', ['scripts/compiler-build-status'], config, config_sha, proof, timeout=120)
    if not before.startswith('FRESH'):
        raise SystemExit('Candidate stage1 is not FRESH.')
    generator = OUT / 'captured-candidate-stage1'; shutil.copy2(ROOT / 'bin/blorp', generator)
    if sha(generator) != config['candidate_state']['generator_sha256']:
        raise SystemExit('Copied candidate generator differs from reviewed generator.')
    run('candidate-stage2-setup', ['benchmarks/build_stage2_compiler', '--generator', str(generator),
        '--generated-c', str(OUT / 'candidate-main.c'), '--diagnostic-output', str(OUT / 'blorp-stage2-diagnostic'),
        str(OUT / 'blorp-stage2')], config, config_sha, proof)
    pairs = {}
    for mode, name in [('normal', 'blorp-stage2'), ('diagnostic', 'blorp-stage2-diagnostic')]:
        path = (OUT / name).resolve()
        version = run('candidate-' + mode + '-version', [str(path), '--version'], config, config_sha, proof, timeout=30)
        pairs[mode] = {'path': str(path), 'sha256': sha(path), 'version': version, 'actual_compiler_stage': 2}
    write_json(OUT / 'stage2-pair-provenance.json', pairs)
    PAIR_PROVENANCE_SHA = sha(OUT / 'stage2-pair-provenance.json')
    baseline_pairs = proof['pairs']
    frozen = proof['frozen_input']
    for program in ['self', 'small']:
        records = {}
        for role, pair in [('baseline', baseline_pairs), ('candidate', pairs)]:
            argv = ['benchmarks/self_compile_measure', '--program', program, '--input-rev', REV,
                '--input-dir', str(Path(frozen['path']).resolve()), '--samples', '3',
                '--compiler', pair['normal']['path'], '--diagnostic-compiler', pair['diagnostic']['path'],
                '--label', 'ranked-tensor-' + role + '-' + program,
                '--output', str(OUT / f'resource-{role}-{program}.json'),
                '--keep-output', str(OUT / f'resource-{role}-{program}.c')]
            if role == 'candidate':
                argv += ['--baseline', str(OUT / f'resource-baseline-{program}.json'), '--require-identical']
            run('resource-' + role + '-' + program, argv, config, config_sha, proof, observe=True)
            records[role], pins = validate_record(role, program, pair, frozen)
            pin_validated_outputs(role, program, pins)
            verify_state(config, config_sha, proof)
        check_budget(program, records['baseline'], records['candidate'])
    after = run('candidate-fresh-after', ['scripts/compiler-build-status'], config, config_sha, proof, timeout=120)
    if not after.startswith('FRESH'):
        raise SystemExit('Candidate stage1 is not FRESH after comparison.')
    verify_state(config, config_sha, proof)
    # Re-read every raw record and saved C after all later native commands.
    # Acceptance is recomputed from those still-pinned bytes, not cached metrics.
    for program in ['self', 'small']:
        records = {}
        for role, pair in [('baseline', baseline_pairs), ('candidate', pairs)]:
            records[role], pins = validate_record(role, program, pair, frozen)
            if pins != MEASUREMENT_PINS[role + '-' + program]:
                raise SystemExit('Final revalidation differs from originally validated JSON/C pins.')
        check_budget(program, records['baseline'], records['candidate'])
    verify_state(config, config_sha, proof)
    write_json(OUT / 'COMPARISON_COMPLETE.json', {'revision': REV, 'capture_sha256': CAPTURE_SHA,
        'configuration_sha256': config_sha, 'controller_sha256': config['controller_sha256'],
        'source_frozen': True, 'baseline_live_freshness_required': False, 'baseline_sealed_pins_rechecked': True,
        'candidate_stage1_fresh_before_after': True, 'native_processes_finished': True,
        'all_four_raw_records_and_saved_c_revalidated': True, 'measurement_output_pins': MEASUREMENT_PINS,
        'limits': 'Self/small enabling scope only; background activity logged, no quiet/wall-time/speed claim.',
        'file_pins': {str(p.relative_to(OUT)): sha(p) for p in sorted(OUT.rglob('*')) if p.is_file()}})
    print('MATCHED_RESOURCE_COMPARISON_PASS; no native child remains.', flush=True)


if __name__ == '__main__':
    main()
