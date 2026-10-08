from pathlib import Path
import hashlib
import io
import json
import os
import re
import signal
import subprocess
import tarfile
import time
from datetime import datetime, timezone

BASE = Path('<worktree:nominal-type-identity>')
CAND = Path('<worktree:reader-cuts>')
PREP = Path('/tmp/blorp-identity-wave-combined-resource')
VALID_BASELINE = Path('/tmp/blorp-identity-wave-wave3-resource')
OUT = PREP / 'results'
EXPECTED_PATHS = ['blorp/src/compiler/stage_06_typecheck/type_system/semantic_type.brp', 'blorp/src/compiler/stage_09_core/backend_projection.brp', 'blorp/src/compiler/stage_09_core/specialize_collection.brp', 'blorp/src/compiler/stage_09_core/specialize.brp', 'blorp/test/test_compiler/test_stage_06_typecheck/test_type_system/test_type.brp', 'blorp/test/test_compiler/test_stage_09_core/test_core_backend_projection.brp', 'blorp/test/test_compiler/test_stage_09_core/test_core_specialize.brp', 'scripts/check-magic-spellings.allowlist']
OUT.mkdir(parents=True, exist_ok=True)
REV = '7ab679600bcefa2fda3d0a14fe4b432758bad91b'
ENV = dict(os.environ, BLORP_CLI_C_OPTIMIZATION='-O2')
COMMANDS = []
FROZEN_INPUT = None
FROZEN_INPUT_SHA256 = None
SMALL_INPUT_SHA256 = None
BUSY = re.compile(r'(?:^|\s)(?:\S*/)?(?:scripts/(?:test|compiler-check|compiler-fixpoint|premerge-gate)|benchmarks/(?:self_compile_measure|build_stage2_compiler)|bin/blorp(?:-stage2|-diagnostic|-stage2-diagnostic)?|clang(?:-\d+)?|make)(?:\s|$)')

def source_state(root):
    return hashlib.sha256(subprocess.check_output(['git', 'diff', 'HEAD', '--', 'blorp/src', 'standard_library/src'], cwd=root)).hexdigest()

INITIAL = {str(root): source_state(root) for root in (BASE, CAND)}

def tree_sha256(root):
    entries = [(str(path.relative_to(root)), hashlib.sha256(path.read_bytes()).hexdigest())
               for path in sorted(root.rglob('*')) if path.is_file()]
    return hashlib.sha256(json.dumps(entries).encode()).hexdigest()

def verify_frozen_input(root):
    archive = subprocess.check_output(['git', 'archive', REV, 'blorp', 'standard_library'], cwd=BASE)
    with tarfile.open(fileobj=io.BytesIO(archive)) as bundle:
        files = [member for member in bundle.getmembers() if member.isfile()]
        expected = {member.name for member in files}
        mismatches = [member.name for member in files
                      if not (root / member.name).is_file()
                      or (root / member.name).read_bytes() != bundle.extractfile(member).read()]
    actual = {str(path.relative_to(root)) for path in root.rglob('*') if path.is_file()}
    allowed_extras = {'.complete', 'blorp/src/compiler/stage_01_generated_inputs/embedded_std.brp'}
    if mismatches or actual - expected != allowed_extras:
        raise SystemExit('Frozen input differs from exact-base archive or expected generated inputs.')
    return {'path': str(root), 'revision': REV, 'archive_files': len(files),
            'tree_sha256': tree_sha256(root), 'allowed_extra_files': sorted(allowed_extras),
            'embedded_std_sha256': hashlib.sha256((root / 'blorp/src/compiler/stage_01_generated_inputs/embedded_std.brp').read_bytes()).hexdigest()}

def external_native():
    output = subprocess.check_output(['ps', '-axo', 'pid=,ppid=,args='], text=True)
    processes = {}
    for line in output.splitlines():
        fields = line.strip().split(None, 2)
        if len(fields) == 3:
            processes[int(fields[0])] = (int(fields[1]), fields[2])
    ancestors = set()
    current = os.getpid()
    while current in processes:
        ancestors.add(current)
        current = processes[current][0]
        if current in ancestors:
            break
    descendants = {os.getpid()}
    changed = True
    while changed:
        changed = False
        for pid, (parent, _) in processes.items():
            if parent in descendants and pid not in descendants:
                descendants.add(pid)
                changed = True
    ignored = ancestors | descendants
    return [{'pid': pid, 'command': command} for pid, (_, command) in processes.items()
            if pid not in ignored and 'native_slot.py' not in command and BUSY.search(command)]

def run(label, root, argv, observe_background=False):
    print(f'STEP {label}', flush=True)
    start = time.monotonic()
    started_at = datetime.now(timezone.utc).isoformat()
    log = OUT / f'{label}.log'
    overlaps = []
    if observe_background:
        overlaps.extend(external_native())
    with log.open('w') as stream:
        process = subprocess.Popen(argv, cwd=root, env=ENV, stdout=stream, stderr=subprocess.STDOUT,
                                   start_new_session=True)
        try:
            while process.poll() is None:
                if observe_background:
                    overlaps.extend(external_native())
                time.sleep(1)
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
    if observe_background:
        overlaps.extend(external_native())
    unique = {entry['pid']: entry for entry in overlaps}
    COMMANDS.append({'started_at_utc': started_at, 'ended_at_utc': datetime.now(timezone.utc).isoformat(), 'label': label, 'argv': argv, 'cwd': str(root), 'exit': process.returncode,
                     'seconds': time.monotonic() - start, 'log': str(log),
                     'external_native_overlap': list(unique.values()),
                     'background_activity_observed': bool(unique) if observe_background else None,
                     'measurement_policy': 'Repository min-of-runs; background activity observed, not a rejection criterion.' if observe_background else None})
    (OUT / 'resource-commands.json').write_text(json.dumps(COMMANDS, indent=2))
    print(f'{label}: exit={process.returncode}; log={log}; external_overlap={len(unique)}', flush=True)
    if process.returncode:
        print(log.read_text()[-12000:], flush=True)
        raise SystemExit(process.returncode)
    for known_root in (BASE, CAND):
        if source_state(known_root) != INITIAL[str(known_root)]:
            raise SystemExit('Compiler sources changed during resource batch; evidence invalid.')
    if hashlib.sha256(subprocess.check_output(['git', 'diff', '--binary', REV, '--', *EXPECTED_PATHS], cwd=CAND)).hexdigest() != frozen['patch_sha256']:
        raise SystemExit('Reviewed candidate patch changed during resource batch.')
    if hashlib.sha256(Path(frozen['candidate_binary']).read_bytes()).hexdigest() != frozen['candidate_binary_sha256']:
        raise SystemExit('Pinned combined stage1 generator changed during the batch.')
    if FROZEN_INPUT is not None and tree_sha256(FROZEN_INPUT) != FROZEN_INPUT_SHA256:
        raise SystemExit('Frozen compile input changed during resource batch; evidence invalid.')
    if SMALL_INPUT_SHA256 is not None:
        for known_root in (BASE, CAND):
            if hashlib.sha256((known_root / 'benchmarks/self_compile/small.brp').read_bytes()).hexdigest() != SMALL_INPUT_SHA256:
                raise SystemExit('Small compile input changed during resource batch; evidence invalid.')
    return log.read_text()

def validate_record(record, role, program):
    if record['program'] != program or record['input_rev'] != REV or Path(record['input_dir']).resolve() != FROZEN_INPUT.resolve():
        raise SystemExit('Measurement workload/input provenance mismatch.')
    if record['samples'] < 3 or len(record['instructions_retired']['samples']) != record['samples']:
        raise SystemExit('Fewer than three matched normal instruction samples.')
    if record['instructions_retired']['min'] != min(record['instructions_retired']['samples']):
        raise SystemExit('Retired instruction minimum differs from recorded samples.')
    for value in [record['total_allocations'], record['output_bytes'], *record['instructions_retired']['samples']]:
        if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
            raise SystemExit('Missing positive allocation/instruction/output evidence.')
    normal = record['toolchain']
    diagnostic = record['diagnostic_toolchain']
    required = ['cc_version', 'optimization', 'target', 'split', 'cc', 'compiled_by', 'commit']
    for field in required:
        if normal.get(field) in (None, 'unknown', '') or diagnostic.get(field) in (None, 'unknown', ''):
            raise SystemExit('Incomplete normal/diagnostic toolchain evidence: ' + field)
        if normal[field] != diagnostic[field]:
            raise SystemExit('Normal/diagnostic toolchain mismatch: ' + field)
    if normal['memory_diagnostics'] != '0' or diagnostic['memory_diagnostics'] != '1':
        raise SystemExit('Normal/diagnostic memory-runtime modes mismatch.')
    if normal['optimization'] != 'cli=-O2 runtime=-O2' or record['c_optimization'] != '-O2':
        raise SystemExit('Expected matching CLI/runtime -O2 measurement.')
    if not normal['compiled_by'].startswith('self-'):
        raise SystemExit('Expected compiler generated by the recorded stage1 compiler.')
    for mode, path_field, hash_field in [('normal', 'compiler_path', 'compiler_sha256'),
                                        ('diagnostic', 'diagnostic_compiler_path', 'diagnostic_compiler_sha256')]:
        expected = pairs[role][mode]
        if Path(record[path_field]).resolve() != Path(expected['path']).resolve() or record[hash_field] != expected['sha256']:
            raise SystemExit('Measurement compiler differs from pinned paired binary.')
    output = (VALID_BASELINE if role == 'baseline' else OUT) / f'resource-{role}-{program}.c'
    if hashlib.sha256(output.read_bytes()).hexdigest() != record['output_sha256']:
        raise SystemExit('Retained C differs from its measurement hash.')

def check_budget(program):
    baseline = BASELINES[program]
    candidate = json.loads((OUT / f'resource-candidate-{program}.json').read_text())
    validate_record(baseline, 'baseline', program)
    validate_record(candidate, 'candidate', program)
    if baseline['samples'] != candidate['samples']:
        raise SystemExit('Baseline/candidate sample counts differ.')
    for field in ('cc_version', 'optimization', 'target', 'split', 'cc'):
        if baseline['toolchain'][field] != candidate['toolchain'][field]:
            raise SystemExit('Baseline/candidate toolchain mismatch: ' + field)
    result = {'program': program, 'generated_c_identical': baseline['output_sha256'] == candidate['output_sha256'],
              'input_revisions_equal': baseline['input_rev'] == candidate['input_rev'],
              'samples': [baseline['samples'], candidate['samples']], 'actual_compiler_stage': 2, 'metrics': {}}
    for metric in ('total_allocations', 'instructions_retired'):
        before = baseline[metric]['min'] if metric == 'instructions_retired' else baseline[metric]
        after = candidate[metric]['min'] if metric == 'instructions_retired' else candidate[metric]
        percentage = (after - before) / before * 100
        result['metrics'][metric] = {'baseline': before, 'candidate': after, 'delta_percent': percentage,
                                     'within_0_5_percent_ceiling': after * 200 <= before * 201}
    for role, record in [('baseline', baseline), ('candidate', candidate)]:
        samples = record['instructions_retired']['samples']
        result[role + '_instruction_sample_spread'] = {
            'samples': samples, 'min': min(samples), 'max': max(samples),
            'spread_percent_of_min': (max(samples) - min(samples)) / min(samples) * 100,
        }
    (OUT / f'resource-summary-{program}.json').write_text(json.dumps(result, indent=2))
    print(json.dumps(result), flush=True)
    if not result['generated_c_identical'] or not result['input_revisions_equal']:
        raise SystemExit('Resource identity mismatch; stop and report.')
    if any(not metric['within_0_5_percent_ceiling'] for metric in result['metrics'].values()):
        raise SystemExit('Resource enabling ceiling exceeded; stop and report.')



if not (PREP / 'expected.json').is_file():
    raise SystemExit('Not runnable until root captures post-integration/build expected.json and gives GO.')
(OUT / 'source-provenance.json').write_text(json.dumps(INITIAL, indent=2))
for known_root in (BASE, CAND):
    if subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=known_root, text=True).strip() != REV:
        raise SystemExit('Checkout is no longer at the exact base revision.')
if INITIAL[str(BASE)] != hashlib.sha256(b'').hexdigest():
    raise SystemExit('Baseline compiler sources are no longer untouched.')
frozen = json.loads((PREP / 'expected.json').read_text())
if frozen.get('revision') != REV or frozen.get('boundary_paths') != EXPECTED_PATHS or not frozen.get('patch_sha256') or not frozen.get('candidate_binary_sha256'):
    raise SystemExit('Missing post-integration/build fingerprints; root must capture expected.json first.')
BASELINES = {}
pins = json.loads((PREP / 'valid-baseline-pins.json').read_text())
for program in ('self', 'small'):
    for kind in ('json', 'c'):
        pinned = pins[program][kind]
        if hashlib.sha256(Path(pinned['path']).read_bytes()).hexdigest() != pinned['sha256']:
            raise SystemExit('Valid wave3 baseline payload changed.')
    BASELINES[program] = json.loads(Path(pins[program]['json']['path']).read_text())
current_patch = subprocess.check_output(['git', 'diff', '--binary', REV, '--', *EXPECTED_PATHS], cwd=CAND)
if hashlib.sha256(current_patch).hexdigest() != frozen['patch_sha256']:
    raise SystemExit('Candidate differs from the independently reviewed frozen patch.')
for path_key, hash_key in (('candidate_binary', 'candidate_binary_sha256'),):
    if hashlib.sha256(Path(frozen[path_key]).read_bytes()).hexdigest() != frozen[hash_key]:
        raise SystemExit('Pinned stage1 compiler changed.')
preflight = external_native()
(OUT / 'preflight-overlap.json').write_text(json.dumps(preflight, indent=2))
for label, root in (('resource-base-freshness', BASE), ('resource-candidate-freshness', CAND)):
    if not run(label, root, ['scripts/compiler-build-status']).startswith('FRESH'):
        raise SystemExit('Resource compiler did not report FRESH.')
expected_base = {
    'normal': '789ea481aa37eb676449d1fb65ea7f5492f4d5835d05e0335477faac1acba859',
    'diagnostic': '5df0efcfb1ec8bff9948b19e22c273d3361bace65128e0de4450ea8309d96b29',
}
for mode, filename in (('normal', 'blorp-stage2'), ('diagnostic', 'blorp-stage2-diagnostic')):
    if hashlib.sha256((BASE / 'bin' / filename).read_bytes()).hexdigest() != expected_base[mode]:
        raise SystemExit('Retained exact baseline stage2 pair changed.')
# Reuse only the accepted repository-protocol wave3 baseline records and C.
input_reference = BASELINES['self']
frozen_input = Path(input_reference['input_dir']).resolve()
if not (frozen_input / '.complete').is_file() or (frozen_input / '.complete').read_text().strip() != REV:
    raise SystemExit('Expected the exact-base frozen input snapshot.')
input_provenance = verify_frozen_input(frozen_input)
accepted_input = json.loads((VALID_BASELINE / 'frozen-input-provenance.json').read_text())
if input_provenance['tree_sha256'] != accepted_input['inventory_sha256'] or input_provenance['embedded_std_sha256'] != accepted_input['embedded_std_sha256'] or input_provenance['archive_files'] != accepted_input['tracked_files_verified']:
    raise SystemExit('Frozen snapshot differs from the accepted baseline input.')
FROZEN_INPUT = frozen_input
FROZEN_INPUT_SHA256 = input_provenance['tree_sha256']
(OUT / 'frozen-input-provenance.json').write_text(json.dumps(input_provenance, indent=2))
run('candidate-stage2-setup', CAND,
    ['benchmarks/build_stage2_compiler', '--diagnostic-output', str(CAND / 'bin/blorp-reader-cuts-stage2-diagnostic'),
     str(CAND / 'bin/blorp-reader-cuts-stage2')])
pairs = {}
for role, root in (('baseline', BASE), ('candidate', CAND)):
    pairs[role] = {}
    for mode, filename in (('normal', 'blorp-stage2'), ('diagnostic', 'blorp-stage2-diagnostic')):
        actual_filename = filename if role == 'baseline' else filename.replace('blorp-stage2', 'blorp-reader-cuts-stage2')
        path = root / 'bin' / actual_filename
        version = run(f'{role}-stage2-{mode}-version', root, [str(path), '--version'])
        pairs[role][mode] = {'path': str(path), 'sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
                             'version': version, 'actual_compiler_stage': 2}
    pairs[role]['stage1_generator_sha256'] = hashlib.sha256((root / 'bin/blorp').read_bytes()).hexdigest()
(OUT / 'stage2-pair-provenance.json').write_text(json.dumps(pairs, indent=2))
small_hashes = {str(root): hashlib.sha256((root / 'benchmarks/self_compile/small.brp').read_bytes()).hexdigest()
                for root in (BASE, CAND)}
(OUT / 'small-workload-hashes.json').write_text(json.dumps(small_hashes, indent=2))
if len(set(small_hashes.values())) != 1:
    raise SystemExit('Small workloads differ.')
SMALL_INPUT_SHA256 = next(iter(small_hashes.values()))
accepted_small = json.loads((VALID_BASELINE / 'small-workload-hashes.json').read_text())
if SMALL_INPUT_SHA256 != next(iter(accepted_small.values())) or len(set(accepted_small.values())) != 1:
    raise SystemExit('Small input differs from the accepted baseline.')
for program in ('self', 'small'):
    common = ['benchmarks/self_compile_measure', '--program', program,
              '--input-dir', str(frozen_input), '--samples', '3']
    for role, root in (('candidate', CAND),):
        for mode in ('normal', 'diagnostic'):
            recorded = pairs[role][mode]
            if hashlib.sha256(Path(recorded['path']).read_bytes()).hexdigest() != recorded['sha256']:
                raise SystemExit('Retained stage2 compiler changed during measurements.')
        compiler_args = ['--compiler', pairs[role]['normal']['path'],
                         '--diagnostic-compiler', pairs[role]['diagnostic']['path']]
        comparison = (['--baseline', str(VALID_BASELINE / f'resource-baseline-{program}.json'), '--require-identical']
                      if role == 'candidate' else [])
        run(f'resource-{role}-{program}', root,
            common + compiler_args + ['--label', f'combined-reader-cuts-{role}-{program}',
              '--output', str(OUT / f'resource-{role}-{program}.json'),
              '--keep-output', str(OUT / f'resource-{role}-{program}.c')] + comparison, observe_background=True)
    check_budget(program)
for role in ('baseline', 'candidate'):
    for mode in ('normal', 'diagnostic'):
        recorded = pairs[role][mode]
        if hashlib.sha256(Path(recorded['path']).read_bytes()).hexdigest() != recorded['sha256']:
            raise SystemExit('Retained stage2 compiler changed after measurements.')
final_freshness = run('resource-final-candidate-freshness', CAND, ['scripts/compiler-build-status'])
if not final_freshness.startswith('FRESH'):
    raise SystemExit('Final combined generator freshness did not report FRESH.')
postrun_baseline_pins = {}
for program in ('self', 'small'):
    postrun_baseline_pins[program] = {}
    for kind in ('json', 'c'):
        pinned = pins[program][kind]
        actual_hash = hashlib.sha256(Path(pinned['path']).read_bytes()).hexdigest()
        if actual_hash != pinned['sha256']:
            raise SystemExit('Valid wave3 baseline payload changed after measurements.')
        postrun_baseline_pins[program][kind] = {'path': pinned['path'], 'sha256': actual_hash}
    validate_record(BASELINES[program], 'baseline', program)
(OUT / 'post-run-proof.json').write_text(json.dumps({
    'baseline_payload_pins': postrun_baseline_pins,
    'candidate_generator_fresh': True,
    'candidate_generator_sha256': frozen['candidate_binary_sha256'],
    'candidate_patch_sha256': frozen['patch_sha256'],
    'frozen_input_sha256': FROZEN_INPUT_SHA256,
    'small_input_sha256': SMALL_INPUT_SHA256,
    'paired_binaries_rechecked': True,
}, indent=2))
print('Combined candidate-only stage2 self/small comparisons passed against valid wave3 baselines under repository min-of-runs policy.', flush=True)
