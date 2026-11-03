# Blorp 2 fs library, read side (phase 2a, landing i-a) (2026-11-03)

`fs.read_text` and `fs.entry_kind` join the `SystemCall` contract
(`d49f3eec2`) as two new `SystemOperation` rows. Both return Int codes, which
`standard_library/fs.brp` decodes into `IOErrorKind`. No `SystemPayload` or
`RuntimeResult` shape was added. This is landing (i-a) of four; `write_text`
(i-b), the seed rotation (ii) and the migration (iii) are not here, and
`src/` itself uses no `fs` operation.

## Provenance

| | Base | Candidate |
| --- | --- | --- |
| Commit | `73102b901` (`git archive`, no `.git`) | `b3270726f`, the `blorp2/fs-read` commit before this report was added |
| B (sha256) | `1be801b46c660782fb9dd06a230d4e55a2306a829b4a482b796e619733e06abb` | `d4b6236ed42916e4bca4de4be42ae220991956435a383d342acd171b92886ec4` |
| B's C (sha256) | `200c49467e8c816abecc471f3319c069051c76cd81f0dfbc41fccbec9992ae5a` | `87244cb6f65e75642b03936985689209befc5fd1057cb27639b2a9f004989b5c` |
| Self C (sha256) | `f4752e77ee807e8d16801f695ead1b03a0af1c189a0db41e31f7a85f3aa35250` | `d085d6ffc3ef1a2cb2a2fa2a5e09210f376e07d6375e797eb5637b6b2f730a56` |
| Self C bytes | 25,237,829 | 25,271,419 |
| `-O2` compiler (sha256) | `22d6599fef586d3f7dbd0885b1fbfca819c2d18c60ea72570887456cf7eb95bd` | `258bab51cc4bf9850d416f932c1e32f6b44521f3f30f6289ce964b81c83310e0` |

Both build from the pinned seed (`blorp2-seed-0d11bd3de938`). The fixpoint's
stage A, B and C all emit the candidate self C above. After the measurement,
`fs.brp` lost one unused import name (`Void`); that file is not part of
`src/`, and the emitted C of the fs example is byte-identical before and after.

Machine: Apple M4, macOS 26.7.1, Apple clang 21.0.0, load average 9 to 16 from
other sessions. Every run was serial, base then candidate in each of five
rounds. The attribution script reports the parent checkout's HEAD for the base
tree, which has no `.git`; that `commit` line in `build/fs_read/base.log` is
wrong, and the table above is right. Raw samples are under the ignored
`build/fs_read/` of the candidate worktree (`W`).

## Ceilings

| Metric | Ceiling | Measured |
| --- | --- | --- |
| Compiler logic, `src/` without `src/runtime/`, net | at most 10 per operation, +40 for 2a | +9 for two operations (`emit` +3, `builtins` +2, `syntax` +4) |
| `src/runtime/`, net | reported | +159: C text 125 lines in `fs.brp`, 27 comment and name lines there, +7 table logic in `system.brp` |
| Fixed-input instructions, `-O2` | +0.2% for 2a | 14,835,273,791 to 14,840,179,233 (+0.033%) |
| Self-compile allocations | +1.0% for 2a | 15,047,035 to 15,056,750 (+0.065%) |
| Self-compile instructions, `-O2` | +1.0% for 2a | 14,822,929,719 to 14,833,758,723 (+0.073%) |
| Self-compile instructions, `-O0` | +1.0% for 2a | 43,144,605,512 to 43,185,097,487 (+0.094%) |
| Self C | the new rows' own emission only | met, below |

Instructions are the minimum of five interleaved runs. Run-to-run spread under
this load was about 0.4% at `-O2` and 0.2% at `-O0`, larger than any of the
differences above, so these are upper bounds on small effects rather than
exact costs. The new rows add compiler source, which is where the self-compile
cost comes from (0.7 to 0.95% of instructions per 1% of source, per the phase 0
spike); the self C grew by 0.13%.

Tests and library: +1,178 -83 test lines (74 of the removed lines are the
`arguments = []` added to each existing `Example`) and `standard_library/fs.brp`
at 175 lines. The C fixture is `test/runtime/fixtures/fs_test.c`, 448 lines.

### Commands

```bash
# Base tree, then the attribution script for each tree.
mkdir -p build/fs_read/base_tree
git archive -o build/fs_read/base.tar 73102b901 blorp_2 scripts Makefile AGENTS.md docs benchmarks/blorp_2
tar -x -f build/fs_read/base.tar -C build/fs_read/base_tree
cd build/fs_read/base_tree && blorp_2/scripts/attribution/run --output ../base --stage build --stage allocations --stage timing
cd W && blorp_2/scripts/attribution/run --output build/fs_read/candidate --stage build --stage allocations --stage timing

# -O0 compilers: the self C linked at -O0, no memory diagnostics.
clang -w -O0 -DBLORP_MEMORY_DIAGNOSTICS=0 build/fs_read/base/self.c -o build/fs_read/o0/base -lm -lpthread
clang -w -O0 -DBLORP_MEMORY_DIAGNOSTICS=0 build/fs_read/candidate/self.c -o build/fs_read/o0/candidate -lm -lpthread

# build/fs_read/measure.sh NAME BASE_COMPILER BASE_LIB BASE_MAIN CANDIDATE_COMPILER CANDIDATE_LIB CANDIDATE_MAIN
# Each run is `/usr/bin/time -l <compiler> --library-root <library> <main.brp> <out.c>`;
# the figure is its "instructions retired" line.
```

| Measurement | Base | Candidate | Output check |
| --- | --- | --- | --- |
| `-O2` self-compile (`measure_o2`) | `base/timing/atomic` on the base `src` | `candidate/timing/atomic` on `W/blorp_2/src` | each `cmp`ed to its own `self.c`: identical |
| `-O0` self-compile (`measure_o0`) | `o0/base`, same input | `o0/candidate`, same input | not compared |
| Fixed input (`measure_fixed`) | `base/timing/atomic` on the base `src` and library | `candidate/timing/atomic` on the same two paths | see below |

## Self C

The candidate `-O2` compiler compiled the base `src` and library. Its output
(`measure_fixed/candidate.c`) is byte-identical to the base self C: the same
sha256, `f4752e77...a35250`, so the new rows add no emission to a program that
does not use them. The candidate's own self C differs from the base's by the
edited `syntax.brp`, `builtins.brp`, `system.brp` and `emit.brp` and the new
`runtime/fs.brp` fragments the compiler now carries as String constants.

## Gates

- `make -C blorp_2 test`: exit 0, 974 PASS lines, 0 FAIL. The new suites and
  examples in its output:
  - `fs operation labels` (2), `fs builtin contracts` (7), `fs builtin C
    emission` (4);
  - `fs runtime` (9 C cases);
  - the e2e fs example and three direct-native programs (4).
- `scripts/blorp2-fixpoint --prove`: exit 0. A, B and C emit one self C, and
  the fixture parity pass covers 667 fixtures (663 before; the four new
  fixture programs).
- The runtime C fixture (`fs_test.c`) builds and passes under
  `-std=c11 -Wall -Wextra -Werror -pedantic` with ASan and UBSan, strict leak
  check, 0 leaked, in the suite; and by hand with Apple clang `-O2` without
  sanitizers, and with GCC 13.3 under ASan and UBSan on Ubuntu 24.04 (arm64, uid
  1001, glibc) in the repository's Docker image. The fs example and the
  direct-native programs also build under GCC there, and the example's output
  on Linux is identical to the pinned output on macOS.
- `git diff --check`: clean.

## Oracles

Each run broke one thing, rebuilt the test compiler (`make -C blorp_2
test-compiler`) and ran `make -C blorp_2 test-e2e` (and the emit suite alone for
the helper count). Failing tests, and only these:

| Broken | Failed |
| --- | --- |
| Swap two codes in C (ENOENT and EACCES) | `fs runtime`: errno codes, failures; the fs example |
| Swap two constants in `fs.brp` (NOT_FOUND and PERMISSION_DENIED) | the fs example only |
| Remove the NUL check (`blorp_fs_has_nul` returns 0) | `fs runtime`: NUL; the fs example |
| Restore measure-then-read (read `st_size` bytes) | `fs runtime`: interrupted open, appending writer (the two FIFO cases). Regular-file sizes still pass, because `st_size` is exact for them |
| Emit `FS_HELPERS_RUNTIME` twice | emit suite: the two helper-count tests; the fs example and the natives fail to compile |
| Remove the `read` retry | `fs runtime`: appending writer only |
| Remove the `open` retry | `fs runtime`: interrupted open only |
| Close the descriptor twice | `fs runtime`: sizes, failures, interrupted open, appending writer |

Not run: omitting the close, which the descriptor-number checks in the same
cases cover by the same mechanism.

## Findings

- **A real fragment-join bug, found while reading the C and fixed here.** The
  aggregates fragment does not end with a newline, so a program that calls
  `fs.entry_kind` or `fs.read_text` and has Result unions but no String-error
  union got `...payload;};#include <errno.h>` on one line, which does not
  compile. The e2e fs example happened to avoid it. `FS_HELPERS_RUNTIME` now
  starts with a blank line, as `process_runtime` does, and three direct-native
  e2e programs (only read, only entry kind, both) compile and run under
  `-Werror`.
- **Emitted nesting.** `decode_error`'s 13 `else if` arms emit 16 nested
  blocks. Both compilers accept it at default limits.
- **The single close is observed by wrapping `close`**, as `process_child.c`
  wraps `execve`: the fixture defines `close` to a counting function before
  including the production fragments. D6 (write-side syscall wrappers for
  `write_text`) is not decided, and this landing uses the existing technique on
  one call.
- **`PROCESS_POSIX_PRELUDE`'s `#error` text still names `process.run_to_files`.**
  Reworded, it would add one more hunk to the self C. Left for a later landing.
- **`fs_test.c` uses `assert`**, with an `#error` if `NDEBUG` is set, because
  some cases keep their work inside `assert`.
- **D16 limit.** A length above `blorp_string_maximum_capacity()` returns
  `FileTooLarge`, but memory runs out first on every machine, so the growth
  arithmetic is tested in isolation (`blorp_fs_grown_capacity`), not by a huge
  read. A file of exactly INT64_MAX bytes is also refused.
