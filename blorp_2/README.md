# Blorp 2

A new compiler written in Blorp that emits C. Each increment starts with a
small program, defines the grammar it needs, and tests that program through
native execution. The existing compiler builds this compiler until it can
build itself.

## First example

[`test/e2e/fixtures/return_zero.brp`](test/e2e/fixtures/return_zero.brp):

```blorp
func main() -> Int:
	0
```

The executable returns exit status 0 with empty stdout and stderr. This first
increment needs no imports, prelude, builtin functions, or target runtime.
Hello world is the next example.

From the repository root:

```sh
make                            # Build the existing compiler first.
make -C blorp_2 example          # Compile the example to C, build it, run it.
make -C blorp_2 test             # Run the tests written in Blorp.
```

`example` keeps its generated C and executable in `blorp_2/build/` for
inspection. The tests use temporary directories. `BLORP_CC` selects a C
compiler executable (default `clang`).

Every source module has a matching unit suite under `test/unit/`. Integration
and native execution suites live under `test/e2e/`; their input programs live
under `test/e2e/fixtures/`. The suites use the existing compiler's `TestSuite`
API and run with `bin/blorp test --suite`; the example
fixture is not a test entrypoint. The host test API uses tuple-based test
registration. The compiler source under `src/` stays within the agreed subset.

Each executable example defines allocation and instruction ceilings in its
end-to-end test. The test prints actual costs and ceilings, then fails when a
ceiling is exceeded. The return-zero limits in
[`test/e2e/test_return_zero.brp`](test/e2e/test_return_zero.brp) are **90 managed
allocations** and **22,000,000 retired instructions**. Ceilings may be changed
deliberately as examples and the compiler grow; tests never raise them automatically.

These measure one execution of the new compiler on the example, including
process startup, argument handling, input/output, and the compile pipeline.
Building the compiler with the existing compiler, compiling the emitted C,
and running the generated program happen outside the cost measurements.
Allocation counts cover Blorp-managed ARC objects. They come from a separate
diagnostic build of the same compiler C, which also requires zero leaks.
Instructions come from the normal `-O2` build and use the minimum of three
process runs; all three samples are printed. Each run must emit the expected C.

The instruction check currently requires macOS `/usr/bin/time -l` and its
retired-instruction counter. Missing or malformed measurements fail the test.
The first limits were established on arm64 macOS with Apple Clang 21. See the
[cost record](../benchmarks/results/blorp_2_costs_2026-10-08.md) for baselines,
commands, provenance, and measurement limits.

## Grammar for this increment

This specification defines only the first example's language. There is one
function, no parameters, an explicit return type, and the integer literal
`0` as its body. No other declarations, expressions, literals, types,
statements, or comments are supported.

The grammar below is EBNF: braces mean repetition, brackets mean optional,
and quoted text denotes a terminal.

```ebnf
letter         = "A".."Z" | "a".."z" ;
digit          = "0".."9" ;
identifier     = (letter | "_") {letter | digit | "_"} ;
newline        = (* LF, U+000A *) ;
indent         = (* one TAB, U+0009, or exactly four spaces, U+0020 *) ;

program        = "func" identifier "(" ")" "->" identifier ":" newline
                 indent "0" [newline] EOF ;
```

Lexical and layout rules:

- The header starts at column 1. No blank lines precede, separate, or follow
  the two lines. The final line may end at EOF or with one LF.
- The entire indentation prefix on the second line is one tab or four spaces.
  Mixed indentation and additional leading whitespace are errors.
- Spaces may separate tokens and trail either line. They are required between
  `func` and the function name. Identifiers are scanned as whole words, so
  `funcmain` is one identifier. The two characters of `->` are adjacent.
  Tabs occur only in the indentation prefix.
- `func` is reserved. Function and type names are identifiers whose meaning is
  checked after parsing.
- The only integer literal is the single character `0`. Other values and
  spellings, including `00`, `-0`, and `0.0`, are outside this increment.
  Non-ASCII characters and CRLF line endings are rejected.
- Every token must be consumed. Extra expressions or trailing declarations
  are errors.

Semantic rules:

- The function must be named `main`, take no parameters, and return `Int`.
  `Int` denotes the language's signed 64-bit integer type; it maps to the C
  entrypoint's exit status here. This is one entrypoint signature, not
  support for general functions or return types.
- The final expression is the return value. No explicit `return` is needed.
- Syntax and semantic errors carry a source location, an explanation, and help.
  Rejected source produces no C output and does not overwrite an existing output.

## Architecture

The command reads an input file and writes an output C file:

```sh
bin/blorp run --no-format blorp_2/src/main.brp -- input.brp output.c
```

The impure command shell owns file I/O and diagnostic rendering. Its pure
pipeline publishes these complete results:

1. Lexing produces tokens with source spans and an explicit end-of-source span.
2. Parsing produces the complete syntax of the function and its return value.
3. Checking validates the entrypoint and publishes an opaque checked program.
4. Emission consumes that checked program and produces C.

Spellings and source spans belong to syntax. Emission receives checked meaning,
not unchecked names. Returning zero needs no heap allocation or ownership pass.
Ownership, type registries, and general pass infrastructure will be introduced
when an executable example requires them.

C emission uses the whitespace required to separate C tokens and a final LF.
It adds no indentation or internal line breaks for presentation.

The lexer shares token/diagnostic construction and byte-run scanning helpers.
Their local work is separate from collecting tokens and advancing the cursor.
The cleanup reduced formatted lexer source from 219 to 202 lines. Indentation
and ordinary scanning use exclusive branches, keeping each byte slice's
lifetime within the path that uses it. Exact token/diagnostic unit tests and
leak checks protect this boundary. The cost record also retains the separate
25,000-call lexer experiment; that total is different from one compilation's
end-to-end cost. Self-compilation is a later milestone.

## Bootstrap direction and process

Compiler source under `src/` stays within the agreed eventual subset: `String`, `Int`
(64-bit), `Float` (64-bit), `Bool`, `Void`, `List`, `Option`, `Result`, `Dict`,
`Set`, records/unions and their fixed spellings, opaque types, generics,
purity, matching, loops, `var`, `?=`, imports, and UFCS. Supporting every one
of these in input programs is future work, not a claim about this increment.

Concurrency, parallelism, tensors and dimension types, tuples, `debug:`, other
numeric widths, traits, doctests, channels, and FFI are excluded. All tests
are written in Blorp. Build commands may use Make and the C toolchain.

The current build uses the existing compiler and its standard library,
including host I/O and process APIs. That library contains excluded features;
it is a temporary host dependency, not a subset-compatible bootstrap library.
Self-hosting requires a library/runtime with explicit primitive contracts and
source dependencies that fit the subset.

Each next increment adds an example, the exact grammar and semantic rules it
needs, positive and negative tests, and independently reviewed implementation.
Builders remain local; published results remain immutable; each semantic fact
has one authority. Existing compiler internals are not pilot dependencies.
