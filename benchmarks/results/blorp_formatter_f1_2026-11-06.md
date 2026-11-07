# Formatter F1: parentheses and declaration starts in the parse tree

`ValueExpression` gains `parentheses: List[Span]` (the pairs written around a
value, outermost first), and every declaration record gains `start: Span` (its
first token). Check never reads either field.

## Matched self-compile

Baseline: `7cbad5284`. Candidate: this change. Both are the `-O0` diagnostic
compiler (`make -C blorp test-compiler`), measured deliberately because it is
the one that prints the leak-check allocation count, run one at a time on the baseline's
`blorp/src/main.brp` with the baseline's `blorp/standard_library`, under
`BLORP_LEAK_CHECK=strict /usr/bin/time -l`. Three runs each. Raw logs and the
generated C are under the ignored scratch directory, not committed.

| | Allocations (all runs equal) | Retired instructions (median of 3) |
| --- | --- | --- |
| baseline | 12,379,051 | 37,399,444,509 |
| candidate | 12,379,326 | 37,425,486,557 |
| change | +275 (+0.002%) | +26,042,048 (+0.07%) |

Instruction samples: baseline 37,425,873,741 / 37,396,736,579 / 37,399,444,509;
candidate 37,425,486,557 / 37,426,096,322 / 37,419,922,776 (the baseline's own first
sample was 37,425,873,741). Run-to-run noise
(about 0.08%) is larger than the change. The two generated C files are
byte-identical (`cmp`). Ceiling was +0.5% on both.

Lines: production (`blorp/src`) net +39 (ceiling +60); tests +296 -96
(net +200), of which most is porting `test_grouping.brp` to the current
language, see below.

## Spike: where to record parentheses

Option A (a field on `ValueExpression`), first version, three runs each against
the same baseline: allocations +165, retired instructions median -0.005%, C
byte-identical, production net +2 lines. That version also recorded a pair on
tuples by mistake (a parse test caught it); the final numbers above are the
corrected design.

Option B (`group_spans` on the module) was not built, because A met the ceiling.
It could not satisfy the plan's exactness requirement anyway: a grouped value's
`span` is widened to its postfix end, so `(x).f()` has a span different from its
group's; `((a))` is one value for two groups; and a flattened `(x.f()).g()`
merges into one application list. Span equality finds only an un-postfixed,
singly grouped value; the rest needs containment search, which is guessing.

Flattened groups (`(x.f()).g()`, the case A cannot reprint): a pattern search
for a parenthesized receiver chain followed by `.` or `[` finds none in
`blorp/src`, `blorp/standard_library`, `blorp/test` or `benchmarks/blorp`. It is
a heuristic search, not a parse-based count.
