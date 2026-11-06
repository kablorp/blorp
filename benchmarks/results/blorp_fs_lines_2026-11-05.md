# Blorp fs library, line reading (phase 2c, landing iii) (2026-11-05)

`fs.fold_lines` joins `fs.brp`: a private opaque `Descriptor` over the three
line natives of landing (i), the private `with_descriptor` (the one place a
descriptor is opened and closed) and `fold_descriptor`, and the public
`fold_lines`. `at_path` shares its error record with the fold through a new
private `error_at`. Nothing under `blorp/src` changes.

## Provenance

| | Base | Candidate |
| --- | --- | --- |
| Source | `d49241001`, `git archive` of `blorp` and `scripts` into `build/2c/base` | the `blorp/fs-fold-lines` worktree, the commit this report is in |
| Stage-A `compiler.c` (sha256) | `ce3d3713417ad51e535b30c7efc26a8a0bc644c305fb069cab4ad1dbfa0bbc85` | `a6ac5466dec5316f3e91be250238b141223adfec0d9b227e2e1eb563f7a75d35` |
| Self C (sha256) | `9b911d581838de142e00a89424c05110ce1febf51b68571583f5617c28b1d643` | `65f32be7c76592d4aa097a5a2583fb71604a5a45c16c9cbe970af14b43858f1f` |
| Self C bytes | 22,867,646 | 22,867,657 |

Host: Apple M4, macOS 26.7.1, Apple clang, other sessions sharing the machine
(load average 7 to 10), every run serial. Raw samples are under the ignored
`build/2c/measure/` of the candidate worktree.

The stage-A `compiler.c` files are **not** byte-identical, so the fixed-input
cost is measured, not zero by construction. The compiler itself imports
`fs.read_text`, which calls `at_path`, which now calls the new `error_at`:
the self C gains that function (+11 bytes) and renumbers. The other new
functions are not instantiated by the compiler.

## Ceilings

| Metric | Ceiling | Measured |
| --- | --- | --- |
| `blorp/src` | 0 lines | 0 (`git diff origin/main --stat -- blorp/src` is empty) |
| `fs.brp` | at most +90 lines | +83 -1, net +82: 47 code, 27 comment, 9 blank |
| Self-compile allocations, `-O2` build with strict leak check | +0.15% | 12,372,112 to 12,379,103 (+6,991, +0.057%), 0 leaked |
| Self-compile instructions, `-O2` | +0.15% | 21 rounds, median 10,816,739,618 to 10,829,942,182 (+0.122%); minimum -0.083% |
| Fixed-input instructions, `-O2` | +0.05% by median | 21 rounds, median 10,820,137,715 to 10,817,339,044 (-0.026%); minimum -0.090% |
| Self-compile instructions, `-O0` | reported | 5 rounds, median 33,668,015,583 to 33,656,676,951 (-0.034%); minimum -0.175% |
| Running total, phases 1 to 2c | 1.5% cap | +0.203% before this landing; +0.177% with the fixed-input median above |
| The new example's compile ceiling | measured +15% | 293,604 allocations and 1,051,259,500 instructions measured (largest of three); ceiling 337,645 and 1,208,948,425 |

Spread (maximum over minimum) in the 21-round runs: self-compile 0.90% base
and 1.08% candidate; fixed input 0.37% and 0.49%. The effects above are
smaller than the spread, so each is an upper bound on a small effect. An
earlier five-round run of the same binaries gave a fixed-input median of
+0.063% (minimum -0.017%) and a self-compile median of +0.142% (minimum
+0.090%); the 21-round runs, interleaved with the order alternating each
round, are the ones reported. With the five-round fixed-input figure the
running total would be +0.266%, still under the cap.

### Commands

```bash
# Base tree, from the commit this branch started at.
git archive -o build/2c/base.tar d49241001 blorp scripts
tar -x -f build/2c/base.tar -C build/2c/base

# build/2c/build_side.sh NAME ROOT o2|o2d|o0: `make -C ROOT/blorp compiler`, the
# self C of ROOT/blorp/src, then the self C linked at -O2, -O2 with
# -DBLORP_MEMORY_DIAGNOSTICS=1, or -O0.
# build/2c/measure_self.sh and measure_fixed.sh: 21 interleaved rounds of
#   /usr/bin/time -l COMPILER --library-root LIBRARY blorp/src/main.brp out.c
# and the "instructions retired" line. measure_cost.sh: five rounds, -O0, and
# the strict allocation counts.
```

## The plan's memory claims

Throwaway programs `count.brp` (a fold counting lines), `collect.brp` (a fold
appending every line to a List) and `readcount.brp` (`read_text`, then a loop
counting LF bytes), compiled to C and linked `-std=c11 -O2
-DBLORP_MEMORY_DIAGNOSTICS=0`. Each figure is `/usr/bin/time -l`; RSS is the
median of three runs. The files were made by `build/2c/mem/generate.sh`
(lines of the form `short line N`) and deleted afterwards.

| Claim | Run | Peak RSS | Verdict |
| --- | --- | --- | --- |
| Short lines are within 2 MiB of the 1 MB file | count, 1.0 MB (60,000 lines) | 2,080,768 | |
| | count, 10.7 MB | 2,113,536 | |
| | count, 99.6 MB (5,300,000 lines) | 2,179,072 | +98,304 bytes: holds |
| One long line peaks at most 40 MB above the 1 MB run | count, one 10 MiB line | 24,559,616 | +22,478,848 bytes: holds |

Instructions of `count` over the 99.6 MB file: 4,197,189,624 (median), about
792 per line.

| List accumulator | `collect` instructions | Ratio to previous | `count` | `read_text` and count |
| --- | --- | --- | --- | --- |
| 5,000 lines | 166,930,460 | | 16,381,348 | 13,147,590 |
| 10,000 lines | 616,675,120 | 3.69 | 22,270,597 | 15,717,854 |
| 20,000 lines | 2,388,610,914 | 3.87 | 28,166,891 | 15,358,254 |

Subtracting the count fold, the accumulator's own cost is 150.5 M, 594.4 M and
2,360.4 M: 3.95 and 3.97 per doubling. The documented quadratic cost holds.

### `take` or an index loop

`fold_descriptor` steps the complete lines of a batch through
`batch.take(complete)`, one List copy per 64 KiB block. A variant with
`for index in 0..complete` and `batch.get_or(index, "")` (library copy under
`build/2c/lib_index`) counts the 99.6 MB file in 3,903,947,609 instructions
(median) against 4,197,189,624: -7.0%, with a trivial step. The kept code uses
`take`: it needs no default String that can never be used, the saving is
small next to any real step, and it is a later, measured change if wanted.

## Tests

- `make -C blorp test`: exit 0; the self-hosted native e2e group is 125 tests
  (the process-lifecycle group is 73), 0 failures. `fs_lines` runs under the
  normal and the strict leak builds.
- The new example, `fixtures/fs/lines.brp`, makes 6,156,046 allocations per
  run, all released, in 0.8 s at `-O0`.
- `scripts/blorp-fixpoint --prove`: exit 0 on the third try. The first try
  stopped at `test_emit` with a native timeout, the second at the process
  spawn flake (`exec or child setup; errno=1`), both while other sessions
  were running the same gates.

## Oracles

Each break was made in `fs.brp`, `lines.brp` compiled and run against the
prepared tree, and the output diffed with the accepted one. Only these lines
differed.

| Break | Lines that differed |
| --- | --- |
| Delete `native_close` | Nothing differed on this machine: its soft limit is 1,048,576 descriptors, far above the 1,300 opens. With `ulimit -n 256`, macOS's default: the 1,000 early stops give 241 stopped and 759 `OtherOs`, the 300 failures give 300 `OtherOs`, and the temporary directory's removal fails with EMFILE (the output ends at `temporary directory: ... operating system error 24`) |
| Pass `""` for `carried` | `mixed.txt`, `scores_ok.txt`, `crlf.txt`, `growth.txt`, `tail.txt`, `carried.txt` |
| Step every element of a batch | `newline.txt`, `mixed.txt`, `scores_ok.txt`, `crlf.txt`, `growth.txt`, `tail.txt`, `carried.txt` |
| `complete_lines(1)` returns 0 | `mixed.txt`, `scores_ok.txt`, `growth.txt`, `tail.txt`, `carried.txt` |
| Drop `folded.is_ok()` from `reading` | the fifth-line step on `long_not_utf8.txt` only (`InvalidUtf8` instead of the step's `Err`) |

Two results are wider than the brief predicted, and both follow from the code.
Without `carried`, any file whose last line has no LF fails, because that
line arrives as the unfinished one and only the end-of-file call returns it
(`mixed.txt`, `scores_ok.txt`). Stepping every element fails every case with
a complete line except the ones that stop before the end of the file.

## Finding: counting open descriptors is not portable in a pinned example

A first version of the example listed `/dev/fd` with `fs.list_directory`
before and after the folds and printed the difference (0; 1,300 with the close
deleted, whatever the limit). It passed locally and failed on all four CI jobs
by 30 allocations (6,156,110 against 6,156,080): the listing's size, and with
it the allocations of `list_directory`, depends on how many descriptors the
driver leaves open in the child, which differs between machines. The example
pins its allocation count exactly, so the probe was removed. The early-stop and
failed-read folds remain, and detect a missing close only under a low
descriptor limit.
