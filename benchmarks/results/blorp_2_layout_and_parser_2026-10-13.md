# Blorp 2 layout and parser cleanup, 2026-10-13

Branch `blorp2/layout-and-parser`. The lexer emits Newline, Indent and Dedent and
records token spacing; the parser reads blocks from those tokens; program
assembly moves to `assemble.brp`. This note records the cost of that change.

## Provenance

| Item | Identity |
| --- | --- |
| Base source | `98ca7a138` (`origin/blorp-2`) |
| Head source | the commit adding this note's current text (parent `0ae613aee`) |
| Host compiler | `bin/blorp` 0.0.1, commit `79deebd45585`, sha256 `5dd10f5b82719bbc…` |
| Base pilot | sha256 `5b8d1c444365a67a…` |
| Head pilot | sha256 `d487305d8c0eb32f…` |
| C compiler | Apple clang 21.0.0, `-O0 -DBLORP_MEMORY_DIAGNOSTICS=1`, aarch64-apple-darwin |

Raw samples, probe sources and scripts are in the ignored
`blorp_2/build/layout-and-parser-2026-10-13/` of the measuring worktree.

## Method

Both pilots compile from their own `src/main.brp` with the same host and the same
C flags. Each pilot then compiles every one of the 222 e2e fixtures serially,
with `--library-root standard_library_temp`. Allocations come from one run's
`BLORP_LEAK_CHECK=1` report. Instructions are retired instructions for the whole
process from `/usr/bin/time -l`, the minimum of three runs with leak checking
off, because leak tracking does work per allocation and would inflate the
saving. Ratios are head over base, per fixture.

The phase split uses two native probes over the seven foundation library files
(`_base/types`, `_base/prelude`, `int`, `float`, `io`, `list`, `string`). One
lexes each file; the other lexes and parses each file. The parser figure is the
second probe minus the first. Probe allocations and instructions are measured
the same way as the whole compile.

Behaviour check: for every fixture, both pilots produce byte-identical C,
stderr and exit status (222 of 222 identical). The unit and grammar suites pin
diagnostic text.

## Results

### Whole compile, 222 fixtures

| Measure | Median | Minimum | Maximum |
| --- | --- | --- | --- |
| Instructions, head/base | 0.718 | 0.687 | 0.862 |
| Allocations, head/base | 0.617 | 0.528 | 0.894 |

Examples (allocations / instructions):

| Fixture | Base | Head |
| --- | --- | --- |
| `match/many_arms.brp` | 87,628 / 277.5M | 67,213 / 204.4M |
| `return/zero.brp` | 9,234 / 41.3M | 5,334 / 29.9M |
| `calculator/float_stress.brp` | 48,530 / 130.1M | 39,982 / 103.9M |

### Lexer and parser split, foundation files

| Phase | Base allocations | Head allocations | Base instructions | Head instructions |
| --- | --- | --- | --- | --- |
| Lexer | 5,907 | 1,649 | 33.1M | 22.1M |
| Parser | 3,545 | 2,983 | 7.9M | 4.4M |

The lexer instructions include process start-up. The main lexer saving comes
from reading bytes with `StringOps.get`, because a one-byte `substring`
allocates a String. The base lexer took one per byte scanned.

## Limitations

These are owned-input compilation proxies on small fixtures, not
self-compilation. Every figure is for a whole process, including start-up and
the foundation library each compile loads, so small fixtures understate the
relative change in lexing and parsing alone. The pilot and the probes are built
at `-O0`; optimized builds were not measured.

## Host costs that shaped the design

These micro-probes ran at `-O0` with the same host compiler. Their sources are
in the raw directory.

- **Updating a record's list field copies the list.** A tail-recursive builder
  returning `{ bag | items = bag.items.append(x) }` retires 118M instructions for
  1,000 items × 20 rounds and 682M for 4,000 (5.8x for 4x). A first
  `parse_module` draft threaded its declaration lists that way, which is
  quadratic in the number of declarations. The head appends each `Declaration`
  to plain `var` lists inside one Result-carrying loop.
- **A list passed into a call from a `var` and reassigned from the result is
  copied.** Appending 10 items per call, 200,000 items cost 3.12G instructions
  this way and 233M for 50,000 (13.4x for 4x). Appending in one loop costs 63M.
  The lexer therefore appends every token to one list in `lex` and does not hand
  that list to a per-line helper.
- **Tail-call accumulators are moved.** Recursion that appends to a list
  parameter stays linear, so the parser's list recursions over arguments, arms,
  statements and similar are not quadratic.

## Formatted code lines

Code lines are non-blank and non-comment, counted after `bin/blorp format` on a
temporary copy.

| File | Base | Head |
| --- | --- | --- |
| `src/lex.brp` | 634 | 655 |
| `src/parse.brp` | 2,990 | 2,536 |
| `src/syntax.brp` | 247 | 269 |
| `src/assemble.brp` | 0 | 222 |
| Total | 3,871 | 3,682 |

Touched test files: 18,901 → 18,624 formatted lines.
