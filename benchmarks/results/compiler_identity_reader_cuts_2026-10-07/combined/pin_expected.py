from pathlib import Path
import hashlib
import json
import os
import subprocess

PREP = Path('/tmp/blorp-identity-wave-combined-resource')
CAND = Path('<worktree:reader-cuts>')
config = json.loads((PREP / 'expected.json.template').read_text())
if (PREP / 'expected.json').exists():
    raise SystemExit('An expectation pin already exists; preserve it and ask root before replacing it.')
if subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=CAND, text=True).strip() != config['revision']:
    raise SystemExit('Parent HEAD differs from the accepted base.')
paths = config['boundary_paths']
changed = subprocess.check_output(['git', 'diff', '--name-only', config['revision'], '--', *paths], cwd=CAND, text=True).splitlines()
if set(changed) != set(paths):
    raise SystemExit('All three cuts are not integrated in the required eight-path boundary.')
source_changes = subprocess.check_output(['git', 'diff', '--name-only', config['revision'], '--', 'blorp/src', 'standard_library/src'], cwd=CAND, text=True).splitlines()
expected_sources = {path for path in paths if path.startswith('blorp/src/')}
if set(source_changes) != expected_sources:
    raise SystemExit('Compiler source changes differ from the four reviewed production paths.')
env = dict(os.environ, BLORP_CLI_C_OPTIMIZATION='-O2')
freshness = subprocess.check_output(['scripts/compiler-build-status'], cwd=CAND, env=env, text=True)
if not freshness.startswith('FRESH'):
    raise SystemExit('Capture only after the combined FRESH O2 build.')
patch = subprocess.check_output(['git', 'diff', '--binary', config['revision'], '--', *paths], cwd=CAND)
config['patch_sha256'] = hashlib.sha256(patch).hexdigest()
config['candidate_binary_sha256'] = hashlib.sha256(Path(config['candidate_binary']).read_bytes()).hexdigest()
config['capture_build_status'] = freshness
config['instruction'] = 'Captured after integration/FRESH O2 build. No native resource GO is implied.'
(PREP / 'expected.json').write_text(json.dumps(config, indent=2))
(PREP / 'expected-boundary.patch').write_bytes(patch)
print(json.dumps(config, indent=2))
