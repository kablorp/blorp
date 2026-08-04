# Changed-only type resolution measurement

Date: 2026-08-03

## Verdict

Returning the original immutable `CompilerType` tree when qualified-name or
imported-alias resolution makes no change removes substantial reconstruction
work and produces a small import-heavy frontend speedup.

- Qualified unchanged-tree allocations: 16 before, 4 after.
- Imported-alias unchanged-tree allocations: 21 before, 4 after.
- Import-graph paired median elapsed change: -2.45%.
- Candidate wins: 9 of 10 order-alternated pairs.
- All samples produced checksum `14565`.

The allocation counts are deterministic focused-test measurements. The wall
time result is directional rather than a whole-compiler latency claim because
an unrelated Docker test gate was active on the host.

## Revisions

| Variant | Source |
|---|---|
| Baseline | `3325ca9aca873b1e5a7914ce59aa2ee170cf6699` |
| Candidate | Baseline plus production diff `d95474949cfd8dd4851306940a58b5b77c417fa86c0100be6933cb050ab6b4bd` |

Both artifacts used the same compiler executable and pinned bootstrap. The
baseline and candidate worktrees had equal-length absolute paths so generated
symbol names did not bias artifact shape.

## Method

The existing `compiler_import_graph_profile` workload ran five iterations per
sample with 30 modules, 32 functions per module, import fan-out 20, and retained
parsed programs. Ten pairs alternated execution order. The benchmark verified
31 artifacts, 1,021 typed declarations, 420 resolved imports, and identical
checksums for every sample.

Median elapsed time was 2.1648525 seconds for the baseline and 2.126220 seconds
for the candidate. The raw median difference was -1.78%; the median of paired
percentage changes was -2.45%.

The focused allocation tests retain a ceiling of four allocations for the
representative unchanged tree. During test development, a temporary copy of
the old always-rebuild traversal established the 16- and 21-allocation
baselines; that duplicate implementation was then removed.

## Raw data

See `compiler_type_resolution_changed_only_2026-08-03.tsv`.
