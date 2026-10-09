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
example needs no imports, builtin functions, or target runtime.
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

The [`union_values.brp`](test/e2e/fixtures/union_values.brp) example adds
payload-free fixed unions:

```blorp
fixed union Choice:
	First
	Second
pure func identity(value: Choice) -> Choice:
	value
pure func choose() -> Choice:
	identity(Second)
func main() -> Int:
	0
```

A variant is written as a bare value. `First.identity()` also works. Helpers
can take and return the declared union; `main` still returns `Int`. The native
TestSuite calls emitted helpers directly, verifies distinct variants and both
call notations, and requires an intentionally collapsed constructor to fail
the independent C driver under UBSan.

The match example, [`match_value.brp`](test/e2e/fixtures/match_value.brp), adds
an optional `Int` field and a match as the complete function body:

```blorp
fixed union Value:
	Empty
	Number(Int)
pure func unwrap(value: Value) -> Int:
	match value:
		Empty: 0
		Number(number): number
func main() -> Int:
	unwrap(Number(42))
```

It exits 42 with empty stdout and stderr. `Number(42)` constructs a value;
`Number(number)` selects that constructor and binds its field. A field `_`
discards the field, and a whole-pattern `_` matches any remaining value.
An unshadowed bare variant pattern selects that variant; another bare name
binds the complete matched value. Matches require exhaustive, useful arms.
The scrutinee runs once and only the first matching arm's result runs.
The companion [`match_values.brp`](test/e2e/fixtures/match_values.brp) supplies
helpers for native checks of field preservation, Int64 endpoints, whole-value
bindings, shadowing, and evaluation counts. Pattern captures are immutable;
general immutable and mutable local bindings are a future increment.

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

Every host-compiled source module has a matching unit suite under `test/unit/`.
The staged target prelude is a future input fixture, not a host module.
Integration
and native execution suites live under `test/e2e/`; their input programs live
under `test/e2e/fixtures/`. The suites use the existing compiler's `TestSuite`
API and run with `bin/blorp test --suite`; the example
fixture is not a test entrypoint. The host test API uses tuple-based test
registration. The compiler source under `src/` stays within the agreed subset.

Each executable example defines allocation and instruction ceilings in its
end-to-end test. The test prints actual costs and ceilings, then fails when a
ceiling is exceeded. The return-zero limits in
[`test/e2e/test_return_zero.brp`](test/e2e/test_return_zero.brp) are **160 managed
allocations** and **22,000,000 retired instructions**. Ceilings may be changed
deliberately as examples and the compiler grow; tests never raise them automatically.
The call-one limits in [`test/e2e/test_call_one.brp`](test/e2e/test_call_one.brp)
are **300 managed allocations** and **26,000,000 retired instructions**.
These two allocation limits were deliberately raised from 120 and 230 for
resolved union signatures and complete call contracts: the retained examples
measured 129 and 244 allocations. Their instruction limits remain unchanged.
The shared native/cost harness gives each fixture its own expected C, exit status
and limits. The pure-call fixture has **400 managed allocations** and
**32,000,000 retired instructions** as its current ceilings; its allocation
ceiling was deliberately raised from 360 for full integer conversion.
The nested-call fixture has **500 managed allocations**, and the nested-order
fixture has **550 managed allocations**. Both retain **40,000,000 retired
instructions** as their ceilings.
Both UFCS fixtures have **550 managed allocations** and **40,000,000 retired
instructions** as their initial ceilings. The return-42 fixture has **230 managed
allocations** and **26,000,000 retired instructions** as its ceilings. Small
allocation changes are reported alongside work and readability; they do not
justify literal-specific fast paths.
The union fixture has **1,150 managed allocations** and **40,000,000 retired
instructions** as its limits. The nested-order and union allocation ceilings
were deliberately raised from 500 and 1,000 after adding typed bodies, binding
identities, constructor operations and checked emission: their matched counts
rose from 492 to 516 and from 999 to 1,072. See the
[match increment measurements](../benchmarks/results/blorp_2_match_2026-10-09.md).
The `match_value` example starts with **5,000 managed allocations** and
**100,000,000 retired instructions** as its limits. The companion
`match_values` fixture supplies independent native value and evaluation proofs;
it is not a separately measured example.

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

This specification defines only the examples' language: functions with explicit
return types and zero or one explicitly typed parameter, and fixed union
declarations whose variants have zero fields or one `Int` field. A function
body is a single expression or a tail match with inline arm results. Expressions
start with a signed Int64 literal, a binding or variant name, or an application
with zero or one argument. UFCS suffixes may follow that expression.
Arguments use the same expression grammar, so direct and receiver calls may nest.
No other declarations, expressions, literals, statements, or comments are supported.

[`grammar.ebnf`](grammar.ebnf) defines the complete restricted source grammar
and its EBNF dialect. Whitespace is explicit: LF is `"\n"`, TAB is `"\t"`, and
the header/body spacing and EOF rules are productions. Identifier rules
exclude the reserved spellings `func`, `pure`, `match`, and lone `_`.
Names beginning with underscore, such as `_value`, remain identifiers.

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

- Every declaration header starts at column 1. A function has one header and
  an expression line or tail match; a union has one header and at least one variant line. No blank
  lines precede, separate, or follow declarations. Exactly one LF separates declarations.
  The final line may end at EOF or with one LF.
- The entire indentation prefix uses tabs only or spaces in groups of four.
  Body and variant lines require depth one: one tab or four spaces. Match arms
  require depth two: two tabs or eight spaces. Mixed indentation is invalid;
  parsing rejects a valid depth in the wrong position. No indentation stack
  or synthetic dedent tokens are needed for this restricted layout.
- Spaces may separate tokens and trail each line. They are required between
  `func` and the function name, and between `fixed`, `union` and the type name.
  Identifiers are scanned as whole words, so
  `funcmain` is one identifier. The two characters of `->` are adjacent.
  Spaces may surround a UFCS dot and its parentheses, as in `1 . one ( )`.
  Tabs occur only in the indentation prefix. Each expression stays on one line,
  including match scrutinees and arm results.
- `func`, `pure`, `match`, and lone `_` are reserved. The optional `pure` qualifier precedes `func`
  with spaces between the two keywords. Function, parameter and type names are
  identifiers whose meaning is checked after parsing.
- `fixed union Type:` introduces one or more variants on indented
  lines. `fixed` and `union` are contextual header words and remain valid names
  elsewhere. A variant is bare or has one type-name annotation, as in
  `Number(Int)`. Parsing preserves that type name; checking requires `Int`.
  Empty declaration parentheses, multiple fields and generic type parameters
  are unsupported.
- `match expression:` starts a nonempty sequence of depth-two arms written
  `Pattern: expression`. A pattern is a bare name, `_`, or a constructor name
  followed by parentheses containing zero or one field pattern. A field
  pattern is a binder or `_`; literal and nested field patterns are unsupported.
  A nullary constructor pattern may be written `Empty` or `Empty()`. `Number()`
  is valid syntax but fails semantic arity checking for a one-field constructor.
- Integer literals are decimal values from `-9223372036854775808` through
  `9223372036854775807`, with an optional adjacent minus. `-0` is accepted
  and has value zero. Leading zeros (`00`, `-01`), plus signs, separated minus
  signs and arithmetic operators are rejected. The lexer preserves the whole
  digit run; the parser validates spelling and range before converting it.
  A dot starts UFCS: `42.identity()` is a call, while `42.5` is invalid.
  Non-ASCII characters and CRLF line endings are rejected.
- Every token must be consumed. Extra expressions and malformed declarations are errors.

Semantic rules:

- Exactly one function must be named `main`, and it takes no parameters. A helper
  takes zero or one explicitly typed parameter. Helper parameter and return types
  are `Int`, the signed 64-bit integer type, or a fixed union declared in this
  file. `main` must return `Int`.
- Union types have nominal identity. Equal variant positions or shared variant
  spellings do not make two unions interchangeable. Union type names must be
  unique and cannot redeclare `Int`; each union's variant names must be unique.
  Type names occupy a separate namespace from functions and variant values, so
  a function may share a type name. A function cannot share any variant name;
  a collision highlights whichever declaration appears later in the source.
- Function names are unique within the input file. Every callee must be declared
  in that file; declaration order does not affect resolution. Calls supply exactly
  the number of arguments the callee declares.
- A bare expression name first resolves to the nearest local binding: an
  arm capture, or the containing function's parameter. Otherwise
  it resolves to a variant in the expected union: the innermost call's parameter
  type, or the containing function's return type when there is no unary call.
  Variants in different unions may share a spelling; expected type chooses the
  owner. `First()` is invalid because a payload-free constructor is a value;
  `Number(expression)` supplies the one `Int` field of a payload constructor.
  A name cannot refer to another function's parameter or denote a function value.
  A local binding shadows a same-named constructor or direct call; its established type
  is preserved, with no fallback to a constructor when that type is wrong.
  Arguments use the caller's scope, even when the callee has a parameter with
  the same spelling.
- `receiver.function()` resolves its target from the file's declared functions,
  independently of parameter shadowing. The receiver still uses the caller's scope.
  A parameter named `identity` can therefore be read and passed to the declared
  function with `identity.identity()`; the direct call `identity(identity)` tries
  to call the parameter and is rejected. UFCS targets require one parameter.
- Each argument and final return expression must match its receiving type.
  Resolved call-edge mismatches highlight the callee name at the call site;
  constructor lookup errors highlight the variant name. Return mismatches highlight
  the complete expression, excluding indentation and trailing spaces.
- A match scrutinee must synthesize a declared union type from a binding or
  function result. `match Empty:` and `match Number(42):` lack a receiving type;
  no type is guessed from patterns or the containing function's return type.
  Integer scrutinees are outside this increment. Each arm result must match
  the containing function's declared result type, which may differ from the
  matched union. All arms are checked, including ones a constant scrutinee
  cannot select.
- An unshadowed constructor spelling in a bare pattern selects that variant
  of the matched union. Other bare names, including a spelling shadowed by a
  local binding, introduce fresh whole-value binders. Explicit constructor
  patterns require an unshadowed constructor of the matched union. Its declared field
  shape determines the required pattern arity. Field binders and wildcards
  cover the constructor's entire field domain. Arm bindings are immutable and
  scoped to that arm; sibling arms may reuse a spelling. Earlier arms determine
  usefulness, and the remaining variants determine exhaustiveness.
- A pure caller may call only declared pure callees. Every function body is
  checked, including unreachable helpers, so a pure call chain cannot hide an
  impure edge. Calls inside arguments obey the containing function's purity.
  A violation highlights the callee name and suggests marking the callee pure
  or removing pure from the caller.
- Every call edge must be acyclic, including nested argument calls. Self and mutual
  recursion produce a semantic diagnostic. Repeating an acyclic call, such as
  `identity(identity(1))`, is valid. General recursion and its resource rules are
  future work.
- Each source function has its checked C return type and a generated symbol based
  on its compilation-local identity. `Int` uses `int64_t`; each union uses its own
  synthetic enum when all its variants are nullary. A payload-bearing union
  uses a distinct struct with an enum tag and one `int64_t` payload slot;
  nullary construction initializes that unused slot to zero. A separate C `int main(void)` wrapper calls
  the checked entrypoint and converts the result to the process exit status.
- The final expression is the return value. No explicit `return` is needed.
- Multiple parameters or arguments, explicit UFCS arguments, parenthesized expressions,
  multiple or non-Int payload fields, nested matches, block arm results,
  guards, qualified/nested/literal patterns, constructor UFCS, multiline chains,
  general bindings, generics, and function
  values are outside this increment. `Bool` has no special treatment: a written
  `fixed union Bool` follows the ordinary union path, and an undeclared `Bool` is unknown.
  Imports and UFCS-only import visibility are deferred; every function in this
  input file is available to either call notation.
- Syntax and semantic errors carry a source location, an explanation, and help.
  Rejected source produces no C output and does not overwrite an existing output.

## Architecture

The command reads an input file and writes an output C file:

```sh
bin/blorp run --no-format blorp_2/src/main.brp -- input.brp output.c
```

The impure command shell owns file I/O and printing. Compilation and
diagnostic rendering are pure. The pipeline publishes these complete results:

1. Lexing produces tokens with source spans and an explicit end-of-source span.
   Integer tokens retain their complete raw spelling; indentation tokens retain
   their depth and the entire prefix span.
2. Parsing produces function and union declarations, payload and parameter
   annotations, written names, expression syntax, and structured match bodies.
   Match patterns preserve names and field syntax without deciding whether a
   bare name denotes a constructor or binding. Each expression has a literal,
   name, or zero-argument application base, followed by unary application
   wrappers in evaluation order. Each wrapper
   retains explicit direct or receiver notation because their target lookup differs.
   Every expression records its consumed token span directly, without reconstructing
   locations from names or literal values.
   A local interning builder assigns one opaque `NameId` per spelling. Parsing
   seals the complete syntax and immutable name table in an opaque `ParsedProgram`.
   Integer conversion accumulates negatively against derived range cutoffs,
   checking before multiplication so even the minimum is represented safely.
3. Checking resolves nominal union and owned variant identities, then publishes
   one authoritative signature per function. A private resolution context holds
   the aligned declarations and signatures. Target resolution returns a complete
   call and signature after one lookup. The zero-argument and unary boundaries
   prove arity once, check purity afterward, and publish complete transient contracts.
   Unary contracts retain parameter and return types while the body validates every
   edge; they are erased to checked calls only after validation. Published function
   signatures remain the sole signature authority. Constructor operations are
   distinct from function calls and use the owning variant's declared field shape.
   Local reads carry a function-owned `BindingId`, distinguishing the parameter
   from each arm's binding. Match checking resolves patterns and result types,
   and establishes usefulness and exhaustiveness before publishing checked arms.
   Constructors retain their owning union and variant identities. Checking
   publishes an opaque program with its entrypoint identity. Call notation is erased
   after target resolution; emission receives the same checked calls for both forms.
4. Emission consumes that checked program and produces C.
   A match saves its scrutinee once and switches on its tag. Arm-local field
   projections occur only in the selected branch; a whole-value binder reads
   the saved value. Emission consumes checked patterns without repeating
   resolution, arity, purity, or coverage checks. Its result can report an
   internal checked-reference error instead of silently choosing a C layout;
   source-language acceptance is already complete.

The names module owns the spelling table and constructs canonical `main` and
`Int` identities once. Parsing uses string lookup only in its local interning
builder, then publishes the immutable table and special identities together.
Written names contain only a `NameId` and source span. Checking compares identities;
spelling lookup is reserved for diagnostics and rejects a missing table entry
as an internal compiler error. IDs are meaningful only within their owning
parse and table; equality and lookup do not validate table ownership. Only the
parser can construct the sealed program that checking accepts. `FunctionId` remains a separate
nominal identity assigned in declaration order. Checking retains call spans;
`UnionId` identifies a declared type and `VariantId` records both its owner and
variant position; neither is interchangeable with a `NameId` or `FunctionId`.
`BindingId` identifies a function-local parameter or arm binding independently
of spelling; reusing a spelling in sibling arms creates distinct bindings.
Emission uses resolved identities, typed signatures and expressions. Integer and
union programs with optional Int fields need no target heap allocation or ownership pass.
The flat expression chain remains the single-line, zero/one-argument leaf.
A structured body sum distinguishes that leaf from a match with ordered arms.
Ownership and general pass infrastructure will be introduced
when an executable example requires them.

[`src/prelude_temp.brp`](src/prelude_temp.brp) stages the target declaration
`type Int = builtin`. It is neither imported by the host compiler nor loaded
by Blorp 2 yet: the host permits builtin type declarations only in its standard
library, and the pilot does not parse type declarations or imports. Until the
next prelude-loading increment, the parser and emitter use the existing host
`int` module's signed bounds, and the frontend seeds the known `Int` spelling
before publishing NameIds. This is a temporary host dependency, not a loaded
target prelude or a claim of bootstrap readiness.

C emission uses the whitespace required to separate C tokens and a final LF.
It adds no indentation or internal line breaks for presentation.
Nonnegative literals use `INT64_C`; negative literals negate a representable
positive magnitude. The minimum uses `<stdint.h>`'s `INT64_MIN`, avoiding an
unrepresentable positive magnitude. The new
[`return_42.brp`](test/e2e/fixtures/return_42.brp) example exits 42. The endpoint
TestSuite calls generated `int64_t` helpers directly from an independent C
driver and compares against `INT64_MIN` and `INT64_MAX` under UBSan. It also
changes the emitted minimum to zero and requires the driver to fail. This
checks full-width values independently of the platform's process exit status.

The lexer shares token/diagnostic construction and byte-run scanning helpers.
Their local work is separate from collecting tokens and advancing the cursor.
The cleanup reduced formatted lexer source from 219 to 202 lines. Indentation
and ordinary scanning use exclusive branches, keeping each byte slice's
lifetime within the path that uses it. Exact token/diagnostic unit tests and
leak checks protect this boundary. The cost record also retains the separate
25,000-call lexer experiment; that total is different from one compilation's
end-to-end cost. Self-compilation is a later milestone.

## Bootstrap direction and process

[MEMORY_PLAN.md](MEMORY_PLAN.md) proposes memory responsibilities and typed
boundaries for the upcoming bindings increments; it adds no runtime support.

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

The performance goal is roughly five times faster compilation through C emission
than the existing compiler on matched workloads. Measure this separately from
Clang compilation/linking and native execution, with explicit source and toolchain
identity; it is a goal, not a measured result. The current unit command still
uses the existing compiler. Its measured 615 ms pipeline would become about
123 ms at that target, saving about 492 ms once the pilot supports that workload.
See the [timing record](../benchmarks/results/blorp_2_match_2026-10-09.md#unit-test-feedback-time).

Each next increment adds an example, the exact grammar and semantic rules it
needs, positive and negative tests, and independently reviewed implementation.
Builders remain local; published results remain immutable; each semantic fact
has one authority. Function identity is declaration-list position; checked calls
contain resolved identities and diagnostic spans, and the checked program owns the
entrypoint. Local topological elimination checks all base and wrapper call edges;
no persistent graph registry is needed. Each checked function retains its validated
signature beside its resolved body. Emission reads only validated
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
