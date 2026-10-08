from pathlib import Path
import subprocess, os, hashlib, json, re
root=Path('<worktree:reader-cuts>')
out=Path('/tmp/blorp-dimension-kind-cut')
env=dict(os.environ, BLORP_CLI_C_OPTIMIZATION='-O2')
rev=subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip()
def sha(p): return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def inventory():
    paths=subprocess.check_output(['git','ls-files','--','blorp/src','standard_library/src','blorp/build','Makefile','benchmarks/self_compile_measure','benchmarks/build_stage2_compiler','scripts'],cwd=root,text=True).splitlines()
    return {p:sha(root/p) for p in paths if (root/p).is_file()}
initial=inventory()
baseline=json.loads((out/'baseline-source.json').read_text())
if rev!=baseline['revision']: raise RuntimeError('HEAD moved')
if set(initial)!=set(baseline['paths']): raise RuntimeError('Tracked production path set changed')
changed={p for p in initial if initial[p]!=baseline['paths'].get(p)}
if changed!={'blorp/src/compiler/stage_06_typecheck/type_system/dim_solver.brp'}: raise RuntimeError('Unexpected production delta '+str(changed))
protected=json.loads((out/'baseline-protected.json').read_text())
for name in ['frozen-input.json','seal_frozen_input.py']:
    protected[name]=sha(out/name)
frozen=json.loads((out/'frozen-input.json').read_text())
frozen_dir=Path(frozen['input_dir']).resolve()
test_path=root/'blorp/test/test_compiler/test_stage_06_typecheck/test_type_system/test_dim_solver.brp'
test_pin=sha(test_path)
construction={}
def verify():
    if inventory()!=initial: raise RuntimeError('Candidate production changed')
    if subprocess.check_output(['git','ls-files','--others','--exclude-standard','--','blorp/src','standard_library/src','blorp/build','scripts'],cwd=root).strip(): raise RuntimeError('Untracked production input')
    if sha(test_path)!=test_pin: raise RuntimeError('Candidate tests changed')
    actual_frozen={str(p.relative_to(frozen_dir)):sha(p) for p in frozen_dir.rglob('*') if p.is_file()}
    if actual_frozen!=frozen['paths']: raise RuntimeError('Frozen input bytes/path set changed')
    for p,digest in construction.items():
        if sha(Path(p))!=digest: raise RuntimeError('Construction product changed '+p)
    for p,digest in protected.items():
        if sha(out/p)!=digest: raise RuntimeError('Protected baseline changed '+p)
    if sha(root/'benchmarks/self_compile/small.brp')!=json.loads((out/'workload-pins.json').read_text())['small']: raise RuntimeError('Small workload changed')
(out/'candidate-source.json').write_text(json.dumps({'revision':rev,'paths':initial},indent=2)+'\n')
commands=[]
def run(name,cmd):
    verify()
    print(name,flush=True)
    with (out/(name+'.log')).open('w') as log:
        result=subprocess.run(cmd,cwd=root,env=env,stdout=log,stderr=subprocess.STDOUT)
    commands.append({'name':name,'command':cmd,'exit':result.returncode,'log_sha256':sha(out/(name+'.log'))})
    (out/'candidate-commands.json').write_text(json.dumps(commands,indent=2)+'\n')
    if result.returncode: raise RuntimeError(name+' failed')
    verify()
run('candidate-make',['make'])
run('candidate-fresh',['scripts/compiler-build-status'])
if 'FRESH' not in (out/'candidate-fresh.log').read_text(): raise RuntimeError('Candidate not FRESH')
construction[str(root/'bin/blorp')]=sha(root/'bin/blorp')
run('candidate-stage1-version',['bin/blorp','--version'])
run('candidate-stage2-build',['benchmarks/build_stage2_compiler','--generated-c',str(out/'candidate-stage2.c'),'--diagnostic-output',str(out/'candidate-diagnostic'),str(out/'candidate-normal')])
builder_log=(out/'candidate-stage2-build.log').read_text()
for name,label in [('candidate-normal','stage2 binary sha256'),('candidate-diagnostic','stage2 diagnostic sha256'),('candidate-stage2.c','stage2 generated C sha256')]:
    matches=re.findall(r'^'+re.escape(label)+r'\s*:\s*([0-9a-f]{64})$',builder_log,re.M)
    if len(matches)!=1 or sha(out/name)!=matches[0]: raise RuntimeError('Builder correspondence missing '+name)
    construction[str(out/name)]=matches[0]
verify()
run('candidate-normal-version',[str(out/'candidate-normal'),'--version'])
run('candidate-diagnostic-version',[str(out/'candidate-diagnostic'),'--version'])
pair={p.name:sha(p) for p in [out/'candidate-normal',out/'candidate-diagnostic',root/'bin/blorp']}
(out/'candidate-pair.json').write_text(json.dumps({'revision':rev,'stage':2,'binaries':pair,'construction':construction,'test_sha256':test_pin},indent=2)+'\n')
for program in ['self','small']:
    run('candidate-'+program,['benchmarks/self_compile_measure','--compiler',str(out/'candidate-normal'),'--diagnostic-compiler',str(out/'candidate-diagnostic'),'--skip-build-check','--input-rev',rev,'--program',program,'--samples','3','--label','dimension-kind-candidate-stage2','--baseline',str(out/('baseline-'+program+'.json')),'--require-identical','--output',str(out/('candidate-'+program+'.json')),'--keep-output',str(out/('candidate-'+program+'.c'))])
    for name,digest in pair.items():
        p=root/'bin/blorp' if name=='blorp' else out/name
        if sha(p)!=digest: raise RuntimeError('Candidate compiler pair changed '+name)
    protected['candidate-'+program+'.json']=sha(out/('candidate-'+program+'.json'))
    protected['candidate-'+program+'.c']=sha(out/('candidate-'+program+'.c'))
verify()
comparison={}
for program in ['self','small']:
    b=json.loads((out/('baseline-'+program+'.json')).read_text())
    c=json.loads((out/('candidate-'+program+'.json')).read_text())
    if Path(b['input_dir']).resolve()!=frozen_dir or Path(c['input_dir']).resolve()!=frozen_dir: raise RuntimeError('Frozen directory differs')
    if c['compiler_sha256']!=pair['candidate-normal'] or c['diagnostic_compiler_sha256']!=pair['candidate-diagnostic']: raise RuntimeError('Measurement compiler differs from construction')
    for key in ['host','machine','input_rev','program','samples','output_sha256','output_bytes']:
        if b[key]!=c[key]: raise RuntimeError('Different '+key+' for '+program)
    for mode in ['toolchain','diagnostic_toolchain']:
        if b[mode]!=c[mode]: raise RuntimeError('Different toolchain '+mode)
    if sha(out/('baseline-'+program+'.c'))!=sha(out/('candidate-'+program+'.c')): raise RuntimeError('Whole C differs')
    metrics={}
    for metric in ['allocations','instructions']:
        before=b['total_allocations'] if metric=='allocations' else b['instructions_retired']['min']
        after=c['total_allocations'] if metric=='allocations' else c['instructions_retired']['min']
        passed=after*200<=before*201
        metrics[metric]={'baseline':before,'candidate':after,'change_percent':100*(after-before)/before,'ceiling_pass':passed}
        if not passed: raise RuntimeError('0.5% ceiling exceeded '+program+' '+metric)
    comparison[program]={'metrics':metrics,'c_sha256':c['output_sha256'],'c_bytes':c['output_bytes']}
verify()
(out/'comparison.json').write_text(json.dumps({'accepted':True,'actual_stage':2,'raw_stage_field_note':'Explicit retained compiler arguments leave harness compiler_stage=1; builder and pair provenance establish actual stage2. Raw records unmodified.','revision':rev,'protected_artifacts':protected,'workloads':comparison},indent=2)+'\n')
print(json.dumps(comparison),flush=True)
print('CANDIDATE COMPARISON COMPLETE',flush=True)
