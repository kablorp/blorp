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
import capture_baseline as capture

PREP = Path(__file__).resolve().parent
ROOT = capture.ROOT
BASE = PREP / 'baseline'
OUT = PREP / 'comparison'
CONFIG = PREP / 'candidate.json'
CAPTURE_SHA = '39d6592b85309ce79101be6ce5082c38d0f920f859b58aeab8183ef818381e61'
REV = '2ee201fb5cb74e8a7b4f3d068a143d8d71dd2bad'
BOUNDARY = ['blorp/src/compiler/stage_09_core/specialize_collection.brp',
            'blorp/test/test_compiler/test_stage_09_core/test_core_specialize_collection.brp',
            'scripts/check-magic-spellings.allowlist']
ALLOWED_PRODUCTION = {BOUNDARY[0], BOUNDARY[2]}
ENV = dict(os.environ, BLORP_CLI_C_OPTIMIZATION='-O2')
BUSY = re.compile(r'(?:^|\s)(?:\S*/)?(?:scripts/(?:test|compiler-check|compiler-fixpoint|premerge-gate)|benchmarks/(?:self_compile_measure|build_stage2_compiler)|blorp(?:-stage2|-stage2-diagnostic)?|clang(?:-\d+)?|make)(?:\s|$)')
COMMANDS = []
PAIR_PROVENANCE_SHA = None
MEASUREMENT_PINS = {}
MEASUREMENT_MANIFEST_SHA = None


def sha(path):
    return capture.sha(path)


def write_json(path, value):
    capture.write_json(path, value)


def git(*args):
    return capture.git(*args)


def patch_sha(paths):
    return hashlib.sha256(git('diff', '--binary', REV, '--', *paths)).hexdigest()


def verify_baseline():
    if sha(BASE / 'CAPTURE_COMPLETE.json') != CAPTURE_SHA:
        raise SystemExit('Accepted baseline capture proof changed.')
    proof = json.loads((BASE / 'CAPTURE_COMPLETE.json').read_text())
    if proof['revision'] != REV or not proof['stage1_fresh_before_after']:
        raise SystemExit('Baseline construction authority is incomplete.')
    for relative, digest in proof['file_pins'].items():
        if sha(BASE / relative) != digest:
            raise SystemExit('Sealed baseline payload changed: ' + relative)
    if sha(PREP / 'prepared.json') != proof['prepared_sha256']:
        raise SystemExit('Prepared committed baseline pins changed.')
    prepared = json.loads((PREP / 'prepared.json').read_text())
    if sha(PREP / 'capture_baseline.py') != proof['controller_sha256']:
        raise SystemExit('Baseline construction controller changed.')
    archive = git('archive', REV, *prepared['production_paths'])
    if hashlib.sha256(archive).hexdigest() != proof['source_archive_sha256']:
        raise SystemExit('Captured production archive no longer agrees with committed git objects.')
    # This compares immutable archive/git objects, not the edited live production tree.
    frozen = capture.frozen_input_proof(proof['frozen_input']['path'], REV)
    if frozen != proof['frozen_input']:
        raise SystemExit('Frozen full-tree/generated-stdlib authority changed.')
    return proof, prepared


def candidate_state(prepared):
    if git('rev-parse', 'HEAD').decode().strip() != REV:
        raise SystemExit('Candidate HEAD moved from the agreed base.')
    changed = set(git('diff', '--name-only', REV, '--', *prepared['production_paths']).decode().splitlines())
    if not changed <= ALLOWED_PRODUCTION:
        raise SystemExit('Production/build/harness changes exceed this bounded cut: ' + repr(sorted(changed)))
    if git('ls-files', '--others', '--exclude-standard', '--', *prepared['production_paths']).strip():
        raise SystemExit('Untracked production/build/harness input requires explicit review.')
    if sha(ROOT / 'benchmarks/self_compile/small.brp') != prepared['small_sha256']:
        raise SystemExit('The local small workload changed from the captured baseline.')
    untracked_tests = git('ls-files', '--others', '--exclude-standard', '--', 'blorp/test').decode().splitlines()
    untracked_documents = git('ls-files', '--others', '--exclude-standard', '--', 'docs', 'benchmarks/results').decode().splitlines()
    drafts = ['docs/README.md', 'docs/MODULE_RESOLUTION_DESIGN.md']
    return {'boundary_patch_sha256': patch_sha(BOUNDARY),
            'production_patch_sha256': patch_sha(prepared['production_paths']),
            'full_tracked_patch_sha256': hashlib.sha256(git('diff', '--binary', REV)).hexdigest(),
            'test_tree_patch_sha256': patch_sha(['blorp/test']),
            'untracked_test_file_hashes': {path: sha(ROOT / path) for path in untracked_tests},
            'untracked_document_file_hashes': {path: sha(ROOT / path) for path in untracked_documents},
            'preserved_architecture_draft_hashes': {path: sha(ROOT / path) if (ROOT / path).exists() else None for path in drafts},
            'generator_path': str((ROOT / 'bin/blorp').resolve()),
            'generator_sha256': sha(ROOT / 'bin/blorp'),
            'generated_inputs': capture.generated_inputs()}


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


def run(label, argv, config, config_sha, prepared, observe=False, timeout=900):
    verify_state(config, config_sha, prepared)
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
    verify_state(config, config_sha, prepared)
    if process.returncode:
        print(log.read_text()[-12000:], flush=True)
        raise SystemExit(process.returncode)
    return log.read_text()


def verify_state(config, config_sha, prepared):
    verify_baseline()
    if sha(CONFIG) != config_sha or sha(__file__) != config['controller_sha256']:
        raise SystemExit('Reviewed candidate configuration/controller changed.')
    if candidate_state(prepared) != config['candidate_state']:
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
    if MEASUREMENT_PINS:
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
        if not tools['compiled_by'].startswith('self-2ee201fb5cb7'):
            raise SystemExit('Expected compiler body generated by the recorded base-revision stage1.')
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


def main():
    global PAIR_PROVENANCE_SHA
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check-template', action='store_true')
    parser.add_argument('--pin-candidate', action='store_true', help='Read-only pin after final production/review/gates; no native command.')
    parser.add_argument('--run-comparison', action='store_true', help='Use only after reviewed candidate/configuration and root GO.')
    args = parser.parse_args()
    if sum([args.check_template, args.pin_candidate, args.run_comparison]) != 1:
        parser.error('Select exactly one mode.')
    proof, prepared = verify_baseline()
    if args.check_template:
        print('TEMPLATE_READY; sealed baseline and canonical frozen path validated; this mode does not evaluate candidate pins or start native commands.')
        return
    if args.pin_candidate:
        if CONFIG.exists():
            raise SystemExit('Candidate pins already exist; preserve rather than overwrite.')
        write_json(CONFIG, {'revision': REV, 'capture_sha256': CAPTURE_SHA, 'controller_sha256': sha(__file__),
            'boundary_paths': BOUNDARY, 'candidate_state': candidate_state(prepared),
            'authorization': 'This is a read-only pin; independent review and root GO are still required for native comparison.'})
        print('CANDIDATE_PINNED; no native command started.')
        return
    config = json.loads(CONFIG.read_text()); config_sha = sha(CONFIG)
    if config['revision'] != REV or config['capture_sha256'] != CAPTURE_SHA or config['boundary_paths'] != BOUNDARY:
        raise SystemExit('Candidate pin authority differs from this template.')
    if OUT.exists() and any(OUT.iterdir()):
        raise SystemExit('Existing comparison payloads must be preserved; no automatic retry/overwrite.')
    OUT.mkdir(parents=True, exist_ok=True)
    verify_state(config, config_sha, prepared)
    before = run('candidate-fresh-before', ['scripts/compiler-build-status'], config, config_sha, prepared, timeout=120)
    if not before.startswith('FRESH'):
        raise SystemExit('Candidate stage1 is not FRESH.')
    generator = OUT / 'captured-candidate-stage1'; shutil.copy2(ROOT / 'bin/blorp', generator)
    if sha(generator) != config['candidate_state']['generator_sha256']:
        raise SystemExit('Copied candidate generator differs from reviewed generator.')
    run('candidate-stage2-setup', ['benchmarks/build_stage2_compiler', '--generator', str(generator),
        '--generated-c', str(OUT / 'candidate-main.c'), '--diagnostic-output', str(OUT / 'blorp-stage2-diagnostic'),
        str(OUT / 'blorp-stage2')], config, config_sha, prepared)
    pairs = {}
    for mode, name in [('normal', 'blorp-stage2'), ('diagnostic', 'blorp-stage2-diagnostic')]:
        path = (OUT / name).resolve()
        version = run('candidate-' + mode + '-version', [str(path), '--version'], config, config_sha, prepared, timeout=30)
        pairs[mode] = {'path': str(path), 'sha256': sha(path), 'version': version, 'actual_compiler_stage': 2}
    write_json(OUT / 'stage2-pair-provenance.json', pairs)
    PAIR_PROVENANCE_SHA = sha(OUT / 'stage2-pair-provenance.json')
    baseline_pairs = json.loads((BASE / 'stage2-pair-provenance.json').read_text())['pairs']
    frozen = proof['frozen_input']
    for program in ['self', 'small']:
        records = {}
        for role, pair in [('baseline', baseline_pairs), ('candidate', pairs)]:
            argv = ['benchmarks/self_compile_measure', '--program', program, '--input-rev', REV,
                '--input-dir', str(Path(frozen['path']).resolve()), '--samples', '3',
                '--compiler', pair['normal']['path'], '--diagnostic-compiler', pair['diagnostic']['path'],
                '--label', 'dict-get-' + role + '-' + program,
                '--output', str(OUT / f'resource-{role}-{program}.json'),
                '--keep-output', str(OUT / f'resource-{role}-{program}.c')]
            if role == 'candidate':
                argv += ['--baseline', str(OUT / f'resource-baseline-{program}.json'), '--require-identical']
            run('resource-' + role + '-' + program, argv, config, config_sha, prepared, observe=True)
            records[role], pins = validate_record(role, program, pair, frozen)
            pin_validated_outputs(role, program, pins)
            verify_state(config, config_sha, prepared)
        check_budget(program, records['baseline'], records['candidate'])
    after = run('candidate-fresh-after', ['scripts/compiler-build-status'], config, config_sha, prepared, timeout=120)
    if not after.startswith('FRESH'):
        raise SystemExit('Candidate stage1 is not FRESH after comparison.')
    verify_state(config, config_sha, prepared)
    # Re-read every raw record and saved C after all later native commands.
    # Acceptance is recomputed from those still-pinned bytes, not cached metrics.
    for program in ['self', 'small']:
        records = {}
        for role, pair in [('baseline', baseline_pairs), ('candidate', pairs)]:
            records[role], pins = validate_record(role, program, pair, frozen)
            if pins != MEASUREMENT_PINS[role + '-' + program]:
                raise SystemExit('Final revalidation differs from originally validated JSON/C pins.')
        check_budget(program, records['baseline'], records['candidate'])
    verify_state(config, config_sha, prepared)
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
