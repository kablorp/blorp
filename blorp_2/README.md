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
The next example adds a call to a zero-argument function:

[`test/e2e/fixtures/call_one.brp`](test/e2e/fixtures/call_one.brp):

```blorp
func main() -> Int:
	one()
func one() -> Int:
	1
```

The executable returns exit status 1 with empty stdout and stderr. A helper
may appear before or after its caller. Imports and printing are future increments.

The third example, [`test/e2e/fixtures/pure_calls.brp`](test/e2e/fixtures/pure_calls.brp),
adds declared purity:

```blorp
pure func one() -> Int:
	1
pure func answer() -> Int:
	one()
func main() -> Int:
	answer()
```

A `pure func` may call only other pure functions. A plain `func` is impure
and may call either kind. Purity is declared and checked, not inferred from a
literal body. A pure `main` is also accepted with the same C entrypoint ABI.
This example exits 1 with empty stdout and stderr.

The fourth example, [`test/e2e/fixtures/nested_calls.brp`](test/e2e/fixtures/nested_calls.brp),
adds one explicitly typed parameter and a nested call:

```blorp
pure func one() -> Int:
	1
pure func identity(value: Int) -> Int:
	value
func main() -> Int:
	identity(one())
```

It exits 1 with empty stdout and stderr. Helpers may take zero or one `Int`
parameter; `main` takes none. A call may pass one complete expression, including
another call. The companion [`nested_order.brp`](test/e2e/fixtures/nested_order.brp)
returns `zero(one(1))`, with both helpers ignoring their parameter. Its exit status
0 and exact generated C distinguish the order of the two calls.

The UFCS example, [`ufcs_calls.brp`](test/e2e/fixtures/ufcs_calls.brp), calls the
same helpers with `one().identity()`. This is equivalent to `identity(one())`
and exits 1. A receiver supplies the function's single argument; the method's
parentheses stay empty in this increment. The companion
[`ufcs_chain.brp`](test/e2e/fixtures/ufcs_chain.brp) demonstrates chaining:

```blorp
pure func one(value: Int) -> Int:
	1
pure func zero(value: Int) -> Int:
	0
func main() -> Int:
	1.one().zero()
```

This exits 0. Chains run left to right, so the body is equivalent to
`zero(one(1))`. Direct calls and UFCS can mix: `zero(identity(1).one()).identity()`
is equivalent to `identity(zero(one(identity(1))))`. The tests specify the exact
generated C and parsed call order for this mixed expression.

From the repository root:

```sh
make                            # Build the existing compiler first.
make -C blorp_2 example          # Compile the example to C, build it, run it.
make -C blorp_2 test-compiler    # Prepare or reuse the shared test compiler binaries.
make -C blorp_2 test             # Run the tests written in Blorp.
```

`example` keeps its generated C and executable in `blorp_2/build/` for
inspection. The tests use temporary directories. `BLORP_CC` selects a C
compiler executable (default `clang`).

`test-compiler` caches one `build/compiler.c` and its normal and diagnostic
`-O2` binaries. Its input manifest records the pilot sources, host executable,
Makefile, resolved C compiler path and version, and both modes' flags. A cold
setup generates C once and links twice; unchanged setup reuses all three
artifacts. Direct `bin/blorp test` runs check the same cache through Make.
Refresh discards the previous manifest before replacing artifacts and publishes
a new manifest after both links succeed, so a failed build cannot become a cache
hit when its source changes are reverted.
Each fixture still owns fresh temporary output, native execution, allocation
checks and three instruction samples. These checks never reuse fixture output.

Every source module has a matching unit suite under `test/unit/`. Integration
and native execution suites live under `test/e2e/`; their input programs live
under `test/e2e/fixtures/`. The suites use the existing compiler's `TestSuite`
API and run with `bin/blorp test --suite`; the example
fixture is not a test entrypoint. The host test API uses tuple-based test
registration. The compiler source under `src/` stays within the agreed subset.

Each executable example defines allocation and instruction ceilings in its
end-to-end test. The test prints actual costs and ceilings, then fails when a
ceiling is exceeded. The return-zero limits in
[`test/e2e/test_return_zero.brp`](test/e2e/test_return_zero.brp) are **120 managed
allocations** and **22,000,000 retired instructions**. Ceilings may be changed
deliberately as examples and the compiler grow; tests never raise them automatically.
The call-one limits in [`test/e2e/test_call_one.brp`](test/e2e/test_call_one.brp)
are **230 managed allocations** and **26,000,000 retired instructions**.
The shared native/cost harness gives each fixture its own expected C, exit status
and limits. The pure-call fixture has **360 managed allocations** and
**32,000,000 retired instructions** as its initial ceilings.
Both nested-call fixtures have **500 managed allocations** and **40,000,000
retired instructions** as their initial ceilings. Earlier ceilings remain unchanged.
Both UFCS fixtures have **550 managed allocations** and **40,000,000 retired
instructions** as their initial ceilings; the five earlier examples keep their limits.

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

The purity increment passed all 71 tests, both normally and with
UBSan/leak checking. It measured **330 allocations** and **19,204,477 retired
instructions** for `pure_calls`;
the existing examples measured 108 and 206 allocations, within their unchanged
ceilings. The native purity example exited 1 with empty stdout and stderr.
Neither final run rebuilt the shared compiler binaries. The cost record retains
the earlier measurements and final validation provenance.

## Grammar for this increment

This specification defines only the examples' language: one or more functions
with explicit return types and zero or one explicitly typed parameter. A function
body starts with the integer literal `0` or `1`, its own parameter name, or a
direct call with zero or one argument. UFCS suffixes may follow that expression.
Arguments use the same expression grammar, so direct and receiver calls may nest.
No other declarations, expressions, literals, statements, or comments are supported.

[`grammar.ebnf`](grammar.ebnf) defines the complete restricted source grammar
and its EBNF dialect. Whitespace is explicit: LF is `"\n"`, TAB is `"\t"`, and
the header/body spacing and EOF rules are productions. Identifier rules
exclude the reserved spellings `func` and `pure`.

[`test/test_grammar/test_conformance.brp`](test/test_grammar/test_conformance.brp)
checks grammar conformance through lexing and parsing, without semantic
checking. Named cases cover alternatives, optional/repeated terms, required
term order, lexical/layout boundaries, and complete input consumption. Accepted
cases check published names, expression structure and byte spans; rejected cases check the
exact diagnostic, help, and span. These are handwritten conformance cases;
the test runner does not interpret EBNF or generate cases from it.

```sh
bin/blorp test --suite --timeout 180 blorp_2/test/test_grammar
```

Lexical and layout rules:

- The header starts at column 1. No blank lines precede, separate, or follow
  declarations or their two lines. Exactly one LF separates declarations.
  The final line may end at EOF or with one LF.
- The entire indentation prefix on each body line is one tab or four spaces.
  Mixed indentation and additional leading whitespace are errors.
- Spaces may separate tokens and trail either line. They are required between
  `func` and the function name. Identifiers are scanned as whole words, so
  `funcmain` is one identifier. The two characters of `->` are adjacent.
  Spaces may surround a UFCS dot and its parentheses, as in `1 . one ( )`.
  Tabs occur only in the indentation prefix. Calls stay on the single body line.
- `func` and `pure` are reserved. The optional `pure` qualifier precedes `func`
  with spaces between the two keywords. Function, parameter and type names are
  identifiers whose meaning is checked after parsing.
- Integer literals are the single characters `0` and `1`. Other values and
  spellings, including `00`, `-0`, and `0.0`, are outside this increment.
  Non-ASCII characters and CRLF line endings are rejected.
- Every token must be consumed. Extra expressions and malformed declarations are errors.

Semantic rules:

- Exactly one function must be named `main`, and it takes no parameters. A helper
  takes zero or one parameter, written `value: Int`. Every function returns `Int`,
  the language's signed 64-bit integer type.
- Function names are unique within the input file. Every callee must be declared
  in that file; declaration order does not affect resolution. Calls supply exactly
  the number of arguments the callee declares.
- A bare name resolves only to the containing function's parameter. It cannot
  refer to another function's parameter or denote a function value. A parameter
  shadows a same-named direct call; calling that name rejects the non-callable `Int`.
  Arguments use the caller's scope, even when the callee has a parameter with
  the same spelling.
- `receiver.function()` resolves its target from the file's declared functions,
  independently of parameter shadowing. The receiver still uses the caller's scope.
  A parameter named `identity` can therefore be read and passed to the declared
  function with `identity.identity()`; the direct call `identity(identity)` tries
  to call the parameter and is rejected. UFCS targets require one `Int` parameter.
- A pure caller may call only declared pure callees. Every function body is
  checked, including unreachable helpers, so a pure call chain cannot hide an
  impure edge. Calls inside arguments obey the containing function's purity.
  A violation highlights the callee name and suggests marking the callee pure
  or removing pure from the caller.
- Every call edge must be acyclic, including nested argument calls. Self and mutual
  recursion produce a semantic diagnostic. Repeating an acyclic call, such as
  `identity(identity(1))`, is valid. General recursion and its resource rules are
  future work.
- Each source function has a 64-bit C return value and a generated symbol based
  on its compilation-local identity. A separate C `int main(void)` wrapper calls
  the checked entrypoint and converts the result to the process exit status.
- The final expression is the return value. No explicit `return` is needed.
- Multiple parameters or arguments, explicit UFCS arguments, parenthesized expressions,
  fields, multiline chains, bindings, and function values are outside this increment.
  Imports and UFCS-only import visibility are deferred; every function in this
  input file is available to either call notation.
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
2. Parsing produces complete declarations, parameter annotations, written names,
   and expression syntax. Each expression has a literal, name, or zero-argument
   call base, followed by unary call wrappers in evaluation order. Each wrapper
   retains explicit direct or receiver notation because their target lookup differs.
   A local interning builder assigns one opaque `NameId` per spelling. Parsing
   seals the complete syntax and immutable name table in an opaque `ParsedProgram`.
3. Checking validates signatures and call chains, resolves calls to function
   identities and parameter reads to the sole parameter slot, and publishes an
   opaque checked program with its entrypoint identity. Call notation is erased
   after target resolution; emission receives the same checked calls for both forms.
4. Emission consumes that checked program and produces C.

The names module owns the spelling table and constructs canonical `main` and
`Int` identities once. Parsing uses string lookup only in its local interning
builder, then publishes the immutable table and special identities together.
Written names contain only a `NameId` and source span. Checking compares identities;
spelling lookup is reserved for diagnostics and rejects a missing table entry
as an internal compiler error. IDs are meaningful only within their owning
parse and table; equality and lookup do not validate table ownership. Only the
parser can construct the sealed program that checking accepts. `FunctionId` remains a separate
nominal identity assigned in declaration order. Checking retains call spans;
emission uses resolved identities, parameter shapes and expressions. These integer-only
programs need no target heap allocation or ownership pass.
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
has one authority. Function identity is declaration-list position; checked calls
contain resolved identities and diagnostic spans, and the checked program owns the
entrypoint. Local topological elimination checks all base and wrapper call edges;
no persistent graph registry is needed. Each checked function retains its validated
purity and parameter shape beside its resolved body. Emission reads only validated
facts and does not recheck purity or name scope. C function and parameter names are
synthetic, and unused parameters are explicitly discarded to keep warning checks
clean. Existing compiler internals are not pilot dependencies.

The compilation pipeline is entirely pure once its source inputs have been
loaded. `compile(source)` composes pure lexing, parsing, checking and C emission;
diagnostic rendering is pure too. Local builders and `var` are allowed within
pure functions. The surrounding shell owns reading and writing files, printing,
process execution and timing. Future import loading must supply a complete source
bundle and explicit configuration to the pure pipeline. Compiler phases must not
consult the filesystem, environment, clock or shared mutable caches. Any reports
or measurements produced by a phase are returned as data for the shell to present.

Compiler source calls concrete arithmetic, comparison and concatenation functions;
it does not use trait-dispatched operators. Future traits and operator syntax can
select these same functions, keeping one implementation per operation. The current
host library declares some concrete functions inside trait implementations; the
future subset library will expose ordinary function declarations instead.
`src/text.brp` supplies exact string equality using equal byte lengths and an exact
prefix check because the host library has no ordinary string-equality function.
