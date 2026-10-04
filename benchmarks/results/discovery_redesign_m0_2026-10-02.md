# Discovery Redesign M0: What The Typed Trees Cost — 2026-10-02

Step M0 of [`docs/DISCOVERY_REDESIGN.md`](../../docs/DISCOVERY_REDESIGN.md):
a throwaway prototype of the expression and statement parser over typed trees
(sections 3.11 to 3.16), measured against today's stage parsing the same
bodies. This file records the numbers and compares them with section 7. The
prototype is deleted before M1.

## Result in four lines

- **Allocations: section 7 had the total right and the parts wrong.** The
  bodies cost 11.4 M allocations (today's tables: 0.007 M). 2.3 M are the
  retained trees (section 7: 3.9 M); 9.1 M are state and tuple plumbing
  (section 7: about 7 M).
- **Instructions: section 7 was wrong by a factor of about 7.** The tree
  parse of the bodies costs 6.80 G instructions against 0.94 G for today's
  parse of the same bodies. Section 7 priced an allocation at 60 to 80
  instructions; it costs about 510 (probe) to 600 (whole parse).
- **On today's compiler the redesign misses the flip ceiling** (+1.0%
  instructions) before the adapter's saving is counted: the tree stage costs
  +5.9 G on a 405 G self-compile (+1.45%).
- **The parked tuple hand-off buys 0.8 G (12%) and 1.5 M allocations (13%).**
  The largest remaining lever is the cost of one allocation, then more of the
  same plumbing.

## Provenance

- Source: branch `compiler-new/m0-tree-prototype`, based on `33df84e93`; the
  prototype is `blorp/test/compiler_new/tools/m0_tree/` and
  `blorp/test/compiler_new/tools/m0_tree_cost.brp`.
- Host: Apple Silicon, Darwin 25.6.0; `/usr/bin/time -l` counters. Load average
  was 5 to 14 (other agents were running): **instruction counts and peak RSS are
  stable (spread under 0.5%); wall time is noisy** (10 ms resolution, load).
- C compiler: Apple clang 21.0.0, `-O2 -fwrapv`. One binary without and one with
  `-DBLORP_MEMORY_DIAGNOSTICS=1` (allocation counts only), as in
  `discovery_adapter_bodies_2026-10-01.md`.
- Workload: the 449 modules of the self-compile root (`blorp/src/main.brp`, the
  module order dump's list, `compile` mode), 13.3 MB of source, 2.10 M tokens,
  13,105 function bodies, 1.37 M body tokens. Run from the repository root.
- Compiler for the main numbers: `bin/blorp` built by `make` at `33df84e93`
  (`FRESH`).
- Tuple hand-off variant: a scratch worktree (`/private/tmp/blorp-m0-handoff`,
  never pushed) at `33df84e93` plus the net diff of the seven commits of
  `core/tuple-return-handoff` after `2ff576c7d` (`5b66c5772` to `2311c509e`),
  applied with `git apply --3way`; one conflict (a renamed helper,
  `same_core_expr`) resolved by keeping main's name. The branch's first six
  commits overlap main's `620293a4f` and were not applied. A commit-by-commit
  rebase conflicts in `consume_specialize`, `record_update` and `reuse`; this
  is the net-diff equivalent. The same prototype source was compiled with this
  compiler.
- Nothing else of mine ran during a measurement; nine rounds, every item once
  per round in a fixed order (interleaved), medians reported.

## What was built

A tree parser over today's lexer output (`lex_source`, unchanged), for
function bodies:

- **Types** (`syntax.brp`): every type of sections 3.2 to 3.13 that bodies
  use: `Expression`/`ExpressionKind` (record plus union), `Statement`, `Block`,
  `Pattern`, `WrittenType`, `Dimension`, the form records and unions,
  `NameUse`/`Binder`/`WrittenName` as structs, `AtLeastOne`/`AtLeastTwo`, and
  the opaque id types minted by `IdMint` (section 3.15: `minted_*` return
  `(IdMint, node)`, counts in a nested `SyntaxCounts` record).
- **Parse state** (`parse_state.brp`): section 3.16: an opaque `ParseState`
  holding the lexed source (one field), the cursor, the mint and the
  diagnostics, and one `finished_*` per `minted_*`, each returning
  `(ParseState, node)`.
- **Parser** (`parser.brp`): every parse function takes a state and returns
  `(ParseState, node)`: expressions with precedence climbing and the postfix
  loop, calls, subscripts, aggregates, interpolation holes, lambdas, `if`,
  `match` with patterns, `select`, `with`, `concurrent`, `debug`, all statement
  forms, written types, patterns, dimensions.
- **Layout** (`body_ranges.brp`): finds each function body by tokens
  (what M3 calls skipping bodies by layout), and builds the stubbed token stream
  that lets today's parser run on declarations alone.

Differences from the design, none of which changes a cost shape except as noted:

- The mint and the node types are in one module: an opaque type inside an import
  cycle is rejected today (section 3.15).
- `SmallTuple[T]` is written out per element type. Constructing the generic
  union failed C emission here (`missing projected callable`); I could not
  reproduce it in a small file, so it is not minimized.
- Literals carry their token payload or text; the value checks are the lexer's
  (M2). A named argument is recognized by `name =` lookahead; a subscript
  assignment mints the `Subscript` first and rebuilds it as a `SubscriptPlace`
  (one dropped node per such statement, a few hundred in the corpus).
- `ParseState` holds `LexedSource`, cursor, mint, diagnostics and a counter that
  stands in for the old parser's tree inspection after a leading-dot
  continuation. `BodyContext` is a struct (loop context and anchor), not the
  enum of section 3.16.
- Concurrency parameters are not read by name (that needs the spelling table).
- Declarations, globals' values, and diagnostics beyond "this body did not
  parse" are not covered. A local function statement is reported as a failure;
  none occurred.

## Coverage

| | |
| --- | ---: |
| Modules | 449 |
| Function bodies located (top level, impl and trait methods) | 13,105 |
| Parsed to the end of the body | 13,105 (100%) |
| Skipped | 0 |
| Body tokens consumed | 1,368,233 of 1,368,233 |
| Bodies where the cursor stopped short of the body's end | 0 |

Ids minted: 469,599 expressions, 94,663 statements, 65,512 blocks, 85,187
patterns, 17,766 written types, 3 dimensions, 401,945 name uses, 21,393 binders;
754,123 nodes with an id of a node family, against 728,947 body nodes in today's
tables (the new count has 94,663 statement wrappers and 65,512 block ids the old
one has no rows for, and the old one has binder, qualifier and text nodes of its
own). The two counts agree to within 4%.

## Measurements

Median of 9 interleaved rounds. "Parse" values are differences between modes
that differ in one step; all modes share the same admission and lexing.

| Mode | What it runs | Instructions | User s | Real s | Peak RSS |
| --- | --- | ---: | ---: | ---: | ---: |
| `lex` | admit and lex every module | 1.868 G | 0.14 | 0.15 | 35.8 MB |
| `holes` | `lex`, then lex every interpolation hole | 1.882 G | 0.14 | 0.15 | 44.6 MB |
| `locate` | `lex`, then locate bodies and build the stub tokens | 2.098 G | 0.16 | 0.17 | 36.6 MB |
| `stub` | today's parser, every body replaced by `void` | 2.538 G | 0.20 | 0.21 | 64.8 MB |
| `old` | today's parser, whole modules | 3.247 G | 0.26 | 0.28 | 122.7 MB |
| `scan` | `holes`, then the prototype's inputs: pieces, line starts, body location, state; no parse | 2.746 G | 0.23 | 0.25 | 49.4 MB |
| `new` | `scan`, then the tree parse of every body | 9.548 G | 0.72 | 0.75 | 177.6 MB |
| `new`, tuple hand-off compiler | same source, other compiler | 8.143 G (`scan` 2.143 G) | 0.58 | 0.61 | 168.7 MB |
| `new`, struct mint | `SyntaxCounts` and `MintState` as structs | 8.919 G (`scan` 2.743 G) | 0.67 | 0.69 | 178.0 MB |

Derived (instructions; the `locate` driver cost, 0.230 G, is subtracted from
`stub`, and `scan`'s own cost from `new`):

| | Instructions | Real s (noisy) |
| --- | ---: | ---: |
| Today's parse of the bodies (`old` - `stub` + `locate` - `lex`) | **0.939 G** | 0.09 |
| Tree parse of the bodies (`new` - `scan`) | **6.801 G** (7.2x) | 0.50 |
| The same, tuple hand-off compiler | 5.999 G (-11.8%) | 0.44 |
| The same, struct mint | 6.175 G (-9.2%) | |
| Today's stage up to the end of parsing (`old`) | 3.247 G | 0.28 |
| The tree stage: declarations (`stub` - `locate` + `lex`) + holes + tree bodies | 9.124 G (+5.876 G, +181%) | |
| Per node: today / tree | 1,290 / 9,020 instr per node | |

Peak RSS: today's whole-module tables 122.7 MB. Trees add 128 MB over `scan`
(the live trees measure 131.8 MB, below). The tree stage with its declaration
tables (add `stub` - `lex`, 29 MB) is about 207 MB: **+84 MB, +68%** over
today's tables, against section 7's "+100 MB". Every module's trees were held
to the end, as the adapter would hold them.

Scale on the self-compile (405.3 G instructions, about 23 s to C): +5.9 G is
+1.45%, about +0.4 s is +1.8%.

## Allocation breakdown

Managed allocations (`BLORP_MEMORY_STATS=1`, diagnostic build), exact:

| Mode | Allocations |
| --- | ---: |
| `lex` | 271,422 |
| `old` (today's parse of everything) | 320,459 (parse: 49,037) |
| `stub` (declarations only) | 313,836 (parse: 42,414) |
| `scan` | 293,234 |
| `new` | 11,676,996 |
| `new` - `scan` (the tree parse) | **11,383,762** |
| The same, tuple hand-off compiler | 9,880,491 (-13.2%) |
| The same, struct mint | 10,227,694 (-10.2%) |

Today's parse of the bodies allocates 6,623 times (0.009 per node); the tree
parse 15.1 times per minted node.

**What the 11.38 M are**, by source:

| Source | Allocations | How known |
| --- | ---: | --- |
| Retained tree: node records | 0.84 M | live-object census |
| Retained tree: union boxes (forms) | 0.89 M | live-object census |
| Retained tree: boxed structs (`NameUse` and `Binder` in payloads) | 0.46 M | live-object census |
| Retained tree: lists | 0.13 M | live-object census |
| **Retained tree, total** | **2.32 M** (131.8 MB) | census, 2,316,642 objects |
| Mint and state plumbing, node mints (732,730 x 5) | 3.66 M | probe x id count |
| Mint and state plumbing, `NameUse` and `Binder` mints (423,338 x 7) | 2.96 M | probe x id count |
| Other parse functions that build a tuple themselves (14 functions, from call counts) | about 1.0 M | call profile |
| Not attributed (list growth, `Option` boxes, temporaries) | about 1.4 M | remainder |

Of the five plumbing allocations of a node mint, two are tuples (`(IdMint,
node)` and `(ParseState, node)`) and three are record copies (`SyntaxCounts`,
`MintState`, `ParseFields`). Tuples in total: about 2.3 M in the mints plus 1.0 M
elsewhere = **about 3.3 M**. Record and box copies: **about 4.3 M**.
**Ids themselves cost nothing**: an id is an `Int`; the cost is in threading the
mint.

Raw buffer allocations (list storage outside managed objects) were 1,360 in the
whole run: list buffers are part of the managed counts above.

### Probes (200,000 calls each; instructions from 1,000,000)

| Shape | Allocations per call | Instructions per call |
| --- | ---: | ---: |
| `state.advanced()` (update in place) | 0 | 32 |
| `(Int, Int)` returned and destructured | 0 | 9 |
| `(record, Int)`, record updated | 2 | 1,107 |
| One variant box built and kept | 1 | 510 |
| `finished_expression(VoidValue)`, node kept | 6 | 3,279 |
| `finished_expression(BooleanLiteral(True))` | 7 | 3,780 |
| expression then a statement over it | 13 | 7,005 |
| `finished_name_use`, struct kept in a list | 7 | 3,761 |
| Variant B: flat counts in a separate mint, two layers | 6 | 3,142 |
| Variant C: counts flat in the state, one layer | 4 | 2,140 |

With the tuple hand-off compiler: mint 4 (2,304 instr), literal 5, statement
9 (5,035), name use 5 (2,796), variant C 3 (1,682). With struct mint: mint 5
(2,839), name use 6.

## Where section 7 was right and where it was wrong

| Section 7 claim | Measured | Verdict |
| --- | --- | --- |
| Tree stage allocates about 11 M | 11.4 M (parse) | right |
| Trees about 3.9 M allocations | 2.32 M retained (3.1 per node, not about 4) | too high by 40% |
| Tuple and state plumbing about 7 M | about 7.6 M (6.6 M mints + 1.0 M other) | right |
| A `(ParseState, T)` call costs about 3 beyond the node | 5 beyond the node for a mint (7 for `NameUse`); 2 for a plain `(record, Int)` | wrong: the mint's two layers |
| No copy of the state's lists per call | confirmed (no quadratic time; no list copy) | right |
| Variant with scalar payload 1; struct in payload +1 | 1.0 per box; 0.46 M boxed structs retained | right |
| Allocation and release work 60 to 80 instructions each | **510** per box lifecycle (probe), **600** per allocation over the parse | wrong by 7 to 8x |
| Tree stage 4.6 to 5.6 G (vs 4.20 G) | about 10.1 G (4.20 G - 0.94 G + 6.80 G) | wrong by about 5 G |
| After G2: about 4 M allocations, 4.0 to 4.5 G | hand-off buys 1.5 M and 0.8 G, not 7 M and about 1 G | wrong: today's hand-off is partial |
| Whole self-compile: +10 M allocations (+5%) | +11.4 M (+5.4%) | right |
| Whole self-compile: -0.4% to 0% instructions | +1.45% for the tree stage alone; the adapter's saving (section 7: 1.3 to 2.0 G, not measured here) would leave about +1.0% to +1.1% | wrong; flip ceiling at risk |
| Memory about +100 MB over today's tables | +84 MB (trees 132 MB live) | right |
| The id census and `freeze` check removals | not measured | open |

The ceilings of section 7.4: on today's compiler the prototype alone is above
+1.0% instructions; with the tuple hand-off applied, about +1.25% before the
adapter. Wall time is above +1.0% by the same ratio. Peak RSS is within +5% if
the trees are released before Core, as planned (the self-compile peak is 2.15
GB; +84 MB is +3.9% if it were at the same point).

## Ranked compiler work

On this workload's 6.80 G and 11.38 M allocations, ranked by measured saving
first, then by estimate. An estimate says so; none of the estimated items could
be run today.

1. **State and tuple hand-off (G2, the parked branch).** Measured: -1.50 M
   allocations (-13.2%), -0.80 G instructions (-11.8%), -9 MB, with the remaining
   plumbing at 4 per mint (3 for the one-layer variant). It also cut the
   prototype's own pre-pass by 0.6 G (`scan` 2.75 G to 2.14 G). **The ceiling is
   far higher: 9.1 M of the 11.4 M allocations (80%) are plumbing, not tree.**
   Returning a small tuple by value and updating an owned record through a call
   would take most of them to zero: estimated up to -7 M allocations, -4 G.
2. **The cost of one allocation.** Measured: 510 instructions to build, keep
   and free one variant box; 600 per allocation over the whole parse. Three
   sampling runs of the `new` mode (about 300 samples each, coarse) put libc
   `malloc` and `free` at 10 to 19% of samples and list buffer copy, destroy,
   `memmove` and `memset` at 18 to 25%; the rest is generated code (header
   initialization, atomic retain and release, destroy dispatch). So a faster
   `malloc` alone buys less than 510 suggests; the whole object lifecycle is the
   lever. Every 1 M allocations avoided or made cheaper is worth about 0.55 G,
   so halving the lifecycle cost is about -3 G here (estimate). The earlier
   mimalloc pilot (self-compile -37% instructions) points the same way.
3. **Unboxed struct payloads (S2), including inside tuples.** Measured by proxy:
   making the two nested mint records structs saves 1.16 M allocations and 0.63
   G (that is a design change, not compiler work, but it shows each removed
   record is worth about 0.5 G per M). A struct inside a tuple or a variant
   payload is still boxed: `NameUse` and `Binder` (0.46 M retained, plus the
   boxes in 423 k mint tuples) and `IdMint` in its tuple. Estimated -0.7 M to
   -1.3 M allocations, -0.4 to -0.8 G.
4. **Value unions in a record field (G1).** Estimated from the census: the
   form box of 464 k expressions, 94.7 k statements, 72.6 k patterns, 17.8 k
   types, 34.3 k case bodies and smaller forms, about 0.68 M allocations,
   -0.35 G at 510 instructions each.
5. **Arena allocation for syntax trees.** Estimated: the 2.32 M retained
   objects stop paying `malloc`, `free` and per-object destroy, -0.5 to -1.0 G;
   also a faster teardown when the trees are dropped.

Design-level savings that need no compiler work, measured with the probes and
one full run: counts as structs (-1.16 M, -0.63 G); one layer for the mint
(probe: 6 to 4 allocations per mint, 3,142 to 2,140 instructions, not run end
to end); both with the hand-off (4 to 3).

## Rough edges found

- **A value handed back inside a tuple is not uniquely owned by the caller's
  next call.** My driver threaded the builder as `(builder, stats, trees) =
  f(builder, ...)`; the same code with the builder returned alone cost 3.29 G
  and the tuple form 6.45 G, with identical allocation counts, the difference
  being list copies (`memmove` was 70% of the samples). Allocation counts do not
  show it. This is the G2 problem in its most expensive form (a whole table
  builder copied per module) and a trap for every caller of a function that
  returns `(Table, x)`.
- Generic union constructor failed C emission (`missing projected callable`)
  for `SmallTuple[T]` across modules; not minimized.
- `BLORP_LEAK_CHECK` and `print_live_object_summary` count only the first 10,000
  live objects (`counted < 10000` in `runtime.c`); I lifted it in a copy of the
  generated C to count 2.3 M. A by-type allocation counter (not only live
  objects) would have answered the breakdown directly.
- `keyword_name_index` in `parser_cursor.brp` is a linear scan per call.
- The discovery stage's own `current_token` and `token_at` use `tokens.get`,
  which allocates an `Option` per read of a struct; the prototype used `get_or`.

## Caveats

- One prototype, written for measurement; its parse functions follow the
  section 3.16 shape and the old parser's grammar and were not tuned.
  The non-allocation work (about 1.0 to 1.1 G of the 6.8 G) is the same order as today's
  whole parse of the bodies (0.94 G), so it is not the story.
- Attribution of the plumbing allocations is probe times call count, with
  1.4 M left unattributed; the retained census is exact; the totals are exact.
- Wall time was measured under load and at 10 ms resolution; use the
  instruction counts.
- The tuple hand-off compiler is a net-diff port onto main, not the branch.
- The adapter (tree to old AST) was not built or measured; section 7's adapter
  figures are untouched.
- No claim about C emission or codegen of the tool; it is a measurement driver.

## Commands

```bash
make                                     # at 33df84e93; scripts/compiler-build-status: FRESH
bin/blorp compile --no-format -o m0.c blorp/test/compiler_new/tools/m0_tree_cost.brp
INCS=(); for d in $(find $PWD/blorp/src -name '*_ffi.h' | xargs -n1 dirname | sort -u); do INCS+=("-I$d"); done
clang -x c m0.c -O2 -fwrapv -w "${INCS[@]}" -lm -lpthread -o m0
clang -x c m0.c -O2 -fwrapv -w -DBLORP_MEMORY_DIAGNOSTICS=1 "${INCS[@]}" -lm -lpthread -o m0_diag

# paths.txt: the module order dump's list for blorp/src/main.brp (449 paths)
for mode in lex holes locate scan stub old new; do
  /usr/bin/time -l ./m0 $mode paths.txt                       # instructions, user and real time, peak RSS
  BLORP_MEMORY_STATS=1 ./m0_diag $mode paths.txt              # allocations
done
./m0 probe <advance|pair|cell|box|expression|literal|statement|nameuse|leaf|flat|counted> 1000000
BLORP_MEMORY_STATS=1 ./m0_diag new paths.txt --live-summary    # live-object census (cap in runtime.c lifted)
bin/blorp run --no-format --release --profile-mode calls --profile-module <m0_tree/...> \
  blorp/test/compiler_new/tools/m0_tree_cost.brp -- new paths.txt   # call counts
```

Raw samples were kept in the session scratch directory
(`final_C.txt`, nine rounds of every item; `alloc_final2.txt`; `live_final.txt`;
`probe_alloc_final.txt`) and are summarized above.
