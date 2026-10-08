from pathlib import Path
import subprocess, hashlib,json,tarfile,io
root=Path('<worktree:reader-cuts>'); out=Path('/tmp/blorp-dimension-kind-cut')
sha=lambda b:hashlib.sha256(b).hexdigest()
record=json.loads((out/'baseline-self.json').read_text()); rev=record['input_rev']
folder=Path(record['input_dir']).resolve()
assert folder==Path(json.loads((out/'baseline-small.json').read_text())['input_dir']).resolve()
archive=subprocess.check_output(['git','archive',rev,'blorp','standard_library'],cwd=root)
with tarfile.open(fileobj=io.BytesIO(archive)) as bundle:
 expected={member.name:sha(bundle.extractfile(member).read()) for member in bundle.getmembers() if member.isfile()}
generator=root/'blorp/build/_build/build-tools/generate-build-sources'
embedded=subprocess.check_output([str(generator),'embedded-std',str(folder/'standard_library/src')],cwd=root)
expected['blorp/src/compiler/stage_01_generated_inputs/embedded_std.brp']=sha(embedded)
expected['.complete']=sha((rev+'\n').encode())
actual={str(p.relative_to(folder)):sha(p.read_bytes()) for p in folder.rglob('*') if p.is_file()}
assert expected==actual, 'Frozen input differs from exact git archive/generated embedded std'
proof={'revision':rev,'input_dir':str(folder),'paths':expected,'embedded_generator_sha256':sha(generator.read_bytes()),'verification':'After baseline, independently checked all archived bytes against exact revision plus regenerated embedded std. Pin before candidate.'}
(out/'frozen-input.json').write_text(json.dumps(proof,indent=2)+'\n')
print('Frozen input matches exact revision:',len(expected),'files')
