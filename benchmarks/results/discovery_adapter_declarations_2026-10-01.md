# Discovery Adapter, Declaration Half: First Cost Measurement — 2026-10-01

First measurement for criterion 5 of
[`docs/DISCOVERY_ACCEPTANCE_ROADMAP.md`](../../docs/DISCOVERY_ACCEPTANCE_ROADMAP.md):
the new discovery stage plus the legacy adapter must cost fewer instructions
than the existing discovery on the self-compile. This is the declaration half
only: every function body and global value is the adapter's placeholder, so the
body half adds work this table does not include.

## Provenance

- Source: branch `compiler-new/adapter-declarations` rebased onto `2842dcc14`
  (the embedded standard library and source packages), measured at the head
  named in the commit that records this file
- Host: Apple Silicon, Darwin 25.6.0; `/usr/bin/time -l` counters
- C compiler: Apple clang 21.0.0 (`clang-2100.3.34.2`), `-O2 -fwrapv`
- Workload: `blorp/src/main.brp` with `standard_library/src` and `pkg`, the
  prelude and tuple implicit modules; 396 modules in every mode
- Tool: `blorp/test/compiler/tools/discovery_adapter_cost.brp`, one binary built
  without and one with `-DBLORP_MEMORY_DIAGNOSTICS=1` (allocations only)
- No gate or other build ran during the measurement; three rounds, the three
  modes back to back in each round

## Commands

```bash
bin/blorp compile --no-format -o /tmp/cost.c \
  blorp/test/compiler/tools/discovery_adapter_cost.brp
INCS=(); for d in $(find $PWD/blorp/src -name '*_ffi.h' | xargs -n1 dirname | sort -u); do INCS+=("-I$d"); done
clang -x c /tmp/cost.c -O2 -fwrapv -w "${INCS[@]}" -lm -lpthread -o /tmp/cost
clang -x c /tmp/cost.c -O2 -fwrapv -w -DBLORP_MEMORY_DIAGNOSTICS=1 \
  "${INCS[@]}" -lm -lpthread -o /tmp/cost_diag

for mode in old tables graph; do
  BLORP_MEMORY_STATS=1 /tmp/cost_diag $mode compile blorp/src/main.brp   # allocations
  /usr/bin/time -l /tmp/cost $mode compile blorp/src/main.brp            # instructions, user time
done
```

- `old`: the existing discovery to a `FrontendGraph`, including the parse of the
  root the CLI does first
- `tables`: the discovery stage to frozen tables (the freeze invariant check
  included)
- `graph`: the discovery stage, then `legacy_frontend_graph`

## Results

Allocations are exact; instructions and user time are the median of three
rounds (instructions varied by less than 0.3% between rounds).

| | Existing discovery | Stage, tables only | Stage plus adapter |
| --- | ---: | ---: | ---: |
| Allocations | 8,467,083 | 530,956 | 3,019,217 |
| Retired instructions | 10.198 G | 4.053 G | 5.675 G |
| User time | 0.63 s | 0.27 s | 0.38 s |
| Peak RSS | 198 MB | 187 MB | 223 MB |

Per-round samples (user seconds, retired instructions):

| round | old | tables | graph |
| ---: | --- | --- | --- |
| 1 | 0.63 s, 10,198,645,364 | 0.27 s, 4,052,995,043 | 0.37 s, 5,671,356,822 |
| 2 | 0.63 s, 10,182,651,094 | 0.27 s, 4,051,154,823 | 0.38 s, 5,674,854,049 |
| 3 | 0.65 s, 10,204,294,949 | 0.28 s, 4,066,137,963 | 0.38 s, 5,686,507,963 |

## Reading

- The stage's margin over the existing discovery is 6.15 G instructions and
  0.36 s here. The declaration half spends 1.62 G instructions (26% of the
  margin), 0.11 s and 2.49 M allocations; stage plus adapter is 56% of the
  existing discovery's instructions and 60% of its user time. The host ran
  slower than in the first measurement (the existing discovery's user time
  was 0.50 s then); instructions are the comparable signal.
- The first measurement of this half, before the rebase and before missing rows
  became errors, was 1.06 G instructions and 1.48 M allocations for the adapter.
  The growth is the `Result` the adapter now returns from every row read (each
  one allocates and is matched) and the module-name derivation from the
  tables. It is not optimized; a row read that cannot fail for frozen tables
  is the obvious place to cut.
- The declaration half is under half the margin, so no stop was needed. The
  body half rebuilds expressions, statements and patterns from a node table
  that holds 894 k nodes for this input; the declaration half reads the type
  nodes of about 55 k definitions and parameters. The body half is likely
  larger than this half, and this measurement does not predict it: measure
  again with the body half, and budget the `Result` cost before it lands.
- The adapter's cost is in the indexes it derives (one counting-sort pass per
  side table), the rebuilt records and lists, the name table's by-spelling
  dictionary, and the existing finalization and surface passes over the
  rebuilt programs (cheap here because the bodies are placeholders).
- The stage's own numbers moved from the design document's (0.435 M
  allocations, 4.24 G instructions) because the stage now loads the implicit
  modules and the embedded provider, interns `#N` spellings with a pairing row,
  seeds 78 more names, records name spans and checks them at freeze.
