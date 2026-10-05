# Discovery Redesign M1: What Minting Costs — 2026-10-02

This is a historical measurement of the original M1 branch, with `struct`
counts and names. The adopted syntax model uses ordinary records, so these
numbers do not validate its construction or return costs. The current model
must be measured separately before its M1 cost gate is complete.

Cost ledger for step M1 of [`docs/DISCOVERY_REDESIGN.md`](../../docs/DISCOVERY_REDESIGN.md):
the syntax types and `IdMint` (section 3.15). Nothing calls the mint yet, so
this measures minting in isolation, with the probe the parser's shape will
follow, and compares it with the M0 prototype's mint (`discovery_redesign_m0_2026-10-02.md`
on branch `compiler-new/m0-tree-prototype`). Per "make it work, make it right, make it
fast", costs that come from the compiler are recorded here, not designed
around.

## Result in four lines

- **The spec's mint costs 6 allocations and 3,214 instructions per node**
  minted through a parse state, against M0's 7 and 3,752 on the same
  compiler: the `struct` `SyntaxCounts` of section 3.4 removes one record copy
  per mint (-1 allocation, -14% instructions).
- **The single-layer shape M0 recommended costs 4 and 2,155**: 2 allocations
  and about 1,060 instructions per mint fewer than the spec's two layers.
  M1 does not adopt it, because it cannot keep section 3.15's boundary (see
  "Single layer" below); the gap is the `(IdMint, node)` tuple and the
  `MintState` copy, which increments 2 and 5 of
  `docs/VALUE_TUPLES_AND_STATE_HANDOFF.md` remove.
- **Minting definitions and imports is quadratic per module today.** Each
  append copies the index list: 4 times the calls costs 15 times the
  instructions, on the bare mint as well as through a parse state. Over the
  self-compile's modules that is an estimated 0.14 G instructions and about
  35 k allocations (0.035% of 405 G).
- **Ids themselves cost nothing**: an id is an `Int`; the cost is in
  threading the mint.

## Provenance

- Source: branch `compiler-new/m1-syntax-types`, based on
  `compiler-new/m2-lexed-module` at `4dc772551`; probe
  `blorp/test/compiler_new/tools/id_mint_cost.brp`
- Compiler: this worktree's `bin/blorp` built by `make`
  (`scripts/compiler-build-status`: `FRESH`), commit `4dc772551`
- M0 comparison: M0's own probe (`m0_tree_cost.brp probe ...`, branch
  `compiler-new/m0-tree-prototype` at `a8e87c30e`) compiled by the same
  `bin/blorp`, so both sides use one compiler
- Host: Apple Silicon, Darwin 25.6.0; Apple clang 21.0.0, `-O2 -fwrapv`;
  `/usr/bin/time -l` counters. Load average 15 to 25 (other agents running),
  so wall time is not evidence; instruction counts were stable (spread under
  0.5% except as noted)
- One process at a time; three rounds, every probe once per round in a fixed
  order; medians

## Commands

```bash
INCS=(); for d in $(find $PWD/blorp/src -name '*_ffi.h' | xargs -n1 dirname | sort -u); do INCS+=("-I$d"); done
bin/blorp compile --no-format -o m1.c blorp/test/compiler_new/tools/id_mint_cost.brp
clang -x c m1.c -O2 -fwrapv -w "${INCS[@]}" -lm -lpthread -o m1
clang -x c m1.c -O2 -fwrapv -w -DBLORP_MEMORY_DIAGNOSTICS=1 "${INCS[@]}" -lm -lpthread -o m1_diag

BLORP_MEMORY_STATS=1 ./m1_diag <mode> 200000        # allocations inside the loop
/usr/bin/time -l ./m1 <mode> 1000000                 # instructions; minus the same mode at 0 calls
/usr/bin/time -l ./m1 <field|mint-field|import> 10000   # and 40000: scaling of the index mints
```

Modes: `mint` (the `IdMint` threaded alone), `state` (through a parse state
that holds the mint, section 3.16), `single` (counts in the state's own
record), `name` (`NameUse` through the state), `field`, `mint-field` and
`import` (index-appending mints). Each mints a `BooleanLiteral(True)`
expression (or the named node) per call and keeps it in a list, as M0's
probes do; node and kind are 2 of the allocations.

## Per mint

Instructions per call are `(I(1,000,000) - I(0)) / 1,000,000` for each mode,
then minus the `empty` loop (32 per call: the loop and the list).

| Shape | Allocations | Instructions | M0 probe on the same compiler |
| --- | ---: | ---: | --- |
| Expression through a parse state (spec, two layers) | **6** | **3,214** | `literal`: 7, 3,752 |
| Expression on the bare mint | 4 | 2,238 | |
| Expression, single layer (counts in the state) | 4 | 2,155 | `counted` (variant C): 4, 2,112 |
| Expression, M0's flat counts in a separate mint record | | | `flat` (variant B): 6, 3,116 |
| `NameUse` through a parse state | 6 | 3,181 | `nameuse`: 7, 3,735 |
| Field through a parse state (indexes it) | 7 | quadratic, below | |
| Field on the bare mint | 5 | quadratic, below | |
| Import through a parse state (indexes it) | 6 | quadratic, below | |

What the 6 of the spec's mint are: the node and its kind's box (2), the
`(IdMint, Expression)` and `(ProbeState, Expression)` tuples (2), and copies
of `MintState` and the parse state's record (2). M0's seventh was a copy of
its `SyntaxCounts` record; section 3.4 makes it a `struct`, copied by value.

The `NameUse` mint keeps 6 because the struct is boxed inside the tuple that
returns it (M0's "struct boxes inside tuples").

Spread across the three rounds: 0.3% (`mint`, `state`), 0.4% (`single`),
2.3% (`name`), 0.1 to 0.4% (M0 probes) and 3.9% (M0 `counted`).

## The index mints are quadratic today

| Mode | 10,000 calls | 40,000 calls | Ratio |
| --- | ---: | ---: | ---: |
| `field` (through a parse state) | 1.148 G | 17.471 G | 15.2 |
| `mint-field` (bare mint) | 1.136 G | 17.427 G | 15.3 |
| `import` (through a parse state) | 1.142 G | 17.482 G | 15.3 |
| `state` (an expression, no index) | 0.052 G | 0.152 G | 2.9 |

A linear cost would give a ratio near 4. About 22 instructions per element
copied: each append copies the index (and retains every element), because the
`MintState` being updated is a borrowed parameter, not an owned one, so the
list it holds is shared at the append. The bare mint shows the same, so it is
not the parse state's nesting: it is today's ownership of a record updated
inside a function that returns a tuple. Increment 3 of
`VALUE_TUPLES_AND_STATE_HANDOFF.md` (consuming clones for multi-value
results) and increment 4 (last-use hand-off out of a `var`) make it linear
for the bare mint; through the parse state it also needs increment 5 (field
places), which section 4.4 of that document already lists for `fields.mint`.

**Estimate on the self-compile.** A per-file count of declarations, fields,
variants, enum cases, methods, local functions and globals over `blorp/src`
and `standard_library/src` (520 files; 34,719 definitions, against the
discovery census's 32,098) gives `sum n(n+1)/2 = 6.30 M` copied elements: at
22 instructions each, **about 0.14 G instructions**, with one extra
allocation per definition (about 35 k). The largest module
(`stage_09_core/ir.brp`, 2,150 definitions) is about 50 M of it; the median
module has 31 definitions. Imports are a handful per module and negligible.
This is an estimate from a regex count, not a measurement; M3 measures the
real parser.

## Single layer

M0 measured a single-layer state, the counts in the parse state's own record,
at 4 allocations per mint against 6, and recommended it. The measurement
stands (above: 4 and 2,155 instructions). M1 keeps the two layers of sections
3.15 and 3.16, because a single layer cannot keep the boundary those sections
specify:

- Only `ids.brp` can make an id (the id types are opaque there), and no
  function returns a bare id. A single record holding both the counts and the
  parser's fields must be defined where ids are made, so `ids.brp` would hold
  the parser's cursor, source and diagnostics, or `parse_state.brp` would
  need a bare id constructor.
- A generic carrier (`IdMint[ParserFields]`) keeps one layer for minting but
  moves the cost to the cursor: every token advance would update a record
  inside the mint, a copy per advance today, far more frequent than a mint.
- The definitions and imports indexes are lists, so the mint cannot be a
  `struct` embedded by value.

So single-layer minting is a change to sections 3.15 and 3.16, not an M1
detail. It is reported to the design's owner with this note; the compiler
work above removes the gap without it.

## Caveats

- Probes isolate the mint; a real parse interleaves token reads, list growth
  and diagnostics (M0 measured the whole).
- The quadratic estimate assumes the parser mints every definition through
  one mint per module, as section 3.15 specifies.
- Host load was high; only instruction and allocation counts are evidence.
