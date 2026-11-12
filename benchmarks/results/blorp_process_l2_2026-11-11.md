# Blorp process API, landing L2 (2026-11-11)

L2 of `blorp/PROCESS_DECISIONS.md` moves every `run_to_files` caller to
`capture` and `output`, makes `Command.program` a `Path`, and deletes
`process.run_to_files` with its label, signature row and C fragment. The
compiler does not import `io/process`, so its own C changes only because its
source lost the builtin.

## Provenance

| | Base | Candidate |
| --- | --- | --- |
| Source | origin/main `7bd2b7047` | `blorp/process-l2` at `be59d562d`, on `7bd2b7047` |
| Stage-A `blorp.c` (sha256), equal to its self C | `33084ec4d0f490c177f6713f868b3d2aed18c7fc6595ba5053071ec2c3c07c80` | `1afea8d66b7670a5fe022ec4c49505eceaa29f620f29befacac3803a997f778d` |
| Self C bytes | 25,742,986 | 25,695,836 |

Host: Apple M4, macOS 26.7.1, Apple clang 21.0.0, load average about 3 from
other sessions. Each side's `blorp.c` (built by the pinned seed) is linked
`-O2` for instructions and `-O2 -DBLORP_MEMORY_DIAGNOSTICS=1` with
`BLORP_LEAK_CHECK=strict` for allocations, and compiles its own
`blorp/src/main.brp`. Five rounds interleave base and candidate. Raw samples
are in the task's scratch `cost/` directory (`samples.tsv`, sha256
`21240238004a0c66db32cc8be425a7cf2f97bc69bd11cb74557f12f519cd3119`).

The **fixed input**, the base source compiled by both compilers, gives
byte-identical C, so no program's C changes.

The branch was measured at `be59d562d` and later rebased, without
re-measuring, onto `873869eb0`. Upstream brought in shared lexer constants
(`286e8a01b`), checking without `main` (`873869eb0`) and plan and benchmark
edits; review fixes after the measurement changed tests and documents only,
not the compiler or the library.

## Self-compile cost

| Metric | Ceiling | Base | Candidate | Change |
| --- | --- | --- | --- | --- |
| Allocations, `-O2` strict (every round) | ±0.1% | 13,824,094 | 13,819,953 | −4,141 (−0.030%) |
| Retired instructions, `-O2`, median of 5 | ±0.1% | 12,074,840,382 | 12,065,986,127 | −8,854,255 (−0.073%) |

Spread (maximum over minimum) across the five rounds: 0.15% base, 0.22%
candidate, so the instruction change is within noise.

## Lines

`git diff --numstat` against `873869eb0`:

| Part | Ceiling | Net |
| --- | --- | --- |
| Compiler production, `blorp/src` | at most −250 | −349 (`runtime/process.brp` −320, `builtins.brp` −13, `system.brp` −13, `syntax.brp` −3) |
| Standard library code, `io/process.brp` | at most +5 | −11 |
| Tests | at most +60 | −777 |

## Commands

```bash
# cost.sh 5: for base and candidate, make -C blorp generate-compiler, then
#   clang -O2 [-DBLORP_MEMORY_DIAGNOSTICS=1] blorp/build/blorp.c -lm -lpthread
# and five interleaved rounds in each side's root of
#   /usr/bin/time -l COMPILER compile blorp/src/main.brp --library-root blorp/standard_library -o self.c
#   BLORP_LEAK_CHECK=strict DIAGNOSTIC_COMPILER compile ... (allocations)
# then both compilers on the base source, compared with cmp.
```
