# AST Ownership and Reuse Roadmap

This roadmap covers the work needed to make Blorp substantially faster on
compiler-style AST workloads while preserving the language principles around
value semantics, deterministic resources, and thread safety.

The immediate motivation is the `compiler_ast` benchmark. It models a common
compiler pass shape:

1. Build a tree.
2. Repeatedly walk it.
3. Allocate a rewritten tree for each pass.
4. Drop the previous tree.

That pattern is exactly where a self-hosted compiler will spend a meaningful
amount of time.

## Current Measurements

Recent benchmark runs on `benchmarks/blorp/compiler_ast.brp` show:

- Blorp: about `0.0073s`.
- Go: about `0.0040s`.
- OCaml: about `0.0008s`.
- Blorp leak check: `310315 allocs`, `310315 releases`, `0 leaked`.

The allocation count matches the benchmark structure:

- Initial tree: `3831` nodes.
- Rewrites: `80 * 3831 = 306480` nodes.
- Total tree nodes allocated: about `310311`, plus a few supporting objects.

The built-in profiler points at the expected hot path:

- `rewrite_expr`: about `70%`, `306480` calls.
- `checksum_expr`: about `9%`, `42141` calls.
- `build_expr`: about `1%`, `3831` calls.

A manual `BLORP_SINGLE_THREADED` comparison did not materially improve this
benchmark. Atomic reference counting is therefore not the main bottleneck here.

A small codegen improvement changed generated union destructors from repeated
tag checks to `switch (self->tag)`. That helped slightly, but only by a few
percent. The larger gap is structural: Blorp is allocating and destroying a
whole new AST for every rewrite pass.

## Current Pipeline Facts

The relevant pipeline order is:

```text
core_lower
core_ffi_boundary
core_list_layout
core_debug
core_desugar
core_ssa
core_mono
core_list_layout
core_synth
core_match
core_trait_resolve
core_resolve
core_std_inline
core_tailrec
core_string_pipeline
core_collection_pipeline
core_parallel_tensor_pipeline
core_tensor_fusion
core_tuple_sroa
core_specialize
core_dce
core_perceus
core_reuse
core_closure
core_resource
core_codegen_prepare
backend emit
```

The key files are:

- `compiler/lib/core.ml`: Core IR definitions.
- `compiler/lib/core_ownership.ml`: ownership contracts and call modes.
- `compiler/lib/core_perceus.ml`: explicit `CDup` / `CDrop` insertion.
- `compiler/lib/core_reuse.ml`: existing reuse optimization.
- `compiler/lib/core_codegen_prepare.ml`: late constructor preparation.
- `compiler/lib/core_emit.ml`: generated C emission.
- `compiler/lib/core_emit_util.ml`: retain/release emission helpers.
- `compiler/lib/runtime.c`: runtime allocation and release machinery.

The existing reuse pass is intentionally narrow. It recognizes collection
allocation sites such as lists, dicts, sets, strings, and bytes. It does not
currently optimize user records or unions.

The most important pipeline mismatch is that ordinary union constructor calls
are converted into `CUnionConstruct` in `core_codegen_prepare`, after
`core_reuse` has already run. That means the reuse pass cannot currently see a
first-class union allocation site.

## Current Generated Shape

For the compiler AST benchmark, the generated `Expr` union is a heap object with:

- a Blorp object header,
- a tag,
- a release mask,
- and a C union of variant field structs.

Constructors allocate with `blorp_alloc(sizeof(Expr))`, initialize the tag and
fields, install type metadata, and return an owned `Expr*`.

`rewrite_expr` currently borrows the input tree and returns a freshly allocated
tree. The caller then releases the old tree:

```c
Expr* next = rewrite_expr(expr, pass);
blorp_release(expr);
expr = next;
```

Inside the rewrite, child fields are read directly. There are no avoidable
per-child retain/release operations in the simple hot path. The cost is instead
the repeated allocation of the replacement tree and the recursive destruction of
the old tree.

## Goals

The work should optimize AST-like workloads without changing source-level
semantics.

Concrete goals:

- Keep value semantics visible to Blorp programs.
- Preserve thread safety by default.
- Preserve deterministic ARC behavior.
- Make consuming tree rewrites allocate far less.
- Avoid stringly or name-based heuristics in compiler passes.
- Keep resource cleanup correctness global, not special-cased for one benchmark.
- Make generated C easier for the C compiler to optimize.

Non-goals:

- Do not introduce shared mutable source-language objects.
- Do not require users to opt into unsafe destructive update.
- Do not make compiler correctness depend on benchmark-specific patterns.
- Do not weaken `Option` / `Result` representation choices for unrelated cases.

## Phase 0: Baselines and Guardrails

Before changing ownership behavior, lock down the evidence.

Work:

- Keep `compiler_ast` in the standard benchmark suite.
- Track benchmark time, allocation count, and leak count for the benchmark.
- Add or keep codegen audit coverage for union destructor emission.
- Add focused regression tests around union constructors, release masks, and
  destructor behavior.
- Make it easy to regenerate and inspect the C for `compiler_ast`.

Validation:

- `make`
- `scripts/test compiler-unit --serial`
- `scripts/test runtime --serial`
- `scripts/test leak --serial`
- `git diff --check`
- `./blorp run --leak-check --no-format benchmarks/blorp/compiler_ast.brp`
- `BENCH_RUNS=5 BENCH_WARMUPS=1 bash benchmarks/bench.sh compiler_ast`

Expected payoff:

- No major runtime improvement. This phase establishes a stable target and
  prevents ownership regressions.

## Phase 1: Typed Release and Destructor Fast Paths

The current runtime release path is generic: decrement a refcount, then route
through the generic slow release path and destructor lookup. For known managed
types, codegen can emit a more direct release path.

Work:

- Extend `compiler/lib/core_emit_util.ml` so `release_value_call` can choose a
  type-specific release helper when the concrete managed type is known.
- Generate or emit direct static release helpers for records and unions.
- Preserve the generic release path for erased, opaque, or unknown managed
  values.
- Keep the slow path available for leak tracing and type metadata accounting.

Design constraints:

- The optimization must not bypass destructor semantics.
- It must still be correct under `BLORP_TRACE_ALLOCS`, leak checking, and
  sanitizers.
- It should be a codegen choice, not a new source-language behavior.

Likely files:

- `compiler/lib/core_emit_util.ml`
- `compiler/lib/core_emit.ml`
- `compiler/lib/runtime.c`
- `compiler/test/test_core_emit.ml`

Validation:

- Generated C should show direct release helpers for known union/record types.
- Leak tests must remain exact.
- `compiler_ast` should be remeasured, but only a modest gain is expected.

Expected payoff:

- Small. This reduces overhead around releases, but does not remove the core
  allocation pattern.

## Phase 2: Make Managed Allocation Sites Visible Before Reuse

The reuse pass needs to see user union and record allocations. Today it cannot,
because `CUnionConstruct` is created after reuse.

There are two viable approaches.

Approach A: introduce earlier managed allocation IR.

- Add a pre-final Core node for managed record/union construction.
- Carry source-level type identity, constructor identity, field expressions, and
  release facts.
- Let later codegen preparation still decide final C names and special
  representations.

Approach B: teach reuse to understand resolved constructor calls.

- Keep constructor calls as calls until codegen preparation.
- Add a typed constructor metadata query that maps a resolved constructor call
  to allocation facts.
- Let reuse reason over those facts without changing the IR shape.

Recommendation:

- Prefer Approach A if the new node can stay representation-neutral.
- Prefer Approach B only if adding another allocation node makes the Core phase
  boundary worse.

Design constraints:

- Do not force final `Option` / `Result` layout decisions earlier than today.
- Do not inspect names or source formatting to detect constructors.
- Generic constructors must carry enough type information for release masks.
- Core invariants should reject partially prepared allocation nodes in stages
  where they are not valid.

Likely files:

- `compiler/lib/core.ml`
- `compiler/lib/core_invariants.ml`
- `compiler/lib/core_codegen_prepare.ml`
- `compiler/lib/core_reuse.ml`
- `compiler/lib/core_perceus.ml`

Validation:

- Unit tests that a user union constructor is visible to reuse before
  `core_codegen_prepare`.
- Existing `Option` / `Result` representation tests must remain unchanged.
- Generated C before and after should remain equivalent when reuse is disabled.

Expected payoff:

- No direct speedup by itself. This unlocks the real optimization.

## Phase 3: Consuming Call Specialization

The hot rewrite shape is a borrowed call followed by a drop of the old value.
To reuse the old tree, the compiler needs a consuming variant of the rewrite:

```text
old owned tree -> rewritten owned tree
```

The source function can still look pure and value-oriented. The compiler can
create an internal consuming specialization when the call site proves the
argument is dead after the call.

Work:

- Extend ownership summaries to represent a consuming user-function variant.
- Identify call sites where an owned managed argument is dropped immediately
  after the call or otherwise has no remaining use.
- Clone or specialize the callee for that call mode.
- Keep the borrowed function body available for other call sites.

Design constraints:

- Do not change behavior for aliased values.
- Do not consume a value if any branch may still need the original owner.
- Do not specialize through resource scopes unless cleanup behavior is proven.
- Fail closed around nonlinear control flow until the analysis is explicit.

Likely files:

- `compiler/lib/core_ownership.ml`
- `compiler/lib/core_perceus.ml`
- `compiler/lib/core_reuse.ml`
- `compiler/lib/core.ml`
- `compiler/test/test_core_perceus*.ml`
- `compiler/test/test_core_reuse*.ml`

Validation:

- Tests where one call site can consume and another must borrow.
- Tests where a branch keeps the original value alive, blocking consumption.
- Tests where a consumed argument is recursively rebuilt.
- Leak and sanitizer tests for consumed and borrowed variants.

Expected payoff:

- Potentially large once paired with union/record reuse.

## Phase 4: Owned Match and Field Move Semantics

A consuming rewrite needs to destructure an owned union without accidentally
double-releasing its fields.

Today, a match over a borrowed union can read fields safely. For consuming
reuse, the compiler needs to model field ownership precisely:

- If a field is moved into the new value, the old parent destructor must not
  release it.
- If a field is not moved, the old parent destructor or reuse path must release
  it exactly once.
- If the parent object is reused, overwritten fields must be cleaned up first.

Work:

- Add an owned-match or owned-destructure representation in Core.
- Track moved fields with an explicit mask or equivalent IR-level fact.
- Teach Perceus and reuse how moved fields affect drops.
- Teach codegen how to clear or update release masks before release/reuse.

Design constraints:

- Moved fields must be represented explicitly, not inferred from local naming.
- It must be impossible for generated C to both move a field and let the old
  destructor release it.
- The design must work for records as well as unions, or explicitly stage
  records after unions with a shared abstraction.

Likely files:

- `compiler/lib/core.ml`
- `compiler/lib/core_match.ml`
- `compiler/lib/core_perceus.ml`
- `compiler/lib/core_reuse.ml`
- `compiler/lib/core_emit.ml`
- `compiler/lib/core_invariants.ml`

Validation:

- Union variants with zero, one, and multiple managed fields.
- Variants with primitive-only fields.
- Rewrites that move one child and replace another.
- Rewrites that change variants.
- Leak checks proving every old field is released exactly once.

Expected payoff:

- This is the safety-critical foundation for allocation reuse.

## Phase 5: Union and Record Reuse

Once managed allocation sites and owned destructuring are represented, reuse can
extend beyond collections.

The target transformation is:

```text
drop old_owner;
construct same managed type with new fields
```

into:

```text
reuse old_owner storage when unique and layout-compatible;
otherwise allocate normally
```

For unions, the same heap type has a max-sized C union payload, so many
variant-changing rewrites can reuse the same object storage. The code still has
to release old managed fields that are not moved into the new value.

Work:

- Add a Core node or reuse annotation for managed object reuse.
- Define compatibility rules for record and union storage.
- Add codegen for reuse construction.
- Add a runtime helper only if static uniqueness is not enough.

Static versus runtime uniqueness:

- A consuming specialization gives strong static ownership information.
- A conservative first implementation can still check uniqueness at runtime and
  fall back to allocation if needed.
- A later implementation can skip the runtime check where Perceus proves unique
  ownership.

Design constraints:

- Reuse must not cross `CResourceScope` unless resource cleanup has been proven.
- Reuse must not apply to values with possible aliases.
- Reuse must preserve destructor IDs and type metadata.
- Reuse must update release masks before any possible cleanup edge.

Likely files:

- `compiler/lib/core_reuse.ml`
- `compiler/lib/core_emit.ml`
- `compiler/lib/core_emit_util.ml`
- `compiler/lib/runtime.c`
- `compiler/lib/core_invariants.ml`

Validation:

- Codegen tests for reuse constructors.
- Runtime tests for same-variant and variant-changing rewrites.
- Leak tests for managed child movement.
- Sanitizer tests for double-free and use-after-free risks.
- Benchmarks for `compiler_ast`.

Expected payoff:

- Large. This directly attacks the `306480` rewrite allocations and the
  recursive destruction of the old tree.

## Phase 6: Compact Scalar Union Variants

The `compiler_ast` benchmark has many scalar leaf nodes. In the measured tree,
more than half of nodes are scalar leaves. Today those leaves are still heap
allocated union objects.

A compact representation can avoid allocating variants with small primitive
payloads, such as:

- no-payload variants,
- integer payload variants,
- boolean payload variants,
- enum-like variants,
- possibly small single-word payload variants.

Work:

- Choose a tagged immediate representation for eligible union variants.
- Teach type classification that some union values may be immediate or pointer.
- Update retain/release to ignore immediate values.
- Update pattern matching, equality, hashing, and debug formatting.
- Keep generic and managed variants on the heap.

Design constraints:

- The representation must be explicit in type/codegen metadata.
- It must compose with `Option` / `Result` special layouts.
- It must not make C interop unsound.
- It must not hide managed payloads inside immediate values.

Likely files:

- `compiler/lib/core_codegen_prepare.ml`
- `compiler/lib/core_emit.ml`
- `compiler/lib/core_emit_util.ml`
- `compiler/lib/runtime.c`
- `compiler/lib/types.ml`
- `compiler/lib/core_invariants.ml`

Validation:

- Runtime tests for immediate and heap variants in the same union.
- Pattern-match tests over scalar and managed variants.
- Leak checks proving immediate variants do not enter ARC.
- Generated C audits for tagged immediate checks.
- Benchmarks for `compiler_ast`.

Expected payoff:

- Large for ASTs with many leaf nodes. This is probably the second major step
  after reuse.

## Phase 7: Pattern and Dispatch Codegen Refinements

After the structural allocation work, tune the generated C dispatch shape.

Work:

- Emit `switch` for dense union tag matches where appropriate.
- Inline small constructors when doing so does not duplicate cleanup logic.
- Avoid unnecessary release-mask work for primitive-only variants.
- Audit generated cleanup paths for avoidable temporary variables.

Design constraints:

- These are local codegen optimizations. They should not introduce new
  ownership facts.
- Readability of generated C still matters for debugging.

Likely files:

- `compiler/lib/core_emit.ml`
- `compiler/lib/core_emit_match.ml` if match emission is split later.
- `compiler/lib/core_emit_util.ml`

Validation:

- Codegen audit tests for dense matches.
- Runtime tests for match behavior.
- Benchmarks after structural optimizations are already in place.

Expected payoff:

- Small to moderate. Useful, but not the main AST gap.

## Phase 8: Rollout and Regression Strategy

This work touches the most failure-prone part of the compiler: ownership and
cleanup. Roll it out behind compiler-controlled gates where practical.

Suggested rollout:

1. Add metrics and tests.
2. Add typed release fast paths.
3. Make managed allocation sites visible before reuse.
4. Add consuming call specialization without enabling reuse.
5. Add owned match and moved-field tracking.
6. Enable union/record reuse for narrow proven cases.
7. Broaden reuse cases.
8. Add compact scalar union variants.

Every stage should be useful and testable on its own.

Required gates before enabling broadly:

- `make`
- `scripts/test compiler-unit --serial`
- `scripts/test compiler --serial`
- `scripts/test runtime --serial`
- `scripts/test leak --serial`
- `scripts/test doctest --serial`
- `scripts/test cli --serial`
- targeted sanitizer runs
- generated C audit tests
- `git diff --check`

## High-Risk Areas

The main correctness risks are:

- double release of moved fields,
- leaking fields when a reused object changes variants,
- consuming a value that still has an alias,
- cleanup edges that bypass release-mask updates,
- interaction with resource scopes and cancellation cleanup,
- accidentally changing `Option` / `Result` optimized representations,
- polymorphic constructor metadata becoming too late or too erased,
- benchmarking an optimization that only helps one synthetic shape.

The mitigation is to represent ownership facts explicitly in Core, enforce
stage invariants, and add leak/sanitizer tests before broad enablement.

## Open Design Decisions

These need explicit decisions before implementation begins:

1. Should managed constructor visibility be represented as a new pre-final Core
   node, or should reuse query resolved constructor metadata?
2. Should consuming functions be cloned as separate Core functions, or should
   call sites carry enough ownership mode to share one body?
3. Should first-pass reuse require static uniqueness, runtime uniqueness, or
   both?
4. What is the exact IR representation for moved fields?
5. Do records and unions ship together, or do unions land first with an
   abstraction that records reuse later?
6. How much scalar immediate union work belongs in the first optimization wave?

## Recommended First Implementation Slice

The highest-leverage self-contained slice is:

1. Add allocation and release count reporting to the benchmark workflow.
2. Introduce a representation-neutral managed constructor allocation fact
   before `core_reuse`.
3. Add compiler-unit tests proving union allocation sites are visible before
   reuse.
4. Add consuming specialization for a narrow direct-call pattern where an owned
   argument is dead immediately after the call.
5. Add owned union destructuring with explicit moved-field masks.
6. Enable union reuse for same union type, fall back to allocation on any
   uncertainty.
7. Measure `compiler_ast` before and after.

This slice is large enough to exercise the real architecture, but narrow enough
to avoid redesigning all data representation at once.

## Expected Payoff Order

Expected impact on the `compiler_ast` benchmark, from highest to lowest:

1. Union/record reuse for consuming rewrites.
2. Compact scalar union variants.
3. Typed release/destructor fast paths.
4. Switch-based tag dispatch and other local codegen polish.

The first two are the structural wins. The latter two are worthwhile cleanup,
but they will not close the gap alone.
