# Compiler Perceus Memory Dossier And Roadmap

Status: active implementation plan; Slices 0-4 completed as of 2026-07-20.

Last checked against `dogfood-3` after `feb3ac29` on 2026-07-20.

This document records the primary cause of the current self-hosted compiler
memory blow-up and defines the implementation sequence for correcting it. It is
not a general compiler optimization backlog. The immediate scope is the late
Core path from global binding resolution through Perceus ownership rewriting.

## Executive Conclusion

The primary backend memory regression was caused by the algorithm used to make
global references ownership-safe in
`compiler/blorp/src/stage_09_core/compiler_core_perceus.brp`.

The pre-Slice 4 implementation repeatedly rebuilt each function body once for
every globally declared value, then can rebuild it up to three more times for
every managed global. A compiler-sized Core program has thousands of functions
and hundreds of globals. This turns a bounded ownership correction into work
proportional to the product of the whole program and the global table, while
retaining enormous numbers of short-lived immutable Core nodes.

The measured failure is an allocation explosion, not CTFE and not fiber stack
growth:

- the backend helper reached a 44.9 GB physical footprint;
- 44.6 GB was attributed to `MALLOC_SMALL` regions;
- the allocator reported approximately 561 million allocations;
- 40.8 GB of those small-allocation regions had been swapped out;
- stack regions accounted for only about 320 MB virtual and 6 MB resident;
- native compilation of the already-generated 57.4 MB C file used about
  1.82 GB and 8.8 seconds, so C compilation is secondary.

The fix should not weaken ownership, make strings immortal, suppress drops, or
hide the cost behind caching. It should make the compiler do less work:

1. resolve binding identity once, before ownership analysis;
2. represent globals with indexed, exact identities;
3. collect the globals actually referenced by each body in one traversal;
4. run ownership rewrites only for those referenced values;
5. consolidate repeated borrowed-value traversals only after the narrow fix is
   correct and measured.

## Measured Evidence

### Compiler-sized source path

The sampled source-to-C path used the current self-hosted compiler sources and
standard library:

| Stage | Input/output evidence | Observed cost |
|---|---|---|
| CLI planning | 398-byte request, 166,856,852-byte response | helper peak about 4.87 GB |
| Typecheck graph | 6,816,531-byte request, 448,514,717-byte response | 118.6 seconds; helper peak about 14.33 GB |
| OCaml typecheck response handling | complete response buffered and decoded | host peak about 4.04 GB |
| Core backend request | 143,888,447-byte Core request | backend helper sampled near 12.48 GB RSS before swap was counted |
| Backend VM footprint | same helper during Perceus | 44.9 GB physical footprint |
| Generated C compile | 57.4 MB, about 755,000 lines, `cc -O0` | about 1.82 GB peak RSS and 8.8 seconds |

The Core request contained approximately 8,707 function declarations and 620
global declarations. The compiler and standard-library source set contained
6,308,432 bytes across 209 files.

The diagnostic backend run was stopped after collecting `vmmap` evidence to
avoid another machine-wide out-of-memory failure. It had already spent about
371 seconds in the backend. The termination means that run is not an end-to-end
timing result; its memory-region evidence is still conclusive.

### Allocator evidence

`vmmap -summary` on the backend helper reported:

| Region/fact | Measurement |
|---|---:|
| Physical footprint | 44.9 GB |
| Writable regions | 45.3 GB |
| `MALLOC_SMALL` total | 44.6 GB |
| `MALLOC_SMALL` resident | 3.8 GB |
| `MALLOC_SMALL` swapped | 40.8 GB |
| Default-zone allocation count | 561,216,415 |
| Default-zone allocated bytes | 44.6 GB |
| Reported fragmentation | about 1% |
| Stack virtual size | about 320 MB |
| Stack resident size | about 6 MB |

Low fragmentation plus hundreds of millions of small allocations means the
memory is occupied by compiler values, not allocator slack. The small resident
set relative to total allocated memory explains why ordinary RSS sampling
underreported the real pressure after the operating system began swapping.

### Stack samples

Samples repeatedly placed the backend in the Perceus path:

```text
run_pre_dce_tail
  -> run_perceus_stage
    -> insert_drops_program
      -> resolve_program_global_refs
        -> resolve_global_refs_in_expr
          -> rename_shadow_var_refs
```

Later samples remained in Perceus:

```text
rewrite_function
  -> retain_borrowed_values
    -> protect_borrowed_param_calls
    -> retain_borrowed_param_aggregate_members
    -> retain_borrowed_param_result
    -> summarize_linear_ownership_uses
```

The typecheck helper sample showed ordinary graph typechecking and materialized
typed artifacts. It did not show compile-time evaluation as the cause of this
backend explosion.

### Bounded Regression Baseline

Slice 0 added `benchmarks/compiler_perceus_memory`, an opt-in fixture runner
that generates Core in a temporary directory and invokes the production
`emit_core_c` bridge action. It validates that the resulting C contains the
first and last generated globals and worker functions before reporting a
successful measurement. Bridge preparation is excluded from measurement, and
the request, response, C, and metrics files are removed after each run.

The fixture keeps 64 reachable worker functions and 64 literal leaves per
worker constant while varying only the number of public managed string globals.
None of those globals is referenced by a worker. This isolates the current
per-global whole-body work while keeping the request small enough for routine
local use.

Baseline on an Apple M4 running arm64 macOS 26.5.1 at `4d88200f`:

| Globals | Declarations | Input expression nodes | Request | Elapsed | Peak RSS |
|---:|---:|---:|---:|---:|---:|
| 24 | 89 | 8,345 | 702,960 bytes | 0.404s | 56,033,280 bytes |
| 384 | 449 | 8,705 | 836,563 bytes | 2.666s | 251,215,872 bytes |

Increasing irrelevant globals from 24 to 384 made the backend about 6.6x
slower and raised peak RSS about 4.5x, while input expression nodes increased
only about 4.3%. This is the bounded scaling signal that subsequent slices
must reduce.

Commands:

```bash
benchmarks/compiler_perceus_memory \
  --globals 24 --functions 64 --body-leaves 64 --json
benchmarks/compiler_perceus_memory \
  --globals 384 --functions 64 --body-leaves 64 --json
```

A separate `--vmmap` run at 384 globals observed:

| Fact | Measurement |
|---|---:|
| Physical footprint | 238,131,609 bytes |
| `MALLOC_SMALL` virtual size | 243,269,632 bytes |
| Default malloc-zone allocation count | 3,510,453 |

`vmmap` sampling increased elapsed time from about 2.7 seconds to 10.4 seconds,
so its elapsed result is not a timing baseline. Use unsampled runs for elapsed
and peak-RSS comparisons, and use `--vmmap` only for allocator composition.

## Production Path Through The Code

The relevant late-Core path is centralized in
`compiler/blorp/src/stage_09_core/compiler_core_pipeline.brp`:

```text
resolve callable ids
  -> std inline / tailrec / fusion / specialize
  -> DCE
  -> consume specialization
  -> ownership preparation
  -> Perceus
  -> reuse
  -> closure conversion
  -> resource / fairness / prepare / prepared reuse
  -> C emission
```

`run_perceus_stage` prepares dictionary literals and then calls
`CorePerceus.insert_drops_program`.

`insert_drops_program` now performs these operations:

1. `CoreResolve.resolve_global_value_refs(program)` resolves unresolved global
   values in one indexed, scope-aware walk.
2. `build_env(resolved_program)` gathers type, constructor, function,
   call-contract, and global facts once.
3. `infer_user_call_contracts` infers consumed arguments.
4. `rewrite_decl` runs Perceus over every function, global initializer, and
   implementation method.

Inside `rewrite_function`, the body passes through a sequence of whole-tree
transformations:

1. `annotate_user_call_contracts`;
2. `protect_borrowed_param_calls_for_function`;
3. `retain_borrowed_param_aggregates`;
4. `retain_borrowed_param_results`;
5. `retain_borrowed_values` for referenced, unshadowed globals;
6. `normalize_owned_result_aliases` for managed results;
7. `insert_drops_expr`;
8. `balance_consumed_param_bodies`.

Several of those passes are semantically necessary. Slices 2-4 removed the
regression by selecting referenced globals once per body and replacing the
per-global resolver with one indexed program walk.

## Primary Cause In Detail

Let:

- `F` be the number of function/global bodies;
- `G` be the number of globals;
- `M` be the number of managed globals;
- `N` be the number of Core expression nodes in one body.

### 1. Global resolution rebuilds every body per global

`resolve_global_refs_in_expr` loops over `env.global_values`. For each eligible
global it calls `rename_shadow_var_refs`, which recursively reconstructs the
entire expression tree while replacing matching variable names.

The cost per body is therefore approximately `O(G * N)`, including `G`
immutable tree reconstructions. It also calls `global_name_is_unique` for every
global, and `global_name_is_unique` scans the complete global list through
`global_name_count`. That adds `O(G^2)` list work per body.

Across the program, this portion is approximately:

```text
O(F * (G * N + G^2))
```

The critical point is that an absent global is not cheap. Its rewrite still
walks and rebuilds the body before discovering that no leaf matches.

### 2. Borrowed-global retention repeats whole-tree rewrites

`unshadowed_global_values` filters the complete global table and calls the same
linear `global_name_is_unique` check for every entry. `retain_borrowed_values`
then loops over the resulting values. For each managed value it runs:

- `protect_borrowed_param_calls`;
- `retain_borrowed_param_aggregate_members`;
- `retain_borrowed_param_result` when the enclosing result is managed.

Each operation is another recursive body rewrite. A body that references one
managed global can therefore be rebuilt for hundreds of unrelated managed
globals first.

This adds approximately `O(M * N)` full transformations per body, with two or
three tree copies per managed global. The transformations also invoke ownership
summaries in nested cases, increasing traversal work further.

### 3. Immutable reconstruction turns bad complexity into retained memory

Blorp values have value semantics and Core expressions are immutable union
trees. Rewriting a body produces new nodes and collection spines. ARC must keep
old and new structures alive long enough to satisfy the expression-level value
semantics of each pass. Repeating this hundreds of times across thousands of
functions creates the observed `MALLOC_SMALL` pressure.

This is not an argument against immutable Core. A linear number of deliberate
phase transformations is reasonable. The error is using a whole-program table
entry as the unit of tree transformation.

## Why The Code Exists

The problematic logic was introduced in `5f899c5f` (`fix string lifetimes`).
That change fixed real ownership failures:

- a borrowed global string stored in a newly owning record or union needs a
  retain before the aggregate assumes ownership;
- a managed global returned from a function needs correct borrowed-result
  treatment;
- assigning a new managed value to a mutable global must release the old owner;
- some lowered global references and assignment targets lacked the declaration
  definition id needed for exact mutable-global recognition.

The runtime regressions added with that change are legitimate. In particular:

- `tests/test_blorp/memory/leak_check_baselines/string_literal_lifecycle.brp`;
- `tests/test_blorp/memory/test_global_record_union_lifecycle.brp`;
- the global ownership cases in
  `compiler/blorp/tests/test_compiler_core_perceus.brp`.

The ownership behavior must remain. The repair strategy is what needs to be
replaced.

## Underlying Representation Gap

Core global declarations have identities, but ordinary typed value references
do not consistently carry them into Core.

In `compiler/blorp/src/stage_08_core_lower/compiler_core_lower.brp`:

- `lower_typed_global` mints a `def_id` and places it on the `CoreGlobal` and
  declaration `CoreVar`;
- `lower_typed_expr` lowers `CompilerTypedNameExpr` through
  `split_var_callable_id`, which supplies ids for resolved callables but not
  ordinary variables;
- `CompilerTypedAssignExpr` lowers its target with `def_id = None`.

The typed expression model in
`compiler/blorp/src/stage_06_typecheck/compiler_infer.brp` records detailed call
resolution but does not record an exact resolved binding identity for ordinary
value reads. `CompilerVarSymbol` similarly records type, mutability, origin,
refinement, and module path, but no value-definition identity.

Perceus consequently became responsible for reconstructing global identity by
matching strings late in the pipeline. That violates the intended phase
boundary: ownership analysis should consume resolved identities, not perform
name binding.

Changing typed-AST binding identity may eventually be the cleanest complete
model, but it is not required to stop the current regression. A dedicated Core
binding-resolution pass can provide a bounded first checkpoint while the
typed-AST design is evaluated separately.

## Correctness Problems In The Current Resolver

The current resolver is expensive and only partially models lexical scope.

### Name matching can overwrite existing identity

`rename_shadow_var_refs` replaces a `VarExpr` when its string name matches. It
does not first require `variable.def_id` to be absent. A same-named reference
that already has a different explicit identity can therefore be rewritten.

The replacement rule should be:

> Resolve only an unresolved value reference, and only when the binding index
> has exactly one valid target in the current module-qualified namespace.

Existing identities must be authoritative.

### Scope handling is incomplete

The current custom traversal recognizes:

- function parameters at the entry call;
- `LetExpr` and `BorrowLetExpr` binders;
- lambda parameters;
- resource-scope binders;
- literal, length, and constructor match bindings.

Its generic fallback uses `map_core_expr_children`, which does not communicate
scope. Consequently it does not explicitly protect binders introduced by:

- `ForRangeExpr` and all specialized `For*Expr` loops;
- `PreClosureConcurrentlyLoopExpr` and `ConcurrentlyLoopExpr`;
- `PreClosureConcurrentExpr` and `ConcurrentExpr` result bindings;
- receive arms in `SelectExpr`;
- `TailrecLoopExpr` and `TailrecListSpreadLoopExpr` parameters/cursors;
- `TensorRawViewLetExpr`;
- the internal variables of `ListHandoffExpr`.

Some internal forms cannot legally refer to a global in the binder position,
but that invariant should be explicit rather than assumed by a generic
name-based traversal. Ordinary loop, concurrent, and select binders are direct
source-level correctness concerns.

### Duplicate names are represented ambiguously

`global_name_is_unique` counts declarations by name. This has several edge
cases:

- two distinct globals with the same unqualified name correctly cannot be
  guessed;
- repeated copies of the same module-qualified `(name, def_id)` identity are
  currently also treated as ambiguous;
- ids are documented as module-local in `compiler_core_resolve.brp`, so an id
  alone is not a complete cross-module identity;
- `CoreGlobal` does not carry `source_module`, making qualified naming an
  important part of the current identity contract.

The resolver must define and test whether repeated identical identities are
deduplicated or rejected. It must never choose the first same-named global.

### Ownership matching falls back to names

The global mutable-assignment path eventually uses
`core_vars_have_same_definition`, which is appropriately exact. In contrast,
borrowed-value summaries and retention helpers primarily compare names and
implement lexical shadowing independently. Passing only actually referenced,
resolved globals makes these helpers safer, but a later consolidation should
make exact identity the common matching rule where Core supplies one.

### Nested lambdas repeat global work

`insert_drops_expr` first calls `normalize_lambda_result_aliases`. Lambda
normalization computes runtime captures and invokes
`normalize_lambda_body_ownership`, which currently appends all unshadowed
globals and calls `retain_borrowed_values` again. Globals are therefore paid for
at both enclosing-function and nested-lambda ownership boundaries.

The target behavior is to analyze each body boundary once and include only the
globals referenced within that boundary.

## Target Architecture

### 1. Binding resolution is a distinct Core responsibility

Extend `compiler_core_resolve.brp` from callable-only resolution to an explicit
Core binding-resolution boundary. The public operation should resolve both:

- selected callable identities already represented by call metadata;
- unresolved global value reads and assignment targets.

Suggested public name:

```blorp
pure func resolve_core_bindings(program: CoreProgram) -> CoreProgram
```

`resolve_callable_id_calls` should become a private implementation detail or be
removed once all callers use the complete operation.

The pass must build indexes once per program. It must not scan the declaration
list for each reference.

### 2. Scope is explicit during resolution

The resolver should carry a lexical scope value through one recursive Core
walk. A small phase-specific type is preferable to loosely related booleans:

```blorp
record CoreBindingScope {
	bound_names: Set[String]
}
```

If `Set` update cost is not suitable under current COW behavior, a list is
acceptable initially because lexical depth is small; the choice must be
measured, not guessed.

Every binding Core form must explicitly define which children use the outer
scope and which use the extended scope. A shared scoped child-mapper in
`compiler_core_traverse.brp` is appropriate only if its binder semantics are
complete and useful to more than this pass. Otherwise keep the traversal local
to `compiler_core_resolve.brp` and exhaustive.

### 3. Perceus indexes globals by exact identity

Replace repeated list lookup with indexed facts in `PerceusEnv`:

```blorp
globals_by_def_id: Dict[Int, PerceusGlobal]
unique_globals_by_name: Dict[String, PerceusGlobal]
```

If module-local ids can collide in the same assembled Core program, use an
explicit compound identity represented by a record and a suitable index rather
than concatenating strings or guessing from names.

The environment should also expose the managed-global subset without testing
every primitive global on every function.

### 4. Reference facts are collected once per body

Introduce a single traversal that records exact referenced global identities:

```blorp
record CoreReferenceFacts {
	global_def_ids: Set[Int]
}
```

The collector must observe at least:

- `VarExpr` reads;
- `AssignExpr` targets and right-hand sides;
- ownership nodes if the collector can run on partially transformed Core;
- all recursively contained expressions and match bodies.

Because globals are already resolved, the collector does not need to reproduce
lexical shadowing. It should match definition identity against the global
index. This is both simpler and more reliable than collecting strings.

The preferred implementation is a reusable, state-threaded Core fold if it can
replace duplicated exhaustive traversal in DCE and other passes. Do not add a
second generic traversal API that merely duplicates
`map_core_expr_children` without reducing code. If a shared fold would make the
first checkpoint too broad, use a focused reference collector and schedule the
DCE consolidation separately.

### 5. Ownership transforms operate on relevant values

`rewrite_function`, `rewrite_global`, and lambda normalization should obtain
their borrowed globals by looking up the body facts in the global index. An
unreferenced global must cause:

- no expression traversal;
- no expression reconstruction;
- no ownership summary;
- no type test inside the body rewrite.

Slice 6 deliberately retains the existing per-value ownership helpers for
referenced globals. Most bodies reference zero or a small number of globals,
so that slice removes the catastrophic multiplier while minimizing semantic
change.

### 6. Consolidate borrowed-value rewrites only with evidence

After the narrow fix, profile these existing function-parameter paths:

- `protect_borrowed_param_calls_for_function`;
- `retain_borrowed_param_aggregates`;
- `retain_borrowed_param_results`;
- `balance_consumed_param_bodies`.

If they remain material, design a `BorrowedValueIndex` and process all borrowed
values in one traversal per ownership concern. This can reduce work from
`parameters * body` to `body`, but it is a correctness-sensitive rewrite and
must not be mixed into the emergency global fix without measurements.

## Implementation Roadmap

The roadmap deliberately uses small slices. Each slice must be independently
mergeable to `main`, preserve all existing ownership behavior, and provide a
complete improvement even if no later slice is implemented. A slice may add
the smallest supporting type or traversal it immediately uses, but must not
land dormant infrastructure, a second production path, or a temporary feature
flag.

The order below is recommended because it first bounds the active failure,
then moves responsibility to the correct phase, then removes the now-obsolete
workaround. Adjacent slices should not be combined merely to reduce PR count.

| Slice | Scope | Expected review size | Safe stopping point |
|---|---|---:|---|
| 0 | Bounded evidence | Small | Yes; no production change |
| 1 | Preserve explicit ids | Small | Yes; correctness improves |
| 2 | Skip impossible global work | Small/medium | Yes; OOM path is bounded |
| 3 | Precompute declaration facts | Small | Yes; repeated scans are gone |
| 4 | Replace resolver algorithm | Medium | Yes; one resolver remains |
| 5 | Move resolver boundary | Small/medium | Yes; phase ownership is clean |
| 6 | Exact per-body global facts | Medium | Yes; ownership scales with use |
| 7 | Lambda-local facts | Small/medium | Yes; nested work is bounded |
| 8 | Re-profile | Small | Yes; produces a go/no-go decision |
| 9 | One measured ownership concern | Medium | Yes; one invariant per change |
| 10 | Typed identity decision | Documentation | Yes; optional future roadmap |

### Slice 0: Add A Bounded Regression Fixture (Complete)

**Independent value:** future changes can reproduce the bad scaling without
driving a developer machine into swap or OOM.

Add a compiler-owned synthetic Core fixture with many irrelevant globals and a
moderate number of small functions. The fixture must exercise the production
backend entry point, not a mock of Perceus. Record:

- declaration and expression-node counts;
- Core request bytes;
- elapsed time and peak memory;
- allocator footprint where the platform exposes it.

Keep it out of ordinary semantic tests if its size materially slows them. Add
it to `benchmarks/bench.sh` only if it fits the standard benchmark budget;
otherwise give it a focused script and document the exact invocation here.
Normal CI should assert output correctness, not wall-clock time.

Files:

- `benchmarks/` or `compiler/blorp/tests/fixtures/`, following the closest
  existing compiler benchmark convention;
- `benchmarks/bench.sh` only when the bounded run is suitable for `All`;
- this dossier for the baseline result.

Required proof:

- the fixture completes reliably before any fix;
- increasing only irrelevant globals demonstrably increases work;
- no generated request, C, executable, or profile output is committed.

Implemented by `benchmarks/compiler_perceus_memory` and documented in
`benchmarks/README.md`. The baseline and exact commands are recorded under
"Bounded Regression Baseline" above. The runner is intentionally excluded from
`bench.sh all` because it measures compiler execution rather than runtime
language performance and has a cold bridge-preparation step.

### Slice 1: Preserve Existing Definition Identities (Complete)

**Independent value:** fixes a latent correctness bug in the current resolver
without changing phase ownership or the surrounding algorithm.

Change `rename_shadow_var_refs` so a name-based repair applies only to a
`CoreVar` whose `def_id` is `None`. An existing identity is authoritative even
when the variable name matches a global.

Tests in `compiler/blorp/tests/test_compiler_core_perceus.brp`:

- a same-named variable with a different `def_id` remains unchanged;
- an unresolved same-named variable still receives the unique global id;
- a resolved mutable assignment target is not rebound by name.

Required proof:

- focused Perceus tests pass;
- existing global lifecycle and mutable-global release tests pass;
- generated Core differs only in the incorrect overwrite case.

This is intentionally a correction to the current production path. It does not
wait for the later phase move.

Implemented in `compiler_core_perceus.brp` with an explicit private rewrite
policy. Global-reference repair rewrites only unresolved matching variables,
while Perceus match-binding freshening retains its existing behavior of
rewriting every matching reference. This keeps an existing `def_id`
authoritative without conflating two distinct uses of the shared scope-aware
traversal. Existing match-freshening coverage now uses explicit definition
identities so the all-matching policy cannot regress to unresolved-only repair.

Verification is recorded with Slice 2 because the final identity tests exercise
both changes together.

### Slice 2: Bound Work To Names That Can Occur In A Body (Complete)

**Independent value:** contains the 45 GB failure with a conservative
performance guard while preserving the current resolver's semantics.

Collect a superset of value-reference names in one linear walk at each Perceus
consumer of a function body or global initializer. Use that set only to skip
per-global rewrites whose name cannot occur in the body. The existing
scope-aware resolver remains authoritative for names that may occur. Slice 2
does not persist this derived set across the separate resolution and ownership
steps; doing so would add cross-step state for two bounded linear walks.

The collector must cover `VarExpr` reads, assignment targets, nested lambdas,
match bodies, loops, concurrent forms, selects, and all other Core children. A
false positive costs extra work but is semantically harmless. A false negative
would skip required ownership handling, so exhaustiveness must be tested and
reviewed as a correctness property. This is not name guessing: the names do
not decide binding identity; they only gate whether the existing exact work can
possibly be relevant.

Tests in `compiler/blorp/tests/test_compiler_core_perceus.brp`:

- many irrelevant globals leave an unrelated body unchanged;
- a global read in every major nested Core form is still resolved;
- a mutable global appearing only as an assignment target is still resolved;
- a local with the same name continues to follow existing shadow rules.

Required proof:

- the Slice 0 fixture becomes effectively insensitive to irrelevant globals;
- the original global ownership/leak tests remain unchanged and passing;
- compiler-sized backend memory is measured only after the bounded fixture
  passes, and completes without machine-wide swapping.

This slice is a valid stopping point. It removes the catastrophic multiplier
without changing ownership semantics. The conservative name facts may later
become exact identity facts, but their immediate use is complete.

Implemented by extending the existing exhaustive reference traversal in
`compiler_core_dce.brp`, rather than adding a second Core matcher. An explicit
collection mode keeps the two consumers separate:

- DCE gathers function, global-name, and type reachability facts;
- Perceus gathers candidate source names, resolved value reads, and resolved
  invalidations from assignment and drop ownership actions.

Candidate names are a conservative prefilter for legacy unresolved-global
repair. The shared collector includes assignment targets so a write-only mutable
global is still repaired. Resolved facts retain the complete `CoreVar`; Perceus
then compares qualified name and definition id, so module-local id collisions
and same-named lexical values cannot select the wrong global. Exact result-alias
proofs use invalidations to reject mutable rebindings and drops before a returned
value. Packed tensor elements are now traversed by the shared collector as well.

The collector deliberately includes lexical locals as harmless name false
positives. Names only decide whether the existing scope-aware repair can be
skipped; exact identity remains authoritative for ownership selection.

The pinned bootstrap can treat an unchanged aggregate return as borrowed,
forcing later COW updates to copy every accumulated list. The shared traversal
therefore gives each recursive step a fresh `DceFacts` record shell while
preserving the lists themselves. This is semantically neutral and benefits both
DCE and Perceus without duplicating traversal code.

Sanitizer diagnosis also exposed a production-only identity mismatch. A
`CoreGlobal` stores its canonical identity in `CoreGlobal.def_id`, while its
embedded `CoreVar` may still have `def_id = None`. Test constructors had
previously populated both fields and masked the mismatch. `build_env` now
normalizes the `CoreVar` from the declaration id at the environment construction
boundary. Global repair consequently assigns the canonical identity, and later
ownership filtering compares qualified `(name, def_id)` identities instead of
treating same-named locals or same-id declarations from another module as the
global. Once a reference is resolved, textual shadowing no longer overrides its
identity. Production-shaped immutable and mutable regressions cover this
representation.

Borrowed-result alias analysis also has a separate exact-identity path. It
follows only result-producing operands and uses call result contracts directly,
so an aliasing same-named argument and an unrelated exact reference cannot be
combined into a false ownership fact. This avoids both the prior correctness
ambiguity and rebuilding a whole reference index for every nested alias query.

Post-Slice 2 medians from three unsampled runs on the same Apple M4 host:

| Globals | Elapsed | Peak RSS | Baseline elapsed | Baseline peak RSS |
|---:|---:|---:|---:|---:|
| 24 | 0.363s | 42,975,232 bytes | 0.404s | 56,033,280 bytes |
| 384 | 0.396s | 48,021,504 bytes | 2.666s | 251,215,872 bytes |

The 384-global fixture is now effectively insensitive to irrelevant globals.
Against the recorded baseline it is about 86% faster and uses about 81% less
peak RSS. A final sampled 384-global run reported 33,554,432 bytes of physical
footprint, 33,554,432 bytes of `MALLOC_SMALL`, and 339,216 allocations. Relative
to the Slice 0 sampled baseline, those are reductions of about 86%, 86%, and
90%, respectively. Sampled elapsed time remains excluded from timing comparisons.

Verification before the final shared-reference refinement on 2026-07-19:

- combined closure and Perceus suites: 165 passed, 0 failed;
- combined closure and Perceus ASan/UBSan run: 165 passed, 0 failed;
- the pinned-bootstrap renderer replayed the 8,032,480-byte runtime request
  successfully under ASan/UBSan and in an ordinary build;
- compiler Core ASan/UBSan gate: 699 passed, 0 failed;
- runtime gate: 4,822 passed, 0 failed;
- compiler-deep gate: 2,134 passed, 0 failed;
- compiler-Blorp ASan/UBSan gate: 1,835 passed, 0 failed;
- all 12 test gates in the final split run: 14,513 passed, 0 failed;
- global record/union lifecycle runtime test: 1 passed, 0 failed;
- string-literal lifecycle leak baseline: 404 allocations, 404 releases,
  0 leaked bytes;
- a production `make` completed successfully with the changed compiler.

Verification after shared reference collection, global-identity
normalization, exact result-alias hardening, and formatting:

- focused DCE and Perceus suites: 199 passed, 0 failed;
- focused Perceus ASan/UBSan run: 184 passed, 0 failed;
- compiler-Blorp ASan/UBSan gate: 1,847 passed, 0 failed;
- production self-host build: passed;
- compiler-deep gate: 686 passed, 0 failed;
- runtime gate: 4,822 passed, 0 failed;
- leak gate: 403 passed, 0 failed;
- focused test-runner suite: 45 passed, 0 failed;
- FIFO safety suite: 5 consecutive runs of 4 passed, 0 failed;
- fresh default compiler-unit, compiler, runtime, leak, doctest, and CLI matrix:
  9,426 passed, 0 failed;
- FIFO read safety suite: 4 passed, 0 failed across three consecutive runs;
- `make quality`: passed;
- three-run benchmark medians: 0.363s and 42,975,232-byte peak RSS with
  24 globals; 0.396s and 48,021,504-byte peak RSS with 384 globals.

The broader affected gates above have been rerun for this mergeable checkpoint.

### Slice 3: Precompute Global Declaration Facts Once (Complete)

**Independent value:** removes repeated `global_name_count` scans and gives
duplicate-name behavior one explicit construction boundary.

At `PerceusEnv` construction, classify global names as unique or ambiguous and
deduplicate repeated identical global identities according to one documented
rule. Replace `global_name_is_unique` calls in body rewrites with indexed
lookups. Preserve existing resolution behavior except for the explicit exact
duplicate rule: repeated copies of one `(qualified name, def_id)` are one
candidate rather than an ambiguity.

Tests:

- one unique global is classified as resolvable;
- two distinct same-named globals remain ambiguous;
- repeated declarations of the same exact identity follow the documented
  deduplication or rejection rule;
- module-local id collisions do not become cross-module matches.

Required proof:

- `global_name_count` is deleted from the hot path;
- declaration classification is `O(G)` once per program;
- focused Perceus and pipeline tests pass;
- the Slice 0 fixture records the incremental timing/memory effect.

This index may be moved to `compiler_core_resolve.brp` later, but this slice
must use it immediately and must not expose a broad premature API.

Implemented in `compiler_core_perceus.brp` with a private
`GlobalNameResolution` index constructed alongside `global_values`. The index
stores one canonical definition id for a resolvable qualified name and an
explicit ambiguous state otherwise. The name is not duplicated in the value;
it is already the dictionary key. Repeated declarations of the same exact
qualified `(name, def_id)` identity remain one resolvable candidate; a second
identity with the same qualified name makes the entry permanently ambiguous.
Because the key is the qualified textual name and exact equality also requires
the definition id, equal module-local ids under different qualified names
remain independent. `global_name_count` and its repeated linear scans are
deleted. A parallel `CoreVar` candidate list contains only the first
declaration for each qualified name, so exact duplicate declarations do not
trigger redundant whole-body rewrites; the index still vetoes that candidate
if a later distinct identity makes the name ambiguous.

Focused regressions cover unique resolution, distinct same-name ambiguity,
exact duplicate deduplication, and equal ids under different qualified names.
The focused Perceus suite passes 187 tests.

Post-Slice 3 medians from five unsampled, interleaved runs on the same Apple M4
host are shown below. Both baseline and changed renderer helpers were produced
by the same freshly built compiler; this controls for unrelated generated-code
size and speed differences that made earlier batches incomparable.

| Globals | Slice 2 elapsed | Slice 3 elapsed | Slice 2 peak RSS | Slice 3 peak RSS |
|---:|---:|---:|---:|---:|
| 24 | 0.136s | 0.138s | 42,991,616 bytes | 42,876,928 bytes |
| 384 | 0.179s | 0.178s | 47,382,528 bytes | 47,300,608 bytes |

The one-time index is therefore effectively neutral on this already bounded
fixture: about 1% slower at 24 globals and 0.6% faster at 384 globals, with
peak RSS lower by less than 0.3% at both sizes. Its independent value is a
clear `O(G)` declaration-classification boundary and removal of repeated
`global_name_count` scans without a measurable memory penalty. The only
resolution change is the documented exact-duplicate rule, which makes
repeated copies of one identity behave as one declaration.

Production `/usr/bin/time -l make` runs also completed successfully. An
intermediate build took 341 seconds and reported a 17,778,098,176-byte maximum
resident set size. The first exact-final rebuild reported only 7,912,521,728
bytes, but a forced cold repeat with that newly produced compiler took 265
seconds and reported 16,186,966,016 bytes. The repeat sampled its renderer at
roughly 15 GB of RSS and reported no swaps. The 7.9 GB run is therefore
treated as a cache/phase-state outlier; 16.19 GB is the conservative current
cold-build peak.

That compiler-sized peak remains far above the bounded Perceus fixture and is
not claimed as a Slice 3 solution. Process sampling showed a large renderer
helper followed by substantial host-side response handling, so the remaining
whole-build pressure includes frontend and bridge ownership outside this
slice's declaration-classification scope.

Post-Slice 4 compiler-sized lifetime hardening removed the largest concurrent
peak. A cold GitHub `ubuntu-latest` build was terminated while the OCaml host
retained its prepared Core graph and the Blorp `emit_core_c` helper decoded an
independent copy. Replaying the captured 144,561,870-byte request isolated the
renderer at 6,641,303,552 bytes maximum RSS. The host also kept
`prepared_core` live because foreign-link metadata was computed only after the
renderer returned.

Foreign metadata is now collected before emission, and the host compacts its
heap immediately before the explicitly selected `emit_core_c` subprocess.
Parser, typechecker, and ordinary renderer requests do not pay that compaction
cost. A cold public-CLI rebuild on the same Apple M4 host completed in 250.72s
with 6,171,443,200 bytes maximum RSS and no swaps. Live sampling showed the
host near 1.15 GB while the renderer was active; the host's later response
processing peak occurred only after the renderer exited. This is about 62%
below the conservative 16.19 GB cold-build peak and restores a bounded process
lifetime boundary without changing Core or emitted-C semantics.

That first measurement reused the content-addressed renderer helper. A second
run with an explicitly empty bridge cache forced helper compilation as well as
the public-CLI build. It completed in 295.15s with 7,498,465,280 bytes maximum
RSS and no swaps. While the newly compiled renderer was active, live sampling
showed about 0.85 GB in the host and 4.0 GB in the renderer. The empty-cache
result remains about 54% below the former conservative peak and covers the
cold-cache path used by a fresh CI source revision.

Final Slice 3 verification:

- focused Perceus suite: 187 passed, 0 failed;
- focused Perceus ASan/UBSan run: 187 passed, 0 failed;
- focused Core pipeline suite: 2 passed, 0 failed;
- global record/union lifecycle runtime test: 1 passed, 0 failed;
- string-literal lifecycle leak baseline: 404 allocations, 404 releases,
  0 leaked bytes;
- `make quality`: passed;
- two production self-host builds from changed source: passed;
- immediate follow-up `make`: passed and reported `Blorp CLI up to date`.

### Slice 4: Replace The Per-Global Resolver With One Core Walk

**Independent value:** replaces the pathological algorithm and deletes its old
implementation without also changing where the pipeline invokes resolution.

Add an indexed, scope-aware resolver to
`compiler/blorp/src/stage_09_core/compiler_core_resolve.brp`:

```blorp
pure func resolve_global_value_refs(program: CoreProgram) -> CoreProgram
```

It resolves unresolved global value reads and assignment targets in one
program pass. It must preserve every existing `def_id`, carry an explicit
lexical scope, and refuse ambiguous name matches. Keep callable resolution
unchanged in this slice.

`CorePerceus.insert_drops_program` should call this operation at the same point
where it currently calls `resolve_program_global_refs`. This deliberately
preserves the production stage order while replacing the algorithm. After the
new call works, delete Perceus's old global-resolution implementation in this
same slice; do not leave it as a fallback.

Tests first in `compiler/blorp/tests/test_compiler_core_resolve.brp`:

- unique unresolved global read and mutable assignment target;
- existing different identity is preserved;
- distinct duplicate names remain unresolved;
- repeated identical identities follow Slice 3's rule;
- function parameters;
- `LetExpr` and `BorrowLetExpr`, including RHS/body scope differences;
- lambda and resource-scope binders;
- literal, length, and constructor match bindings;
- every `For*Expr` binder;
- pre-closure and post-closure concurrent binders;
- select receive-arm binders;
- tail-recursive parameters and list-spread cursors;
- tensor raw-view and list-handoff internal binders.

Deletion from `compiler_core_perceus.brp`:

- `resolve_global_refs_in_expr`;
- `resolve_function_global_refs`;
- `resolve_global_initializer_refs`;
- `resolve_decl_global_refs`;
- `resolve_program_global_refs`;
- global-resolution-only portions of `rename_shadow_var_refs`.

Separate any match-binding freshening that still uses
`rename_shadow_var_refs` into a narrowly named helper before deleting the
global-resolution portion. Move unresolved-reference tests from Perceus to
`test_compiler_core_resolve.brp`; keep ownership tests in Perceus.

Required proof:

- the resolver touches each body once regardless of global count;
- all scoped-form tests pass;
- `rg` finds no second global name-resolution implementation in Perceus;
- `insert_drops_program` still accepts the same input contract as before, so
  direct callers and named-stage behavior do not change in this slice;
- global lifecycle, leak, and Core sanitizer gates pass.

This is a complete algorithm replacement. If the roadmap stops here, the
compiler has one correct resolver and bounded behavior; only its orchestration
location remains later than desired.

Implemented as one indexed, scope-aware walk in `compiler_core_resolve.brp`.
The index maps each qualified global name to either one canonical definition
id or an explicit ambiguous state. Exact duplicate declarations retain the
Slice 3 behavior of one resolvable identity; distinct identities sharing a
name remain unresolved. Existing ids are authoritative. The traversal handles
every Core binder explicitly and resolves ordinary expression children through
the shared context-aware traversal API.

Sanitizer testing of a freshly compiled renderer helper found that the pinned
bootstrap did not retain managed values captured by repeatedly invoked generic
callbacks. The first failure freed the resolution dictionary between top-level
declarations; the second freed an extended match scope between nested match
results. The durable fix was to make
`map_core_expr_children_with_context` and
`map_core_match_results_with_context` pass context as ordinary function
arguments throughout their complete traversals. Their list/container helpers
use explicit loops, avoiding both managed captures and a pinned-bootstrap C
declaration-order bug for private generic functions used as first-class
callbacks. The older non-context APIs are now thin adapters over the same
implementations, so there is one traversal definition for each operation.
The resolver's recursive entry also creates a fresh record shell for each
edge. This keeps the shared index and current scope owned for the full child
call without deep-copying either collection; an official Core sanitizer run
found and now covers the sibling-child lifetime that requires this shell.

`insert_drops_program` invokes the new resolver at the former Perceus resolver
location. The per-global implementation, its indexes, its unresolved-only
rewrite policy, and nine resolution-only Perceus tests were deleted. Match
binding freshening retains a single narrowly scoped name rewrite with no
global-resolution mode. Ownership tests remain in Perceus; 16 global-value
identity and scope regressions, including the sibling-scope lifetime case, now
live in CoreResolve.

Post-Slice 4 medians from five unsampled, interleaved runs on the same Apple M4
host:

| Globals | Elapsed | Peak RSS |
|---:|---:|---:|
| 24 | 0.320s | 44,482,560 bytes |
| 384 | 0.377s | 48,775,168 bytes |

The larger fixture adds 360 global declarations and their emitted C, but no
longer multiplies each function body by the global count. Elapsed time grows
about 18% and peak RSS about 10%, versus the original roughly 6.6x elapsed
growth. Both runs validated the generated C.

A post-Slice 4 `--vmmap` sample of the 384-global fixture reported 79,549
default-zone allocations, a 9,076,736-byte physical footprint, and 20,971,520
bytes of `MALLOC_SMALL`. The comparable pre-Slice 4 sample reported 3,510,453
allocations and a 238,131,609-byte physical footprint. Sampling perturbs
elapsed time, but the allocator counts confirm that the resolver's
sanitizer-required ownership shells do not offset the algorithmic reduction.

Final Slice 4 verification:

- focused CoreResolve suite: 24 passed, 0 failed;
- focused Perceus suite: 178 passed, 0 failed;
- fresh renderer helper under ASan/UBSan: both focused suites passed with no
  sanitizer findings;
- official focused Core sanitizer gate: 730 passed, 0 failed;
- focused Core pipeline suite: 2 passed, 0 failed;
- global record/union lifecycle runtime test: 1 passed, 0 failed;
- string-literal lifecycle leak baseline: 404 allocations, 404 releases,
  0 leaked bytes.

### Slice 5: Move Resolution To The Core Pipeline Boundary

**Independent value:** Perceus consumes resolved Core and no longer owns or
orchestrates name binding.

In `compiler_core_resolve.brp`, expose one operation that establishes the
complete current resolution boundary:

```blorp
pure func resolve_core_bindings(program: CoreProgram) -> CoreProgram
```

It should combine the existing callable-id resolution and Slice 4's global
value resolution without adding another full-program reconstruction when one
scoped walk can establish both facts clearly. Replace
`CoreResolve.resolve_callable_id_calls` at the existing resolution stage in
`compiler_core_pipeline.brp`, and remove the Slice 4 call from
`CorePerceus.insert_drops_program`.

Update direct Perceus tests to construct resolved Core explicitly. Add a
pipeline test proving that global reads and assignment targets have exact ids
before the Perceus stage. Verify named-stage entry points do not bypass the
resolution boundary.

Required proof:

- `rg` finds no binding-resolution call or implementation in Perceus;
- direct Perceus tests describe ownership, not name binding;
- the pipeline has one `resolve_core_bindings` boundary;
- `insert_drops_program` builds its environment once from resolved input;
- compiler pipeline, Core sanitizer, runtime lifecycle, and leak gates pass;
- Slice 0 records the cost removed by combining the resolution walks.

This slice changes orchestration and phase contracts, not binding or ownership
semantics. It is independently useful because every later ownership pass can
now rely on resolved Core.

### Slice 6: Select Borrowed Globals By Exact Reference Identity

Status: exact selection and alias matching were pulled forward while hardening
Slice 2; final gate and compiler-sized measurement evidence remains to close
this slice formally.

**Independent value:** ownership work becomes proportional to the globals a
body actually references, and same-name coincidences cannot influence it.

Add the smallest precise types needed by Perceus, for example:

```blorp
record CoreReferenceFacts {
	global_def_ids: Set[Int]
}
```

If definition ids are module-local in assembled Core, use an explicit compound
identity instead. Collect facts once for each function body and global
initializer, then look up only referenced managed globals. Preserve the
existing retain/protect helpers for that small set; do not consolidate their
semantics in this slice.

Tests in `test_compiler_core_perceus.brp`:

- hundreds of irrelevant managed globals add no `DupExpr` or `DropExpr`;
- one referenced managed global is retained exactly where required;
- primitive globals are excluded from managed retention;
- two referenced managed globals are both retained;
- a global initializer includes its dependencies and excludes itself;
- mutable global assignment still releases its previous owner;
- exact identity wins over a same-name coincidence.

Required proof:

- no ownership pass walks a body once per program-wide global;
- the conservative name facts from Slice 2 are deleted or reduced to a useful
  general role, not maintained as a second identity system;
- generated Core and C preserve expected dup/drop behavior;
- all focused ownership, sanitizer, lifecycle, and leak tests pass;
- before/after compiler-sized memory and elapsed time are recorded.

### Slice 7: Make Nested Lambda Ownership Use Local Facts

**Independent value:** nested lambdas stop repeating enclosing-program global
work and make their ownership boundary explicit.

Use Slice 6's exact reference facts at each lambda body boundary. Include
only globals referenced by that lambda and avoid duplicate retention in the
enclosing body. Do not alter ordinary closure capture analysis in this slice.

Tests:

- a global referenced only in a lambda is retained at the lambda boundary;
- an unrelated outer global is ignored;
- a global referenced by both outer body and lambda is handled once at each
  semantically required boundary;
- nested lambdas and shadowed local names preserve ownership and identity;
- leak-check baselines cover managed strings and owning record/union storage.

Required proof:

- lambda normalization no longer receives all globals;
- focused Perceus, closure, runtime, and leak tests pass;
- a nested-lambda fixture records lower traversal/allocation counts.

### Slice 8: Profile Before Consolidating Borrowed-Parameter Passes

**Independent value:** produces a concrete decision about the remaining hot
path; no semantic refactor is justified merely by the former profile.

Profile these separately after Slices 2 through 7:

- call-contract annotation;
- borrowed call protection;
- aggregate retention;
- borrowed-result retention;
- ownership summaries;
- drop insertion;
- consumed-parameter balancing;
- nested lambda normalization.

Land the profile instrumentation/results as a self-contained diagnostics or
benchmark change if they are generally useful. If no borrowed-parameter pass
is material, stop here and retain the simpler separate passes.

### Slice 9: Consolidate One Measured Ownership Concern

**Independent value:** removes one demonstrated multiplier without creating a
monolithic ownership visitor.

Only if Slice 8 identifies a dominant pass, choose one concern and transform
all applicable borrowed values in one body traversal. Introduce a precise
borrowed-value index, share lexical-scope handling where it removes actual
duplication, and preserve exact `CoreVar` identities. Do not combine call
protection, aggregate retention, result retention, and drop insertion in one
PR.

Required proof:

- the PR names one ownership invariant;
- before/after profiles justify it;
- generated Core snapshots make dup/drop changes reviewable;
- focused and broad ownership gates pass.

Repeat Slice 9 independently for another concern only when a fresh profile
supports it.

### Slice 10: Decide Typed Binding Identity Separately

**Independent value:** this is an architectural decision record, not a hidden
prerequisite for the memory fix.

Investigate a typed representation such as:

```blorp
union CompilerResolvedValueTarget:
	CompilerResolvedLocalValue(Int)
	CompilerResolvedModuleValue(String, Int)
```

Answer before implementation:

- Are `CompilerEnv.next_def_id` values graph-global or module-local?
- Should all local values receive ids, or only module/global bindings?
- How are imported module values represented after alias resolution?
- Can `CompilerTypedAssignTarget` and name reads carry the same identity?
- Can Core lowering consume it without mutable context through every call?
- Does the correctness benefit justify typed-AST and JSON growth?

If adopted, implement it as its own roadmap with migration slices across infer,
typed JSON, Core lowering, and cleanup. The production Core resolver remains a
coherent validation boundary even if this work never lands.

## Per-Slice Merge Contract

Every implementation slice above must satisfy all of these before merge:

1. Its invariant is stated in the PR. A behavior change has a failing
   regression test before implementation; a measurement-only change has a
   reproducibility check and no semantic delta.
2. It changes one production responsibility or one measured performance
   multiplier, not several adjacent concerns.
3. It has no dormant helper, disabled path, feature flag, or expectation that a
   later slice will make it useful.
4. Focused tests, relevant sanitizer/leak tests, the broad merge gates in this
   document, `make quality`, and `git diff --check` pass.
5. A performance slice records comparable before/after data; a structural
   slice records the deleted path or newly enforced phase invariant.
6. Generated Core or C is inspected whenever ownership operations can change.
7. The branch can stop after the slice without leaving two authoritative
   implementations or an undocumented phase precondition.

## Verification Matrix

### Focused semantic gates

```bash
./blorp test --no-format --no-cache -j 1 --timeout 600 \
  compiler/blorp/tests/test_compiler_core_resolve.brp

./blorp test --no-format --no-cache -j 1 --timeout 600 \
  compiler/blorp/tests/test_compiler_core_perceus.brp

./blorp test --no-format --no-cache -j 1 --timeout 600 \
  compiler/blorp/tests/test_compiler_core_pipeline.brp
```

### Ownership and runtime gates

```bash
scripts/test compiler-core-sanitize --serial
scripts/test runtime leak --serial
```

At minimum, explicitly rerun:

- `tests/test_blorp/memory/test_global_record_union_lifecycle.brp`;
- `tests/test_blorp/memory/leak_check_baselines/string_literal_lifecycle.brp`;
- mutable global assignment tests;
- nested lambda capture tests;
- record/union/list managed-global storage tests.

### Broad merge gates

```bash
make
scripts/test compiler-unit compiler runtime leak doctest cli
make quality
git diff --check
```

### Performance evidence

Use the same machine, compiler mode, request, and sampling interval before and
after. Record:

- Core declarations and request bytes;
- backend elapsed time;
- peak RSS;
- macOS physical footprint or Linux peak anonymous memory;
- allocator region totals where available;
- generated C bytes and native C compile cost.

Immediate performance target for Slice 2:

- the backend helper completes the compiler-sized request without machine-wide
  swapping or OOM;
- physical footprint falls by at least 5x from the 44.9 GB observation on the
  same fixture;
- the synthetic fixture is effectively insensitive to irrelevant global count;
- no correctness or leak regression is accepted to reach the target.

The longer-term target is a backend comfortably below 4 GB for the current
compiler program. Slice 2 should not be rejected solely because separate JSON
materialization or typecheck costs keep it above that target, but it must
demonstrably remove the irrelevant-global multiplier it claims to address.

## Secondary Costs, Kept Out Of These Slices

The investigation found important memory costs outside Perceus:

### Typecheck bridge buffering (Complete)

The typecheck helper already streamed one artifact per line, but the OCaml host
used `run_process_capture`, buffered the complete response, split the resulting
448 MB string, and only then decoded all artifacts. The helper simultaneously
materialized large typed values. Earlier measurements recorded separate 14.33
GB helper and 4.04 GB host peaks.

The host now redirects only `typecheck_graph` stdout to a private temporary
file, waits for the helper to exit, and decodes the response one nonempty line
at a time. Parser and renderer responses retain their existing in-memory
transport. The decoder still retains the complete typed graph required by the
semantic middle, but it no longer retains the complete serialized response or
the list produced by `String.split_on_char`. Process failure diagnostics read
bounded excerpts while bridge statistics use the actual output file sizes.

On the compiler-sized production request, the response file reached
456,501,933 bytes. Live sampling while the helper was active showed about 5 MB
in the waiting host and 5.2 GB in the helper; the response file was removed
before backend emission began. A build with an explicitly empty bridge cache
completed in 300.28 seconds with 7,500,136,448 bytes maximum single-process RSS
and no swaps. That headline maximum is effectively unchanged from the prior
7.50 GB empty-cache build because a later backend process remains the largest
single process. This slice instead removes the serialized-response overlap at
the constrained typecheck phase.

Follow-up profiling rejected helper-side artifact projection as the immediate
typecheck target. A direct JSON-emission experiment still died with zero output
bytes, proving the peak preceded artifact projection and serialization.
Temporary stage probes then localized the failure to graph-wide CTFE dependency
preparation. Under an 8 GB `linux/arm64` Docker limit, the helper attempted to
prepare 129 typed dependency programs and was killed while adding dependency 63,
`compiler_core_reuse`. The killed helper had about 7.02 GB anonymous RSS and the
container had peaked at 7,687,340,032 bytes. No typechecked artifact had been
emitted.

The graph builder treated every explicit import as a CTFE dependency whenever a
module contained any immutable global. That made a literal such as
`DEFAULT_WIDTH: Int = 100` retain the module's entire typed import closure even
though evaluating it cannot consult imported functions or values. It also made
an unused broken import incorrectly prevent an otherwise closed global from
being evaluated.

The graph now proves a deliberately narrow set of parsed initializer trees to
be import-independent: primitive literals and recursively closed operators,
ascriptions, lists, tuples, records, dictionaries, vectors, blocks, and
conditionals. Unknown, name-bearing, and call-bearing expressions retain the
existing conservative dependency closure. A regression verifies that closed
literal, list, and binary initializers evaluate successfully despite an unused
import whose function body does not typecheck.

With that change, the same constrained build completed typecheck and entered the
renderer helper. The renderer was then killed at about 7.02 GB anonymous RSS;
the container peak was 7,681,785,856 bytes. The complete 8 GB build therefore
remains red, but the failure moved across a process boundary to the late backend.
The next measured memory slice belongs there. Direct JSON emission remains a
possible later optimization only after a profile shows projection or
serialization at the live peak.

#### Exact `compiler_infer` replay (2026-07-23)

The later compiler migration exposed a separate self-hosted typecheck peak, so
the bridge now supports exact request capture through
`BLORP_COMPILER_CAPTURE_TYPECHECK_GRAPH_REQUEST`.
`benchmarks/compiler_typecheck_replay` executes that request in an isolated
process with a timeout, a Linux address-space or macOS sampled-RSS limit,
file-backed output, response validation, request/helper hashes, and
phase/module markers.

The captured `compiler_infer.brp` request is 1,396,350 bytes with SHA-256
`72ed96735b70982cd63bcb4688b3233f73d31ecccb457ff32648587e0067639e`.
Normal replays established:

| Selection | Before peak RSS | After peak RSS | Before time | After time |
|-----------|----------------:|---------------:|------------:|-----------:|
| target typecheck, full graph context | 2,073,985,024 bytes | 2,016,165,888 bytes | 22.48 s | 22.31 s |
| full selected graph | 3,177,906,176 bytes | 3,084,386,304 bytes | 25.61 s | 25.54 s |

The target-typecheck peak fell by 57,819,136 bytes (2.8%), and the full graph
peak fell by 93,519,872 bytes (2.9%), with effectively unchanged elapsed time
and byte-identical responses. A focused recursive resource-scan fixture fell
from about 222,887,936 bytes to 51,773,440 bytes.

The implemented reductions are deliberately narrow:

- declaration resource-shape traversal expands only an alias head before
  visiting children, avoiding recursive reconstruction at every node;
- immutable semantic and value types are shared across value slots and typed
  expression metadata instead of being recursively copied into equivalent
  fields;
- the type-shape memo is reset at declaration boundaries and before the final
  state escapes;
- typed artifacts are emitted one declaration at a time, and graph responses
  are written in chunks without constructing a second program-sized
  `JsonValue` or serialized string;
- each typechecked artifact falls out of lexical scope after its response is
  emitted; graph preparation, typecheck, projection, emission, and artifact
  scope boundaries are visible in opt-in trace markers. Prepared graph modules
  remain live for the request.

The markers rule out CTFE and final projection as the dominant peak for this
request. It has no CTFE dependency preparations. Graph parse and importable
preparation reach roughly 155 MB; most growth happens while constructing the
typed target. Prior selected modules leave roughly 1.26 GB of allocator
high-water before the target starts. Typechecking only the target reaches about
2.0 GB while still retaining the full prepared graph context.

`--memstats` is intentionally perturbative and is disabled in normal
measurements. One target-typecheck diagnostic run timed out at 120 seconds near
3.81 GB sampled RSS. Its `typecheck_complete` marker reported 189,594,195
allocations, 162,679,722 releases, 26,914,473 current objects, and
1,849,339,381 requested allocation bytes. Projection raised total allocations
to about 201.75 million without increasing current objects. This is evidence
of extreme allocation churn plus a large live typed representation; it is not
evidence of an unbounded leak.

The remaining 2.0 GB target-typecheck and 3.08 GB full-graph peaks are not
resolved by this slice. The next measured work should inventory recursive
`compiler_type_copy` boundaries and reduce only copies whose values are
provably immutable and non-mutated. Environment-wide ownership changes or a
typed-AST representation redesign require separate tests and measurements;
they should not be inferred from RSS high-water alone.

#### Bounded full CLI rebuild (2026-07-23)

A native `linux/arm64` Docker rebuild was run with swap disabled and an
effective Docker VM ceiling of 7.751 GiB. The current CLI did not finish
building, so the compiler inference tests never started. The container was OOM
killed while executing the `compiler_cli_main` `typecheck_graph` action:

- cgroup peak: 7,664,627,712 bytes;
- largest observed helper RSS: 7,127,982,080 bytes;
- request size reported by the host: 6,958,706 bytes;
- helper exit: 137, with one cgroup `oom_kill` event.

This rules out the earlier `compiler_infer` target replay as a sufficient proxy
for a full self-hosted build. The failing process is a typecheck bridge launched
during `make`, before the requested `blorp test --no-cache` workload.

An exact local `compiler_cli_main` request was then captured before helper
launch. It is 6,963,323 bytes with SHA-256
`4070fed72199e1d63e31e03571c58e2d331e49f7aed7855c33045d29538e7589`.
The request contains 145 prepared modules, 145 selected module targets, and 597
resolved imports. Bounded prefix replays against the preserved Linux helper
produced:

| Selected module targets | CTFE dependencies completed | Artifacts emitted | Peak bytes | Result |
|------------------------:|----------------------------:|------------------:|-----------:|--------|
| 0 | 0 | 1 | 1,044,066,304 | completed |
| 25 | 0 | 26 | 1,916,477,440 | completed |
| 50 | 6 | 41 | 7,641,427,968 | 180 s timeout |
| 75 | 33 | 18 | 7,640,506,368 | 180 s timeout |
| 145 | 33 | 19 | 7,649,677,312 process RSS | terminated at diagnostic deadline |

The 50-target replay stalled while starting `compiler_core_consume_specialize`.
The 75-target replay stalled while starting `compiler_parsed_ast_traverse`.
The full replay completed all 33 CTFE dependency preparations, emitted 19
selected-module artifacts, and remained near the ceiling while starting
`compiler_type_name_metadata`.

This establishes two distinct multipliers:

1. selecting the first 25 frontend/type modules remains below 2 GB;
2. crossing into Core modules induces retained CTFE programs and selected
   module typechecking/emission pressure, taking the process to the 8 GB
   ceiling before even half of the selected graph is emitted.

The lexical typed-artifact boundary and chunked response remove projection
overlap, but process RSS does not fall between modules. The next correction
must therefore bound retained graph-wide CTFE/typecheck state or move selected
module typechecking to independently reclaimable processes. Unbounded local
full builds remain unsafe; use a cgroup or Docker memory ceiling until this
graph-width multiplier is removed.

#### Structural retention inventory (2026-07-23)

The typecheck helper now has a separate opt-in structural inventory path.
Normal compiler requests do not traverse or retain inventory metadata.
`benchmarks/compiler_typecheck_replay` enables it for diagnostic replays and
aggregates one graph record, one record per retained CTFE typed program, and
one record per emitted artifact. Recursive typed-expression counts provide a
stable logical-size comparison without enabling perturbative runtime
`memstats` or serializing retained CTFE programs.

Three bounded macOS replays of the exact `compiler_cli_main` request produced:

| Selection | Retained CTFE programs | Retained CTFE declarations | Retained CTFE expression nodes | Duplicate artifacts | Peak RSS | Time |
|-----------|-----------------------:|---------------------------:|--------------------------------:|--------------------:|---------:|-----:|
| target only | 0 | 0 | 0 | 0 | 926,138,368 bytes | 5.52 s |
| `compiler_core_closure` plus target | 6 | 1,291 | 31,710 | 0 | 2,220,326,912 bytes | 15.24 s |
| retention slice plus target | 6 | 1,291 | 31,710 | 6 | 2,753,265,664 bytes | 19.79 s |

The retention slice selects `compiler_core_closure` and the six CTFE
dependencies that its `VOID_TYPE` global requires. All six dependency modules
are also emitted artifacts. Their second typed representations contain 31,703
expression nodes, nearly matching the 31,710 nodes in the retained CTFE
programs. The largest observed logical overlap is 56,633 expression nodes
because the largest current artifact is added to all retained CTFE programs.
This confirms redundant simultaneous typed representations rather than merely
allocator high-water.

An otherwise identical `--no-inventory` control measured 2,751,496,192 bytes
and 19.65 seconds, versus 2,751,610,880 bytes and 19.75 seconds with structural
counting. The 114,688-byte peak difference is 0.004%, so the inventory walk
does not materially perturb this workload.

The prepared graph also contains 146 parsed programs covering 5,959,542 source
bytes and 9,752 declarations, plus 145 importable-module surfaces referencing
9,731 declarations. The importable declaration lists are expected to share the
parsed declarations through ARC, so those logical references are not yet
evidence of physical tree copies.

The focused feedback command is:

```bash
benchmarks/compiler_typecheck_replay "$capture" \
  --retention-slice --timeout 60 --memory-limit 4G
```

The confirmed CTFE duplication is a concrete optimization target, but 31,710
expression nodes alone do not explain multi-gigabyte RSS. Each typed node also
retains type metadata, resolved-call data, and other recursive structures, and
CTFE builds derived indexes while the source programs remain live. The next
implementation should compact or reuse CTFE dependency artifacts, then compare
this same slice before broadening the investigation.

#### CTFE artifact reuse (2026-07-23)

Selected modules that were already typechecked as CTFE dependencies now reuse
that retained typed program as their artifact input. Reuse is attempted in the
ordinary artifact import environment. It is rejected when the graph target is
an ambient prelude/trait module or is reachable through the dependency's
resolved explicit-import closure; those dependencies retain the target-aware
CTFE program and use a separate artifact typecheck. This preserves the existing
case where a CTFE dependency intentionally imports the target surface.

Four matched retention-slice runs after the change produced:

| Run | Reused artifacts | Duplicate artifacts | Peak RSS | Time |
|----:|-----------------:|--------------------:|---------:|-----:|
| 1 | 6 | 0 | 2,222,555,136 bytes | 17.28 s |
| 2 | 6 | 0 | 2,223,357,952 bytes | 17.36 s |
| 3 | 6 | 0 | 2,223,767,552 bytes | 17.49 s |
| 4 | 6 | 0 | 2,223,210,496 bytes | 17.58 s |

An otherwise identical `--no-inventory` run peaked at 2,222,309,376 bytes,
confirming that reuse is active on the normal bridge path and is not an
inventory-only effect.

Against the latest pre-change inventory run at 2,751,561,728 bytes and 19.59
seconds, the first matched run reduces peak RSS by 529,006,592 bytes (19.2%)
and elapsed time by 2.31 seconds (11.8%). The six reused artifacts cover 31,703
typed-expression nodes. The conservative largest simultaneous logical count
remains 56,633 nodes because CTFE evaluation rebuilds the declaration list and
materializes global initializers even when artifact typechecking is reused.

This removes the confirmed CTFE/artifact duplication but leaves approximately
2.22 GB in the narrow slice. The remaining baseline closely matches the earlier
`compiler_core_closure`-plus-target run, so the next investigation should
measure retained CTFE metadata and graph-wide parsed/importable state rather
than extending artifact reuse.

### Core JSON duplication

The OCaml side builds a large `Lsp_json` Core tree and serialized request; the
Blorp helper parses the request and decodes another Core tree. The measured Core
request was about 144 MB. Streaming or a more compact boundary can help, but it
does not explain 44.6 GB of small allocations by itself.

### Callable resolution list scans

`compiler_core_resolve.brp` currently stores callable identities in a list and
checks each selected call with `callable_identity_exists`. Indexing callables
can be a separate measured slice if it keeps module-local identity semantics
explicit. It is not part of Slice 4 because it is not the primary memory cause.

### DCE traversal duplication

`compiler_core_dce.brp` maintains an exhaustive recursive collector while
`compiler_core_traverse.brp` maintains an exhaustive child mapper. A reusable
state-threaded Core fold could simplify both DCE and reference collection. This
should be a separate reviewable refactor rather than expanding a memory slice.

## Rejected Shortcuts

- **Make strings immortal:** violates deterministic ownership and hides the
  lifetime bug.
- **Skip global retention:** reintroduces use-after-free in owning aggregates
  and managed results.
- **Open-code a name substring scan:** relies on serialized formatting and does
  not represent binding semantics.
- **Cache rewritten bodies:** retains more large Core trees and does not correct
  the algorithm.
- **Only index `global_name_count`:** removes `O(G^2)` list work but leaves
  `O(G * N)` body reconstruction.
- **Treat name presence as binding identity:** a name-presence set is acceptable
  in Slice 2 only as a conservative skip guard around existing semantics. It
  must not decide which declaration a reference denotes or survive as a second
  binding system after exact identity facts are available.
- **Move the work to runtime:** ownership decisions belong in Core and must be
  explicit before C emission.
- **Merge all Perceus passes immediately:** raises correctness risk before the
  dominant global multiplier has been removed and measured.

## Final Architecture Review Checklist

Before merging the implementation, a reviewer should be able to answer yes to
all of these:

- Is binding resolution owned by one explicit phase?
- Does resolution touch each Core body once, independent of global count?
- Are existing `def_id` values preserved?
- Are all source-level binding forms covered by scope tests?
- Can ambiguous global names remain unresolved without guessing?
- Does Perceus select globals by exact resolved identity?
- Are unreferenced globals absent from ownership traversals?
- Do global initializers and nested lambdas use the same precise rule?
- Do runtime lifecycle and leak tests still prove the original bug is fixed?
- Does the compiler-sized backend complete with materially lower memory?
- Did the change delete the obsolete workaround instead of layering another
  compatibility path over it?

## Recommended First Mergeable Change

Land Slice 0 by itself: add the bounded regression fixture and record its
baseline without changing compiler behavior. This gives every subsequent PR a
stable comparison and is safe to merge independently.

Then land Slice 1 by itself. It is the smallest production correction: an
existing `def_id` becomes authoritative, with three focused regressions and no
phase move. Do not bundle Slice 2 merely because it is the first large
performance win.

The expected sequence is therefore:

```text
Slice 0: bounded evidence
Slice 1: preserve existing identity
Slice 2: contain irrelevant-global work
Slice 3: remove repeated declaration scans
Slice 4: establish one-pass Core resolution
Slice 5: delete Perceus resolution fallback
Slice 6: drive ownership from exact reference facts
Slice 7: make lambda boundaries local
Slice 8+: profile, then optimize one remaining concern at a time
```

Typed-AST identity, bridge streaming, DCE traversal consolidation, callable
indexing, and unrelated compiler cleanup remain separate work. None is an
unstated prerequisite for merging Slices 0 through 7.
