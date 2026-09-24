# I3 salvage slice: identity short-circuit + shared dimension normalization (parked)

Branch `core/i3a-type-equality-identity`, base `origin/main@3b8f270b`. Split out
of the parked I3 table branch (`core/i3-type-table`) per the coordinator's
request to isolate the two representation-free pieces: the `same_object`
short-circuit on `core_type_equal`/`core_mono_type_equal`, and unifying
tensor-dimension normalization (`normalize_dim`) so both equalities agree.
No `CoreTypeTable`, no `type_table` field, no change to type construction.

## Result: parked, no measurable instruction win

Frozen self-compile, `--input-rev 0c2e104331a2`, samples=3, **stage-2**
compilers for both sides (parent and candidate both built from the same
`3b8f270bf37c` source tree; candidate carries only this slice's diff).
Byte-identical C confirmed (112,314,170 bytes both sides).

| metric | parent | candidate | delta |
| --- | --- | --- | --- |
| core_lowering_complete allocs | 17,259,793 | 17,259,793 | +0.00% |
| pass_mono_complete allocs | 14,867,348 | 14,867,306 | -0.00% |
| total allocs | 182,846,171 | 182,841,000 | -0.00% |
| instructions retired (min) | 285,369,157,462 | 285,382,503,598 | +0.00% |

All per-phase allocation rows are flat at +0.00%/-0.00% (a handful show a
few dozen fewer allocations — `pass_synth_complete` -0.04%,
`pass_record_update_ownership_complete` -0.42% — noise-level, not a
regression). Instructions retired do not fall outside measurement noise
(+0.0047%, rounds to +0.00%). Per the go/no-go, this is parked alongside
the table (not landed): the slice is allocation-neutral and correctness is
unaffected (all suites, `compiler-check`, `compiler-blorp`/`compiler-tools`,
`leak`, `compiler-core-sanitize`, `hygiene-check` pass), but it does not
independently earn its keep as a performance change.

### Why the shortcut doesn't move instructions

`same_core_type` (`blorp_same_object`) only pays off when the two `CoreType`
values being compared are *literally the same allocation*. Without any
interning upstream (this slice deliberately has none), two structurally
equal `CoreType` trees are produced by independent `NamedType(...)`/
`FunctionType(...)`/etc. constructor calls and are different allocations
essentially every time. So at nearly all of the 176 `core_type_equal`/
`core_mono_type_equal` call sites, `same_core_type` returns `False` and the
full structural comparison still runs — the shortcut adds one pointer
compare per call without skipping any recursion. The shortcut is a
necessary *precondition* for a future interning step to pay off (once two
equal subtrees really can be the same object), not a win on its own.

## Root cause note: what real construction-time sharing would need

Requested by the coordinator to settle whether a smaller follow-up is worth
staffing.

### Lowering: ~1.27M constructions, deep call graph, no threaded return

The lowering histogram (`benchmarks/results/core_lowering_type_histogram_2026-09-22.md`)
counted 1,275,348 `CoreType` constructions in `core_lower_type_with_prefixes_impl`
for 22,180 distinct shapes. The type-lowering functions themselves
(`core_lower_type_with_prefixes[_impl]`, `core_lower_tensor_type`,
`core_lower_type_list`, `core_lower_value_type[_list]`) already form a
closed, mutually-recursive group of 6 functions -- threading a table through
*just that group* is cheap and was already implemented in the parked I3
branch, giving free sharing within one type's own recursive construction
(e.g. a `FunctionType`'s repeated `Int` params).

The 1.27M calls are not made from one or two places, though -- they come
from roughly 54 call sites scattered across `lower.brp`:

- ~9-12 are declaration-signature sites (record/union/enum field types,
  type-alias targets, trait method signatures, param/return types) whose
  *immediate* callers already return a context-carrying result
  (`CoreLowerDeclResult`, `CoreLowerFunctionResult`) up to
  `lower_typed_program_with_ctfe_replacements`'s per-declaration loop.
  Threading a `type_table` through just this tier -- roughly 9-12 function
  signatures (`lower_value_record_field(s)`, `lower_heap_record_field(s)`,
  `lower_union_field(s)/variant(s)/variants`, `lower_typed_record`,
  `lower_typed_union`, `lower_typed_type_alias`, `lower_typed_trait_method(s)`,
  `concurrent_for_item`) -- would give real cross-*declaration* sharing for
  every function/record/union signature in the program, which is a
  contained, low-risk change.
- The remaining ~40+ sites are inside expression-body lowering: every
  literal, call, local binding and loop annotates a `CoreType` via
  `core_lower_value_type(context, typed_expr_value_type(...))` or similar,
  called from `lower_typed_expr_with_context` and its dozens of
  statement/expression-kind helpers (concurrent bindings, match cases,
  timeout exprs, for-loop iterables, map/dict entries, tensor reads, ...).
  `lower_typed_expr_with_context` is the single highest-fan-in function in
  the file and returns a bare `Result[CoreExpr, CoreLowerError]` today, with
  no context/table return at all. Giving it (and its mutually-recursive
  helpers) a threaded return is not a 10-function change -- `lower.brp` is
  ~6,500 lines and the expression-lowering surface beyond the
  declaration-signature tier is on the order of 60-80 distinct private
  helper functions, all of which would need a widened return type
  (`{context, expr}` in place of a bare `Result[CoreExpr, ...]`) and every
  call site within that surface updated to thread it. That is the "real"
  I3a: materially larger than this task, which is why the parked table
  branch's compatibility wrapper (read `context.type_table` for cache hits,
  discard growth) was used instead -- and why it produced a net loss rather
  than the targeted -1.2M.

### Mono: smaller volume, already runs under threaded pass state

Mono's `apply_type_substitution` family has 20 call sites total (2 in
`mono_specialize.brp`, 10 in `mono_substitute.brp`, 4 in `mono_data.brp`, 1
each in `mono_option.brp`, `mono_impl.brp`, `synth_context.brp`,
`match_projection.brp`), all much shallower than lowering's call graph.
Critically, mono's specialization loop already threads a state record
across repeated substitution calls within one pass --
`CoreMonoProgramSpecialization { program: CoreProgram, next_def_id: Int }`
and `CoreMonoFunctionSpecializationStep { program, next_def_id,
rewritten_decl_count }` in `mono_specialize.brp` -- so a `type_table` field
added to that existing state (or to `CoreProgram` once it carries one) would
ride along for free instead of requiring new threading machinery.

No isolated call count for mono's own type constructions exists yet (the
2026-09-22 histogram only instrumented lowering), but the parked table
branch's measured allocation deltas give an indirect estimate: enabling the
(broken, non-sharing) table added +7,186,194 allocations to
`core_lowering_complete` (17,259,793 -> 24,445,987) and +1,793,877 to
`pass_mono_complete` (14,867,348 -> 16,661,225) on the same frozen
self-compile -- a roughly 4:1 ratio of lowering's table-bookkeeping
overhead to mono's. If table overhead scales with the number of intern
attempts, that suggests mono's own type-construction volume is very roughly
a quarter of lowering's (order of magnitude 250K-350K constructions, not
1.27M) -- meaningfully smaller, but not negligible, and reachable through
existing threaded state rather than a lowering-style rewrite.

**Recommendation**: mono-only interning (route the 20
`apply_type_substitution` call sites' results through a table carried on
`CoreMonoProgramSpecialization`) is a contained follow-up worth measuring on
its own before attempting lowering's full expression-graph threading. It
will not reach the roadmap's full -1.2M target (that number is dominated by
lowering's 1.27M), but it is a bounded, low-risk slice that could land
independently and would validate the interning/hashing machinery
(`CoreTypeTable`, `intern_core_type`, `core_type_hash`) against a real
workload before committing to the larger lowering-side rewrite.
