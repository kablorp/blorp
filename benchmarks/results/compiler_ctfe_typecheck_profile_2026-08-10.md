# CTFE dependency typecheck profile

Date: 2026-08-10

## Verdict

Declaration prescan was a worthwhile low-risk first slice. Retaining the
top-level-name dictionary in the batch loop instead of storing it back into the
full typecheck state after every declaration reduced the `24 x 32` median by
8.50% and the broad `64 x 128` median by 27.00%. The `64 x 1` depth control was
effectively unchanged, which localizes the gain to declaration width rather
than dependency planning.

The next substantial architectural target remains CTFE dependency preparation,
not the dependency-order planner around it. Each imported program is
typechecked with its reachable import closure, and all of its function bodies
are materialized before constant evaluation even when CTFE reaches only one.

This should be addressed in architectural order:

1. build definition-owned type headers once for the graph, as specified by
   the typechecking phase-product work active at the time;
2. reuse those immutable headers when preparing imported CTFE programs; and
3. materialize CTFE bodies from an explicit reachable-definition worklist.

The first step removes repeated importer-owned semantic registration and gives
the later reachability step a shared, typed declaration boundary. A standalone
CTFE-only typechecker would duplicate semantics and is not an acceptable
shortcut.

## Prescan result

Both revisions used retained parsed programs and three graph typechecks per
sample. Each median is from seven warm serial samples of the cached benchmark
executable. The exact baseline and candidate `typecheck_decl.brp` Git blob IDs
are recorded with the raw samples. Review subsequently replaced two wildcard
no-op match arms with explicit declaration variants; the raw data also records
that reviewed source blob separately from the measured candidate.

| Modules | Functions per module | Baseline median | Candidate median | Change |
|---:|---:|---:|---:|---:|
| 24 | 32 | 89.387 ms | 81.787 ms | -8.50% |
| 64 | 1 | 135.583 ms | 135.347 ms | -0.17% |
| 64 | 128 | 1,328.839 ms | 970.087 ms | -27.00% |

The implementation preserves the existing single-declaration API, known type
and resource-name updates, private-declaration recursion, foreign functions,
and first-declaration-wins namespace behavior. The batch path now mutates one
loop-owned dictionary value and writes it into the state once.

## Scaling baseline

The baseline benchmark used retained parsed programs and three graph
typechecks per sample. Setup and parsing are outside the elapsed region.

| Modules | Functions per module | Median elapsed | Per graph |
|---:|---:|---:|---:|
| 8 | 1 | 8.12 ms | 2.71 ms |
| 8 | 32 | 26.9 ms | 8.97 ms |
| 8 | 128 | 109.4 ms | 36.5 ms |
| 24 | 1 | 26.4 ms | 8.79 ms |
| 24 | 32 | 89.4 ms | 29.8 ms |
| 24 | 128 | 383.2 ms | 127.7 ms |
| 64 | 1 | 135.6 ms | 45.2 ms |
| 64 | 32 | 353.6 ms | 117.9 ms |
| 64 | 128 | 1,328.8 ms | 442.9 ms |

At 24 modules, changing only unreachable sibling width from 1 to 128 accounts
for about 93% of the wide workload. At 64 modules it accounts for about 90%.
Those percentages are an upper bound for selective materialization, because a
real program may reach more than one body per module, but they establish that
the available gain is structural rather than a small inference micro-tuning.

Seven warm `3 24 32 retained` samples were 89.387, 89.183, 93.721, 88.888,
89.119, 89.396, and 91.898 ms; the median was 89.387 ms. Raw samples for this
workload and the two `64`-module controls are in
`compiler_ctfe_typecheck_profile_2026-08-10.tsv`.

## Function profile

One instrumented `1 24 32 retained` graph took 1.057 seconds under function
instrumentation. Inclusive times were:

| Function | Inclusive time | Calls |
|---|---:|---:|
| `prepare_ctfe_dependencies` | 1.032 s | 1 |
| `ctfe_imported_program_from_prepared` | 1.032 s | 24 |
| `typecheck_program_with_import_modules_for_module` | 1.016 s | 24 |
| body materialization | 0.702 s | 25 programs |
| imported-module registration | 0.183 s | 25 programs |

The run materialized 768 dependency function bodies plus the target `main`,
although the evaluated dependency call chain used 24 functions. Inclusive
times overlap and must not be added.

The narrow `1 64 1 retained` control still spent 452 ms of 475 ms instrumented
time in CTFE dependency preparation. Imported-module registration consumed
214 ms and imported type registration consumed 186 ms across the transitive
closures. This is the direct evidence for doing shared type headers before
selective body checking.

An optimized baseline native stack sample of a deliberately long wide run
collected 7,721 main-thread samples. `blorp_dict_copy` was the largest resolved
leaf at 605 samples, followed by substantial dict destruction, allocation, and
memory movement. The dominant call chain passed through imported-module type
registration, declaration prescan, and top-level-name insertion. This justified
moving dictionary ownership to the prescan batch boundary without changing
typechecking semantics.

In the instrumented candidate, all 349 `typecheck_prescan_decls` calls consumed
5.4 ms inclusive. Its 11,138 top-level insertions consumed 3.7 ms, while body
materialization still consumed about 0.70 seconds. Function instrumentation is
intrusive, so those numbers are attribution evidence rather than a timing
comparison with the optimized samples.

## Rejected experiment

An indexed direct-dependency plan and retained per-artifact CTFE plan changed
the default median by less than 1%, improved the `64 1` depth control by about
1.2%, and did not improve `64 128`. The production experiment was reverted.
It confirmed that dependency-order list mechanics are not the current target.

## Feedback loop

```bash
# Fast optimized guard after the first content-addressed build.
BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 \
  benchmarks/compiler_ctfe_typecheck_profile 3 24 32 retained

# Separate depth from eager body width.
BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 \
  benchmarks/compiler_ctfe_typecheck_profile 3 64 1 retained
BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 \
  benchmarks/compiler_ctfe_typecheck_profile 3 64 128 retained

# Attribute production functions; do not compare its elapsed time to O2.
BLORP_CTFE_TYPECHECK_PROFILE_FUNCTIONS=1 \
  benchmarks/compiler_ctfe_typecheck_profile 1 24 32 retained
```

The focused correctness guard is:

```bash
./blorp test --timeout 120 \
  compiler/tests/test_compiler_ctfe_typecheck_profile_benchmark.brp
```
