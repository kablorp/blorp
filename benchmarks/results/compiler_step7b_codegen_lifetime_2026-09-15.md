# Step 7B Codegen Input Lifetime Result — 2026-09-15

## Outcome

The normal compile command now transitions through an opaque pre-Core request
that cannot reach `CliCompilePlan`, `TypecheckedGraph`, or full source-text
buffers.
The new `core_lowering_input_ready` checkpoint proves that the transition
releases 102,650 managed objects and 17,005,632 allocator bytes before Core
allocation begins.

Within the candidate run, the boundary changes live state as follows:

| Metric | Frontend complete | Core input ready | Change |
| --- | ---: | ---: | ---: |
| Live managed objects | 8,338,467 | 8,235,817 | -102,650 (-1.23%) |
| Allocator bytes | 652,793,552 | 635,787,920 | -17,005,632 (-2.60%) |

This is a positive memory result at the intended boundary. It is not yet a
cross-build peak result: late Core and backend data dominate the process
high-water mark, and Roadmap Step 9 targets those owners.

## Workload And Command

The retained candidate compiled `blorp/src/main.brp` on macOS from repository
revision `c2c7d495af51d84e6822d9b1a704a5fa7b011e74` with the uncommitted Steps 7A
and 7B changes present.

```bash
env BLORP_COMPILER_MEMORY_PROFILE=1 bin/blorp compile --no-format \
  --no-embed-runtime --time-phases \
  -o /tmp/blorp-step7b-<sample>.c blorp/src/main.brp \
  > /tmp/blorp-step7b-<sample>.stdout \
  2> /tmp/blorp-step7b-<sample>.stderr
```

The raw candidate log was retained locally as
`/tmp/blorp-step7b-candidate7.stderr`. The candidate compiler SHA-256 was
`88a51be5f2c1815d4c6f88413d9eaa97dd8557d1cb4eb5fc127d878121bd26b1`.

## Comparison Caveat

An exploratory baseline/candidate pair reported favorable later memory and
timing deltas, but each compiler compiled its own changed `blorp/src/main.brp`.
The resulting C files differed in size and hash, so those cross-build deltas
are confounded and are not evidence for this change. A future headline
comparison must use frozen identical input, preserve both compiler hashes, and
run three alternating pairs; ten pairs are unnecessary. The within-candidate
allocator and live-object transition above is the direct signal accepted here.

Generated C for the compiler itself is not byte-identical because this workload
compiles the changed compiler sources. Focused runtime tests and the codegen
audit are the semantic/output guard instead.
