# Blorp Int literal patterns (2026-11-06)

Two commits on `blorp/int-literal-patterns`, base `5b48adb9e`:

1. **Generalize String patterns to literal patterns.** `PatternString`,
   `BytesPattern`, `StringHead`, `StringDomain`, `OtherStringWitness` and each
   phase's `TestStringBytes` become one `LiteralPattern` (`ExactBytes` only)
   carried by `PatternLiteral`, `ExactPattern`, `LiteralHead`, `OpenDomain`,
   `OtherValueWitness` and `TestLiteral`. No behaviour changes.
2. **Add Int literal patterns.** `ExactInt(Int)` joins `LiteralPattern`. The
   parser reads an Int literal, or `-` and one, with the expression decoder,
   and rejects a Float literal. Check accepts an Int scrutinee, gives an Int
   column the open domain and checks each literal against its place. Verify
   checks `ExactInt` against an Int place, and emit compares with `==`.

## Provenance

| | Base | Commit 1 | Commit 2 |
| --- | --- | --- | --- |
| Source | `git archive 5b48adb9e` | `git archive` of commit 1 | `git archive` of commit 2 |
| Stage-A `compiler.c` (sha256) | `d33c67b8e66f…` | `73d808ea2377…` | `57fb0d42515a…` |
| Self C (sha256) | `7615f8613db8…` | `9aae41df24b3…` | `ed52459a7d59…` |
| Self C bytes | 22,867,743 | 22,871,343 | 22,899,766 |

Each side builds its stage-A compiler from the pinned seed
(`make -C blorp compiler`) and has it compile its own `blorp/src/main.brp`.
That self C is linked with `clang -std=c11 -O2`, once with
`-DBLORP_MEMORY_DIAGNOSTICS=0` and once with `=1`. Each side's `-O2` binary
reproduced its self C byte for byte.

Host: Apple M4, macOS 26.7.1, Apple clang 21.0.0. Every run was serial and
started only when no other session was running Blorp binaries. The 1-minute
load average was 2.26 before the instruction runs and 2.29 after. Raw samples
are under the ignored `build/intpat/measure/` of the branch's worktree.

## Ceilings

| Metric | Ceiling | Measured |
| --- | --- | --- |
| Commit 1, production lines (`blorp/src`) | net 0 ±15 | +72 -58, net +14 |
| Commit 1, self-compile allocations | +0.05% | 12,379,057 to 12,381,531 (+2,474, +0.020%) |
| Commit 1, self-compile instructions | +0.05% | median 10,738,125,147 to 10,738,248,377 (+0.001%); minimum -0.004% |
| Commit 2, production lines (`blorp/src`) | at most +110 | +64 -19, net +45 |
| Commit 2, self-compile allocations | +0.2% | 12,381,531 to 12,397,558 (+16,027, +0.129%); +0.149% over base |
| Commit 2, self-compile instructions | +0.2% | median 10,738,248,377 to 10,746,948,375 (+0.081%); minimum +0.065%; +0.082% over base |
| Commit 2, fixed-input instructions | +0.1% | median 10,735,593,283 to 10,730,683,554 (-0.046%); minimum -0.031% |

Allocations are deterministic, so one strict run per side
(`BLORP_LEAK_CHECK=strict`, diagnostic `-O2` build) gives each count, and every
run released everything. Instructions are the "instructions retired" lines of
`/usr/bin/time -l`, from 21 rounds with the side order reversed every round.
The spread (maximum over minimum) is 0.16% to 0.32% for self-compiles and
0.11% to 0.20% for the fixed input. Commit 1's effects are smaller than the
spread. Commit 2's self-compile rise is larger than its spread on both median
and minimum, so it is a real effect, well inside the ceiling.

The fixed input is the base tree's `blorp/src/main.brp`. All three sides make
**12,379,057** allocations compiling it and emit the same C
(sha256 `7615f8613db8…`, the base self C). So commit 2's +16,027 self-compile
allocations, and its instructions, come from the compiler's own larger source:
the new parser, check, verify and emit code, and the `Result` methods
`parse.brp` now imports. They are not extra work per compiled program.
The brief expected `ExactBytes` to add one box per String pattern. The input
has 68 String pattern arms (most of them the lexer's keyword table), and
commit 1 compiles it in the same 12,379,057 allocations as the base, so the
wrapper costs no allocation here. Commit 1's +2,474 self-compile allocations
also come from its own slightly larger source.

Tests grow by 88 changed lines (4 removed) in existing files, and 667 lines in
new files: six phase suites, `int_pattern_inputs.brp` and the e2e fixture.

## Output identity

Every `.brp` under the base tree's `blorp/test/e2e/fixtures` (685 files) was
compiled by each side's `-O2` compiler, from the base tree root with its
library. Each side's C, or its diagnostic text and status, was compared
(`build/intpat/identity.sh`):

| Pair | Identical | Differing | Accepted / rejected |
| --- | --- | --- | --- |
| base and commit 1 | 685 | 0 | 566 / 119 |
| commit 1 and commit 2 | 685 | 0 | 566 / 119 |

No existing program's check result, selection or generated C changes when Int
columns become open.

## The new fixture's compile ceiling

`fixtures/match/int_literals.brp` with the test compiler (`-O0`,
`-DBLORP_MEMORY_DIAGNOSTICS=1`): 113,610 and 113,609 allocations, and
584,030,337 and 572,545,752 instructions. The ceiling is the larger reading of
each plus 15%, rounded up: 130,652 allocations and 671,634,888 instructions.
The program exits 127 after 11 allocations, all released.

### Commands

```bash
build/intpat/build_side.sh NAME ROOT      # stage-A build, self C, -O2 and -O2 diagnostic links
build/intpat/measure.sh 21 build/intpat/base base=build/intpat/base c1=build/intpat/c1tree c2=build/intpat/c2tree
build/intpat/fixed_alloc.sh base c1 c2    # fixed-input strict allocations and output identity
build/intpat/identity.sh base c1          # and c1 c2
build/intpat/fixture_cost.sh match/int_literals
```
