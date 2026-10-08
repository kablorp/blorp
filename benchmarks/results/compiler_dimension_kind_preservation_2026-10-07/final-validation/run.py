#!/usr/bin/env python3
"""Authorized final correctness only; launch under native_slot_serial.py."""
import hashlib, json, os, pathlib, re, shutil, subprocess, sys, time
ROOT=pathlib.Path('<worktree:reader-cuts>')
OUT=pathlib.Path(__file__).resolve().parent
BASE='8fe717e28d461088258f7744db77f2d9c8d02a0f'
SOURCE='blorp/src/compiler/stage_06_typecheck/type_system/dim_solver.brp'
SUITE='blorp/test/test_compiler/test_stage_06_typecheck/test_type_system/test_dim_solver.brp'
SOURCE_SHA='9e152a0c7631de1756f484332b67b1137a1c795ae63de8d3b2ec07ae73a334dd'
TEST_SHA='746b60e7407aaee75ffa327be6fa21f9112e722b5979b39256e6ebcaa1cd5fb2'
ENV=dict(os.environ,BLORP_CLI_C_OPTIMIZATION='-O2')
COMMANDS=[]
RESULTS=[]
def sha(p):
    if p.is_symlink(): return 'symlink:'+hashlib.sha256(os.readlink(p).encode()).hexdigest()
    return hashlib.sha256(p.read_bytes()).hexdigest() if p.is_file() else 'absent'
def save(name,data): (OUT/name).write_text(json.dumps(data,indent=2,sort_keys=True)+'\n')
def git(args): return subprocess.check_output(['git',*args],cwd=ROOT)
def snapshot():
    paths=git(['ls-files','-z']).decode().split('\0')+git(['ls-files','--others','--exclude-standard','-z']).decode().split('\0')
    files={p:sha(ROOT/p) for p in sorted(set(paths)) if p}
    build=ROOT/'blorp/build/_build/blorp-cli'
    generated={str(p.relative_to(ROOT)):sha(p) for p in sorted(build.glob('*.sha256'))}
    generated.update({str(p.relative_to(ROOT)):sha(p) for p in sorted((ROOT/'blorp/src/compiler/stage_01_generated_inputs').glob('*')) if p.is_file()})
    return {'head':git(['rev-parse','HEAD']).decode().strip(),'files':files,'worktree_sha256':hashlib.sha256(json.dumps(files,sort_keys=True,separators=(',',':')).encode()).hexdigest(),'generated_build_stamps':generated,'binary_sha256':sha(ROOT/'bin/blorp'),'build_binary_sha256':sha(build/'blorp')}
def run(name,argv):
    start=time.time(); print('START '+name,flush=True)
    COMMANDS.append({'name':name,'argv':argv,'cwd':str(ROOT),'started_utc':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime(start)),'environment':{'BLORP_CLI_C_OPTIMIZATION':'-O2'}})
    save('commands.json',COMMANDS)
    with (OUT/(name+'.log')).open('w') as log:
        result=subprocess.run(argv,cwd=ROOT,env=ENV,stdout=log,stderr=subprocess.STDOUT)
    text=(OUT/(name+'.log')).read_text(errors='replace')
    matches=re.findall(r'BLORP_GATE_RESULT gate=([^ ]+) status=(PASS|FAIL) passed=(\d+) failed=(\d+) tests=(\d+)',text)
    summary={'name':name,'exit':result.returncode,'seconds':round(time.time()-start,3),'log':name+'.log'}
    if matches:
        gate,status,passed,failed,tests=matches[-1]
        summary.update(gate=gate,status=status,passed=int(passed),failed=int(failed),tests=int(tests))
    if name=='owning':
        summary.update(passed=len(re.findall(r'\[PASS\]',text)),failed=len(re.findall(r'\[FAIL\]',text)))
        summary['tests']=summary['passed']+summary['failed']
    RESULTS.append(summary);save('results.json',RESULTS)
    print('END '+name+' '+json.dumps(summary,sort_keys=True),flush=True)
    if result.returncode: raise RuntimeError('first failed gate: '+name+'; raw '+name+'.log')
    return text,summary

def fresh(name):
    text,_=run(name,['scripts/compiler-build-status'])
    if 'FRESH:' not in text or 'cli=-O2 runtime=-O2' not in text: raise RuntimeError('not FRESH CLI/runtime O2; no further gate')
def guard(name,allow_types_make=False):
    global ACTIVE_BUILD
    current=snapshot()
    source_changed=current['head']!=BEFORE['head'] or current['files']!=BEFORE['files']
    build_state={key:current[key] for key in ('generated_build_stamps','binary_sha256','build_binary_sha256')}
    build_changed=build_state!=ACTIVE_BUILD
    save(name+'-guard.json',{'source_changed':source_changed,'build_changed':build_changed,'build_change_allowed':allow_types_make,'head':current['head'],'worktree_sha256':current['worktree_sha256'],**build_state})
    if source_changed: raise RuntimeError('protected source/test/docs/worktree drift after '+name)
    if build_changed and not allow_types_make: raise RuntimeError('unexpected generated/build-stamp/compiler drift after '+name)
    if allow_types_make: ACTIVE_BUILD=build_state

BEFORE=None
ACTIVE_BUILD=None
failure=None
try:
    BEFORE=snapshot();save('before.json',BEFORE)
    ACTIVE_BUILD={key:BEFORE[key] for key in ('generated_build_stamps','binary_sha256','build_binary_sha256')}
    if BEFORE['head']!=BASE or sha(ROOT/SOURCE)!=SOURCE_SHA or sha(ROOT/SUITE)!=TEST_SHA: raise RuntimeError('unexpected frozen source/test/HEAD')
    shutil.copyfile(ROOT/SOURCE,OUT/'dim_solver.frozen.brp')
    shutil.copyfile(ROOT/SUITE,OUT/'test_dim_solver.frozen.brp')
    (OUT/'validated-source.patch').write_bytes(git(['diff','--binary','HEAD','--',SOURCE,SUITE]))
    fresh('fresh-before')
    plan,_=run('changed-plan',['scripts/compiler-check','--changed','--base',BASE,'--plan','--json'])
    selection=json.loads(plan)['selection']
    if selection['sources']!=[SOURCE] or selection['suites']!=[SUITE] or selection['checks']: raise RuntimeError('unexpected changed-plan owners/checks')
    plan,_=run('types-plan',['scripts/compiler-check','--stage','types','--plan','--json'])
    selection=json.loads(plan)['selection']
    if len(selection['suites'])!=31 or selection['checks']!=['leak']: raise RuntimeError('types-stage selection differs; reassess scope')
    guard('plans')
    _,count=run('owning',['bin/blorp','test','--timeout','180',SUITE])
    if count['passed']!=26 or count['failed']!=0: raise RuntimeError('unexpected owning count')
    guard('owning')
    run('types',['scripts/compiler-check','--stage','types']);fresh('fresh-after-types');guard('types',allow_types_make=True)
    save('post-types-build.json',ACTIVE_BUILD)
    run('compiler-blorp',['scripts/test','--no-build','--serial','--log-dir',str(OUT/'broad-logs'),'compiler-blorp']);guard('compiler-blorp')
    run('magic-strict',['python3','scripts/check-magic-spellings','--strict']);guard('magic-strict')
    run('identity',['python3','scripts/compiler-identity-census','--check','--json']);guard('identity')
    run('hygiene',['make','hygiene-check']);guard('hygiene')
    run('diff-check',['git','diff','--check']);guard('diff-check')
    fresh('fresh-after');guard('final')
except Exception as e:
    failure=str(e);print('STOP '+failure,flush=True)
finally:
    after=snapshot();save('after.json',after)
    save('FINAL_RESULT.json',{'status':'PASS' if failure is None else 'STOP','first_failure':failure,'source_changed':BEFORE is None or BEFORE['head']!=after['head'] or BEFORE['files']!=after['files'],'build_changed_during_types_make':BEFORE is not None and any(BEFORE[key]!=after[key] for key in ('generated_build_stamps','binary_sha256','build_binary_sha256')),'head':after['head'],'binary_sha256':after['binary_sha256'],'gate_results':RESULTS,'completed_utc':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()),'children_waited':True,'slot_release':'wrapper releases after this process exits'})
    print('Final '+('PASS' if failure is None else 'STOP')+'; all foreground subprocesses waited.',flush=True)
sys.exit(0 if failure is None else 1)
