# A calculator through small executable increments

Status: local imports, temporary target-library integration and concrete Int
addition are implemented and validated under
[their bounded design](INT_ADD_PLAN.md). UTF-8 String literals complete step 3
under [STRINGS_PLAN.md](STRINGS_PLAN.md), with
[retained validation](../benchmarks/results/blorp_2_strings_2026-10-11.md).
Step 4, Void, ordered statements and concrete print, is complete under
[VOID_PRINT_PLAN.md](VOID_PRINT_PLAN.md), with
[retained validation](../benchmarks/results/blorp_2_void_print_2026-10-12.md).
Steps 5–9 are complete: ordinary library Option/Bool imports, strict numeric
conversion, line input, integer and Float calculators. The
[completion design](CALCULATOR_COMPLETION_PLAN.md) and
[retained validation](../benchmarks/results/blorp_2_calculator_2026-10-12.md)
cover granular tests, native outcomes, independent reviews and matched costs.

Read [AGENTS.md](AGENTS.md) and the parent instructions. The supported language
is described by [README.md](README.md) and [grammar.ebnf](grammar.ebnf); this plan
does not make its future features supported.

| Order | Increment | Executable acceptance example |
| --- | --- | --- |
| 1 | Local selective function imports | A root calls an imported pure helper and exits 42. |
| 2 | Temporary target library and concrete Int addition | Import `add`; `add(20, 22)` exits 42. |
| 3 | Quoted UTF-8 String literals | `length("hello")` exits 5; Unicode contents, literal copies and returns preserve ownership. |
| 4 | Void, effect sequencing and concrete print | Print `Hello, World!` and exit 0; pure callers cannot print. |
| 5 | Library Option and integer conversion | Match `parse_int("42")`; invalid and out-of-range inputs produce None. |
| 6 | Line input and an integer addition calculator | Input `20\n22\n` produces `42\n`; invalid input and EOF have specified results. |
| 7 | Operation selection and other integer arithmetic | Input `multiply\n6\n7\n` produces `42\n`; unknown operations have specified results. |
| 8 | Float64 literals, arithmetic and formatting | Print an arithmetic result from Float literals. |
| 9 | Float conversion and calculator input | Decimal/exponent input works with explicit exceptional-value rules. |

The first calculator reads stdin and retains zero-argument `main() -> Int`.
Argument lists, a REPL and parsing infix expressions are later examples.

## Library boundary

When increment 2 needs them, copy selected standard-library files into
`standard_library_temp/`. Keep unsupported declarations commented out and record
the upstream source and deliberate adaptations. Lift concrete functions out of
trait implementations; the input language continues to exclude traits and FFI.
The temporary input library and the host library used to build the compiler are
separate dependencies. One declaration owns each builtin type. An explicit
library root and closed typed builtin contracts determine permitted runtime
operations; filesystem search does not silently fall back to the host library.

The first Option may use the already-supported `fixed union` spelling. Its
declaration identity, rather than its name or shape, determines the result of a
runtime conversion. Parsing rules must specify full consumption, signs,
whitespace and Int64 bounds. Float conversion additionally specifies exponents,
rounding, overflow, underflow, NaN, infinity and formatting.

## Validation and ownership

Each increment starts with a failing executable example and direct phase tests.
Update its restricted grammar, rejection cases and documentation together.
Use compiler-expert implementation and independent code/test review.

String literal construction has an explicit ownership contract. Print and parse
borrow their arguments. Input returns an owned String inside Option. Success,
invalid-input and EOF paths must discharge every ownership obligation. Test
analyses, insertion, independent verification and runtime behavior separately.

Build the pilot once per end-to-end run, compile each fixture once at `-O0`, and
run its real entrypoint. For the calculator, reuse the executable across input
cases and assert stdout, stderr and exit status. Keep the existing cost checks
and record measurements when setting new fixture ceilings.

The detailed first increment is [MODULES_PLAN.md](MODULES_PLAN.md).
