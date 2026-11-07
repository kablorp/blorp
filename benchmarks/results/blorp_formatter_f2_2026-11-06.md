# Formatter F2: the List builtin records its element parameter

`ParsedBuiltinType.ListBuiltin` gains the element parameter's `WrittenName`
(`type List[T] = builtin`), so the formatter prints it from the tree instead
of reading it from the token after `[`. It is F2's one Parse change.

## Matched self-compile

Baseline: `07f6da1d1`. Candidate: that commit plus this change only. Both are
the `-O0` diagnostic compiler (`make -C blorp test-compiler`), run one at a
time on the baseline's `blorp/src/main.brp` with the baseline's
`blorp/standard_library`, under `BLORP_LEAK_CHECK=strict /usr/bin/time -l`.
Three runs each, alternating. Raw logs and the generated C are under the
ignored scratch directory, not committed.

| | Allocations | Retired instructions (median of 3) |
| --- | --- | --- |
| baseline | 13,248,499 (one run 13,248,500) | 39,979,518,521 |
| candidate | 13,248,505 (one run 13,248,506) | 39,978,441,082 |
| change | +6 | -1,077,439 (-0.003%) |

Instruction samples: baseline 39,999,587,829 / 39,977,651,236 /
39,979,518,521; candidate 39,994,313,355 / 39,978,441,082 / 39,977,491,861.
The difference is within run-to-run noise. The two generated C files are
byte-identical (`cmp`).
