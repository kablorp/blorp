# Blorp 2 String literal decoding, 2026-10-16

`string_value` in `blorp_2/src/parse/parse.brp` decoded a literal by building
a String to look at each byte (three allocations per byte) and by rebuilding
the decoded prefix with a copying `concat` for every escape. It now finds the
next escape by reading byte codes, keeps each raw run and each decoded escape
as one piece in a local list, and joins once. A 16 KB literal's parse costs
56 allocations instead of 49,208 and 4.1M retired instructions instead of
99.2M; the quadratic term is gone (see the dense rows). Output is identical on
all 425 e2e fixtures.

This is a proxy for the self-compile cost: the parse phase of owned inputs,
measured through a scratch harness that is not in the repository. It omits
checking and every later phase.

## Provenance

| item | value |
| --- | --- |
| baseline source | `git archive a1d7c7a98 blorp_2` |
| candidate source | branch `blorp2/string-decoding` on `a1d7c7a98`, working tree before the commit |
| host compiler | `bin/blorp` built by `make` from the same tree (`blorp 0.0.1`, commit `a1d7c7a98f06-dirty`), `aarch64-apple-darwin` |
| C compiler | Apple clang 21.0.0 (clang-2100.3.34.2), macOS 26.7.1, Apple M4 |
| pilot flags | `-O0 -DBLORP_MEMORY_DIAGNOSTICS=1 ... -lm -lpthread`, the Makefile `test-compiler` recipe |
| baseline pilot | `compiler.c` sha256 `d8c086c0...71a81314`, `compiler` sha256 `1331903a...dd167ccd` |
| candidate pilot | `compiler.c` sha256 `95a40688...47309cd5`, `compiler` sha256 `56d824e9...2f6386a8` |
| baseline harness | `decode_cost` sha256 `8f05e173...4bf44c82` |
| candidate harness | `decode_cost` sha256 `c2ca9b92...b39bfdf6` |
| `parse.brp` sha256 | baseline `e6ba44a2...c7f4ba63`, candidate `8cac4ccb...741e3ee7` |

Raw samples and scripts stay in the session scratch directory
(`scratchpad/tier2/` and `scratchpad/tier2/impl/`), not the repository. The
parse-phase harness is reproduced below instead of committed.

## Commands

Pilots (run from each tree's root):

```
bin/blorp compile --no-format blorp_2/src/main.brp -o compiler.c
clang -O0 -DBLORP_MEMORY_DIAGNOSTICS=1 compiler.c -o compiler -lm -lpthread
```

Whole compile, the harness's own invocation, serial, from the repository root:

```
BLORP_LEAK_CHECK=strict /usr/bin/time -l -o REPORT /usr/bin/env COMPILER \
  --library-root blorp_2/standard_library_temp FIXTURE OUT.c
```

Allocations come from `N allocs` on stderr; instructions from `instructions
retired` in REPORT. Allocations are deterministic. The first run of a freshly
linked compiler retires more instructions than later runs: over four relinks,
`long_unreached` 63.1M to 64.1M against 55.3M steady and
`many_escapes_unreached` 72.0M to 73.0M against 64.3M; a review saw 69.9M
(+26%) for `long_unreached`.

Parse phase alone: a scratch program imports `lex` and `parse_module` from
`blorp_2/src`, reads one file, and stops after `lex` (mode `lex`) or after
`parse_module` (mode `parse`). Each cell is the parse run minus the lex run,
the median of three serial runs of each, for the input file named. The
harness, built the same way as the pilot but from `harness/decode_cost.brp`
placed beside `src/` in each tree:

```
import:
	../src/lex/lex: lex
	../src/utils/names: program_names
	../src/utils/source: module_source, root_module_id
	../src/parse/parse: parse_module
	system: read_file


-- Scratch harness: MODE is read, lex or parse; the parse phase's cost is the parse run minus the lex run.
func main(args: List[String]) -> Int:
	match args:
		[_, mode, path]:
			match read_file(path):
				Err(error):
					print_error(error)
					2
				Ok(source):
					run(mode, source)
		_:
			print_error("usage: decode_cost MODE FILE")
			2


private func run(mode: String, source: String) -> Int:
	if mode == "read":
		print("read bytes=" + source.length().to_string())
		0
	else:
		match lex(module_source(root_module_id()), source, program_names().names):
			Err(error):
				print("lex error: " + error.message)
				1
			Ok(program):
				if mode == "lex":
					print("lexed tokens=" + program.tokens.length().to_string())
					0
				else:
					match parse_module(program, root_module_id()):
						Err(error):
							print("parse error at " + error.span.start.to_string() + ": " + error.message)
							1
						Ok(_):
							print("parsed")
							0
```

Build it with `bin/blorp compile --no-format blorp_2/harness/decode_cost.brp -o
decode_cost.c` and the same `clang` line; run `decode_cost lex FILE` and
`decode_cost parse FILE` under `BLORP_LEAK_CHECK=strict /usr/bin/time -l`.

Inputs: plain text (`abcdefghij` repeated), "escapes" (`a\n` pairs, three
source bytes each), "dense" (`\n` only, two source bytes per escape), each
inside `func main() -> Int: "...".length()`; and four owned sources from
`a1d7c7a98`.

## Parse phase, allocations / retired instructions

| input | baseline | candidate |
| --- | --- | --- |
| plain 1,024 B | 3,128 / 6.37M | 56 / 0.56M |
| plain 4,096 B | 12,344 / 24.8M | 56 / 1.27M |
| plain 16,384 B | 49,208 / 99.2M | 56 / 4.20M |
| plain 262,144 B | 786,488 / 1,584M | 56 / 63.1M |
| `a\n` x5,461 (16 KB) | 60,124 / 130.1M | 16,465 / 42.1M |
| dense 4 KB | 14,389 / 28.9M | 6,222 / 14.9M |
| dense 64 KB | 229,429 / 554M | 98,390 / 234M |
| dense 256 KB | 917,557 / 3,537M | 393,306 / 961M |
| `main.brp` (5.5 KB) | 7,356 / 16.4M | 5,411 / 12.9M |
| `parse.brp` (121 KB) | 151,916 / 335.1M | 107,224 / 251.1M |
| `emit.brp` (72 KB) | 79,919 / 180.3M | 69,154 / 160.2M |
| `render.brp` (44 KB) | 72,576 / 154.6M | 31,965 / 77.7M |

Baseline slope on plain text: 3.000 allocations and about 6,050 instructions
per byte; candidate: constant 56 allocations and about 240 instructions per
byte.

Dense, instructions per source byte (baseline / candidate): 1 KB 7,266 /
3,722; 4 KB 7,068 / 3,630; 16 KB 7,304 / 3,568; 64 KB 8,459 / 3,571; 256 KB
13,491 / 3,665. The baseline's per-byte cost rises past 64 KB because
`blorp_string_concat` copies the whole decoded prefix for every escape; the
candidate stays flat. Allocation counts are linear in both, so no allocation
ceiling can show the quadratic term, and below about 64 KB the allocation
term dominates.

## End to end

| fixture (4 KB literal in a function nothing calls) | baseline | candidate | ceiling |
| --- | --- | --- | --- |
| `long_unreached` | 20,792 / 78.0M | 8,792 / 55.3M | 10,100 / 74M |
| `many_escapes_unreached` | 23,452 / 83.1M | 12,813 / 64.3M | 14,700 / 85M |

Allocation ceilings are the candidate's count plus 15%, as in `test_join.brp`,
`test_namespace.brp` and `test_lists.brp`. Allocations are deterministic and
carry the regression check. `CostLimits` has no allocation-only form (adding
one would change `cost.brp`), so each test also states an instruction ceiling,
set about 33% over the steady figure to survive a cold first run; it catches
gross growth only. On the baseline pilot both tests fail (`compiler allocations exceeded limit:
20792 > 10100` and `23452 > 14700`); on the candidate all 17 cases of the
string-literal group pass. The existing `LIMITS` (134,000 allocations) and
`LONG_LIMITS` (170,000) are 9 to 15 times the measured costs and could not
see this; tightening them is a separate change.

Whole-corpus allocation sweep over 425 fixtures (423 existing, 2 new): 354
equal, 70 fewer, 1 more (`empty.brp`, 8,980 to 8,981: the empty literal now
builds a one-piece list). `basic.brp` 9,005 to 8,990; `long.brp` 30,292 to
18,004. Total 5,358,744 to 5,320,114.

Output identity: for every one of the 425 fixtures the generated C, stdout,
stderr and exit status are byte-identical between the baseline and candidate
pilots, rejections included.

## Siblings (listed, not fixed; line numbers at `a1d7c7a98`)

- `emit/emit.brp:192-204` `append_string_bytes`: per decoded byte,
  `projected.concat(",")` plus `append_int`. For a reached literal, measured
  at `23aa093ab`: 2.0 allocations per byte and a rising instruction cost per
  byte (6.5k at 1 KB, 8.1k at 4 KB, 17.8k at 16 KB), more than the decoder
  after this change. Attributed by reading the code and the generated C, not
  isolated.
- `lex/lex.brp:925-945` `pipe_block`: `value = Text.concat(value, ...)` twice
  per pipe line; quadratic in line count.
- `main.brp:43` `render_file_location`: `substring(cursor, 1)` and `equals`
  per byte up to the error offset; the diagnostic path only.
- The emit concat class: 14 lines in `emit/emit.brp` of the form
  `result = result.concat(...)`, `output = output.concat(...)` or
  `prefix = prefix.concat(...)`, each copying the text built so far.
  Unmeasured except for `append_string_bytes`; the fix shape is a fragment
  list and one `join`, as `emit.brp` already does at several sites.
- Instruction ceilings with 18% headroom, as in `test_join.brp:7`,
  `test_namespace.brp:7` and `test_lists.brp:13`, have the same cold-run
  exposure: a cold first run retired up to 26% over steady here. Unchanged.
- Per escape, not per byte: `parse/parse.brp:908` (`lower(substring)` per hex
  digit), `:923` and `:931` (brace substrings), `:972` (the escape code
  substring) and the `DecodedEscape` record. An escape costs 3 allocations
  after this change (the empty-run piece, the code substring, the record).
  Skipping empty runs would save a third of the dense figure and nothing on
  ordinary text, so it was left out.

## Line counts

| | added | removed | net |
| --- | --- | --- | --- |
| production: `blorp_2/src/parse/parse.brp` | 51 | 34 | +17 |
| tests: `test_string_literals_syntax.brp` | 51 | 0 | +51 |
| tests: `test_string_literals.brp` | 22 | 0 | +22 |
| tests: two fixtures (`*_unreached.brp`) | 10 | 0 | +10 |
| docs: `LIBRARY_PARITY.md` | 1 | 1 | 0 |
| docs: `README.md` | 3 | 1 | +2 |

Of the production growth, 6 lines are the three named byte constants and
their shared comment, and 2 are the comment on the `$` test in `string_value`:
the pilot does not parse Char literals yet (the frontier would drop from 32/34
to 31/34), so the bytes are Ints.

## Gates

`make`, then `scripts/compiler-build-status` FRESH. `make -C blorp_2 test`
passed on the first revision of this commit (3,673 passed, 0 failed); after the
review fixes (comments, one local rename, README and parity text, ceilings) I
re-ran the whole `blorp_2/test/unit/test_parse` directory (243 passed, 0
failed, 32/34 source files parse), `make -C blorp_2 test-e2e` (426 cases
passed, including both new cost tests) and `scripts/blorp2-fixpoint --frontier`
(`parsed 32/34`, the same two files as before: `lex.brp` for Char literals,
`specialize.brp` for `pure` as a name). The added source has no tuples, `==`,
`!=`, new lambdas or String `+`.
