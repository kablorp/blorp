# Reduce DCE Reachability Fact Application Work

**Status:** Proposed; measurement-first DCE state and lookup refactor

**Current state:** `close_reachability` repeatedly passes a six-collection
`DceClosureState` through `apply_reachability_facts`. That helper expands direct
definition IDs, name-to-definition buckets, constructor references, globals,
and types while maintaining ordered lists plus membership sets. A compiler
self-compile at `f6af78c0` observed its generated consuming path 14,057 times,
with 1,216.626 ms self out of 1,252.768 ms inclusive time.
**Next action:** Instrument the production DCE closure to attribute time and
work among state transfer, dictionary lookup, candidate iteration, membership
probes, and successful insertions before choosing a representation change.
**Read first:** `blorp/src/compiler/stage_09_core/dce.brp`,
`blorp/test/compiler/stage_09_core/test_core_dce.brp`, and the `dce` mode of
`benchmarks/compiler_core_pipeline_work_profile`.
**Fast loop:** Vary reachable functions, named-call bucket width, globals,
types, constructor collisions, and unreachable declarations one axis at a
time around the actual `prune_program` entry point.
**Decision:** Optimize only the measured dominant operation. Preserve ordered
closure results and fail-closed behavior; ask for guidance before changing
`DceReachabilityIndex` or the identity model.

## Objective

Make each newly processed fact perform bounded lookup and insertion work
without repeatedly copying unchanged closure state or rescanning broad name
buckets.

Do not assume the record update itself is expensive: the generated symbol is a
consuming specialization, so the current compiler may already transfer its
state efficiently. Candidate cuts depend on counters and may include:

- return the original state immediately when every fact list is empty;
- mutate one owned local state instead of reconstructing equal fields;
- avoid constructing default empty lists on successful index misses;
- narrow a name bucket with exact definition identity where that identity is
  already present in the fact; or
- batch proven unique additions while preserving their encounter order.

Do not replace ordered result lists with sets, infer identity from names, or
change the conservative `fail_closed` path.

## Invariants And Tests

- Preserve root order and breadth of the function/global closure worklist.
- Preserve the first encounter order of reachable function IDs, globals, and
  type names.
- Preserve overload/name buckets and exact constructor `def_id` checks.
- Missing facts remain conservative exactly where they are conservative today.
- Duplicate facts remain idempotent without suppressing later distinct IDs.
- Cover direct-ID, name-only, constructor, global, and type roots separately;
  then cover mixed facts, collisions, cycles, missing index entries, and
  `fail_closed`.
- Require identical pruned Core and byte-identical generated C.

## Measurement

Extend the production DCE work profile with counters for:

- facts processed by category;
- name/bucket lookups and bucket candidates inspected;
- membership probes, successful insertions, and duplicate rejections;
- closure-state constructions or clones;
- worklist entries processed; and
- allocations, releases, instructions, elapsed time, and Core checksum.

Example one-axis runs should hold expression nodes and reachable roots fixed
while growing only same-name candidates, then hold candidate width fixed while
growing reachable declarations:

```bash
for functions in 64 128 256 512; do
  benchmarks/compiler_core_pipeline_work_profile \
    1 dce "$functions" 64 32 8 "$functions" 4 0 8
done

bin/blorp test --timeout 180 \
  blorp/test/compiler/stage_09_core/test_core_dce.brp
scripts/compiler-check --changed
scripts/test compiler-core-sanitize leak
```

If the current generic fixture cannot independently control reachable roots and
name-bucket collisions, extend it narrowly or add a DCE-specific fixture. Do
not use total declaration count as a proxy for the work inside this helper.

## Acceptance And Rejection

Accept when the chosen work counter falls by at least 80% or approaches linear
growth, a compiler-shaped case improves instructions or allocations by at
least 10%, zero/small/collision controls stay within 3%, Core and C output are
identical, and sanitizer/leak gates pass. Reject if the consuming state already
has no material copy cost, lookup work is merely displaced into index building,
order changes, or the index persists beyond the DCE invocation without an
invalidation owner.
