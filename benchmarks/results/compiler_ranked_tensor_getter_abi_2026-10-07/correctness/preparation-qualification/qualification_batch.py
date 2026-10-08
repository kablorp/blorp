from pathlib import Path
import json,os,re,subprocess,sys,time
OUT=Path(__file__).resolve().parent
sys.path.insert(0,str(OUT.parent/'retry-v4'))
from freeze_baseline import ROOT,current_source,digest
ENV=dict(os.environ,BLORP_CLI_C_OPTIMIZATION='-O2')
FROZEN=json.loads((OUT/'initial-frozen-provenance.json').read_text())
GENERATED_PREFIX='blorp/src/compiler/stage_01_generated_inputs/'
KNOWN_GENERATED={GENERATED_PREFIX+'compiler_build_info.brp',GENERATED_PREFIX+'embedded_std.brp'}
POST=None
COMMANDS=[]
RESULT={'scope':'Preparation only; suffix renderer and two allowlist rows unchanged','source_initial':FROZEN['source_initial'],'native_complete':False,'gates':[],'failures':[]}
def generated():
 folder=ROOT/GENERATED_PREFIX
 return {str(p.relative_to(ROOT)):digest(p.read_bytes()) for p in sorted(folder.rglob('*')) if p.is_file()}
def stable(state):
 return {'head':state['head'],'tracked':{p:h for p,h in state['tracked_files'].items() if p not in KNOWN_GENERATED},'untracked':{p:h for p,h in state['untracked_files'].items() if p not in KNOWN_GENERATED}}
def save():
 (OUT/'commands.json').write_text(json.dumps(COMMANDS,indent=2)+'\n')
 (OUT/'qualification-results.json').write_text(json.dumps(RESULT,indent=2)+'\n')
def guard():
 state=current_source()
 if stable(state)!=stable(FROZEN['source_initial']): raise SystemExit('Production/test/docs changed beyond known generated make inputs; STOP.')
 if set(generated())!=set(FROZEN['generated_inputs_initial']): raise SystemExit('Generated file set changed; STOP.')
 if POST is not None:
  if state!=POST['source'] or generated()!=POST['generated_inputs'] or digest((ROOT/'bin/blorp').read_bytes())!=POST['compiler_sha256']:
   raise SystemExit('Post-make source/generated/bin drift; STOP.')
 for path,expected in FROZEN['scratch_proposal_files'].items():
  if digest(Path(path).read_bytes())!=expected: raise SystemExit('Frozen scratch proposal changed; STOP.')
 if digest(Path(FROZEN['oracle']['path']).read_bytes())!=FROZEN['oracle']['source_sha256']:
  raise SystemExit('Frozen oracle input changed; STOP.')
 if digest(Path(FROZEN['baseline_C']['path']).read_bytes())!=FROZEN['baseline_C']['sha256']:
  raise SystemExit('Retained baseline C changed; STOP.')
 return state
def run(label,argv,build=False):
 before=guard(); print('STEP '+label,flush=True); start=time.monotonic()
 packet=OUT/(label+'-packet'); log=OUT/(label+'.log')
 command=['scripts/record-validation','--output',str(packet),'--',*argv]
 with log.open('w') as stream:
  process=subprocess.run(command,cwd=ROOT,env=ENV,stdout=stream,stderr=subprocess.STDOUT)
 meta=json.loads((packet/'metadata.json').read_text()); output=(packet/'stdout.log').read_text()+(packet/'stderr.log').read_text()
 after=current_source(); guard()
 item={'label':label,'argv':command,'cwd':str(ROOT),'exit':process.returncode,'seconds':time.monotonic()-start,'log':str(log),'packet':str(packet),'source_changed_during_run':meta['source_changed_during_run'],'stable_production_test_docs_unchanged':stable(before)==stable(after),'full_source_equal_before_after':before==after}
 COMMANDS.append(item); save(); print(label+': exit='+str(process.returncode)+'; log='+str(log),flush=True)
 if process.returncode or stable(before)!=stable(after) or (not build and meta['source_changed_during_run'] is not False):
  RESULT['failures'].append({'gate':label,'exit':process.returncode,'source_changed':meta['source_changed_during_run'],'log':str(log)}); save()
  first=[line for line in output.splitlines() if 'error:' in line or '[FAIL]' in line]
  print(first[0] if first else output[-1000:],flush=True)
  raise SystemExit('Qualification failed or source drift; no automatic fix/retry.')
 return re.sub(r'\x1b\[[0-9;]*m','',output)
try:
 guard()
 run('preparation-build',['make'],build=True)
 post_generated=generated()
 delta={p:{'before':FROZEN['generated_inputs_initial'][p],'after':h} for p,h in post_generated.items() if h!=FROZEN['generated_inputs_initial'][p]}
 if not set(delta)<=KNOWN_GENERATED: raise SystemExit('Unexpected generated input delta from make.')
 if GENERATED_PREFIX+'embedded_std.brp' in delta: raise SystemExit('Generated stdlib changed with unchanged stdlib source; STOP.')
 POST={'source':current_source(),'generated_inputs':post_generated,'compiler_sha256':digest((ROOT/'bin/blorp').read_bytes()),'initial_make_generated_delta':delta}
 (OUT/'post-make-frozen-provenance.json').write_text(json.dumps(POST,indent=2)+'\n')
 RESULT['post_make_provenance']=POST; save()
 status=run('preparation-build-status',['scripts/compiler-build-status'])
 if not status.startswith('FRESH') or 'optimization: cli=-O2 runtime=-O2' not in status: raise SystemExit('Preparation not FRESH O2.')
 RESULT['build_status']=status; save()
 for label,path,expected in [('preparation-owning-emit','blorp/test/test_compiler/test_stage_10_backend/test_core_emit.brp',372),('preparation-context-tensor','blorp/test/test_compiler/test_stage_09_core/test_core_tensor_specialize.brp',36)]:
  output=run(label,['bin/blorp','test','--timeout','180',path])
  passed=[line for line in output.splitlines() if '[PASS]' in line]; failed=[line.split('[FAIL]',1)[1].strip() for line in output.splitlines() if '[FAIL]' in line]
  RESULT['gates'].append({'gate':label,'suite':path,'passed':len(passed),'failed':len(failed),'failures':failed}); save()
  if len(passed)!=expected or failed: raise SystemExit('Owning/context case inventory changed unexpectedly.')
  print(label+': '+str(len(passed))+' PASS /0 FAIL',flush=True)
 c_path=OUT/'ranked-getter-oracle.preparation.c'
 run('preparation-oracle-compile',['bin/blorp','compile','--no-format','--no-embed-runtime','-o',str(c_path),FROZEN['oracle']['path']])
 oracle={'source':FROZEN['oracle'],'C_path':str(c_path),'C_sha256':digest(c_path.read_bytes()),'C_bytes':c_path.stat().st_size,'baseline_C':FROZEN['baseline_C'],'byte_identical':c_path.read_bytes()==Path(FROZEN['baseline_C']['path']).read_bytes()}
 RESULT['oracle']=oracle; save()
 if not oracle['byte_identical']: raise SystemExit('Preparation emitted C differs from retained baseline; STOP.')
 run('preparation-oracle-run',['bin/blorp','run','--no-format',FROZEN['oracle']['path']])
 RESULT['oracle']['run_exit']=0; save()
 final=run('preparation-final-build-status',['scripts/compiler-build-status'])
 if not final.startswith('FRESH') or 'optimization: cli=-O2 runtime=-O2' not in final: raise SystemExit('Final preparation FRESH O2 failed.')
 RESULT.update({'source_final':guard(),'generated_inputs_final':generated(),'compiler_sha256_final':POST['compiler_sha256'],'final_build_status':final,'post_make_source_changed_during_tests':current_source()!=POST['source'],'stable_production_test_docs_changed_during_batch':stable(current_source())!=stable(FROZEN['source_initial']),'native_complete':True,'verdict':'PREPARATION QUALIFICATION PASS; resource/reader deletion not accepted'})
 save(); print('Preparation qualification PASS; all children waited; slot releases on wrapper exit.',flush=True)
except BaseException as error:
 RESULT['stop_reason']=str(error); RESULT['source_final']=current_source(); RESULT['generated_inputs_final']=generated(); save(); raise
