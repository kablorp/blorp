from pathlib import Path
import hashlib, json, subprocess
ROOT=Path('<worktree:reader-cuts>')
OUT=Path(__file__).resolve().parent
BASE='2ee201fb5cb74e8a7b4f3d068a143d8d71dd2bad'
TEST='blorp/test/test_compiler/test_stage_10_backend/test_core_emit.brp'
BIN='a17a6ed3cdfcac11df20e459bea1b7235a57768194d73551a78c0a76964513ab'
def digest(data): return hashlib.sha256(data).hexdigest()
def git(*args): return subprocess.check_output(['git',*args],cwd=ROOT)
def current_source():
    tracked={raw.decode():digest((ROOT/raw.decode()).read_bytes()) for raw in git('ls-files','-z').split(b'\0') if raw and (ROOT/raw.decode()).is_file()}
    untracked={raw.decode():digest((ROOT/raw.decode()).read_bytes()) for raw in git('ls-files','--others','--exclude-standard','-z').split(b'\0') if raw and (ROOT/raw.decode()).is_file()}
    return {'head':git('rev-parse','HEAD').decode().strip(), 'tracked_files':tracked, 'untracked_files':untracked,
            'production_patch_sha256':digest(git('diff','--binary',BASE,'--','blorp/src','standard_library/src','blorp/build','Makefile')),
            'compiler_test_allowlist_patch_sha256':digest(git('diff',BASE,'--','blorp/src','blorp/test','scripts/check-magic-spellings.allowlist')),
            'full_tracked_patch_sha256':digest(git('diff',BASE))}
if __name__=='__main__':
    observation=json.loads((OUT.parent/'read-only-baseline-observation.json').read_text())
    state=current_source()
    assert state['head']==BASE
    assert state['production_patch_sha256']==observation['production_patch_sha256']
    assert digest((ROOT/'bin/blorp').read_bytes())==BIN
    assert digest((ROOT/TEST).read_bytes())=='1355d3d429e0ebf1f4ae8b9fc0a371dfa83e96cb33c0e579583fe468f6a786e7'
    patch=Path('/tmp/blorp-ranked-tensor-abi-implementation/tests-only-v3.patch')
    assert digest(patch.read_bytes())=='97132e624f93f64ea9a5421f9713c5361fede0be1d8be94cc2b1d6c2d39f8b33'
    frozen={'authority':'2ee + accepted dictionary309 production, tests-only ranked controls',
            'source':state,'compiler_sha256':BIN,'owning_suite':TEST,'owning_suite_sha256':digest((ROOT/TEST).read_bytes()),
            'tests_only_patch_sha256':digest(patch.read_bytes()),'native_commands_started_at_freeze':0}
    oracle=Path('/tmp/blorp-ranked-tensor-abi-implementation/ranked_getter_oracle.brp')
    assert digest(oracle.read_bytes())=='8c9aca635816a35891825e6f784f99c3ea6153a74b991bddb21742b11524e57f'
    frozen['oracle']={'path':str(oracle),'source_sha256':digest(oracle.read_bytes()),'authorization':'Root corrected-v3 GO, after two parse probes and four suites pass.'}
    frozen['retry_reason']='Owner parenthesized seven multiline Boolean assignments after v2 parse failure; earlier inline-if and pipeline shape-name corrections retained. Production unchanged.'
    frozen['original_attempt']=str(OUT.parent/'baseline-controls/PRESERVATION_MANIFEST.json')
    proposal=Path('/tmp/blorp-ranked-tensor-abi-implementation')
    pins=json.loads((proposal/'PROPOSAL_PINS.json').read_text())
    assert pins['emit.preparation.brp']=='5fe71603571ab2614b80fc6d6b22b168fb056bb7039e5d78e19a28a497dd9e9b'
    frozen['scratch_proposal_files']={}
    for name,expected in pins.items():
        item=proposal/name
        assert digest(item.read_bytes())==expected
        frozen['scratch_proposal_files'][str(item)]=expected
    frozen['scratch_proposal_files'][str(proposal/'PROPOSAL_PINS.json')]=digest((proposal/'PROPOSAL_PINS.json').read_bytes())
    (OUT/'emit.preparation.frozen.brp').write_bytes((proposal/'emit.preparation.brp').read_bytes())
    (OUT/'PROPOSAL_PINS.frozen.json').write_bytes((proposal/'PROPOSAL_PINS.json').read_bytes())
    (OUT/'ranked_getter_oracle.frozen.brp').write_bytes(oracle.read_bytes())
    (OUT/'baseline-frozen-provenance.json').write_text(json.dumps(frozen,indent=2)+'\n')
    (OUT/'tests-only.patch').write_bytes(patch.read_bytes())
    (OUT/'owning-suite-frozen.brp').write_bytes((ROOT/TEST).read_bytes())
    (OUT/'frozen-source-boundary.patch').write_bytes(git('diff',BASE,'--','blorp/src','blorp/test','scripts/check-magic-spellings.allowlist'))
    print('Frozen source/tests/docs/binary; native commands not started.')
