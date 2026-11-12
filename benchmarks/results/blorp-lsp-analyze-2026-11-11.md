# `analyze` makes the entry function optional (2026-11-11)

Landing 1 of [`LSP_PLAN.md`](../../blorp/LSP_PLAN.md). `check` is split into
`analyze`, which checks every declaration and body and records the entry
function as `Option[Entrypoint[FunctionId]]`, and `check`, which runs
`analyze` and fails with the unchanged `MissingMain` when there is no entry.
A program with no `main` and a body error now reports the body error first.

## Output identity

The base (`286e8a01b`, a detached worktree) and the candidate compilers each
compiled the base's `blorp/src/main.brp`, `/tmp/no_main.brp` (the
reproduction) and every file under `blorp/test/e2e/fixtures/` that defines
`func main`, serially, with `--library-root blorp/standard_library`. That was
666 inputs: 573 compile and 93 are rejected. For each input the check compared
the C (only when either side wrote one), stdout, stderr and exit status.
**No input differed.** For `/tmp/no_main.brp` both print
`error: expected a main function` with the help `declare func main() -> Int: as
the entrypoint` at 3:1, exit status 1.

## Self-compile cost

Both compilers were generated from their sources by the candidate compiler and
linked with `clang -O2 -DBLORP_MEMORY_DIAGNOSTICS=1`. Each compiled the
candidate's `blorp/src/main.brp` under `BLORP_LEAK_CHECK=strict`. Three
rounds alternated base and candidate.

| Metric | Ceiling | Base | Candidate |
| --- | --- | ---: | ---: |
| Allocations | at most +0.05% | 13,828,995 | 13,828,996 (+1) |
| Retired instructions, best of 3 | at most +0.2% | 13,456,358,170 | 13,458,844,566 (+0.018%) |
| Peak memory footprint | at most +0.1% | 204,554,768 (best) | 204,522,000 (best) |
| Self C | n/a | 25,753,523 bytes | identical in all rounds |

Retired-instruction samples, one per round:

| Round | Base | Candidate |
| ---: | ---: | ---: |
| 1 | 13,479,743,516 | 13,466,075,907 |
| 2 | 13,456,358,170 | 13,458,844,566 |
| 3 | 13,464,109,418 | 13,465,615,819 |

Peak memory footprint per round (base, candidate): round 1 204,554,768 and
204,522,000; round 2 204,554,768 and 204,603,920; round 3 204,587,536 and
204,751,376. The spread between rounds (0.08%) is as large as the ceiling, so
this figure cannot prove +0.1%; the footprint is dominated by the C output
join, and the allocation count is the sharper signal.

## Lines

From `git diff --numstat` against `286e8a01b`, after review. The review gave
`entry_shape` a return type without an `Option` (one import line more); the
costs above were measured before that change, which alters no behaviour.

| Area | Added | Deleted | Net | Ceiling |
| --- | ---: | ---: | ---: | --- |
| Production (`blorp/src`) | 79 | 23 | +56 | at most +80: met |
| Tests (`blorp/test`) | 182 | 0 | +182 | none |

## Latency baseline

The server's latency ceilings need the one-shot time of `analyze` on
`blorp/src/main.brp`. The attribution tool's `profile` stage (`sample` of an
-O2 -g self-compile, 1 ms interval, 1,241 samples) gives the inclusive share of
`check.analyze_program` as **354 samples, 28.5%** (`check.check` is the same 354
samples, since it only wraps it). The profile stage's timed self-compile took
**2.18 s real, 1.69 s user** on a shared machine, so the one-shot `analyze`
baseline is about 28.5% x 2.18 s = **0.62 s** (0.48 s of user time). The tool
gives no separate figure for analysis alone beyond this inclusive share; the
share covers every phase `analyze` runs, body checking included, and nothing
before it (parsing runs earlier). It is one sampled run on a shared machine,
so treat it as an order of magnitude: re-measure on a quiet machine before
the server's latency ceilings are judged against it.
Command: `blorp/scripts/attribution/run --output blorp/build/lsp-analyze/attribution --stage build
--stage profile --stage report`.

## Provenance

- **Source:** base is `286e8a01b`; the candidate is that commit plus this change.
- **Binaries:** each side's `blorp/build/blorp` came from `make -C blorp compiler`.
- **Toolchain and host:** Apple clang, macOS. Every run waited until no other gate was running.
- **Raw samples:** the ignored `blorp/build/lsp-analyze/` of the candidate worktree:
  `identity/{base,cand}/`, `cost/` (time output and self C per round) and
  `attribution/` (`profile/sample.txt`, `profile/time.txt`, `tables/profile.md`).
