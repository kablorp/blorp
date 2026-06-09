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
