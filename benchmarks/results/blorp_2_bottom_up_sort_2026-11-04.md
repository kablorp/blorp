# Blorp 2 bottom-up sort_by, 2026-11-04

`list_ops` retired 3.07 times the legacy compiler's instructions, and 86% of
Blorp 2's work was `sort_by`. That function was a top-down merge sort, and it
built a new List for every leaf and every merge: 2n - 1 Lists per sort. It is
now a bottom-up merge over two buffers. Each pass merges adjacent runs from one
buffer into the other with `set`, and then the two swap. Each buffer copies the
input once, on its first write; every later write updates a uniquely owned
buffer in place. A sort therefore allocates at most two Lists, whatever its
length; when the caller hands over a uniquely owned input, the second buffer
reuses it and the sort allocates one.

## Results

| Workload | Before | After | Change |
| --- | ---: | ---: | ---: |
| `list_ops` sorts only (200 × 10,000 Ints), instructions | 4.556 G | 1.661 G | −63.5% |
| `list_ops` sorts only, allocations | 3,999,817 | 417 | |
| `list_ops` whole benchmark, instructions | 5.24 G | 2.380 G | −54.6% |
| `list_ops` against legacy (1.718 G) | 3.07× | 1.39× | |
| `library_linear` e2e (4,096 elements), allocations | 12,306 | 4,117 | |
| Stage-2 self-compile, allocations | 12,430,398 | 12,351,951 | −0.63% |
| Stage-2 self-compile, -O2 instructions (mean of 3) | 10.762 G | 10.730 G | −0.30% |

The e2e allocation pins move by the old sort's 2n − 1 Lists per sort, less the
new one or two:

| Fixture | Before | After |
| --- | ---: | ---: |
| `library_linear` | 12,306 | 4,117 |
| `library_loops` | 626 | 581 |
| `list_sort_by` | 68 | 45 |
| `list_sort_by_orderable` | 59 | 34 |
| `list_sort_by_nested_stress` | 1,326 | 811 |
| `sort_by_ties` (new: 1,000 elements on seven keys) | | 6 |

The new `sort_by_ties` fixture fails, reporting 993 disorders, when a tie takes
the right element.

The other `list_ops` operations do not use `sort_by` and are unchanged. Measured
on their own, each net of startup, legacy against Blorp 2:

| Operation | Legacy | Blorp 2 |
| --- | ---: | ---: |
| append | 150 M | 170 M |
| filter | 125 M | 129 M |
| fold | 186 M | 22 M |
| reverse | 262 M | 380 M |
| concat | 17 M | 16 M |

The sort is still 1.7 times the legacy builtin. Each merge step reads through
`get`, which returns an `Option`, reads its two candidates again for the key
comparison, and checks uniqueness inside `set`. The legacy builtin compares
`Int`s inline over raw buffers.

## Method

- **Machine.** Apple M4, macOS 26, Apple clang. Every binary ran serially, with
  no Blorp 2 gate running, which was checked with the anchored `pgrep -f`
  pattern.
- **Source.**
  - Base: `f3f623599`.
  - Candidate: branch `blorp2/bottom-up-sort` on top of it.
  - The only difference is `blorp_2/standard_library/list.brp` plus tests and
    docs.
- **`list_ops`.**
  - Compiling and linking:
    - Both trees run `make -C <tree>/blorp_2 compiler`, and each tree's
      `blorp_2/build/compiler` compiles `benchmarks/blorp_2/list_ops.brp` with
      `--library-root <tree>/blorp_2/standard_library`.
    - `clang -fwrapv -O2` builds the result.
    - Legacy is `bin/blorp compile benchmarks/blorp/list_ops.brp`, built with
      the same flags.
  - The per-operation rows come from a copy of each benchmark whose `main` runs
    the one operation named in `argv[1]`. Each row subtracts a startup-only run.
  - Instructions come from `/usr/bin/time -l` "instructions retired".
  - Allocations come from an `-O0 -DBLORP_MEMORY_DIAGNOSTICS=1` build run with
    `BLORP_LEAK_CHECK=strict`. Both report 0 leaked.
  - The benchmark's stdout is byte-identical before and after.
- **Self-compile.**
  - Each tree's seed-generated `blorp_2/build/compiler.c` is built with
    `clang -O2` (stage 1).
  - Stage 1 compiles its own tree's `blorp_2/src/main.brp`, and that C is built
    with `-O2` (stage 2) and again with `-O0 -DBLORP_MEMORY_DIAGNOSTICS=1`.
  - Both stage-2 compilers compile the base tree's `src/main.brp` with the base
    tree's library. Their emitted C is byte-identical at -O2 and at -O0.

## Raw samples

`list_ops` sorts only (`argv[1] = sort`), instructions retired, in run order:

```
legacy 977,972,781  975,911,374  975,865,246
before 4,556,695,614  4,504,403,647  4,556,513,219
after  1,660,887,519  1,660,822,924  1,660,867,883
```

`list_ops` whole benchmark, instructions retired (wall time):

```
legacy 1,719,364,942 (0.09 s)  1,717,346,058 (0.08 s)  1,717,248,364 (0.08 s)
before 5,275,939,151 (0.25 s)  5,223,705,568 (0.25 s)  5,223,443,326 (0.23 s)
after  2,380,230,516 (0.11 s)  2,379,964,528 (0.11 s)  2,380,120,522 (0.11 s)
```

Stage-2 self-compile at -O2, instructions retired (wall time), alternating:

```
before 10,775,473,544 (0.74 s)  10,755,677,427 (0.72 s)  10,754,783,613 (0.71 s)
after  10,738,822,744 (0.71 s)  10,728,854,217 (0.71 s)  10,722,325,940 (0.71 s)
```
