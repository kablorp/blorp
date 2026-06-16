# Compiler Roadmap

Status: active roadmap.

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

## Active Workstreams

### Semantic Call Identity

Current behavior still has transitional layers where the source AST, typed AST,
Core, and tooling can ask similar questions in different forms:

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

High-value next checks:

- A direct source call that has been resolved in typed AST should not be
  lowered as an unknown Core call target.
- UFCS and pure/impure overload resolution should select by callable identity,
  not by generated-name suffixes.
- Purity errors should cite the resolved target when one is known.
- Semantic tools should keep parse-only fallbacks isolated and documented.

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

### Ownership And Reuse Performance

Self-hosting will stress compiler-shaped data: AST construction, traversal,
rewriting, and destruction. The important performance gap is structural
allocation churn, not only atomic reference count overhead.

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

## Near-Term Queue

1. Continue reducing unresolved Core call targets by carrying typed callable
   identity farther into lowering and resolution.
2. Measure the largest Core pass groups before adding broad compile-time
   optimizations.
3. Advance managed allocation/reuse facts for AST-like union/record workloads.
4. Keep native-boundary hardening inside the existing security gate.
5. Delete compatibility helpers once production callers no longer need them,
   and keep hygiene tests narrow enough that they catch real regressions.
