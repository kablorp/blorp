# P2c: implemented / validation in progress

Working branch `codex/union-enum-retirement`, source base
`07c1ee30231cd79e80aac42a2d625a5d8cac87a6`. This provisional checkpoint is not a
final-source freeze, fresh compiler proof, phase acceptance or publication.
The epochs below predate the current-main integration unless explicitly labeled.
Historical declaration-cut evidence remains in
[final validation](../fixed_union_declaration_migration/final-validation.md).

## Current main integration

`origin/main` at `aa602e4ce051` is merged in `c80069ae0c98`; recovery snapshot
`c0eb8ad443f332e67d09b65c9f00f6c42e4972dd` restored enum-retirement WIP,
which remains uncommitted. New main parser/body/StopPoint and invariant/retention
changes are retained, with enum-only paths adapted to the common union model.
Maintained parent/suite paths use `test_*`; raw fixture directories and explicitly
listed support modules remain exemptions, not removed coverage.

Pure `/tmp/blorp-restored-path-audit.Sg6rtW/REPORT.md`, SHA
`7fb15cabe17a39cc0f316c6949b773418ef7b90e46d04195606c5a4e6f92755b`,
records layout/manifest exit0: 369 production modules, 268 suites, nine checks;
840 tracked marked check fixtures, 3576 parity files with zero missing paths,
and 894 changed-source relative imports with existing targets. This is static
preflight, not native acceptance. The moved `retired_enum_declaration.brp` and
`enum_identifier_positions.brp` are byte-identical to recovery, respectively SHA
`fe572f0048dc7f7da96de0078317cba80581e14db6ca4b741bd42534721a78c4` and
`9400ff5738018daa61d9e384bf926a43d0f36ea668e5774f8d4250b1e801bd2e`.

Default bootstrap `dev-d2959d886320` fails build-tool C compilation (Bool pointer/
integer mismatches); a cached generator is not default-pin regeneration proof.
The explicit retained `ebbd309a…540eb` bridge required regeneration with
`-W blorp/tool/generate_build_sources.brp`. Restored-WIP make first fails with two
CTFE unresolved-import diagnostics and one OR-pattern variable mismatch; removing
only the obsolete `EnumKeyword` alternative then gives make exit0 and override
FRESH (`c80069ae0c98-dirty`, CLI O0/runtime O2). Current binary SHA
`a182c30aa2e2ddab3cff7ea42de3918279f62884709f3d4645644f415ee523cd`.
Local `/tmp/blorp-union-main-integration.fXCTvc/` retains default generator C,
bridge regeneration and both restored build logs; RED/after-removal log SHAs are
`96d04864bb7bba10247c0bad76b41bd8487d9472d059803dbb6b04d32c69a705` and
`e73f22824b31b16bf09ddb4c0c9737d8945833064c1828b33a34153ff0fb96c3`.

Focused `/tmp/blorp-restored-focused.d7fi04` records warmup exit0 and seven
renamed owners **585/585 PASS**: late invariants51, Perceus445, tree declarations13,
stop reasons6, tree expressions32, ID census10 and parser fixtures28. The parser
owner separately executes774 positive/168 negative fixtures with diagnostic
pins/text; these overlap suite coverage and are not added to585. Before/after
3788-input manifests, bootstrap, binary and compiler C compare equal, with
override FRESH; compiler C SHA
`9d34d1c6d1252a136be78e189dfde35b0a7e6e2a44f3d6a09fe74a722f88a435`.
Exact environment/argv, raw outputs, hashes and exit records remain in that local
packet. All owned children ended and the native token was released. This is
bounded integration proof; earlier broad gates and self-host fixpoint remain
historical after this merge, not current-source acceptance.
Default-pin closure, ownership/ABI and match-access follow-ups, resource cost,
checked-fixed guarantees and publication remain unresolved.

## Common contract

`TypeKind.TypeUnion(UnionLayout)` replaces TypeEnum/TypeUnion logical families;
the accepted header publishes `ScalarTagUnion` or `TaggedUnion`. Graphless Env
installation retains that same layout fact. Nongeneric, payload-free unions retain
scalar tag defaults and native storage independent of ordinary/fixed spelling.
Generic/payload-bearing unions remain managed; no retired enum generic ban is
transferred to fixed unions.

Core has one `UnionType(name, CoreUnionValueStorage)` and one `CoreUnionDecl`.
Value storage is `ScalarTagValue | ManagedUnionValue`; declaration storage is
`ScalarTagStorage | ManagedPayloadStorage(CoreUnionPayloadStorage)`. Common
variants retain actual name/tag/DefID and field rows. Scalar declarations require
no type parameters and empty fields. Matching uses explicit scalar/managed tag
access. Bool stays canonical NamedType, not a namesake scalar-union ABI shortcut.
Authored Eq/Hash, issued constructor identities, managed ownership and existing
native contracts must survive the final gates. This does not solve deferred
general nominal/caller-trait identity work.

The internal TypeKind payload carrier is now boxed and has explicit exhaustive
Equatable behavior (including differing layouts); no unnecessary Hashable impl
was added. Its temporary allocation/resource cost remains unmeasured. A later
common-model baseline is required; this cut makes no performance claim.

## Actual source-owner/static epochs

All native commands below used the retained **prior-source** stage2 compiler
`/tmp/blorp-channel-final.tbXdUz/fixpoint-artifacts/blorp-stage2`, SHA256
`ebbd309a63347b5069abe20417afc6e0ae21ee1c7eb22ddf74893bfcb7f540eb`, and explicit
own `--std-dir .../43a9/blorp/standard_library/src`. They compile the edited owner
modules; they do not prove a fresh P2c compiler or new CLI syntax.

| Epoch | Actual result |
| --- | --- |
| Env source owner | 42/42 pass |
| Accepted-union authority + header dependencies | 10/10 + 8/8 pass |
| Semantic pipeline header graph + global completion | 59/59 + 31/31 pass |
| Total above | 150 assertions, all exits0 |
| Separate source-surface owner epoch | 549 assertions pass; discovery additionally reports774 positive/168 pinned-negative fixture executions, not additional framework assertions |
| Separate narrow Stage9 epoch | JSON146 + policy8 + match34 + late-invariants50 =238 assertions pass |
| Separate Stage10 epoch | emitter368 + projection64 + split23 =455 assertions pass |
| Python identity-census unit suite | 32/32 pass |
| Separate magic-scanner + dead-code audit Python epoch | 30/30 pass |
| Identity census after reviewed reconciliation | 3371 rows, within baseline; not a general identity proof |

Raw source-owner packet: `/tmp/blorp-p2c-semantic.RU6MIG/REPORT.md`, exact stdout/
stderr and retained Core/C in the same directory. Commands use `test --suite
--timeout 180` with the owner paths listed in that report. No owner counts are
relabeled as fresh-host/full gates.

Independent raw epoch artifacts (all same prior host/explicit own Std):

- Surface: `/tmp/blorp-p2c-surface.YYKRfc/owners.retry.stdout`, SHA256
  `6a423264ae74ce1482f3eb00852571f1a591c7b32561b5c67c6486e88d1dddd4`;
  fixture counters at435–440. The discovery fixture runs overlap the fixture
  framework assertions, so neither these nor different epochs are summed here.
- Stage9: `/tmp/blorp-union-core-retirement.K2neWx/owners.stdout`, SHA256
  `f03dbcb67bfe25fa9ffbbf194fd6ad6d3e878277aa19f69751551990c604ed46`;
  `owners.stderr` empty, accompanying REPORT records exact four owners.
- Stage10: `/tmp/union-cut2-backend.lWaFF0/owners.stdout`, SHA256
  `984ebc68e8be34c58e7dad36947018a4d62a1b04d4364d4d23d6b29fc4b7ce5b`;
  accompanying REPORT records exact three owners, source hashes and exit0.
- Scanner/dead-code Python: `/tmp/blorp-p2c-surface.YYKRfc/scanner-tests.stderr`,
  SHA256 `6f85f66a9beee15b9639699c5238822a76eeb9a75c42f5e4d8186ef3cf4b1ad7`;
  `python3 -m unittest blorp.test.build.test_check_magic_spellings
  blorp.test.compiler.architecture.test_dead_code_audit` reports30 tests/OK;
  stdout is empty. This is separate from the earlier source-surface Python61,
  editor6 and editor-drift0 epochs.

This repository checkpoint retains the concise claims/hashes; temporary raw paths
are artifact locators, not permanent repository evidence or fresh-source proofs.
Whole-source setup/typecheck failures remain separate zero-execution epochs and
must be resolved before the fresh compiler build. Owner tests of emission strings
do not substitute for native execution of the emitted programs.

Two setup stops preceded Env GREEN and executed zero assertions: missing generated
embedded_std (repaired by the authorized owning build-source generator targets),
then missing C definition for a new nested-capturing equality-matrix lambda.
Direct TypeKind and Option[TypeKind] equality native controls both passed.
`test_env_driver.c/.core` retain prototype/use but no emitted definition for
`brp_1WC`, Core DefID7478 with hoisted-lambda origin enclosing5511. The approved
test-only nested ordinary loops preserve all25 ordered equality checks; the
prior-host nested-closure emission defect is deferred, not repaired by P2c.

The identity ratchet reconciles exactly11 renamed keys plus7 storage-fact
annotations (three phase-snapshot maps), changes only Stage9 Dict cap180→187,
and deletes two retired CoreEnumDecl/CoreEnumVariant heuristic budget rows.
No schema, source revision, capabilities or unrelated caps are refreshed.
After A announced the source freeze (compiler-production manifest
`02abdfceead9d15f30e4e9647492566f925bad25b3581cd78321f6e42e38f8ef`),
the final non-native magic strict check passes506 findings/0 stale and identity
check passes3371 rows within baseline. These static checks do not establish
fresh compiler or runtime acceptance.

The whole-source check was interrupted with exit143, incomplete and zero
assertions; it is not a failed semantic gate. Reuse/pipeline owner execution
remains a separate pending proof.

## Initial fresh build and runtime RED

The initial P2c O2 `make` exited0 and build status reported FRESH under explicit
`BLORP_BOOTSTRAP_COMPILER_BIN=/tmp/blorp-channel-final.tbXdUz/fixpoint-artifacts/blorp-stage2`
and `BLORP_CLI_C_OPTIMIZATION=-O2`. The retained prior-stage2 bootstrap SHA is
`ebbd309a63347b5069abe20417afc6e0ae21ee1c7eb22ddf74893bfcb7f540eb`;
the newly built candidate SHA is
`304276ecca62d723bb8d70326603f6cb3befc7004253131b1e6648eda5d59df3`.
Generated compiler C SHA is
`973f8082989742cdfcc9f12e645aee2efd95911eee46d8c98765db85b68ca018`.
These are distinct roles, not default-pin closure. Build raw packet is
`/tmp/blorp-p2c-fresh.KxUSyU`; `build.stdout` SHA
`7d8bbcfafc3b9a566eb0ebbd574e54d51b17f5a343300ae776bb6e48f74e243e`
and `build-status.retry.stdout` SHA
`ae8667629d4d559a600bc741e5b50bf9e7f6ec690e4a0aad0d11d7466199f63b`.
The before-repair binary is retained as `blorp-before-bool-fix` there.

The seven-owner fresh runtime epoch in
`/tmp/union-cut2-fresh-runtime.Z5lxKf/REPORT.md` exited1: **37 PASS /1 FAIL,
38 executed assertions**. The packed tensor owner failed only
`test_bool_tensor_to_string`; scalar bridge8/8, managed synonym3/3, generic
layout4/4, List-result cleanup2/2, packed tensor18/19 and both String channel
owners1/1 are separate row counts in that same aggregate, not additional totals.
The reported CLI-process `3 allocs/3 releases/0 leaked` is not a separately
captured allocation interval for each workload or a full leak gate.
Raw `owners.stdout` SHA is
`2bcacb05be61b86a160f7857b0f47febd2ea47776f63561bff9b1868f89968ae`;
`owners.stderr` SHA is
`faa9e89937bc315f481377ab38d7161d0808209cd61e9d5e745a6c8d81e4b2ee`.

The minimal retained reproduction in `/tmp/union-cut2-bool-string.oeqrxi`
compiles and executes successfully but prints `bool={False, True, False}` for
the expected `{True, False, True}`; the Base control prints `{A, C, G}` correctly.
Final Core selects `blorp_vector_to_string_Bool` for
`UnionType("Bool", ScalarTagValue)`, whose declaration tags True0/False1;
the actual primitive Bool vector contains1/0/1. This loses the declaration's
accepted `abi_type=bool` when building the shared layout index, so the generic
declared-tag formatter reverses primitive Bool text. Source SHA
`e26f40dabe14cf1c1bc12a0e1a8791a09fa96441e39d21741f6a760604fa7d82`;
Core `9fdb93d58a0d5b1cbb04d2ee655489f97beac7ba5b6e70566ea145952ed44300`;
C `94e856febbaad210d9bb63112790116a7bb7ee95e3760471be85251498556381`;
stdout `dddb49a64fa52e71fcc76f6ff29d630ade356e8225c043a478d8b0c5e3606a5e`.
The initial invalid scratch main/print setup executed no code and remains a
separate setup failure, not this runtime verdict.

Earlier static review missed this runtime issue and is not correctness proof.
The proposed bounded repair preserves `Some(DeclaredAbiBool)` as canonical
`NamedType("Bool", [])` in the existing shared layout index; ABI-none namesakes
remain ordinary scalar unions. The exact patch and three owning tests received
independent static approval: direct/alias/nested canonical Bool, ABI-none
namesake/direct scalar identity, and adversarial managed-storage+Bool-ABI
metadata guard. That last test is not lawful native Bool admission. Owning
module execution using unchanged initial candidate304276 goes22/23 RED to23/23
GREEN, with only the trusted Bool control failing before the fix. This executes
the edited source owner; it does not make the old binary FRESH for the repair
or establish runtime pass-after. Raw packet is
`/tmp/blorp-p2c-bool-layout.5BHbYb`; bounded production diff SHA
`e422e72f410ce6d2022bc495c500a74afc160909a6c48e21ac2943f8532c222c`;
`owner-red.stdout` SHA
`8991c232803e04aa97bab4642f130e4584c325e702096635ab5304a8b6c590ab`;
`owner-green.stdout` SHA
`a9a832fec2e40e9fa66565513bb0bbe010185753a930639346841611548de487`.
At that source-owner epoch, repair rebuild and runtime pass-after were pending;
their subsequent results are recorded separately below, not attributed to the
unchanged initial candidate.

After the repair source freeze, compiler-source manifest
`75b5bce8144e5c7fba24679a060fd7fd5b8d4459234581c199aa120ff9244e89`,
the independent non-native identity check remains3371 rows within baseline,
magic remains506 findings/0 stale, and diff check passes. No extra budget or
magic allowlist change was needed for this repair. Logs are the packet's
`independent-{identity,magic}.{stdout,stderr}`.

## Repaired fresh build and runtime GREEN

The repaired O2 `make` exited0 and status reported FRESH under the same explicit
retained-stage2 bootstrap/O2 override. Candidate binary SHA is
`edec0fa7391eb3122fbc0c828fab345bb8d09dbf073a358a9d79e61b13e3326a`;
generated compiler C SHA is
`445cd11dfe85ccccc543d409f54f469fc804f4a63f0d510eae5f06ce56f37d0b`.
Build/status logs are `/tmp/blorp-p2c-fresh.KxUSyU/build-bool-fix.*` and
`build-status.bool-fix.*`. This proves the explicit local bring-up, not default
immutable-pin closure.

The unchanged seven-owner runtime command now exits0: **38/38 PASS**,
with row counts8+3+4+2+19+1+1. Raw packet
`/tmp/union-cut2-bool-fixed.Vs0rgO/REPORT.md` retains exact argv and unchanged
source/binary provenance; `owners.stdout` SHA is
`597a273a60db2d2cc9db15a694248f6b7bff645d0d7b9f172206d0f6d8519d29`.
The CLI-process3 allocs/3 releases/0 leaked interval retains the same limited
scope as the initial epoch; it is not a full workload leak gate.

The saved minimal source is byte-identical to the earlier reproduction and
now prints `bool={True, False, True}` and `base={A, C, G}`. Actual final Core
selects canonical lowercase `blorp_vector_to_string_bool`; emitted C calls that
helper at47666, while Base's issued formatter remains unchanged. Repaired Core
SHA is `8ca8d4c40f3eff4869b48a6fe785d23e4452f7f020dfd034f479c6d7565110d2`;
C `ce2bfeaac0078c42ea77fc4f26bc0dc333012287bd49b2bf377e70b57b5e2166`;
stdout `d248073edb62fb7d2974e173cc161837bc575ef57d73455bba9b60b4f11d5786`.
The first37/38 RED and source-owner22/23→23/23 epochs remain separate historical
evidence. This bounded repair is runtime-confirmed, not full P2c acceptance.

The first broad `compiler-blorp` attempt with the repaired host stopped in about
2 seconds during source setup, executing zero assertions: the new malformed
scalar-publication test had an ungrouped multiline equality predicate at
`test_core_lower.brp:6204`. Raw failure is retained in
`/tmp/blorp-p2c-compiler-aggregate.9AZFRn/logs/compiler-blorp.log`.
The authorized test-only repair adds parentheses around the unchanged two
exact error-string assertions; corrected owner SHA is
`253073fcbb36176a81879d7af2c5a53aa2bc26cbcbfc0547831a70dfb3d6a5e6`.
Other newly added Stage6–8 test continuations were inspected for the same
grammar shape; no further new ungrouped predicates were found. Compiler
production and the repaired binary are unchanged. The corrected broad epoch
is pending, not inferred GREEN from this setup repair.

The next source-closure attempt exposed remaining maintained benchmark/pipeline
fixture uses of the retired one-argument union type and declaration payload
field. Authorized mechanical fixture-only updates preserve their managed
storage, constructor IDs/tags, workloads/counters and algorithms; the valid
`CoreUnionConstruct.payload_storage` remains unchanged. These source setup
repairs are not workload or performance changes.

## Broad retry2: incomplete native batch and fixture GREEN

`/tmp/blorp-p2c-compiler-aggregate.9AZFRn/retry-2/REPORT.md` records outer exit1
with source/host-C compilation successful, then the normal360-second native
execution timeout. Actual completed progress is **4596 PASS /2 assertion FAIL,
4598 executed assertions** before timeout; the runner adds one timeout failure,
reporting native4596 pass/3 fail/4599 entries. The separate **840 marked
production check fixtures pass**. Composed machine result5436 pass/3 fail/5439
entries is not complete native-owner acceptance. No missing assertion is
presumed passed, and no timeout increase or waiver was used. Raw gate log SHA
`128b3ab64260480853bca10a2759daeb8a28016cb66093131d8c0deb094b6bee`.

Two actual assertions fail: backend constructor-index parent-kind control and
the work-profile serialized-output length pin. The latter's single diagnostic
records every observation field and actual canonical JSON: semantic workload
checksum stays`-1646294515644582960`, nodes88→88 and lookup queries/candidates4/4.
Only output JSON length13416→13796 changes. Exact schema accounting is4 union
value-storage fields×26 +4 declaration wrappers×35 +4 managed tag-access
wrappers×34 =380; an inverse wire projection of only those fields reconstructs
the old13416 length exactly. Root approved only the test length pin13796 and
an explanatory comment; all semantic/counter predicates and profiler algorithms
are unchanged. Diagnostic packet is
`/tmp/blorp-p2c-semantic.RU6MIG/WORK_PROFILE_CHECKSUM_DIAGNOSIS.md`.
The complete work-profile owner subsequently passes3/3, exit0, using unchanged
edec with explicit own Std; raw `work-profile-owner.stdout` SHA
`182d9b96c1b6b5182ecf149a6f967d0532ab0c12d950555d390c1ace025ad946`,
stderr empty. This is edited source-owner execution, not current-source CLI
freshness after the backend repair. Independent expectation review reports
zero findings; no semantic checksum or algorithm change was accepted.

The bounded backend-projection repair was a separate source-owner epoch, not
attributed to the edec fresh-runtime proof above. It made edec stale; the
subsequent fresh rebuild and execution are recorded separately below.

## Final pre-loss fresh-host proof and recovery boundary

The final pre-loss O2 build exited 0/FRESH with the same explicit retained-stage2
override, not the immutable default pin. Compiler manifest:
`522bb1a9d11a0041f5ec6c361aa4143444621d9e0d369771ce65b6e463b17922`;
binary `9f0170a3a4d23df9336bf8e48f0c724b3d9314bab96e8df8e3d322aeabe8a153`;
compiler C `9c748b180023856fd5b9b56d916be4971271ac75d1353722e4bfe5a69fcb856e`.
Packet `/tmp/blorp-p2c-grouped.4qAO2R/REPORT.md` retains exact build environment,
argv, input manifests and raw results.

All 267 unique registered owners ran in disjoint groups of 1/100/100/66 paths:
14 + 2002 + 2579 + 1264 = **5859/5859 assertions**, all four exits 0. The
manifest-bound script validates exact membership; no repeated epoch counts
are added. This covers the registered Stage8, CTFE, legacy-parser, Core/backend
and maintained benchmark owners, rather than leaving them wholly unrun.
The separate marked-fixture command passes **840/840**. Test artifacts retain
default O0 and normal 360-second execution limits. Raw group output hashes:

- Group 0: `a9b6fd6feac290c34554d49923a3d0a69f3b4ea082bb9d43384921998af1a57e`
- Group 1: `3e1cb80aaec067b9f7135fd32a388fcf29bf4c01c3cc8fa984fd0605fe5627b4`
- Group 2: `1a7ae557278a799c563d6e5e7604cf13e54c5c0552e72fc4602753b5f24ca39e`
- Group 3: `6b31a981e723137f0df49b4bbe3e72f70e0edb3515a3caae6025e165d9811f10`
- Fixtures: `b5594032c3be824da9614165b58f9a1545cc869de519e9b61006a048db075354`

The same final host passes strict runtime **38/38**, and the byte-identical
saved probe prints correct Bool and Base text using canonical lowercase Bool
formatter in actual Core/C. Runtime stdout SHA:
`1834c292ec8fd9e8f7edff66718ec64106639a8971cd299c5cfcae07c0835ba8`.
The process interval is 11 allocations/11 releases/0 leaked, not per-fixture
allocation measurements. Three inherited const-List qualifier C warnings remain;
no warning-clean or runtime-constness repair is claimed.

The subsequent unchanged normal combined retry completes its native portion
**5859/5859** at the normal timeout. During its fixture phase the entire checkout
disappeared: 634 fixtures passed and 206 commands could not start (`Errno 2`,
missing `bin/blorp`). The actual outer result is infrastructure **FAIL:
6493 passed/206 failed/6699 entries**, exit 1, not a semantic fixture failure or
normal gate PASS. Raw `normal-retry/logs/compiler-blorp.log` SHA:
`79a9cfb6e8fe8cac20c79831670817f6c7e66c9e75930229fabbefd9ed718f0a`.
Grouped and repeated native coverage overlap, not add. Post-run no-drift/FRESH
verification was blocked by the loss and is not inferred from earlier checks.

Recovery at the same path/branch used automatic cleanup snapshot `b52fe8ea`
(parent `07c1ee302`). Root verified both full-source and compiler-production
manifests equal pre-loss inputs and locked the worktree. Generated caches and
the compiler were rebuilt separately. The clean recovered epoch in
`/tmp/blorp-p2c-recovered.OyYhfb` records make exit 0 and explicit-override FRESH,
with identical binary `9f0170a3a4d23df9336bf8e48f0c724b3d9314bab96e8df8e3d322aeabe8a153`
and compiler C `9c748b180023856fd5b9b56d916be4971271ac75d1353722e4bfe5a69fcb856e`.
The unchanged normal command completes **6699/6699**, exit 0: 5859 native
assertions across 267 owners and 840 marked fixtures. Default artifacts O0 and
native timeout 360 remain unchanged. Scoped source equality covers the enumerated
`blorp/src`, `standard_library/src`, `blorp/test/compiler` and
`blorp/benchmark/compiler` roots, plus separately hashed owners/gate inputs;
it does not cover every repository file or the separate
`blorp/source_ownership.json` metadata deletion. Those inputs verify equal
before/after; final explicit-override status is FRESH.
This is a new passing recovery epoch, not a relabeling of the infrastructure
FAIL above or additive coverage with the grouped run.

Raw evidence: recovered `REPORT.md` SHA
`ab0fd4b043af73b12bab5ecdcacb8c0983cc30fb5b258b9686428d74872a2c28`;
`gate.stdout` SHA
`67ff315ca5327fc25e8e49e927e2736add0eb485861b1d8e59bbfab0571c7e90`;
`logs/compiler-blorp.log` SHA
`69769810dfe02606b9fc5d7d5c902c7777cd02339016f7a94aa5260c625991b6`.
Actual compiler and C artifacts are retained in that packet. The default
bootstrap pin was not used or validated.

Supplementary root-transcript-only static proof (no saved raw file/hash):
`PYTHONDONTWRITEBYTECODE=1 python3 -m unittest
blorp.test.build.test_compiler_identity_census
blorp.test.build.test_compiler_new_parity
blorp.test.build.test_check_magic_spellings
blorp.test.compiler.architecture.test_dead_code_audit
editor.test_record_spelling_grammar` reports 129 tests/OK in 16.820 seconds.
This does not replace native parity or product gates.

## Frontend closure on the unchanged fresh host

The initial `/tmp/union-cut2-frontend.opvo00/REPORT.md` records compiler-new
838 passed/1 failed: only the vocabulary ordinal assertion failed. Removing
the enum seed shifted 14 tested nonempty IDs by one. The reviewed test-only
repair preserves all 15 independent spelling predicates and EMPTY=0; its
identical focused command moves from **4/5 RED to 5/5 GREEN**. Production and
binary inputs did not change.

The retry `/tmp/union-cut2-vocabulary.8IAYgL/REPORT.md` records compiler-new
**839/839**, compiler-tools **241/241** and Std **1/1** PASS. Its parity result
remains **3563 passed/2 failed/3565**, because the two intentionally removed enum
parser files remained in the Git index and could not produce dumps. That bundle
exited 1; it is not reclassified as a parity pass.

Root then staged exactly those two existing deletions, without changing source,
scripts or oracles. The separate parity-only retry in
`/tmp/union-cut2-parity-index.BzoHmX/REPORT.md` passes **3563/3563**, exit 0,
with **0 mismatched files**. Two existing documented interpolation divergences
remain unchanged. Diagnostic differences and overlapping corpus statistics
are not extra independent test counts. Both epochs retain default limits/O0
artifacts and before/after explicit-override FRESH with unchanged `9f0170` binary
and `9c748b` compiler C. Subsequent fixpoint/stage2 results below are separate
proofs, not inferred from frontend closure.

Report SHAs: vocabulary
`17b42956a8b4772b2d69253b57cc60d9a624589deca7db98e07e278c731f6bc5`;
parity `6d3fa4aaef755c1002050a8b51e6ce2d262ab74077e873d0f1ca839ba6f0d717`.
Parity raw `logs/compiler-new-parity.log` SHA
`8dd9441a3db8ceee6cc8a0b5416a88ca0ed62979a4a6eaf551f1263863a09ecf`.

## O2 self-host fixpoint

The actual `scripts/compiler-fixpoint --work-dir
/tmp/blorp-p2c-fixpoint.8cOpzw/fixpoint` gate exits 0 under the explicit retained
bootstrap/O2 environment. Full byte comparisons of stage1/2 C and stage2/3 C
both return 0. All three 76,578,733-byte C artifacts share SHA
`1c7fafed96f5e07f013e4fc9db10f98d84515b617ae7e09692967b70c82b02fa`.
New stage2 binary SHA:
`221f412a2a94e56a61da86a95767273789af0002f0dcfe99930b6cc9e32e9c95`;
stage3 binary SHA:
`3c82dce11551f8f0ba84d2d076b015451e49f1aeae7ea29a463b856bca033d84`.
Their binaries are not claimed byte-identical. Both retained versions report
commit `07c1ee30231c-dirty`, `compiled_by: self-07c1ee30231c`, aarch64 macOS,
CLI/runtime O2, split 8, Apple clang 21.0.0 and memory diagnostics 0.
Raw `fixpoint.stdout`, `stage-artifacts.sha256` and both version files reside
in that packet. This generated-C fixpoint is not itself new-stage2 codegen/native
test acceptance; those separate results follow.

## New-stage2 bounded validation and inherited IP ownership failure

`/tmp/blorp-p2c-fixpoint.8cOpzw/REPORT.md` (SHA
`d353fef58c1a6e56c67980f773197cc245a48081a5c91cd5f0365fb948227f53`)
records actual new-stage2 **audit 229/0 PASS**, jobs1/default30, and unchanged
seven runtime owners **38/0 PASS**. Audit checks C syntax/warnings, not linked
native execution. Runtime process interval 11 allocations/11 releases/0 leaked
is not a per-fixture allocation measurement or additive coverage with root-host38.

The separate strict Directory/TCP/MemoryCounter aggregate is **FAIL 31/1/32**:
Directory13 and MemoryCounter1 pass; TCP17/18 passes, failing only
`IP TCP echo round trip [LEAK: 2 objects]`. Its per-test table reports unknown
two objects/84 bytes; the distinct CLI-process interval11/11/0 does not waive it.
The original strict TCP probe was not run after that real failure.

Differential `/tmp/blorp-p2c-ip-differential.NPnl1b/REPORT.md` (SHA
`d7258d4c7002f93e84248d5a1ceadef76d130876137840f411d4677d2d609914`)
then reproduces the
same native31/1 with retained prior-stage2 `ebbd309a…540eb`, using the exact
current owner/Std. Both same-source strict IP non-leak runs exit0 and print
`TCP_NATIVE_IP_OK`; both leak-check runs exit99 with 48 allocations/46 releases/
two leaked/84 bytes. This proves actual socket success and reproduces ownership
failure under the retained prior compiler; it is **not** a fresh parent-07 runtime
comparison, regression attribution or acceptance waiver. Raw Core/C and outputs
remain in that local packet; no native admission or expectation was changed.

## Hygiene metadata closure

Actual `make hygiene-check` first exits2 in
`/tmp/blorp-p2c-hygiene.glTZ74/validation`, solely because a temporary import
permission still named retired `enum_preview.brp`. Removing exactly that one
entry from `blorp/source_ownership.json` changes adapter permissions32→31;
both retired imports are absent, with no owner/rule widening. Focused layout
RED→GREEN and the inspected pure Python layout suite38/38 pass, retained in
`/tmp/union-cut2-layout-metadata.Tf8chg/REPORT.md`.
The full aggregate then exits0 in `/tmp/blorp-p2c-hygiene.glTZ74/green`:
identity3371 within baseline, magic506 allowlisted/0 stale. Metadata records
no change during either run; compiler/Std/binary bytes are unchanged by this
metadata-only fix. Green stdout SHA
`57ed932bd200e3a1efa056c39d9d26882f05b37f13bff591c9322f46af741f3a`.
This closes hygiene, not the separate IP ownership failure.

## Broader product gates: stopped at LSP

Frozen `/tmp/blorp-p2c-product-plan.QvZbhG/REPORT.md`, SHA
`d622c3be8872e5b576f297b86bb234198e1bcc36d177d7375feae419bbbfb010`,
records separate actual PASS gates: runtime **4701/0**, leak **1174/0**,
doctest **1057/0**, CLI-deep **177/0**, each exit0. Counts are per gate and
overlapping earlier epochs are not added.

LSP stops with actual suite-level **FAIL 1/1/2**, exit1: its first protocol
fixture passes, then NativeLspBaselineTests runs18 tests with one error in
`test_definitions_traverse_selective_imports_to_unopened_provider`, waiting for
publishDiagnostics. Raw failure is a timed-out LSP response, not a fabricated
assertion count. Later LSP suites, package and compiler-core-sanitize were
**not executed**. No retry, timeout increase, contention attribution or inherited
regression classification follows. Raw `product/lsp/lsp.log` SHA
`1c67004b1d46d141f9be696bb2dbecc09c91243a3ddfe7abc4050003cf301a77`.

This capture began after the metadata-only permission fix: 4634 existing files,
zero missing, sorted tracked/untracked/generated inputs SHA
`6dc1d72882af7d35efa99e120fc1fafaf0b2cf6039f5327b42d8e74f64fcaf98`;
only these two evidence docs were excluded. Each after-gate manifest compares
equal, and compiler/C/bootstrap hashes remain unchanged with override FRESH
before/after. This is separate from the earlier enumerated-root source proof,
not a broadened interpretation of it. Default limits/O0 test artifacts remain
unchanged. Passing runtime/leak does not waive the strict IP two-object/84-byte
failure or establish P2c/P3 acceptance.

## Later LSP diagnostics and independent gate coverage

The unchanged isolated exact test passes **1/1** at its default30s deadline:
`/tmp/blorp-p2c-lsp-isolated.5pGcHz/REPORT.md`, SHA
`9fbff4b8487f07714b0e8a34cefc047acd2cc37ab8da32d295eade2e6a290f10`.
The subsequent full LSP retry still fails **1/1/2**, exit1, with the same native
18-test/one diagnostics-timeout error; `/tmp/blorp-p2c-product-resume.hnoTsW/REPORT.md`
SHA `d652f2066e6e1eef41f63d614dfaf101561768451617431aba8aa1a78c3d8e05`,
raw LSP log SHA `3f9fe0b8cb35740df582bc62cecb832ef82da05742ac52c347b4ec74e8d72ac2`.
One instrumented four-test prefix then passes **4/4**, exit0, under unchanged
deadlines: `/tmp/blorp-p2c-lsp-diagnostic.cX6bTc/REPORT.md`, SHA
`b2c7a0ca01a179fa7316ef15f94c7ed96264325bd21362ac82389da5189f93f7`;
protocol SHA `bed0adffa9321fe378db3c5bb7dbc70a578be7e797c7e59e3f2e58caf867484d`.
Instrumentation can perturb scheduling. These diagnostic passes establish
neither the failures' cause nor full-gate closure; both full failures remain.

Separately authorized despite LSP, package **49/49** and Core sanitizer
**2431/2431** each pass, exit0, using default limits/O0 artifacts:
`/tmp/blorp-p2c-independent-gates.NjOoJF/REPORT.md`, SHA
`71f10ae6876363155d8b77cc6e3166f0df2ebd42cae2e76159031e12cbaf76a9`.
Raw package/Core sanitizer log SHAs are respectively
`b751b1098d8483f2ebbaa5fa6c573625589e9b2aa0accb42c60bff70ca2e54ee` and
`c1eeac2262370567ff2dd627cb25be19c4c95bdf1d08fbdd6d364807571a8c44`.
Each packet retains exact argv, own Std, explicit ebbd/O2 override, unchanged
source/gate manifests and bin9f/compiler C9c provenance, with FRESH before/after;
only these two evidence docs are excluded. These are local artifacts, not
retained repository logs. Earlier unexecuted epochs remain historical. This is
independent coverage, not LSP exclusion, IP-leak waiver or P2c/P3 acceptance.

## Pending bounded P3 hardening

Read-only generated-C review also identifies an inherited direct-pointee ABI
issue: generated DirectoryEntry has `uint8_t kind`, while the native runtime
uses `long kind`. The retained declaration-cut baseline has the same mismatch;
no P2c regression is demonstrated. Native behavior tests cannot replace an
exact field-type/width oracle (tail padding can hide the mismatch from offsets
or total size). The separate identity-authorized native-pointee layout proposal
and required managed String/ownership controls are retained in
`/tmp/union-cut2-generated-c-review.Z2kms2/DIRECTORY_ENTRY_DESIGN.md`.
No repair or ABI-hardening acceptance is claimed here.

Independent audit notes that common `UnionTagConstructorTest` access decodes
separately from its scrutinee, while current declaration/value storage checks
do not validate match access. Valid producers choose correctly today; no source
regression was observed. A future bounded whole-Core validation should compare
`ScalarTagAccess`/`ManagedTagAccess` with the actual resolved subject/accessor
type and issued parent identity, reject both mismatches, and retain canonical
Option/Bool controls. The decoder's local record lacks subject context, so this
must not become a spelling heuristic. Source seams:
`ir.brp:decode_core_constructor_match_test_json`,
`late_invariants.brp:union_storage_violations`, and
`emit.brp:emit_constructor_match_test`. No implementation or acceptance proof
for this follow-up is claimed.

**Authorized bounded builtin-ownership repair:** the closed native-managed
IpAddress/DnsName/InterfaceScope category now carries issued accepted-header
identity through a required typed-program authority capability and the existing
checked canonical projection into a self-contained Core witness. Shared leaf
ARC/native-pointer policies consume that witness; no managed-name whitelist,
String alias, or trait/FFI admission expansion was added. Broader nominal
identity work remains deferred. The earlier scope review is retained locally in
`/tmp/union-cut2-generated-c-review.Z2kms2/BUILTIN_OWNERSHIP_SCOPE_REVIEW.md`.

## Current native-managed ownership repair

The integrated retained-bridge build in `/tmp/blorp-union-ownership-integrated.Nx8Wi9`
passes after two mechanical missing Core-type arms: the first build's six CTFE
dependency diagnostics and two non-exhaustive matches remain in `build.log`;
the retry clears all eight without a CTFE rewrite. Build-status is FRESH
(CLI O0/runtime O2), warmup exits0. Bin SHA256
`9ce7e2589431ec3a741c3d952a0bb0e68391b13cd9d69dd88a3054c8aaf7a1d8`
and compiler C SHA256
`45ddfaf9f75678b55b074c43aef73a4db402d51d2f919ff8ba33a5ef35457198`
are recorded in `provenance.sha256` (SHA256
`64d8fa098d12f7648e1c559dfa35fe5581162fd8787760a92deac8b28ffc245d`).

The unchanged strict probe exits0 with `TCP_NATIVE_IP_OK` and **48 allocations,
48 releases, zero leaked objects/bytes**, versus the retained baseline's
48/46/two objects/84 bytes. Independent Core/C inspection confirms both address
locals carry exact `NativeManagedType` witnesses and receive one Drop each.
Raw `strict-leak.stdout`/`strict-leak.stderr` SHAs are
`17f8fdad4a514985304b6499d41eead5d2a16116d5d6e3540cf86560d4e7a1db` /
`96729bf6a3079b1dfbdc1277eac8c2f62b6d59b28eb1fa2ab0129dfae314e5a1`.
These are local evidence artifacts, not retained repository logs. The existing
TCP suite exits0, **18/18 PASS**, including actual IP echo; shutdown reports
three allocations/three releases/zero leaks. All root native children ended.
Post-probe status remains FRESH under the same explicit bridge/O0, and every
`provenance.sha256` entry verifies unchanged (bin, C, bridge, probe/TCP source,
and authority module).

Separate prior-host imported-source proofs remain **262 frontend/lower** and
**201 final Core controls**, not fresh CLI/runtime assertions; their packets are
`/tmp/blorp-native-authority-owner.H1vV2f/REPORT.md` and
`/tmp/blorp-native-core-freeze.6sngTb`. The fresh strict result does not establish
current broad gates, fixpoint, LSP, performance or overall P2c/P3 acceptance.
Default-pin Bool ABI/build-tool closure still requires a verified capability
bootstrap; no pin rotation or publication is authorized. DirectoryEntry width,
match-access validation, costs and checked-fixed guarantees remain pending.

## Pending acceptance

Historically, registered Stage8, CTFE, legacy-parser, Core/backend and benchmark owners are
covered by the complete current-source 267-owner proof; none are added to the
earlier 150 semantic assertions. The clean recovered normal compiler gate
passes 6699/6699 in its own epoch. Separate frontend/parity/tools/Std closure
is recorded above. New-stage2 audit229 and seven-runtime38 pass separately;
native IP ownership failed in that epoch; the current strict repair proof is
separate above. Broader runtime/leak/
doctest/CLI gates pass, but product closure stops at the actual LSP failure;
package49 and sanitizer2431 pass independently as recorded above, without
closing that epoch's LSP or strict IP ownership. Current P2c/P3 acceptance remains pending.
P3 obsolete-wrapper/
authority cleanup and the common-model resource/instruction baseline remain
open; no P4 optimization or checked-fixed contract is claimed. Default immutable
bootstrap closure/pin rotation and publication are not validated or authorized
by this provisional checkpoint.
