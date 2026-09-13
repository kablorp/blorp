# Nested declaration hoist finalization profile - Issue 92

Date: 2026-09-13

Integrated on `main` in `a2f613a2` (optimization) and `4c8c9947`
(corrected direct benchmark and evidence).

## Scope

This measures the source-AST nested declaration finalization pass directly.
Fixture source construction and parsing happen before the timed window. The
timed work is exactly one call to:

```blorp
finalize_nested_functions_program(parsed)
```

Benchmark source:

- `blorp/benchmark/compiler/compiler_nested_hoist_finalize_profile.brp`

Build setup:

- Baseline compiler: `eb6893ea` in `/var/folders/m7/zszgqft538nfx_qr1kmc7dlc0000gn/T/issue92_baseline_1789285542_23447`
- Candidate compiler: `32e92f61` plus the benchmark source in this worktree
- Each benchmark was compiled to C with its matching compiler, then built with `cc -O2`.
- Each row below uses 1 warmup process and 5 measured process invocations.

Benchmark command shape:

```bash
baseline_dir=/var/folders/m7/zszgqft538nfx_qr1kmc7dlc0000gn/T/issue92_baseline_1789285542_23447
bench_dir=/var/folders/m7/zszgqft538nfx_qr1kmc7dlc0000gn/T/issue92_finalize_bench.EBRXVi

"$baseline_dir/bin/blorp" compile --no-format -o "$bench_dir/baseline_nested_hoist_finalize.c" \
  "$baseline_dir/blorp/benchmark/compiler/compiler_nested_hoist_finalize_profile.brp"
bin/blorp compile --no-format -o "$bench_dir/candidate_nested_hoist_finalize.c" \
  blorp/benchmark/compiler/compiler_nested_hoist_finalize_profile.brp
cc -O2 "$bench_dir/baseline_nested_hoist_finalize.c" -o "$bench_dir/baseline_nested_hoist_finalize"
cc -O2 "$bench_dir/candidate_nested_hoist_finalize.c" -o "$bench_dir/candidate_nested_hoist_finalize"
```

Output validation:

- Every run reported `parse_diagnostics=0`, `finalize_diagnostics=0`, and `workload_valid=True`.
- Baseline and candidate checksums matched for every variant/size pair.
- Full sample log: `/var/folders/m7/zszgqft538nfx_qr1kmc7dlc0000gn/T/issue92_finalize_bench.EBRXVi/finalize_samples.log`

## Results

Times are finalization-only elapsed microseconds, averaged over five measured
process invocations after one warmup.

| Variant | Functions | Baseline avg us | Candidate avg us | Speedup | Baseline min/max us | Candidate min/max us | Checksum |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| independent | 4,096 | 53,017.0 | 838.0 | 63.3x | 49,974 / 58,406 | 707 / 1,129 | 3491015909307924894 |
| independent | 8,192 | 206,673.0 | 1,754.0 | 117.8x | 204,616 / 210,341 | 1,702 / 1,825 | -96855918857296248 |
| independent | 16,384 | 836,030.0 | 3,989.2 | 209.6x | 829,759 / 841,766 | 3,884 / 4,086 | -5190079602003779228 |
| mixed | 4,096 | 113,917.4 | 4,653.6 | 24.5x | 113,260 / 114,487 | 4,587 / 4,710 | 4076157424609887495 |
| mixed | 8,192 | 444,665.6 | 9,770.8 | 45.5x | 442,187 / 446,882 | 9,668 / 9,852 | -1651308805904211444 |
| mixed | 16,384 | 1,759,264.2 | 19,666.2 | 89.5x | 1,749,552 / 1,769,824 | 19,358 / 19,933 | 4831792469239693159 |

The baseline grows close to quadratically as fixture size doubles. The
candidate grows roughly linearly in the measured range.

## Expected Copy Work

The old implementation repeatedly concatenated accumulated prefixes with
new hoisted declarations. For these deterministic fixtures, the expected
old copied-prefix work is:

| Variant | Functions | Old copied-prefix elements |
| --- | ---: | ---: |
| independent | 4,096 | 8,386,560 |
| independent | 8,192 | 33,550,336 |
| independent | 16,384 | 134,209,536 |
| mixed | 4,096 | 16,781,312 |
| mixed | 8,192 | 67,117,056 |
| mixed | 16,384 | 268,451,840 |

The candidate replaces those top-level concatenations with direct append loops
over `result.hoisted`, so accumulated prefixes are not recopied at every
declaration boundary.

## Separate Tooling Rough Edge

While preparing the same-source baseline, compiling the benchmark from a
hyphenated temporary worktree failed because generated C identifiers included
pieces of the absolute source path:

```text
/var/folders/.../issue92-baseline-eb6893ea.WkJYpU/...
typedef struct _var_folders_..._issue92-baseline-eb6893ea_WkJYpU_...
                                      ^
error: expected identifier or '('
```

The benchmark was rerun from an underscore-only temporary worktree to avoid
mixing that compiler issue into Issue 92 timing evidence. That path-derived
identifier sanitization bug is separate from nested declaration hoisting.
