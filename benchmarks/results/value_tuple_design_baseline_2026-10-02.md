# Value tuple design baseline (2026-10-02)

Historical evidence moved from the pre-pruning
[`VALUE_TUPLES_AND_STATE_HANDOFF.md`](../../docs/VALUE_TUPLES_AND_STATE_HANDOFF.md)
at `15785f753`. These are recorded measurements, not new runs or estimates of
the effect of any future increment. Increment 1 has a separate
[`result`](tuple_flatten_increment1_2026-10-02.md). The M0 tree-parser
prototype has its own `discovery_redesign_m0_2026-10-02.md` on the local
`compiler-new/m0-tree-prototype` branch (tip `a8e87c30e`; report says its
measured base was `33df84e93`). That report is not on this checkout.

## Probe provenance and commands

The original probe compiler was repository `bin/blorp`, `FRESH` after `make`
at `9172b35e0`, Apple clang 21, Apple Silicon, `-O2 -fwrapv`. The programs
are retained in [`benchmarks/ownership_shapes/`](../ownership_shapes/README.md):
`value_tuple_probe.brp`, `intern_probe.brp`, `nested_update_probe.brp`,
`pair_probe.brp`, and `last_use_probe.brp`. Its README owns the executable
commands and controls. `BLORP_MEMORY_STATS=1` on a diagnostic C link counted
allocations exactly; `/usr/bin/time -l` on the normal link supplied retired
instructions. Modes were run serially, three instruction samples each; the
table subtracts the `empty` mode and divides by calls. Recorded spread was
under 0.3%. The parser-shaped loops assign a returned state to a `var` via
`(next, x) = f(state, ...); state = next`.

| Shape | Allocations per call | Instructions per call | Tuple-free control |
| --- | ---: | ---: | --- |
| `(Int, Int)` from a call expanded by the old `tuple_sroa` | 0 | about 0 | |
| `(Int, Int)` from an opaque body | 1 | 574 | 0 / about 0 |
| `(Cell, Int)`, record updated and result destructured | 2 | 1,103 | `cell = bumped(cell)`: 0 / 5 |
| `(ParseState, Node)` over `(Mint, Node)`, node kept | 6 | 3,169 | same counter and node, no tuple: 2 / 1,013 |
| Recursive descent, 19 mints per call | 125 | 63,679 (3,350 per mint) | |
| `(Builder, Int)` with a growing list, 100,000 rows | 3 | 77,931 | `builder = builder.pushed_only(i)`: 0 / 39 |
| `(Builder, Cell)`, two owned records | 4 | 78,416 | one record holding both: 1 / 76,880 |

The builder shapes grew 7.5 times in instructions when rows grew from
10,000 to 30,000. The following tuple-free probes also exposed copy costs:

| Shape | Recorded allocations at 1,000 / 10,000 calls |
| --- | --- |
| Three-level nested record update | 1 per call |
| Same update through two local bindings | 2 per call |
| List append two record levels down | 1,001 / 10,001 |
| Scalar update two levels down | 1 / 1 |
| Immutable alias read once, then owner updated | 40,001 at 20,000 |
| Same read from owner directly | 15 |
| `next = interned_alone(spellings, i); spellings = next` | 2,251 / 22,501 |
| `spellings = interned_alone(spellings, i)` | 19 / 25 |

For the interning probe, three of four calls miss and update two lists. It
recorded the following total allocations at 1,000 / 10,000 calls:

| Result and caller shape | Allocations |
| --- | ---: |
| `(Spellings, Int)`, hit returns the given `spellings` | 3,251 / 32,501 |
| Same, without a read of `state` in the second element | 3,251 / 32,501 |
| Same, hit returns `into_opaque Spellings(state)` | 3,251 / 32,501 |
| `-> Spellings`, then `next = f(spellings, i); spellings = next` | 2,251 / 22,501 |
| `-> Spellings`, called as `spellings = f(spellings, i)` | 19 / 25 |

The generated C showed two references meeting on a miss: the caller kept
its `var` through reassignment, and the callee retained an alias of the
table and called a borrowing original rather than its consuming clone. The
probe programs and controls, not this summary, are the reproduction for a
future same-boundary measurement.

Recorded whole-process medians for `value_tuple_probe.brp` at 100,000 calls
(except `descent`, 10,000 calls) preserve the raw values behind the per-call
table:

| Mode | Retired instructions | Allocations |
| --- | ---: | ---: |
| `empty` | 18,699,134 | 0 |
| `pair_inline` | 18,465,667 | 0 |
| `pair_call` | 76,073,804 | 100,000 |
| `record_alone` | 19,234,636 | 1 |
| `record_pair` | 129,017,014 | 200,001 |
| `mint_control` | 120,007,097 | 200,020 |
| `mint_kept` | 335,618,363 | 600,020 |
| `descent` | 655,487,588 | 1,250,004 |
| `builder_alone` | 22,552,458 | 17 |
| `builder_pair` | 7,811,790,729 | 300,001 |
| `two_owned_record` | 7,706,659,632 | 100,003 |
| `two_owned` | 7,860,331,276 | 400,002 |

## Tuple allocation census

At `9172b35e0`, a copy of `runtime.c` counted `blorp_tuple_new` calls by
arity while `bin/blorp compile --no-format blorp/src/main.brp` compiled the
compiler. It counted **3,446,785 tuples**: 2.83 M pairs, 0.61 M triples and
three quadruples. That binary emitted byte-identical C to its unmodified
counterpart and retired 397.7 G instructions; its compiler C was built at
`-O0`, so its instructions are not a cost baseline for an `-O2` stage-2
compiler. For attribution, generated C used `--profile-mode calls`, the
tuple maker counted by return address, and the result was compiled at `-O0`
to avoid inlining shifting attribution. It counted the same 3,446,785
tuples. Functions with at least 500 calls accounted for 3,425,121; 21,664
were below that threshold. Classification by source shape yielded:

| Destination or source shape | Tuples | Share |
| --- | ---: | ---: |
| Match subject left on heap | 1,054,891 | 31% |
| Local built by a `match`/`if` arm and destructured | 451,066 | 13% |
| Returned and destructured | 280,136 | 8% |
| Returned inside `Option` | 214,133 | 6% |
| Stored in `List[(K, V)]` or by `List.enumerate` | 1,052,834 | 31% |
| Not classified | 372,061 | 11% |
| Box rebuilt from another box's elements | 0 | |

Large attributed sites include `ctfe_context_from_decls_in_domain`
(`List[(Id, Function)]`, 196,232), `ctfe_replace_binding`
(`List[(String, Binding)]`, 162,438), `mono.add_substitution`
(`List[(String, Type)]`, 83,525), and `List.enumerate` over `Int`, `CoreDecl`
and `CoreUnionVariant` (142,531, 97,416 and 88,972 respectively). Two
`Option` result sites in global/callable authority contributed 74,584 each.
The list-storage and optional counts are on this older revision; increment
1's later matched result did not repeat this full classification.

## Allocation lifecycle microprobe

The original `-O2` C loop did `malloc(40)`, a store, a read and `free`, with
and without an atomic increment/decrement, for 10,000,000 iterations under
`/usr/bin/time -l`. Its recorded figures were 504 retired instructions and
71 cycles for `malloc`/`free`, 7 instructions and 9 cycles for the atomic
pair, and 574 instructions and 91 cycles for a heap `(Int, Int)` tuple built,
read and released. These figures describe that host and toolchain; they do
not price a candidate on current main.
