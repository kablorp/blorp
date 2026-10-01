# Discovery: Rows Written Once, At Close — Cost, 2026-10-01

Cost ledger for making the discovery builder's two-step protocols
unrepresentable: modules, imports, import items and foreign blocks are appended
once, at close, from an opening; a definition's close changes only its span; a
root or implicit request carries its outcome in one row.

## Provenance

- Base: origin/main `d707d53a4`; branch `compiler-new/append-at-close`, one
  squashed commit on it (the first measurement, on `9e270d350`, gave the same
  picture: allocations -13, instructions +0.4%)
- Host: Apple Silicon, Darwin 25.6.0; `/usr/bin/time -l` counters
- C compiler: Apple clang 21.0.0, `-O2 -fwrapv`
- Input: a copy of the base's `blorp/src`, `standard_library` and `pkg`
  (`blorp/src/main.brp` as the root, prelude and tuple implicit modules; 446
  modules); both binaries read the same copy
- Tool: `blorp/test/compiler/tools/discovery_adapter_cost.brp`, one binary per
  revision built from that revision's sources, without and with
  `-DBLORP_MEMORY_DIAGNOSTICS=1` (allocations only)
- No gate ran during the measurement; three rounds, base and branch back to back
  in each round

## Commands

```bash
bin/blorp run --release --no-format --memory-stats \
  blorp/test/compiler_new/tools/discovery_dump.brp -- counts blorp/src/main.brp
bin/blorp run --release --no-format \
  blorp/test/compiler_new/tools/discovery_dump.brp -- tables blorp/src/main.brp
# cost tool, as in discovery_adapter_bodies_2026-10-01.md
/usr/bin/time -l ./cost_$revision $mode compile blorp/src/main.brp
BLORP_MEMORY_STATS=1 ./cost_${revision}_diag $mode compile blorp/src/main.brp
```

## Results

| | Base | Branch | Change |
| --- | ---: | ---: | ---: |
| Discovery allocations, `discovery_dump counts` | 578,372 | 578,359 | -13 |
| Allocations, cost tool `tables` | 578,378 | 578,365 | -13 |
| Allocations, cost tool `graph` | 7,645,038 | 7,645,020 | -18 |
| Instructions, `tables` (median of 3) | 4.199 G | 4.219 G | +20.6 M (+0.49%) |
| Instructions, `graph` (median of 3) | 9.172 G | 9.193 G | +21.8 M (+0.24%) |
| User time | 0.22 / 0.49 s | 0.22 / 0.49 s | none |
| Peak RSS, `tables` / `graph` | 131.5 / 324.6 MB | 131.6 / 324.4 MB | none |

Per-round instructions (`tables`): base 4,310,573,888 (first run of the
session, an outlier) / 4,198,770,694 / 4,194,403,283; branch 4,251,528,149 /
4,217,399,171 / 4,219,413,627. `graph`: base 9,171,607,252 / 9,170,102,890 /
9,172,866,402; branch 9,195,271,673 / 9,193,410,342 / 9,192,777,227.

Output identity: the `tables` dump differs from the base only in the dump's
count line, which no longer names the four tables of root and implicit-request
targets and diagnostics that the rows' outcomes replaced (`root_targets`,
`root_diagnostics`, `implicit_targets`, `implicit_diagnostics`); every other
line, with the roots and rejection lines, is byte-identical. The `counts` line
differs by those four keys alone. `scripts/test compiler-new-parity` passes
3,332 of 3,332 (full-AST differential and module order).

## Reading

- Allocations do not rise. Every opening is a plain struct inside an opaque
  type, so it costs none, and the roots' rows are two records per compilation.
- Instructions rise by 0.2 to 0.5 percent. A tool rebuilt at the definitions
  change alone measured the same as the base; the rise belongs to opening and
  closing modules, imports, import items and foreign blocks: an opening carries
  each block's start and the close appends the finished row, where the base
  appended a placeholder and replaced it, and the debug guards are functions of
  numbers. The rise is the price of the types and stays small. Not chased.

## Shapes found while measuring

Two shapes cost allocations and were avoided, both from the builder threading
rules (`tables/builder.brp`):

- A `debug:` guard written as a statement in a close (a call to a helper of two
  numbers, or a constant call) made the close's record update copy: 2 to 3
  allocations per row, 29,500 on this input. The guard is now inside a function
  that returns the block's row count, used as an expression, and adds none.
- `foreign` blocks ended with `out.close_foreign_block(...)` as the tail of an
  `else` arm copied a table twice per block (rule 2). Assigning
  `out = out.close_foreign_block(...)` and ending with `out` is flat; the
  allocation budget suite caught it.
