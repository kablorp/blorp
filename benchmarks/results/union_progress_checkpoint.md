# Union progress checkpoint

Historical checkpoint base: `66944f3e97af7c394661747af69ef9f1afa44dfd`, consisting of published
`c3040e79c` plus two independently reviewed local integration-branch prerequisites.
This note records acceptance boundaries and the current execution checkpoint,
not performance measurements.
The [roadmap](../../docs/FIXED_UNION_ROADMAP.md) remains the implementation plan.

## Current execution checkpoint

Validation source base is `cbffad8a3`, including the merge of recorded `origin/main`
`3f80e94e08e136265cc9138cf6acfcdca3c499af`. User direction now accelerates all
maintained declaration/fixture source to `fixed union` first: resolve actual
tests, validate/review/commit that cut, then remove all enum internals. Common
traits and nominal-identity design work are deferred, not completed or gates
for the mechanical cut. The declaration cut is reviewed and validated.
Final host `2f44843a7` is FRESH under the explicit frozen
bridge/O2 override, not verified default-pin closure. Independent final-host
compiler 6672, runtime 4701, leak 1174, sanitizer 2413, product/CLI/LSP/package
gates, audit 229, O2 fixpoint and retained stage2 runtime 29/audit 229 pass. The
reviewed seven-cap census closure passes hygiene and Python 32; its original RED
report remains frozen. [Final validation](fixed_union_declaration_migration/final-validation.md)
keeps all earlier frontend/parity and repair epochs distinct. General heterogeneous
OR-pattern field identity remains deferred beyond the bounded late-loop traversal
repair. Enum-family deletion and checked fixed guarantees remain pending. No pin
rotation, enum-internals closure or enforced fixed no-box guarantee is claimed.

The evidence below belongs to the prior checkpoint, whose root source was
`dd23675b7912a824173b3362bc53a69928e44d39` on the local
`codex/fixed-union-execution` branch. It contains accepted static producer foundation
`93dbe8f8f`, published-main integration `3c3383357914ed7a90cb3eb9ebab22ba378186d7`,
and accepted lexical callable-bound slots (author `dfadf1a`). Acceptance is bounded
to unhooked static products, not inference/Core/CTFE transport. The isolated
candidates below are not integrated. At that checkpoint local `main` was
`9ad323493e833aa82497b8009c7d6916857276c1` and the recorded `origin/main` ref is
`9859898e0595b80987fb800dc56568ecdb33dc99`; those refs are historical observations,
not current integration or validation evidence.

At that historical checkpoint, the last actual FRESH root O2 proof was the merged `3c3383357` epoch:
[independent report](/tmp/blorp-current-foundation-independent.L1NVRm/REPORT.md).
It passes 84/84 focused foundation cases and separately 2/2 borrowed-payload-loop
leak cases, with zero leaked objects/bytes. The process-end 3 allocations/releases
are not fixture-allocation costs. CLI/runtime O2, split8, Apple clang21.0.0,
aarch64-apple-darwin, bootstrap `dev-c3040e79c7d8`, memory diagnostics0 and clean
source were verified FRESH before/after. Binary SHA-256:
`dc8b6f87ad881926c6caa4207ba8993c97d5c2589df8ba96555c35edfa2ba636`.
Actual compiler C SHA-256:
`5f8a3459a6d1224cedb962e0562ace0ada6b7f0e12c2e2f8066f5be947502bc6`.
That binary is unchanged but STALE after lexical integration and at root `dd23675b7`;
no FRESH current-source build or full quality/broad/fixpoint proof is claimed.

| Boundary | Accepted scope and remaining work |
| --- | --- |
| Static producer foundation | Shared guarded source-candidate loop, prepared builtin registry and issuer/module-validated trait context; independent frozen foundation proof is retained in [DESIGN](union_caller_evidence/DESIGN.md#successor-producer-foundation-checkpoint-not-recursive-closure). Recursive proof selection remains open. |
| Lexical callable-bound slots | Exact issuer/active-callable ownership, one shared opaque owner, normalized effective parameters and separate implementation-method projection. [Independent report](/tmp/blorp-lexical-independent.zgiiCa/REPORT.md), SHA-256 `90d5b19796ea6aac215123555b111c6495d7214aeaaf306d1aaa187363d025f7`: 244/244 focused owner cases; selected suites 294/294 plus one actual Python test, selector verdict 295/295. Counts overlap. Five tested inputs stayed frozen; [DESIGN](union_caller_evidence/DESIGN.md#lexical-callable-bound-slot-checkpoint-not-recursive-selection) hash is `1d2fc8b4ece344b51a7a78d4810eab191234df8264039935d04ccd9b308acd2e`. No recursive/inference/Core/CTFE or all-trait closure. |
| Recursive/supertrait source products | Independent static review reports zero findings; 25/25 owner cases and 626 distinct selected cases pass. Source-only candidate on `codex/union-evidence-producer`, base `680a75859`, remains unintegrated. No downstream transport, builtin capabilities or executable templates. |
| Native preparation and repairs | Frozen 41-file `codex/union-native-current` candidate, based on `3c3383357`; broad A evidence is green, but B2 resource-guard defects and baseline-reproduced TCP ownership leakage remain unresolved. Separate repairs below are unintegrated; failures are not waived. |
| Bootstrap and language | Inherited `dev-c3040e79c7d8` supports P1 syntax; common-trait/native capability closure remains pending. `fixed union` is an ordinary-union synonym with no checked guarantee; `enum` remains. Release, pin rotation and publication require separate user authorization. |

The merged-root and lexical candidate emit byte-identical complete small-program C:
`3f4e7cf0fbabc5459ba7802a4fc5cb69a20d0699e4c19991f19dcf374cce4abe`.
This is a same-absolute-input/Stdlib stability control, not a performance result.
The lexical report separately identifies actual invoked executables; recorder
cwd-local binary metadata does not substitute for their provenance.

Earlier native author checkpoint: [report](/tmp/union-native-current-abi.5Lfa9S/REPORT.md),
SHA-256 `9d73fc52412e237ce6b7d97cd23b0ce1a22c217f2c343a65020bbc369a3939fd`.
The separate 3c-based candidate was built FRESH O2; binary SHA-256
`6c2ffd352a0b24ae31cde81f26959ce375f09a68757154b8cd02105eef017e4e`.
Author checks pass candidates/headers 75/75 and physical/source owners 579/579
(CType20, JSON146, match37, raw emitter365, actual-source compilation11).
All eight original same-absolute-input control/reordered-Stdlib commands exit0;
all four runs have zero leaked objects/bytes. These are author checks, not
independent acceptance, and counts overlap with later broad gates. The old
632-case proof remains historical at `00c9`; it is not current validation.
Later frozen broad A evidence does not close the B2 resource/TCP failures.
Actual stage2/fixpoint, admission and independent final aggregate acceptance remain
pending; the candidate's binary hash and 3c source epoch above remain distinct
from the repair hosts below.
The admitted ordinary target `Bool` already loses nominal identity before the
backend: baseline emits invalid C, candidate fails closed. Its regression does
not establish support for all target namesakes; identity repair is separate work
and excluded from the native authority slice; no complete identity repair is claimed.
No native/P2a completion is claimed.

Source-only recursive producer: local packets `/tmp/blorp-trait-green.8JdigJ`
and `/tmp/blorp-trait-manifest-green.OxkPg7` retain 25 actual owner cases and 626
distinct selected cases. The repeated 25-case leak run is not added to 626. An actual public,
admitted diamond regression changed 24/25 RED to 25/25 GREEN. The source-product
rule prefers an exact own override; equal full parent targets merge, while
different targets return actionable `Err`. Current language admission is unchanged
until transport is wired. Frozen SHA-256 values: producer
`8ae660ece67a16767b4a8be12ae5d003c2b89bf19802e7b7cbbe67f36d67ce71`, authority
`f01955f4e3f1056d247ded3cc4f4e1e924cc9795d16adc85d3e100a5e56f0191`, test
`d4cc5594a751d417771f15ab2bd143678a16803d09a1d5b5bc4138e060c3056f`.
Actual invoked external host was constructor repair binary
`1a2afd9a0e5393901191f2a2399d5004dd2a62751b909d9fee14b4b9efcce0ca`, with explicit
producer Stdlib. Recorder cwd-local metadata names
`c6ad20b238f2c7b39eabf445ef55c32cf41fb22fe69fb6c0292a2d1cd40a3b59`; it is not the
invoked host. This publishes static proof only, not executable inference/Core/CTFE
transport or completed all-trait/common Eq/Hash behavior.

Resource guards: `/tmp/union-resource-independent-freeze/summary.md` records the
five-file `codex/union-resource-boundary` candidate at base `dd23675b7`, diff SHA-256
`fc80f26e9be96ecc1d4a5954db6631f1efc3c72e03f76474109130652b122a24`.
Four actual negative assertions were RED before repair; independent selected
635/635, nine exact diagnostic/help pins, body metrics 1/1 and CTFE 58/58 are GREEN.
Counts overlap.
Matched cost work is complete and accepted within the frozen two-workload,
O0 diagnostic-worker (`memoryDiagnostics1`) scope. Local report
`/tmp/resource-guard-cost.2QfKDU/REPORT.md`, SHA-256
`3f38ace99dd881d61d7eef7f2e34a86e990ab48dd09ebb1980d5f5c0152a6c9d`, records common
Stdlib and 35 ordered artifacts per request, byte-identical responses and empty
errors in every run. Heavy graph has 113 actual typed-body matches, including
64 in root. Four alternating instruction pairs and two separate memory pairs
per workload show heavy minimum instructions +0.0055%, below sample spread;
no speedup, quiet latency or full-selfcompile claim follows. Heavy root adds
292 allocations and matching releases (4.5625 per root match); its distinct
whole-graph marker adds 623. Representative adds 341 whole-graph and 10 root
allocations/releases. Live objects, managed bytes and allocator bytes are
unchanged at these boundaries. The earlier setup failure from omitted ignored
inputs remains preserved: two frozen generated inputs were copied identically
into both archives, with no baseline production-code fix. These measurements
do not measure the shared corrected constructor host's own remap-product costs.

Constructor identity: `/tmp/blorp-nullary-independent.2G6Fln` and
`/tmp/blorp-nullary-identity.6IaE3Q` retain the frozen 13-file
`codex/union-nullary-identity` candidate at base `dd23675b7`. Independent focused
124/124, sanitizer 2410/2410, compiler 6637/6637, leak 1172/1172 and audit 229/229
pass; these counts overlap.
Independent fixpoint and retained stage-2 follow-up are now GREEN:
`/tmp/blorp-nullary-fixpoint.EVVrRO/REPORT.md` records all three compiler C outputs
at 76,582,076 bytes, SHA-256
`3fca91cb815d78b6fb05c15e4be5bc55bdbff2a85f562a4cdb95e2cf4fb2f8c3`;
separate stage-2/stage-3 `cmp` exits 0. Actual retained stage-2 focused tests pass
26 mono-data + 18 early-pipeline + 5 nullary-identity cases, 49 distinct;
strict missing/present runtime controls report respectively 3/3/0 and 6/6/0
allocations/releases/live objects, with zero leaked bytes. The stage-2 codegen
audit passes 229/229 using its actual positional compiler interface and `--jobs 1`.
All 13 frozen entries and source/test/Stdlib inventories remain identical
before/after, as do checkout host
`1a2afd9a0e5393901191f2a2399d5004dd2a62751b909d9fee14b4b9efcce0ca`, checkout compiler C
`529b8b8b16c1f0079d050c5915c8b5692bb6e360db6243d0e77484fea1f21c48` and retained stage-2
executable `3518ae4aae4d29cc06f2ce27a9cc7f94d1794430e22e20010767c78fa571f8eb`.
This is bounded self-hosted correctness evidence, not a measured
cost or integrated-root proof; the candidate remains unintegrated.

TCP opaque String alternative: isolated three-production-file candidate on
`fix/accepted-builtin-ownership`, base `dd23675b7`, removes three obsolete ABI
exception/storage entries. Local report
`/tmp/tcp-opaque-test-freeze.ue2Hhd/FOCUSED_NONFFI_RESULT.md` records actual FRESH O2
host `5bee7431edd10db1f8f7120293bdd5134b8c552169c6267c3cdfc219d8fd8e8a`, explicit own
Stdlib, source owners 42/42, 61/61 and 151/151, projection 12/12 and opaque-hash
17/17 leak cases GREEN. Owner18 actually executes 18/18 PASS with zero residual;
baseline18 executes ZERO
cases because of retained `#error` captures. Exactly one unchanged standalone
IPv4 run has 5 allocations/5 releases/0 live. Historical dc8 IPv4 5/4/1 is separate
failure evidence, not a matched performance comparison. Nine privacy pins match
observed diagnostics; six unobserved help predictions were removed, with no
production diagnostic improvement. Independent TCP owner/runtime evidence now
passes 364 distinct cases, including the original ten native owners (63 cases),
plus the unchanged IPv4 probe at 5 allocations/5 releases/0 live. Local reports:
`/tmp/tcp-independent.ipnIn0/REPORT.md`, SHA-256
`014037d7b024efa758d1c13511b8547021dfa75ea7acc7d41ca6e65b740d0f38`, and
`/tmp/tcp-independent.ipnIn0/RESUMED_NONFFI_REPORT.md`, SHA-256
`520d057a20fc502a128d2a1451bb26cb0190e4cb66092c15c5a9321facc96fe7`.
Resumed non-FFI inspection independently verifies the three qualified aliases,
selected IDs 912/915/918 and Core/C releases. Direct fixture expectations pass
11/12; the qualified foreign positive retains three actual defensive-copy errors,
an unresolved prerequisite rather than a waived or passing fixture. TCP fixpoint
and coherent aggregate acceptance remain pending; these results do not validate
the separate 41-file native candidate or solve general managed-builtin ownership.

The separate `codex/opaque-foreign-copy-admission` prerequisite, based on main
`9859898e0`, now uses its own FRESH host
`2ab4039023a480611938df31f7bcc33328054db740740f2fd33f7dc72ec4140f` and explicit own
Stdlib. Local `/tmp/opaque-foreign-copy-test-freeze.tkunWK/green-v7/PARTIAL_GREEN.md`
records 212 focused PASS: authority 8, declarations 197, Core FFI 4 and native
mutation/ownership 3, with strict zero live objects/bytes. V8's three clean
negative pins pass separately. Original build/probe setup failures remain
preserved. V10 now rejects the candidate as-is: three source checks and three
lower-only commands succeeded, with the first two root-shadow aliases selecting
correct copy kinds. The third imported TextBuffer=String under root String=Bytes
wrongly annotates `probe_mutate_string` with `default_copy_kind: bytes` instead of
String copy. Local safety stop:
`/tmp/opaque-foreign-copy-test-freeze.tkunWK/green-v10/CORE_SAFETY_STOP.md`;
actual lower artifact SHA-256
`aa45f5d21ee658a3ad5d712b0f93af1c3d0c070dd9ff6e1ee91558460746930f`.
The source accepted-alias query preserves the definition-owned terminal, but
Core's shared global alias target resolution rebinds primitive String through
the consumer root alias. Fourth probe, full C and native runtime are UNRUN;
all children ended. Independent source-derived diagnosis finds the header
distinction between declared versus prelude/intrinsic references erased to identical named String
representations in semantic/typed/Core consumers; alias-target facts or copy-kind
forwarding cannot repair helper literals, returns, binders and container storage,
so complete repair requires explicit primitive-versus-issued-nominal references
beyond the three source owners. That broader prerequisite is neither implemented
nor approved; temporary fail-closed shadow admission would narrow support and
requires a deliberate policy decision, with no such policy implemented or waived.
The 212 cases and
three clean negatives remain scoped GREEN evidence, not native acceptance or P2
completion. All candidates remain unintegrated and root remains STALE.

Historical executable fixture source in
`union_caller_evidence/fixtures/provider.brp` and
`fixed_union_selected_targets/fixtures/caller_diagnostic/{provider,auto_provider}.brp`
is mechanically migrated to the new spelling. These edited inputs no longer
recreate their recorded frozen source hashes; measurement records, manifests and
logs retain their original epochs unchanged.

The packets named above are local temporary artifacts, not claimed as retained
repository evidence. Common Eq/Hash, capability bootstrap, P2b/P2c conversion and
family deletion, and P3–P5 remain open. Repair gates do not complete P2; `enum`
remains supported and `fixed union` remains an ordinary synonym. String payload
rejection belongs only to the future P5 guarantee. No release, pin rotation or
publication is authorized.

## Historical integration build and quality checkpoint

Source: `00c9b28979f8adf95336d75c7d355ab7b4845be4`. O2 `make` and `make quality`
both exit0 under `scripts/with-build-lock`. Retained logs at
`/tmp/blorp-union-current-integration.VlCsnQ` (`build.log`, `build-status.log`,
`version.log`, `quality.log`) show FRESH, clean source, CLI/runtime O2, split8,
aarch64-apple-darwin, Apple clang21.0.0, compiled by `dev-c3040e79c7d8`.
Binary SHA-256: `2a60b44e6569177610ef29984f4b2a799c016f14b650414170cde9a7dbe3208a`.
Actual compiler C `blorp/build/_build/blorp-cli/blorp_cli_main.c` SHA-256:
`dd72e06e63304c192598fa83b3564274015e4f89587892e18cb3d398a8c0f10e`.
Broader integration gates were not completed at this historical epoch. The frozen
slice results below retain their own epochs; counts overlap and are not retested
current-source results.

| Boundary | Historical status and evidence |
| --- | --- |
| Bootstrap | `dev-c3040e79c7d8`, inherited from published main `ff4da4b31dc2f5e0e1b9425a2ac96c06f6399a63`, has P1 synonym/selected-source syntax. Local-host asset verification occurred during `make`; no all-platform/preview/package/self-host/fixpoint proof or release/pin action. Common-trait/native capability closure remains pending. |
| Preparatory owner API | Independently accepted locally in `2c8f7bb80` (source `4fec86c2b90d`): env40/40, catalog17/17, selected661/661, broad6601/6601; whole raw C identical. [Design and frozen evidence](union_caller_evidence/DESIGN.md#independent-validation-and-frozen-epoch), [independent report](/tmp/blorp-caller-independent.HODTxX/REPORT.md). Recursive evidence and transport remain open. |
| Tensor native projection | Accepted locally in root `00c9b2897` (source `80d568a`). Frozen `66944f3e9` proof: owners227/227, extras27/27, Core ASan2400/2400, four raw-C identities; neither canonical native authority nor retested integration proof. [Retained note](union_native_tensor_projection.md); evidence `/tmp/union-native-projection-independent.TND2tE`. |

## Historical published source and accepted local prerequisites

Published `d9c737a86c461ff998e50b418edc72966a810de0` implements the ordinary-union
`fixed union` synonym and selected-target prerequisites. Later `dde591ecd`
centralizes discovery keyword spelling in production parsers; `c3040e79c` updates
tooling. Historical evidence in the roadmap keeps its
original revisions, counts and binary hashes; it is not relabeled as current.

- `e20fe4cf9`: test-only timeout readiness. A controlled 100ms child startup
  delay makes the original exact-output oracle fail 1/1 on native macOS and
  Linux; this is not reproduction of the historical failure. The revised
  fixture uses bounded readiness before polling, retains the same 20ms lifetime
  and exact timeout/stdout/stderr assertions, and changes no runtime code.
  Author owning suites pass 35/35 on both platforms; independent native suites
  pass 72/72 (35 process-session, 20 process-command, 17 process). Independent
  review reports zero findings. Retained author source SHA-256:
  `a8d148c170ab63d372b18a17efef1dd43bd9cd6bb4897c33495d080a13c2b01d`.
  Evidence: `/tmp/blorp-union-timeout.Pdz1tP/REPORT.md` and
  `/tmp/blorp-union-timeout-independent.5bKDRZ`.
- `66944f3e9`: six-file explicit Int native-fixture preparation. Independent
  review reports zero blockers/should-fixes (nit fixed); foreign check 1,
  layout O0/O2, runtime branches 2 with zero leaks, generated-C warnings and
  full codegen audit 229/229 pass. The
  [native preparation note](union_native_preparation.md) retains exact contracts,
  source/binary provenance and limitations; independent artifacts are at
  `/tmp/union-native-independent.gIPE6O`. Canonical ABI authority and foreign
  admission are not implemented by these fixture adapters.

Historical full Linux premerge runtime validation failed at 4,692/4,693 before
the full gate was interrupted. Its cause remains unproven. The bounded timeout
results above do not establish a passing full Linux runtime or premerge aggregate.

## Remaining implementation boundary

The frozen caller-evidence baseline at `dde591ecd` retains 5 PASS / 5 FAIL, exposing
caller-private selection, List/Option forwarding and CTFE/runtime divergence.
Provider plain/List/Option and Selector/Stringable controls pass; importer
plain/List/Option and provider/importer CTFE agreement fail. The unchanged-base
packet `/tmp/blorp-caller-base.K7848U` retains statuses, separate output streams,
source/binary hashes, FRESH provenance and Core/C. Selector CTFE is explicitly
unsupported on the base, not a new regression. The preparatory owner API is now
accepted locally in its historical epoch; the successor static foundation and
lexical slots are accepted as recorded above. Recursive evidence selection,
downstream transport and common automatic Eq/Hash remain open. Caller-selected
evidence must close for all traits, including defaults/inheritance, CTFE and
generated callbacks, before automatic publication. Recursive proof production
and native preparation are active parallel streams; the transport seam has one
serial owner.

The inherited current bootstrap pin is recorded above; source `enum` and the
separate logical family remain. P2a common semantics/native authority/admission,
capability bootstrap, migration/family deletion, P3 closure, P4 representation
optimization and P5 enforcement remain open. Simplification precedes optimization
and checked enforcement. Direct or nested String payloads remain inadmissible
under the planned final fixed guarantee; the current synonym enforces none of
that guarantee. This checkpoint authorizes no release, pin rotation or push.
