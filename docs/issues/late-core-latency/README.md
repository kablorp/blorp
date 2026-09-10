# Late-Core Latency Execution Packet

**Status:** Ready for sequential execution after immediate-parent validation

**Created:** 2026-09-09

## Purpose

This directory turns the current late-Core profile into four bounded,
independently measurable changes. Each issue removes repeated work or
amortizes an existing runtime safety check without creating a shared,
cross-pass cache.

The packet starts from `main` at `c109117b`, which already contains match-
projection declaration indexing. The native profile that selected these
issues was captured from `aa465380`, before that index landed, so every issue
must compare against its immediate parent and the packet must be reprofiled
after the first three pass-local changes.

## Current Evidence

An optimized compiler compiling `blorp/src/main.brp` through C emission spent
a median 15.435 seconds in late Core, or 46.43% of the measured compiler
pipeline. A 1 ms macOS sample attributed the following non-additive shares of
the late-Core subtree:

| Work | Approximate late-Core share |
| --- | ---: |
| Match projection | 28.4% before its index landed |
| Perceus insertion | 25.7% |
| Consume specialization | 5.8% |
| Final Core preparation | 8.7% |
| Prepared reuse | 5.4% |
| Direct cooperative-checkpoint self time | 12.23% |
| TLS lookup self time | 7.76% |

Inclusive stacks overlap. In particular, checkpoint and TLS samples occur
inside pass work and must not be added to pass percentages. The profile is
selection evidence, not an acceptance result for a future candidate.

## Issues

1. [Index prepared-reuse declarations](01-index-prepared-reuse-declarations.md)
2. [Index Core-preparation declarations](02-index-core-preparation-declarations.md)
3. [Index consume-specialization candidates](03-index-consume-specialization-candidates.md)
4. [Amortize runtime cooperative checkpoints](04-amortize-runtime-cooperative-checkpoints.md)

The numbering is local to this packet. These correspond to priorities 3–6 in
the late-Core profile review.

## Dependency And Conflict Map

The prepared-reuse and consume-specialization issues own separate production
files and can be developed independently. The field-ordering candidate was
rejected after quiet-host measurement, so preparation declaration indexing
starts from current `main` without it. The checkpoint issue is runtime-only and
has no source-file dependency on the three Core indexes.

Recommended integration order:

1. prepared-reuse declaration indexing;
2. Core-preparation declaration indexing;
3. consume-specialization candidate indexing;
4. repeat the clean late-Core profile;
5. checkpoint amortization against that new parent.

Checkpoint amortization is deliberately last even though it is source-file
independent. Removing algorithmic scans first gives its semantic tradeoff a
cleaner absolute measurement and prevents overlapping profiler stacks from
inflating its apparent opportunity.

## Common Measurement Contract

Every issue records:

1. baseline and candidate revisions;
2. compiler executable SHA-256 values;
3. host, architecture, compiler version, and optimization flags;
4. exact benchmark and self-compilation commands;
5. one discarded warmup and at least seven alternating measured pairs;
6. ten pairs when the median change is below 2%;
7. raw samples, median, and median absolute deviation;
8. deterministic work counters and a semantic checksum;
9. allocation, release, current-object, allocator-byte, and peak-RSS deltas
   where the harness can report them;
10. final Core and generated-C identity where the issue requires it; and
11. focused and integrated test results.

The changed compiler must compile the workload. Compiling changed source with
an unchanged compiler does not measure the candidate compiler implementation.
Keep measurement artifacts out of the repository unless the issue explicitly
requires a retained result document.

## Common Correctness Contract

- Preserve source declaration order and diagnostic order. Dictionaries are
  lookup authorities, never output-order authorities.
- Preserve exact definition identity where the input carries it. Names may be
  used only where the current phase's canonical representation makes names the
  documented identity.
- Make duplicate behavior explicit at index construction. Never acquire
  accidental last-write-wins behavior from `Dict.set`.
- Build each pass-local product once at its public entry point and thread it
  through recursion. Do not rebuild it per declaration, function, or node.
- Delete superseded scans. A new dictionary beside a fallback scan is not a
  completed optimization.
- Do not retain an index across a mutating pass boundary. Each issue owns the
  declaration or candidate epoch it indexes.
- Prefer ordinals into an immutable source-order list if storing complete Core
  values materially increases allocation or retained memory.
- Put deterministic work counters in lane-owned benchmark adapters or behind
  `@debug_only`. They must compile down to no mutation, allocation, or branch in
  the normal optimized compiler path. Verify the candidate's generated C or
  optimized symbols rather than assuming an unused counter compiles away.
- Reject a candidate that misses its issue's performance gate. The packet is
  not permission to retain theoretically better but measurably worse code.

## Fast Feedback Philosophy

During implementation, use the issue-owned focused test and benchmark. Do not
rebuild or compile the entire compiler after every edit. Run the changed-stage
typecheck and one representative benchmark shape first, then the focused Core
suite. Build the candidate compiler and run compiler self-compilation only
after the local representation is stable. Run broad compiler/runtime gates
once before review.

## Packet Completion

The packet is complete when every issue is either merged with its evidence or
closed with a recorded rejection, and a fresh native late-Core sample has been
captured from the resulting `main`. That profile, not this packet's historical
percentages, decides the next optimization family.
