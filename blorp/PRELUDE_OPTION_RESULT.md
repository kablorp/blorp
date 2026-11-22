# Option and Result methods in the prelude

A proposal for Keith, measured on 2026-11-21 on unpushed scratch branches.
Keith chose A on 2026-11-21 ("Yes, add both"); [Landing](#landing) records
the change and its ceilings.

**Historical.** This records the 2026-11-21 decision, and the import rows it
quotes are as they were then. On 2026-11-22 the prelude also gained
`Bool`'s methods, and that change removed these rows from user modules
everywhere, fixtures included. See [Bool](#bool).

## Problem

The prelude's methods return Options (`get`, `find`, `parse_int`, …) and
Results (`add_checked` and the other checked operations), but the methods
of Option and Result need an import:

```blorp
func main(args: List[String]) -> Int:
    args.get(1).get_or("none").length()
```

Today this fails with `error: no method accepts this receiver type`, whose
notes point at List's and Dict's `get_or`. A `.map_err(...)` call fails with
`unknown function`. Neither error names the fix. 86 rows in 55 user modules,
including `src/main.brp`'s `result: Result methods`, existed only for this.

## Options

- **A. Add both** `option: Option methods` and `result: Result methods` to the
  prelude. Remove the redundant rows and update the README in the same change.
- **B. Add neither.** A better error, one that names the missing `methods`
  import, helps either way, as a separate change.
- **C. Add Option only.** Every compile already loads `option.brp` through
  `string.brp`, so this is nearly free; Results keep their import.

No lazy loading mechanism is needed. A's cost is parsing one 26-line module,
the same cost an import of `result` has today.

## Cost

Measured on this Mac (macOS 26.7.1, Apple clang 21) against base `631ab9a73`,
with compilers built at `-O2` by `self-compile-cost`'s recipe. Allocations and
peak heap are deterministic. Instructions are the median of 11 runs, rotating
the order. Each side's first run is cold, about 14% high, and the median
ignores it; the other 10 runs spread about 0.6%. Raw samples are in
`blorp/build/prelude-option-result/` and `blorp/build/self-compile-cost/`.

**A one-module program that uses neither**, `return/zero`:

| | allocations | peak heap, bytes | instructions |
| --- | --- | --- | --- |
| base | 56,538 | 1,251,743 | 69,074,167 |
| A | +1,372 (+2.43%) | +31,758 (+2.54%) | +1,191,989 (+1.73%) |
| C | +55 (+0.10%) | +1,531 (+0.12%) | −0.03%, noise |

**A one-module program that uses both.** Base imports both, A imports
neither, and C imports `result`. The emitted C is identical on all three:

| | allocations | peak heap, bytes | instructions |
| --- | --- | --- | --- |
| base | 65,173 | 1,327,661 | 76,292,789 |
| A | −6 | −1,481 | +0.04%, noise |
| C | +10 | −424 | +0.02%, noise |

**Self-compile**, `--rounds 3`. The fixed-input row, which the ceilings bind,
has identical C, allocations and peak heap. Its instructions change by noise
(+0.063% and +0.040%). The own-source row:

| A | allocations | peak heap | instructions |
| --- | --- | --- | --- |
| rows kept | +1,374 (+0.0106%) | +1,511 (+0.0008%) | +0.094%, noise |
| 86 rows removed | −1,324 (−0.0102%) | −39,415 (−0.0214%) | −0.053%, noise |

In a small program, A's cost is loading `result.brp`. On base, importing
`result` costs +1,340 allocations, about 1,030 of them in lexing and parsing.

## Rule checks

- **Receivers:** same-named methods on different receivers do not conflict,
  such as `get_or` on List, Dict and Option, or `map` on List, Option and
  Result. The swept candidate passes `make -C blorp test`, with 3,336
  passing checks, none failing, and exit 0.
- **Redundant rows:** a row that repeats the prelude is accepted.
- **Reserved names:** a user function named `is_some`, `is_none`, `get_or`,
  `to_result`, `map`, `is_ok`, `map_err` or `and_then` is rejected when its
  first parameter fits Option or Result. The error is "two functions named
  is_ok can accept the same receiver", as for String's methods. This
  includes generic parameters: `pure func is_ok[T](value: T) -> Bool` compiles
  today and would not. Nothing in the tree is affected.
- **Direct calls:** `is_some(x)` still needs a named import.

## What goes

- **Production:** 86 rows in 55 files, plus `src/common/utils/text.brp`'s
  emptied import block. That removes 89 lines and adds 2 to the prelude.
- **Test code**, outside fixtures and `*_inputs/`: 193 rows in 141 files.
  Another 42 rows select functions by name, such as `result: map_err`, but
  call them only as methods; check each one first.
- **Fixtures** (18 rows) stay, because they are test subjects.
- **Library modules** (20 rows) stay, because they get no prelude.

## Recommendation

**A.**

- The prelude already returns Options and Results, so their methods belong
  with it (principle 10).
- C would make `.get_or` work while `.map_err` fails.
- The cost, about 1.4k allocations and 1.2 M instructions, falls only on
  programs that never use Result. On self-compile, the removed rows save
  more than the prelude rows cost.
- Record the parse cost rather than design around it. The lever is the
  parser's per-token allocation.
- The real compatibility cost is the eight reserved names; rule 14 accepts it
  before 0.1.

## Landing

The change adds the two prelude rows. It removes the 86 production rows,
`text.brp`'s emptied import block, the 193 test rows, and the 42 rows that
select these functions by name and only call them as methods. The README and
the library README describe the prelude's new selections and the reserved
names. Two API sketches in `PROCESS_DECISIONS.md` drop their row. Fixtures
keep theirs: they still carry the other prelude rows the earlier sweep left,
and some pin diagnostic spans. A new suite,
`test/test_common/test_analysis/test_check/test_prelude_option_result.brp`,
checks the real library. Against the old prelude it fails its three behaviour
cases: methods without an import, and the `get_or` and generic `is_ok`
overlaps.

Lines: production +2 −89 (net −87), test +189 −235 (net −46).

### Ceilings

These were set before the final measurement, from the figures above, against
base `631ab9a73`. After rebasing onto landing 13, the final column is
measured against its commit, `2ba8bcd8e`:

| Measure | Ceiling | Final |
| --- | --- | --- |
| self-compile fixed input: allocations, peak heap | +0 | +0, +0 |
| self-compile fixed input: instructions | +0.15% (the base spread) | −0.021% |
| self-compile own source: allocations, peak heap | +0 | −1,289, −39,425 bytes |
| `return/zero` at `-O2`: allocations | +1,450 | +1,372 |
| `return/zero` at `-O2`: peak heap | +33,500 bytes | +31,758 bytes |
| `return/zero` at `-O2`: instructions | +2.0% | +1.33% |
| production lines | net −85 or fewer | net −87 |

### Final measurement

This measures commit `ae54bc67b`, rebased onto `2ba8bcd8e`. After the
rebase, the sweep was rerun on the new tree; it removed landing 13's rows in
`src/lsp/lsp_command.brp` and `test/test_main/cli.brp`. The host and recipe
are as in [Cost](#cost).

- **Self-compile:** `self-compile-cost 2ba8bcd8e ae54bc67b --rounds 3`.
  - The fixed-input C is identical (`016f49c2d798d00a`).
  - Own-source instructions changed by −0.149%.
- **One-module:** `return/zero`, 11 rounds, embedded library, emitted C
  identical.
  - Base median 68,437,548, landing 69,346,924.
  - Apart from the cold first run, base spreads 0.17% and the landing 0.33%.
- **Gates, all exit 0:**
  - `make -C blorp test`: 3,343 PASS, 0 FAIL.
  - `make -C blorp test-e2e INSTRUCTION_CHECK=on`: 1,166 PASS, 0 FAIL. No
    e2e allocation or instruction ceiling was exceeded, so none moved.

Logs and samples are in `blorp/build/prelude-option-result/landing-rebased/`.

## Bool

On 2026-11-22 Keith asked that `option: Option methods`,
`result: Result methods` and `bool: Bool methods` all be "unneeded and
removed". The prelude gains `bool: Bool methods`. Every compile already loads
`bool.brp`, through `dict.brp`.

### Cost of the prelude row

Scratch commit `295f2f430` adds only the row; base is `265366b37`. Host and
recipe are as in [Cost](#cost).

| Workload | allocations | peak heap, bytes | instructions |
| --- | --- | --- | --- |
| `return/zero` at `-O2` | +49 (+0.085%) | +1,287 (+0.10%) | +0.30% (spread about 0.4%) |
| self-compile, fixed input | +0 | +0 | +0.035%, noise; C identical |
| self-compile, own source, rows kept | +234 (+0.0018%) | +990 | −0.055%, noise |

### The change

Every user module loses its `Option methods`, `Result methods` and
`Bool methods` selections: `src`, `scripts`, tests and now fixtures. It also
loses every by-name `option:`, `result:` or `bool:` selection it uses only as
a method. Names called directly, as in `and(left, right)`, or passed as values
stay. In all, 171 rows go and 29 are trimmed, in 197 files, and two import
blocks empty.

Other changes:

- `README.md` covers Bool's section, the prelude list, and a redundant-import
  example, now `list: List methods`.
- The library README is updated, and the decision records that quote these
  rows are labelled historical.
- The suite is renamed `test_prelude_methods.brp`. It adds Bool calls and a
  `not` overlap, and its redundant-import case uses `list: List methods`.
  Against main's prelude its two Bool cases fail.

Library modules keep their 27 rows: they receive no prelude. How they could
drop them is a separate proposal for Keith.

Lines against `265366b37`:

- production: +8 −41 (net −33);
- test code: +47 −149 (net −102);
- fixtures: +25 −38 (net −13).

### Ceilings

| Measure | Ceiling | Final |
| --- | --- | --- |
| self-compile fixed input: allocations, peak heap | +0 | +0, +0 |
| self-compile fixed input: instructions | +0.15% | −0.083% |
| self-compile own source: allocations, peak heap | +0 | −912, −15,246 bytes |
| `return/zero` at `-O2`: allocations | +80 | +49 |
| `return/zero` at `-O2`: peak heap | +2,000 bytes | +1,287 bytes |
| `return/zero` at `-O2`: instructions | +0.6% | −0.06%, noise |
| production lines | net −30 or fewer | net −33 |

The final column measures commit `3a2281bb8` against `265366b37`:

- **Self-compile:** `self-compile-cost 265366b37 3a2281bb8 --rounds 3`. The
  fixed-input C is identical (`adada6d84d4b7d19`).
- **One-module:** `return/zero`, 11 rounds, emitted C identical. Base median
  69,713,105, landing 69,671,341.
- **Gates, all exit 0:**
  - `make -C blorp test`: 3,342 PASS, 0 FAIL;
  - `make -C blorp test-e2e INSTRUCTION_CHECK=on`: 1,166 PASS, 0 FAIL. No
    e2e ceiling was exceeded, so none moved.

Logs and samples are in `blorp/build/prelude-bool/final/`. This record
amends the commit, and the amendment changes only this file.
