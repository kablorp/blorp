from pathlib import Path
import subprocess, os, hashlib, json, sys
root=Path('<worktree:reader-cuts>')
out=Path('/tmp/blorp-dimension-kind-cut')
env=dict(os.environ, BLORP_CLI_C_OPTIMIZATION='-O2')
rev=subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip()
def sha(p): return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def inventory():
    paths=subprocess.check_output(['git','ls-files','--','blorp/src','standard_library/src','blorp/build','Makefile','benchmarks/self_compile_measure','benchmarks/build_stage2_compiler','scripts'],cwd=root,text=True).splitlines()
    return {p:sha(root/p) for p in paths if (root/p).is_file()}
initial=inventory()
(out/'baseline-source.json').write_text(json.dumps({'revision':rev,'paths':initial},indent=2)+'\n')
commands=[]
def run(name,cmd):
    if inventory()!=initial: raise RuntimeError('Production changed before '+name)
    print(name,flush=True)
    with (out/(name+'.log')).open('w') as log:
        result=subprocess.run(cmd,cwd=root,env=env,stdout=log,stderr=subprocess.STDOUT)
    commands.append({'name':name,'command':cmd,'exit':result.returncode,'log_sha256':sha(out/(name+'.log'))})
    (out/'baseline-commands.json').write_text(json.dumps(commands,indent=2)+'\n')
    if result.returncode: raise RuntimeError(name+' failed')
    if inventory()!=initial: raise RuntimeError('Production changed during '+name)
run('baseline-make',['make'])
run('baseline-fresh',['scripts/compiler-build-status'])
if 'FRESH' not in (out/'baseline-fresh.log').read_text(): raise RuntimeError('Baseline not FRESH')
run('baseline-stage1-version',['bin/blorp','--version'])
run('baseline-stage2-build',['benchmarks/build_stage2_compiler','--diagnostic-output',str(out/'baseline-diagnostic'),str(out/'baseline-normal')])
run('baseline-normal-version',[str(out/'baseline-normal'),'--version'])
run('baseline-diagnostic-version',[str(out/'baseline-diagnostic'),'--version'])
pair={p.name:sha(p) for p in [out/'baseline-normal',out/'baseline-diagnostic',root/'bin/blorp']}
(out/'baseline-pair.json').write_text(json.dumps({'revision':rev,'stage':2,'binaries':pair,'source':initial},indent=2)+'\n')
print('BASELINE PAIR SEALED. Production may now change.',flush=True)
for program in ['self','small']:
    run('baseline-'+program,['benchmarks/self_compile_measure','--compiler',str(out/'baseline-normal'),'--diagnostic-compiler',str(out/'baseline-diagnostic'),'--skip-build-check','--input-rev',rev,'--program',program,'--samples','3','--label','dimension-kind-baseline-stage2','--output',str(out/('baseline-'+program+'.json')),'--keep-output',str(out/('baseline-'+program+'.c'))])
    for name,digest in pair.items():
        p=root/'bin/blorp' if name=='blorp' else out/name
        if sha(p)!=digest: raise RuntimeError('Compiler pair changed: '+name)
print('BASELINE COMPLETE',flush=True)
