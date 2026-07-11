# Late-Core Ownership Stabilization Roadmap

Status: revised on 2026-07-10 after implementation and sanitizer probing.

This roadmap replaces the earlier compiler-wide cloning plan. That plan mixed
three different jobs:

1. fixing two concrete late-Core ownership failures;
2. hardening every Blorp compiler stage under ASan;
3. removing the OCaml-to-Blorp Core handoff.

Those jobs have different boundaries and completion criteria. Treating them as
one project caused broad copy refactors, expensive rebuilds, and unrelated
pre-Core failures without moving the production boundary. This roadmap keeps
them separate.

## Immediate Objective

Produce one self-contained, mergeable checkpoint that makes the currently
implemented Core surface sanitizer-clean without changing Core semantics or
redesigning Blorp ownership generally.

The checkpoint must:

- fix the known Result `?=` Core-lowering use-after-free;
- fix the known nullable-Option tuple-preparation use-after-free;
- provide only the small, phase-neutral reconstruction helpers those fixes
  require;
- add a focused, uncached Core ASan gate;
- preserve normal Core JSON and generated-C behavior;
- pass the existing late-Core test surface under ASan;
- avoid unrelated pre-Core ownership work;
- avoid a call-contract representation change;
- avoid a pass-wide or JSON-round-trip clone.

When this checkpoint is complete, return immediately to the compiler migration
roadmap. Do not continue expanding ownership infrastructure without a concrete
production-path failure.

## Architectural Facts

### Current production handoff

OCaml currently owns Core through DCE. The default backend path then performs
one post-DCE JSON handoff to Blorp:

```text
OCaml lower -> debug -> desugar/SSA -> mono -> synth -> match
  -> trait resolve -> resolve -> std inline -> tailrec -> fusion
  -> specialize -> DCE
  -> Core JSON handoff
  -> Blorp consume specialize -> Perceus -> reuse -> closure
  -> resource -> fairness -> prepare -> prepared reuse -> C emission
```

Relevant entry points:

- `compiler/lib/core_pipeline.ml`
  - `post_dce_program_json`
  - `observe_blorp_tail_json`
  - `emit_via_c_backend`
- `compiler/lib/core_emit_blorp_c.ml`
  - temporary OCaml Core-to-JSON projection
- `compiler/blorp/src/stage_09_core/compiler_core_pipeline.brp`
  - `run_post_dce_tail`
  - `run_core_pipeline_stage`
- `compiler/blorp/src/stage_10_backend/compiler_core_emit.brp`

The Blorp tail order is already centralized. Do not add another handoff or
duplicate pass ordering while fixing ownership.

### What this checkpoint does not unlock by itself

Ownership stabilization does not make the post-DCE handoff deletable. Blorp
does not yet have production equivalents for every Core stage between lowering
and DCE. In particular, the complete debug, SSA, monomorphization, synthesis,
match compilation, resolution, inlining, tail-recursion, fusion,
specialization, and DCE sequence is not yet available as one authoritative
Blorp path.

Deleting `post_dce_program_json` or `core_emit_blorp_c.ml` before those stages
move would skip production transformations. That is not an acceptable bridge
cleanup.

The ownership checkpoint instead establishes a stable late-Core destination
for the next leftward boundary move.

## Ownership Rule For This Checkpoint

Use ownership-preserving reconstruction at concrete construction sites:

> When a transformation installs a managed input or extracted child into a new
> owning aggregate and the original owner remains live, reconstruct the value
> for the new position.

This is narrower than “deep-copy every Core value.” Blorp value semantics may
share immutable backing storage when ARC correctly retains it. The goal is not
pointer inequality. The goal is that every owner can be destroyed safely.

Required properties:

- input and output may remain live and be inspected together;
- input and output may be destroyed in either order;
- a binder and a reference do not depend on one unretained `CoreVar` record;
- multiple expression positions do not depend on one unretained recursive
  `CoreType` aggregate;
- a transformed node never returns an input union node unchanged when the
  caller will retain both trees;
- primitive values and enums are copied directly;
- strings may be assigned into a freshly reconstructed record and retained by
  normal value semantics; do not force string concatenation merely to obtain a
  different address.

This is compiler-internal discipline, not a user-visible language change.

## Scope Lock

### Included

- the two confirmed lower/prepare failures;
- `CoreVar`, `CoreType`, `CoreLiteral`, and `CoreSourceLoc` reconstruction;
- focused tests that keep original and reconstructed values live;
- focused Core ASan test orchestration;
- minimal cleanup necessary to keep one implementation of those four helpers;
- normal, leak, codegen, quality, and clean-build verification.

### Explicitly deferred

- an exhaustive `clone_core_expr` or `clone_core_program` framework;
- mechanical replacement of every `copy_*` helper in every Core pass;
- a left-to-right audit of every pass without an ASan failure;
- the unresolved/resolved `UserCall` contract redesign;
- pre-Core ASan failures in dimensions, CTFE, inference, or typecheck state;
- adding the broad compiler-owned ASan suite to premerge;
- deleting the post-DCE JSON handoff;
- changing source-language ownership or ARC semantics;
- serializing and decoding Core to manufacture copies;
- suppressing releases or accepting leaks.

### Stop condition

Stop ownership work when all focused Core suites pass together under ASan and
the merge gate below is clean. A broad compiler-owned ASan failure outside the
focused Core set is recorded separately and does not extend this checkpoint.

## Known Evidence

Before the current fixes:

- `test_compiler_core_lower.brp` failed under ASan in
  `test_lowers_question_bind_result_to_constructor_match` while destroying a
  recursively nested `CoreType`;
- `test_compiler_core_prepare.brp` failed under ASan in
  `test_prepare_converts_nullable_option_tuple_literal` while destroying a
  transformed `CoreExpr` child.

After the focused reconstruction changes:

- Core lower passed 60/60 under ASan;
- Core prepare passed 28/28 under ASan;
- consume specialization and Perceus passed 127/127 together under ASan;
- all 14 `test_compiler_core_*.brp` files passed 588/588 together under ASan.

A separate full `compiler/blorp/tests/` ASan run reached 1,240 passing tests
before reporting pre-Core failures. Those failures are listed in the backlog
at the end of this document and are not evidence that the late-Core checkpoint
failed.

### Bootstrap compatibility experiment

An older released compiler can reduce bootstrap cost only if it also accepts
the current language surface and ownership registry. Probing immutable dev
releases produced this matrix on macOS arm64:

| Bootstrap | Current source | Result |
|---|---|---|
| `dev-9f56c40d2b91` | `compiler_bridge_cli.brp` | Compiles in 5.98s with a 519 MB peak |
| `dev-9f56c40d2b91` | `compiler_cli_main.brp` | Fails: missing `blorp_process_run_inherit` ownership contract |
| `dev-9f56c40d2b91` | `test_compiler_core_lower.brp` | Fails: predates current typed match-expression behavior |
| pinned `dev-33e00c2b94df` | `compiler_cli_main.brp` | Fails on the same missing process ownership contract |
| `dev-fb008fe4ffb2` | `compiler_cli_main.brp` | Has the contract but grows to 6.85 GB; stopped before OOM |

Setting `BLORP_COMPILER_BRIDGE_BIN` to the old binary does not bypass current
compiler behavior during `make install`: it uses the old binary to build fresh
current-source bridge helpers. The typecheck helper then processes the full CLI
source graph and still exhibits the multi-gigabyte path.

Conclusion: do not repin to `dev-9f56c40d2b91`. It is useful only for narrow
source files that avoid newer syntax and contracts. Use the supported pinned
bootstrap path for correctness rather than hiding build problems behind an
incompatible binary.

### Current verification status

The narrow ownership implementation currently has the following evidence:

- clone, lower, and prepare pass 92/92 normally;
- all 14 focused Core files pass 588/588 under ASan and UBSan;
- the test-runner harness passes, including exact focused-gate arguments;
- `make quality` passes;
- formatter checks for the two new files and `git diff --check` pass.
- a clean `make install` completes in about 143 seconds with a 1.76 GB peak RSS.

The clean-build blocker was repeated graph preparation, not the bootstrap
binary. The typecheck bridge reparsed and finalized every imported module for
every streamed artifact. It now prepares each module once and reuses explicit
prepared-program and importable-module values. That exposed two real semantic
type ownership bugs, now fixed at parsed-type projection and unchanged
semantic-type transformation branches. The build recipe also stops on a failed
CLI compilation and publishes the binary and input hash atomically instead of
linking stale generated C.

The broader compiler-deep, runtime, and standard leak gates still must pass
before the combined branch is described as merge-ready. Current results are:

- fast compiler: 1,485/1,485 pass;
- compiler-deep: 94 pass and 98 fail on existing frontend-parity gaps;
- runtime: 4,107 pass with one direct failure plus combined-harness failures;
- leak: 28 pass and four fail.

Representative failures reproduce with the previous cached typecheck helper:
`dim_constant_fold.brp` reports the same tensor trait/bounds errors, and
`test_url.brp` returns the same status 106. These failures are not regressions
from prepared graph reuse, but they remain real migration debt and keep the
full merge gate red.

## Checkpoint A: Reduce The Current Diff To The Scope Lock

Goal: make the branch reviewable before adding more behavior.

### Keep

- `compiler/blorp/src/stage_09_core/compiler_core_clone.brp`, limited to:
  - `clone_core_var`;
  - `clone_core_type`;
  - `clone_core_literal`;
  - `clone_core_source_loc`;
- `compiler/blorp/tests/test_compiler_core_clone.brp`;
- the Result `?=` changes in
  `compiler/blorp/src/stage_08_core_lower/compiler_core_lower.brp`;
- the leaf and tuple changes in
  `compiler/blorp/src/stage_09_core/compiler_core_prepare.brp`;
- the focused sanitizer gate and its shell-harness regression;
- imports of the four canonical helpers where a retained ASan regression
  proves they are needed.

### Remove or defer from this checkpoint

- broad `copy_core_type`/`copy_core_var` call-site renames that produce review
  churn without fixing a failing test;
- whole-file formatter churn unrelated to the ownership hunks;
- unused clone-list wrappers;
- comments or APIs promising an exhaustive Core clone implementation;
- premerge wiring for the broad compiler-owned ASan run.

### Procedure

1. Inspect `git diff --stat` and `git diff --word-diff=plain` for each touched
   compiler file.
2. Classify every hunk as one of:
   - required by a reproduced ASan failure;
   - required test/gate support;
   - formatting-only;
   - mechanical cleanup without a failure.
3. Keep only the first two classes.
4. Re-run `rg` for newly unused helpers and imports.
5. Run `git diff --check`.

### Pitfalls

- Do not use a destructive worktree reset. The branch may contain user changes;
  reduce only known Codex-authored hunks.
- The current formatter can reorder and reflow an entire older file. A
  formatter-clean result is not worth hundreds of unrelated lines in this
  checkpoint. Format new files; keep edits in old files locally styled.
- A helper rename across hundreds of call sites is not “free cleanup.” It
  increases review cost and invalidates the self-hosted CLI build cache.

### Exit criteria

- every remaining compiler hunk has a named regression or gate purpose;
- no touched production file has broad formatting-only movement;
- no unused helper or import remains;
- the diff can be reviewed pass by pass without reconstructing mechanical
  rename history.

## Checkpoint B: Establish Two Sanitizer Scopes

Goal: distinguish the merge-blocking Core gate from broader diagnostic debt.

### B1. Focused Core gate

Add or retain a `compiler-core-sanitize` gate with an explicit file list. Do
not rely on a shell glob inside the long-term script because future files would
silently change the gate’s scope.

Required files:

```text
compiler/blorp/tests/test_compiler_core_clone.brp
compiler/blorp/tests/test_compiler_core_closure.brp
compiler/blorp/tests/test_compiler_core_consume_specialize.brp
compiler/blorp/tests/test_compiler_core_desugar.brp
compiler/blorp/tests/test_compiler_core_emit.brp
compiler/blorp/tests/test_compiler_core_emit_type_layout.brp
compiler/blorp/tests/test_compiler_core_fairness.brp
compiler/blorp/tests/test_compiler_core_json.brp
compiler/blorp/tests/test_compiler_core_lower.brp
compiler/blorp/tests/test_compiler_core_ownership.brp
compiler/blorp/tests/test_compiler_core_perceus.brp
compiler/blorp/tests/test_compiler_core_prepare.brp
compiler/blorp/tests/test_compiler_core_resource.brp
compiler/blorp/tests/test_compiler_core_reuse.brp
```

Invocation contract:

```bash
./blorp test --no-format --no-cache --sanitize -j 1 --timeout 60 \
  <explicit Core files>
```

Required behavior:

- `--no-cache` is mandatory;
- `--sanitize` is mandatory on Darwin and Linux for this non-fiber suite;
- `-j 1` is mandatory to keep diagnostics ordered and memory bounded;
- the gate reports the structured TestSuite count;
- a nonzero child status overrides a printed passing summary.

Add shell-harness assertions for the exact flags and gate label. Expose the
same command as `make compiler-core-sanitize-test`.

### B2. Broad diagnostic gate

`compiler-blorp-sanitize` may continue to run all of
`compiler/blorp/tests/`, but it is diagnostic until its pre-Core backlog is
separately closed.

Rules:

- do not include it in the default local gate;
- do not include it in premerge yet;
- do not weaken it to hide known failures;
- preserve logs when it is run;
- do not treat its failures as permission to expand this checkpoint.

### Pitfalls

- ASan disables normal result caching internally, but the command must still
  say `--no-cache` so the gate contract is explicit and regression-testable.
- Apple’s runtime-wide sanitizer gate uses UBSan because fibers switch stacks.
  That exception does not apply to compiler-owned Core suites.
- An ASan crash may print a partial “N passed, 0 failed” suite summary before
  returning 127. Trust the process status and sanitizer output, not only the
  test count.
- TestSuite files use a top-level `tests: TestSuite`. They must not define
  `func main`; the test runner intentionally rejects that shape.

### Exit criteria

- the focused gate passes 588 tests from one invocation;
- the shell harness proves flags and process-status handling;
- the broad gate remains clearly labeled diagnostic;
- no premerge configuration depends on a known-failing gate.

## Checkpoint C: Keep The Reconstruction API Minimal

Goal: centralize only the phase-neutral operations proven necessary.

File:

- `compiler/blorp/src/stage_09_core/compiler_core_clone.brp`

Public API for this checkpoint:

```text
clone_core_var(CoreVar) -> CoreVar
clone_core_type(CoreType) -> CoreType
clone_core_literal(CoreLiteral) -> CoreLiteral
clone_core_source_loc(CoreSourceLoc) -> CoreSourceLoc
```

Implementation requirements:

1. Reconstruct every variant of each imported union explicitly.
2. Recursively reconstruct nested `CoreType` arguments, tuple items, tensor
   element types, and tensor dimensions.
3. Reconstruct `KnownSourceLoc` and its span record field by field.
4. Reconstruct `CoreVar.def_id` as an `Option[Int]` value.
5. Do not import Perceus, traversal, preparation, lowering, or emission.
6. Do not add wildcard identity fallbacks.
7. Do not add `clone_core_expr`, `clone_core_decl`, or `clone_core_program`
   speculatively.

Tests:

- recursive `StackResultType` containing tuple, named, and tensor types;
- `CoreVar` with `Some(def_id)`;
- managed `StringLiteral`;
- known source location with a managed file name;
- synthetic source location;
- keep original and reconstructed values live, serialize/read both, and let
  both leave scope.

### Pitfalls

- “Clone” means independently ownable, not necessarily different backing
  addresses. Do not test pointer identity.
- Returning `args`, `dims`, or another managed list unchanged defeats the
  purpose. Rebuild the list with `map` where nested reconstruction is needed.
- Reconstructing a record with the same string field is valid if normal value
  semantics retain it. Do not allocate strings with `+ ""` or substring
  tricks.
- Record update syntax can preserve managed fields implicitly. Use explicit
  construction in this module.
- Keep this module below `compiler_core_json` in the dependency graph; a cycle
  would make the bootstrap path substantially harder to diagnose.

### Exit criteria

- clone tests pass normally and under ASan;
- matches are exhaustive;
- `rg` finds no wildcard return of the input in the module;
- only the four listed functions are public.

## Checkpoint D: Close Result `?=` Core Lowering

Goal: ensure every owning position in the generated match tree has valid
ownership while preserving exact Core semantics.

File:

- `compiler/blorp/src/stage_08_core_lower/compiler_core_lower.brp`

Functions to inspect and, where required, change:

- `core_carrier_success_type`;
- `core_carrier_failure_type`;
- `lower_question_bind_success_type`;
- `lower_question_bind_success_case`;
- `lower_question_bind_failure_case`;
- `builtin_core_call`;
- `carrier_failure_expr`;
- `lower_typed_question_bind`.

Required ownership positions:

1. The payload type extracted from `Option` or `Result` must be reconstructed
   before storage in a match binding.
2. The temporary `CoreVar` used by the `LetExpr` binder and `VarExpr`
   scrutinee must be reconstructed for the additional owner.
3. `rhs_type` must not be one unretained aggregate shared by the temporary
   reference, match cases, and enclosing `LetExpr`.
4. `block_type` must be valid in the failure constructor and match result.
5. A source location used by both a callee `VarExpr` and its `CallExpr` must be
   reconstructed for the additional owner.

Semantic constraints:

- preserve constructor names, accessors, tests, binding modes, release policy,
  and expression shape;
- do not change Option/Result layout selection;
- do not alter the encoded `UserCall` contract;
- do not add a pass-wide clone around `lower_typed_program`.

Tests:

```bash
./blorp test --no-format --no-cache -j 1 --timeout 60 \
  compiler/blorp/tests/test_compiler_core_lower.brp
./blorp test --no-format --no-cache --sanitize -j 1 --timeout 60 \
  compiler/blorp/tests/test_compiler_core_lower.brp
```

The existing Result `?=` test must still assert the expected
`constructor_match` JSON shape, not merely survive destruction.

### Pitfalls

- A child returned from `core_carrier_success_type` or
  `core_carrier_failure_type` is borrowed from the carrier aggregate. Storing
  it directly recreates the bug.
- `?=` cannot be introduced arbitrarily inside a nested `match` arm. If the
  enclosing expression is not recognized as returning `Result`, use an
  explicit `Ok`/`Err` match.
- Do not reconstruct a type once and then install that reconstructed value in
  several owning fields. Each additional owner needs its own reconstruction at
  the storage boundary.

### Exit criteria

- 60/60 lower tests pass normally and under ASan;
- Result `?=` retains the same Core JSON;
- no unrelated lowering function changes;
- generated source locations and variable identities remain semantically
  equal.

## Checkpoint E: Close Core Preparation Leaf Sharing

Goal: prevent preparation from returning input leaf nodes into a new tree while
the original tree remains live.

File:

- `compiler/blorp/src/stage_09_core/compiler_core_prepare.brp`

Functions to inspect and, where required, change:

- `prepare_expr`;
- `prepare_exprs`;
- `prepare_tuple_expr`;
- `prepare_union_construct`.

Required behavior:

1. Reconstruct unchanged leaf variants that can be retained by both trees:
   - `LiteralExpr`;
   - `VarExpr`;
   - `VoidExpr`;
   - `CooperativeCheckpointExpr`;
   - `BreakExpr`;
   - `ContinueExpr`.
2. When an Option constructor call becomes `UnionConstructExpr`, its result
   type and source location must be independently ownable.
3. When a tuple literal becomes `TupleConstructExpr`, the output type and
   location must be independently ownable.
4. The prepared callee discarded by constructor conversion must be safe to
   destroy while the input call still exists.

Do not mechanically reconstruct every `CoreExpr` variant. Existing transformed
variants already build new nodes, and the combined Core ASan gate is the
evidence for whether another site is needed.

Tests:

```bash
./blorp test --no-format --no-cache -j 1 --timeout 60 \
  compiler/blorp/tests/test_compiler_core_prepare.brp
./blorp test --no-format --no-cache --sanitize -j 1 --timeout 60 \
  compiler/blorp/tests/test_compiler_core_prepare.brp
```

### Pitfalls

- `return expr` in a transformation can be safe only when ownership is moved
  and the input owner does not remain live. That is not the contract of these
  tests.
- The tuple failure appears during destruction, after its semantic assertions
  pass. A normal TestSuite pass is therefore insufficient evidence.
- A temporary prepared list can own children that are later installed in a
  second aggregate. Keep the original and transformed programs live in tests.
- Do not “fix” the failure by skipping release bits or clearing ownership
  metadata. That changes generated-program semantics and leaks values.

### Exit criteria

- 28/28 prepare tests pass normally and under ASan;
- nullable Option tuple conversion retains its expected prepared form;
- release and retain masks are unchanged;
- no constructor conversion or tuple layout rule changes.

## Checkpoint F: Run A First-Failure-Only Core Loop

Goal: prove the complete focused Core surface is clean without starting a
speculative pass audit.

Procedure:

1. Run `make install` once.
2. Run `make compiler-core-sanitize-test` serially.
3. If it passes, stop modifying ownership code.
4. If it fails:
   - identify the first sanitizer stack;
   - run only the named TestSuite file;
   - reduce to the named test where the harness supports it;
   - add or strengthen one regression that keeps both owners live;
   - fix the narrow construction site;
   - rerun that file normally and under ASan;
   - rerun the focused gate once.
5. Do not fix the second failure until the first is independently understood.

Allowed expansion rule:

- add a clone helper only when the first failing construction site requires a
  phase-neutral value not covered by the four existing helpers;
- add only that helper and its exhaustive unit tests;
- do not preemptively add sibling clone families.

### Pitfalls

- Running multiple self-hosted compiler tests concurrently can compile the
  bridge helpers more than once and consume several gigabytes. Run one build
  or gate at a time.
- A direct standalone check of a large compiler module was observed above
  5 GB across the host and renderer processes. Prefer `make install` followed
  by focused TestSuite invocations.
- A stale root `./blorp` can disagree with current bridge JSON and report
  missing fields such as `consumed_args`. Rebuild before diagnosing source.
- Repeated stage-observation requests may run the Blorp tail once per requested
  snapshot. Do not use dump-heavy CLI commands as a performance baseline.

### Exit criteria

- one combined invocation passes all 588 focused Core tests under ASan;
- no implementation was added without a concrete failing trace;
- no pass-wide cloning or serialization was introduced;
- peak memory remains bounded enough to complete on the normal development
  machine.

## Checkpoint G: Merge Gate

Goal: prove the narrow checkpoint is production-ready and does not merely pass
its two regressions.

Run these commands serially, in this order:

```bash
make install
tests/test_scripts_test_harness.sh
make compiler-core-sanitize-test
scripts/test --serial compiler-deep
scripts/test --serial runtime leak
make quality
git diff --check
```

Then inspect:

```bash
git status --short
git diff --stat
git diff --word-diff=plain -- \
  compiler/blorp/src/stage_08_core_lower/compiler_core_lower.brp \
  compiler/blorp/src/stage_09_core/compiler_core_prepare.brp
```

Required review questions:

1. Does every production hunk correspond to a named ASan regression?
2. Is the Core JSON shape unchanged?
3. Did any release policy, retain mask, layout, constructor test, or call kind
   change?
4. Did formatting or renaming obscure the behavioral change?
5. Is the broad pre-Core ASan debt clearly excluded rather than hidden?
6. Are all test processes and bridge helpers gone after the gate?

### Failure policy

- Focused Core ASan failure: blocks merge and returns to checkpoint F.
- Normal Core/compiler failure: blocks merge; diagnose as semantic regression,
  not automatically as ownership.
- Leak regression: blocks merge; cloning may have accidentally over-retained.
- Quality failure: blocks merge.
- Broad `compiler-blorp-sanitize` pre-Core failure: record in the separate
  backlog; it does not reopen this checkpoint.
- Build-time regression above 10%: inspect for accidental broad cloning or
  formatter-triggered bootstrap invalidation before accepting.

### Commit shape

Prefer one self-contained implementation commit after the roadmap commit. The
implementation commit should contain:

- focused reconstruction helpers and tests;
- lower and prepare fixes;
- focused sanitizer gate and harness coverage;
- no known-failing premerge configuration;
- no promise of a later fix for correctness.

Do not split the helper from the only production fixes that justify it; an
intermediate commit with unused ownership infrastructure is harder to review
and revert.

### Exit criteria

- every required command passes;
- the focused Core gate reports 588 passing tests;
- no unrelated churn remains;
- the implementation is independently correct and mergeable.

## Checkpoint H: Resume Boundary Migration

Goal: leave ownership work and return to moving the Blorp production boundary.

### H1. Reconfirm the exact target boundary

Before deleting bridge code, inventory the authoritative implementation for
every stage in `compiler/lib/core_pipeline.ml`:

```text
lower, debug, desugar/SSA, mono, synth, match, trait resolve, resolve,
std inline, tailrec, fusion, specialize, DCE, consume specialize, Perceus,
reuse, closure, resource, fairness, prepare, emission
```

For each stage, record:

- authoritative production language: OCaml or Blorp;
- production entry point;
- Blorp parity TestSuite;
- OCaml test that can be deleted after the boundary moves;
- whether stage dumps/stops observe OCaml values or Blorp JSON.

### H2. Apply the bridge deletion rule

Delete `post_dce_program_json`, the relevant projection code in
`core_emit_blorp_c.ml`, or its bridge action only when no production stage on
the left still needs to send an OCaml `Core.core_program` to a Blorp stage on
the right.

If any stage from debug through DCE remains OCaml-authoritative, the post-DCE
handoff remains structurally necessary. Continue porting the next contiguous
left-side stage instead of disguising the handoff.

### H3. Keep one handoff during migration

While OCaml remains in the middle of the compilation pipeline:

- keep exactly one program-bearing handoff from OCaml back to Blorp;
- do not add per-pass bridge calls;
- stage observation may request JSON snapshots, but it must not become a
  second authoritative transformation path;
- pass ordering remains in one module for each side of the boundary.

### H4. Resume with the next missing production stage

Use `BLORP_COMPILER_PORT_ROADMAP.md` to select the next stage immediately left
of the current handoff. Port it with parity tests, move the boundary, switch
production, and delete its OCaml implementation/tests in the same checkpoint
when no other consumer remains.

Do not resume the `UserCall` contract redesign merely because it was next in an
older ownership plan. Resume it only when the next production stage requires
the distinction or a focused ownership/correctness test proves the current
state ambiguous.

### Exit criteria

- the ownership branch is merged before boundary work starts;
- the next boundary change has one named stage and one authoritative path;
- no bridge is deleted while it still carries an OCaml-owned stage result;
- no new bridge is introduced.

## Separate Pre-Core ASan Backlog

The broad compiler-owned ASan run exposed failures outside this checkpoint.
Track them separately, in production order:

1. `compiler_dim_solver`
   - monomial/canonical-list lifetime during solve and solve-diff;
   - observed from `test_compiler_dim_solver`, `test_compiler_context`, and
     dimension-constrained inference tests.
2. `compiler_ctfe_pattern`
   - binding a selected match-case payload into CTFE context;
   - observed from `test_compiler_ctfe_eval`.
3. `compiler_typecheck_state`
   - selective import bindings and constructor metadata;
   - observed from `test_compiler_typecheck_decl`.
4. `compiler_infer`
   - dimension-constraint checking paths that retain solver results;
   - observed from `test_compiler_infer`.

Backlog rules:

- reproduce each file individually before editing;
- do not assume all stacks share one root cause;
- do not fold these fixes into the late-Core merge checkpoint;
- add a broad compiler ASan premerge gate only after the full directory passes
  on Linux x86_64 and focused coverage passes on macOS arm64/Linux arm64.

## Gotcha Checklist

Before each implementation or test run, check:

- [ ] Root `./blorp` was rebuilt after bridge-schema changes.
- [ ] Only one self-hosted build/test process is running.
- [ ] ASan tests use `--no-cache` and `-j 1`.
- [ ] TestSuite files define top-level `tests`, not `main`.
- [ ] A transformed managed union is reconstructed rather than returned by
      identity while the input remains live.
- [ ] Extracted Option/Result/list children are reconstructed before storage.
- [ ] Each additional owning field receives its own reconstructed aggregate.
- [ ] Record updates do not silently preserve managed fields at clone sites.
- [ ] JSON equality is checked; pointer inequality is not.
- [ ] Release policies, masks, and call metadata are unchanged.
- [ ] The formatter did not rewrite unrelated portions of old compiler files.
- [ ] Child exit status is checked even if a partial TestSuite summary passed.
- [ ] No bridge/helper process remains after interruption or timeout.
- [ ] A broad pre-Core failure has not expanded the current scope.

## Completion Definition

This roadmap is complete when:

- the current diff is reduced to the scope lock;
- the four minimal reconstruction helpers are exhaustive and tested;
- Core lower passes 60/60 normally and under ASan;
- Core prepare passes 28/28 normally and under ASan;
- all 14 focused Core files pass 588/588 together under ASan;
- compiler-deep, runtime, leak, quality, and diff hygiene gates pass;
- no unrelated formatting or mechanical rename churn remains;
- the broad pre-Core ASan debt is documented separately;
- work returns to the next contiguous compiler migration checkpoint rather
  than continuing speculative ownership infrastructure.
