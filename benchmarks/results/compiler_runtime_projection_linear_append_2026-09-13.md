# Compiler Runtime Projection Linear Append

Date: 2026-09-13

Integrated on `main` in `04eb0437`.

Issue 93 changes `project_runtime_program` to build the projected runtime
declaration list with a preallocated accumulator and per-row `append` instead
of repeated whole-list concatenation.

Baseline source commit: `eb6893ea5e7d4e1e28fd2d81da468fb69a20d877`.
Candidate source: `76705425` on `codex/issue-93-runtime-projection`.

## Corrected Direct Profile

The retained CLI benchmark constructs the fixture outside the measurement
window, runs exactly one real `project_runtime_program(program)` inside the
time/profile/memory window, captures metrics, then validates rows and computes
the checksum after the window closes.

Commands used for the final samples:

```bash
for i in 1 2 3 4 5; do
	bin/blorp run --no-format \
		blorp/benchmark/compiler/compiler_runtime_projection_profile.brp -- \
		0 4096 0 0
done

for i in 1 2 3 4 5; do
	bin/blorp run --no-format \
		blorp/benchmark/compiler/compiler_runtime_projection_profile.brp -- \
		0 8192 0 0
done

for i in 1 2 3 4 5; do
	bin/blorp run --no-format \
		blorp/benchmark/compiler/compiler_runtime_projection_profile.brp -- \
		0 16384 0 0
done
```

Arguments are `generic_declarations function_declarations impl_declarations
methods_per_impl`. All samples reported `workload_valid=True` and
`error_count=0`.

| Functions | Modeled legacy prefix elements | Elapsed samples, us | Median, us | Allocations |
| ---: | ---: | --- | ---: | ---: |
| 4,096 | 8,386,560 | 2,592; 2,971; 2,888; 8,265; 8,310 | 2,971 | 40,969 |
| 8,192 | 33,550,336 | 4,982; 5,313; 5,605; 5,258; 5,161 | 5,258 | 81,929 |
| 16,384 | 134,209,536 | 10,429; 23,468; 23,959; 23,874; 23,993 | 23,874 | 163,849 |

The 4,096-point samples include two late outliers, and the 16,384-point samples
split between one low first sample and four higher samples. Treat this matrix
as corrected-boundary evidence that the retained benchmark excludes validation
work from the measured window; do not use these medians alone as a precise
scaling claim.

## Historical Inclusive Check

Before the benchmark boundary was corrected, the same fixture was run with a
temporary old concat-loop toggle and with the append candidate through an
inclusive helper window. Those measurements included projection plus O(output)
row validation/checksum work, so they are useful only as a same-boundary
old/new sanity check. They did not time exactly one `project_runtime_program`
with checksum outside the window and are not directly comparable to the
corrected direct profile above.

Commands used with the older inclusive driver:

```bash
bin/blorp run --no-format \
	blorp/benchmark/compiler/compiler_runtime_projection_profile.brp -- \
	5 0 4096 0 0

bin/blorp run --no-format \
	blorp/benchmark/compiler/compiler_runtime_projection_profile.brp -- \
	5 0 8192 0 0

bin/blorp run --no-format \
	blorp/benchmark/compiler/compiler_runtime_projection_profile.brp -- \
	5 0 16384 0 0
```

| Functions per iteration | Iterations | Legacy concat-loop elapsed, us | Append elapsed, us | Change |
| ---: | ---: | ---: | ---: | ---: |
| 4,096 | 5 | 149,060 | 32,567 | -78.15% |
| 8,192 | 5 | 591,414 | 32,574 | -94.49% |
| 16,384 | 5 | 2,268,182 | 97,310 | -95.71% |

The modeled legacy concat-loop prefix elements were 41,932,800, 167,751,680,
and 671,047,680 respectively, derived from the fixture shape rather than an
instrumented collection-copy counter. Use those modeled values to explain the
expected repeated whole-prefix copy pressure. The elapsed values in this
section are retained as inclusive same-boundary context only. The final
benchmark does not report a current production copy counter; it reports only
modeled legacy prefix pressure from fixture shape.

## Validation

- `bin/blorp check --no-format blorp/benchmark/compiler/compiler_runtime_projection_profile.brp`: passed.
- `bin/blorp test blorp/test/compiler/stage_09_core/test_core_runtime_projection_benchmark.brp`: 3 passed, 0 failed.
- `git diff --check HEAD`: passed.
