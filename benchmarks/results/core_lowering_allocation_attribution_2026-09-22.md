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
