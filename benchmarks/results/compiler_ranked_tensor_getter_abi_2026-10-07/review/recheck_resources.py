from pathlib import Path
import sys,json,hashlib,re
from decimal import Decimal,localcontext
p=Path('/tmp/blorp-ranked-tensor-reader-resource');o=p/'comparison';review=Path('/tmp/blorp-ranked-tensor-controller-review');sys.path.insert(0,str(p));import compare_resources as c
cfg_path=p/'candidate.json';cfgsha=c.sha(cfg_path);assert cfgsha=='ed10faeb10f2d3cad558daff36502a8f89e0f4b7fab42e2732f8adf22197ca53';cfg=json.loads(cfg_path.read_text());proof=c.verify_baseline();assert c.candidate_state(proof)==cfg['candidate_state'];assert c.dependency_pins()==cfg['dependency_pins'];assert c.sha(p/'compare_resources.py')==cfg['controller_sha256']=='a599e6b377739266fcf656ad893ff9c73cc31e7cdb7248261f015191eff270aa'
complete_path=o/'COMPARISON_COMPLETE.json';complete_sha=c.sha(complete_path);complete=json.loads(complete_path.read_text());assert complete['configuration_sha256']==cfgsha and complete['controller_sha256']==cfg['controller_sha256'] and complete['capture_sha256']==c.CAPTURE_SHA
for name,h in complete['file_pins'].items():assert c.sha(o/name)==h,name
construction=json.loads((o/'construction-pins.json').read_text());assert construction==complete['candidate_construction_pins']
for k,v in construction.items():assert c.sha(v['path'])==v['sha256'],k
setup=(o/'candidate-stage2-setup.log').read_text()
for name,label in [('generated_c','stage2 generated C sha256'),('body_object','stage2 body sha256'),('normal_binary','stage2 binary sha256'),('diagnostic_binary','stage2 diagnostic sha256'),('runtime_object_0','stage2 runtime sha256 diagnostics=0'),('runtime_object_1','stage2 runtime sha256 diagnostics=1')]:
    found=re.findall('^'+re.escape(label)+r'\s*:\s*(.+)$',setup,re.MULTILINE);assert found==[construction[name]['sha256']]
pairs=json.loads((o/'stage2-pair-provenance.json').read_text())
for mode,key in [('normal','normal_binary'),('diagnostic','diagnostic_binary')]:
    assert c.sha(pairs[mode]['path'])==pairs[mode]['sha256']==construction[key]['sha256'];assert pairs[mode]['actual_compiler_stage']==2
    assert (o/f'candidate-{mode}-version.log').read_text()==pairs[mode]['version']
assert c.sha(o/'captured-candidate-stage1')==cfg['candidate_state']['generator_sha256']
for name in ['candidate-fresh-before.log','candidate-fresh-after.log']:assert (o/name).read_text().startswith('FRESH')
measurement=json.loads((o/'measurement-pins.json').read_text());assert measurement==complete['measurement_output_pins'];result={}
for program in ['self','small']:
    records={}
    for role,pair in [('baseline',proof['pairs']),('candidate',pairs)]:
        rec,pins=c.validate_record(role,program,pair,proof['frozen_input']);assert pins==measurement[f'{role}-{program}'];assert rec['checkpoints'][-1]['total_allocations']==rec['total_allocations'];records[role]=rec
    before=records['baseline'];after=records['candidate'];assert before['output_sha256']==after['output_sha256']
    for field in ['cc_version','commit','compiled_by','optimization','target','split','cc']:
        assert before['toolchain'][field]==after['toolchain'][field]
    assert before['host']==after['host'] and before['machine']==after['machine']
    with (o/f'resource-baseline-{program}.c').open('rb') as b,(o/f'resource-candidate-{program}.c').open('rb') as a:
        while True:
            x,y=b.read(1048576),a.read(1048576);assert x==y
            if not x:break
    metrics={}
    for field in ['total_allocations','instructions_retired']:
        b=before[field]['min'] if field=='instructions_retired' else before[field];a=after[field]['min'] if field=='instructions_retired' else after[field]
        assert a*200<=b*201
        with localcontext() as context:context.prec=40;delta=Decimal(a-b)/Decimal(b)*100
        metrics[field]={'baseline':b,'candidate':a,'delta':a-b,'delta_percent_9dp':str(delta.quantize(Decimal('0.000000001'))),'exact_ceiling_pass':a*200<=b*201,'integer_candidate_ceiling':b*201//200}
    summary=json.loads((o/f'resource-summary-{program}.json').read_text());assert summary['generated_c_identical'] is True
    for field,m in metrics.items():
        actual=summary['metrics'][field];assert actual['baseline']==m['baseline'] and actual['candidate']==m['candidate'] and actual['within_0_5_percent_ceiling'] is True;assert actual['delta_percent']==(m['candidate']-m['baseline'])/m['baseline']*100
    spreads={}
    for role,rec in records.items():
        samples=rec['instructions_retired']['samples'];spreads[role]={'samples':samples,'min':min(samples),'max':max(samples),'spread_percent_of_min':(max(samples)-min(samples))/min(samples)*100};assert spreads[role]==summary[role+'_instruction_samples']
    result[program]={'metrics':metrics,'instruction_samples':spreads,'whole_c_sha256':before['output_sha256'],'whole_c_bytes':before['output_bytes'],'byte_identical':True}
commands=json.loads((o/'resource-commands.json').read_text());assert len(commands)==9 and all(x['exit']==0 for x in commands)
for program in ['self','small']:
    candidate=[x for x in commands if x['label']==f'resource-candidate-{program}'][0];assert '--require-identical' in candidate['argv'] and candidate['argv'][candidate['argv'].index('--samples')+1]=='3'
activity={x['label']:len(x['external_native_activity']) for x in commands if x['label'].startswith('resource-')}
c.CONSTRUCTION_PINS=construction;c.CONSTRUCTION_MANIFEST_SHA=complete['file_pins']['construction-pins.json'];c.PAIR_PROVENANCE_SHA=complete['file_pins']['stage2-pair-provenance.json'];c.MEASUREMENT_PINS=measurement;c.MEASUREMENT_MANIFEST_SHA=complete['file_pins']['measurement-pins.json']
c.verify_state(cfg,cfgsha,proof)
assert c.sha(complete_path)==complete_sha
for name,h in complete['file_pins'].items():assert c.sha(o/name)==h
out={'status':'INDEPENDENT_RESOURCE_CHECKS_PASS','complete_sha256':complete_sha,'candidate_sha256':cfgsha,'controller_sha256':cfg['controller_sha256'],'source_frozen_before_document_edits':True,'all_completion_file_pins_rechecked':len(complete['file_pins']),'construction_pins_rechecked':len(construction),'measurement_pins_rechecked':measurement,'metrics':result,'background_process_observations':activity,'baseline_live_freshness_required':False,'raw_harness_stage_caveat':'Outside-repo explicit-pair raw metadata reports unknown revision/freshness and stage1; exact retained source/generator/C/object/binary/header authority proves actual stage2. Raw records unchanged.','native_commands_by_reviewer':False,'repo_or_raw_metric_edits':False}
(review/'RESOURCE_REVIEW_CHECKS.json').write_text(json.dumps(out,indent=2)+'\n');print(json.dumps({k:v for k,v in out.items() if k!='measurement_pins_rechecked'},indent=2));print('checksSHA',c.sha(review/'RESOURCE_REVIEW_CHECKS.json'))
