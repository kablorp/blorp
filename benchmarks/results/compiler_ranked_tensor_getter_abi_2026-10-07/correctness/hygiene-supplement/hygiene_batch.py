from pathlib import Path
import json,os,subprocess,sys,datetime
OUT=Path(__file__).resolve().parent
sys.path.insert(0,'/tmp/blorp-ranked-tensor-abi-validation/retry-v4')
from freeze_baseline import ROOT,current_source,digest
initial=json.loads((OUT/'initial-provenance.json').read_text())
final=OUT.parent/'final-correctness'
def guard():
 assert current_source()==initial['source'],'source drift'
 assert digest((ROOT/'bin/blorp').read_bytes())==initial['compiler_sha256'],'binary drift'
 assert digest((final/'TEST_RUNNER_REPORT.md').read_bytes())==initial['accepted_report_sha256'],'accepted report changed'
 assert digest((final/'PRESERVATION_MANIFEST.json').read_bytes())==initial['accepted_manifest_sha256'],'accepted manifest changed'
guard()
cmd=['scripts/record-validation','--output',str(OUT/'hygiene-packet'),'--','make','hygiene-check']
print('STEP make hygiene-check',flush=True)
with (OUT/'hygiene.log').open('w') as log:
 r=subprocess.run(cmd,cwd=ROOT,env=dict(os.environ,BLORP_CLI_C_OPTIMIZATION='-O2'),stdout=log,stderr=subprocess.STDOUT)
meta=json.loads((OUT/'hygiene-packet/metadata.json').read_text())
guard()
result={'command':cmd,'exit':r.returncode,'source_changed_during_run':meta['source_changed_during_run'],'final_source':current_source(),'compiler_sha256':initial['compiler_sha256'],'accepted_report_unchanged':True,'accepted_manifest_unchanged':True,'native_complete':True,'completed_at_utc':datetime.datetime.now(datetime.timezone.utc).isoformat()}
(OUT/'results.json').write_text(json.dumps(result,indent=2)+'\n')
print('hygiene exit='+str(r.returncode)+'; source_changed='+str(meta['source_changed_during_run']),flush=True)
if r.returncode or meta['source_changed_during_run'] is not False:raise SystemExit('Hygiene failed/drift; STOP no retry.')
print('Hygiene PASS; child waited; wrapper releases slot on exit.',flush=True)
