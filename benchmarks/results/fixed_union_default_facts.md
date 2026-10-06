# Default callable publication preparation

Status: publication assertion RED→GREEN; frozen declaration178/178, UFCS2/2,
selected244/244, CTFE191/191, broad12371/12371 PASS. UFCS actually folds37 and
preserves the issued runtime target; bare-call CTFE remains unsupported. Independent
code review (0 findings) and bounded test validation accept this cut. Local root
integration and combined audit/fixpoint proof are recorded below; no main integration,
release or bootstrap publication is claimed.
Base `41483b853db01e6021ed9d1fa245763387fece13`, branch
`codex/fixed-union-default-facts`, worktree
`<worktree:fixed-union-explicit-eq>`.

## Isolated baseline evidence

Artifact root: `/tmp/blorp-default-facts-red.MxG3sF/`.
Own-worktree `BLORP_CLI_C_OPTIMIZATION=-O2 make` succeeded (`build.log`).
`scripts/compiler-build-status` reports FRESH (`status.log`): O2/O2, split8,
Apple Clang21, diagnostics0, compiled by pinned `dev-d44472d3a5d0`.

Binary SHA256:
`efa7ed377c8a96bee6cf5ac81b1b8b2554f1f52fcd747080ef64ab3e27d9009b`.
Unmodified production `decl.brp` SHA256:
`d2575ddb3562402a4cb1485d0baea48ca4ed96299ef7c87652cc38210b4bed92`.
Declaration test SHA256:
`ac4b83d31836e122645e2b96327e274bb5cc059c5083a33474e9a46b3739c671`.

Exact command:

```sh
bin/blorp test --release --timeout 180 \
  blorp/test/compiler/stage_06_typecheck/test_typecheck_decl.brp
```

Observed result (`declaration-red.log`): 172/173 PASS, exit1. The original
170 checks pass. New controls are separate from the publication assertion:

- `[PASS] literal default setup materializes reserved body` (line100).
- `[FAIL] literal default publishes materialized callable facts` (line101).
- `[PASS] receiver template does not publish unmaterialized default` (line102).

The arbitrary custom `Marker.marker` default returns literal37; it is not
Equatable/not_equals and contains no nested trait call. An explicit `anchor`
method proves the accepted implementation projection is available. The setup
proves the default body already materializes under its reserved callable ID.
The receiver-template control retains implementation parameter T and the
explicit anchor but no materialized or published default. This is a clean
publication assertion failure, not parser/schema/setup failure.

## Implementation boundary

Publication must precede body inference. Reuse the actual existing normalized
receiver/body-materialization eligibility, then derive published method infos
and method IDs from the same ordered eligible header list. Do not introduce a
method-name whitelist, generic-declaration restriction, or another state column.

For defaults, use the owner-checked existing accepted signature factory and
synthetic source whose span is the implementation span. Validate read-only that
the existing reservation `(module, method name, implementation span)` equals
the already-issued default header callable ID. Do not mint or claim a new ID.
Retain implementation bounds on the instance and matching effective body
parameters, even if receiver canonicalization erases a variable. Default
method-only parameters remain distinct from implementation parameters.

The shared parsed-receiver calculation uses `canonical_annotation_type` followed
by `impl_normalize_receiver_type`, matching accepted and legacy body preparation.
The accepted record's existing resolved-header receiver is unchanged. An ordered
eligible header list omits only template defaults; broken concrete source/signature
or reservation facts remain preparation errors. Explicit methods retain their
existing claim path, while defaults only read their existing reservation.
Published default callable parameters are the implementation bounds followed by
method parameters, exactly like the materialized body's effective parameters.
Explicit-method publication keeps its existing method-only convention. The
erased-receiver control compares both written bound names and full identity-bearing
bound facts against the actual typed default; selection's instance bounds alone
are not a substitute for callable specialization metadata.

Candidate declaration checks compare published target, function signature, purity,
parameter names, resource policy, dimension/debug metadata to the actual typed
default. Malformed/impure unit controls assert diagnostic substrings; they do not
directly prove absence of an evaluable CTFE product. Controls cover two defaults at one implementation span,
same-name defaults at distinct implementation spans, explicit override priority,
malformed/impure body diagnostics, and alias-erased receiver parameters with retained
implementation/effective bounds. Candidate declaration checks pass all these
controls, including the erased-parameter identity facts. New-region formatting
is canonical; inherited whole-module debt remains. Independent acceptance is recorded below.

No nested concrete bare-call binder, CTFE/Core changes, automatic traits, aliases,
Hash, ABI/source migration, performance claim, or bootstrap publication is included.
The still-generic implementation-owner distinction requires separate reviewed
selection/provenance work before the later concrete binder can be admitted.

## Focused candidate checkpoint

Artifacts: `/tmp/blorp-default-facts-candidate.1x1Rnu/`.
Initial builds failed for added lambda-arm trailing commas (`build.log`) and a
missed `impl_decl` source-order use after removing the local (`build-2.log`).
Repairs remove invalid commas and read the same implementation source span
directly; ordering semantics are unchanged. `build-3.log` exits0; `status.log`
reports FRESH own-414-dirty O2/O2 with the baseline's pinned compiler/toolchain.

Production `decl.brp` SHA256:
`8af154b16eceae45ec64b6fa5ef84981e5b8eab4ecc0f49d19b5052a85929286`.
Candidate binary SHA256:
`8c745fb707fcb95a8fa8959d14158769f6dda04ad0150f8cf0cf26306a35b6d8`.
Declaration test SHA256:
`2ba57a516f2095947f96614547597796a196eea7cda185b304a21ab47c63a3e0`.
Declaration command above: **178/178 PASS**, exit0 (`declaration.log`).
Baseline was 172/173 with the isolated publication failure. Candidate adds five
controls and strengthens the distinct-span check; counts are not identical corpora.

## Standalone probes

The own-414 baseline executable is preserved as
`/tmp/blorp-default-facts-red.MxG3sF/baseline-blorp`, with the same
`efa7ed37...` SHA256 above. It is baseline-provenance, not FRESH for the
now-modified candidate sources. The retained standalone
[literal default probe](fixed_union_default_facts/literal_default_probe.brp)
imports only standard `test`, not the changed compiler subject. Its global
`marker(TOKEN)` and runtime wrapper both expect 37. Both binaries must consume
that exact same absolute source path.

Both binaries ran that exact absolute path with `test --timeout 180 --leak-check`.
First attempts included `main` in a TestSuite source and hit a harness rejection
(`probe-baseline.log`, `probe-candidate.log`). The fixture now omits main;
`literal_default_program.brp` at the candidate artifact root is a separate runnable
scratch copy for possible Core inspection, not a TestSuite input.

Actual baseline and candidate both exit1 before test execution with:
`compile-time constant evaluation does not support intrinsic function call 'marker' yet`
(`probe-baseline-2.log`, `probe-candidate-2.log`). No runtime/leak pass, selected-call
Core evidence, or actual literal-global folding is claimed. Jobs stopped and the
compiled token was released. No infer/binder/CTFE changes were made.
Corrected bare-call source SHA256:
`dfc258904e9e3b8b2f73bb6fe29d9f6ac2c9e672620ec952edfd94f8edbd83ac`.
Each exact diagnostic log has identical SHA256:
`5a8c46e22968bfa326e34de7808d11ee91cd386334ed89f4a0d86135bb4f7d59`.

A separate [UFCS probe](fixed_union_default_facts/literal_default_ufcs_probe.brp)
uses `TOKEN.marker()` and `value.marker()` without overwriting the bare-call repro.
It has no main. At that identical absolute source path, baseline exits1 with the
same unsupported intrinsic marker diagnostic (`ufcs-baseline.log`), while candidate
passes **2/2**, zero tracked leaked objects/bytes (`ufcs-candidate.log`). The final
3 allocations/3 releases interval is post-suite harness activity, not total cost.
Nested `not_equals` and bare-call folding remain outside this proof.
UFCS source SHA256:
`1f8cb518b96f7b39135877991f2146380ffd5b01619ac1d974bea6e5d03209d3`.

Both binaries also compile the identical retained runnable scratch source
`literal_default_ufcs_program.brp` with `--no-format --dump-core-after=lower`,
separate `--dump-core-file` and `-o` outputs. Baseline again exits1. Candidate
exits0: Core `FOLDED_MARKER` has `const=true`, literal Int37 initialization;
`runtime_marker` has a selected-trait call and callee ID123, exactly the materialized
Marker.marker body ID123 (impl-method origin, literal37 body). C has
`static long FOLDED_MARKER = 37L;`. This is actual folding, not runtime fallback.
Raw Core SHA256:
`9a79024d203b2d86cc4232ebb2cf986c3b283b8cf143ff8546cb09709824c816`.
Raw C SHA256:
`8442bf4329f556dd4aaa3636f27415db2e7ee8bd5ddb8251995a0c9afecf4e9e`.

## Initial selected gate blocker and diagnosis

Actual `BLORP_CLI_C_OPTIMIZATION=-O2 scripts/compiler-check --changed --base 41483b853`
selected six suites plus body-metrics, built successfully, then exited1 before
suite execution: `UnionLayout` is not exported by `headers/type_header_graph`.
The wrapper's failure count is not a compiler test pass count. Complete logs are
retained in `selected-gate-failure/` under the candidate artifact root.

Bounded diagnostic slot runs each identical owner source path with the retained414
baseline compiler and candidate compiler (subject sources unchanged between runs).
Five owners pass individually on both: accepted catalog4, body order32, bound graph23,
callable profile2, declaration178. The frontend declaration catalog profile owner
alone fails identically; baseline also fails the exact six-owner grouped command.
Per-owner logs are `diagnostic-{baseline,candidate}-<owner>.log`, plus
`diagnostic-baseline-six.log`. These are compiler-comparison diagnostics, not new
pristine-subject publication RED evidence: unit tests import the current subject.

Source-backed cause: that owner imports the frontend profile fixture, which imports
`blorp/benchmark/compiler/compiler_typecheck_phase_profile_fixture.brp`. Line209 of
the latter still imports `UnionLayout` from `headers/type_header_graph`. The exact
stale import is already present in `git show 41483b853:<fixture>` with no local diff;
the base's enum owner is now `type_system/union_layout`. This is a missed benchmark
consumer of the prior layout move, not grouped-name collision or publication
signature/resource metadata. No public re-export, fallback, or default suppression
is proposed. A separately authorized mechanical import relocation is required;
until the real gate passes this remains an acceptance blocker. All diagnostic jobs
stopped and the token was released; no extra source owner was edited.

## Separate root import preparation

Root authorized a one-file mechanical prep in the ROOT43a9 checkout only: remove
the benchmark helper's old headergraph import entry and import the same variants
from `type_system/union_layout`. No re-export, fallback, semantic change, or Git
mutation was made. Helper SHA256 after repair:
`5036749f547992026a61d7ea5ae8229d83540d70eaadea30cc0880d5ac97614c`.

Both retained414 baseline (`efa7ed37...`) and publication candidate (`8c745fb7...`)
run the exact absolute ROOT owner path
`<worktree:43a9>/blorp/test/compiler/stage_06_typecheck/test_frontend_declaration_catalog_profile_benchmark.brp`:
each **4/4 PASS**, exit0, no diagnostics (`root-import-prep-baseline.log`,
`root-import-prep-candidate.log`). Both read the same ROOT subjects at HEAD
`a1091fd135dc984a76881b1e6284a71ff5757e6d`; this is not a pristine414 subject
claim and the stale root binary is never used. Root independently reviewed/tested
and committed ONLY that import relocation as
`06618d7d712e21546c31023c19759fe00604a730`. Its authorized cherry-pick onto this
dirty publication branch is `2da40cc4925723ea509f4d85340e1a55ab48e079`, preserving
all declaration/test/evidence WIP. The later actual selected gate passes after this
prep; the initial failure logs remain intact. No publication feature commit was made.

## Final frozen candidate snapshot

HEAD `2da40cc4925723ea509f4d85340e1a55ab48e079`, dirty publication source/test edits.
O2 rebuild after bounded formatting exits0 (`build-final-format.log`);
`status-frozen.log` reports FRESH, self2da40-dirty, CLI/runtime O2/O2, split8,
Apple Clang21, diagnostics0, pinned compiler `dev-d44472d3a5d0`.

Final binary SHA256:
`ad2fd53b2d2b96380a04a5502f7b6813a98fe423a036ed46b13f0f24c590e123`.
Final production `decl.brp` SHA256:
`361f4b3df7dc7d04e8f1eab586a28623a74ae9e492fba0ce7f9e34812c5ee3a9`.
Final declaration test SHA256:
`7525eb8ac42a823f013ed8b3eeb20f8bf256ba32efd888ad3d0d796ac6bcdef2`.
Complete manifest: `final-manifest.log`; historical snapshots are retained separately.
Intermediate test SHA `e28f9a1a...` preceded one test-only canonical import repair
(generic_params import moved to multiline with trailing comma). Repeated selected244,
CTFE191, broad gates and final standalone178 all exercise final7525.

### Formatting scope

Full-file `format --check --diff` remains exit1 (`format-frozen.log`) from inherited
debt, not a claimed full pass. Full formatter scratch copies cover both entire files,
including lower helpers. Only new/changed code and new imports were reformatted.
`format/residual-exact-audit.log` verifies all10 source and113 test residual formatter
operations map to exact unchanged414 baseline locations AND equal corresponding
baseline formatter replacement bytes. This is not merely add/remove multiset equality.
Both retained probes pass `format --check` (`format-probes-frozen.log`).

### Actual final gates

```sh
BLORP_CLI_C_OPTIMIZATION=-O2 scripts/compiler-check --changed --base 41483b853
BLORP_CLI_C_OPTIMIZATION=-O2 scripts/compiler-check --stage ctfe
bin/blorp test --warmup-only
scripts/test --serial --no-build --log-dir /tmp/blorp-default-facts-candidate.1x1Rnu/gates compiler-blorp runtime leak
bin/blorp test --release --timeout 180 blorp/test/compiler/stage_06_typecheck/test_typecheck_decl.brp
bin/blorp test --timeout 180 --leak-check benchmarks/results/fixed_union_default_facts/literal_default_ufcs_probe.brp
```

- Selected244/244: six suites plus body-metrics special check, exit0
  (`compiler-check-frozen.log`). Earlier e28 iteration also passed244, but is not
  substituted for final7525. Successful compiler-check internal suite logs are
  removed by its harness; complete wrapper output and standalone owner logs remain.
- CTFE191/191: eleven suites plus dependency-demand special check, exit0
  (`ctfe-check-frozen.log`). Warmup exits0 (`warmup.log`).
- Broad compiler6528/6528 =5698 suite tests+830 production check fixtures;
  runtime4673/4673; leak1170/1170; combined12371/12371, exit0
  (`broad-gates.log`, full `gates/{compiler-blorp,runtime,leak}.log`). Standard
  maintained artifact flags are used; O2 describes the compiler build, not a claim
  that every test artifact was compiled with --release.
- Runtime/default controls22/22 with per-test leak checking, zero tracked leaks:
  UFCS2, default-method4, default-bodies4, generic-dispatch3, explicit equality9
  (`runtime-controls-final.log`).
- Final standalone declaration178/178 with --release (`declaration-frozen.log`).
- Final standalone UFCS2/2, zero tracked leaked objects/bytes (`ufcs-frozen.log`).
  Unchanged final bare probe exits1 with unsupported intrinsic marker
  (`bare-frozen.log`); no binder or CTFE workaround was applied.

Counts overlap; they are not unique coverage totals. Final UFCS Core/C regenerated
at the SAME retained runnable scratch source path are byte-identical to first proof:
Core SHA `9a79024d...`, C SHA `8442bf43...` (full hashes above). Global literal37 and
selected target/body ID123 remain unchanged. Raw files/manifests remain at the
artifact root. No codegen audit, sanitizer, stage2/fixpoint, or performance measurement
was attempted in this slot; passing gates do not imply those checks. All jobs stopped
and the compiled token was explicitly released. At that worker snapshot independent
code/test acceptance was still required; bare-call binding, nested not_equals folding, aliases, automatic
Eq/Hash, and enum conversion are not completed by this publication-only cut.

## Independent acceptance (pre-commit)

Independent report:
`/tmp/blorp-default-facts-candidate.1x1Rnu/independent/REPORT.md`.
The independent runner made no source edits or rebuilds: FRESH before/after,
O2/O2, pinned compiler/toolchain above, HEAD2da40-dirty, identical before/after
manifests for production361f, test7525, helper5036, candidate binad2 and probe1f8c
(full hashes above). Its exact declaration178/178 and candidate UFCS2/2 pass;
default/shadow controls12/12 pass with per-test leak checking, zero tracked leaks.
The trailing 3-allocation/3-release interval is not whole-suite allocation cost.

Retained414 baseline uses the SAME absolute UFCS test/compile input paths and
still rejects unsupported intrinsic marker. Independent Core confirms literal
constant37 plus selected/callee ID123 equals materialized default ID123; raw Core/C
hashes exactly match9a79024d/8442bf43 above. This proves actual UFCS folding, not
runtime fallback. Initial unsupported `test --no-format` attempts are retained as
harness setup failures only; valid reruns omit that flag. Unit malformed/impure
diagnostics do not directly establish CTFE-product absence.

Prior selected244, CTFE191 and broad12371 worker results were inspected, not
independently rerun wholesale; counts overlap and must not be aggregated as unique
coverage. Final source/evidence code review reports0 findings. This acceptance
does not close arbitrary bare-global/nested trait binding, generic selection,
automatic Eq/Hash, aliases or enum migration. Generated-C audit, sanitizer,
stage2/stage3 fixpoint and performance measurement remain unperformed, not implied
by acceptance. All independent jobs exited and its token was released. Historical
snapshots above remain pre-commit evidence; publication/root integration is separate.

## Combined local prerequisite validation

The publication cut is locally integrated at ROOT
`175a3821519ec6749f541933a72cf6fcb4e70590`, including scoped identity and the
separate import preparation. Independently reviewed report and complete logs:
`/tmp/blorp-default-facts-combined.B6X7p3/REPORT.md`. Initial/final status is FRESH;
CLI/runtime O2/O2, split 8, Apple Clang 21, pinned `dev-d44472d3a5d0`, diagnostics 0.
The unchanged root executable SHA256 is
`8d3a1be4ba3831484c2e15f4c6d926e0f8988c41e2dccfae63a4c2ab68ea25a6`.

Actual focused 630/630, selected 252/252, CTFE 191/191 and serial broad 12,385/12,385
pass; broad is compiler 6542 + runtime 4673 + leak 1170. Stage1/stage2 codegen
audits each pass 228/228; stage2 runtime controls pass 30/30 with per-test leak
checking. Suites overlap and are not unique coverage totals. The retained samepath
UFCS input proves literal 37 and selected/callee/materialized target 123 at both stages,
with raw Core/C identity
and hashes `9a79024d...` / `8442bf43...` unchanged from the full hashes above.
Harness-end 3 allocations/3 releases is not workload allocation cost.

The unmodified O2 fixpoint passes: stage1/2/3 raw C outputs each have SHA256
`f3b2da2f3af68f0ba5a796f964eebacc513722c40b55b9942cb38dbb8fdd6793`.
Stage2 executable SHA256:
`d5f5373c368f0f9453f0f0de5fb9afcc41ef0364bb885382ba96778a73221a1e`.
Raw logs, outputs and exact provenance remain under the report's artifact root.
This supersedes earlier omitted-audit/stage2/fixpoint limitations only for this
combined run; no sanitizer repeat or performance measurement is claimed.

The proof covers integrated preparation/publication, not the subsequent binder:
its separate baseline declared-body target test has 182 PASS / 1 FAIL, and standalone
CTFE still rejects intrinsic `equals`. Implementation is under focused review,
including purity refinement; no accepted/green binder or nested default folding
is claimed. Arbitrary bare-global classification, aliases/generic selection,
automatic Eq/Hash, source enum conversion, remaining native admission and checked
fixed payload enforcement remain open. No release, bootstrap publication or pin.
