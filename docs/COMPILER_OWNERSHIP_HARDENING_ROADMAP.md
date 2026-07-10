# Compiler Ownership Hardening Roadmap

Status: planned on 2026-07-10. This roadmap blocks further movement of the
production compiler boundary to the left of Core DCE.

## Decision

Until Blorp's general aggregate ownership analysis is stronger, compiler-owned
Blorp code will follow a stricter implementation discipline:

> A managed Core value must not be installed into more than one owning output
> position. Clone it for every additional owner, and clone transformed metadata
> rather than sharing it with the input tree.

This is a compiler-internal restriction, not a change to Blorp's language
semantics. Source-level assignment and aggregate construction still promise
value semantics. The restriction gives the self-hosted compiler a conservative,
reviewable implementation path while preserving those semantics.

The resulting work must be production-ready on its own. It must not disable
ARC, leak values, rely on a future call-contract change, or require a later
Perceus fix to be correct.

## Due Diligence Findings

### Production boundary

Normal compilation currently hands post-DCE Core from OCaml to Blorp. The
Blorp-owned tail runs, in order:

1. consume specialization;
2. Perceus;
3. post-Perceus reuse;
4. closure conversion;
5. resource lowering;
6. fairness insertion;
7. Core preparation;
8. prepared reuse;
9. C emission.

The ordering is centralized in
`compiler/blorp/src/stage_09_core/compiler_core_pipeline.brp`. The workaround
can therefore be audited by phase without adding another bridge or changing
pipeline order.

### Confirmed failures

The committed post-DCE boundary is not sanitizer-clean:

- `test_compiler_core_prepare.brp` has a heap-use-after-free in the nullable
  `Option[String]` tuple preparation case.
- `test_compiler_core_lower.brp` exits 118 in the Result `?=` lowering case;
  ASan identifies shared recursive `CoreType` storage.

A discarded prototype established that the workaround is viable:

- a complete call-contract prototype plus explicit copies made Core prepare
  pass 28/28 under ASan;
- explicit `CoreType`/`CoreVar` copies made Core lower pass 60/60 under ASan;
- the next ASan failure was another instance of the same pattern in Perceus
  function metadata, not a new representation or pipeline problem.

These results are diagnostic evidence only. None of the prototype source
changes remain in the worktree.

### Existing copy code

Copy logic already exists, but it is duplicated and incomplete:

- `compiler_core_perceus.brp` has private `copy_core_var`, `copy_core_type`,
  `copy_core_param`, and `copy_expr` helpers. It has roughly 300
  `copy_core_type` call sites.
- `compiler_core_consume_specialize.brp` independently implements the same
  families and has roughly 50 `copy_core_type` call sites.
- Perceus's `copy_expr` falls back to
  `CoreTraverse.map_core_expr_children`. That traversal maps child expressions
  but deliberately preserves types, variables, names, bindings, locations,
  call metadata, and other non-child fields.
- Consume specialization's `copy_expr` handles only a small subset of
  `CoreExpr` and returns the original expression for all other variants.
- Several helpers called `copy_strings` or `copy_ints` currently return the
  original list. They do not satisfy the no-sharing discipline.

Promoting either implementation would preserve the bug. The canonical clone
implementation must be built from the typed Core schema instead.

### Test coverage gap

All 72 files under `compiler/blorp/tests` are `TestSuite` files, but the normal
`compiler-deep` gate runs them without a sanitizer. `make test-asan` covers
runtime roots, not `compiler/blorp/tests`; on Darwin it also selects UBSan
instead of ASan for the fiber-heavy runtime suite.

The compiler-owned suites do not require the runtime fiber workaround. They
need a dedicated ASan invocation so a pass cannot appear correct merely because
the dangling value remains readable in an unsanitized run.

### Scope assessment

The path is substantial but straightforward:

- it adds no Core variants, runtime ABI, JSON bridge fields, or OCaml logic;
- the canonical clone module is mechanically derived from the closed Core
  schema and checked by exhaustive matching;
- only two production modules currently own competing copy implementations;
- eight ordered production pass boundaries require review;
- the principal uncertainty is clone-site coverage, which the dedicated ASan
  gate makes observable one failure at a time.

The largest change will be the exhaustive clone module. Its size is expected
because `CoreExpr` and its supporting records are large; its logic should remain
regular and phase-neutral.

## Scope

Included:

- canonical deep-clone operations for the Core JSON model;
- removal of duplicate and identity-returning compiler copy helpers;
- targeted clones at compiler transformation construction boundaries;
- ASan and leak gates for compiler-owned Blorp modules;
- a left-to-right audit from Core lowering through C emission;
- documentation of the temporary compiler discipline.

Excluded from this roadmap:

- changing user-visible value semantics;
- exposing clone APIs in `std`;
- resolving the `UserCall(..., consumed_args = [])` ambiguity;
- moving the production bridge farther left;
- serializing and decoding Core merely to break sharing;
- disabling releases, leaking input trees, or treating every call as consuming;
- redesigning Perceus's general alias provenance model.

The call-contract migration resumes only after this roadmap's exit gate passes.

## Required Invariants

### Output ownership

For every compiler transformation:

- the input and output may be destroyed in either order;
- two owning fields in the output must not depend on one unretained managed
  child;
- a borrowed child extracted from `CoreType`, `CoreExpr`, `Option`, `Result`, a
  record, tuple, union, or list must be cloned before storage;
- unchanged declarations and metadata copied into a new `CoreProgram` must be
  cloned, not returned directly;
- primitive fields and enums may be copied directly.

### Clone implementation

The canonical clone module must:

- allocate a distinct value for every managed occurrence;
- clone strings with an allocating string operation, except immortal empty
  strings;
- rebuild lists instead of returning the original list;
- recursively clone `Option` and every managed field in records and unions;
- use exhaustive matches without wildcard identity fallbacks;
- construct records explicitly rather than use record update when the record
  has managed fields;
- import the Core model but not Perceus, reuse, closure, prepare, or emission.

These constraints keep the dependency direction:

```text
compiler_core_json
        |
        v
compiler_core_clone
        |
        +--> core lower
        +--> consume specialization
        +--> Perceus
        +--> reuse / closure / resource / fairness / prepare
```

## Checkpoint 0: Freeze The Baseline

Goal: turn the two known crashes and the general sharing shape into stable,
focused regressions before refactoring copy code.

Files:

- `compiler/blorp/tests/test_compiler_core_prepare.brp`
- `compiler/blorp/tests/test_compiler_core_lower.brp`
- new `compiler/blorp/tests/test_compiler_core_clone.brp`
- `tests/test_blorp/memory/test_mutable_assignment_memory.brp`

Work:

1. Preserve the nullable-Option tuple and Result `?=` failures as named tests.
2. Add minimal compiler-shaped records that store one recursive managed value
   in two fields, including:
   - `CoreType` in two expression/binding positions;
   - one `CoreVar` in a binding and a reference;
   - one `String` in two function metadata fields;
   - one `List[CoreParam]` in two function-like records;
   - payloads extracted from `Option` and `Result` and then stored.
3. Keep both original and transformed values live, inspect both through JSON,
   and let both destruct at function exit. This catches input/output sharing as
   well as duplicate output ownership.
4. Add a small ordinary-language aggregate-sharing regression under
   `tests/test_blorp/memory`; this records that the workaround is compiler-only
   and must not weaken source value semantics.

Commands:

```bash
./blorp test --no-format --no-cache --sanitize -j 1 \
  compiler/blorp/tests/test_compiler_core_prepare.brp \
  compiler/blorp/tests/test_compiler_core_lower.brp
./blorp test --no-format --no-cache --leak-check --suite -j 1 \
  tests/test_blorp/memory/test_mutable_assignment_memory.brp
```

Exit criteria:

- failures reproduce deterministically before the implementation change;
- failure names identify the owning fields, not only the pass;
- no test depends on allocator reuse or timing.

## Checkpoint 1: Add A Compiler ASan Gate

Goal: make ownership safety observable during every following checkpoint.

Files:

- `scripts/test`
- `Makefile`
- `scripts/premerge-gate`
- `tests/test_scripts_test_harness.sh`
- `AGENTS.md`

Work:

1. Add a `compiler-blorp-sanitize` test gate that runs:

   ```bash
   ./blorp test --no-format --no-cache --sanitize -j 1 compiler/blorp/tests/
   ```

2. Keep the existing runtime sanitizer policy unchanged. The new gate uses
   ASan on Darwin because these compiler tests do not exercise the fiber paths
   that require UBSan-only runtime coverage there.
3. Add a `make compiler-blorp-sanitize-test` wrapper.
4. Add a focused sanitizer set for normal development:
   - Core clone;
   - Core lower;
   - consume specialization;
   - Perceus;
   - reuse;
   - closure;
   - prepare;
   - emit.
5. Run all 72 compiler-owned suites under ASan in the Linux premerge gate.
6. Keep the gate uncached. A cached normal result is not evidence for an ASan
   build.

Exit criteria:

- harness tests prove the new gate selects ASan and disables result caching;
- a known UAF produces a failed gate with the ASan excerpt;
- a passing run reports the actual TestSuite count rather than only process
  success.

## Checkpoint 2: Build The Canonical Core Clone Module

Goal: provide one exhaustive implementation that creates independently owned
Core values.

Files:

- new `compiler/blorp/src/stage_09_core/compiler_core_clone.brp`
- new `compiler/blorp/tests/test_compiler_core_clone.brp`
- `compiler/blorp/src/stage_09_core/compiler_core_json.brp` only if a narrowly
  useful type must be exposed; do not move clone policy into JSON encoding.

Public API:

```text
clone_core_var(CoreVar) -> CoreVar
clone_core_type(CoreType) -> CoreType
clone_core_param(CoreParam) -> CoreParam
clone_core_expr(CoreExpr) -> CoreExpr
clone_core_function(CoreFunction) -> CoreFunction
clone_core_global(CoreGlobal) -> CoreGlobal
clone_core_decl(CoreDecl) -> CoreDecl
clone_core_program(CoreProgram) -> CoreProgram
```

Private clone families must cover:

- strings, optional strings, integer and string lists;
- source spans and source locations;
- tensor dimensions and tensor type metadata;
- literals and call kinds;
- closure ABI and captures;
- tuple elements, boxed storage, list/tensor/hash-container metadata;
- record fields, union declarations, variants, and payload metadata;
- all loop, concurrency, select, resource, and tail-recursion records;
- literal and constructor decision-tree cases, fallbacks, bindings, tests, and
  accessors;
- every `CoreExpr` variant;
- every declaration and `CoreProgram.foreign_includes`.

Implementation rules:

1. Work directly from the unions and records in `compiler_core_json.brp`.
2. Use exhaustive matches. Do not add `_ : expr`, `_ : value`, or a
   `CoreTraverse.map_core_expr_children` fallback.
3. Reconstruct managed records field by field. Record update is allowed only
   for records proven to contain no managed fields.
4. Keep helpers private unless another pass needs that exact phase-neutral
   value.
5. Add JSON-equivalence tests: cloning may change addresses, never semantic
   Core content.
6. Add destruction tests where original and clone remain live and are read in
   both orders before scope exit.

Compile-time maintenance property:

- adding a new Core union variant must make `compiler_core_clone.brp` fail
  exhaustiveness checking until clone behavior is supplied;
- explicit record construction must make newly added managed fields visible at
  the clone site.

Exit criteria:

- clone tests pass normally, under ASan, and with leak checking;
- there are no wildcard identity fallbacks;
- a source audit finds no function in the clone module that returns its managed
  input unchanged.

## Checkpoint 3: Consolidate Existing Copy Implementations

Goal: remove conflicting definitions before applying the discipline elsewhere.

Files:

- `compiler_core_perceus.brp`
- `compiler_core_consume_specialize.brp`
- `test_compiler_core_perceus.brp`
- `test_compiler_core_consume_specialize.brp`

Work:

1. Replace Perceus's private `copy_core_*` and `copy_expr` families with
   `compiler_core_clone` calls.
2. Replace consume-specialization's duplicate families the same way.
3. Remove identity implementations of `copy_strings`, `copy_ints`, and the
   consume-specialization `_ : expr` fallback.
4. Do not alter consume-specialization eligibility or Perceus balancing logic
   in this checkpoint.
5. Compare representative Core JSON before and after consolidation to prove
   this is an ownership refactor, not an IR rewrite.

Exit criteria:

- `rg` finds one implementation of each Core clone operation;
- consume-specialization and Perceus suites retain their normal assertions;
- both suites pass under ASan and leak checking.

## Checkpoint 4: Fix The Confirmed Construction Sites

Goal: close the known prepare, lower, and function-metadata failures using the
canonical API.

### Core lowering

File: `compiler/blorp/src/stage_08_core_lower/compiler_core_lower.brp`

Functions:

- `core_carrier_success_type`
- `core_carrier_failure_type`
- `lower_question_bind_success_type`
- `lower_question_bind_success_case`
- `lower_question_bind_failure_case`
- `lower_typed_question_bind`
- `lower_tuple_destruct_bindings`

Required behavior:

- extracted `Option`/`Result` payload types become independent owned values;
- match binding types, temporary reference types, match result types, and
  enclosing `LetExpr` types each receive a valid owner;
- variables used in both a binder and a reference are cloned for the second
  position.

### Perceus function rewriting

File: `compiler/blorp/src/stage_09_core/compiler_core_perceus.brp`

Functions:

- `rewrite_function`
- `rewrite_global`
- `rewrite_decl`
- `insert_drops_program`

Required behavior:

- output function names, source modules, type parameters, parameters, return
  types, function kinds, locations, and foreign includes do not borrow storage
  from the input program;
- the rewritten body and copied function metadata are independently
  destructible;
- closure ABI metadata is cloned recursively.

### Core preparation

File: `compiler/blorp/src/stage_09_core/compiler_core_prepare.brp`

Functions:

- `prepare_expr`
- `prepare_exprs`
- `prepare_tuple_expr`
- `prepare_union_construct`
- `prepare_function`
- `prepare_decl`
- `prepare_program`

Required behavior:

- constructor-call children discarded during preparation are not still owned
  by the input tree;
- prepared tuple elements and nested nullable options have independent child
  ownership;
- unchanged declarations and foreign includes are cloned.

Exit criteria:

- Core prepare passes 28/28 under ASan;
- Core lower passes 60/60 under ASan;
- Perceus progresses past all previously observed metadata failures;
- the same suites pass under leak checking.

## Checkpoint 5: Audit Every Production Pass Left To Right

Goal: apply one mechanical review checklist to each remaining pass, without
changing pass semantics.

For each pass:

1. list every public transformation entry point;
2. identify fields copied from input into output;
3. identify locals installed in more than one output position;
4. clone every additional owning occurrence;
5. keep input and output live together in a focused test;
6. run normal, ASan, and leak modes before proceeding.

| Order | Module | Entry points and high-risk areas |
|---|---|---|
| 1 | `compiler_core_consume_specialize.brp` | `rewrite_program`; cloned functions, recursive call rewrites, constructor decision trees, clone candidate metadata |
| 2 | `compiler_core_perceus.brp` | `insert_drops_expr`, `insert_drops_program`; rewritten bodies, inserted `DupExpr`/`DropExpr`, mutable aliases, inferred contract maps |
| 3 | `compiler_core_reuse.brp` | `rewrite_post_perceus_program`, `rewrite_prepared_program`; source/reuse nodes, prepared union metadata, decision-tree branches |
| 4 | `compiler_core_closure.brp` | `convert_program`; hoisted functions, captures, closure ABI, task and concurrent bodies, captured name/type lists |
| 5 | `compiler_core_resource.brp` | `rewrite_resource_expr`, `rewrite_resource_program`; cleanup lists, scope bodies, resource variables and types |
| 6 | `compiler_core_fairness.brp` | `insert_cooperative_checkpoints_expr`, `insert_cooperative_checkpoints`; unchanged metadata around rewritten loop bodies |
| 7 | `compiler_core_prepare.brp` | `prepare_program`; boxed storage, tuple/union metadata, unchanged declarations |
| 8 | `compiler_core_emit.brp` | `emit_core_program_c_artifact_with_options`; verify emission only borrows final Core and does not construct persistent aliases |

Review checklist:

- no `return expr` or `_ : expr` in a function advertised as copying;
- no record update that silently preserves managed fields in clone code;
- no shared `CoreType`, `CoreVar`, `CoreParam`, bindings list, captures list,
  string, or source metadata across owning output fields;
- no unchanged declaration returned into a newly allocated program without a
  clone;
- no clone added to primitives or enums merely for symmetry;
- no ownership policy change hidden inside the copy cleanup.

Exit criteria per pass:

- focused TestSuite passes normally and under ASan;
- input/output destruction regression passes;
- generated Core JSON is semantically unchanged;
- leak count does not increase.

## Checkpoint 6: Full Compiler And Bootstrap Validation

Goal: prove the workaround holds when the compiler compiles compiler code, not
only isolated pass fixtures.

Commands:

```bash
make
./blorp test --no-format --no-cache --sanitize -j 1 compiler/blorp/tests/
scripts/test --serial compiler-deep
scripts/test --serial runtime leak
make quality
git diff --check
```

Add one scripted ASan CLI smoke:

1. compile `compiler/blorp/src/stage_12_cli/compiler_cli_main.brp` to C using the
   pinned bootstrap path used by `make`;
2. compile that generated C with ASan and UBSan;
3. run `--help`, `check`, `compile`, and one compiler-owned TestSuite through
   the sanitized CLI;
4. fail on sanitizer output, timeout, or a leaked helper process.

Platform coverage:

- macOS arm64: focused compiler-owned ASan suites and sanitized CLI smoke;
- Linux x86_64: all 72 compiler-owned ASan suites;
- Linux arm64: focused compiler-owned ASan suites plus normal full compiler
  gate.

Performance evidence:

- record a clean compiler CLI rebuild time before and after;
- record normal `compiler-deep` time before and after;
- investigate regressions above 10% before merging;
- do not replace targeted clones with pass-wide clone/serialize round trips to
  recover correctness at unacceptable compile-time cost.

Exit criteria:

- every command above passes from a cleanly rebuilt workspace;
- no compiler-owned ASan failure remains;
- no leak regression appears in resource, channel, task, mutable aggregate, or
  file-resource suites;
- no generated helper process survives its test;
- the public CLI remains the Blorp executable compiled by the pinned bootstrap.

## Checkpoint 7: Resume The Migration Boundary Work

Goal: restart ownership ABI work only after the conservative baseline is solid.

Work:

1. Reintroduce the phase-explicit unresolved/resolved user-call state described
   in `BLORP_COMPILER_PORT_ROADMAP.md`.
2. Make Perceus resolve the complete call contract once.
3. Make reuse, closure, and emission consume the resolved contract without
   independent fallback policies.
4. Re-run the complete validation matrix from checkpoint 6.

This checkpoint is not required for the no-sharing workaround to be correct or
mergeable. It is the next migration task after the workaround's exit gate.

## Review And Merge Strategy

Keep commits independently reviewable:

1. baseline regressions and sanitizer gate;
2. canonical clone module and clone tests;
3. Perceus/consume copy consolidation;
4. confirmed lower/prepare/Perceus fixes;
5. one commit per audited production pass when changes are nontrivial;
6. full bootstrap validation and documentation.

Do not combine call-contract representation changes with these commits. A
failure should be attributable either to clone coverage or to one pass audit.

## Risks And Mitigations

### Clone coverage drifts with Core

Mitigation: exhaustive matches, explicit record construction, and no wildcard
identity fallback in `compiler_core_clone.brp`.

### Correctness is bought with excessive compile time

Mitigation: clone at additional ownership sites, not at every pass boundary;
measure clean CLI build and `compiler-deep`; reject JSON round-trip cloning.

### A helper named copy still returns an alias

Mitigation: remove duplicate helpers and audit for identity-returning
`copy_*`/`clone_*` functions. Reserve `clone` for fresh managed ownership.

### ASan only checks runtime tests

Mitigation: dedicated uncached compiler-owned ASan gate and sanitized full CLI
smoke.

### The workaround is mistaken for the language fix

Mitigation: keep it under `compiler/blorp`, document the restriction here and
in `OWNERSHIP_MODEL.md`, and retain ordinary-language value-semantics tests.

## Completion Definition

This roadmap is complete when:

- the compiler has one canonical exhaustive Core clone implementation;
- compiler passes follow the no-sharing discipline at every production
  transformation boundary;
- all compiler-owned TestSuites pass normally, under ASan, and where applicable
  under leak checking;
- the full Blorp CLI rebuild and sanitized self-compile smoke pass;
- runtime ownership/resource/concurrency leak suites remain clean;
- compile-time regression is measured and accepted;
- checkpoint 10 in `BLORP_COMPILER_PORT_ROADMAP.md` points to a clean ownership
  baseline from which call-contract work can resume.
