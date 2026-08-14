# Phase 3E Module Header Projection

Date: 2026-08-13

## Workload

The new `mixed` mode of `compiler_typecheck_profile` runs the production graph
typechecker over recursive records, transparent and opaque aliases, unions,
private declarations, import fan-out, and qualified imported type references:

```bash
BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 \
  benchmarks/compiler_typecheck_profile 1 8 32 64 mixed 4
```

Every measured run reported nine artifacts, 1,073 source declarations, 1,073
typed declarations, 30 resolved imports, 272 records, 264 aliases, eight
unions, 521 functions, eight private declarations, zero errors,
`workload_valid=True`, and checksum `3258`.

The retained containment control used:

```bash
BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 \
  benchmarks/compiler_typecheck_profile 1 8 64 128 retained
```

It continued to report checksum `3083`.

## Profile Evidence

Before the change, every category-specific local or public module projection
scanned the complete accepted-header inventory and repeated module-identity and
visibility checks. The mixed profile reported 97,920 calls to
`compiler_type_header_is_selected_for_module`, consuming 59.56 ms inclusive.

`type_homes` was also evaluated as a candidate. Its complete measured path was
small: `compiler_typecheck_state_record_type_home` consumed 25.57 ms across
1,548 calls, `compiler_typecheck_state_find_type_home` consumed 13.65 ms across
1,548 calls, and `find_type_home_entry` consumed 2.87 ms. Its local-override and
first-import-wins collision semantics make an indexed replacement materially
more complex, so no `type_homes` change was retained.

## Change

`CompilerTypeHeaderTable` now owns a private keyed per-module inventory
alongside its ordered headers and exact-name buckets. Each exact module storage
key owns one graph-ordered all-header/public-header index pair, so duplicate
module buckets cannot be represented. The sole table constructor derives all
three views together from exact declaration identities and declaration
visibility. Resource-containment completion may replace headers at stable
positions, but it cannot create an incoherent index.

Headers remain the only semantic source of truth. Projections use the private
indices only to narrow candidates, then retain the existing category-specific
accepted-header conversion. No visibility, type, or declaration facts are
duplicated.

## Result

Twenty alternating cached runs were collected for baseline and candidate
artifacts. Build time was excluded.

| Workload | Baseline median | Candidate median | Change |
|---|---:|---:|---:|
| Mixed shapes and imports | 188,229 us | 184,648 us | 1.9% faster |
| Retained containment control | 55,017 us | 53,684 us | 2.4% faster |

The initial isolated samples overstated the improvement because the two
artifacts ran under different warm-up conditions. The alternating result above
is the retained claim. Both workloads preserved all counters and checksums.

In the post-change function profile, the four category projections each took
0.87-1.04 ms across 45 calls, and the shared keyed module lookup took 0.69 ms
across 180 calls. Adding all 544 headers to their eight module inventories took
1.49 ms. The complete type-header graph build took 40.80 ms. The removed
full-inventory selection predicate no longer appears in the profile.

Raw samples are in the adjacent TSV file.

## Phase 3 Closure Checkpoint

The final ownership pass keeps definition-only headers separate from parsed
module bodies. `CompilerImportableModuleGraph` constructs the dependency and
target projections once, and `CompilerAcceptedTypecheckGraph` validates that
inventory against the compatible header graph. The benchmark checksum and all
logical counters remain unchanged.

Five uncontended cached `-O2` runs after that ownership change measured
180,885, 184,527, 184,924, 226,236, and 172,498 us. The median is **184,527
us**, effectively unchanged from the earlier indexed-projection checkpoint
median of 184,648 us. Artifact compilation was excluded; the uncached first
invocation and samples collected during unrelated sanitizer work are not
workload measurements.

## Validation

- `make`: passed;
- `compiler-blorp`: 3,422/3,422 passed;
- `std-check`: passed;
- focused type-header and benchmark suites: 25/25 and 5/5 passed;
- focused type-header ASan/UBSan suite: 25/25 passed;
- `make quality`, including C static analysis: passed; and
- independent code review: no remaining findings.

## Follow-Up

Recursive semantic conversion of resolved alias shapes dominates the remaining
mixed profile. Addressing that requires a definition-owned reusable semantic
header representation rather than a local cache or another projection index.
It remains architectural follow-up for the declaration-header cutover.
