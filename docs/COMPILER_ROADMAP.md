# Compiler Roadmap

Status: active roadmap, reviewed 2026-06-12.

Use [ARCHITECTURE.md](ARCHITECTURE.md) for the live compiler pipeline and
[OWNERSHIP_MODEL.md](OWNERSHIP_MODEL.md) for the ownership ABI. This file tracks
the next compiler work that is still valuable enough to keep visible.

Use [BLORP_COMPILER_PORT_ROADMAP.md](BLORP_COMPILER_PORT_ROADMAP.md) for the
detailed OCaml-to-Blorp port plan, including the single JSON transfer point,
incremental deletion merge points, and the expectation that compiler stage logic
is implemented as pure functions wherever possible.

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
- The self-hosting path is active in `compiler/blorp`: the supported backend
  route now owns a contiguous Core tail through resource cleanup rewriting,
  fairness checkpoint insertion, final-preparation subset, and C artifact
  emission subset. Further migration should expand that production path and
  delete the matching OCaml implementation, not add more optional renderer-only
  scaffolding.

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

### Compile-Time Constants And CTFE

Desired end state:

- Immutable top-level bindings are constants. `NAME = expr` means the compiler
  evaluates `expr` at compile time and materializes the result as ordinary
  immutable global data.
- There is no special `compile_time:` declaration form. The ordinary constant
  syntax is the CTFE surface.
- Mutable top-level `var` bindings are not constants. They must not hide runtime
  startup work before `main`.
- There is no expression-level CTFE form, no macros, no type generation, and no
  second compile-time standard library.

Source semantics:

- Top-level constants evaluate in source order.
- A constant may reference earlier constants and pure functions.
- A constant may not reference itself or a later constant. Report this as a
  dependency error, not as an evaluator accident.
- Constant initializers must be pure and CTFE-compatible. Unsupported pure
  operations are compile errors for constants, not runtime fallbacks.
- Called pure functions may use local mutation, loops, recursion, pattern
  matching, closures, and deterministic collection/tensor operations supported
  by CTFE.
- Visibility remains ordinary declaration visibility: `private NAME = expr`.
  There is no special block-level visibility.

Architecture:

- Reuse the normal parser, import loading, name resolution, type inference,
  purity checks, and runtime materialization path. CTFE consumes typed facts; it
  must not recover semantics from source spelling, generated names, or backend
  conventions.
- Run CTFE after typecheck/purity and before Core lowering. Core and codegen
  should see ordinary immutable global initializers after rewrite.
- Keep `compiler/lib/ctfe_ir.ml` as the evaluator boundary. Typed AST is still
  too broad for execution, while full Core is broader than CTFE currently
  needs.
- Keep compiler-owned std/builtin behavior behind `Ctfe_intrinsic` and
  `Ctfe_std_eval`. Each supported operation should have a named intrinsic
  identity and one evaluator entry.
- Keep top-level initializer policy centralized in
  `Top_level_initializer`: immutable constants require CTFE; mutable globals
  reject hidden startup calls.
- Prefer explicit CTFE value variants and IR call kinds over optional metadata
  with hidden coupling.

Current checkpoint:

- `Ctfe.evaluate_program` rewrites source-order immutable globals through one
  shared CTFE environment.
- Immutable globals are semantically required CTFE now; unsupported pure
  operations are compile errors instead of best-effort runtime fallbacks.
- Private constants referenced only by later constants are treated as CTFE
  scratch and can be omitted from generated runtime data.
- `Ctfe_ir` classifies expressions, function references, call kinds,
  constructors, field access, tuple/range access, vectors, lists, dicts,
  records, and control flow before evaluation.
- CTFE function values wrap typed functions with lazy cached IR bodies, so
  unsupported function bodies are rejected only when compile-time evaluation
  calls them.
- CTFE environments explicitly distinguish evaluated globals from the current
  global, later globals, runtime-initialized globals, and imported globals that
  are not compile-time constants. Dependency diagnostics are no longer lookup
  misses.
- Materialization rewrites evaluated scalar, string, tuple, list, vector, dict,
  record, range, and constructor values back into ordinary typed initializer
  expressions.
- CTFE supports enough deterministic std/builtin behavior for useful constants:
  string byte helpers, list/dict/option/result helpers, vector/tensor literals,
  tensor constructors, tensor subscript reads, tensor length, and matrix shape
  counts.
- Codegen audit coverage checks that CTFE-only builder functions are absent from
  generated C for materialized constants.
- `compiler/blorp/codegen_intrinsic_renderer.brp` now dogfoods ordinary
  top-level constants for derived intrinsic lookup/manifest data.
- Static emission currently supports strings, pointer-storage lists whose
  elements are supported static values, integer-like inline primitive literal
  lists, `List[Float]`, `List[Float32]`, `List[Float16]`, non-generic records,
  ordinary generic record/struct instantiations, and ordinary concrete generic
  union constants whose payloads are in the supported static-value subset. It
  also supports tuple constants whose pointer, primitive literal,
  floating-point literal, and void erased slots can be emitted as C static
  initializers, plus stack `Result` constants whose Ok/Err payload slot can use
  the same static boxed-slot subset.
  Ordinary generic unions now get concrete instantiated type identities, typed
  ordinary payload storage, source template pruning, and static emission for
  supported constant payloads.
- The old `compile_time:` parser, AST, formatter, LSP, typed AST, and CTFE
  block expansion paths have been removed.

Next implementation slices:

- Audit std, `compiler/blorp`, examples, and scratch programs for constants
  that still need CTFE support. Add narrow intrinsics or rewrite the constants;
  do not reintroduce best-effort runtime fallback.
- Extend static emission beyond the current string/list/tuple/record/union
  subset: inline-struct lists, tuple slots that require heap boxes,
  dicts/sets, tensors, and erased dynamic-boundary values where there is an
  explicit typed bridge.
- Keep moving semantic normalization out of the evaluator and into `Ctfe_ir`
  translation where it can be represented explicitly.
- Dogfood compiler-owned tables in `compiler/blorp` once ordinary constants can
  express the required data without a special block.

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

- `compiler/blorp` now contains the active bridge dispatcher, typed Core JSON
  codecs, renderer modules, and a supported Core-tail path: resource cleanup
  rewriting, cooperative checkpoint insertion, final Core preparation subset,
  and C artifact emission subset.
- OCaml still owns the frontend, most Core stages, most representation/layout
  decisions, most C emission, and fallback paths for unsupported Core shapes.
- `compiler/blorp/tests` checks renderer behavior and direct compiler-slice
  behavior. The detailed deletion-first port plan lives in
  [BLORP_COMPILER_PORT_ROADMAP.md](BLORP_COMPILER_PORT_ROADMAP.md).

Direction:

- Stop treating Blorp compiler code as optional helper code. New slices should
  expand a contiguous production pipeline region and delete the corresponding
  OCaml implementation where practical.
- Keep one JSON transfer point. Moving the boundary left is preferred over
  adding new bridge side channels or renderer-specific protocols.
- Prefer adjacent late-Core work before broad frontend ports, because the
  current handoff already carries Core facts and the deletion path is clearer.
- Choose slices by OCaml deletion potential, not by ease of adding more Blorp
  scaffolding.

Implementation order:

1. Delete remaining manifest/template bootstrap debt from the bridge.
2. Expand the Blorp C artifact path by backend family, deleting matching OCaml
   helpers as each family becomes authoritative.
3. Finish the supported final-preparation subset in Blorp, then shrink or
   delete matching `core_codegen_prepare.ml` logic.
4. Make Blorp-owned resource/fairness passes observable enough to delete the
   OCaml compatibility path when final-stage observation no longer requires it.
5. Move the JSON boundary left through the ownership tail before starting broad
   parser/typechecker migration.

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

1. Continue self-hosting by expanding the contiguous Blorp Core-tail path and
   deleting matching OCaml code in the same slice.
2. Delete remaining bridge/manifest/template compatibility helpers once
   production callers no longer need them; keep hygiene tests narrow enough that
   they catch real regressions.
3. Move the JSON boundary left through final preparation and the ownership tail
   before starting broad parser/typechecker migration.
4. Baseline `compiler_ast`, `compiler_symbols`, and `compiler_emit` with timing
   and allocation counters before large Core-tail ports.
5. Add resolver/emitter tests that make accidental `CKUser (_, None)` fallback
   visible for ordinary source calls.
6. Audit remaining UFCS DefId suffix paths and decide which source-call shapes
   still rely on them.
7. Keep native-boundary hardening inside the existing security gate.
