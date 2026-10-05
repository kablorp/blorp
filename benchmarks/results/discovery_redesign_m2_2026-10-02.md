# Discovery Redesign M2: The Pure Lexer and Its Bridge — Cost, 2026-10-02

This is a historical measurement of the original M2 branch. The adopted lexer
has unseeded local spellings, a separate keyword index and opaque decimal
digits; its syntax values use ordinary records. These numbers do not validate
that representation. Current token-storage and bridge costs must be measured
separately before the M2 cost gate is complete.

Cost ledger for step M2 of `docs/DISCOVERY_REDESIGN.md`: the lexer is a pure
function `lex_module(module, text) -> LexedModule`, and a temporary bridge
copies its product into the builder the parser still reads. The bridge's cost
goes away when the parser reads trees (M3, M4). Per the development rule
"make it work, make it right, make it fast", the costs below that come from
the compiler (a tuple allocation per word, a table copy per new spelling) are
recorded, not designed around; the compiler work removes them.

## Provenance

- Base: origin/main `754812369`; branch `compiler-new/m2-lexed-module` at the
  commit that holds this file
- Host: Apple Silicon, Darwin 25.6.0; `/usr/bin/time -l` counters. Other work
  ran on the host during the measurement (load average 14 to 24), so wall time
  is not evidence; instructions, allocations and peak RSS are
- C compiler: Apple clang 21.0.0, `-O2 -fwrapv`
- Stage input: a copy of the base's tree (`blorp/src/main.brp` as the root,
  prelude and tuple implicit modules; 449 modules); both binaries read the same
  copy, so the branch's source changes are not in the workload
- Stage tool: `blorp/test/compiler/tools/discovery_adapter_cost.brp`, one
  binary per revision built from that revision's sources, without and with
  `-DBLORP_MEMORY_DIAGNOSTICS=1` (allocations only)
- Five rounds, base and branch back to back in each round, one process at a
  time; medians

## Commands

```bash
bin/blorp compile --no-format -o cost.c blorp/test/compiler/tools/discovery_adapter_cost.brp
clang -x c cost.c -O2 -fwrapv -w $INCS -lm -lpthread -o cost_$revision
clang -x c cost.c -O2 -fwrapv -w -DBLORP_MEMORY_DIAGNOSTICS=1 $INCS -lm -lpthread -o cost_${revision}_diag
BLORP_MEMORY_STATS=1 ./cost_${revision}_diag $mode compile blorp/src/main.brp
/usr/bin/time -l ./cost_$revision $mode compile blorp/src/main.brp
/usr/bin/time -l bin/blorp compile --no-format -o out.c blorp/src/main.brp   # self-compile
```

## Results: the discovery stage

| | Base | Branch | Change |
| --- | ---: | ---: | ---: |
| Allocations, `tables` | 579,201 | 1,816,143 | +1,236,942 (+213.6%) |
| Allocations, `graph` | 7,703,766 | 8,940,708 | +1,236,942 (+16.1%) |
| Instructions, `tables` | 4.361 G | 6.921 G | +2.560 G (+58.7%) |
| Instructions, `graph` | 9.440 G | 11.957 G | +2.517 G (+26.7%) |
| Peak RSS, `tables` | 132.6 MB | 144.9 MB | +12.2 MB (+9.2%) |
| Peak RSS, `graph` | 327.5 MB | 338.9 MB | +11.4 MB (+3.5%) |

Per-round instructions (`tables`): base 4,452,490,550 / 4,360,811,184 /
4,405,460,057 / 4,340,139,844 / 4,336,066,874; branch 6,873,175,749 /
6,963,585,943 / 6,990,661,846 / 6,882,097,834 / 6,921,471,443. `graph`: base
9,440,115,968 / 9,481,987,040 / 9,489,520,222 / 9,408,629,719 /
9,403,743,423; branch 11,996,965,450 / 12,065,089,989 / 11,957,209,550 /
11,944,297,049 / 11,950,597,852.

### Where the rise comes from

Intermediate measurements of the same step on the same input (`tables`
instructions, medians of three to five rounds, host loaded):

| Version of the step | Instructions | Allocations |
| --- | ---: | ---: |
| Base | 4.34 G | 579 k |
| First version: lookup and add as two calls, unsound API | 5.14 to 5.19 G | 753,526 |
| Review fixes on the two-call form | 5.21 to 5.27 G | 753,757 |
| One-call `interned_spelling` (this branch) | 6.92 G | 1,816,143 |

- **The two-call form cost about +0.9 G (+20%) and +174 k allocations.** The
  bridge accounts for roughly half of the instruction rise. A first
  measurement (before the review fixes, against `33df84e93`, 449 modules)
  split it as: base lexing with admission 1.853 G; the pure lexer 2.051 G;
  the pure lexer plus the bridge 2.490 G. So the bridge was about 0.44 G of
  the 0.79 G rise then, the pure lexer's checked values, spelling table and
  interpolation pieces about 0.2 G, and lexing each interpolation hole apart
  and bridging it the rest. These probe figures were not repeated.
- **The one-call interning adds +1.709 G instructions and +1,062,386
  allocations** (753,757 to 1,816,143) over the two-call form. The stage's
  input holds 802,952 words (module tokens and the tokens of every
  interpolation hole, which are lexed apart) and 87,170 new spellings, so one
  tuple per word and 3 more allocations per new spelling (the table's record
  and its two lists, copied because the table is shared while a miss updates
  it) come to 802,952 + 3 x 87,170 = 1,064,462, within 0.2% of the
  measured rise. The exact shapes and what the compiler must do are in
  `docs/issues/interning-copies-table-and-allocates-tuple.md`; the pins that
  carry the cost say so.

The design choice (one call that cannot be misused, against a two-call form
whose add trusted a lookup of possibly another table) was made for soundness
first; the cost is the compiler's today.

## Results: the whole self-compile

`bin/blorp compile --no-format -o out.c blorp/src/main.brp` with the CLI built
from the base against the CLI built from the branch, both run on the base's
tree, five interleaved rounds:

| | Base CLI | Branch CLI | Change |
| --- | ---: | ---: | ---: |
| Instructions | 397.66 G | 401.45 G | +3.79 G (+1.0%) |
| Peak RSS | 2,070.7 MB | 2,071.4 MB | +0.7 MB |
| Wall time (loaded host, not evidence) | 34.3 s | 35.6 s | |
| Generated C | | byte-identical | |

`bin/blorp compile` runs the discovery stage by default: `DEFAULT_FRONT_END`
is `DiscoveryStage` (`blorp/src/lib/source_graph.brp`), reached through
`blorp/src/compiler/discovery_front_end.brp`. The +1.0% self-compile
instructions (+3.79 G) are therefore this step's stage cost reaching a real
compile; the generated C is byte-identical. The stage tool measured +2.56 G in
`tables` mode and +2.52 G in `graph` mode; the remaining gap to +3.79 G is not
attributed (the stage tool is built `-O2` and the CLI `-O0`, separate builds).
Rebuilding the base CLI with the branch's one `blorp/src/lib` change (a
function made public) gave +0.1%, so that change is not the source.
Allocations are not measured for the self-compile: the CLI is built without the
diagnostic runtime.

**Interim cost on main:** about +1.0% self-compile instructions and flat peak
RSS (+0.7 MB). By the stage ledger above, roughly a third of it (0.87 G of the
2.56 G) is the bridge and the pure lexer's checked values, which M4 removes
(M3 and M4 move the parser to trees), and roughly two thirds (1.71 G) is the
interning's tuple per word and table copy per new spelling, which the compiler
work removes
(`docs/issues/interning-copies-table-and-allocates-tuple.md`). The M6 ceiling of
`docs/DISCOVERY_REDESIGN.md`, section 7.4, applies at the flip.

## Output identity

The `tables` dump (`discovery_dump tables blorp/src/main.brp`) run from the
base's copy of the tree has the same md5 as the base's,
`e2428d158ae381f97d8a3788d89c35fc` (checked on the two-call form; the
one-call form changes how a spelling is interned, not which). `scripts/test
compiler-new-parity` passes (token-for-token corpus comparison, full-AST
differential, module order) and `scripts/test compiler-new` passes; their
counts are in the commit hand-off.

## Allocations per kind of token

`checked_number` (the lexer's number check, a union result read by the number arm) is a clarity choice, recorded here and not included in the stage totals above (measured before it was extracted): it adds 2 allocations per integer and 1 per float that a value result with no box would not need.

Pinned by `test_lexer_allocations` (2,000 repeats); the pins are exact where
one known cause explains them:

| Token | Base | Branch |
| --- | ---: | ---: |
| Symbol, layout token, comment, `#` | 0 | 0 |
| Word, keyword or name, or dimension name | 0 | 1 (the interning result tuple) |
| New spelling | not measured | 5: the text, the tuple, and a new record with copies of the texts and slots lists (2 with the table in place and no tuple) |
| Integer literal | 0 | 4: the checked magnitude's option and the boxed value (2), and the `CheckedNumber` result of `checked_number` with its boxed `Int128` payload (2) |
| Float literal | 0 | 4: its digits, the checked decimal that keeps them with the `Float`, the boxed value, and the boxed `CheckedNumber` result |
| String literal | 0 | 2: a checked value and the boxed union that holds it |
| Raw string | 3 | 4 |
| Interpolated string with one hole | 22 | 32 |

The bridge is pinned by `test_allocation_budget`: nothing per repeat for names
and literals the builder has met, 1 per rejected number (the diagnostic row),
and 10 per interpolated string of four pieces (2 per piece, the boxed variant
and its payload, and 2 per string, the bridged interpolation and its pieces
list). The parse pin of a string with two holes rose from 36,056 to 42,056 with
the 3 words in its holes, one tuple each.

## Shapes found while measuring

Two shapes copied tables and cost far more than the design does; a gate did
not catch either, which is why the allocation pins exist:

- **A function that branches on whether a spelling is present and also
  returns the table**, in the first measurement of the step (`tables` 14.2 G
  instructions, 1.1 M allocations). The tuple-returning one-call form still
  copies the table on a miss, at a smaller cost because a module's table is
  small; see the issue above.
- **A `var` builder reassigned in a loop, with a chain on it after the loop**
  (builder threading rule 2), which copied every table the parse appends to,
  once per interpolated string: 6.3 G instructions for the 88 modules that
  have interpolation, 1.85 G after moving the loop into its own function (the
  base is 1.45 G on the same modules). The allocation budget test pinned this
  construct at a count that had been changed without finding the cause; the
  reshaped loop brought it from 50,047 to 36,056.

## Reading

- The stage's cost, +58.7% instructions on `tables` and +26.7% on `graph`
  (the mode a compile pays, which shows as +1.0% of a self-compile), is the bridge (temporary), the pure lexer's
  checked values, and the interning's tuple and table copy, which the compiler
  work removes. The first two are about +0.9 G; the interning is +1.7 G.
- Peak RSS rises by 12 MB. Not investigated; the module's `LexedModule`
  (tokens, spellings, literal values) living beside the builder's copy of it
  is the likely source.
- `lex_module` is a pure function: parse order no longer changes a module's
  lexing, which is what M5's parallel parse needs.
- A float literal that is not finite is now a lexer diagnostic; the existing
  compiler rejects it in typecheck, with different wording.
