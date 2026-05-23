# Core Dead-Code Elimination Roadmap

## Goal

Reduce generated C size and `blorp run` compile latency by pruning unreachable
compiler-produced Core declarations before C emission.

This should be a Core IR optimization, not a generated-C cleanup. Core already
carries resolved call kinds, function `def_id`s, closure metadata, task metadata,
and typed declarations. Generated C only has text, mangled names, and backend
artifacts, so C-level DCE would require fragile reverse engineering.

## Principles

- Prefer explicit Core identities over string matching.
- Make reachability facts phase-specific and explicit.
- Fail closed: if a declaration might be required, keep it.
- Keep behavior unchanged; this work targets compile latency and emitted C size.
- Do not prune a declaration or generated artifact class until its dependency
  model is explicit enough to be safe.

## Current Pipeline Placement

The current Core pipeline is:

```text
lower -> debug -> desugar -> mono -> synth -> match -> trait_resolve ->
resolve -> std_inline -> tailrec -> fusion -> specialize -> dce -> perceus ->
reuse -> closure -> resource -> codegen_prepare -> final -> emit
```

The initial DCE pass runs after `Core_specialize` and
`Core_closure.adapt_function_refs_program`, before `Core_perceus`.

```text
... -> fusion -> specialize -> dce -> perceus -> reuse -> closure -> ...
```

Reasons:

- Calls should already be resolved to `CKUser (_, Some def_id)` where possible.
- Generic functions should already have concrete monomorphic copies.
- Trait calls and overloaded operators should already have direct targets.
- Function references should already be adapted into explicit function-ref
  shapes that can be treated as reachability edges.
- Non-runtime generic function/impl templates should already have any needed
  monomorphic copies, so they can be removed here without starving
  monomorphization.
- Pruned functions avoid Perceus, reuse analysis, closure conversion, and C
  emission work.

Do not start with an earlier pass. If compile-time still needs more improvement,
add a second earlier conservative pass later, after the post-specialize pass is
proven correct.

## Phase 1: Function DCE

Add a new `Core_dce` pass that prunes only unreachable top-level functions.

Status: implemented as `Core_dce.prune_unreachable_declarations`.

### Root Set

The root set should include:

- `main`, when present.
- Global variable initializers, because they may run through
  `__blorp_init_globals`.
- Test harness entrypoints or suite functions if the test runner injects or
  depends on them.
- Any declaration the backend/runtime requires by contract.

The root set should be represented as `cf_def_id` values where possible. Avoid
name-based roots except for stable language entrypoints such as `main`, and keep
that exception isolated.

### Reachability Edges

The pass should traverse reachable Core expression bodies and add edges for:

- `CCall (CKUser (_, Some def_id), _, args)`.
- `CClosureCreate { cc_def_id; ... }`.
- `CConcurrent` task metadata once closure/task functions are represented.
- `CConcurrentFor` task metadata once closure/task functions are represented.
- `CDetach` task metadata once closure/task functions are represented.
- Global initializer expressions.
- Function values/adapters produced by `Core_closure.adapt_function_refs_program`.

It should also recurse through all child expressions using existing Core
traversal helpers where possible. If a Core node has metadata that can reference
a function, the DCE traversal should handle it explicitly.

### Conservative Retention

Kept declarations in the initial Phase 1 implementation:

- Foreign declarations.
- Builtin declarations.
- Type declarations.
- Record declarations.
- Type aliases.
- Imports.
- Trait declarations.
- Globals.
- Impl declarations whose safe pruning rules are not yet modeled.

This was intentionally conservative. The first pass only removed concrete
bodied `CDFunc` declarations that were definitely unreachable. Later phases now
prune additional declaration classes only where the dependency model is
explicit.

### Tests

Add tests before implementation:

- A tiny program should not emit an obviously unused imported std function.
- A directly called helper should remain emitted.
- An imported but unused helper should be pruned.
- A function passed as a callback should remain emitted.
- A closure-created adapter should remain emitted.
- A concurrent task body should remain emitted.
- A trait/operator call should retain the selected impl function.

Prefer codegen-audit tests for emitted-C shape and runtime/compiler tests for
semantic preservation. Avoid brittle exact line counts.

## Phase 2: Impl Method DCE

Once Phase 1 is stable, prune unreachable concrete impl methods.

Status: implemented. Concrete emitted impl methods now participate in the same
`cf_def_id` reachability graph as top-level functions. Empty concrete impl
blocks are removed after their last method is pruned. Runtime callback pointer
dependencies that are not ordinary calls are modeled as explicit reachability
edges for custom `Dict`/`Set` Hashable/Equatable callbacks and list Stringable
callbacks.

Requirements:

- Trait/operator dispatch must be fully resolved before pruning.
- Impl methods must be keyed by `cf_def_id`, not by generated names.
- Any runtime callback pointer emission that depends on impl methods must expose
  explicit reachability edges before pruning.

Tests:

- Used trait method remains.
- Unused impl method is pruned.
- User key hashing/equality callbacks for dict/set remain when required.
- Operator overload methods remain when selected by trait resolution.

## Phase 3: Type And Constructor DCE

Do not attempt this until type dependencies are represented explicitly.

Status: foundation in progress. DCE reachability now uses a phase-local
`decl_ref` set instead of raw function ids. The graph can represent function
bodies, globals, type declarations, record declarations, type aliases, traits,
generated constructor artifacts, generated destructor artifacts, and generated
enum/union macro or singleton artifacts. Type edges carry explicit contexts for
function signatures, expression value types, globals, record fields, union
variant fields, type aliases, impl receiver types, and trait method signatures.
Runtime-artifact edges distinguish record layout constructors,
value-construction constructors, union variant layout constructors, union value
constructors, enum variant macros, enum/vector stringification helpers, union
tag macros, union release-mask layout, nullary union singletons, heap-record and
union runtime type tags, source-emitted stack Option typedefs for enum and
value-record payloads, runtime-owned primitive stack Option typedefs,
backend-generated stack Option typedefs for Int128, UInt128, and Range,
heap-record erased-field release masks, heap-record destructors, union
destructors, runtime-managed builtin lifecycle artifacts for ARC-only and
destructor-backed runtime types, and runtime-owned stack Result layouts
including the erased-vs-managed release-mask distinction. The prunable
declaration kinds are now concrete function bodies, concrete impl methods,
now-empty concrete impl blocks, and monomorphic source record/union/enum
declarations. Global ABI type declarations such as `Range` remain retained as
layout anchors until ABI/runtime layout artifacts have first-class graph
identities. Type aliases, traits, globals, imports, generic type/record
templates, and runtime-owned artifacts remain retained until their pruning
policies are explicit. Post-specialize generic function and impl templates are
now removed by DCE because monomorphization has already produced any runtime
copies, with closure conversion retaining a late safety-net cleanup for the
same non-runtime templates. If reachability analysis fails closed, the original
program is retained, including generic templates.

Runtime/debug type-name audit: source-emitted heap-record and union
`BLORP_TAG` strings are covered by the runtime type-tag artifacts above.
`debug.type_name` is folded to a string literal in `Core_specialize`, and
`debug.is_heap` consumes layout metadata instead of emitting a name-bearing
runtime helper. No additional runtime/debug type-name artifacts are currently
known; if one is added later, it must be represented in this graph before type
or artifact pruning is enabled.

Before pruning additional declarations or generated artifacts, add the pruning
policy itself and keep it fail-closed:

- Prune only declaration/artifact classes with complete dependency edges.
- Retain all type declarations when the graph enters fail-closed mode.
- Retain generic type/record templates until monomorphic declaration identity
  is modeled.
- Retain runtime-owned artifacts that live outside emitted Core/C output.

This phase should likely introduce an explicit declaration dependency graph
rather than extending function-only reachability ad hoc.

## Phase 4: Earlier Conservative DCE

If post-specialize DCE improves C size but not enough compiler time, add an
earlier conservative DCE pass after `resolve` or `std_inline`.

Constraints:

- It must not remove generic templates needed by monomorphization.
- It must understand unresolved or selected-direct calls.
- It must not interfere with later synthesis, specialization, or trait
  resolution.

This phase is optional and should only happen after measuring Phase 1.

## Measurement Plan

Measure before and after:

- Generated C bytes and line count for a tiny program.
- Generated C function definition count for a tiny program.
- `./blorp run` wall time for a tiny program.
- `./blorp run` wall time for `examples/hello.brp`.
- `./blorp run` wall time for a std-heavy benchmark such as list operations.
- `--time-phases` output to confirm downstream Core/codegen work shrinks.

Expected impact:

- Tiny/std-light programs: roughly 20-40% faster edit-run latency if emitted C
  shrinks substantially.
- Medium std-using programs: roughly 10-30%.
- Large benchmark programs: likely 5-20%, depending on how much compile time is
  still C parsing/emission versus typechecking and optimization.

These are estimates. Treat measured numbers as source of truth.

## Risks

- Missing a function-reference edge can produce invalid C or runtime crashes.
- Missing a task/closure edge can break concurrency or callback-heavy code.
- Pruning impl methods too early can break trait callback emission.
- Name-based reachability can silently collide after module flattening.
- Type pruning can break destructors or constructors if introduced before the
  dependency model is explicit.

## Verification Gate

For each phase:

```bash
make
scripts/run_tests.sh compiler
scripts/run_tests.sh runtime
make fmt-check
git diff --check
```

For Phase 1 specifically, also inspect generated C for a tiny program and one
std-heavy program before claiming compile-latency improvement.
