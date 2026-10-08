import hashlib, json, os, pathlib, shutil, subprocess, sys, time
root=pathlib.Path('<worktree:reader-cuts>')
out=pathlib.Path('/tmp/blorp-dimension-kind-cut/fail-before')
suite='blorp/test/test_compiler/test_stage_06_typecheck/test_type_system/test_dim_solver.brp'
expected_head='8fe717e28d461088258f7744db77f2d9c8d02a0f'
expected_test='746b60e7407aaee75ffa327be6fa21f9112e722b5979b39256e6ebcaa1cd5fb2'
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def snap():
 paths=subprocess.check_output(['git','ls-files','-z','blorp/src','standard_library/src'],cwd=root).decode().split('\0')
 pins={p:sha(root/p) for p in paths if p and (root/p).is_file()}
 return {'head':subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip(),'production_files':pins,'production_sha256':hashlib.sha256(json.dumps(pins,sort_keys=True,separators=(',',':')).encode()).hexdigest(),'test_sha256':sha(root/suite),'binary_sha256':sha(root/'bin/blorp')}
def save(name,value): (out/name).write_text(json.dumps(value,indent=2,sort_keys=True)+'\n')
before=snap();save('before.json',before)
assert before['head']==expected_head and before['test_sha256']==expected_test, 'unexpected HEAD/test fingerprint'
prod_diff=subprocess.check_output(['git','diff','--','blorp/src','standard_library/src'],cwd=root)
(out/'production-before.patch').write_bytes(prod_diff)
assert not prod_diff, 'production differs before fail-before'
shutil.copyfile(root/suite,out/'test_dim_solver.frozen.brp')
status=subprocess.run(['scripts/compiler-build-status'],cwd=root,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
(out/'build-status-before.log').write_text(status.stdout)
assert status.returncode==0 and 'FRESH' in status.stdout and '-O2' in status.stdout, 'baseline is not verified FRESH O2; no native started'
command=['python3','/tmp/blorp-identity-wave-7ab679600/native_slot_serial.py','--cwd',str(root),'--wait-seconds','600','--','bin/blorp','test','--timeout','180',suite]
save('command.json',{'argv':command,'cwd':str(root),'started_utc':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime())})
print('Verified FRESH O2 and exact test/production pins; starting one fail-before suite under the native lock.',flush=True)
with (out/'raw.log').open('w') as log:
 result=subprocess.run(command,cwd=root,stdout=log,stderr=subprocess.STDOUT)
print('Suite finished; exit='+str(result.returncode)+'. Checking final fingerprints.',flush=True)
after=snap();save('after.json',after)
status2=subprocess.run(['scripts/compiler-build-status'],cwd=root,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
(out/'build-status-after.log').write_text(status2.stdout)
prod_diff2=subprocess.check_output(['git','diff','--','blorp/src','standard_library/src'],cwd=root)
(out/'production-after.patch').write_bytes(prod_diff2)
proof={'suite_exit':result.returncode,'source_changed':before!=after,'production_diff_empty_before':not prod_diff,'production_diff_empty_after':not prod_diff2,'fresh_before':status.returncode==0 and 'FRESH' in status.stdout,'fresh_after':status2.returncode==0 and 'FRESH' in status2.stdout,'native_slot_released':True,'completed_utc':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime())}
save('result.json',proof)
assert before==after and not prod_diff2 and proof['fresh_after'], 'baseline inputs or freshness changed'
print(json.dumps(proof,sort_keys=True),flush=True)
sys.exit(0)
