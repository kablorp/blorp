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

It exits 1 with empty stdout and stderr. Helpers may take any number of typed runtime parameters; `main` takes none. A call may pass one complete expression, including
another call. The companion [`nested_order.brp`](test/e2e/fixtures/nested_order.brp)
returns `zero(one(1))`, with both helpers ignoring their parameter. Its exit status
0 and exact generated C distinguish the order of the two calls.

The UFCS example, [`ufcs_calls.brp`](test/e2e/fixtures/ufcs_calls.brp), calls the
same helpers with `one().identity()`. This is equivalent to `identity(one())`
and exits 1. A receiver supplies the first argument; explicit arguments in the method's
parentheses follow it. The companion
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
can take and return the declared union; `main` still returns `Int`. Source
fixtures select variants through their ordinary `main` functions and match
the results to observable exit statuses. The host TestSuite orchestrates pilot
compilation, builds the unmodified C output and checks each executable.

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
The companion [`match_values.brp`](test/e2e/fixtures/match_values.brp) covers
whole-value capture and field preservation; the separate
[`match_shadow.brp`](test/e2e/fixtures/match_shadow.brp) covers shadowing. Small
source fixtures expose these behaviors through `main`; exact full-width
values and evaluation order are checked directly at phase boundaries.
Pattern captures are immutable.

The [bindings example](test/e2e/fixtures/bindings.brp) adds a prefix of local
bindings before the final expression or tail match:

```blorp
pure func identity(value: Int) -> Int:
	value
pure func preserve() -> Int:
	original = 1
	var current = original
	current = identity(42)
	original
func main() -> Int:
	preserve()
```

This exits 1. `original` is immutable; `current` is mutable, and reassignment
does not change the earlier value. Local mutation is permitted in pure
functions. Every initializer runs once in source order, including unused
bindings. The [binding design](BINDINGS_PLAN.md) defines the phase contracts;
the [companion fixture](test/e2e/fixtures/binding_values.brp) instead returns
the reassigned current value, 42. Separate small fixtures cover self-assignment,
parameter shadowing and union values. Phase tests check exact full-width values
and evaluation order.

Bindings also compose with match arms. The
[arm-binding example](test/e2e/fixtures/match_binding_original.brp) returns 7:

```blorp
fixed union Choice:
    Empty
    Number(Int)
pure func identity(value: Int) -> Int:
    value
pure func inspect(choice: Choice) -> Int:
    match choice:
        Empty: 0
        Number(payload):
            var current = payload
            original = current
            current = identity(42)
            original
func main() -> Int:
    inspect(Number(7))
```

An arm block contains zero or more binding lines and a final expression,
indented one level deeper than its pattern. Inline and block arms can coexist.
Each arm has its own scope; sibling arms can declare the same name. An explicit
`var` may shadow an enclosing binding, and its initializer sees the earlier
binding. Ordinary `=` still reassigns the nearest mutable binding or rejects
assignment to an immutable one. Companion fixtures return the
[updated value](test/e2e/fixtures/match_binding_current.brp), exercise the
[other branch](test/e2e/fixtures/match_binding_empty.brp), and preserve an
[outer value](test/e2e/fixtures/match_binding_outer.brp) across shadowing.

The [mortal String example](test/e2e/fixtures/mortal_string.brp) starts the
managed path without literals, traits or general imports:

```blorp
func main() -> Int:
    value = 7.to_string()
    value.length()
```

It returns 1. The explicit temporary input prelude declares concrete pure
`to_string(Int) -> String` and `length(String) -> Int` functions. Conversion
allocates an immutable String leaf; length borrows it; its owner is released
after that use. The [identity companion](test/e2e/fixtures/mortal_string_identity.brp)
returns a borrowed parameter as an owned result before replacing the caller's
old owner. Other fixtures cover unused results, a surviving alias, and Int64
conversion boundaries. These operations use ARC; they introduce no COW or reuse.

The [tail String example](test/e2e/fixtures/match_string_second.brp) returns a
fresh String from its selected arm:

```blorp
fixed union Choice:
    First
    Second
pure func choose(choice: Choice) -> String:
    match choice:
        First: 7.to_string()
        Second: 42.to_string()
func main() -> Int:
    choose(Second).length()
```

It returns 2; the [First companion](test/e2e/fixtures/match_string_first.brp)
returns 1. Conversion stays inside the selected case, which transfers its
owner to the caller. The caller borrows the result for length and then drops
its owner. Arm-local bindings, aliases and reassignment follow the same value
rules as straight-line code; [the cleanup companion](test/e2e/fixtures/match_string_cleanup.brp)
returns its original alias after replacing a local and dropping unused Strings.
The function's parameters and prefix before the match must remain unmanaged.
Managed outer dependencies, nested/non-tail matches and joins are deferred.

From the repository root:

```sh
make                            # Build the existing compiler first.
make -C blorp_2 example          # Compile the example to C, build it, run it.
make -C blorp_2 test             # Run the Blorp TestSuite tests.
```

`example` keeps its generated C and executable in `blorp_2/build/` for
inspection. The tests use temporary directories. `BLORP_CC` selects a C
compiler executable (default `clang`).
To run only end-to-end tests, use `bin/blorp test blorp_2/test/e2e` with the
command's default timeout.

Each end-to-end run builds the pilot at the beginning: the host compiler
generates `build/compiler.c` once, then the C compiler links one `-O0` executable
with allocation diagnostics enabled. Its executable path is passed
explicitly to every test group. Build failure stops the run before any fixture
executes. Existing artifacts are overwritten on the next run; there is no
persistent compiler cache or input manifest. For manual inspection,
`make -C blorp_2 test-compiler` performs the same unconditional build; it is
not a prerequisite for running the tests.
[`test_end_to_end.brp`](test/e2e/test_end_to_end.brp) is the sole e2e test
entrypoint; the other case modules provide groups to it and are not standalone
runnable suites.
Each fixture owns fresh temporary output and one measured compilation, followed
by a native `-O0` build and execution under UBSan. Allocation and instruction
counters come from the same compilation. These checks never reuse fixture output.

Every host-compiled source module has a matching unit suite under `test/unit/`.
The temporary target prelude is an explicit source input, not a host module.
Integration
and native execution suites live under `test/e2e/`; their input programs live
under `test/e2e/fixtures/`. The suites use the existing compiler's `TestSuite`
API and run with `bin/blorp test --suite`; the example
fixture is not a test entrypoint. The host test API uses tuple-based test
registration. The compiler source under `src/` stays within the agreed subset.

Direct C unit tests of the target String runtime live under `test/runtime/`,
with Blorp `TestSuite` orchestration. Run them with
`bin/blorp test blorp_2/test/runtime`. They compile the same runtime fragment
used by emission at `-O0` with ASan/UBSan. Small test-local allocator wrappers
observe actual allocation/free calls; production runtime code has no test mode.
Generated unit-test code uses the host command's default `-O0`; omit `--release`
for development tests. Sanitizer builds also use `-O0`.

Each executable example defines allocation and instruction ceilings in its
end-to-end test. The test prints actual costs and ceilings, then fails when a
ceiling is exceeded. Ceilings are adjusted deliberately with retained evidence.

| Example | Allocation ceiling | Retired-instruction ceiling |
| --- | ---: | ---: |
| return_zero | 800 | 40,000,000 |
| call_one | 1,000 | 40,000,000 |
| pure_calls | 1,300 | 40,000,000 |
| nested_calls | 1,500 | 40,000,000 |
| nested_order | 1,600 | 40,000,000 |
| ufcs_calls | 1,500 | 40,000,000 |
| ufcs_chain | 1,600 | 40,000,000 |
| return_42 | 800 | 40,000,000 |
| union_values | 4,000 | 40,000,000 |
| match_value | 5,000 | 100,000,000 |
| bindings | 10,000 | 100,000,000 |
| mortal Strings | 20,000 | 200,000,000 |

Small companion fixtures pass explicit limits of 10,000 allocations and
100,000,000 instructions. The two structural stress fixtures use explicit
limits of 100,000 allocations and 500,000,000 instructions. They reuse the
same single-compilation measurement path as the primary examples.

The multiple-argument increment deliberately raises only `union_values` from
3,600 to 4,000 allocations. Its frozen baseline uses 3,574 allocations and the
candidate uses 3,641 (+1.87%); matched instruction medians increase 0.50%.
The 40-million instruction limit is unchanged. Removing redundant parameter
type copies and temporary traversal lists reduced the initial overhead; further
special cases to recover the remaining 41 allocations are not justified.

Historical matched `-O2` measurements of ordered-value lowering increased
allocations on the ten frozen prior inputs
by at most 28.3%; matched instruction minima increased by at most 1.21%.
The current union example additionally calls its helpers and matches a result
from `main`; its larger workload measured 2,082 allocations. The binding
increment deliberately raises the affected allocation ceilings above those
measurements. The later switch to a single instrumented `-O0` run rebases the
small fixtures' instruction ceilings to 40 million; allocation ceilings stay
unchanged at that increment. The explicit input prelude and independent ownership
verification now raise the affected allocation ceilings deliberately: return zero
measures 623 allocations, including 424 for prelude processing and 33 for ownership
insertion/verification in a phase-prefix probe. All 43 frozen prior fixtures emit
identical C; the final matched instruction sample grows by at most 13.00%. See the
[managed String record](../benchmarks/results/blorp_2_managed_strings_2026-10-09.md)
for the straight-line comparison and limitations, the
[tail String record](../benchmarks/results/blorp_2_tail_strings_2026-10-09.md)
for branch ownership costs and unchanged C, and the
[binding increment record](../benchmarks/results/blorp_2_bindings_2026-10-09.md)
for matched workloads, provenance, samples and validation.

Companion source fixtures expose individual behaviors through their real
`main` entrypoints. End-to-end tests compile them with the pilot and run the
unmodified generated programs. Exact full-width values and call order are
phase-test observations; process exit codes alone do not establish them.

These measure one execution of the new compiler on the example, including
process startup, argument handling, input/output, and the compile pipeline.
Building the compiler with the existing compiler, compiling the emitted C,
and running the generated program happen outside the cost measurements.
Allocation counts cover Blorp-managed ARC objects and require zero leaks.
The `-O0` pilot runs once per fixture with strict allocation diagnostics enabled;
macOS `/usr/bin/time -l` collects instructions for that same run. Instruction
counts include allocation bookkeeping and reporting. They are development-test
ceilings, and are not directly comparable to the historical minimum of three
uninstrumented `-O2` runs in the binding increment record.

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

## Generic function example

[`generic_identity.brp`](test/e2e/fixtures/generic_identity.brp) uses one
declaration with both unmanaged Int and managed String arguments:

```blorp
pure func identity[T](value: T) -> T:
    value
func main() -> Int:
    integer = identity(7)
    text = integer.to_string().identity()
    identity(text).length()
```

Its real `main` exits 1 with empty output. The Int instance returns directly;
the String instance borrows its parameter and acquires an owned return before
the caller releases the earlier String obligation.
[`generic_forward_string.brp`](test/e2e/fixtures/generic_forward_string.brp)
forwards through a second generic declaration and preserves the saved result
when its caller replaces the original String binding.

## Generic union example

[`generic_box.brp`](test/e2e/fixtures/generic_box.brp) wraps and matches an Int:

```blorp
fixed union Box[T]:
    Box(T)
pure func box[T](value: T) -> Box[T]:
    Box(value)
pure func unbox[T](value: Box[T]) -> T:
    match value:
        Box(payload):
            payload
func main() -> Int:
    unbox(box(7))
```

Its real `main` exits 7 with empty output. The union and each function own
separate rigid parameters. Specialization translates constructor and pattern
identities, payload bindings and calls together. Generic functions can also
receive concrete union values, including through direct calls and UFCS.

Written annotations admit one atomic argument, such as `Box[Int]` or `Box[T]`;
nested written `Box[Box[Int]]` is unsupported. Semantic calls can produce a
nested type, but `box(box(7))` fails when its outer payload specializes to a
union. Concrete payloads must be Int. Unsupported payload diagnostics point
to the written application or initiating call and note the payload declaration.
A phantom `Marker[String]` with no parameter payload remains valid, as does
`Tagged[String]` whose field is explicitly Int. Equal layouts retain distinct
nominal instance identities.


The [multiple-argument example](test/e2e/fixtures/generic_arguments.brp) adds
ordered runtime parameters while retaining one type parameter:

```blorp
pure func keep_first[T](first: T, second: T) -> T:
    first
func main() -> Int:
    keep_first(7, 9)
```

It exits 7. `value.keep_first(other)` supplies `value` first and `other`
second. Arguments evaluate left to right exactly once; lowering saves every
computed argument in an immutable local before emitting a C call. A helper
may return either borrowed String parameter as an owned result. The
[first String fixture](test/e2e/fixtures/generic_arguments_first_string.brp)
returns length 1 after replacement of the caller's old value; the
[second String fixture](test/e2e/fixtures/generic_arguments_second_string.brp)
returns length 3. Passing the same managed value twice preserves both borrows
through the call and drops its owner once after the result owner exists.


## Grammar for this increment

This specification defines only the examples' language: functions with explicit
return types, an ordered list of explicitly typed parameters, an optional single type
parameter on functions and fixed unions. Union variants have zero fields or
one field annotated `Int` or the union's own parameter; concrete fields
specialize to Int. A function
body has zero or more binding lines followed by a single expression or a tail
match with inline arm results or binding blocks. Expressions
start with a signed Int64 literal, a binding or variant name, or an application
with an ordered list of arguments. UFCS suffixes may follow that expression.
Arguments use the same expression grammar, so direct and receiver calls may nest.
No other declarations, expressions, literals, statements, or comments are supported.

[`grammar.ebnf`](grammar.ebnf) defines the complete restricted source grammar
and its EBNF dialect. Whitespace is explicit: LF is `"\n"`, TAB is `"\t"`, and
the header/body spacing and EOF rules are productions. Identifier rules
exclude the reserved spellings `func`, `pure`, `match`, `var`, and lone `_`.
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

- Every declaration header starts at column 1. A function has one header,
  optional binding lines, and a final expression line or tail match; a union
  has one header and at least one variant line. No blank
  lines precede, separate, or follow declarations. Exactly one LF separates declarations.
  The final line may end at EOF or with one LF.
- The entire indentation prefix uses tabs only or spaces in groups of four.
  Body and variant lines require depth one: one tab or four spaces. Match arms
  require depth two: two tabs or eight spaces. Arm-block lines require depth
  three: three tabs or twelve spaces. Mixed indentation is invalid;
  parsing rejects a valid depth in the wrong position. No indentation stack
  or synthetic dedent tokens are needed for this restricted layout.
- Spaces may separate tokens and trail each line. They are required between
  `func` and the function name, and between `fixed`, `union` and the type name.
  Identifiers are scanned as whole words, so
  `funcmain` is one identifier. The two characters of `->` are adjacent.
  Spaces may surround a UFCS dot and its parentheses, as in `1 . one ( )`.
  Tabs occur only in the indentation prefix. Each expression stays on one line,
  including match scrutinees, binding initializers and final arm results.
- `func`, `pure`, `match`, `var`, and lone `_` are reserved. The optional `pure` qualifier precedes `func`
  with spaces between the two keywords. Function, parameter and type names are
  identifiers whose meaning is checked after parsing.
- A function may declare one type parameter, as in
  `pure func identity[T](value: T) -> T:`. Its name starts with a capital ASCII
  letter and contains only ASCII letters and digits. Multiple type parameters
  and explicit function type arguments at calls are unsupported.
- `fixed union Type:` introduces one or more variants on indented
  lines. `fixed` and `union` are contextual header words and remain valid names
  elsewhere. A variant is bare or has one type-name annotation, as in
  `Number(Int)` or `Box(T)`. A union may declare one parameter with
  `fixed union Box[T]:`; payload annotations are `Int` or its own parameter.
  Function parameter and return annotations accept one atomic application,
  such as `Box[Int]` or `Box[T]`. Empty declaration parentheses, multiple fields
  and nested written applications are unsupported.
- `match expression:` starts a nonempty sequence of depth-two arms written
  `Pattern: expression` or `Pattern:` followed by a depth-three block of
  binding lines and a mandatory final expression. A pattern is a bare name,
  `_`, or a constructor name
  followed by parentheses containing zero or one field pattern. A field
  pattern is a binder or `_`; literal and nested field patterns are unsupported.
  A nullary constructor pattern may be written `Empty` or `Empty()`. `Number()`
  is valid syntax but fails semantic arity checking for a one-field constructor.
- A binding line is `name = expression` or `var name = expression`, at depth
  one in a function or depth three in an arm block. Its initializer occupies
  the same line. Function bindings precede the mandatory final expression or
  tail match; arm bindings precede a mandatory final single-line expression.
  Bindings inside arguments, annotations, and standalone expression statements
  are unsupported. An arm block cannot contain a nested match.
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
  takes zero or more explicitly typed parameters with distinct names. Helper parameter and return types
  are `Int`, the signed 64-bit integer type, `String`, or a fixed union declared in this
  file, including an application of a generic union, or the function's declared
  rigid parameter. `main` must return `Int`.
- Union types have nominal identity. Equal variant positions or shared variant
  spellings do not make two unions interchangeable. Union type names must be
  unique and cannot redeclare the prelude's `Int` or `String`; each union's variant names must be unique.
  Type names occupy a separate namespace from functions and variant values, so
  a function may share a type name. A function cannot share any variant name;
  a collision highlights whichever declaration appears later in the source.
- Function names are unique within the input file and cannot conflict with prelude
  functions. Every callee must be declared in that file or in the explicit
  prelude; declaration order does not affect resolution. Calls supply exactly
  the number of arguments the callee declares.
- A bare expression name first resolves to the nearest local binding: an
  arm capture, a body-local binding, or the containing function's parameter. Otherwise
  it resolves to a variant in the expected union: the innermost call's parameter
  type, or the containing function's return type when there is no enclosing call.
  Variants in different unions may share a spelling; expected type chooses the
  owner. `First()` is invalid because a payload-free constructor is a value;
  `Number(expression)` supplies the one `Int` field of a payload constructor.
  A name cannot refer to another function's parameter or denote a function value.
  A local binding shadows a same-named constructor or direct call; its established type
  is preserved, with no fallback to a constructor when that type is wrong.
  Arguments use the caller's scope, even when the callee has a parameter with
  the same spelling.
- `name = expression` declares an immutable binding when the name is absent,
  reassigns an existing mutable binding, and rejects an existing immutable
  binding. `var` declares a fresh mutable binding and may shadow a parameter,
  an arm capture, or a local from an enclosing block; redeclaring a local in
  the same block is rejected. The initializer sees the earlier
  scope, so `var value = value` can initialize from a parameter. New bindings
  infer their type from the initializer; reassignment checks the established
  type. Bare constructors need a receiving union type, supplied by a call,
  return or reassignment; a new local initializer does not guess that type.
  All initializers are checked for purity and call cycles, even when unused or
  in an arm a constant scrutinee cannot select. Arm locals stay within their
  arm. Reassignment of an enclosing mutable binding affects only the selected
  arm's computation; matches remain in the function tail.
- `receiver.function(arguments)` resolves its target from the file's declared functions,
  independently of parameter shadowing. The receiver still uses the caller's scope.
  A parameter named `identity` can therefore be read and passed to the declared
  function with `identity.identity()`; the direct call `identity(identity)` tries
  to call the parameter and is rejected. UFCS supplies the receiver first, followed
  by the explicitly written arguments. Every argument is evaluated left to right
  exactly once before the call.
- Each argument and final return expression must match its receiving type.
  Unary call-edge mismatches highlight the callee name; multiple-argument
  mismatches highlight the disagreeing argument occurrence;
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
- Generic declarations are checked once with a rigid type parameter, including
  unused bodies. An arbitrary `T` cannot return an Int literal or call a
  concrete Int/String runtime operation. Parameters cannot share a name with
  `Int`, `String`, or any declared union; separate declarations may reuse `T`.
  `main` and runtime prelude functions cannot declare type parameters.
  Direct and UFCS calls infer the sole type parameter consistently from every
  synthesized argument type. A later argument can determine it when an earlier
  parameter is concrete. Repeated occurrences, including structural `Box[T]`
  occurrences, must agree.
  Generic forwarding preserves the caller's rigid parameter until specialization.
  Expected return types never infer a generic substitution: `identity(First)`
  and `identity(Number(7))` reject even in a union-returning body. Pass an
  already-typed union value or call a concrete helper instead. A concrete
  nongeneric parameter still contextualizes constructors. Phantom parameters
  and zero-argument generic calls diagnose uninferable parameters; no default
  type is chosen. A parameter in a union argument, as in `unbox(Box[T])`,
  is inferred structurally from the complete synthesized argument type.
  Union instances are keyed by declaration and concrete argument; repeated
  direct/UFCS requests reuse the same instance. Layout admission rejects
  non-Int payloads before lowering, with application/request and payload spans.
- Each concrete function has its checked C return type and a generated symbol based
  on its compilation-local identity. `Int` uses `int64_t`; each union uses its own
  synthetic enum when all its variants are nullary. A payload-bearing union
  uses a distinct struct with an enum tag and one `int64_t` payload slot;
  nullary construction initializes that unused slot to zero. A separate C `int main(void)` wrapper calls
  the checked entrypoint and converts the result to the process exit status.
- The final expression is the return value. No explicit `return` is needed.
- `String` is an immutable managed leaf. The temporary input prelude supplies
  concrete pure functions `to_string(Int) -> String` and `length(String) -> Int`.
  Both direct calls and UFCS work. Parameters borrow for the duration of a
  synchronous call; String results transfer an owner to the caller, including
  results that alias a borrowed parameter. Unused mortal results are released.
  A tail-match arm may create, borrow, alias and return fresh arm-local Strings;
  unused and intermediate owners are dropped on that arm, and a String result
  transfers its owner. The function's parameters and binding/scrutinee prefix
  must remain unmanaged. String literals, String union payloads, managed outer
  dependencies, COW and joins are deferred.
- Parenthesized expressions,
  multiple or non-Int payload fields, nested matches,
  guards, qualified/nested/literal patterns, constructor UFCS, multiline chains,
  non-tail matches, multiple type parameters, and function
  values are outside this increment. `Bool` has no special treatment: a written
  `fixed union Bool` follows the ordinary union path, and an undeclared `Bool` is unknown.
  Imports and UFCS-only import visibility are deferred; every function in this
  input file is available to either call notation.
- Syntax and semantic errors carry a source location, an explanation, and help.
  Rejected source produces no C output and does not overwrite an existing output.

## Architecture

The command reads the temporary input prelude and a program, then writes C:

```sh
bin/blorp run --no-format blorp_2/src/main.brp -- blorp_2/src/prelude_temp.brp input.brp output.c
```

The impure command shell owns file I/O and printing. Compilation and
diagnostic rendering are pure. The pipeline publishes these complete results:

1. Lexing produces tokens with source spans and an explicit end-of-source span.
   Integer tokens retain their complete raw spelling; indentation tokens retain
   their depth and the entire prefix span.
2. Parsing produces function and union declarations, payload and parameter
   annotations, written names, ordered binding syntax, expression syntax, and structured match bodies.
   Match patterns preserve names and field syntax without deciding whether a
   bare name denotes a constructor or binding. Each expression has a literal,
   name, or direct application base with ordered recursive arguments, followed by
   receiver applications with ordered explicit arguments. Direct and receiver
   syntax stay distinct because their target lookup differs.
   Every expression records its consumed token span directly, without reconstructing
   locations from names or literal values.
   A local interning builder assigns one opaque `NameId` per spelling. Parsing
   seals the complete syntax and immutable name table in an opaque `ParsedProgram`.
   Integer conversion accumulates negatively against derived range cutoffs,
   checking before multiplication so even the minimum is represented safely.
3. Checking resolves nominal union and owned variant identities, then publishes
   one authoritative signature per function. A private resolution context holds
   the aligned declarations and signatures. Target resolution returns a complete
   call and signature after one lookup. Call boundaries prove complete arity once,
   check purity afterward, and publish transient contracts with every ordered
   parameter type and the result type. Checking infers one consistent substitution
   across all argument positions before validating every edge; they are erased to checked calls only after validation. Published function
   signatures remain the sole signature authority. Constructor operations are
   distinct from function calls and use the owning variant's declared field shape.
   Local reads carry a function-owned `BindingId`, distinguishing the parameter,
   body locals and each arm's binding. Binding definitions own type, mutability,
   origin (including each parameter's explicit signature position) and declaration span; typed expression occurrences retain their own
   spans. Match checking resolves patterns and result types,
   and establishes usefulness and exhaustiveness before publishing checked arms.
   Each arm publishes its ordered assignments and result. The current block's
   first local ordinal establishes which declarations belong to that block;
   semantic origin alone does not determine scope membership.
   Constructors retain their owning union and variant identities. Checking
   publishes an opaque program with its entrypoint identity. Call notation is erased
   after target resolution. A user call carries its checked substitution in its
   target variant; a runtime call cannot carry one. Rigid type parameters have
   explicit function-declaration or union-declaration owners.
   Checking returns either the complete `CheckedProgram` or an opaque
   `CheckFailure` retaining the original parsed program and a nonempty
   `CheckErrors` collection. The current checker stops at the first error, so
   that collection is a singleton. Failures contain closed semantic variants,
   types, owner-qualified identities, argument positions and source occurrences;
   temporary builders do not escape. `render_failure` separately produces every
   diagnostic using the same parsed name authority. The CLI preserves the entire
   rendered collection. Semantic unit tests inspect typed facts directly;
   renderer and pipeline tests pin wording independently. UFCS receiver mismatch
   occurrences retain the existing call-span limitation. Inference remains
   one-way; bidirectional checking and structural unification are later work.
4. Pure specialization expands instances from every ordinary function, preserving
   unused ordinary functions and unions. Generic declarations emit only when
   requested by those roots or another instance. One local instance list reuses
   equal declaration/type keys and distinguishes nominal union arguments. It
   translates complete signatures, bindings, values, calls, variants and matches
   without checking bodies or resolving names again, then seals a
   `SpecializedProgram`. Concrete types cannot contain type parameters; concrete
   function, union and variant identities have separate instance domains.
   Checked signatures retain one `TypeUse` per annotation, preserving its span.
   Concrete signatures belong to their separate immutable phase. Union instance
   keys preserve complete nominal arguments; checked occurrence types translate
   declaration-owned variants to the corresponding concrete union instance.
   Initiating call provenance is carried through generic forwarding and stays
   outside key equality. Unsupported payloads diagnose before lowering.
5. Pure lowering publishes a sealed program of ordered value definitions and
   distinct function-owned `ValueId`s. A local builder maps each `BindingId` to
   its current value. An alias uses the same value; reassignment updates that
   map after evaluating the right-hand side. Every computed value retains its
   type and source span. Match-arm computations remain in their branches.
   Every arm starts with the enclosing binding map, lowers its capture and
   binding sequence, and publishes a branch-local value block. Sibling arms
   share only the function's value allocator, preserving distinct identities.
6. Ownership insertion classifies each concrete value as having no ownership
   or being a managed String leaf. It publishes ordered definitions, owner
   acquisitions, drops and return transfers. `OwnerId` names one obligation;
   `ValueId` still names the computed value. Borrowed operands name the owner
   they depend on, or the exact borrowed parameter value identity. Last-use cleanup keeps
   an argument alive until a call has established its result owner. Tail-match
   arms publish the same ownership operations and typed return transfers as a
   straight-line block. Value and owner identities remain function-wide; sibling
   arms cannot observe each other's values or obligations.
7. Independent verification checks the actual operations against representation
   and call contracts, rejecting dead/wrong owners, invalid borrows and
   undisposed obligations. Raw ownership IR does not preserve checking's sealed
   match proof, so verification independently requires nonempty, exhaustive,
   useful arms with valid unique variants and at most one final default.
   It also enforces the zero-argument Int entry ABI, rejects managed match
   prefixes and checks each arm's owner discharge/transfer independently.
   Only it can seal a
   `VerifiedProgram`; it neither repairs ownership nor uses insertion's
   liveness decisions as its oracle.
8. Emission consumes that verified program and produces C. Computed values use
   immutable C locals; scalar reassignment requires no runtime mutable cell.
   A match uses its evaluated scrutinee once and switches on its tag. Arm-local field
   projections occur only in the selected branch; a whole-value binder reads
   the saved value. Emission consumes resolved lowered labels and values without repeating
   resolution, arity, purity, or coverage checks. Its result can report an
   internal lowered-reference error instead of silently choosing a C layout;
   source-language acceptance is already complete. Retains/releases project the
   explicit operations; emission does not invent owners or cleanup.

The names module owns the spelling table and constructs the entrypoint's `main`
identity. Prelude declarations establish `Int` and `String` before program
parsing extends the same table. Parsing uses string lookup only in its local interning
builder, then publishes the immutable table and special identities together.
Written names contain only a `NameId` and source span. Checking compares identities;
spelling lookup is reserved for diagnostics and rejects a missing table entry
as an internal compiler error. IDs are meaningful only within their owning
parse and table; equality and lookup do not validate table ownership. Only the
parser can construct the sealed program that checking accepts. `FunctionId` remains a separate
nominal identity assigned in declaration order. Checking retains call spans;
`UnionId` identifies a declared type and `VariantId` records both its owner and
variant position; neither is interchangeable with a `NameId` or `FunctionId`.
`BindingId` identifies a function-local parameter, body local or arm binding independently
of spelling; reusing a spelling in sibling arms creates distinct bindings.
Specialization retains those source occurrence IDs, qualified by each concrete
instance's complete translated binding table. Equal raw IDs across instances
are not comparable; downstream readers never fall back to the checked table.
`ValueId` identifies a lowered computed value within its function, separately
from the source binding that currently refers to it. Emission uses resolved
identities and typed operations. Integer and
union programs with optional Int fields need no target heap allocation or RC operations.
Recursive direct arguments and postfix receiver calls remain single-line values.
A structured body sum distinguishes that leaf from a match with ordered arms.
Managed control-flow joins and general pass infrastructure remain future work.

[`src/prelude_temp.brp`](src/prelude_temp.brp) is a target source input, not a
host import. Its `type Int = builtin` and `type String = builtin` declarations
establish the two builtin types. Its concrete functions use the closed runtime
keys `builtin("int.to_string")` and `builtin("string.length")`. Prelude parsing
translates those keys to typed operations once; checking validates their exact
purity, parameter and result contracts. Program source cannot declare builtin
types or bodies, and quoted builtin labels do not enable ordinary String
literals. Prelude and program diagnostics retain separate source origins.
There is no general module loader or implicit prelude lookup.

C emission uses the whitespace required to separate C tokens and a final LF.
It adds no indentation or internal line breaks for presentation.
Nonnegative literals use `INT64_C`; negative literals negate a representable
positive magnitude. The minimum uses `<stdint.h>`'s `INT64_MIN`, avoiding an
unrepresentable positive magnitude. The new
[`return_42.brp`](test/e2e/fixtures/return_42.brp) example exits 42. Parser and
emitter phase tests check full-width endpoint values and their C projection.
Native fixtures run their normal `main` functions under UBSan. These native
exit-status checks do not prove full-width equality because the platform
truncates process status.

The lexer shares token/diagnostic construction and byte-run scanning helpers.
Their local work is separate from collecting tokens and advancing the cursor.
The cleanup reduced formatted lexer source from 219 to 202 lines. Indentation
and ordinary scanning use exclusive branches, keeping each byte slice's
lifetime within the path that uses it. Exact token/diagnostic unit tests and
leak checks protect this boundary. The cost record also retains the separate
25,000-call lexer experiment; that total is different from one compilation's
end-to-end cost. Self-compilation is a later milestone.

## Bootstrap direction and process

[MEMORY_PLAN.md](MEMORY_PLAN.md) records the managed String slice and proposed
later memory responsibilities, including the limits of current verification.

Compiler source under `src/` stays within the agreed eventual subset: `String`, `Int`
(64-bit), `Float` (64-bit), `Bool`, `Void`, `List`, `Option`, `Result`, `Dict`,
`Set`, records/unions and their fixed spellings, opaque types, generics,
purity, matching, loops, `var`, `?=`, imports, and UFCS. Supporting every one
of these in input programs is future work, not a claim about this increment.

Concurrency, parallelism, tensors and dimension types, tuples, `debug:`, other
numeric widths, traits, doctests, channels, and FFI are excluded. Compiler tests
are written in Blorp; the target runtime has explicitly approved C unit tests
run by Blorp `TestSuite`. Build commands may use Make and the C toolchain.

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
entrypoint. Local topological elimination checks all base and wrapper call edges,
including every recursive argument and binding initializer;
no persistent graph registry is needed. Each checked function retains its validated
signature beside its resolved body. Emission reads only validated
facts and does not recheck purity or name scope. C function and parameter names are
synthetic, and unused parameters are explicitly discarded to keep warning checks
clean. Existing compiler internals are not pilot dependencies.

The compilation pipeline is entirely pure once its source inputs have been
loaded. `compile(CompilationInputs{prelude, program})` composes pure lexing,
parsing, checking, specialization, ordered-value lowering, ownership insertion,
independent verification and C emission;
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
