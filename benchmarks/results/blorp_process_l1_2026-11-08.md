# Blorp process API, landing L1 (2026-11-08)

L1 of `blorp/PROCESS_DECISIONS.md` adds `Command`, `capture`, `output` and
`find_program` beside `run_to_files`. Three natives join the system tables:
`process.capture`, `process.find_program` and `process.fault`, which aborts
on a reply the library cannot decode (P5). A `process_helpers` flag on
`SystemRuntime` emits the helpers they share with `run_to_files` once. The
compiler does not import `process`.

## Provenance

| | Base | Candidate |
| --- | --- | --- |
| Source | origin/main `390945503`, `git archive` of `blorp` and `scripts` | the `blorp/process-l1` worktree, the commit this report is in |
| Stage-A `blorp.c` (sha256) | `4c8e5e38970914c3512fa1815faf0ad2890ca0818501198e13f3074c81f8f116` | `22310f77068abd7fc37312d26ee951160ea416e61ce26aa4b7fbe0a5c4f35369` |
| Self C (sha256) | `f1fe61336527992d94cf340aa284ae235dd31c4e9a46d6d102e9a4d677fc36eb` | `69d7e3e80b0f8ab5f74d3ce77efabf8bc05219cdb610f02dbe08c07c944392ef` |
| Self C bytes | 25,067,222 | 25,231,799 |

Host: Apple M4, macOS 26.7.1, Apple clang 21.0.0. Every run was serial, on a
machine shared with other sessions. The candidate was measured before seven
comment lines were cut from `process.brp`, which changes only embedded
library text. Raw samples were in the task's scratch
`measure/` directory and were not kept.

The self C differs because the compiler's own source grew: the new natives'
table rows, the C fragments held as raw Strings, and the library text the
compiler embeds. The **fixed input** (the base source compiled by both
compilers) gives **byte-identical C** (25,067,222 bytes), so programs that do
not call the new natives get exactly the C they got before.

## Ceilings

The brief set them before implementation; Keith raised three on 2026-11-09
after the first measurement. The plan's estimates (about 300 C lines, about 230
library lines, about 10 table lines) predated the formatter's one-entry-per-line
layout and the full error matrix, and the same-input C is identical, so the
rise is the cost of compiling a larger source, not a slower compiler.

| Metric | First ceiling | Raised | Measured |
| --- | --- | --- | --- |
| Native tables (`syntax`, `builtins`, `system`, `emit`) | +30 | +65, then +75 with `process.fault` | +84 −5 (+79 net): 4 over, accepted by Keith on 2026-11-09 |
| Runtime C core, `src/compile/runtime/process.brp` | +400 | +650 | +688 −56 (+632 net) |
| `standard_library/process.brp` | 300 lines | 380 | 380 |
| Fixed-input C | byte-identical | | identical |
| Self-compile allocations, `-O2` strict | +0.2% | | 13,589,993 to 13,607,114 (+17,121, +0.126%), 0 leaked |
| Fixed-input allocations | reported | | 13,589,993 to 13,589,996 (+3) |
| Self-compile instructions, `-O2` | +0.2% | +0.3% | 11 interleaved rounds, median 11,829,166,165 to 11,853,818,091 (+0.208%), minimum +0.253% |
| Fixed-input instructions, `-O2` | reported | | median 11,822,713,416 to 11,827,140,708 (+0.037%), minimum +0.071% |

Spread (maximum over minimum) across 11 rounds: self 0.25% base, 0.15%
candidate; fixed 0.14% and 0.26%.

`process.fault` costs 16 table lines: its label, its row in `system_runtime`,
and the `./process` import in `system.brp`, which the formatter now breaks over
five lines. That import accounts for the 4 lines over +75.

The new e2e examples' compile ceilings are their measured cost plus 15%:

| Example | Allocations measured, ceiling | Instructions measured, ceiling |
| --- | --- | --- |
| `process_native_capture` | 100,692, 115,796 | 512,432,600, 589,297,490 |
| `process_native_find_program` | 96,956, 111,499 | 501,730,643, 576,990,239 |
| `process_native_fault` | 99,590, 114,529 | 520,524,749, 598,603,461 |
| `process_native_together` | 101,536, 116,766 | 514,171,620, 591,297,363 |

### Commands

```bash
git archive origin/main blorp scripts | tar -x -C base
# measure/build_side.sh NAME ROOT: make -C ROOT/blorp compiler, the self C of
# ROOT/blorp/src, linked -O2 and -O2 -DBLORP_MEMORY_DIAGNOSTICS=1.
# measure/measure.sh 11: interleaved rounds of
#   /usr/bin/time -l COMPILER compile --library-root blorp/standard_library blorp/src/main.brp -o out.c
# in each side's root (self) and in base (fixed); "instructions retired".
# Allocations: BLORP_LEAK_CHECK=strict with the -O2 diagnostics build.
```
