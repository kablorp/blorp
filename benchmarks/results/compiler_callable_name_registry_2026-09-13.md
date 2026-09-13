# Compiler Callable Name Registry Batching

Former issue: callable-name registry copies (#94). The implementation handoff
was removed after integration; Git history preserves it.

Measured source commit: `6102a27d Batch callable name registry construction`
Integrated on `main` in `0d16352a`.

The final branch commit may differ because this results note was added after
the validation run; no source or benchmark code changed after the measured
source commit.

## Summary

Core graph preparation previously registered callable display names by fetching a
module dictionary, setting one callable, and writing the dictionary back for
every callable. Temporary instrumentation showed this copied dictionary entries
quadratically for large single-module workloads. The candidate batches entries
per module, builds the module dictionary once with `dict_from_list`, and writes
the outer `by_module` list once per populated module.

The retained benchmark is a public whole-graph preparation benchmark. It builds
typed graph inputs outside the measured window, then executes exactly one
`prepare_core_graph` call per process invocation. Repetition is external.

## Provenance

Build and checks were run in:

```text
/Users/keithphilpott/.codex/worktrees/d8e7/blorp
```

Candidate binary provenance:

```text
branch: codex/issue-94-callable-registry-copies
measured source commit: 6102a27d
compiler: /Users/keithphilpott/.codex/worktrees/d8e7/blorp/bin/blorp
```

The benchmark runner command family was:

```bash
BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 \
BLORP_COMPILER_BENCHMARK_COMPILER="$PWD/bin/blorp" \
benchmarks/compiler_callable_name_registry_profile plain 1 <modules> <callables> <shape>
```

Shapes:

- `top`: top-level `TypedFunctionDecl`s.
- `private`: each callable wrapped in `TypedPrivateDecl`.
- `impl`: callables grouped as impl methods.

Full quiet candidate matrix log:

```text
/tmp/issue94_callable_registry_matrix.log
```

## Temporary Direct-Counter Evidence

These counts came from a temporary instrumentation hook that was removed from
production before the final commit. They are retained here as direct work-counter
evidence, not as part of the public benchmark API.

The old algorithm's copied dictionary entries matched:

```text
sum over populated modules: k * (k - 1) / 2
```

where `k` is the callable count in that module. The candidate's copied
dictionary-entry counter was `0` for the unique-module workloads below because
dictionary construction moved to one `dict_from_list` per populated module.

The outer `by_module` list work is separate: old work was per callable
(`total_callables * module_count`); candidate work is one write per populated
module (`module_count * populated_modules`).

| modules | callables | old dict copied entries | candidate dict copied entries | old outer list work | candidate outer list work |
|---:|---:|---:|---:|---:|---:|
| 1 | 4096 | 8,386,560 | 0 | 4,096 | 1 |
| 1 | 8192 | 33,550,336 | 0 | 8,192 | 1 |
| 1 | 16384 | 134,209,536 | 0 | 16,384 | 1 |
| 8 | 4096 | 1,046,528 | 0 | 32,768 | 64 |
| 8 | 8192 | 4,190,208 | 0 | 65,536 | 64 |
| 8 | 16384 | 16,769,024 | 0 | 131,072 | 64 |
| 32 | 4096 | 260,096 | 0 | 131,072 | 1,024 |
| 32 | 8192 | 1,044,480 | 0 | 262,144 | 1,024 |
| 32 | 16384 | 4,186,112 | 0 | 524,288 | 1,024 |

Temporary post-batching direct-counter elapsed medians for the top-level shape
before hook removal were:

| modules | 4096 elapsed us | 8192 elapsed us | 16384 elapsed us | dict copied entries |
|---:|---:|---:|---:|---:|
| 1 | 976 | 2,110 | 4,906 | 0 |
| 8 | 960 | 2,020 | 4,290 | 0 |
| 32 | 1,003 | 2,002 | 4,295 | 0 |

## Public Candidate Matrix

All rows reported:

```text
workload_valid=True
invocations=1
retained_objects=1
```

Values are medians of five process invocations.

### Top-Level Shape

| modules | callables | elapsed us | allocations |
|---:|---:|---:|---:|
| 1 | 4096 | 14,812 | 159,853 |
| 1 | 8192 | 40,630 | 319,599 |
| 1 | 16384 | 139,851 | 639,089 |
| 8 | 4096 | 38,193 | 285,806 |
| 8 | 8192 | 127,705 | 571,020 |
| 8 | 16384 | 489,919 | 1,141,418 |
| 32 | 4096 | 33,450 | 300,752 |
| 32 | 8192 | 93,021 | 599,502 |
| 32 | 16384 | 364,807 | 1,196,876 |

### Private Shape

| modules | callables | elapsed us | allocations |
|---:|---:|---:|---:|
| 1 | 4096 | 15,153 | 163,948 |
| 1 | 8192 | 42,783 | 327,790 |
| 1 | 16384 | 135,847 | 655,472 |
| 8 | 4096 | 39,501 | 289,901 |
| 8 | 8192 | 128,253 | 579,211 |
| 8 | 16384 | 489,253 | 1,157,801 |
| 32 | 4096 | 33,043 | 304,847 |
| 32 | 8192 | 95,191 | 607,693 |
| 32 | 16384 | 358,998 | 1,213,259 |

### Impl Shape

| modules | callables | elapsed us | allocations |
|---:|---:|---:|---:|
| 1 | 4096 | 12,297 | 123,024 |
| 1 | 8192 | 35,943 | 245,907 |
| 1 | 16384 | 107,281 | 491,670 |
| 8 | 4096 | 17,975 | 198,921 |
| 8 | 8192 | 51,810 | 397,089 |
| 8 | 16384 | 181,830 | 793,401 |
| 32 | 4096 | 19,047 | 208,983 |
| 32 | 8192 | 54,935 | 415,287 |
| 32 | 16384 | 208,166 | 827,799 |

## Generated-C Inspection

Generated candidate C:

```bash
bin/blorp compile --no-format --no-embed-runtime \
  -o /tmp/callable_name_registry_profile_revised.c \
  blorp/benchmark/compiler/compiler_callable_name_registry_profile.brp
```

Observed structure:

- Top-level declarations append registry entries directly in the owning module
  loop.
- Private and impl helpers allocate only a declaration-local entry list.
- The owning module loop appends returned declaration entries into the module
  accumulator.
- The module dictionary is built after the loop and committed with one
  `by_module.set`.

## Narrow Old/New Timing

This same-boundary timing comparison uses the same retained benchmark source
copied into an `eb6893ea` baseline worktree and the candidate worktree. It
measures only one-module top-level callable workloads, with five separate
process invocations per size.

Baseline provenance:

```text
worktree: /tmp/issue94_baseline_eb6893ea_GfX4z0
source commit: eb6893ea5e7d4e1e28fd2d81da468fb69a20d877
benchmark files: copied from the candidate retained benchmark harness
compiler: /tmp/issue94_baseline_eb6893ea_GfX4z0/bin/blorp
```

Candidate provenance:

```text
worktree: /Users/keithphilpott/.codex/worktrees/d8e7/blorp
source snapshot during timing: 79fffb1c7833149f471127a0ed665b4f2c9add0d
compiler: /Users/keithphilpott/.codex/worktrees/d8e7/blorp/bin/blorp
```

The source snapshot above differs from the final branch commit only by
results-note-only amendments.

Command family:

```bash
# baseline
BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 \
BLORP_COMPILER_BENCHMARK_WORKSPACE_ROOT="/tmp/issue94_baseline_eb6893ea_GfX4z0" \
BLORP_COMPILER_BENCHMARK_COMPILER="/tmp/issue94_baseline_eb6893ea_GfX4z0/bin/blorp" \
"/tmp/issue94_baseline_eb6893ea_GfX4z0/benchmarks/compiler_callable_name_registry_profile" \
plain 1 1 <callables> top

# candidate
BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 \
BLORP_COMPILER_BENCHMARK_COMPILER="$PWD/bin/blorp" \
benchmarks/compiler_callable_name_registry_profile plain 1 1 <callables> top
```

Full log:

```text
/tmp/issue94_old_new_top_one_module.log
```

All rows reported `workload_valid=True`, `invocations=1`, and
`retained_objects=1`.

| callables | baseline elapsed us | candidate elapsed us | speedup | baseline allocations | candidate allocations |
|---:|---:|---:|---:|---:|---:|
| 4096 | 60,469 | 14,649 | 4.13x | 163,942 | 159,853 |
| 8192 | 216,530 | 40,680 | 5.32x | 327,784 | 319,599 |
| 16384 | 821,796 | 137,629 | 5.97x | 655,466 | 639,089 |

## Validation

Final validation after the candidate revision:

```text
make
bin/blorp format --check \
  blorp/src/compiler/stage_08_core_lower/graph_prepare.brp \
  blorp/benchmark/compiler/compiler_callable_name_registry_profile_fixture.brp \
  blorp/benchmark/compiler/compiler_callable_name_registry_profile.brp \
  blorp/test/compiler/stage_08_core_lower/test_callable_name_registry_profile_benchmark.brp \
  blorp/test/compiler/stage_08_core_lower/test_core_lower.brp
bin/blorp test --timeout 180 blorp/test/compiler/stage_08_core_lower/test_core_lower.brp
bin/blorp test --timeout 180 blorp/test/compiler/stage_08_core_lower/test_callable_name_registry_profile_benchmark.brp
bin/blorp test --timeout 180 blorp/test/compiler/benchmark/test_core_ufcs_name_profile.brp
scripts/compiler-check --changed
```

Results:

- `make` passed.
- Core lower suite passed: 138/138.
- Callable-name registry benchmark suite passed: 4/4.
- Core UFCS name profile benchmark suite passed: 2/2.
- `scripts/compiler-check --changed` passed, including `compiler-core-sanitize`.

## Caveats

- The Public Candidate Matrix above is candidate-only whole-graph preparation
  timing; the narrower matched-path table separately reports old/new speedups.
- Old-vs-new copied-entry evidence came from temporary direct counters and is
  retained only as work-counter evidence.
- The benchmark and production pipeline exercise the normal typechecked graph
  shape where dependency modules are emitted once from `typechecked.modules`.
  The public `core_graph_modules` constructor can still be given repeated
  `CoreGraphUnit` values with the same `ModuleId`; in that malformed/direct
  caller case, the candidate still preserves semantics by merging with
  `dict_entries(existing).concat(entries)`, but it would rebuild that module's
  accumulated dictionary once per repeated unit. That repeated-unit cost is
  scoped outside the accepted per-callable dictionary-copy fix.
