# Discovery Adapter, Body Half: Cost — 2026-10-01

Criterion 5 of
[`docs/DISCOVERY_ACCEPTANCE_ROADMAP.md`](../../docs/DISCOVERY_ACCEPTANCE_ROADMAP.md)
with the adapter complete: the new discovery stage plus the legacy adapter
(declarations and bodies) and the existing finalization must cost fewer
instructions than the existing discovery on the self-compile. It does.

## Provenance

- Source: branch `compiler-new/adapter-bodies`, based on `79f5fa4b7`, measured
  at the head named in the commit that records this file
- Host: Apple Silicon, Darwin 25.6.0; `/usr/bin/time -l` counters
- C compiler: Apple clang 21.0.0 (`clang-2100.3.34.2`), `-O2 -fwrapv`
- Workload: `blorp/src/main.brp` with `standard_library/src` and `pkg`, the
  prelude and tuple implicit modules; 396 modules in every mode
- Tool: `blorp/test/compiler/tools/discovery_adapter_cost.brp`, one binary built
  without and one with `-DBLORP_MEMORY_DIAGNOSTICS=1` (allocations only)
- No gate or other build ran during the measurement; three rounds, the four
  modes back to back in each round

## Commands

```bash
bin/blorp compile --no-format -o /tmp/cost.c \
  blorp/test/compiler/tools/discovery_adapter_cost.brp
INCS=(); for d in $(find $PWD/blorp/src -name '*_ffi.h' | xargs -n1 dirname | sort -u); do INCS+=("-I$d"); done
clang -x c /tmp/cost.c -O2 -fwrapv -w "${INCS[@]}" -lm -lpthread -o /tmp/cost
clang -x c /tmp/cost.c -O2 -fwrapv -w -DBLORP_MEMORY_DIAGNOSTICS=1 \
  "${INCS[@]}" -lm -lpthread -o /tmp/cost_diag

for mode in old tables programs graph; do
  BLORP_MEMORY_STATS=1 /tmp/cost_diag $mode compile blorp/src/main.brp   # allocations
  /usr/bin/time -l /tmp/cost $mode compile blorp/src/main.brp            # instructions, user time
done
```

- `old`: the existing discovery to a `FrontendGraph`, including the parse of the
  root the CLI does first
- `tables`: the discovery stage to frozen tables (the freeze invariant check
  included)
- `programs`: the stage, then the adapter's parsed program of every module (the
  adapter alone, before typecheck's finalization of each module); new in this
  measurement
- `graph`: the stage, then `legacy_frontend_graph`

## Results

Allocations are exact; instructions, user time and peak RSS are the median of
three rounds (instructions varied by less than 0.3% between rounds).

| | Existing discovery | Stage, tables | Stage plus programs | Stage plus graph |
| --- | ---: | ---: | ---: | ---: |
| Allocations | 8,474,032 | 530,613 | 5,149,076 | 7,132,981 |
| Retired instructions | 10.134 G | 4.055 G | 7.242 G | 8.743 G |
| User time | 0.51 s | 0.22 s | 0.39 s | 0.48 s |
| Peak RSS | 198 MB | 189 MB | 206 MB | 373 MB |

Per-round samples (user seconds, retired instructions):

| round | old | tables | programs | graph |
| ---: | --- | --- | --- | --- |
| 1 | 0.51 s, 10,149,421,490 | 0.23 s, 4,055,184,850 | 0.38 s, 7,244,840,698 | 0.48 s, 8,738,201,712 |
| 2 | 0.51 s, 10,132,592,065 | 0.22 s, 4,054,594,520 | 0.39 s, 7,240,520,660 | 0.48 s, 8,751,881,814 |
| 3 | 0.51 s, 10,134,220,112 | 0.22 s, 4,054,494,762 | 0.40 s, 7,242,419,549 | 0.48 s, 8,742,769,091 |

## Reading

- The stage's margin over the existing discovery is 6.08 G instructions. The
  whole adapter costs 4.69 G of it (77%): 3.19 G for the programs (the
  declaration half was 1.62 G in the first measurement, so the bodies are about
  1.6 G for 895 k nodes, under 2,000 instructions a node), and 1.50 G for
  typecheck's finalization and the module surfaces over bodies that are now
  real. Stage plus adapter is 14% under the existing discovery in instructions,
  16% in allocations and 6% in user time.
- The margin is narrow in time (0.48 s against 0.51 s) and in memory: the graph
  mode holds every module's rebuilt program at once, as the existing graph
  does, and its peak RSS is 1.9 times the existing discovery's (373 MB against
  198 MB). The adapter is temporary, deleted as typecheck reads the tables.
- Cost found and removed while building the body half, measured on the same
  workload:
  - The freeze check over the node name span rows, once they number 131 k
    instead of a few thousand, cost 150 k allocations and 0.13 G instructions:
    a `get` of a row struct allocates an `Option` per row and mapping every row
    to its owner through a closure allocates per element. Reading the rows by
    iteration and a total `get_or` brought the stage's tables back to about 0.53 M
    allocations and 4.05 G instructions, the numbers before the body half. The
    required name span rows (every named body node records its row) and the
    frame-stack hole scan cost 0.016 G of those.
  - Three changes to the pass saved 0.14 G instructions together: reading each
    node's name span by merging with the sorted name span rows as the walk
    reaches the node (instead of a binary search per name), computing a node's
    location once, and reading a child's value without a `Result`. Reading a
    node's row without an `Option`, and the name span cursor as two integers,
    saved another 0.08 G.
- Tried and not kept: handling identifier nodes outside the generic node
  builder (to skip the `Result` and the wrapper per node) saved 0.05 G, under 1%
  of the programs, for a second path to keep in step.
- Not optimized further: the adapter allocates 4.6 M times (about five a node,
  declarations included: the rebuilt value, its identifier, the `BuiltNode` and
  the `Result`), and the rest is spread over the finalization passes and the
  module surfaces; none is a hot spot, and the acceptance bar is met.
