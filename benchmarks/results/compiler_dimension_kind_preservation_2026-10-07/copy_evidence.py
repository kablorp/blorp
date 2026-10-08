from pathlib import Path
import json,hashlib,gzip
src=Path('/tmp/blorp-dimension-kind-cut')
root=Path('<worktree:reader-cuts>')
dst=root/'benchmarks/results/compiler_dimension_kind_preservation_2026-10-07'
sha=lambda b:hashlib.sha256(b).hexdigest()
entries=[]; omitted=[]
chosen=[p for p in src.glob('baseline-*') if p.is_file()]+[p for p in src.glob('candidate-*') if p.is_file()]
chosen += [src/name for name in ['baseline.py','candidate.py','baseline-protected.json','comparison.json','frozen-input.json','seal_frozen_input.py','workload-pins.json','manual-reader-census.json','RESOURCE_REVIEW.md','copy_evidence.py']]
for folder in ['fail-before','final-validation']:
 chosen += [p for p in (src/folder).rglob('*') if p.is_file() and '__pycache__' not in p.parts]
impl=Path('/tmp/blorp-dimension-kind-reader-implementation')
chosen += [impl/name for name in ['production.patch','candidate.patch','tests-only.patch','IMPLEMENTATION_READY.json','TESTS_ONLY_READY.json','baseline-test_dim_solver.brp'] if (impl/name).is_file()]
for p in sorted(set(chosen)):
 rel=p.relative_to(src) if p.is_relative_to(src) else Path('implementation')/p.name
 b=p.read_bytes(); original={'source':str(p),'path':str(rel),'sha256':sha(b),'bytes':len(b)}
 if p.name in ['baseline-normal','baseline-diagnostic','candidate-normal','candidate-diagnostic'] or (p.suffix=='.c' and 'small' not in p.name):
  omitted.append({**original,'reason':'Large generated C/compiler product remains in scratch; hashes and construction identity retained.'});continue
 compress=len(b)>131072 and p.name not in ['comparison.json','RESOURCE_REVIEW.md','TEST_RUNNER_REPORT.md']
 payload=gzip.compress(b,mtime=0) if compress else b
 stored=Path(str(rel)+'.gz') if compress else rel
 target=dst/stored;target.parent.mkdir(parents=True,exist_ok=True)
 assert not target.exists(), 'Would overwrite delivery payload'
 target.write_bytes(payload)
 assert (gzip.decompress(target.read_bytes()) if compress else target.read_bytes())==b
 entries.append({**original,'stored_path':str(stored),'stored_sha256':sha(payload),'stored_bytes':len(payload),'encoding':'gzip' if compress else 'identity'})
dst.mkdir(parents=True,exist_ok=True)
(dst/'COPY_MANIFEST.json').write_text(json.dumps({'payloads':entries,'omitted_products':omitted},indent=2)+'\n')
(dst/'.gitattributes').write_text('*.log -whitespace\n*.patch -whitespace\n*.json -whitespace\n*.brp -whitespace\n')
(dst/'README.md').write_text('''# Dimension kind evidence

Raw records retain their original bytes and paths. `COPY_MANIFEST.json` records
original and stored hashes; `.gz` payloads restore exactly with `gzip -dc`.
Large generated C and compiler binaries remain in scratch with hashes retained
in construction/comparison records and the omission manifest. Small C is retained.

- `comparison.json` and `RESOURCE_REVIEW.md`: independently accepted resource proof.
- `baseline-commands.json`, `candidate-commands.json`: exact paired-stage construction
  and measurement commands. Actual stage2 provenance qualifies incidental raw
  `compiler_stage=1` for explicitly supplied retained binaries.
- `frozen-input.json.gz`: exact revision plus regenerated embedded std, independently
  checked after baseline and pinned throughout candidate phases.
- `fail-before/TEST_RUNNER_REPORT.md`: seven intended baseline failures.
- `final-validation/TEST_RUNNER_REPORT.md`: passing final gates and complete source guards.
- `implementation/`: exact reviewed source/test patches and construction pins.

Baseline and candidate use frozen revision
`8fe717e28d461088258f7744db77f2d9c8d02a0f`. Three normal samples per workload,
paired diagnostic allocations, whole C identity and exact 0.5% integer ceilings
were checked. Background work is permitted; no speed or quiet-window claim is made.
''')
print(json.dumps({'payloads':len(entries),'omitted_products':len(omitted),'stored_bytes':sum(e['stored_bytes'] for e in entries),'manifest_sha256':sha((dst/'COPY_MANIFEST.json').read_bytes())}))
