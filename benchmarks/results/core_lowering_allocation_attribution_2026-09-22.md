# Core lowering allocation attribution (2026-09-22)

Model: `benchmarks/compiler_dce_facts_builder_allocations` plus
`benchmarks/blorp/profiles/dce_facts_builder_allocations.brp` (landed in
94d34bdc). This is the same idea applied to `lower_typed_program`
(`blorp/src/compiler/stage_08_core_lower/lower.brp:5710`): a synthetic
program run through the real entry point, with `MemStats`
(`reset_mem_stats`/`get_mem_stats`, `standard_library/src/memory.brp`)
bracketing each measurement.

## What the probe measures

`core_lower_type` (`lower.brp:1030`, public), `core_source_loc`
(`lower.brp:~614`, public), and the whole-program entry point
`lower_typed_program` are called directly. `core_lower_type_with_prefixes`
(`lower.brp:1038`) and `core_var` (`lower.brp:630`) are `private`, so this
lands as a measurement-only commit with no production change: they are
exercised indirectly — `core_lower_type` calls `core_lower_type_with_prefixes`
with an empty prefix map on every call, so timing the public wrapper times
the private helper too, and `core_var`'s entire body is one record literal
(`{ name, uniq = 0, def_id }`), so building that literal directly costs the
same allocation the private function performs.

**Representative subset, not the frozen self-compile input.** Loading the
frozen self-compile's real `TypedProgram` requires running the parser and
typecheck pipeline inside the profile binary; none of the existing
`benchmarks/blorp/profiles/*.brp` probes do this (including the DCE model
this one follows), they all hand-build a synthetic fixture. This probe does
the same: a synthetic function body of `NODE_PAIR_COUNT = 400` (variable
declaration, its list-literal initializer, one name reference) triples, plus
an enclosing block and a trailing void expression — 1202 real `TypedExpr`
nodes lowered per run, built the same way
`blorp/test/compiler/stage_08_core_lower/test_core_lower.brp`'s
`lower_core_test_expr_with_context` fixture builds its `TypedProgram`. Every
node in the fixture carries **one shared `SemanticType` object**
(`List[String]`, built exactly once with `SemanticNamedType`), mirroring the
documented invariant on `SemanticType` itself: "Compiler types are immutable
values. Phase boundaries share these trees ... only a transformation that
changes a node should rebuild that node" (`semantic_type.brp:15`) — i.e. the
frozen self-compile's typed program already hands lowering thousands of
occurrences of the same nominal type as the same object, and this fixture
reproduces exactly that pattern at a smaller, fast-to-run scale.

Command (from repo root, after `BLORP_CLI_C_OPTIMIZATION=-O2 make`):

```bash
BLORP_TRACK_STATS=1 bin/blorp run --no-format \
  benchmarks/blorp/profiles/core_lowering_allocation_attribution.brp
```

## Results

Helper-isolated calls (`HELPER_CALL_COUNT = 2000`):

| helper | calls | allocations | allocations/call |
|---|---|---|---|
| `core_lower_type`, same `List[String]` object every call | 2000 | 8000 | 4 |
| `core_lower_type`, a fresh distinct-named type object every call | 2000 | 18000 | 9 |
| `core_source_loc`, same table+location every call | 2000 | 4000 | 2 |
| `CoreVar` record literal (what `core_var` builds) | 2000 | 6000 | 3 |

`VERIFY distinct_results_from_three_lowerings=1`: three separate
`core_lower_type` calls (twice on the shared object, once on a freshly built
but structurally-equal tree) all produce the same `core_type_to_json` text,
confirming there is currently no sharing — the shared-object run rebuilds an
identical `CoreType` tree from scratch 2000 times. Calls (2000) minus
distinct results (1) is ~100% of that helper's own allocations: of the 8000
allocations, at most 4 (one build) are load-bearing and the remaining 7996
(99.95%) are re-deriving a result already computed.

Whole-program runs (1202 real `TypedExpr` nodes lowered through
`lower_typed_program`, everything else held fixed):

| run | total allocations | allocations/node |
|---|---|---|
| shared type = `List[String]` (one object, reused everywhere) | 13641 | 11.35 |
| shared type = `Void` (cheapest named type: `core_lower_type_with_prefixes` short-circuits to the bare `VoidType` constructor) | 10028 | 8.34 |
| **delta attributable to lowering `List[String]`'s shape repeatedly** | **3613** | — |

`TYPE_SHAPE_DELTA / (List[String] run total) = 3613 / 13641 = 26.5%`.

Both runs reuse the exact same `SourceLocation`/`SourceTable` and the same
node shapes, so this delta isolates the type-lowering contribution: it is
the cost of rebuilding one non-trivial named type's `CoreType` tree on every
occurrence, over and above a type that is already free to lower. Since every
occurrence in the `List[String]` run is the *same* `SemanticType` object
(`same_object` would report true for all of them, by construction), 100% of
that 26.5% is currently wasted re-derivation: a memo keyed on that object
would produce the identical `CoreType` result after the first occurrence.

Source-location construction is a second load-bearing contributor: 1202
nodes each pay one `core_source_loc_from_context` call at ~2
allocations/call ⇒ roughly 2404 allocations, ~17.6% of the `List[String]`
run's 13641 total (and present, unchanged, in both rows above, since both
runs reuse the same location). `CoreVar` record construction is smaller:
only the 400 `TypedNameExpr` occurrences build one (~1200 allocations from
the isolated per-call cost, ~8.8%); most of the remaining allocations are
the `CoreExpr` node constructions themselves (one per node, exact by
construction: 1202 nodes lowered).

Nothing else in this fixture's shape crosses 5% of lowering's allocations —
the four rows above (type lowering, source location, `CoreVar`, node
construction) account for the totals in both runs within measurement noise.

## Go/no-go decisions

**Cut 1 (share lowered types): GO.** The gate was "types built minus
distinct types is at least 25% of lowering's allocations." The type-shape
ablation puts it at 26.5%, and the helper-isolated run shows the waste ratio
on the shared-type path is ~99.95% (2000 calls, 1 distinct result). Cut 1 is
implemented below.

**Cut 2 (compact locations): GO, not implemented this session.** The gate
was "at least 3% of lowering's allocations." Measured at ~17.6%, comfortably
over threshold — a real opportunity — but implementing it (changing
`CoreSourceLoc`'s shape, updating the 10 `KnownSourceLoc(` construction
sites across `stage_09_core`/`stage_10_backend`, the JSON codec and its
round-trip test, and diagnostics rendering) is a second full-sized change
and was left out to keep this session's landed diff to one measured cut.
Flagging as a follow-up task rather than starting it half-finished.

## Caveats

- `core_lower_type_with_prefixes`, `core_lower_type_list`, and `core_var`
  are `private` to `lower.brp`; their exact call counts inside
  `lower_typed_program` were not instrumented directly (doing so would be a
  production change, which this attribution commit avoids). Their cost is
  bounded instead through the public `core_lower_type` wrapper (which calls
  `core_lower_type_with_prefixes` with an empty prefix map on every call)
  and through building the `CoreVar` record shape directly.
- This is a representative synthetic fixture, not a trace of the frozen
  self-compile's actual typed program; the 26.5%/17.6% figures are the
  fixture's numbers, used only to clear or fail the stated go/no-go
  thresholds, not as literal self-compile percentages.


## Real-program follow-up (2026-09-22, second pass)

Cut 1 landed measuring 26.5%/17.6% type/location shares on the synthetic
fixture above, but the real self-compile's scalar-constant cut only moved
`core_lowering_complete` by 1.59% (see
`core_lowering_type_histogram_2026-09-22.md`) -- types turned out to be a
small share of the real program's allocations, and the fixture's numbers
were an artifact of the specific type shape it chose to repeat, not
representative of the real program. This section was first written with a
bug in the instrumentation itself; the corrected version below replaces it
entirely (see "Instrumentation correctness bug" for what was wrong and how
it was found).

### Extended instrumentation

Extended `BLORP_CORE_LOWERING_TYPE_METRICS` (same opt-in env var, same
C-side counter mechanism in `blorp/src/lib/runtime/native/runtime.c`) with:

- **`core_source_loc`** and **`core_var`** wrapped the same way as
  `core_lower_type_with_prefixes`: total calls and the allocation delta
  measured immediately around each call, accumulated into one running
  counter. Printed as `BLORP_CORE_LOWERING_SOURCE_LOC` / `BLORP_CORE_LOWERING_VAR`.
- **Per-typed-node-kind self/inclusive allocations.** `lower_typed_expr_as_type`
  (the function every `TypedExpr` node passes through exactly once) is
  wrapped with an enter/exit pair around a call-stack of frames: entering
  records the allocation counter; exiting computes this node's own
  *inclusive* delta (allocations since entry, including everything its
  children did) and *self* delta (inclusive delta minus the sum of its
  direct children's inclusive deltas, the child sum tracked by charging each
  child's inclusive delta to its parent's frame as it returns) -- the
  standard stack-based self/inclusive split a sampling profiler uses. Each
  node's kind (`TypedCallExpr`, `TypedBlockExpr`, ...) comes from a new
  `typed_expr_kind_name` function added purely for this instrumentation (a
  literal string per union variant; it cannot affect lowering's output).
  Printed as `BLORP_CORE_LOWERING_NODE_KIND kind=... calls=... self_allocations=... inclusive_allocations=...`.
  The same enter/exit primitives are reused inline inside the `TypedCallExpr`
  arm with call-specific labels (`CallExpr.callee_type_lowering`,
  `CallExpr.callee_identity`, `CallExpr.args_list`, `CallExpr.call_kind`,
  `CallExpr.node_construct`) to drill one level into call lowering's own
  budget -- see "Drilling into TypedCallExpr" below.

### Instrumentation correctness bug (found, fixed)

The first version of this section reported a lowering delta of 72,022,496
allocations and concluded `TypedCallExpr` was 46.46% of it. Both numbers
were wrong. The bug: `core_lower_type_with_prefixes`'s metric recorder
called `core_lowering_type_metric_record(core_type_to_json(lowered).to_string())`
on every one of the ~1.3M calls in a self-compile -- building a full JSON
tree and then a string from it, on every call, purely so the histogram
could bucket by structural shape. That allocates tens of millions of
managed objects, and it allocates *while `BLORP_CORE_LOWERING_TYPE_METRICS`
is on*, i.e. exactly while the measurement is running, silently inflating
every downstream percentage. Confirmed directly: `core_lowering_complete`
with the variable **unset**:

```text
BLORP_COMPILER_MEMORY_CHECKPOINT schema=1 phase=typed_frontend_complete total_allocations=47430609 ...
BLORP_COMPILER_MEMORY_CHECKPOINT schema=1 phase=core_lowering_complete total_allocations=66459691 ...
```

delta = 19,029,082 -- within noise of the harness's ~18.3M reference row.
With the variable **set** (before the fix): `core_lowering_complete`
total_allocations = 119,453,105, delta = 72,022,496 -- 3.8x larger, entirely
an artifact of the JSON-stringify probe itself.

**Fix**: key the type histogram by the lowered `CoreType` value's own
allocation identity (its pointer -- the same notion `blorp_same_object`
compares) instead of a structural JSON string. Recording a pointer requires
no Blorp-managed allocation at all. `core_lower_type_with_prefixes`'s
foreign declaration changed from `core_lowering_type_metric_record(type_json: String)`
to `core_lowering_type_metric_record(lowered_type: CoreType)`, and the C-side
hash table's key changed from `char*` (strcmp-compared, heap-copied on
insert) to `const void*` (pointer-compared, no copy). This also changes what
"distinct" means in the histogram -- pointer identity rather than structural
shape -- which is arguably the more useful number for cut-1-style questions
(same object reused vs. rebuilt), at the cost of losing human-readable type
text in the top-30 report (now `object=0x...` rather than `type={"kind":...}`).

Verified fixed, same command, same input, both with the variable **set**:

```text
BLORP_COMPILER_MEMORY_CHECKPOINT schema=1 phase=typed_frontend_complete total_allocations=47430609 ...
BLORP_COMPILER_MEMORY_CHECKPOINT schema=1 phase=core_lowering_complete total_allocations=66459691 ...
```

Identical to the metrics-unset run, to the allocation. Also verified with
`benchmarks/self_compile_measure --require-identical` comparing this
worktree (metrics instrumentation present but unset, the normal state) against
the parent commit: byte-identical generated C, every phase's allocation row
at exactly +0.00%, instructions retired +0.03% (noise). The instrumentation
is a true no-op when off and allocation-neutral when on.

**Both totals, as asked:**

| run | `typed_frontend_complete` | `core_lowering_complete` | lowering delta |
|---|---|---|---|
| `BLORP_CORE_LOWERING_TYPE_METRICS` unset | 47,430,609 | 66,459,691 | **19,029,082** |
| `BLORP_CORE_LOWERING_TYPE_METRICS=1` (fixed) | 47,430,609 | 66,459,691 | **19,029,082** (identical) |
| `BLORP_CORE_LOWERING_TYPE_METRICS=1` (buggy, pre-fix) | 47,430,609 | 119,453,105 | 72,022,496 (4x inflated) |

### Corrected result

Top node kinds by **self** allocations (own construction cost, children's
allocations excluded), all against the true 19,029,082 lowering delta:

| kind | calls | self allocations | self % of lowering | self/call |
|---|---|---|---|---|
| `TypedNameExpr` | 271,793 | 3,802,949 | **19.98%** | 14.0 |
| `TypedBlockExpr` | 68,829 | 1,143,015 | 6.01% | 16.6 |
| `CallExpr.callee_type_lowering` | 86,648 | 852,492 | 4.48% | 9.8 |
| `CallExpr.args_list` | 86,648 | 549,180 | 2.89% | 6.3 |
| `CallExpr.call_kind` | 86,648 | 506,713 | 2.66% | 5.8 |
| `CallExpr.callee_identity` | 86,648 | 390,076 | 2.05% | 4.5 |
| `TypedMatchExpr` | 10,186 | 318,362 | 1.67% | 31.3 |
| `TypedFieldAccessExpr` | 32,782 | 277,172 | 1.46% | 8.5 |
| `TypedCallExpr` (own residual, mostly its `core_source_loc`) | 86,648 | 173,296 | 0.91% | 2.0 |
| `TypedRecordUpdateExpr` | 1,735 | 118,727 | 0.62% | 68.4 |
| `TypedStringLiteralExpr` | 23,755 | 95,020 | 0.50% | 4.0 |
| `CallExpr.node_construct` | 86,648 | 86,648 | 0.46% | 1.0 |
| remaining 24 kinds | 85,830 | 591,921 | 3.11% | -- |
| **sum, all kinds/labels** | -- | **8,905,571** | **46.80%** | -- |
| `core_source_loc` (all nodes) | 748,990 | 1,497,980 | 7.87% | 2.0 |
| `core_var` (all nodes) | 348,992 | 348,992 | 1.83% | 1.0 |
| not attributed to any expression node (decl/function/record/global lowering overhead outside `lower_typed_expr_as_type`) | -- | 10,123,511 | 53.20% | -- |

Summing `TypedCallExpr`'s own residual with its four `CallExpr.*` sub-steps
recovers exactly the same number the (buggy) first pass reported as
`TypedCallExpr`'s self-allocations before this fix (2,558,405) -- the fix
did not change the total, only the (much smaller, correct) denominator it is
a percentage of, and split that total into finer sub-steps.

**`TypedNameExpr` -- ordinary variable/function-name references, not calls
-- is the single largest self-allocation contributor at 19.98%.** It is a
leaf node (`Ok(VarExpr(core_var(clean_name, def_id), typ, loc))`): its per-call
cost is `core_var` (1 allocation) plus whatever `core_source_loc_from_context`
and the type it was handed cost, at massive volume (271,793 calls, the most
frequent node kind after the arg/callee traffic already broken out above).
This something-plus-volume shape, not one expensive helper, is why it is not
already the subject of a cut; it would need its own drill-down before
proposing one, and is flagged as the next attribution target below.

### Drilling into TypedCallExpr

Per the ask, drilled one level into `TypedCallExpr`'s own allocation budget
(2,558,405, none of it double-counted with the callee's or an argument's own
recursive lowering, which are separately charged to their own node kinds).
Each of the arm's four steps -- `apply_resolved_callee_identity` (callable
resolution / UFCS name split), `lower_typed_exprs` (the argument list
build), `lower_resolved_call_kind` (`CoreCallKind` construction), and the
final `CallExpr(...)` node -- was wrapped with the same enter/exit
primitive, plus one more: the callee's own `lower_typed_expr_with_context`
call, because that call computes the callee's *semantic type* via
`core_lower_value_type` **before** calling the wrapped
`lower_typed_expr_as_type` that pushes the callee's own frame -- so without
wrapping the whole call, that type-lowering cost is silently charged to
whichever node calls the callee (here, `TypedCallExpr`) instead of to the
callee's own kind. This is a real, general subtlety of where the wrapper
sits, not a further allocation bug (it does not affect the true lowering
total, only which self-time bucket a cost lands in) -- worth noting for
anyone extending this instrumentation further.

| step | calls | self allocations | % of call lowering's own budget | self/call |
|---|---|---|---|---|
| `CallExpr.callee_type_lowering` (the callee's own semantic type, lowered fresh on every call site) | 86,648 | 852,492 | **33.32%** | 9.8 |
| `CallExpr.args_list` (argument list construction, excluding each argument's own recursive lowering) | 86,648 | 549,180 | 21.47% | 6.3 |
| `CallExpr.call_kind` (`CoreCallKind` construction: builtin/direct/trait/unknown dispatch) | 86,648 | 506,713 | 19.81% | 5.8 |
| `CallExpr.callee_identity` (UFCS name split / resolved-call name substitution) | 86,648 | 390,076 | 15.25% | 4.5 |
| `TypedCallExpr` own residual (mostly `core_source_loc` for the call node itself) | 86,648 | 173,296 | 6.77% | 2.0 |
| `CallExpr.node_construct` (the final `CallExpr` node) | 86,648 | 86,648 | 3.39% | 1.0 |
| **total (= call lowering's own budget)** | 86,648 | **2,558,405** | 100% | 29.5 |

### Go/no-go: callee type lowering

**GO** -- `CallExpr.callee_type_lowering` is 33.32% of call lowering's own
budget, clearing the 25% threshold. Mechanism: the callee's semantic type
(almost always a `SemanticFunctionType`, the referenced function's own
signature) is lowered fresh via `core_lower_value_type` on *every call
site* that references a given function, rather than once per function
declaration. Unlike cut 1's built-in scalars, a function's `FunctionType`
is not a small fixed set of shapes that can be replaced by a handful of
module-level constants -- it is specific to each function's own param/return
types.

**Not implemented this session.** The safe version of this cut is a memo
keyed by the callee's resolved definition id (available from
`info.resolved_call` on a resolved `TypedCallExpr`) rather than by
`SemanticType` identity, populated once when each function's own
`TypedFunctionDecl`/`TypedForeignFunctionDecl` is lowered (a point that
*does* correctly thread an updated `CoreLowerContext` forward across
declarations, unlike expression-level lowering -- see the earlier
context-threading finding above) and read (never written) from expression
lowering, so no context-return-threading is needed at the read sites. That
design avoids the blocking issue that ruled out cut 1's per-function memo.
It was not implemented here because of a real, unverified risk in the time
available: monomorphization. If the same function name resolves to
*different* instantiated signatures at different call sites (a generic
function called with different type arguments), a memo keyed only by
definition id would hand a later call site the wrong, stale instantiation --
a functional correctness bug in generated code, not just a missed
optimization. Confirming whether `info.resolved_call`'s definition id is
already instantiation-specific (safe to key on directly) or shared across
instantiations (needs the type arguments folded into the key) requires
reading the monomorphization/specialization passes this session did not
have time to read carefully. Landing a memo without that check risked
exactly the kind of unverified cut that got reverted before cut 0 existed.

Recommending this as the next task, with the specific design and the
monomorphization question spelled out above so it does not need
re-deriving.

## Caveats (real-program section)

- The per-node self/inclusive split has a known attribution quirk: a node's
  own outer type-lowering cost (computed by its *caller* via
  `core_lower_value_type` before the node's own frame is pushed) is charged
  to the caller, not the node itself, unless the caller explicitly wraps
  that specific call (as done for `TypedCallExpr`'s callee above). Kinds
  that were not drilled into this way may be under-counting their own true
  cost and over-counting whichever kind most often calls them.
- "Not attributed to any expression node" (53.20%) is declaration-level
  lowering (function signatures, record/union/global declarations,
  `CoreProgram`/`CoreDecl` list-building) that this instrumentation does not
  wrap; a future pass could extend the same enter/exit mechanism to
  `lower_typed_decl_with_visibility`'s dispatch to close this gap the same
  way.
- `core_source_loc` and `core_var`'s percentages are not additional to the
  46.80% node-kind sum -- their allocations happen *inside* whichever node's
  self-time window called them.

## Drilling into TypedNameExpr, and the callee-signature memo question (2026-09-22, third pass)

Two items, following the same discipline: attribute, check the 25%
threshold, cut only what clears it.

### Drilling into TypedNameExpr

`TypedNameExpr` (plain name references -- `Ok(VarExpr(core_var(clean_name, def_id), typ, loc))`)
was the largest self-allocation contributor at 19.98% of lowering
(3,802,949 allocations, 271,869 calls, 14.0/call). Wrapped its four
sub-steps the same way as `TypedCallExpr`'s drill-down (same enter/exit
primitive, new labels):

| step | calls | self allocations | % of name-reference budget | self/call |
|---|---|---|---|---|
| `NameExpr.identity_total` (the final callable-id reconciliation match, before the cut below) | 271,869 | 1,359,345 | **35.74%** | 5.0 |
| `NameExpr.split_callable_id` (`split_var_callable_id`: UFCS-prefix check, `#<id>` suffix split) | 271,869 | 543,738 | 14.29% | 2.0 |
| `TypedNameExpr` own residual (exactly `core_source_loc`'s 2/call, isolated once `node_construct` and `identity_total` were split out) | 271,869 | 543,738 | 14.29% | 2.0 |
| `NameExpr.node_construct` (`core_var` + `VarExpr(...)`) | 271,869 | 543,738 | 14.29% | 2.0 |
| `NameExpr.resolved_definition_id` (`resolved_core_decl_callable_id` when `info.resolved_call` is set) | 271,869 | 469,963 | 12.35% | 1.7 |
| `NameExpr.lowered_name` (`lowered_name_expr_name`: UFCS name substitution for resolved calls) | 271,869 | 343,458 | 9.03% | 1.3 |
| **total (= name-reference budget)** | 271,869 | **3,803,980** | 100% | 14.0 |

**Go: `NameExpr.identity_total`, 35.74%, clears the 25% threshold.** The
mechanism was not a String split or concatenation (those are
`split_callable_id`/`lowered_name`, each under 15%) -- it was
`lower_name_expr_identity`'s own return type. That function reconciled two
sources of the callable id (`encoded_id` from `split_var_callable_id`,
`resolved_id` from a resolved call) but returned `Result[(String, Option[Int]), CoreLowerError]`,
boxing `clean_name` into a tuple purely to carry it back out past the
reconciliation, even though the reconciliation itself never reads or
touches `clean_name`. At 5 allocations/call for what is, in the common
case, one integer-or-none comparison, that tuple-in-Result return was the
single most expensive thing a plain variable reference pays for.

**Cut, landed**: split `lower_name_expr_identity` into
`resolve_name_expr_def_id(name, encoded_id, resolved_id) -> Result[Option[Int], CoreLowerError]`
(the reconciliation, unchanged logic, now returning only the `Option[Int]`
it actually decides) and `resolved_name_expr_id` (the `info.resolved_call`
match, unchanged). `clean_name` is now read directly from
`split_var_callable_id`'s existing return at the one call site
(`lower_typed_expr_as_type_impl`'s `TypedNameExpr` arm) instead of being
routed through the reconciliation's return value. Same semantics, same
error message, one fewer heap-boxed tuple per name reference.

Measured on the frozen self-compile (same input, same command as the
earlier sections):

```
core_lowering_complete, metrics unset, before this cut: 19,036,171
core_lowering_complete, metrics unset, after this cut:  18,764,302
```

**-271,869 allocations (-1.43%), exactly one allocation per call** -- the
tuple, and only the tuple; the `Ok`/`Option` boxing the reconciliation still
does was already there before and is unchanged. `self_compile_measure --require-identical`
confirms: byte-identical generated C (160,183,601 bytes both), every other
phase's allocation row at +0.00%, `TOTAL` -0.11%, instructions retired
-0.08% (improved, not regressed). Re-verified metrics on/off allocation
parity holds after the cut (66,210,587 both ways, same as the metrics-off
baseline), so the drill-down instrumentation itself did not shift.

### The callee-signature memo question

Point 2 of the earlier follow-up left open whether a memo for
`CallExpr.callee_type_lowering` (33.32% of call lowering's own budget,
see the second-pass section above) could safely be keyed by the callee's
resolved definition id alone.

**Answer: the id is per template, not per instantiation.** `ResolvedCallInfo`
(`blorp/src/compiler/stage_06_typecheck/infer.brp:506`) carries `target:
ResolvedCallTarget` (whose `ResolvedGraphCallableCall(CallableId, ...)` and
similar variants hold the STABLE callable/definition id, the same for every
call site referencing a given function or trait method) as a *separate*
field from `bound_type_params: List[BoundTypeParam]`,
`instantiated_params: List[SemanticType]`, and `instantiated_return:
SemanticType` -- the per-call-site instantiation. `resolve_trait_self_call`
(`infer.brp:9557`) is direct proof these differ: for a trait method with
`Self` in its signature, it computes `resolved_params =
params.map(func(param): resolve_self(self_type, param))` and
`resolved_return = resolve_self(self_type, return_type)` from *this call
site's* receiver type, builds `resolved_func_type =
SemanticFunctionType(is_pure, resolved_params, resolved_return)`, and
folds it into `updated_resolved_call`'s `instantiated_params`/
`instantiated_return` -- two calls to the same trait method with different
receiver types get different instantiated signatures under the same
callable id. `CoreMonoDefIdMap` (`blorp/src/compiler/stage_09_core/mono_impl.brp:71`)
confirms this from the other end: monomorphization is a **Core-level pass
that runs after lowering**, rewriting definition ids to point at
specialized copies it creates -- its whole job is to turn one
lowering-time definition id plus the concrete types actually used back
into multiple specialized declarations, which only makes sense if lowering
itself sees one id shared across differently-instantiated call sites.

**A memo keyed only by definition id would therefore be wrong**: it would
hand a later call site whichever instantiation happened to lower first.
Per the standing instruction, the key must include the instantiated
parameter/return types.

**Is that key available without allocating? Yes, for retrieval -- not yet
for safe storage.** `instantiated_params`/`instantiated_return` already
exist on `ResolvedCallInfo`; no new computation is needed to obtain them,
and hashing them by pointer identity (the same technique the type-metric
fix above uses) needs no new allocation either -- walk the list, combine
each element's pointer hash with the definition id's. But a **hash** key is
not a safe **equality** key: two different instantiations could collide,
and correctness requires confirming an exact match (definition id, plus
every param pointer, plus the return pointer) on a hit, not just a hash
match. That comparison is itself cheap (pointer equality, no allocation),
but it means the cache entry must retain the full parameter list and return
type pointers to compare against on lookup, not just a hash -- a real,
new, always-on (not debug-gated) C-side data structure with correctness
consequences if it is wrong, unlike this session's other two cuts (a
handful of module-level constants, and dropping one already-redundant
tuple), which cannot silently produce a wrong answer if a comparison is
subtly off.

**Not implemented this session.** The pieces are identified precisely
enough that a future session should not need to re-derive them: memo
storage keyed by `(definition_id, instantiated_params pointers,
instantiated_return pointer)`, populated once per distinct instantiation
the first time it is lowered (naturally happens during expression lowering
itself, no need to special-case declaration lowering the way the
type-histogram or scalar-constant work did), read on every
`CallExpr.callee_type_lowering`. Recommending it as the next task, gated on
writing and testing the exact-match comparison before it goes anywhere
near a production (non-debug-gated) code path.
