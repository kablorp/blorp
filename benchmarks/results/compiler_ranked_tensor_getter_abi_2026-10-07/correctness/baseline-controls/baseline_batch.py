from pathlib import Path
import json, os, re, subprocess, time
from freeze_baseline import ROOT, OUT, TEST, BIN, current_source, digest
ENV=dict(os.environ,BLORP_CLI_C_OPTIMIZATION='-O2')
FROZEN=json.loads((OUT/'baseline-frozen-provenance.json').read_text())
COMMANDS=[]
RESULTS={'authority':FROZEN['authority'],'compiler_sha256':BIN,'source_before':FROZEN['source'],'gates':[],
         'native_batch_complete':False,'unexpected_failures':[],'oracle_status':'Authorized after all four suites PASS; not yet run'}
CONTROLS={
 'standalone ranked getters preserve all ABIs',
 'standalone ranked getters sequence receiver before read',
 'standalone ranked getters reject incompatible parts',
 'standalone ranked getter lookalikes keep runtime fallback',
 'pipeline ranked getters preserve runtime projection',
 'standalone ranked unboxes follow explicit scalar kind',
 'pipeline ranked struct unbox uses validated parts'}
def save():
    (OUT/'commands.json').write_text(json.dumps(COMMANDS,indent=2)+'\n')
    (OUT/'baseline-results.json').write_text(json.dumps(RESULTS,indent=2)+'\n')
def guard():
    state=current_source()
    if state!=FROZEN['source'] or digest((ROOT/'bin/blorp').read_bytes())!=BIN:
        raise SystemExit('Frozen source/docs/test/binary drift; STOP without edits.')
    oracle=FROZEN['oracle']
    if digest(Path(oracle['path']).read_bytes())!=oracle['source_sha256']:
        raise SystemExit('Frozen scratch oracle source drift; STOP without edits.')
    return state
def run(label,argv,packet):
    before=guard()
    print('STEP '+label,flush=True)
    started=time.monotonic()
    command=['scripts/record-validation','--output',str(OUT/packet),'--',*argv]
    log=OUT/(label+'.log')
    with log.open('w') as stream:
        process=subprocess.run(command,cwd=ROOT,env=ENV,stdout=stream,stderr=subprocess.STDOUT)
    meta=json.loads((OUT/packet/'metadata.json').read_text())
    output=(OUT/packet/'stdout.log').read_text()+(OUT/packet/'stderr.log').read_text()
    output=re.sub(r'\x1b\[[0-9;]*m','',output)
    after=current_source()
    item={'label':label,'argv':command,'cwd':str(ROOT),'exit':process.returncode,
          'seconds':time.monotonic()-started,'log':str(log),'packet':str(OUT/packet),
          'source_changed_during_run':meta['source_changed_during_run'],
          'source_equal_before_after':before==after,'compiler_sha256_after':digest((ROOT/'bin/blorp').read_bytes())}
    COMMANDS.append(item); save()
    print(label+': exit='+str(process.returncode)+'; log='+str(log),flush=True)
    if process.returncode or meta['source_changed_during_run'] is not False or before!=after:
        RESULTS['unexpected_failures'].append({'gate':label,'exit':process.returncode,'log':str(log),'source_changed_during_run':meta['source_changed_during_run']})
        save(); print(output[-14000:],flush=True)
        raise SystemExit('Unexpected baseline failure or drift; stop without fix/retry.')
    guard()
    return output
try:
    status=run('baseline-build-status',['scripts/compiler-build-status'],'build-status-packet')
    if not status.startswith('FRESH') or 'optimization: cli=-O2 runtime=-O2' not in status:
        raise SystemExit('Baseline not FRESH O2; tests held.')
    RESULTS['build_status']=status; save()
    suites=[('baseline-owning-emit',TEST),
            ('baseline-context-tensor','blorp/test/test_compiler/test_stage_09_core/test_core_tensor_specialize.brp'),
            ('baseline-runtime-checked','blorp/test/test_runtime/test_numeric/test_checked_get_set.brp'),
            ('baseline-runtime-multi-index','blorp/test/test_runtime/test_numeric/test_tensor_multi_index.brp')]
    for label,path in suites:
        output=run(label,['bin/blorp','test','--timeout','180',path],label+'-packet')
        passed=[line.split('[PASS]',1)[1].strip() for line in output.splitlines() if '[PASS]' in line]
        failed=[line.split('[FAIL]',1)[1].strip() for line in output.splitlines() if '[FAIL]' in line]
        if not passed or failed:
            raise SystemExit('Unexpected successful-exit case inventory for '+label)
        result={'gate':label,'suite':path,'passed':len(passed),'failed':len(failed),'failures':failed}
        if label=='baseline-owning-emit':
            controls=sorted(CONTROLS.intersection(passed))
            result['new_controls_passed']=controls
            if set(controls)!=CONTROLS:
                RESULTS['gates'].append(result); save()
                raise SystemExit('Not all seven frozen new controls reported PASS.')
        RESULTS['gates'].append(result); save()
        print(label+': '+str(len(passed))+' PASS / '+str(len(failed))+' FAIL',flush=True)
    oracle=FROZEN['oracle']
    c_path=OUT/'ranked-getter-oracle.baseline.c'
    run('baseline-oracle-compile',['bin/blorp','compile','--no-format','--no-embed-runtime','-o',str(c_path),oracle['path']],'oracle-compile-packet')
    c_text=c_path.read_text()
    RESULTS['oracle']={**oracle,'generated_c':str(c_path),'c_sha256':digest(c_path.read_bytes()),'c_bytes':c_path.stat().st_size,
                      'ranked_runtime_names':sorted(set(re.findall(r'\bblorp_tensor[345]_checked_get[A-Za-z0-9_]*',c_text))),
                      'scalar_read_helpers':sorted(set(re.findall(r'\bblorp_vector_read_f(?:64|32|16)',c_text))),
                      'contains_inline_storage_guard':'BLORP_VECTOR_STORAGE_INLINE' in c_text,
                      'contains_memcpy':'memcpy(' in c_text}
    save()
    run('baseline-oracle-run',['bin/blorp','run','--no-format',oracle['path']],'oracle-run-packet')
    RESULTS['oracle_status']='Compile PASS / run exit0; baseline C retained'
    RESULTS['oracle']['source_sha256_after']=digest(Path(oracle['path']).read_bytes())
    save()
    final=run('baseline-final-build-status',['scripts/compiler-build-status'],'final-build-status-packet')
    if not final.startswith('FRESH') or 'optimization: cli=-O2 runtime=-O2' not in final:
        raise SystemExit('Final baseline not FRESH O2.')
    RESULTS.update({'final_build_status':final,'source_after':guard(),'source_changed_during_batch':current_source()!=FROZEN['source'],
                    'native_batch_complete':True,'verdict':'PASS'})
    save()
    print('BASELINE CONTROLS PASS. All subprocesses waited; wrapper will release native slot on exit.',flush=True)
except BaseException as error:
    RESULTS['stop_reason']=str(error)
    RESULTS['source_after']=current_source()
    RESULTS['source_changed_during_batch']=RESULTS['source_after']!=FROZEN['source']
    save()
    raise
