# Blorp 2 arithmetic traits: cost and String reuse

Milestone 1 of the [arithmetic operators plan](../../blorp_2/ARITHMETIC_OPERATORS_PLAN.md):
`_base` declares Addable, Subtractable, Multipliable, Divisible, Modulable and
Negatable, and Int, Float and String implement them in place of free functions.
The plan's ceilings, on the matched frozen-input recipe, are +0.3% retired
instructions, +0.1% allocations and 60 production lines (gross additions). All
three are met: no `blorp_2/src` line changed.

The binding cost is the input effect, which the frozen recipe cannot see: what
compiling source that uses the new library costs. Before the resolution fix it
was +4.9% instructions and +1.4% allocations, because every arithmetic UFCS
call became a trait-method call and Check scanned every implementation row per
call. The [resolution fix](blorp2-trait-resolution-cost-2026-10-30.md)
(e594b4d72) indexed those rows. Rebased onto it, the input effect is +0.27%
instructions and +0.27% allocations, and the frozen recipe is unchanged
([after the fix](#after-the-resolution-fix)). The sections before that one
record the first measurement, against `a5785d3fd`.

## String concatenation keeps in-place reuse

Before, a direct call to the builtin `string.add` became
`RuntimeTarget(StringConcat)`, which consumes its left operand. Now the call
reaches the Addable implementation's wrapper. Owned-parameter inference
(393438c00) gives that wrapper an owned left parameter, because its body passes
the parameter to the consuming operation, so a caller still moves a dying left
operand in. The plan's fallback, specializing a single-builtin implementation to
its runtime target, was therefore not needed and was not added.

`concat_reuse.accumulate` (`output = output.add("x")` in a loop), before:

```c
struct blorp_string* const blorp_vl_9=blorp_string_concat_take_left(blorp_vl_3,blorp_vl_8);
```

After, the call site moves `blorp_vl_3` into the wrapper, which consumes it:

```c
struct blorp_string* const blorp_vl_9=blorp_f_4(blorp_vl_3,blorp_vl_8);
/* string.add */ struct blorp_string* blorp_f_4(struct blorp_string* blorp_p_0,struct blorp_string* blorp_p_1){
  ... blorp_string_concat_take_left(blorp_vl_0,blorp_vl_1); ... return blorp_owner_1;}
```

The retains and releases around these calls are unchanged. In the compiler's own
C, the seven String `add` sites (`path.join` 3, `path.normalize` 1,
`list.join_range` 2, `text.concat` 1) were `take_left` calls before and are now
wrapper calls, with the same retain and release counts in each function. The
`self.add(self)` site gains one retain and release. It copies both before and
after, so its allocations do not change. Reuse also holds through two generic
levels: the new fixture's `repeated[Value: Addable]` → `sum` → `string.add` →
`take_left` chain moves the dying total at every step.

`int/add.brp` emits byte-identical C before and after: `add.main` calls
`int.add`, whose body is `blorp_int_add(blorp_vl_0,blorp_vl_1)`.

The guard is the native row `arithmetic_traits`'s allocation count. With
ownership forced to all-borrowed (`own` calling `insert_ownership(program,
AllBorrowed)`), the wrapper's body becomes `blorp_string_concat(...)`, which
copies, and the fixture made 36 allocations instead of 29. That probe ran before
review added two Float rows, which raised the expected count to 31.

## Setup of the first measurement

- **Frozen input:** `git archive a5785d3fd blorp_2`, compiled as
  `--library-root <frozen>/standard_library <frozen>/src/main.brp`.
- **Compilers:** the pinned seed `blorp2-seed-905b4e7d5326` generated each
  compiler's C from `blorp_2/src` with its own library: the baseline from
  `a5785d3fd`, and the candidate from this change's working tree. Both were linked
  with Apple clang 21.0.0 at `-O0`, with `-DBLORP_MEMORY_DIAGNOSTICS=0` for
  instructions and `=1` for allocations.
  - baseline C `3bcf62b7…0efb202`;
  - candidate C `bfec7080…6c4c41`.
- **Runs:** serial on one macOS 26.7.1 arm64 machine. One warmup each, then three
  timed runs alternating baseline and candidate under `/usr/bin/time -l`, then
  one strict run of each diagnostic build.
- **Raw samples:** `build/arithmetic-traits/` (ignored): `measure.sh`, adapted
  from `build/supertraits/measure.sh`, `measure.log`, the `time-*` files, the
  C excerpts under `c/`, and the synthetic probes under `probe/`.

## Matched frozen-input results against a5785d3fd

| Metric | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Instructions retired, median of 3 | 62,965,085,919 | 62,991,024,316 | +0.041% |
| Instructions retired, range | 62,958,213,056 – 62,977,352,130 | 62,988,542,242 – 63,047,864,525 | |
| Allocations (strict, all released) | 19,051,408 | 19,051,408 | 0 |
| Output C SHA-256, all 8 runs | `3bcf62b7…0efb202` | `3bcf62b7…0efb202` | identical |

The candidate binary differs from the baseline only in how the compiler's own
library calls are lowered (the String wrapper calls above), so this result is
expected to be near zero. Elapsed time and peak RSS are not claimed.

## Input effect before the fix

The frozen recipe holds the input fixed, so it cannot see what the new library
costs each compilation. The same candidate binary was run on the frozen input and
on this change's own `blorp_2` (identical `src`, new library), twice each:

| Input | Instructions retired | Allocations |
| --- | ---: | ---: |
| frozen `a5785d3fd` | 62,958,371,646 / 62,916,405,352 | 19,051,409 |
| this change | 66,008,195,896 / 66,020,107,426 | 19,324,788 |
| change | +4.9% | +273,379 (+1.4%) |

Output for the candidate input is `bfec7080…6c4c41`, identical to the fixpoint
proof's seed, A, B and C outputs.

A synthetic probe isolates the cause. It has 600 functions of 20 chained
`step = step.add(n)` bindings (12,000 Int `.add` calls), compiled by one binary
with each library: 7.51G instructions with the base library and 10.16G with the
new one, about 220K extra instructions per call. The extra cost is linear in the
number of calls at 375, 750 and 1,500 functions (241K, 244K and 235K per call).
A control of 6,000 non-arithmetic receiver calls (`to_string`, `length`) is
unchanged (4.52G against 4.49G). A native `sample` of the probe puts the
increase in Check: 615 to 1,314 samples, 699 extra. Three areas hold 516 of
them:
- `callables.visible_method`: 149 to 437 samples (+288). Of these,
  `provider_owns_method` adds 226: it scanned every implementation for each
  method import, on every call. That is about 44% of the three areas' extra
  samples, and 32% of all of Check's.
- contract proof in `expressions.freeze_pending_value`: 43 to 144 (+101).
- `recursion.validate_recursive_instantiation`: 30 to 157 (+127).

The single-module probe could not show a second cause, which the resolution fix
found in self-compilation: `receiver_clashes` repeated each family check once
per import edge.

## After the resolution fix

The change was rebased onto main at e594b4d72, which also adds `Hashable` to
`_base`. It was then measured with `build/arithmetic-traits/rebased/measure.sh`:
- **Frozen input:** `git archive e594b4d72 blorp_2`.
- **Compilers:** generated by the seed from e594b4d72 and from this tree, then
  linked as before.
  - baseline C `e4261405…ceb865`;
  - candidate C `090ad8b7…5ceb655d`.
- **Runs:** serial. One warmup each, then three rounds of baseline on frozen,
  candidate on frozen, and candidate on this tree's `blorp_2`.

| Metric | Baseline, frozen | Candidate, frozen | Candidate, this tree |
| --- | ---: | ---: | ---: |
| Instructions retired, median of 3 | 62,722,310,478 | 62,723,487,627 | 62,894,635,551 |
| Range | 62,716,008,380 – 62,754,542,392 | 62,690,832,227 – 62,759,087,109 | 62,884,798,489 – 62,923,833,983 |
| Allocations (strict, all released) | 19,277,826 | 19,277,826 | 19,329,390 |
| Output C SHA-256, every run | `91dc5714…454a50` | `91dc5714…454a50` | `82469618…c006d5` |

- **Frozen recipe:** +0.002% instructions, inside the noise range. Allocations
  and output are identical.
- **Input effect:** the candidate on this tree against the same candidate on
  main's `blorp_2` costs +0.273% instructions and +51,564 allocations (+0.267%).

The resolution report measured +0.74% and +0.27% for the same comparison
against `a5785d3fd`. The two pairs of inputs differ, so the numbers are not
directly comparable.

## Lines

Counted against e594b4d72. The plan's 60-line ceiling counts gross added
production lines.

| Area | Added | Removed | Net |
| --- | ---: | ---: | ---: |
| `blorp_2/src` | 0 | 0 | 0 |
| Library (`_base`, `int`, `float`, `string`, `prelude`) | 83 | 33 | +50 |
| Tests: new suite, seven check fixtures, native fixture | 305 | 0 | +305 |
| Tests: harness row, Makefile registration, renamed bundle traits | 10 | 7 | +3 |

## Mutation probes

Each mutation was applied and the tests run. The source was then restored.

| Mutation | What failed |
| --- | --- |
| Int `negate` as `subtract(value, 0)` | `arithmetic_traits` row: `negation(5)` printed `5`, not `-5`. The `INT_MIN` row cannot tell the two forms apart. |
| Float `negate` as `subtract(0.0, value)` | `arithmetic_traits` row: the sign of negated `0.0` printed `1`, not `-1` |
| String's Addable implementation removed | The fixture is rejected at 63:11 (`sum("con", "cat")`, "type does not satisfy the required trait bound"). The seed rejects the compiler source at `utils/text.brp:6:7`, and the e2e driver no longer compiles. |
| Ownership forced to all-borrowed | `arithmetic_traits` allocations: 36, not 29 |
