# Blorp 2 arithmetic operators: cost

Milestone 3 of the [arithmetic operators plan](https://github.com/kablorp/blorp/blob/9829b166ba73f1d14540971abefdd143e0c52d19/blorp_2/ARITHMETIC_OPERATORS_PLAN.md):
`+`, `-`, `*`, `/`, `%` and prefix `-`, each dispatched through its own
prelude-selected trait. The plan set ceilings of +0.8% retired instructions,
+0.1% allocations and 450 gross added production lines. On 2026-10-31 the owner
raised the instruction ceiling to about +1.3% and the line ceiling to about 700,
and kept the change whole.

| Ceiling | Result | Met |
| --- | ---: | --- |
| Instructions, about +1.3% | +1.23% | yes |
| Allocations, +0.1% | +0.091% | yes |
| Production lines, about 700 | 815 | no |

The output C is byte-identical on the frozen input in every run. Two known
costs drive the increase, each a separate follow-up:
- **Hash clustering, about +1.0%.** The instructions mostly come from the
  twelve new foundation words. They put `add`, `subtract` and the other members
  in the dense run of seed name IDs. `HashMap` (`blorp_2/src/utils/hash_map.brp`,
  `probe`) hashes an Int key to itself and probes linearly, so that run is one
  primary cluster in every map holding those names. With a mixed home slot the
  change costs +0.19%. The fix belongs in `probe`.
- **Depth, about 330 lines.** The 2,000-term sum requires Check, Specialize and
  Lower to walk left-nested call chains in a loop.

## Setup

- **Frozen input:** `git archive acafe1de8 blorp_2`, compiled as
  `--library-root <frozen>/standard_library <frozen>/src/main.brp`. It contains
  no arithmetic operators.
- **Compilers:** the pinned seed `blorp2-seed-9df029bac05b` generated each
  compiler's C: the baseline from `acafe1de8`, the candidate from this tree.
  - baseline C `643fe4d8…`;
  - candidate C `fc961cb5…`.
- **Linking:** Apple clang 21.0.0 at `-O0`, with `-DBLORP_MEMORY_DIAGNOSTICS=0`
  for instructions and `=1` for allocations.
- **Runs:** serial on one macOS 26.7.1 arm64 machine. One warmup, then three
  rounds of: baseline on frozen, candidate on frozen, baseline on the
  pre-milestone-1 input, candidate on this tree. Then one strict run of each
  diagnostic build.
- **Raw samples:** `build/arithmetic-operators/` (ignored):
  - `measure.sh`, adapted from `build/arithmetic-contracts/measure.sh`;
  - `measure-7.log`, the final run;
  - the `time-*` files;
  - `mix3.log`, the mixed-hash comparison;
  - the allocation-site reports `sites3-*.report`.

## Matched frozen-input results

| Metric | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Instructions retired, median of 3 | 48,688,916,130 | 49,290,024,656 | +1.235% |
| Range | 48,671,152,870 – 48,690,860,615 | 49,271,934,653 – 49,291,944,171 | |
| Allocations (strict, all released) | 16,791,297 | 16,806,562 | +15,265 (+0.091%) |
| Output C SHA-256, every run | `7dc9d2e9…` | `7dc9d2e9…` | identical |

The allocation-site profile charges the remaining allocations to chain links:
- the link records;
- the lists of inner links;
- the first-operand `drop(1)` copies.

Method chains such as `x.f().g()` are left-nested chains, so compiler source
holds about 1,660 of them. Two choices brought the count from +31,041 to
+15,265:
- walking a chain back up by index (`links.get`, whose `None` is an internal
  error), rather than with `List.reverse`, an O(n log n) copy;
- keeping the outermost link out of the list, so a two-link chain allocates no
  list. Its step stays a plain match, because a closure there allocated once
  per chain and measured +19,074.

Only the type walk, which has no error result, still reverses.

## Attribution

**By phase.** Measured on the earlier base `f935d55fb`, by cutting each compiler
short after one phase (a temporary edit under `build/`):
- Check accounted for +537M of +682M.
- Specialize accounted for +84M.
- Load, Lower, Own and Verify each stayed within ±50M.

**Seed words.** Main's compiler with twelve unused extra seed words changed
Check by −162M. With the twelve arithmetic spellings, which compiler source
calls constantly, it changed by +458M. Other unused counts (1, 6, 13, 24) moved
it by −172M to +21M, which shows a layout effect, not new work. That
experiment used `IntMap`; `HashMap` replaced it with the same home slot and
probe.

**Mixed home slot.** Measured on `acafe1de8`, both compilers with `probe`'s home
slot changed to
`key.hash().multiply(-7046029254386353131).divide(4294967296).remainder(size)`,
under `build/` only:

| Metric | Baseline, mixed | Candidate, mixed | Change |
| --- | ---: | ---: | ---: |
| Instructions, median of 3 | 47,282,561,821 | 47,370,845,303 | +0.19% |
| Output C | `7dc9d2e9…` | `7dc9d2e9…` | identical |

The mix also cuts main's own self-compile by 2.9%, from 48.713G to 47.283G.

## Input effects

**Milestone 1, on current main (the plan's precondition).** Main's compiler
compiled main's `blorp_2`, and the same `blorp_2` with the library from
`d355cdb70^` (`68f8b92033`), before milestone 1:

| Input | Instructions, median of 3 | Allocations |
| --- | ---: | ---: |
| main with the pre-milestone-1 library | 48,286,958,181 | 16,738,526 |
| main (`acafe1de8`) | 48,688,916,130 | 16,791,297 |
| change | +0.832% | +52,771 (+0.315%) |

**This change.** Its compiler source writes no operators. The candidate compiling
this tree, rather than the frozen input, costs +0.876% instructions
(49,721,924,855) and +288,728 allocations (+1.72%). That is the cost of the
source this change adds.

## Generated C

`a + b` and `a.add(b)` on Int emit the same body, a call to the `int.add`
wrapper, whose body is `blorp_int_add`:

```c
/* cmp.operator */ int64_t blorp_f_1(int64_t blorp_p_0,int64_t blorp_p_1){const int64_t blorp_vl_0=blorp_p_0;(void)blorp_vl_0;const int64_t blorp_vl_1=blorp_p_1;(void)blorp_vl_1;const int64_t blorp_vl_2=blorp_f_4(blorp_vl_0,blorp_vl_1);(void)blorp_vl_2;return blorp_vl_2;}
/* cmp.method */ int64_t blorp_f_2(int64_t blorp_p_0,int64_t blorp_p_1){const int64_t blorp_vl_0=blorp_p_0;(void)blorp_vl_0;const int64_t blorp_vl_1=blorp_p_1;(void)blorp_vl_1;const int64_t blorp_vl_2=blorp_f_4(blorp_vl_0,blorp_vl_1);(void)blorp_vl_2;return blorp_vl_2;}
```

A String loop that writes `output = output + "x"` emits the same C as
`output.add("x")`, apart from the function name. Both reach
`blorp_string_concat_take_left`.

## Depth

One level of a left-nested chain cost these frames at `-O0`:
- Check's freeze, about 26 KB;
- Specialize's translation, about 20 KB;
- `append_value_types`, 6.6 KB;
- `lower_value`, at least 9 KB.

The first overflow came at about 400 terms on an 8 MB stack. These now walk
the chain in a loop, the left-spine iteration Roslyn uses for binary operator
trees:
- `expressions.freeze_call_chain`;
- `specialize.append_chain_types` and `translate_call_chain`;
- `lower.lower_call_chain`.

Each loop walks back up by index, and the order of definitions and types is
unchanged.
- 2,000 to 8,000 terms compile.
- At 16,000 terms, the generated recursive drop of the nested checked tree
  overflows in runtime code.
- `nesting.brp` emits C with a maximum parenthesis depth of 4 and brace depth
  of 3. `long_sum.brp` emits 3 and 4.

## Mutation probes

Each mutation was applied to `blorp_2/src` and the owning groups and e2e were
run. The source was then restored. Logs and diffs are in
`build/arithmetic-operators/probes/`. Most probes ran before review rewrote the chain
walks, `fold_negative_literal` and `arithmetic_operand`. The postfix-rejection
probe was rerun on the final code, and removing `arithmetic_operand`'s `not`
check was added; the rows marked "rerun" come from the final code.

| Mutation | Tests that failed |
| --- | --- |
| `-` dispatched to `add` | check: each operator calls its own member; operators need the prelude-selected traits. e2e: operators, order, nesting |
| `%` dispatched to `divide` | the same check tests; e2e: operators, order, nesting |
| negation dispatched to `subtract` | check: the member and prelude tests and the aggregates test; e2e: operators, order and nesting fail to compile |
| `+` and `*` precedence swapped | parse: multiplicative above additive; both entry paths. e2e: operators, nesting |
| prefix `-` bound above postfix | parse: prefix minus between postfix and multiplication; folded-literal postfix. e2e: nesting |
| `-` right-associative | parse: binary levels associate left. e2e: operators (the `10 - 3 - 2` and `100 / 10 / 5` row) |
| literal fold dropped | Every compile fails: the library's `INT_MIN` is out of range and Float `negate` calls itself. Dropping the fold only for a spaced `- 1` fails parse: minus folds into a following literal; folded-literal postfix. |
| postfix rejection removed (rerun) | parse: folded literal followed by a postfix is rejected |
| `not` operand check removed (rerun) | parse: `not` cannot be an arithmetic operand |
| statement entry path removed | parse: both entry paths; `not` as an arithmetic operand |
| operand order swapped | check: operand mismatches at the right operand. e2e: operators, order, nesting, long_sum |
| member shape ignores parameters | check: malformed arithmetic traits; abstract members with wrong parameters; ordering's wrong default signature |

## Lines

Gross added production lines, against `acafe1de8`:

| Area | Added |
| --- | ---: |
| Lexer, parser, syntax, names | 289 |
| Check: contracts, dispatch, render, String help | about 208 |
| Depth: Check freeze | about 115 |
| Depth: Specialize | 126 |
| Depth: Lower | 86 |
| **Total `blorp_2/src`** | **815 (150 removed)** |

Review added about 90 lines:
- narrowing `MalformedCanonicalMember` to `ComparisonTrait`;
- typed chain links, whose walks have no unreachable arms;
- the outermost-link step that saves allocations;
- spelling the postfix and operator from tokens rather than source.

Tests: 1,151 added and 46 removed under `blorp_2/test`, most of them in three new
suites and four new fixtures.
