# Blorp emits aggregates in Verify's layout order (2026-11-10)

Verify's `verify_layout_graph` and Emit's `append_aggregate_definitions`
walked the by-value aggregate layout graph with the same depth-first search.
Verify now returns the walk's completion order, and `VerifiedProgram` carries
it. Emit renders the records and unions in that order and no longer walks the
graph. See [`AGGREGATE_ORDER_PLAN.md`](../../blorp/AGGREGATE_ORDER_PLAN.md).

## Output identity

The base and candidate compilers each compiled the base revision's
`blorp/src/main.brp` and every file under `blorp/test/e2e/fixtures/` that
defines `func main`, serially, with `--library-root blorp/standard_library`.
That was 651 inputs: 568 compile and 83 are rejected. For each input the
check compared the C, stdout, stderr and exit status. **No file differed.**

## Self-compile cost

Both compilers were generated from their sources by the candidate compiler
and linked with `clang -O2 -DBLORP_MEMORY_DIAGNOSTICS=1`. Each one compiled
the candidate's `blorp/src/main.brp` under `BLORP_LEAK_CHECK=strict`. The
three rounds alternated base and candidate.

| Metric | Ceiling | Base | Candidate |
| --- | --- | ---: | ---: |
| Allocations | no increase | 13,563,081 | 13,563,080 (−1) |
| Retired instructions, best of 3 | at most +0.3% | 13,140,850,081 | 13,138,339,797 (−0.02%) |
| Self C | identical | 25,184,644 bytes | identical in all three rounds |

These were the retired-instruction samples, one per round:

| Round | Base | Candidate |
| ---: | ---: | ---: |
| 1 | 13,173,061,774 | 13,159,036,494 |
| 2 | 13,151,358,458 | 13,139,423,907 |
| 3 | 13,140,850,081 | 13,138,339,797 |

The allocation count fell by one rather than by the few the plan expected.
Emit's per-program visit vectors and worklist are gone, but the order list
and the seal record replace them. Both are a handful of allocations against
13.5 million.

## Lines

These counts come from `git diff --numstat` against the plan commit.

| Area | Added | Deleted | Net | Ceiling |
| --- | ---: | ---: | ---: | --- |
| Production (`blorp/src`) | 81 | 308 | −227 | net at most −150: met |
| Tests (`blorp/test`) | 461 | 0 | +461 | added at most +450: **over by 11** |

The tests were not shortened to fit, as the plan requires. The coordinator
decides whether to correct the test ceiling.

## Provenance

- **Source:**
  - The base is `999c28fb6`, a detached worktree.
  - The candidate is that commit plus this change.
- **Binaries:**
  - Each side's `blorp/build/blorp` came from `make -C blorp compiler`.
  - The cost binaries were generated as described above.
- **Toolchain and host:** Apple clang 21.0.0 (clang-2100.3.34.2), Apple M4,
  macOS 26.7.1. Other sessions shared the machine, and every run waited until
  no gate was running.
- **Raw samples:** the ignored `blorp/build/aggregate-order/`, in two places:
  - `identity/`: per-input C, stdout, stderr and status, for each side;
  - `cost/`: the `/usr/bin/time -l` output and self C for each round.
