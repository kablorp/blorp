#!/usr/bin/env python3
"""Read-only repository audit; seal the retained dictionary candidate as a new baseline."""
from pathlib import Path
from datetime import datetime, timezone
import hashlib
import io
import json
import subprocess
import tarfile

ROOT = Path('<worktree:reader-cuts>').resolve()
OUT = Path(__file__).resolve().parent
OLD = Path('/tmp/blorp-dict-get-reader-resource').resolve()
REV = '2ee201fb5cb74e8a7b4f3d068a143d8d71dd2bad'
EXPECTED = {
    'compare_resources.py': 'b4af2609415b87f1a39e357c6393f395f199c16d9f6b43dfb30e4e3ae6b8b7bd',
    'candidate.json': 'f3e2bd9831420df4f5807eab7fd93bea85b48267cef5c861c8c0f23c0dcbf09d',
    'comparison/COMPARISON_COMPLETE.json': '9ceca5793b737e484b4bec628a5211e3b78f6e7c375525a47c739931bb3d6553',
    'baseline/CAPTURE_COMPLETE.json': '39d6592b85309ce79101be6ce5082c38d0f920f859b58aeab8183ef818381e61',
}


def sha(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(1048576), b''):
            digest.update(chunk)
    return digest.hexdigest()


def digest(data):
    return hashlib.sha256(data).hexdigest()


def git(*args):
    return subprocess.check_output(['git', *args], cwd=ROOT)


def write_json(name, value):
    (OUT / name).write_text(json.dumps(value, indent=2) + '\n')


def require(condition, message):
    if not condition:
        raise SystemExit(message)


def check_old():
    pins = {}
    for name, expected in EXPECTED.items():
        path = OLD / name
        require(sha(path) == expected, 'Prior authority changed: ' + name)
        pins[str(path)] = expected
    for folder, proof_name in [('baseline', 'CAPTURE_COMPLETE.json'), ('comparison', 'COMPARISON_COMPLETE.json')]:
        proof = json.loads((OLD / folder / proof_name).read_text())
        for name, expected in proof['file_pins'].items():
            path = OLD / folder / name
            require(sha(path) == expected, 'Prior sealed payload changed: ' + str(path))
            pins[str(path)] = expected
    capture = json.loads((OLD / 'baseline/CAPTURE_COMPLETE.json').read_text())
    for name, key in [('prepared.json', 'prepared_sha256'), ('capture_baseline.py', 'controller_sha256')]:
        path = OLD / name
        require(sha(path) == capture[key], 'Original capture ingress changed: ' + name)
        pins[str(path)] = capture[key]
    return pins


def current_body(config, prepared):
    require(git('rev-parse', 'HEAD').decode().strip() == REV, 'HEAD differs from retained construction base.')
    paths = prepared['production_paths']
    patch = git('diff', '--binary', REV, '--', *paths)
    require(digest(patch) == config['candidate_state']['production_patch_sha256'], 'Compiler/build/harness patch differs from retained candidate construction.')
    changed = set(git('diff', '--name-only', REV, '--', *paths).decode().splitlines())
    require(changed == {'blorp/src/compiler/stage_09_core/specialize_collection.brp', 'scripts/check-magic-spellings.allowlist'}, 'Current production delta exceeds accepted dictionary cut.')
    require(not git('ls-files', '--others', '--exclude-standard', '--', *paths).strip(), 'Untracked production/build/harness input requires explicit review.')
    entries = [path for path in git('ls-files', '-z', '--', *paths).decode().split('\0') if path]
    generated = config['candidate_state']['generated_inputs']
    for path, expected in generated.items():
        require(sha(ROOT / path) == expected, 'Generated compiler input differs: ' + path)
    entries = sorted(set(entries) | set(generated))
    require(sha(ROOT / 'bin/blorp') == config['candidate_state']['generator_sha256'], 'Installed stage1 differs from retained pair generator.')
    require(sha(ROOT / 'benchmarks/self_compile/small.brp') == prepared['small_sha256'], 'Local small workload changed.')
    require(digest(git('archive', REV, *paths)) == prepared['production_archive_sha256'], 'Original committed production objects changed.')
    data = {path: (ROOT / path).read_bytes() for path in entries}
    inventory = {path: digest(content) for path, content in data.items()}
    return patch, data, inventory


def check_frozen(capture):
    frozen = capture['frozen_input']
    path = Path(frozen['path']).resolve()
    require((path / '.complete').read_text().strip() == REV, 'Frozen input marker differs.')
    archive = git('archive', REV, 'blorp', 'standard_library')
    require(digest(archive) == frozen['archive_sha256'], 'Frozen input archive authority changed.')
    with tarfile.open(fileobj=io.BytesIO(archive)) as bundle:
        files = [item for item in bundle.getmembers() if item.isfile()]
        for item in files:
            require((path / item.name).read_bytes() == bundle.extractfile(item).read(), 'Frozen committed bytes differ: ' + item.name)
    actual = {str(item.relative_to(path)) for item in path.rglob('*') if item.is_file()}
    require(actual - {item.name for item in files} == set(frozen['allowed_extra_files']), 'Frozen input extras differ.')
    entries = [(str(item.relative_to(path)), sha(item)) for item in sorted(path.rglob('*')) if item.is_file()]
    require(digest(json.dumps(entries).encode()) == frozen['tree_sha256'], 'Frozen full-tree digest differs.')
    require(sha(path / 'blorp/src/compiler/stage_01_generated_inputs/embedded_std.brp') == frozen['embedded_std_sha256'], 'Frozen generated stdlib differs.')
    return dict(frozen, path=str(path))


def snapshot_tests_documents():
    paths = ['blorp/test', 'docs', 'benchmarks/results']
    tracked = [path for path in git('ls-files', '-z', '--', *paths).decode().split('\0') if path]
    untracked = [path for path in git('ls-files', '--others', '--exclude-standard', '-z', '--', *paths).decode().split('\0') if path]
    inventory = {path: sha(ROOT / path) for path in sorted(set(tracked + untracked)) if (ROOT / path).is_file()}
    patch = git('diff', '--binary', REV, '--', *paths)
    (OUT / 'test-document-baseline.patch').write_bytes(patch)
    write_json('test-document-file-hashes.json', inventory)
    return {'observed_at_utc': datetime.now(timezone.utc).isoformat(), 'tracked_and_untracked_file_count': len(inventory),
            'inventory_sha256': sha(OUT / 'test-document-file-hashes.json'), 'patch_sha256': digest(patch),
            'scope': 'Observation only, excluded from compiler-body reuse authority. Concurrent new controls may already be present; this does not claim a pre-control or frozen test/doc snapshot.'}


def main():
    require(not (OUT / 'BASELINE_READY.json').exists(), 'Baseline already sealed; preserve rather than overwrite.')
    old_pins = check_old()
    config = json.loads((OLD / 'candidate.json').read_text())
    prepared = json.loads((OLD / 'prepared.json').read_text())
    capture = json.loads((OLD / 'baseline/CAPTURE_COMPLETE.json').read_text())
    comparison = json.loads((OLD / 'comparison/COMPARISON_COMPLETE.json').read_text())
    require(comparison['source_frozen'] and comparison['candidate_stage1_fresh_before_after'] and comparison['all_four_raw_records_and_saved_c_revalidated'], 'Prior comparison construction/source authority incomplete.')
    patch, data, inventory = current_body(config, prepared)
    frozen = check_frozen(capture)
    (OUT / 'production-baseline.patch').write_bytes(patch)
    write_json('production-file-hashes.json', inventory)
    with tarfile.open(OUT / 'production.tar', 'w', format=tarfile.PAX_FORMAT) as bundle:
        for path, content in data.items():
            item = tarfile.TarInfo(path)
            item.size = len(content)
            item.mode = (ROOT / path).stat().st_mode & 0o777
            item.mtime = 0
            bundle.addfile(item, io.BytesIO(content))
    write_json('prior-authority-file-pins.json', old_pins)
    pairs = json.loads((OLD / 'comparison/stage2-pair-provenance.json').read_text())
    for mode, expected in [('normal', '0de63d8215e2600a6c4123fc97b554189f066a64a0918b8e0fe6a2db6d361cd2'), ('diagnostic', '5950a64a26fd267486193e331445e2704f9c02599104b762b908460aa8fd1a62')]:
        require(pairs[mode]['sha256'] == expected and sha(pairs[mode]['path']) == expected and pairs[mode]['actual_compiler_stage'] == 2, 'Retained stage2 pair differs.')
    write_json('retained-stage2-pair-provenance.json', pairs)
    write_json('frozen-input-provenance.json', frozen)
    test_docs = snapshot_tests_documents()
    require(current_body(config, prepared)[2] == inventory, 'Compiler body changed during sealing.')
    require(check_old() == old_pins and check_frozen(capture) == frozen, 'Prior evidence or frozen input changed during sealing.')
    write_json('BASELINE_READY.json', {'status': 'READY; retained pair reuse proven without native build or measurements',
        'revision': REV, 'captured_at_utc': datetime.now(timezone.utc).isoformat(),
        'root': str(ROOT), 'controller_sha256': sha(__file__), 'production_paths': prepared['production_paths'],
        'production_file_count': len(inventory), 'production_archive_sha256': sha(OUT / 'production.tar'),
        'production_inventory_sha256': sha(OUT / 'production-file-hashes.json'),
        'retained_candidate_production_patch_sha256': config['candidate_state']['production_patch_sha256'],
        'retained_boundary_patch_sha256': config['candidate_state']['boundary_patch_sha256'],
        'installed_and_captured_stage1_sha256': config['candidate_state']['generator_sha256'],
        'generated_inputs': config['candidate_state']['generated_inputs'], 'pairs': pairs, 'frozen_input': frozen,
        'small_sha256': prepared['small_sha256'], 'test_document_observation': test_docs,
        'prior_comparison_proof_sha256': EXPECTED['comparison/COMPARISON_COMPLETE.json'],
        'pair_source_authority': 'Original committed production archive plus exact retained accepted dictionary production patch, generated inputs, captured stage1, sealed stage2 C/object/binaries, commands and FRESH-before/after proof. Tests/documents are excluded from compiler-body authority.',
        'raw_harness_caveat': 'Outside-repo explicit pairs report unknown compiler revision/freshness and incidental stage 1; retained construction proves actual stage 2. Original raw fields are preserved.',
        'native_commands_run': False, 'prior_evidence_modified': False,
        'file_pins': {str(path.relative_to(OUT)): sha(path) for path in sorted(OUT.rglob('*')) if path.is_file()}})
    print(json.dumps({'status': 'BASELINE_READY', 'proof': str(OUT / 'BASELINE_READY.json'),
                      'proof_sha256': sha(OUT / 'BASELINE_READY.json'), 'controller_sha256': sha(__file__),
                      'production_files': len(inventory), 'sealed_prior_payloads': len(old_pins)}))


if __name__ == '__main__':
    main()
