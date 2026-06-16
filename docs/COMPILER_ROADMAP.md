# Compiler Roadmap

Status: active roadmap, reviewed 2026-06-12.

Use [ARCHITECTURE.md](ARCHITECTURE.md) for the live compiler pipeline and
[OWNERSHIP_MODEL.md](OWNERSHIP_MODEL.md) for the ownership ABI. This file tracks
the next compiler work that is still valuable enough to keep visible.

## Goals

- Represent semantic facts directly instead of recovering them from names,
  suffixes, optional payloads, or backend conventions.
- Keep phase boundaries clear: parser syntax in the parser, semantic decisions
  in inference/typecheck, representation decisions in Core, and C details in
  the backend/runtime boundary.
- Improve compiler-shaped runtime performance without weakening value semantics
  or deterministic ownership.
- Keep native boundaries auditable: runtime ABI, FFI metadata, generated C
  escaping, ownership contracts, and security gates should be explicit.

## Review Notes

No objection to the overall direction. The important correction from reviewing
the current code is that several roadmap concepts are already partially
implemented:

- Source-level call metadata exists in `Ast.resolved_call` and typed expression
  metadata.
- Core call identity already crosses lowering through `CKSelectedDirect` and
  `CKUser (name, def_id option)`.
- Final Core already rejects `CKUnknown` and `CKSelectedDirect`; the remaining
  work is to remove earlier fallback paths and make diagnostics/tools consume
  the resolved facts consistently.
- List producer handoff is already explicit in Core as `CListHandoff` with
  `BorrowFresh` and `ConsumeReuse`, and the runtime has matching handoff
  helpers. Reuse work should extend and measure this path, not rediscover reuse
  from arbitrary loops.
- The self-hosting path is active in `compiler/blorp`, especially the
  Blorp-authored emission renderers. Further migration should keep this small
  bridge-and-test pattern.

## Active Workstreams

### Semantic Call Identity

Current state:

- Typecheck/inference mints callable ids and attaches `resolved_call` metadata
  to calls when the source target is known.
- `Core_lower` lowers direct resolved calls as `CKSelectedDirect <id>` so Core
  can use the source-selected target before the canonical post-flatten name is
  available.
- `Core_resolve` promotes selected and name-based calls to `CKUser (name,
  Some def_id)` when it can prove the concrete target.
- `Core_emit` already prefers DefId-based C names, but still has a
  compatibility fallback for `CKUser (_, None)`.
- Purity analysis and `purify` already know how to read resolved call metadata,
  but still keep parse/env-based fallbacks for unresolved cases.

The transitional layers still let the source AST, typed AST, Core, and tooling
ask similar questions in different forms:

- Which callable does this bare, qualified, UFCS, trait, operator, or
  first-class call target?
- What purity does the selected callable have?
- Which source name should diagnostics and `purify` cite?
- Which Core function or impl method should codegen retain and emit?

Direction:

- Treat inference/typecheck as the source-level resolver.
- Carry stable callable identity through typed metadata where a call has a
  direct target.
- Keep closure and first-class calls explicit rather than pretending every call
  has a direct source declaration.
- Move `purify`, diagnostics, and Core lowering toward consuming typed
  resolution facts instead of re-resolving names.
- Shrink backend name lookup to cases that truly require backend knowledge.
- Treat `CKUser (_, None)`, UFCS `#<def_id>` suffix parsing, and name-only
  resolution as migration paths, not the desired steady state.

Implementation order:

1. Add focused compiler-unit coverage that counts or rejects newly introduced
   `CKUser (_, None)` in resolver paths that should have DefIds.
2. Tighten source-call coverage for bare, qualified, UFCS, overload-selected,
   constructor, trait, and closure calls so each case documents whether a
   concrete callable id should exist.
3. Move remaining diagnostic and `purify` call classification toward
   `resolved_call` first, with documented parse-only fallbacks for files that
   cannot be typed.
4. Remove legacy UFCS DefId suffix handoff once resolved-call metadata covers
   the same call shapes.
5. Remove `CKUser (_, None)` emission fallback when tests prove all user calls
   reaching emit carry a DefId, except deliberately hand-built test Core.

Required checks:

- `Core_invariants` must keep rejecting `CKUnknown` and `CKSelectedDirect`
  after specialization and at the final emission boundary.
- A direct source call with typed `resolved_call` metadata must never lower as a
  purely unknown call target.
- UFCS and pure/impure overload resolution should select by callable identity,
  not by generated-name suffixes.
- Purity errors should cite the resolved target when one is known.

### Core Pipeline Maintainability

`compiler/lib/core_pipeline.ml` and `compiler/lib/core_stage.ml` are the source
of truth for pass order. Roadmap work should avoid duplicating that order in
new long-form docs.

Current priorities:

- Keep `Core_dce` conservative and identity-based. It already prunes concrete
  unreachable functions, impl methods, empty impl blocks, non-runtime generic
  templates after monomorphization, and source-only declarations whose runtime
  artifacts are represented explicitly enough.
- Add new DCE only when the dependency edge is explicit. If in doubt, retain.
- Split or instrument large aggregate stages before guessing where compile time
  is going. The `Fusion` stage currently represents several full-program
  traversals.
- Avoid handwritten runtime ABI string maps when a typed operation manifest or
  intrinsic contract can represent the boundary.
- Keep final Core invariant checks focused on facts that must never reach C
  emission: unresolved calls, unconverted closure/concurrency forms, invalid
  ownership crossings, and unprepared erased storage.

### Compile-Time Evaluation Architecture

`compile_time:` is an explicit request to evaluate already-validated pure Blorp
code in a restricted compiler execution environment, then serialize the result
as ordinary immutable global data. The feature should not grow into a second
frontend, typechecker, standard library, or backend.

Direction:

- Keep the surface narrow: top-level `compile_time:` blocks, immutable value
  bindings only, source-order dependencies, purity required, no type generation,
  no macros, and no expression-level form until the architecture is stable.
- Reuse the normal parser, name resolution, type inference, purity checks, and
  runtime materialization path. CTFE should consume those facts, not recompute
  them from source names or expression shapes.
- Evaluate a small CTFE IR derived mechanically from typed AST. Full Core is
  still broader than CTFE needs today, but the evaluator should consume a
  lowered, explicit representation instead of matching directly on typed AST
  expression shapes.
- Put compiler-owned std/builtin behavior behind a CTFE intrinsic registry. Each
  supported operation should have one narrow entry describing the runtime
  builtin/source identity, determinism requirement, evaluator, and unsupported
  reason when relevant.
- Keep evaluator code responsible for control flow, local bindings, function
  calls, closures, pattern decisions, and constructed values. It should not
  keep accumulating one-off std module semantics.
- Dogfood after the architecture boundary is in place. The intrinsic renderer is
  a useful acceptance test, but it should not force ad hoc CTFE support.

Current checkpoint:

- CTFE has a narrow public boundary in `compiler/lib/ctfe.mli`: external
  compiler phases provide constructor metadata and call `evaluate_program`.
- Compile-time-required bindings are explicit in the typed representation.
- `Ctfe_ir` is the chosen evaluator boundary for expression execution. Top-level
  compile-time binding initializers and called function bodies are translated
  into this smaller representation before evaluation.
- CTFE function values wrap typed functions with lazy cached IR bodies, so
  unsupported function bodies are still rejected only when compile-time
  evaluation actually calls them.
- Intrinsic source classification is centralized in `Ctfe_intrinsic`; supported
  imported, builtin, and trait std behavior is isolated in `Ctfe_std_eval`
  instead of mixed into the main evaluator.
- CTFE value-construction helpers and std evaluators consume `Ctfe_ir` call
  sites, keeping typed-expression location/type access inside the IR translator.
- `Ctfe_ir` classifies resolved calls into CTFE call kinds, including local,
  imported, builtin, constructor, trait, closure, and unresolved calls. The
  evaluator dispatches on those explicit variants instead of re-decoding raw
  call-resolution metadata.
- `Ctfe_ir` also classifies identifier function references, so named callbacks
  are explicit local-function references, unsupported references, impure
  references, or ordinary value identifiers before evaluation.
- `Ctfe_ir` classifies nullary constructor identifiers with constructor
  metadata before evaluation; the evaluator still checks local bindings first,
  preserving normal shadowing while avoiding name-based constructor guessing in
  the execution loop.
- Empty dict literals are normalized to `Ctfe_ir.Dict []` during translation
  using the typed expression type, rather than making the evaluator treat an
  empty record-shaped literal as a possible dictionary.
- Field access is classified in `Ctfe_ir` as record, tuple-index, range-start,
  range-end, or explicit invalid tuple/range access, so the evaluator no longer
  parses tuple indexes or decodes range field names while executing values.
- `Ctfe_ir` stores source AST only where materialization still needs it:
  constructor calls retain the callee AST narrowly so evaluated constructors can
  be rewritten as ordinary source-level constructor initializers.
- Raw call-resolution metadata is not carried on every CTFE expression;
  constructor calls retain the resolved-call payload narrowly because
  materialization uses it to rebuild ordinary constructor initializers.
- CTFE constructor values carry explicit constructor identity and
  materialization origin, rather than optional callee/resolved-call/constructor
  metadata with hidden coupling.
- The main evaluator consumes `Ctfe_ir` for expression/control-flow/call
  evaluation and keeps top-level compile-time block expansion separate.
- Codegen audit coverage now checks that CTFE-only builder functions are absent
  from generated C for both scalar constants and heap-shaped list/dict/record/
  union materialized data.
- Private compile-time-only intermediate bindings are evaluated and validated
  for materializability, but omitted from generated runtime globals unless
  ordinary code references them.
- CTFE supports the core deterministic byte-string helpers used by std/string,
  including slicing, trimming, search, byte access, reversal, counting, repeat,
  split, replace, and Char/list conversion helpers.

Next steps:

- Keep moving semantic normalization out of the evaluator and into `Ctfe_ir`
  translation where it can be represented explicitly.
- Add new CTFE surface area only after deciding the IR node and intrinsic
  contract it belongs to.
- Avoid broad Core reuse unless a later CTFE feature needs a Core-only fact.

### Core Pipeline Profiling And Invariants

Implementation order:

1. Measure pass-group time before splitting a stage. `Core_profile` can already
   report observed Core stages; use it before optimizing aggregate stages.
2. Split the `Fusion` observed stage only if measurements show that string,
   collection, tensor, or tuple SROA work needs independent visibility.
3. Keep non-observed safety/finalization passes (`Core_resource`,
   `Core_fairness`, `Core_codegen_prepare`, prepared reuse) out of
   `Core_stage` unless user-facing dump/stop/profile behavior genuinely needs
   them.
4. When adding new IR checks, prefer a named invariant in
   `core_invariants.ml` over local assertions in emit.

### Ownership And Reuse Performance

Self-hosting will stress compiler-shaped data: AST construction, traversal,
rewriting, and destruction. The important performance gap is structural
allocation churn, not only atomic reference count overhead.

Current state:

- Perceus inserts explicit `CDup` and `CDrop` ownership operations before
  reuse.
- `Core_reuse` already upgrades explicit list producer handoffs from
  `BorrowFresh` to `ConsumeReuse` when it can consume the matching
  post-Perceus drop.
- `CListHandoff` carries the source/result variables, capacity, layout, result
  type, and forward-compacting write policy. Runtime helpers preserve source
  reads while allowing storage reuse when uniqueness and layout checks pass.
- Compiler benchmarks now include `compiler_ast`, `compiler_symbols`, and
  `compiler_emit`, which are the right pressure tests for self-hosting.

Most promising path:

1. Make managed allocation sites visible before reuse without tying the fact to
   one C representation.
2. Specialize narrow consuming-call patterns where an owned argument is dead
   immediately after the call.
3. Add owned match and field-move semantics for values that can be safely
   destructured without retaining every payload.
4. Reuse union and record allocations only when type, layout, and liveness facts
   are explicit.
5. Consider compact scalar union variants after the ownership model can prove
   the representation is safe.

Rules:

- Reuse must be a proven optimization, not a semantic distinction.
- If a candidate might be observed again, allocate a fresh value.
- Resource scopes, cancellation cleanup, and external capabilities are reuse
  barriers unless a later pass has explicit facts that make reuse safe.
- Every ownership optimization needs leak-check and generated-C inspection for
  success, early return, and error paths.

Implementation order:

1. Establish baseline numbers for `compiler_ast`, `compiler_symbols`, and
   `compiler_emit` with `BENCH_RUNS` high enough to smooth noise, plus Blorp
   allocation counters where applicable.
2. Use generated Core and generated C inspection to identify which allocations
   are still unavoidable versus missing reuse facts.
3. Extend explicit producer handoff only where the Core node can state the
   collection family, layout, source/result element ownership, capacity bound,
   and write-order policy.
4. Prefer targeted handoffs for common compiler-shaped operations over a
   general loop-reuse recognizer.
5. Add regression tests at the ownership boundary: no reuse with later source
   use, no reuse across closures/tasks/resources, no wrong destructor reuse,
   and no leak on early return or branchy producer bodies.

Do not optimize by making public borrow-preserving APIs secretly consume their
receiver. Public API semantics stay simple; compiler-selected reuse remains an
explicit internal Core boundary.

### Self-Hosting Slices

Current state:

- `compiler/blorp` contains Blorp-authored renderer programs for several
  emission-template families.
- OCaml still owns Core traversal, C escaping, and backend context management.
  The Blorp programs own narrow template/manifest generation slices with tests.
- `compiler/test/test_compiler_blorp.ml` checks renderer compilation,
  generated-template drift, and `compiler/blorp` TestSuite files.

Direction:

- Migrate small compiler leaves first: pure rendering, manifest generation,
  source-to-source helpers, and deterministic transformations with compact
  input/output contracts.
- Keep bridges explicit. A migrated slice should have a stable CLI or function
  boundary, golden output, and a narrow OCaml integration point.
- Avoid moving semantic compiler decisions into Blorp code before the
  corresponding typed/Core facts are explicit enough for generated code to use
  correctly.

Implementation order:

1. Continue with emission-template and prepared-Core rendering slices because
   they have small boundaries and strong output tests.
2. Move helper logic only after there is a direct drift test proving the Blorp
   output matches the current OCaml-owned artifact.
3. Use the compiler benchmarks to track whether each migration increases AST,
   symbol-table, or output-construction pressure.
4. Treat any self-hosted code that needs workarounds for missing language
   features as feedback for language/runtime priorities, not as an excuse to
   encode compiler hacks.

### Native Boundary And Security

The active security focus is not a sandbox. It is hardening the compiler-owned
native boundary:

- runtime C memory safety;
- OS C-string conversion and embedded-NUL rejection;
- cryptographic randomness and hash seeding;
- FFI metadata validation;
- generated C escaping and name hygiene;
- explicit ownership contracts for runtime builtins.

The narrow gate is:

```bash
make security-check
```

Keep this gate focused. Broad fuzzing, sandboxing, package trust, and capability
policy are separate projects unless they block the current native-boundary
invariants.

## Execution Rules

- Add a failing parser, typecheck, compiler-unit, runtime, leak, or codegen
  audit test before changing behavior.
- Update [GUIDE.md](GUIDE.md) and [GRAMMAR.md](GRAMMAR.md) in the same change
  when syntax, diagnostics, or user-facing behavior changes.
- Prefer explicit typed variants, phase-specific records, operation manifests,
  and Core nodes over booleans, string tags, nullable payloads, or comments that
  describe invariants the type system could carry.
- Re-measure performance claims with `benchmarks/bench.sh`, `--profile`,
  allocation/release counts, or generated C size as appropriate.
- For compiler-performance work, report the benchmark command, the machine
  controls that matter (`BENCH_RUNS`, `BENCH_ALLOC_STATS`, thread counts), and
  at least one before/after number.

## Near-Term Queue

1. Add resolver/emitter tests that make accidental `CKUser (_, None)` fallback
   visible for ordinary source calls.
2. Audit remaining UFCS DefId suffix paths and decide which source-call shapes
   still rely on them.
3. Baseline `compiler_ast`, `compiler_symbols`, and `compiler_emit` with timing
   and allocation counters before the next ownership optimization.
4. Inspect list-handoff generated Core/C for compiler-shaped list pipelines and
   identify the next narrow reuse case.
5. Continue self-hosting by migrating one more emission-template slice behind
   the existing generated-artifact drift tests.
6. Keep native-boundary hardening inside the existing security gate.
7. Delete compatibility helpers once production callers no longer need them,
   and keep hygiene tests narrow enough that they catch real regressions.
