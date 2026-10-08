from pathlib import Path
import json,os,re,subprocess,sys,time
OUT=Path(__file__).resolve().parent
sys.path.insert(0,str(OUT.parent/'retry-v3'))
from freeze_baseline import ROOT,BIN,current_source,digest
FROZEN=json.loads((OUT/'probe-frozen-provenance.json').read_text())
ENV=dict(os.environ,BLORP_CLI_C_OPTIMIZATION='-O2')
COMMANDS=[]
RESULT={'purpose':FROZEN['purpose'],'complete':False,'source_before':FROZEN['source'],'compiler_sha256':BIN,'native_cap_seconds':180}
def save():
 (OUT/'commands.json').write_text(json.dumps(COMMANDS,indent=2)+'\n')
 (OUT/'probe-results.json').write_text(json.dumps(RESULT,indent=2)+'\n')
def guard():
 state=current_source()
 if state!=FROZEN['source'] or digest((ROOT/'bin/blorp').read_bytes())!=BIN:
  raise SystemExit('Frozen repo/test/docs/compiler drift; STOP.')
 for path,expected in FROZEN['scratch_proposal_files'].items():
  if digest(Path(path).read_bytes())!=expected: raise SystemExit('Scratch proposal drift; STOP.')
 if digest(Path(FROZEN['probe']['path']).read_bytes())!=FROZEN['probe']['sha256']:
  raise SystemExit('Scratch probe drift; STOP.')
 link=Path(FROZEN['probe_import_src_symlink']['path'])
 if not link.is_symlink() or str(link.readlink())!=FROZEN['probe_import_src_symlink']['link_target'] or str(link.resolve())!=FROZEN['probe_import_src_symlink']['resolved']:
  raise SystemExit('Probe source import symlink changed; STOP.')
 for path,expected in FROZEN['resolved_blrop_source_hashes'].items():
  if digest((ROOT/path).read_bytes())!=expected: raise SystemExit('Resolved compiler source changed; STOP.')
 return state
def run(label,argv):
 before=guard(); print('STEP '+label,flush=True)
 start=time.monotonic(); packet=OUT/(label+'-packet'); log=OUT/(label+'.log')
 command=['scripts/record-validation','--timeout','180','--output',str(packet),'--',*argv]
 with log.open('w') as stream:
  process=subprocess.run(command,cwd=ROOT,env=ENV,stdout=stream,stderr=subprocess.STDOUT)
 meta=json.loads((packet/'metadata.json').read_text())
 output=(packet/'stdout.log').read_text()+(packet/'stderr.log').read_text()
 after=current_source()
 COMMANDS.append({'label':label,'argv':command,'cwd':str(ROOT),'exit':process.returncode,'seconds':time.monotonic()-start,'packet':str(packet),'log':str(log),'source_changed_during_run':meta['source_changed_during_run'],'source_equal_before_after':before==after,'compiler_sha256_after':digest((ROOT/'bin/blorp').read_bytes())}); save()
 print(label+': exit='+str(process.returncode)+'; full stdout retained '+str(packet/'stdout.log'),flush=True)
 if process.returncode or meta['source_changed_during_run'] is not False or before!=after:
  diagnostic=[line for line in output.splitlines() if 'error:' in line or '[FAIL]' in line]
  print((diagnostic[0] if diagnostic else output[:1000]),flush=True)
  raise SystemExit('Probe setup/run failure or drift; STOP without fix/retry.')
 guard(); return output
try:
 status=run('probe-build-status',['scripts/compiler-build-status'])
 if not status.startswith('FRESH') or 'optimization: cli=-O2 runtime=-O2' not in status: raise SystemExit('Not FRESH O2; diagnostic held.')
 RESULT['build_status']=status; save()
 output=run('probe-run',['bin/blorp','run','--no-format',FROZEN['probe']['path']])
 RESULT['diagnostic_output_sha256']=digest((OUT/'probe-run-packet/stdout.log').read_bytes())
 RESULT['diagnostic_output_bytes']=(OUT/'probe-run-packet/stdout.log').stat().st_size
 RESULT['probe_markers']=[line for line in output.splitlines() if line.startswith('PROBE')]
 RESULT['probe_sha256_after']=digest(Path(FROZEN['probe']['path']).read_bytes()); save()
 final=run('probe-final-build-status',['scripts/compiler-build-status'])
 if not final.startswith('FRESH') or 'optimization: cli=-O2 runtime=-O2' not in final: raise SystemExit('Final FRESH O2 check failed.')
 RESULT.update({'final_build_status':final,'source_after':guard(),'source_changed_during_batch':current_source()!=FROZEN['source'],'complete':True,'verdict':'DIAGNOSTIC RUN COMPLETE, not output-control acceptance'})
 save(); print('Diagnostic run complete; every child waited; wrapper releases slot on exit.',flush=True)
except BaseException as error:
 RESULT['stop_reason']=str(error); RESULT['source_after']=current_source(); RESULT['source_changed_during_batch']=RESULT['source_after']!=FROZEN['source']; save(); raise
