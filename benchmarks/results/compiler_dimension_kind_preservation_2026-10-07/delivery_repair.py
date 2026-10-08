from pathlib import Path
import json,hashlib
src=Path('/tmp/blorp-dimension-kind-cut')
dst=Path('<worktree:reader-cuts>/benchmarks/results/compiler_dimension_kind_preservation_2026-10-07')
sha=lambda b:hashlib.sha256(b).hexdigest()
p=dst/'COPY_MANIFEST.json';x=json.loads(p.read_text())
entry=next(e for e in x['payloads'] if e['path']=='candidate-stage2.o')
assert sha((dst/entry['stored_path']).read_bytes())==entry['stored_sha256']
(src/'COPY_MANIFEST.before-object-omission.json').write_bytes(p.read_bytes())
(dst/entry['stored_path']).unlink()
x['payloads'].remove(entry)
x['omitted_products'].append({k:v for k,v in entry.items() if k in ['source','path','sha256','bytes']}|{'reason':'Compiler body object remains in scratch; hash retained by stage2 builder. Omitted after initial copy.'})
b=Path(__file__).read_bytes();(dst/'delivery_repair.py').write_bytes(b)
x['payloads'].append({'source':str(Path(__file__)),'path':'delivery_repair.py','sha256':sha(b),'bytes':len(b),'stored_path':'delivery_repair.py','stored_sha256':sha(b),'stored_bytes':len(b),'encoding':'identity'})
p.write_text(json.dumps(x,indent=2)+'\n')
print({'payloads':len(x['payloads']),'stored_bytes':sum(e['stored_bytes'] for e in x['payloads']),'manifest_sha256':sha(p.read_bytes())})
