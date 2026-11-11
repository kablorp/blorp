# Blorp splits `main.brp` and `cli.brp` by command (2026-11-10)

Step 2 of [`SOURCE_LAYOUT_PLAN.md`](../../blorp/SOURCE_LAYOUT_PLAN.md) moves
each command's options, help text and shell into its own directory, the shared
reporting into `common/cli/`, and the pipeline into
`common/codegen/generate_c.brp`. `SourceFile` and `SourceInputs` move to
`common/syntax/source.brp`. The compiler's behaviour is unchanged.

## Output identity

The base (`e972c56ea`, a detached worktree) and the candidate compilers each
compiled the base revision's `blorp/src/main.brp` and every file under
`blorp/test/e2e/fixtures/` that defines `func main`, serially, with
`--library-root blorp/standard_library`. That was 655 inputs: 570 compile and
85 are rejected. For each input the check compared the C, stdout, stderr and
exit status. **No file differed.**

The measurement script's first comparison flagged the 85 rejected inputs
because neither side writes a `.c` for them, and `cmp` fails on two missing
files. A second pass that compares a file only when either side has it found
0 differences.

## Self-compile cost

Both compilers were generated from their sources by the candidate compiler
and linked with `clang -O2 -DBLORP_MEMORY_DIAGNOSTICS=1`. Each one compiled
the candidate's `blorp/src/main.brp` under `BLORP_LEAK_CHECK=strict`. The
three rounds alternated base and candidate.

| Metric | Ceiling | Base | Candidate |
| --- | --- | ---: | ---: |
| Allocations | within ±0.01% | 13,652,994 | 13,652,994 (0) |
| Retired instructions, best of 3 | within ±0.2% | 13,248,848,574 | 13,246,071,044 (−0.02%) |
| Self C | n/a | 25,312,165 bytes | identical in all three rounds |

Retired-instruction samples, one per round:

| Round | Base | Candidate |
| ---: | ---: | ---: |
| 1 | 13,293,095,365 | 13,272,055,958 |
| 2 | 13,255,960,171 | 13,256,863,705 |
| 3 | 13,248,848,574 | 13,246,071,044 |

Both compilers produce the same C for the candidate's source, in all rounds.

## Lines

These counts come from `git diff --numstat` against `e972c56ea`.

| Area | Added | Deleted | Net | Ceiling |
| --- | ---: | ---: | ---: | --- |
| Production (`blorp/src`) | 840 | 778 | +62 | net at most +62 (was +40; see below): met |
| Tests (`blorp/test`) | 225 | 102 | +123 | none |

**Budget correction.** On 2026-11-10 the coordinator raised the production
ceiling from +40 to +62 net lines, under Keith's standing delegation for
routine corrections. The plan set +40 "for new module headers and imports",
and the whole overage is exactly that: six module docstrings and the import
blocks of six files where there were two. No body grew. Nothing was trimmed
to fit. The lines come from:

| Cost | Lines |
| --- | ---: |
| Six module docstrings (`main`, `usage`, `report`, `generate_c`, `compile_command`, `format_command`), 4 lines each, minus `cli.brp`'s 4 | +20 |
| Import blocks: 99 lines in the six files against 63 in `main.brp` and `cli.brp` | +36 |
| Blank separators between header, imports and body, and the two `.map(...)` wrappers, net of the removed `Compile(...)` and `Format(...)` wrapping | +6 |

## Provenance

- **Source:**
  - The base is `e972c56ea`, a detached worktree.
  - The candidate is that commit plus this change.
- **Binaries:** each side's `blorp/build/blorp` came from
  `make -C blorp compiler`.
- **Toolchain and host:** Apple clang, Apple Silicon, macOS. Other sessions
  shared the machine, and every run waited until no gate was running.
- **Raw samples:** the ignored `blorp/build/source-layout-step2/`:
  - `identity/{base,cand}/`: per-input C, stdout, stderr and status;
  - `cost/`: the `/usr/bin/time -l` output and self C for each round.
