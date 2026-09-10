# Parallel-Safe Compiler Latency Work

**Status:** Historical packet; lanes 1–3 are merged, lane 4 has an unaccepted
candidate, and lane 5 moved to the late-Core latency packet

**Baseline:** `30ff91683cda52fde14d76f5babe43ee7753bbd3`

## Purpose

This directory contains compiler-latency work that can proceed concurrently
without requiring workers to coordinate edits to the same production owner.
Every issue is a bounded vertical change with an explicit semantic authority,
a focused measurement, and an independent merge decision.

Current reconciliation:

- phase timing is implemented and accepted;
- match-projection declaration indexing is merged in `c109117b`;
- type-home indexing is merged in `174983f4`;
- field-order linearization is committed at `9ea9b1f3` and still requires its
  acceptance decision; and
- runtime checkpoint Phase A is now specified by
  [the late-Core execution issue](../late-core-latency/04-amortize-runtime-cooperative-checkpoints.md).

The packet deliberately excludes work that is merely plausible. An item belongs
here only when:

- its production ownership boundary is distinct from the other items;
- its implementation can delete repeated work rather than add a shadow cache;
- correctness can be expressed with exact identities or a named runtime policy;
- it has a focused benchmark capable of measuring its own result; and
- it can be rejected independently without invalidating another lane.

## Current Baseline

On a clean checkout of the baseline revision, three optimized runs produced:

| Measurement | Current baseline |
| --- | ---: |
| `check --no-format blorp/src/main.brp` | 9.02 s median |
| Compile through C emission, no embedded runtime | 42.75 s median wall |
| Coarse compiler `frontend` bucket | 18.18 s median |
| Coarse compiler `backend` bucket | 22.32 s median |
| Peak resident memory | approximately 2.16 GB |
| Generated C | 88,419,354 bytes |
| Generated C | 1,267,939 lines |
| Artifact write window | approximately 57 ms |

The current two timing buckets do not correspond to the seven phase identities
declared in `blorp/src/compiler/pipeline.brp`. In particular, `frontend`
contains typechecking, lowering, early Core, and runtime projection, while
`backend` combines the complete late-Core tail, C projection and emission, and
artifact construction.

A backend-only native sample identified these relevant self-time leaves:

| Leaf | Self samples |
| --- | ---: |
| `blorp_list_get_inline` | 8.59% |
| `_tlv_get_addr` | 7.13% |
| `blorp_cooperative_checkpoint` | 6.96% |
| `blorp_release` | 6.05% |
| `match_projection.union_variant_field_type` | 4.40% |
| `blorp_retain` | 4.05% |
| `reuse.alias_lookup` | 2.09% |
| `prepare.order_heap_record_fields` | 1.74% |

These rows are evidence for selecting work, not additive stage percentages.
TLS work has multiple callers, inclusive stacks overlap, and compact C symbols
are not yet mapped robustly enough for exact production pass attribution.

## Parallel Lanes

| Lane | Issue | Exclusive production owners |
| --- | --- | --- |
| 1 | [Expose the seven compiler phase timings](01-expose-seven-compiler-phase-timings.md) | compiler orchestration and timing |
| 2 | [Index match-projection declarations](02-index-match-projection-declarations.md) | `stage_09_core/match_projection.brp` |
| 3 | [Index type-home state](03-index-type-home-state.md) | Stage 06 type-home state and consumers |
| 4 | [Linearize Core preparation field ordering](04-linearize-core-preparation-field-ordering.md) | `stage_09_core/prepare.brp` |
| 5 | [Amortize cooperative checkpoints, Phase A](../late-core-latency/04-amortize-runtime-cooperative-checkpoints.md) | native runtime checkpoint policy |

Every optimization lane owns a uniquely named focused fixture and benchmark
driver. It must not add a mode to a shared benchmark, edit a shared benchmark
fixture, or edit another lane's production owner merely to make measurement
more convenient. Registration in a shared benchmark catalog, if desired, is a
small integration edit after the parallel branches land.

## Required Branch Discipline

All workers start from the recorded baseline or the same later agreed revision.
Use one branch and one worktree per issue. Do not share a writable checkout.

The phase-timing lane should merge first when practical. Other work does not
need to wait for it: each optimization has a focused metric using existing
tools. Before its final performance report, each optimization rebases onto the
phase-timing result and reruns its paired measurements.

Do not create a shared Core declaration-index abstraction during these lanes.
Match projection and preparation consume different facts at different phase
boundaries. Each pass owns and validates its narrow index. A later issue may
extract a shared product only if measurement and declaration-epoch analysis
show that doing so removes real construction work without weakening identity.

## Common Measurement Contract

Each optimization issue must record:

1. Baseline and candidate source revisions.
2. Baseline and candidate compiler executable SHA-256 values.
3. Host, architecture, and C compiler version.
4. Exact commands and flags.
5. One discarded warmup followed by at least five alternating measured pairs.
6. Ten alternating pairs when the median difference is below 2%.
7. Raw samples, median, and median absolute deviation.
8. Focused deterministic work counters.
9. Stage-two compiler self-check or self-compilation results as required by the
   issue.
10. Peak RSS and managed allocation/release deltas where applicable.
11. Generated-C bytes, lines, and SHA-256.
12. Focused and broader test results.

The candidate compiler must be built and then used to compile the workload.
Measuring the old compiler while it compiles changed compiler source does not
measure runtime or algorithmic improvements in the candidate executable.

Use the narrowest authoritative metric for the merge decision. A pass-local
index may be below whole-compiler wall-clock noise, but it must show lower
deterministic work and stable focused latency. Whole-compiler measurements for
such a lane are regression guards evaluated against the paired distribution,
not sub-percent point-estimate gates. Treat a repeatable regression greater
than 2% as material unless the issue defines a stronger gate. A cross-cutting
runtime change must also improve the stage-two whole compiler.

## Common Correctness Contract

- Add or strengthen a failing regression before changing behavior.
- Use exact semantic identity. Do not infer identity from prefixes, source
  formatting, or likely declaration order.
- Build one authority per declared phase lifetime. Do not retain the old list
  as a competing writable authority or fallback scan beside a new dictionary.
  Retaining an immutable source-order list as the indexed payload is valid
  when enumeration order remains semantic.
- Validate duplicate keys at construction or preserve the existing rejection
  point explicitly. Never acquire accidental last-write-wins behavior.
- Preserve diagnostic ordering, Core observation/stop behavior, generated C,
  and runtime results unless the issue explicitly authorizes a difference.
- Delete superseded lookup, list-rebuild, or timing paths.
- Do not combine cleanup, refactoring, or adjacent optimizations with the
  assigned issue.
- Do not merge a candidate that misses its issue's performance gate.

## Integration Order

The intended merge order is:

1. phase timing;
2. whichever indexed lane demonstrates the largest retained improvement;
3. the remaining indexed lanes, each rebased and remeasured;
4. cooperative checkpoint Phase A after its cancellation contract passes
   review; and
5. a new full profile before admitting another optimization family.

Performance improvements are not assumed to add linearly. Every branch is
remeasured against its immediate parent before merge.

## Explicitly Excluded Work

The following work is not parallel-safe or not yet admitted:

- **Reuse alias storage:** replacing `List[SourceAlias]` with a dictionary is
  not approved until the design uses exact hygienic identity and demonstrates
  appropriate persistent-scope behavior. A string-keyed side cache is not
  acceptable.
- **Perceus Tranches 5–6:** the current Perceus roadmap explicitly records that
  all-value fact collection was not admitted by the latest focused profile. A
  future issue must identify a newly measured legacy query family first.
- **Stage 10 restructuring:** artifact output is large, but writing it takes
  only about 57 ms. No emitter rewrite is admitted until the phase-timing lane
  isolates C projection and rendering cost.
- **Generated local checkpoint counters:** this is Phase B of the existing
  checkpoint roadmap. It changes generated Core/C and is considered only if
  the runtime-only Phase A leaves at least 2% focused checkpoint overhead.
- **A universal Core index:** shared storage across pass epochs would couple the
  parallel lanes and risk stale facts. Pass-local indexes come first.
- **Preparation declaration indexing:** source inspection finds repeated
  declaration scans, but the current sample directly admits only record-field
  ordering. Declaration indexing requires its own counters and issue after the
  field-order lane; combining them would make two independently rejectable
  optimizations share one outcome and one production owner.

## Completion Of The Packet

The packet is complete when every lane is either merged with its required
evidence or rejected with retained baseline/candidate results. Afterward,
repeat the clean compile-through-C profile and update the compiler performance
roadmap from the new bottleneck distribution.

The completed issue files in this directory retain their execution history.
Field ordering remains governed here until its acceptance decision. Runtime
checkpoint work is governed by the linked late-Core issue, whose narrower
carrier-thread and cancellation contracts supersede the earlier Phase A text.
