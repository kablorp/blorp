# Blorp 2

A new compiler written in Blorp that emits C. Each increment starts with a
small program, defines the grammar it needs, and tests that program through
native execution. It can compile itself. `make -C blorp_2` uses the verified,
digest-pinned Blorp 2 seed as its production builder. Unit, runtime and grammar
suites continue using the legacy TestSuite host.

The combined integration implements pure lambdas with immutable captures,
structural patterns, value conditionals and managed source loops. The target
library includes the temporary concrete helpers described below. Focused
functional results are supplemented by an actual self-compilation: all 43
compiler source modules emit C, that C links, and the resulting compiler emits
byte-identical C from the same source and library. The [self-compilation
report](../benchmarks/results/blorp_2_self_compiled_bootstrap_2026-10-20.md)
records the proof and matched build costs. Full fixture parity, native-suite
and resource acceptance remain separate; measured cost failures stay recorded.

The [module and prelude sections](#local-modules) define explicit
type/method visibility and a shared base/prelude for the target
[standard library](standard_library/README.md) at `blorp_2/standard_library`.
Its syntax and layout are implemented in this pilot.
The target library provides generic pure Option `is_some`, `is_none`, `get_or`,
`to_result`, `map` and Result `is_ok`, `map`, `map_err`, `and_then` through explicit
imports. Default/error arguments are eager. The four callback helpers accept pure
named functions, lambdas and forwarding, invoke once only in the selected branch, and
preserve the other variant/payload. Returned managed values remain independently
owned. See the [API contracts](standard_library/README.md); compiler-source imports
remain separately tracked from callable admission and capture conversion.

Current language examples and limits are below; [grammar.ebnf](grammar.ebnf)
owns the formal syntax. The [roadmap](ROADMAP.md) owns planned increments,
immutable-fact and ownership contracts, and required validation. It consolidates
the earlier memory, aggregate, generics and recursion plans.
The compiler-source subset is governed by [AGENTS.md](AGENTS.md); source
convenience does not remove currently supported input features.

Concrete, authored traits are supported as described in [concrete traits](#concrete-traits).
Function bounds, full generic receiver families, default methods and contextual
method references extend that surface. Automatic equality for nongeneric named
records and unions is complete; its [qualification report](../benchmarks/results/blorp2-derived-equality-2026-10-23.md)
records proof and costs. The [Equatable-first trait plan](TRAITS_PLAN.md) owns
remaining generic automatic equality and library migration, together with phase
boundaries and acceptance gates.

The [incremental layout migration](LAYOUT_MIGRATION.md) defines the proposed
physical-layout model, staged replacements, code examples and cost gates.
Implementation starts after CI/bootstrap repair and the bounded test migration.

Completed increment plans and handoffs are retained in Git; validation reports
remain under [benchmarks/results](../benchmarks/results/). Historical research
is available in the committed designs for
[pattern matching across Haskell, OCaml, Rust, Scala and Elm](https://github.com/kablorp/blorp/blob/4b05ea3b431d9fbe4e906a0802bd41060b6f397f/blorp_2/MATCH_PLAN.md#cross-language-implementation-references),
[module identities and visibility](https://github.com/kablorp/blorp/blob/4b05ea3b431d9fbe4e906a0802bd41060b6f397f/blorp_2/MODULES_PLAN.md#established-implementations-and-the-bounded-choice),
and [guaranteed tail calls](https://github.com/kablorp/blorp/blob/4b05ea3b431d9fbe4e906a0802bd41060b6f397f/blorp_2/TAIL_RECURSION_PLAN.md#established-precedents-and-deliberate-choices).

The [scaffolding cleanup report](../benchmarks/results/blorp_2_cleanup_2026-10-12.md)
records explicit unit inputs, reachable specialization, the slim target library,
matched costs and validation limits. Its measurements supersede earlier cost
examples for this implementation; older increment reports retain their history.

## Concrete traits

A trait declares pure method signatures using the implicit type `Self`. Each
method's first parameter must have exactly that type. A signature without a
colon is abstract; a colon introduces an ordinary default body. An omitted
return annotation means Void, as for ordinary functions.

```blorp
trait Equatable:
	pure func equals(left: Self, right: Self) -> Bool

implements Equatable for Int:
	pure func equals(left: Self, right: Self) -> Bool:
		builtin("int.equals")
```

The configured prelude's ordinary `Equatable` binding selects the canonical
trait identity, including when imported from a library module. Without that
binding, no trait is canonical. The selected trait has `equals` as its sole abstract
requirement; additional pure methods need defaults. Implementations define every
abstract method with matching parameter, result and purity contracts. They may
override defaults; omitted defaults use the trait definition's lexical scope.
Default bodies and authored bodies are ordinary checked functions, including
unused bodies. A default-only implementation ends after its receiver, without
a colon or an empty indented block. A module
must own the trait or receiver declaration. A library operation module may
also implement a foundation trait for a foundation receiver. The same allowance
applies to the selected canonical trait when its declaration belongs to an
actual library module; unrelated library traits gain no such permission.

Method names denote trait families. Importing `int: equals` makes that family
available for every receiver with an accepted implementation, including custom
records; the import does not fix `Self` to Int. UFCS and module-qualified calls
use the same family. Trait declarations also introduce their families, while
implementation bodies are never independent free-function offers. Multiple
routes to one family coalesce; different families or a free function with the
same name need an alias or renamed declaration. A type's `methods_only` route
requires the provider to own a written implementation for that receiver head.

Function type parameters declare their required traits with `:` and combine
bounds with `+`. Each generic body is checked once against those declarations;
future callers never supply a missing bound. Receiver families introduce every
parameter directly after their named head, using distinct fresh names:

```blorp
trait Visit:
    pure func visit(value: Self) -> Int
    pure func repeated(value: Self) -> Int:
        visit(value)

fixed record Box[Element] { value: Element }

implements Visit for Box[Element: Visit]:
    pure func visit(value: Self) -> Int:
        visit(value.value)

pure func forward[Value: Equatable + Visit](value: Value) -> Int:
    repeated(value)
```

A concrete default-only header is written `implements Observe for Shape` on its
own line when every method has a default. A complete family such as `Box[T]`
applies to that entire nominal head. Bounds do not distinguish overlapping
implementations; a failed bound never selects another implementation. Partial,
concrete-argument or nested receiver patterns are rejected.

A method family can be an ordinary function value when an expected callable
contract determines `Self`, for example `callback: pure (Int) -> Int = visit`
for a visible one-argument family `visit`. Typed callback arguments, stored
callables and returned callables use the same rule. Without sufficient context,
the diagnostic asks for a callable annotation or a typed callback parameter.
Invoking these values follows ordinary purity, capture and ownership rules;
operands evaluate once in written order.

The existing finite-instantiation check includes trait calls and method-value
creation before specialization. Its constructor-depth proof is conservative:
it can reject a finite `Box` to `Wrap` relay or a generic field containing three
nested Lists with `cannot prove finite generic trait instantiation`. These are
explicit temporary limits; ordinary deeply nested field dispatch must be
closed before the structural-equality milestone can complete.

Traits remain parameterless, with no independently generic methods, impure
requirements or top-level callable formals. Record/union
declaration bounds remain deferred. Traits are separate from value types, and
`Self[Int]` cannot apply scoped `Self`; qualified module type names retain their
normal meaning. Check validates contracts and bound obligations once, then
Specialize selects ordinary bodies through the existing instance graph. No
trait representation reaches lowering, ownership or emission.

The [concrete fixture](test/e2e/trait_inputs/concrete/main.brp) supplies its own
[isolated library](test/e2e/trait_inputs/concrete/library/) and returns 23 for
`equals(7, 7)`. These inputs live outside the ordinary fixture scan and require
an explicit `--library-root`. The production library continues to use its
existing concrete APIs until the later library migration. Compiler source
continues to obey the separately pinned [bootstrap subset](AGENTS.md).

## Automatic equality for nongeneric aggregates

With the designated foundation's canonical `Equatable`, a nongeneric named
record or union supports equality when every actual field or payload supports
it. Both fixed spellings use the same rule. No annotation or implementation
block is needed. The method family must still be visible through ordinary
imports. Automatic capability does not publish operation names: importing an
automatically supported type, including Bool through the prelude, does not
implicitly import `equals`
or its defaults. A written implementation may offer the family through the
ordinary type/methods_only route. An unrelated trait spelled `Equatable` does
not enable automatic equality.

```blorp
fixed record Point { x: Int, y: Int }
fixed union Reply:
    Empty
    Value(Point)
```

Record fields compare in declaration order and stop at the first False. Union
tags must agree before payloads compare in order; a payloadless matching case
returns True. Logical Void fields and payloads still call their written equality
implementation even when their storage is erased. NaN remains unequal to itself;
there is no same-object or pointer shortcut. Empty record and union declarations
remain outside the accepted grammar.

Written implementations replace automatic equality for their whole receiver
head. An enclosing aggregate calls the selected written implementation, including
its declared conditions; failed conditions never fall back to structural equality.
Ground fields may therefore use ordinary conditional families such as
`Custom[Int]` requiring `Int: Visit`, without inventing an Equatable requirement
for an unused type argument. Recursive nongeneric Tree/List and mutual aggregate
dependencies close only after all outgoing member requirements succeed.

An unused declaration with a callback or otherwise unsupported member remains
legal. Equality use reports the actual unsupported field or payload annotation.
Generic aggregate heads, including phantom heads, require a written full-family
implementation for now; their automatic equality is the open T4b increment.
Tuples, opaque types and callable values receive no automatic implementation.
A prelude without the canonical Equatable binding creates no automatic equality bodies.

Derived methods use ordinary direct calls, defaults and contextual callable
references through the existing specialization graph. Only reachable bodies
emit code; no trait representation reaches lower phases. The production target
library retains its existing APIs. T5 must qualify and pin a seed supporting
this declaration-location rule before moving its canonical trait and implementations.

## First example

[`test/e2e/fixtures/return/zero.brp`](test/e2e/fixtures/return/zero.brp):

```blorp
func main() -> Int:
	0
```

The executable returns exit status 0 with empty stdout and stderr. This first
example needs no imports, builtin functions, or target runtime.
The next example adds a call to a zero-argument function:

[`test/e2e/fixtures/call/one.brp`](test/e2e/fixtures/call/one.brp):

```blorp
func main() -> Int:
	one()
func one() -> Int:
	1
```

The executable returns exit status 1 with empty stdout and stderr. A helper
may appear before or after its caller. Local selective imports and concrete
String printing are supported.

The third example, [`test/e2e/fixtures/pure/calls.brp`](test/e2e/fixtures/pure/calls.brp),
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

The fourth example, [`test/e2e/fixtures/nested/calls.brp`](test/e2e/fixtures/nested/calls.brp),
adds one explicitly typed parameter and a nested call:

```blorp
pure func one() -> Int:
	1
pure func identity(value: Int) -> Int:
	value
func main() -> Int:
	identity(one())
```

It exits 1 with empty stdout and stderr. Helpers may take any number of typed runtime parameters; this example's `main` takes none. A call may pass one complete expression, including
another call. The companion [`nested/order.brp`](test/e2e/fixtures/nested/order.brp)
returns `zero(one(1))`, with both helpers ignoring their parameter. Its exit status
0 and exact generated C distinguish the order of the two calls.

The UFCS example, [`ufcs/calls.brp`](test/e2e/fixtures/ufcs/calls.brp), calls the
same helpers with `one().identity()`. This is equivalent to `identity(one())`
and exits 1. A receiver supplies the first argument; explicit arguments in the method's
parentheses follow it. The companion
[`ufcs/chain.brp`](test/e2e/fixtures/ufcs/chain.brp) demonstrates chaining:

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

The [`union/values.brp`](test/e2e/fixtures/union/values.brp) example adds
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
can take and return the declared union; `main` returns `Int` or `Void`. Source
fixtures select variants through their ordinary `main` functions and match
the results to observable exit statuses. The host TestSuite orchestrates pilot
compilation, builds the unmodified C output and checks each executable.

The match example, [`match/value.brp`](test/e2e/fixtures/match/value.brp), adds
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
A whole-arm name must select a visible constructor of the matched union.
`_` is the whole-arm wildcard; a bare name never binds the whole value; an arm that needs the whole value reads
the scrutinee binding. Matches require exhaustive, useful arms.
The scrutinee runs once and only the first matching arm's result runs.

Patterns compose recursively: `Some(Some(value))`, constructor alternatives
such as `Left(item, _) | Right(_, item)`, exact Lists such as `[first, second]`,
and prefix Lists such as `[first, ...remaining]`. Alternatives must bind the
same names at identical semantic types, even when their field positions differ.
A successful alternative enters one shared arm body. A captured List suffix
owns a fresh ordinary root and its retained elements; `..._` constructs no suffix.
String patterns compare the complete decoded UTF8 byte sequence, including NUL;
`"é\0x"` differs from `"é"` and `"é\0y"`. All patterns retain exhaustive,
useful, first-match semantics. [Structural pattern fixtures](test/e2e/fixtures/pattern/)
exercise nested fallthrough, aliases, suffixes and binary output through `main`.

The companion [`match/values.brp`](test/e2e/fixtures/match/values.brp) covers
whole-value and field preservation; the separate
[`match/shadow.brp`](test/e2e/fixtures/match/shadow.brp) preserves an outer
parameter alongside a distinct field capture. Small
source fixtures expose these behaviors through `main`; exact full-width
values and evaluation order are checked directly at phase boundaries.
Pattern captures are immutable. The pilot enforces these name rules; the
frozen host compiler keeps its existing shadowing and whole-arm capture behavior.

The [bindings example](test/e2e/fixtures/binding/basic.brp) adds a prefix of local
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
bindings. The [binding report](../benchmarks/results/blorp_2_bindings_2026-10-09.md) records phase validation;
the [companion fixture](test/e2e/fixtures/binding/values.brp) instead returns
the reassigned current value, 42. Separate small fixtures cover self-assignment,
parameter initialization and union values. Phase tests check exact full-width values
and evaluation order.

An `if` can be a function's returned value, a binding initializer, a condition,
or an arm's final value. Its condition has the designated `Bool` type and runs
once; only the selected branch runs. With an expected result type, both branches
receive that type. Otherwise the then branch determines the result type and
the else branch must match it. Branch-local bindings remain local; assignments
to enclosing variables continue through the ordinary join's carried bindings.

The [value-if fixture](test/e2e/fixtures/value_if/answer.brp) initializes an
`Int` with `if flag: 41 else: 0` and returns 42. Without `else`, an `if` yields
`Void`: its then block must be Void or end with a statement. Inferred and
annotated Void bindings are permitted. A Void function's final if with both
branches discards each selected result, as a final match does. Controls nested
in call arguments, record fields or list elements remain unsupported; bind the
control's result first. Boolean keyword operators and nested `?=` remain
unsupported.

Bindings also compose with match arms. The
[arm-binding example](test/e2e/fixtures/match/binding_original.brp) returns 7:

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

An arm block contains zero or more binding or Void expression statements and a final expression,
indented deeper than its pattern. An inline arm holds one value, or one
statement (`None: failure = Some(error)`), as in the host; a statement arm
has no value, which a tail match rejects. Inline and block arms can coexist.
Each arm has its own scope; sibling arms can declare the same fresh name. An
explicit `var` cannot hide an enclosing binding; its initializer may read that
binding to initialize a distinct local. Ordinary `=` still reassigns the nearest mutable binding or rejects
assignment to an immutable one. Companion fixtures return the
[updated value](test/e2e/fixtures/match/binding_current.brp), exercise the
[other branch](test/e2e/fixtures/match/binding_empty.brp), and preserve an
[outer value](test/e2e/fixtures/match/binding_outer.brp) alongside arm-local mutation.

The [mortal String example](test/e2e/fixtures/mortal_string/basic.brp) starts the
managed path without literals, traits or general imports:

```blorp
func main() -> Int:
    value = 7.to_string()
    value.length()
```

It returns 1. The default prelude selects concrete pure
`to_string(Int) -> String` and `length(String) -> Int` functions. Conversion
allocates an immutable String leaf; length borrows it; its owner is released
after that use. The [identity companion](test/e2e/fixtures/mortal_string/identity.brp)
returns a borrowed parameter as an owned result before replacing the caller's
old owner. Other fixtures cover unused results, a surviving alias, and Int64
conversion boundaries. These operations use ARC; they introduce no COW or reuse.

The [tail String example](test/e2e/fixtures/match/string_second.brp) returns a
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

It returns 2; the [First companion](test/e2e/fixtures/match/string_first.brp)
returns 1. Conversion stays inside the selected case, which transfers its
owner to the caller. The caller borrows the result for length and then drops
its owner. Arm-local bindings, aliases and reassignment follow the same value
rules as straight-line code; [the cleanup companion](test/e2e/fixtures/match/string_cleanup.brp)
returns its original alias after replacing a local and dropping unused Strings.
Borrowed managed parameters and locally owned values are admitted before an
ordinary terminating tail match. Each selected arm either transfers a returned
prefix owner or drops it after securing the result. Prefix roots and acquired
projections remain alive through the selected arm; sibling arms share no local
obligations. The [owned-prefix examples](test/e2e/test_owned_prefix.brp) cover
aliases, reassignment, projected payloads and selected-arm effects.

A match that is not the function's tail is a join: the function continues
after it with the value its selected arm yields.
[`join/bound_int.brp`](test/e2e/fixtures/join/bound_int.brp) binds one:

```blorp
pure func width(shape: Shape) -> Int:
	w = match shape:
		Circle(radius): radius.multiply(2)
		Square(side): side
	w.add(1)
```

The first arm's value decides a bound match's type (a reassigned `var`
decides it instead), and every later arm is checked against it. A statement
match is Void: each arm's value must be Void, and an arm may end with a
statement instead. A match whose position expects a type, such as a tail
arm's, checks every arm against it. At a Void function's tail, a nested
match discards each arm's value, as a plain Void tail does. A bare match as
an arm's value is a nested join; in a `@tail_recursive` function a self call
there remains unsupported by annotated tail-call admission. An arm may reassign a visible
`var`; the code after the join sees the selected arm's final value, or the old
value on an arm that leaves it unchanged. Older immutable aliases keep their
values. A match nested inside a
larger expression, such as a call argument, must be bound first. Each yielding
arm moves its value into the join: a managed value moves an owner made in its
arm, so a yielded prefix value is acquired again, and owners live before the
join stay live through every arm and are dropped after it at their last use.
With carried variables, every managed outgoing occurrence acquires its own
obligation before arm-local sources retire; enclosing owners stay live.
In C the join's outputs are locals declared before selection and assigned in each
shared arm body. The [join examples](test/e2e/test_join.brp) include sixteen
nested bound matches.

From the repository root:

Blank lines and `--` single-line comments are accepted in pilot fixtures.
Format host compiler/tests separately: the host formatter also supports syntax
outside this pilot's restricted grammar.

```sh
make                            # Build the existing compiler first.
make -C blorp_2 example          # Compile the example to C, build it, run it.
make -C blorp_2 test             # Run the Blorp TestSuite tests.
```

`example` keeps its generated C and executable in `blorp_2/build/` for
inspection. Host suites use temporary directories; the target component gate keeps
its C and executable in `blorp_2/build/self-hosted-tests/`. `BLORP_CC` selects a C
compiler executable (default `clang`).
`make -C blorp_2 test-compiler test-components` runs the complete component
gate: the temporary existing-compiler host runs the unit/runtime/grammar
roots, then Blorp 2 runs the explicit `TARGET_COMPONENT_SOURCES` in the Makefile.
The selection currently covers text, Boolean calls, constant/declaration IDs,
IntMap, names, source identities and syntax publication, plus Lexer token traces,
float boundaries, keyword roles, source origins, character literals, continuation,
doc fences, ranges, lexical trivia, pipe Strings and runtime-text round trips.
Parse coverage includes constant inventories, source provenance, and String,
integer, Float and file builtin labels. The selection has 27 suites with 188
active cases. Each selected suite uses its ordinary
`tests: TestSuite` entry; generated C and executables mirror its source path
under `blorp_2/build/self-hosted-tests/`.

Twelve Lexer cases are explicitly deferred in source comments: eleven bracketed
block cases need `String.split`, and one pipe String case needs a byte-input
boundary for invalid UTF-8. Their original inputs and assertions remain beside
the TODOs. Deferred cases receive no PASS credit; the empty bracketed-block suite
is not in the target selection. Other untranslated suites retain the temporary
host until they can be ported without new library work or large refactors.

`test-components BLORP2_COMPILER=PATH` uses an already-built compiler without a
fallback. To run just the target selection, use:

```sh
make -C blorp_2 test-target-components BLORP2_COMPILER=PATH
```

This target does not build or use the legacy host. Compilation, native linking,
failed callbacks and strict leak failures all fail the target; an empty source
selection is an error. The host run also discovers these suites, but their
separate target execution remains required for the complete component gate.

The explicit compile-only test entry is:

```sh
blorp_2/build/compiler --library-root blorp_2/standard_library --test-suite \
  blorp_2/test/unit/test_utils/test_text.brp blorp_2/build/test_text.c
```

The root scope's visible `tests: TestSuite` constant (including an explicit
import) must have the configured library's `TestSuite` type. The
compiler-owned entry calls the ordinary library runner and returns 0 when
its actual `TestCounts.failed` is zero, otherwise 1. It follows normal
checking, specialization, ownership insertion, independent verification and
emission. This mode neither discovers directories nor links/runs C; the
component gate links and runs that output with strict memory checking.
The target `test` module defines
`TestSuite { description: String, tests: List[(String, () -> Bool)] }` and
`TestCounts { passed: Int, failed: Int }`. `run_suite_result` prints and returns
counts; `run_suite` accepts the suite value and derives the exit status.
Case callbacks may be pure or impure; execution follows registration order and
continues after a failed callback. Empty suites succeed. Suite constants use
ordinary closed initializers; inline lambda entries remain unsupported.
The [existing text suite](test/unit/test_utils/test_text.brp) is the first example.

To run only end-to-end tests, build the pilot and run the suite against it:

```sh
make -C blorp_2 test-compiler test-e2e
```

The host test runner's default 30-second deadline applies to the entire
generated suite, including every fixture. End-to-end runs disable that
deadline. `make -C blorp_2 test` runs e2e separately with `--timeout 0`; the
other suites retain their 180-second deadline.

`test-compiler` builds the pilot once: the pinned Blorp 2 seed generates
`build/compiler.c`, then the C compiler links one `-O0` executable with
allocation diagnostics enabled. `test-e2e` names that executable on the
suite's command line through the Makefile variable `BLORP2_COMPILER`
(default `blorp_2/build/compiler`), and the harness passes it explicitly to
every test group; the harness has no default and rejects a missing or unset
compiler with an exact message. Build failure stops the run before any fixture
executes. Existing artifacts are overwritten on the next run; there is no
persistent compiler cache or input manifest. To test another executable, pass
the variable: `make -C blorp_2 test-e2e BLORP2_COMPILER=path/to/pilot`
(relative to the repository root).

CI's Blorp 2 lanes run on Linux x64 and ARM64 with Clang, Linux x64 with GCC,
and macOS with Clang. Each waits for the matching existing compiler's build
and restores that temporary TestSuite host artifact. It builds the pilot once
from the pinned Blorp 2 seed, runs `test-components`, then `test-e2e` against
that pilot. Hosted runners do not guarantee
the required retired-instruction counters, so that CI step explicitly sets
`BLORP_2_INSTRUCTION_CHECK=disabled`. Allocation caps, strict leak reports and
all native ASan/UBSan cases still run. Failures upload their test logs. Clang
platform jobs package release binaries only after their test lanes pass.
Clang and GCC builds have separate caches and artifacts. The macOS lane also
runs the compiler-comparison tooling suite, whose command requires macOS
`/usr/bin/time -l` and does not support Linux.

[`test_end_to_end.brp`](test/e2e/test_end_to_end.brp) is the sole e2e test
entrypoint; the other case modules provide groups to it and are not standalone
runnable suites.
Each fixture owns fresh temporary output and one measured compilation, followed
by one strict C11 native `-O0` build under ASan and UBSan. Explicit native cases
reuse that binary with explicit argument vectors, byte stdin and exact exit status, stdout and stderr
assertions. Every example has a first case and a list of remaining cases;
existing examples have one case. Failures identify the case and mismatched
channel, with output shown as hex so embedded NUL and UTF-8 bytes remain visible.
By default, `BLORP_2_INSTRUCTION_CHECK` is `required`: allocation and retired-
instruction counters come from the same compilation, once per fixture. Missing,
malformed or nonpositive instruction counters remain errors. Explicit `disabled`
skips `/usr/bin/time` and instruction limits, records instructions as unmeasured,
and keeps allocation parsing and caps. Empty or unknown settings reject before
fixture compilation or output changes. These checks never reuse output from an
earlier fixture compilation.

`BLORP_2_RESOURCE_POLICY` defaults to `enforce-limits`; an unset value or that
exact spelling preserves every resource-limit error. Initial bootstrap
qualification may explicitly select `record-initial-bootstrap-debt`. Each
exceeded cost decision then prints a `BLORP2_RESOURCE_RESULT status=FAIL` record
with its policy, both counters and limits, and the original error. An explicitly
disabled instruction counter is recorded as `unmeasured` with its limit retained.
Only this cost decision permits the behavioral callback to continue; compiler,
counter, native, sanitizer, strict-accounting and independent file-state errors
still fail. Empty or unknown policy values fail even when costs are within limits.
Passing behavioral callbacks under this initial policy retain resource FAIL debt;
they do not establish resource or full M8 acceptance. Ordinary runs stay strict.

CI temporarily selects `record-allocation-debt` only for its e2e command.
Allocation overruns print `BLORP2_ALLOCATION_RESULT status=FAIL` with the actual
counters, limits and original allocation error. Instruction overruns still fail,
including when allocations also exceed their limit. Counter validity, strict
balance, ordinary native behavior and sanitizer failures remain blocking.
CI's existing disabled instruction measurement is unchanged; no instruction
measurement PASS is inferred. Unit tests and compiler generation stay strict.

Every host-compiled source module has a matching unit suite under `test/unit/test_<stage>/`,
mirroring its folder under `src/`; the support modules that suites share stay in `test/unit/`.
`src/` has one folder per stage (`lex`, `parse`, `load`, `namespace`, `check`, `specialize`,
`lower`, `own`, `verify`, `emit`), `utils` for modules several stages share and `runtime` for the C
fragments `emit` embeds. A folder imports only earlier folders, `main.brp` stays at the root, and
imports of compiler modules are explicit relative paths; bare paths name the target library only.
The designated target base/prelude are loaded from the explicit library root; they are not host modules.
Integration
and native execution suites live under `test/e2e/`; their input programs live
under `test/e2e/fixtures/`, grouped by feature. Folders carry the shared prefix,
as in `match/shadow.brp` and `mortal_string/identity.brp`. Base examples without
a distinguishing suffix use `basic.brp`. The suites use the existing compiler's
`TestSuite` API and run with `bin/blorp test --suite`; the example
fixture is not a test entrypoint. The host test API uses tuple-based test
registration. The compiler source under `src/` stays within the agreed subset.

Direct C unit tests of the target String runtime live under `test/runtime/`,
with Blorp `TestSuite` orchestration. Run them with
`bin/blorp test blorp_2/test/runtime`. They compile the same runtime fragment
used by emission at `-O0` with ASan/UBSan. Small test-local allocator wrappers
observe actual allocation/free calls; production runtime code has no test mode.
Generated unit-test code uses the host command's default `-O0`; omit `--release`
for development tests. Sanitizer builds also use `-O0`.

Each executable example defines its allocation and retired-instruction ceilings
in its end-to-end test under [test/e2e/](test/e2e/); those tests are the only
authority for the values. The test prints actual costs and ceilings, then fails
when a ceiling is exceeded. Ceilings are adjusted deliberately with retained
evidence. The figures quoted in the increment history below were the ceilings at
that increment, not the current ones.

The multiple-argument increment deliberately raises only `union_values` from
3,600 to 4,000 allocations. Its frozen baseline uses 3,574 allocations and the
candidate uses 3,641 (+1.87%); matched instruction medians increase 0.50%.
At that increment the 40-million instruction limit was unchanged. Removing redundant parameter
type copies and temporary traversal lists reduced the initial overhead; further
special cases to recover the remaining 41 allocations are not justified.

The fixed-record validation deliberately raises only the `union_values`
instruction ceiling from 40M to 45M after coordinator and independent review.
The first full gate used 40,111,881 instructions (3,668/4,000 allocations).
Historical cleanup baseline/final measurements already used 40,031,543 and
40,052,080; an unchanged gate failed at 40,004,573 then passed at 39,920,129.
The current matched minima are 39,210,111 → 39,359,584 (+0.381%), with candidate
maximum 39,382,264. This establishes marginal process-startup headroom rather
than repeatable growth above 5%. The 4,000 allocation limit, all other fixture
ceilings, and the separate 10% allocation/5% minimum-instruction investigation
stops are unchanged. The [fixed-record report](../benchmarks/results/blorp_2_fixed_records_2026-10-10.md)
preserves the failed full gate and final rerun.

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
in the default `required` mode, macOS `/usr/bin/time -l` collects instructions
for that same run. Instruction counts include allocation bookkeeping and reporting. They are development-test
ceilings, and are not directly comparable to the historical minimum of three
uninstrumented `-O2` runs in the binding increment record.

The process request sets strict leak diagnostics and removes memory statistics
before starting the timer. The timer invokes the compiler directly, so a
preparatory environment launcher is outside the retired-instruction boundary.
The earlier harness timed that launcher too; retained measurements identify
their epoch, and earlier failed gates remain failures. Numerical limits stay
unchanged. Both instruction modes use the same compiler arguments and environment.
These file-only compiler requests use null stdin and no child deadline. This
intentionally replaces legacy `process.run`'s inherited stdin and implicit
30-second or `BLORP_PROCESS_TIMEOUT_MS` deadline. The enclosing TestSuite timeout
is separate; output capture retains its existing default limit and environment override.

The default instruction check requires macOS `/usr/bin/time -l` and its
retired-instruction counter. Missing or malformed required measurements fail
the test. CI explicitly selects `BLORP_2_INSTRUCTION_CHECK=disabled` because hosted
runners may lack this counter; that mode retains strict allocation reports and caps.
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

[`generic/identity.brp`](test/e2e/fixtures/generic/identity.brp) uses one
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
[`generic/forward_string.brp`](test/e2e/fixtures/generic/forward_string.brp)
forwards through a second generic declaration and preserves the saved result
when its caller replaces the original String binding.

## Generic union example

[`generic/box.brp`](test/e2e/fixtures/generic/box.brp) wraps and matches an Int:

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

Written annotations admit nested ordered arguments, such as `Box[Box[Int]]`
or `Result[Box[Int], Int]`. The [nested example](test/e2e/fixtures/generic/nested/written.brp)
declares `double_box[T](value: T) -> Box[Box[T]]` and extracts the result
through ordinary `unbox` calls; its real `main` exits 7. Concrete payloads may
be Int, Float, String, Void, a List of any supported finite type, a finite record, or another finite inline union. Specialization
publishes complete payload types and defines child layouts before parents.
Constructors and projections carry the selected variant identity through
lowering, ownership and independent verification. Heterogeneous variants use
distinct members of a tagged C union. String-bearing unions remain inline and
own only their active variant's children. Their generated dup/drop helpers visit
that child path; the union root has no heap allocation or reference count.
Nullary and unmanaged active variants keep the same aggregate obligation while
performing no child ownership work. Finite nesting composes through child-first
helpers and managed record roots; a union may also name itself as one direct
payload, which stores it boxed (see [unary recursive unions](#unary-recursive-unions)).
A phantom `Marker[String]` with no parameter payload remains valid, as does
`Tagged[String]` whose field is explicitly Int. Equal layouts retain distinct
nominal instance identities.

Union field annotations use the same type syntax as parameters and
record fields. `Text(String)`, `Floating(Float)`, `Wrapped(Box[String])` and
`Items(List[String])` name one complete payload type. The annotation resolves
in the union declaration's module and type-parameter scope. Nested arguments
retain nominal identity and declaration-owned parameters. All declared aggregate
types must be finite, including unused unions.

A nullary variant is bare `Empty`. `Unit(Void)` is unary and is constructed as
`Unit(void)`; it remains distinct from an empty variant. `Variant()` is invalid,
and `Variant(Int, String)` declares two ordered fields. `Variant(Pair[Int, String])` names one payload and is valid. Lists accept any supported finite element type.

Constructors evaluate each field expression once in written order. Patterns write one recursive pattern for each position, such as `Pair(left, _)`;
all captured names within one alternative are distinct.
Each managed stored occurrence acquires an independent obligation, including
`Pair(text, text)`; an escaped managed child remains live after its parent retires.
Nonempty variants use inline C field structs, while nullary variants have no
payload member. Recursive aggregate types other than a direct self-reference
retain their existing restrictions.

The [managed payload example](test/e2e/fixtures/generic/managed/basic.brp) runs
`unbox(box(42.to_string())).length()` and exits 2. Its tail match borrows the
Box parameter and acquires an independent owner for the returned String. The
[saved extraction](test/e2e/fixtures/generic/managed/saved.brp) still exits 2 after
replacing the caller's Box; the [current value](test/e2e/fixtures/generic/managed/current.brp)
exits 1. A [shared Box](test/e2e/fixtures/generic/managed/shared_box.brp) returned
through generic identity also survives replacement. Calls borrow arguments and
return owned managed values; constructors explicitly transfer child obligations.
Strict phase/full pilot tests, all twelve native examples, eight ownership fault
checks and final-hash matched costs pass independent review. The
[increment report](../benchmarks/results/blorp_2_managed_union_payloads_2026-10-11.md)
records the evidence, current limits and separate host Core failures.


The [function-recursion example](test/e2e/fixtures/recursion/self.brp) uses an
existing union to terminate without adding arithmetic or conditional syntax:

```blorp
fixed union Step:
    Stop
    Once
pure func walk(step: Step) -> Int:
    match step:
        Stop: 7
        Once: walk(Stop)
func main() -> Int:
    walk(Once)
```

It exits 7. Companion fixtures exercise mutual calls, UFCS, nested arguments,
bindings, record-literal children, generic calls and managed String results.
The String fixtures return an owned result through recursive calls and preserve
an arm-local owner across a recursive call. Each fixture runs through its real
`main`, with unchanged generated C compiled at `-O0` under ASan/UBSan. Every
fixture has limits of 10,000 allocations and 100,000,000 instructions. Calls
use the C stack; automatic tail-call optimization and constant-stack recursion are not
part of this increment. Cyclic runtime data is forbidden. The first recursive
data shape, a [unary recursive union](#unary-recursive-unions), is supported;
the [M4 recursive-types roadmap](ROADMAP.md#m4-recursive-types) defines the remaining
shapes and their ownership requirements.
An explicit `@tail_recursive` function has a checked direct-self loop guarantee:

```blorp
fixed union Step:
    Stop
    Once
@tail_recursive
pure func walk(step: Step, left: Int, right: Int) -> Int:
    match step:
        Stop: right
        Once: walk(Stop, right, left)
func main() -> Int:
    walk(Once, 7, 9)
```

This [swap fixture](test/e2e/fixtures/tail_recursion/swap_right.brp) exits 7.
The annotation may also share a line with `pure func` or `func`. Every direct
self call must be the complete final function expression or match-arm result;
a final UFCS self call qualifies. Receivers, explicit arguments, binding
initializers, scrutinees, constructor payloads, record fields and earlier
postfix calls remain non-tail. A saved call result returned later is rejected.
Name, arity, type and purity errors are checked first.

Annotated functions must be nongeneric and contain a direct self call. Their
concrete parameters, result and every evaluated intermediate must be unmanaged,
even an unused String initializer. Int, supported fixed records and fixed unions
are allowed; an unmanaged phantom `Marker[String]` carries no String value.
A helper's internal managed values are allowed when the annotated caller sees
only unmanaged values. Zero-argument helpers and `main` may be annotated, with
no promise of termination. Generic, managed and mutual-only guarantees are
future increments.

Lowering evaluates all next arguments in source order before replacing any
parameter. Immutable value snapshots and all prefix work execute inside the
loop on every iteration. The emitted C guarantees bounded stack growth for
these direct self edges at `-O0`; other calls and mutual recursion retain their
ordinary stack behavior. The annotation does not bound heap use or prove
termination. Unannotated C output is preserved. The
[tail-recursion report](../benchmarks/results/blorp_2_tail_recursion_2026-10-10.md)
records phase invariants, malformed-IR tests and the native stack-exhaustion
mutation oracle. The [tail-loop roadmap](ROADMAP.md#m3-loops-and-tail-recursion)
retains the deferred generic and managed annotated tail-recursion requirements.

The [numeric accumulator](test/e2e/fixtures/tail_recursion/accumulator.brp)
decrements an Int while adding one to a second Int. The regular suite checks
exact stdout for zero, one, seventeen and one million iterations under `-O0`
and sanitizers. This observes the completed count independently of the process
exit status. The older hexadecimal countdown remains a separate carry/borrow
case; its constant result alone does not prove the iteration count.

For a longer stress run, compile the same fixture and run its normal entrypoint
with a nonnegative iteration argument:

```sh
blorp_2/build/compiler --library-root blorp_2/standard_library \
  blorp_2/test/e2e/fixtures/tail_recursion/accumulator.brp \
  blorp_2/build/tail-accumulator.c
clang -std=c11 -Wall -Wextra -Werror -pedantic -O0 \
  blorp_2/build/tail-accumulator.c -lm -o blorp_2/build/tail-accumulator
blorp_2/build/tail-accumulator 1000000000
```

Expected stdout is `1000000000` followed by LF, with status zero and empty
stderr. The fixture's manual argument must be nonnegative; it does not validate
negative iteration counts. The one-billion run stays outside the routine suite.

The [multiple-type-parameter example](test/e2e/fixtures/generic/function_parameters/second.brp)
adds independent declaration parameters:

```blorp
pure func second[A, B](first: A, second: B) -> B:
    second
func main() -> Int:
    second(7, 42.to_string()).length()
```

It exits 2. Parameter identity includes its declaring function or union and
position; call substitutions and specialization keys retain every argument in
declaration order. Repeated concrete instances are reused, while changing even
an unused later parameter creates a distinct instance. Substitution preserves
caller-owned rigid types during forwarding. A declared expected result can solve
parameters represented in the result; unrelated phantom parameters remain
ambiguous. Fixed unions also support ordered declaration parameters,
as in `Result[T, E]`.


The [multiple-argument example](test/e2e/fixtures/generic/arguments.brp) adds
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
[first String fixture](test/e2e/fixtures/generic/arguments_first_string.brp)
returns length 1 after replacement of the caller's old value; the
[second String fixture](test/e2e/fixtures/generic/arguments_second_string.brp)
returns length 3. Passing the same managed value twice preserves both borrows
through the call and drops its owner once after the result owner exists.


The [two-parameter union example](test/e2e/fixtures/generic/union_parameters/ok.brp)
adds independently positioned payload types:

```blorp
fixed union Result[T, E]:
    Ok(T)
    Err(E)
pure func success() -> Result[Int, Int]:
    Ok(7)
pure func unwrap_or[T, E](value: Result[T, E], fallback: T) -> T:
    match value:
        Ok(item): item
        Err(_): fallback
func main() -> Int:
    success().unwrap_or(3)
```

It exits 7. Written applications must supply exactly the declared number of
type arguments in order. A known `Result[T, E]` argument can infer both
function parameters; matching visits runtime arguments first, then each type
argument from left to right. Conflicts retain the earliest inferred occurrence.
At a conflict, diagnostic expectations retain any uninferred callee parameters
as rigid types. Accepted calls still require every parameter to be inferred.
Constructors and patterns substitute the union's own parameter identities.
Phantom arguments still distinguish instances even when layouts match.
`Result[Int, String]` has an owning layout even when the program constructs only
Ok: its complete variant inventory includes a String child. The Ok tag requires
no child work, while Err dup/drop visits its String. Written applications and
finite String-bearing payloads may nest.


## Unary recursive unions

A union may name itself as one direct payload of a variant. The
[depth example](test/e2e/fixtures/recursive/depth.brp) counts a chain:

```blorp
import:
    int: add
fixed union Nat:
    Zero
    Succ(Nat)
pure func make() -> Nat:
    Succ(Succ(Succ(Zero)))
pure func count(value: Nat, total: Int) -> Int:
    match value:
        Zero: total
        Succ(child): count(child, add(total, 1))
func main() -> Int:
    count(make(), 0)
```

It exits 3. Checking admits exactly this shape: a non-generic union whose only
references to itself are direct variant payloads, with at most one such payload
per variant, so every value is a chain. Mutual recursion (`A(B)`, `B(A)`),
recursion through a record, a `List[Nat]` payload, a generic `Tree[T]` naming
`Tree[T]`, and two self payloads in one variant are rejected at the written
annotation with help naming the admitted form. Other payloads may sit beside the
self-reference, such as `Step(String, Trail)`.

Specialization reserves the union's instance identity locally while its other
payloads are prepared and publishes one complete layout whose representation is
boxed: every value, including a leaf such as `Zero`, is a counted heap node and
the self payload is a pointer to the child node. A record or union holding a
boxed union is managed or owning as for any managed child; `List[Nat]` elements
use the same dup/drop helpers. Verification accepts a layout that refers to
itself only through a boxed payload and rejects a self payload under an inline
representation, a boxed layout without one, two self payloads in a variant, and a
cycle closed through a record.

Constructing `Succ(n)` allocates one node from the same compound literal an
inline union uses and stores `n` as an acquired occurrence under the existing
payload rule; matching reads the tag and payload through the pointer, and the
match binding borrows from its parent as record fields do. The generated C has
the node struct, a constructor, a retain and an iterative final release: when a
node's count reaches zero the walk releases its other payloads, saves its one
child, frees the node and continues with the child while that child also dies,
so C stack use does not grow with the chain. The
[trail example](test/e2e/fixtures/recursive/trail.brp) keeps a `Step(String, Trail)`
chain inside an inline owning union and prints each String. The
[shared example](test/e2e/fixtures/recursive/shared.brp) stores one chain in two
record fields and exits 4; the [deep example](test/e2e/fixtures/recursive/deep.brp)
builds a 10,000-deep chain by ordinary recursion, prints its length and releases
it. A direct runtime test releases a 100,000-deep chain, built iteratively from
completed children, on a 512 KiB thread stack. Source construction and traversal
still use ordinary C call depth, and managed values remain outside
`@tail_recursive` loops. See the
[increment report](../benchmarks/results/blorp_2_recursive_unary_2026-10-15.md).


Ordinary [List membership](standard_library/README.md#list-membership) accepts a
supplied pure equality callback, with a temporary concrete Int adapter.
Its indexed recursion does O(n) work and uses linear C stack at O0.

## Recursive data through records and Lists

Every recursive shape the pilot's own source declares is now admitted: a
union whose payload is a record holding the union, `List[Self]` payloads,
mutual recursion between records and unions, record-only cycles, and a
generic union such as `Maybe` applied to a recursive type. The
[tree example](test/e2e/fixtures/recursive/tree.brp) walks and releases one:

```blorp
fixed record Expr { form: Form, span: Int }
fixed union Form:
    Leaf(Int)
    Call(String, List[Expr])
    Field(Expr, Int)
```

The rule is that the by-value storage graph is acyclic: a union stores each
direct payload by value, including the payloads of an applied generic union's
body (`Maybe[Node]` is checked as `Just(Node)`), while a record field, a List
element and a non-generic union's one direct self payload are pointer edges
that a cycle may pass through. Union-only cycles (`A(B)`, `B(A)`;
`Node(Maybe[Node])`) and a generic declaration whose body applies itself to
one of its parameters (`Tree[T]: Node(List[Tree[T]])`) are rejected at the
written type that closes the cycle. A record on a cycle is managed and a union
on one is owning; an uninhabited `record Node { next: Node }` is admitted
without a warning, as the host admits it. Specialization reserves a layout
group's identities while it is built and publishes complete rows only;
identities stay in child-first order, so programs without recursion emit the
same C as before.

Each managed layout keeps a direct release helper that releases its children
by calling their helpers, so the helpers of one recursive group call one
another and release depth follows structure depth. Every record, List and
boxed union helper is declared before any aggregate definition, and only
storage by value orders definitions: the
[group example](test/e2e/fixtures/recursive/group.brp) runs a union that
stores a later union by value. The unary boxed chain keeps its iterative
release. Releasing user data therefore has a depth limit: a self-linked record
such as `record Node { value: Int, next: Option[Node] }` releases at most
87,505 nodes on an 8 MiB stack and 5,584 on a 512 KiB thread stack when the
generated C is built at `-O0` (262,520 and 16,760 at `-O2`). The
[report](../benchmarks/results/blorp_2_recursive_mixed_2026-10-15.md) gives the
full depth table and the nesting the pilot's own source reaches.


## Finite mixed records

Fixed records can contain any currently supported finite concrete type, including
Float, String, Void, List[E] for any supported finite E, other records and instantiated unions:

```blorp
fixed record Entry { count: Int, ratio: Float, text: String }
pure func make_entry() -> Entry:
    { count = 7, ratio = 2.5, text = 42.to_string() }
pure func escaped_text(value: Entry) -> String:
    value.text
func main() -> Int:
    escaped_text(make_entry()).length()
```

The [mixed fixture](test/e2e/fixtures/record/mixed.brp) exits 2. The returned
String has its own owner before the temporary Entry is destroyed. A repeated
child stored in two fields contributes two independent ownership obligations.
Parameters borrow; managed results return owned. Field expressions execute once
in written order, independently of declaration order.

Fixed records whose fields are Int, Float or recursively eligible inline fixed
records stay inline. Other fixed records use an ARC root, including a record
whose Void or unmanaged-union fields need no child cleanup. Root retention
changes only the root count. Final root release destroys every owned stored
occurrence; inline owning union fields drop their active payload paths.
Acquired managed projections remain valid after their parent is destroyed.

Whole-variable reassignment preserves old aliases. Empty record
declarations, recursive records and field assignment remain unsupported.
Recursive declaration references other than a union's direct self payload
reject before layout expansion.
The [roadmap](ROADMAP.md#delivered-foundation) tracks final
integrated acceptance and later aggregate extensions.

## Structural tuples

Tuples contain two to four ordered elements with independent types:

```blorp
pure func first(value: (Int, String, Bool)) -> Int:
	(number, _, _) = value
	number

func main() -> Int:
	value: (Int, String, Bool) = (1, "one", True)
	value[0]
```

Tuple types nest inside tuples, generic arguments, record fields, callable
parameters and results. As elsewhere, bare union constructors need a receiving
type; annotate a tuple when its elements need that context. `(value)` groups one expression and `(Type)` groups one
type. Neither `(value,)` nor `(Type,)` denotes a tuple. Tuples of two to four
elements may have a trailing comma. An arrow after enclosed types selects a
callable type: `(Int, String) -> Int` has two parameters, while
`((Int, String)) -> Int` has one tuple parameter. Callable parameter arity is
independent of the tuple limit.

Read an element with an integer literal index, starting at zero. Computed and
out-of-range indices are compile errors. Tuple patterns are recursive, including
`Some((number, _))` and `(Some(number), (other, _))`; they use the ordinary
exhaustiveness and alternative-binder rules. A tuple may be a direct match
subject, as in `match (left, right):`.

`(first, _, third) = value` declares immutable names. A for loop accepts the same
flat target, such as `for (name, _) in entries:`. Wildcards discard their
elements. These targets contain two to four names or `_`, with optional trailing
commas, and evaluate their subject once. Nested declaration/for targets,
per-member annotations, tuple `?=`, tuple parameters written as patterns, and
subscript assignment are unsupported. A destructuring always declares its names;
an ordinary mutable variable containing a tuple may still be replaced as a whole.
Destructure a nested tuple in a separate declaration. Ordinary named parameters
may have tuple type annotations.

Tuple elements evaluate once from left to right, including Void elements whose
values have no physical storage. Tuples have value semantics and remain
structurally typed, distinct from authored named records. Once concrete, they
use the ordinary managed record storage and ownership machinery. Tuple
equality, ordering and traits are outside this increment.
The [tuple validation and cost report](../benchmarks/results/blorp_2_tuples_2026-10-21.md)
records matched self-compilation costs, ownership checks and native coverage.

## Fresh record updates

`{ base | field = expression }` creates a complete record with selected fields
replaced. The base determines its nominal record type and every type argument;
replacement names never select a different type. Unchanged fields keep their
values. Existing aliases retain the original values:

```blorp
import:
    list: repeat
    int: to_string
    io: print
fixed record Entry { number: Int, text: String, values: List[Int] }
pure func make_entry(number: Int) -> Entry:
    { number = number, text = number.to_string(), values = repeat(number, 2) }
pure func replace_text(value: Entry) -> Entry:
    { value | text = 7.to_string() }
func main() -> Void:
    old = make_entry(42)
    alias = old
    fresh = replace_text(old)
    print(alias.text)
    print(fresh.text)
```

The [alias fixture](test/e2e/fixtures/record/update/aliases.brp) prints exactly
`42\n7\n` and exits 0. The base executes once. Replacement expressions execute
once in written order, followed by unchanged-field projections in declaration
order. Complete construction stores every field in declaration order. The
[order fixture](test/e2e/fixtures/record/update/order.brp) updates `text` before
`number` and prints `base\ntext\nnumber\n7\n7\n`.

Managed updates always allocate a fresh root. There is no uniqueness test or
COW reuse yet, including when a replacement has the same value as the old field.
Inline numeric records use ordinary complete construction without ARC. Each
managed stored occurrence receives its own obligation through the existing
acquire-then-drop protocol: a projection acquires an owned child, construction
acquires its stored child, and the temporary owner retires after its last use.
Unchanged fields do not keep their parent alive after their own obligations are
established. Replaced fields are never projected unnecessarily. All current
finite field types work, including Void, owning unions, records and nested Lists.
The [escaped-child fixture](test/e2e/fixtures/record/update/escaped_children.brp)
returns a List and a mortal String after their updated parents retire.

Generic arguments may be inferred from replacements when the base already has a
known nominal head. For example, a pending `Box[T]` base updated with `value = 7`
can become `Box[Int]`. A literal base uses the ordinary result context; fields
never supply an otherwise unknown record owner. Checking publishes complete
typed replacement and inherited-field rows, with parser-owned base spans.
Later stages use resolved field identities rather than spelling lookups.

Updates require at least one replacement and allow a trailing comma; their
braces may span lines. After `{`, a name followed by `=` starts a literal; otherwise
the parser reads a base expression and requires `|`. Thus `{ first : 7 }` reports
a missing update bar, while `{ first = 7, second : 9 }` reports the second field's
missing `=`. Unknown names, duplicates and mismatched field types report
typed checking errors. A duplicate points to the first written name; a type
mismatch points to the field annotation. Field assignment and recursive data
remain deferred. This increment favors correct fresh construction; COW/reuse
optimization follows separate evidence and review.

## Generic records

```blorp
fixed record Box[T] { value: T }
pure func box[T](value: T) -> Box[T]:
    { value = value }
pure func unbox[T](value: Box[T]) -> T:
    value.value
func main() -> Int:
    unbox(box(7))
```

The example exits 7. Generic bodies are checked once with declaration-owned rigid
parameters. Specialization preserves the record declaration and every ordered
concrete argument, including phantom arguments. Box[Int] and Box[Float] are
inline; Box[String] and Box[Void] are managed roots under the existing field
policy. Void fields have no child ownership obligation. A projected managed
child remains valid after its parent dies.

A receiving Box[T] annotation establishes the literal's nominal owner even while
T is unresolved: `inspect[T](value: Box[T])` can accept `{ value = 7 }` and infer
Int from the field. Nested record fields and uniquely resolved UFCS contracts use
the same rule. An unannotated literal or `identity[T](value: T)` alone supplies no
record owner. Fields are checked and evaluated in written order. Recursive
record layouts and recursively growing generic call substitutions reject before
specialization expands them. Record-owned List[T] fields accept every supported finite element type, including
other Lists. Checking accepts generic List annotations without a String-only
admission rule. Specialization prepares all nested nominal element layouts and
publishes their complete concrete identities before lowering.
Void is a valid type argument and return type for pure functions, including
generic instances. Purity is checked at calls; specialization does not inspect it.

## Grammar for this increment

This specification defines only the examples' language: functions with an optional
return annotation (omission means `Void`), an ordered list of explicitly typed parameters, an optional ordered list of type
parameters on functions, fixed unions and fixed records with
one or more finite fields after substitution. Union variants have zero or more ordered fields using ordinary type annotations; concrete fields
specialize to Int, Float, String, Void, a List of any supported finite type, a finite record, or another finite inline union. A function
body has zero or more ordered binding or Void expression statements followed
by a final expression or a tail match with inline arm results or statement blocks. Expressions
start with `void`, a signed Int64 or decimal Float64 literal, a quoted UTF-8 String literal, a pipe String or raw block, a binding or variant name, a record literal or update,
an application with an ordered list of arguments, a list literal such as
`[1, 2]` or `[]`, a qualified name or call
such as `IntOps.add(1, 2)` where `IntOps` is a module alias of the import
block (the alias wins over a local of the same spelling, as in the host), or
one expression grouped in parentheses. UFCS calls and record field
suffixes may follow that expression, including a group's closing parenthesis,
and may continue on following lines that start with `.`, at the same
indentation or one level deeper (a method chain, as in the host); inside an
indented chain every line starts with `.`, and an `if`, `while`, `for` or
`match` header may not hold an indented chain.
`low..high` is a range of two such operands; `not a`, `a and b` and `a or b`
combine them with the host's precedence (`or` below `and` below `not` below
`..`, `and`/`or` left-associative). A line break after `and` or `or` is
accepted only inside brackets; the host also accepts it bare, which is a
follow-up. `if condition:` opens an indented block, optionally followed by
`else:` with a block or `else if condition:`, which nests the next
if-expression; the form is one expression in value and statement positions
alike. It ends at its last block's dedent: no operator, range or UFCS
suffix on the next line continues it, and a binding or line it ends needs
no newline of its own. An `else` with no `if` to belong to is a syntax
error. `[pure] func(params) [-> Type]: body` is a lambda: its parameters are
names or `_`, each optionally annotated, and its body is one expression on
the same line or an indented block (inside brackets, a bracketed block,
which must end before the bracket closes: a `)` on the block's last line is
an error, as in the host). A lambda body starts a new statement context, so
a loop control inside one needs a loop of its own, and by owner decision
`?=` is rejected anywhere inside one, where the host accepts it. `pure func` and `func` lambdas carry their declared purity. Function types are
`pure (Int, String) -> Int` for a pure callable and `(Int, String) -> Int` for
an impure-capable callable. Both admit zero parameters, trailing commas and
nested callable parameter/result types. Callables are ordinary values: they may
be local bindings, record/union fields, List elements, return values and generic
type arguments.

```blorp
pure func identity[T](value: T) -> T:
    value

pure func apply[T, U](value: T, callback: pure (T) -> U) -> U:
    callback(value)

func main() -> Int:
    apply(17, identity)
```

A callable value may be a declared, imported or module-qualified function
reference, a lambda, or another callable binding. Generic references infer fresh
type arguments at each use; enclosing generic parameters stay rigid. A generic
reference whose types lack concrete evidence still rejects rather than creating
a runtime generic function. Zero and multiple parameters and Void results are
supported. A pure callable may satisfy an impure-capable context with the same
parameter and result types; the reverse is rejected. Purity weakening applies to
the outer callable only, not arbitrary nested parameter/result types. A pure
function may create an impure callable but may not invoke one.

Lambda input types must be complete from annotations, the expected callable type
or ordinary arguments; a later ordinary argument may solve an earlier callback's
input. Inline bodies infer their result when the lambda has a callable context.
A standalone lambda without a callable context currently needs complete written
parameter types and a return annotation. A block body needs a written return
annotation or a complete expected result. A written nominal result annotation
supplies the context for record literals.

Lambdas capture immutable outer values by value, including Strings, Lists,
records and callable parameters or locals. Repeated reads of one binding share
one capture; two alias bindings remain separate captures. Nested lambdas may
read their parent's or a further ancestor's immutable values. A stored or
returned callable keeps its capture environment alive independently of the
creating call. Mutable outer bindings cannot be captured: copy the current value
into an immutable binding first. A lambda may mutate its own local variables.

```blorp
import:
    int as IntOps

pure func apply[T, U](callback: pure (T) -> U, value: T) -> U:
    callback(value)

pure func offset(value: Int, amount: Int) -> Int:
    apply(pure func(item: Int) -> Int: IntOps.add(item, amount), value)
```

`offset(40, 2)` returns 42.

```blorp
fixed record Operation {
    run: () -> Int
}

pure func stored(value: Int) -> Operation:
    { run = func() -> Int: value }

func main() -> Int:
    operation = stored(42)
    callback: () -> Int = operation.run
    callback()
```

This returns 42. Read a callable field into a local before invoking it:
`operation.run()` retains its existing UFCS meaning, not field-call precedence.
Invoke a callable binding with `callback(value)`. An ordinary stored local also
works as a helper's UFCS receiver: `saved.use(17)` means `use(saved, 17)`, with
the same outer purity permission and argument order. Statically selected callable
parameters and bare named references retain their direct-call restrictions;
`formal.use(17)`, `value.formal()` and `identity.use(17)` remain rejected.
Each lambda has its own purity and loop scope: a pure lambda inside an impure function still cannot call an impure
function, and a loop inside it does not inherit the enclosing loop context.

Statically selected callbacks keep the existing ordinary direct-call path:
named and noncapturing callbacks need no runtime data slot, while a statically
selected capturing callback passes its managed environment. Stored values use
their concrete callable signature and keep that environment through ordinary
copies, returns and aggregate storage. Data arguments retain written evaluation
order, and data-receiver UFCS still works for declared helpers. Creating a
function value does not execute its body. Named references and lambda bodies
still participate in the generic cycle-growth check even when the receiving
function ignores them. Functions with callable parameters cannot use
`@tail_recursive`, and an annotated function cannot pass itself as a callback.

A `match` anywhere but a function's tail (bound, nested in an arm
or branch block, or followed by further lines) is likewise one expression
ending at its last arm's dedent; the function's last match stays its tail
body. Value `if` is supported as a whole initializer, function tail, condition,
or branch value. An absent `else` produces only Void; statement branches must
also produce Void. Conditions require the designated Bool type. Bind an `if`
or `match` before using it inside a larger expression. Ascending, end-exclusive
Int ranges are supported as `for` iterables; general Range values remain unsupported.
Prefix `not value` and infix `and`/`or` are invalid; diagnostics teach ordinary calls.
A bound or statement match is a join.

Select pure Bool functions with `bool: not, and, or`: `not(value)` / `value.not()`,
`and(left, right)` / `left.and(right)` and `or(left, right)` / `left.or(right)`.
Calls evaluate every argument once, left to right; use `match` to skip an RHS.
`not (value)` is also a call. These three keywords may name functions, imported
selections and called members; bindings, types and fields retain their reserved-name rules.
A dotted type such as `Shared.Span[Int]` is a qualified type. A qualified
name resolves through the import block's alias row to the target module's
own public declarations: `IntOps.add(1, 2)` is a direct call to that
module's function, `S.Circle(2)` and `S.On` build that union's variants, and
`S.Span` names its record. Private declarations and the target's own imports
are not exported; a bare alias is not a value, and `Alias.function` without
a call is rejected.
Arguments use the same expression grammar, so direct and receiver calls may nest.
No other declarations, expressions, literals, or statements are supported.
Single-line comments begin with `--`; a line holding only `---` at column 1
opens a documentation block that the next such line closes, and the block is
trivia.

[`grammar.ebnf`](grammar.ebnf) defines the complete restricted source grammar
and its EBNF dialect. Whitespace is explicit: LF is `"\n"`, TAB is `"\t"`, and
the header/body spacing and EOF rules are productions. Identifier rules
exclude the reserved spellings `func`, `pure`, `match`, `var`, `void`, and lone `_`.
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
  optional ordered statements, and a final expression line or tail match; a union
  has one header and at least one variant line. Blank, whitespace-only and
  comment-only lines may appear before, between, and after code lines. Their
  incidental indentation has no layout meaning. Real code lines require LF
  separation; the final line may end at EOF.
- `--` begins a comment anywhere outside a quoted String or builtin label and consumes
  bytes up to LF or EOF. Inline comments preserve the code line's newline;
  comments cannot continue expressions across lines, except inside an open
  bracket, where the comment and the line break are trivia. Comments permit
  ASCII bytes, including tabs; CR and non-ASCII bytes are rejected at their
  original byte offsets. A line holding only `---` at column 1 opens a
  documentation block closed by the next such line; its text is trivia and
  admits any byte but CR. `----` and `--- x` remain comments, and there is no
  docstring metadata yet.
- The entire indentation prefix of a real code line uses tabs only or spaces in groups of four;
  mixed indentation is invalid. As in the host, a block's lines may sit at any
  depth deeper than its header: the lexer emits a newline token ending each
  code line, an indent token for a line deeper than the innermost open level
  (opening that level, whatever the step), and a dedent token per closed
  level, which must land on an open level or the indentation is inconsistent.
  A line indented between a bracketed block's base and its level closes the
  block. The parser reads blocks from those tokens and never compares depths.
- Spaces may separate tokens and trail each line. They are required between
  `func` and the function name, and between `fixed`, `union` and the type name.
  Identifiers are scanned as whole words, so
  `funcmain` is one identifier. The two characters of `->` are adjacent.
  Spaces may surround a UFCS dot and its parentheses, as in `1 . one ( )`.
  Outside comments, tabs occur only in the indentation prefix. Each expression stays on one line,
  including match scrutinees, binding initializers and final arm results,
  except that a line break inside an open bracket continues the line.
- A `|` first on a line, including a continuation line inside brackets,
  starts a pipe String: each line's text after its marker, verbatim and
  without escapes, joined with LF; the literal continues while the next line
  has the first line's exact indentation bytes before its `|`. `||` yields one
  `|` and `${expression}` opens an interpolation hole. `raw` alone on a line followed by marker lines
  starts a raw block, where `${` is text. The literal is the whole code of its
  lines, so it stands where an expression line does or as an argument on its
  own lines; a record update bar therefore never starts a line.
- `'a'` and `'\n'` are Char literal tokens: one character or escape pair in
  single quotes. The parser rejects them with a teaching message until the
  Char type exists.
- Every word GRAMMAR 1.4 reserves is reserved here: `func`, `pure`, `match`,
  `var`, `void`, `import`, `type`, `private`, `record`, `union`, `builtin`,
  `as`, `opaque`, `into_opaque`, `from_opaque`, `if`, `else`, `and`, `or`,
  `not`, `while`, `for`, `in`, `break`, `continue`, `alias`, `debug`, `detach`,
  `foreign`, `from`, `implements`, `resource`, `select`, `trait`, `try`,
  `where` and lone `_`. Writing one
  where a name is declared reports "`word` is a reserved keyword and cannot be
  used as a name". `fixed`, `methods_only` and `tail_recursive` are names in
  the host too and remain valid names here. The optional `pure` qualifier precedes `func`
  with spaces between the two keywords. Function, parameter and type names are
  identifiers whose meaning is checked after parsing.
- A function may declare ordered type parameters, as in
  `pure func second[A, B](first: A, second: B) -> B:`. Each name starts with a
  capital ASCII letter and contains only ASCII letters and digits. Names must
  be distinct within a declaration. Explicit function type arguments at calls
  are unsupported; argument types and known expected results constrain the type
  parameters.
- `fixed union Type:` introduces one or more variants on indented
  lines. `fixed` is a contextual header word and remains a valid name
  elsewhere; `union` is reserved. A variant is bare or declares an ordered list of field types, as in
  `Number(Int)`, `Box(T)` or `Pair(String, String)`. A union may declare ordered
  parameters with `fixed union Result[T, E]:`. Every field annotation uses ordinary
  type syntax in the union declaration's module and parameter scope, including
  recursive type arguments such as `Box[Box[Int]]` or `Result[T, Box[E]]`.
  Empty declaration parentheses remain unsupported. Concrete field layouts may
  contain Int, Float, String, Void, Lists of supported finite types, finite inline unions or records.
- `fixed record Pair { first: Int, second: Int }` declares a nominal record;
  its braces may span lines. Field names must be distinct and have supported finite concrete
  types after specialization. `fixed record Box[T] { value: T }` declares ordered
  type parameters; their identity belongs to this record. `record` is
  reserved. Empty and recursive records remain unsupported. Representation follows the
  inline-versus-managed field policy described above.
- `{ second = 9, first = 7 }` constructs the nominal record required by a
  helper return type, receiving parameter or existing binding reassignment.
  Every field appears exactly once. Expressions evaluate in written order;
  field order in the literal may differ from declaration order. A new inferred
  binding alone supplies no record context. `{}` parses and reports the first
  missing field. Declarations and literals may span lines inside their
  braces and allow a trailing comma; field assignments are unsupported.
- `{ pair | second = 9, first = 7 }` preserves the base's nominal type and
  type arguments. The base executes once, replacements execute in written
  order, and construction stores all fields in declaration order. Every
  replacement name appears at most once; at least one replacement is required.
  Updates may span lines inside their braces and permit a trailing comma.
- `pair.first` reads a declared field; `pair.read_first()` remains a UFCS call.
  A uniquely resolved immediate UFCS receiver parameter may supply a nominal
  literal context, including a head with unresolved generic arguments.
  Literal fields constrain those arguments on the same expression-local inference
  state. A field read supplies
  none, and later operations never infer a literal's type through an earlier
  field read. Within one generic call, a typed sibling supplies a literal's
  nominal record context in either operand order, including through nested
  calls. Field names never select an owner. Records pass and return by
  value, including through existing generic functions whose arguments infer
  a concrete record. Copies and whole-binding reassignment preserve old aliases.
- `match expression:` starts a nonempty sequence of depth-two arms written
  `Pattern: expression` or `Pattern:` followed by a depth-three block of
  ordered binding or Void expression statements and a final expression; a
  block ending after a statement parses, and checking rejects such an arm
  ("match arm has no final value"). A pattern is a bare name,
  `_`, or a constructor name
  followed by parentheses containing zero or more comma-separated patterns, so
  patterns nest; alternatives separated by `|` form an or-pattern; `[]`,
  `[a, b]` and `[first, ...rest]` are list patterns (no trailing comma, the
  rest last); a String or Char literal is a literal pattern; `Alias.Variant`
  qualifies a constructor by a module alias. Checking accepts nested
  constructor, alternative, List and String patterns; Char remains unsupported.
  Alternatives bind the same names at identical semantic types. Lists without
  rest require exact lengths; a rest accepts any remaining suffix. A qualified
  head selects a public constructor through the importing module's alias.
  A nullary constructor pattern may be written `Empty` or `Empty()`. `Number()`
  is valid syntax but fails semantic arity checking for a one-field constructor.
- A binding line is `name = expression` or `var name = expression`, optionally
  annotated as `name: Type = expression` or `var name: Type = expression`, at depth
  one in a function or depth three in an arm block. Its initializer starts on
  the same line, or stands alone on the next line indented one level, and may
  continue inside brackets. `name ?= expression` is a propagating binding:
  it parses only among a function body's own top-level statements, never with
  `var`. It is rejected inside every `if` or `match` block, in statement and
  value positions alike, including tail arms. Loop bodies, lambda bodies,
  `while` conditions and `for` iterables also reject it.
  Checking accepts a canonical `Result[Value, Error]` in a function returning
  `Result[Return, Error]`; the success types may differ, and the error types
  must match. It binds the `Ok` payload once and returns an `Err` before
  evaluating later statements. A binding annotation names the success type:
  `value: String ?= expression` supplies `Result[String, Error]` context.
  Otherwise the RHS must infer a complete type through ordinary inference;
  bind a typed Result first when a constructor needs more context. `Option`
  propagation and `?=` in `@tail_recursive` functions remain unsupported.
  Match on the Result or Option in place, or give a nested block its own
  function and propagate at that function's top level.
  `while condition:` and `for name in iterable:` (or
  `for _ in iterable:`, discarding each element) open a loop body; they,
  `break` and `continue` are statements with no value, and a loop control
  stands alone on its line (`break 1` is rejected here while the
  host still accepts it, pending GRAMMAR D10).
  As in the host, `break` and `continue` need an enclosing loop body; by owner
  decision neither may sit in an `if` or `match` used as a value within a loop.
  Propagation is also rejected throughout loop bodies. The parser enforces
  those rules. Checking accepts nested `while` statements with designated Bool
  conditions and `for` over Lists or ascending, end-exclusive Int ranges such as
  `start..end`. The iterable or both bounds evaluate once before iteration, in
  written order. Empty Lists and equal or reversed ranges run no body. Each
  iteration binds a fresh immutable item (or discards it with `_`) and creates
  fresh body locals. `break` exits the nearest loop; `continue` advances that
  loop to its next iteration, including through statement `if` and `match`.
  Inner writes to enclosing mutable bindings reach the outer continuation.
  Carried values use their ordinary sealed ownership layouts, including Strings,
  Lists, managed records and unions; older aliases and borrowed outer values
  retain their values. Managed `@tail_recursive` functions remain unsupported.
  Bindings and bare expression statements may interleave before
  the mandatory final expression or function tail match. A non-final bare
  expression must return Void; bind or return other values. Bindings inside
  arguments and annotations are unsupported. An arm block may end with a
  nested match, a join whose value the arm returns or yields.
- Integer literals are decimal values from `-9223372036854775808` through
  `9223372036854775807`, with an optional adjacent minus. `-0` is accepted
  and has value zero. Leading zeros (`00`, `-01`), leading numeric plus,
  separated minus signs and arithmetic operators are rejected. The `+` token
  separates trait bounds; it does not enable arithmetic. The lexer preserves the whole
  digit run; the parser validates spelling and range before converting it.
  A dot followed by a function name starts UFCS: `42.identity()` is a call;
  `42.5` is a Float literal.
  Non-ASCII bytes outside quoted Strings and CRLF source line endings are rejected.
- A declaration may start with `private` (GUIDE, Visibility): it stays
  visible within its module and is neither selectable by import nor
  reachable through an alias from another module. A public function's parameter
  or return type, public record field, or public union payload may not mention a
  private type, including inside nested type arguments. Make the type public or
  the enclosing declaration private. Private declarations and body-only uses
  of private types remain valid.
- `opaque type Name = Underlying` declares a distinct, nongeneric type.
  `into_opaque Name(value)` wraps its underlying value and
  `from_opaque Name(value)` projects it, only inside the declaring module.
  Export ordinary constructor/accessor functions for other modules, as in the
  [two-file Int example](test/e2e/fixtures/opaque/int/main.brp). Two opaque types
  remain distinct during checking and function specialization even when they wrap
  the same type, including inside Lists and generic records. A generic function
  has distinct body instances for those opaque types and their underlying type;
  repeated requests with the same semantic type arguments and callable choices
  reuse that function's instance. Named and lambda callable choices retain the
  same semantic distinction. Within one record or union declaration or capture
  site, same-storage opaque substitutions may still share a physical layout.
  Conversions evaluate their operand once; afterward they use the underlying
  layout and ownership operations without a runtime wrapper. Opaque types do not
  inherit representation fields or methods.
  Public opaques may hide private representations. Cyclic opaque representations
  are rejected; wrapping an independently recursive aggregate remains valid.
  The conversion words are reserved: `into_opaque(7)` is a syntax error.
- `LIMIT: Int = 7` declares an explicitly annotated module constant; its
  initializer may stand alone on the next line. Closed initializers admit
  scalar/Void literals, constructors, records, Lists, tuples and named function
  references. An annotation supplies ordinary context, including an empty List's
  element type and a generic named function's concrete callable signature.
  Calls, references to other constants, lambdas, postfix operations, record
  updates, opaque conversions and control expressions are not closed initializers.
  Name a callback as a function instead of writing a lambda in a constant.
  Creating an impure function value does not invoke it; ordinary callable purity
  checking still governs its annotation and later invocation.
  Every declaration is checked, including unused constants. Checking resolves all
  constant annotations, then function signatures and entrypoint diagnostics,
  then constant initializers, then function bodies. Constants obey module privacy
  and cannot be shadowed by parameters or local bindings. Imported and qualified
  reads resolve to the same declaration identity. Each runtime read materializes
  an ordinary value with fresh value/ownership identities; there is no runtime
  global initialization or retained global object. The materialized root carries
  the read's span; aggregate children retain their initializer's source spans.
  Callable constants support ordinary direct and qualified calls; scalar constants
  cannot be called, and constants do not enter UFCS method selection.
  Test-suite mode uses an ordinary `tests: TestSuite` constant with named
  callbacks; inline lambda initializers remain unsupported.

- Every token must be consumed. Malformed declarations and statements are errors.

Semantic rules:

- Exactly one root function must be named `main`. It takes no parameters or one
  `List[String]` parameter, and returns `Int` or `Void`. The argument list includes the
  executable name at index zero. A helper
  takes zero or more explicitly typed parameters with distinct names. Helper
  annotations use the supported scalar, finite record/union, List[E] or
  declaration-owned generic types described above. An omitted return annotation
  means `Void`. Pure functions
  cannot return `Void`, including concrete generic instances.
- Union types have nominal identity. Equal variant positions or shared variant
  spellings do not make two unions interchangeable. Union type names must be
  unique in their module and cannot replace a base type visible in that module; each union's variant names must be unique.
  Type names occupy a separate namespace from functions and variant values, so
  a function may share a type name. A function cannot share any variant name;
  a collision highlights whichever declaration appears later in the source.
- Function names are unique within each module. Direct calls use local declarations
  and explicit function imports. UFCS also uses type-selected functions and the
  default prelude. Declaration order does not affect resolution. Calls supply
  exactly the number of arguments the callee declares.
- A bare expression name first resolves to the nearest local binding: an
  arm capture, a body-local binding, or the containing function's parameter. Otherwise
  it resolves to a variant in the expected union: the innermost call's parameter
  type, or the containing function's return type when there is no enclosing call.
  A variant name is unique in its module, across all of its unions and its
  functions; a user module also cannot declare one the prelude supplies (`True`,
  `False`, `Some`, `None`, `Ok`, `Err`). The expected type must be the variant's
  union. `First()` is invalid because a payload-free constructor is a value;
  `Number(expression)` supplies its one field; `Pair(left, right)` supplies two.
  Each complete field type is established by the receiving union instance.
  A name cannot refer to another function's parameter or denote a function value.
  A new parameter, local or field capture cannot reuse a visible function,
  constructor or module alias, or an enclosing parameter, local or capture. The
  prelude provides functions and constructors; its own aliases are not inherited.
  Type-only names occupy the separate type namespace. A
  binding's established type is preserved when it is read.
  Arguments use the caller's scope, even when the callee has a parameter with
  the same spelling.
- `name = expression` declares an immutable binding when the name is absent,
  reassigns an existing mutable binding, and rejects an existing immutable
  binding. `var` declares a fresh mutable binding under the same no-shadowing rule.
  An annotated occurrence also declares a new binding; it does not retype or
  reassign an existing variable. Its annotation is resolved in the function's
  defining type scope before its initializer and supplies that initializer's
  expected type, including generic calls, empty Lists and bare constructors.
  Body annotations may use implementation-private types, even in public functions.
  The initializer sees the earlier scope: write `var current = value` to
  initialize a distinct mutable local from a parameter. New declarations check
  their initializer before reporting a name collision; assignment to an existing
  binding still reports immutable or unsupported reassignment before its RHS. New bindings
  without annotations infer their type from the initializer; reassignment checks the established
  type. Bare constructors need a receiving union type, supplied by a call,
  return, reassignment or local annotation; an unannotated initializer does not guess that type.
  All initializers are checked for purity and call cycles, even when unused or
  in an arm a constant scrutinee cannot select. Arm locals stay within their
  arm. Reassignment of an enclosing mutable binding affects only the selected
  arm's computation; matches remain in the function tail.
- `receiver.function(arguments)` resolves its target from the file's declared
  and imported receiver functions. The receiver uses the caller's scope: a
  parameter `value` can be passed to `identity` with `value.identity()`. A
  direct call on a parameter value, such as `value(value)`, is rejected. UFCS supplies the receiver first, followed
  by the explicitly written arguments. Every argument is evaluated left to right
  exactly once before the call.
- Each argument must match its receiving type, as must the final expression
  of a non-Void function. A Void function's final expression synthesizes its own type
  and is evaluated and discarded.
  Unary call-edge mismatches highlight the callee name; multiple-argument
  mismatches highlight the disagreeing argument occurrence;
  constructor lookup errors highlight the variant name. Return mismatches highlight
  the complete expression, excluding indentation and trailing spaces.
- A match scrutinee must synthesize a declared union, List or String type.
  `match Empty:` and `match Number(42):` lack a receiving type;
  no type is guessed from patterns or the containing function's return type.
  Integer scrutinees are outside this increment. Each arm of a non-Void function
  must match that function's declared result type, which may differ from
  the matched value. Void functions evaluate and discard the selected arm's
  result. All arms are checked, including ones a constant scrutinee
  cannot select.
- A bare pattern name must be a visible constructor of the matched union.
  Constructors declared in another module must be imported with their union;
  an unimported constructor receives import help, including in a field position.
  Unknown bare names are errors, and `_` alone catches all remaining values.
  Bind a computed scrutinee before the match when an arm needs the whole value.
  Explicit constructor patterns also require a visible constructor of that union. Its declared field
  shape determines the required pattern arity. A field may contain a nested
  pattern, binder or wildcard; a visible constructor of that field's union is
  a constructor pattern even when written without parentheses. Arm bindings
  are immutable and scoped to that arm; sibling arms may reuse a spelling.
  Earlier arms determine usefulness. The same ordered pattern matrix checks
  exhaustiveness and builds selection, preserving exact List lengths and
  minimum lengths for rest patterns. An uncovered String domain requires a
  catchall. Every alternative binds the same names at the same semantic types,
  regardless of their constructor field positions.
- A pure caller may call only declared pure callees. Every function body is
  checked, including unreachable helpers, so a pure call chain cannot hide an
  impure edge. Calls inside arguments obey the containing function's purity.
  A violation highlights the callee name and suggests marking the callee pure
  or removing pure from the caller.
- Self and mutual function recursion are supported, including calls in arguments,
  UFCS chains, binding initializers, record fields and match arms. Signatures are
  established before any body is checked. Unannotated calls use the ordinary C stack; this
  increment makes no constant-stack or tail-call optimization guarantee.
- Generic recursion reuses a concrete instance identified by its declaration and
  ordered type arguments. Bare-parameter forwarding, permutations and concrete
  resets are supported. Checking rejects a parameter-dependency cycle that nests
  a parameter inside a union application, since it could generate unbounded
  concrete instances. This applies to unused declarations as well as called ones.
- Recursive calls do not permit cyclic runtime data. Values remain immutable
  graphs of already constructed values; whole-binding reassignment cannot make
  an existing value refer back to its replacement. Recursive declarations
  through record fields, List elements and one direct self payload are
  supported; their final release recurses through the group's helpers, while a
  unary boxed chain is released iteratively. Union-only cycles and generic
  self-reinstantiation remain deferred.
- Generic declarations are checked once with distinct rigid type parameters, including
  unused bodies. An arbitrary `T` cannot return an Int literal or call a
  concrete Int/String runtime operation. Parameters cannot share a name with
  `Int`, `String`, or any declared union; separate declarations may reuse `T`.
  `main` cannot declare type parameters. List repeat, length, get, append, set and concat builtin wrappers may be generic; other closed builtin bodies remain nongeneric.
  Direct and UFCS calls solve private call variables structurally, processing
  argument constraints before a declared expected result. Later sibling evidence
  can solve an earlier pending call or supply the nominal context for a
  record literal or constructor. The initial walk checks available children
  in written order, then ordinary argument constraints progress before
  deferred literal children resume. Their fields and payloads are checked
  once; runtime operands still evaluate once in written order. Repeated occurrences, including structural
  `Box[T]` occurrences, must agree; infinitely nested type equations are rejected.
  Generic forwarding preserves the caller's rigid parameter until specialization.
  Expected results can contextualize nested calls and constructors. A known
  nominal union head also supplies constructor context while its arguments are
  still being solved: `inspect[T](value: Choice[T])` accepts `inspect(Value(7))`.
  Uniquely resolved UFCS contracts supply the same reverse hints. Variant spelling
  alone never chooses a union; overloads remain receiver-directed and are not
  ranked by expected returns or later arguments. Field reads never choose a
  record owner. New bindings and match scrutinees receive no containing-function
  return context; discarded Void tails impose no result constraint.
  A zero-argument call can infer parameters represented in an expected result.
  Any remaining phantom or unconstrained parameter diagnoses ambiguity, with no
  default type. Every accepted call publishes complete ordered substitutions;
  private variables and tentative facts never escape checking.
  Union instances are keyed by declaration and all ordered concrete arguments; repeated
  direct/UFCS requests reuse the same instance. Layout admission accepts finite
  owning inline unions, managed records, boxed unary recursive unions and
  recursive layout groups through records and Lists before lowering.
  Union-only cycles and self-reinstantiating generic declarations remain
  unsupported.
- Each concrete function has its checked C return type and a generated symbol based
  on its compilation-local identity. `Int` uses `int64_t`; each union uses its own
  synthetic enum when all its variants are nullary. A payload-bearing union
  uses a distinct struct with an enum tag and a C union containing a correctly
  typed field struct for every nonempty variant, including unary variants.
  Nullary variants have no member and create no empty C struct. Construction
  supplies its tag and ordered fields; omitted storage is zero-initialized.
  A separate C wrapper calls
  the checked entrypoint and converts an `Int` result to the process exit status,
  or discards a `Void` result and exits 0. Checking publishes both the argument
  convention and result convention as typed entrypoint facts; later phases
  preserve them rather than rediscovering them from a signature.
  A nullary entrypoint uses `int main(void)`; an argument-taking entrypoint
  uses `int main(int argc,char **argv)` and owns the argument list for the call.
- The final expression is the return value for a non-`Void` function. A `Void`
  function evaluates and discards it, releasing any owned result, then returns
  `void`. No explicit `return` is needed.
- `String` is an immutable managed leaf. The default prelude supplies UFCS
  operations such as `to_string(Int) -> String` and `length(String) -> Int`.
  Direct calls require named function imports. Parameters borrow for the duration of a
  synchronous call; managed results transfer an owner to the caller, including
  results that alias a borrowed parameter. Unused mortal results are released.
  String-bearing unions store their root inline and own their active children.
  A tail-match arm may create, borrow, alias and return arm-local managed values;
  unused and intermediate owners are dropped on that arm, and a managed result
  transfers its owner. Borrowed managed parameters and locally owned prefixes
  are admitted before an ordinary terminating match. Each selected arm discharges
  prefix obligations after securing its result. Literal construction creates a
  fresh ordinary String owner. A join's arms follow the same rules and move a
  managed result into the join, which owns it afterwards. Direct String `add`
  calls and interpolation may instead transfer a last-used owner into
  concatenation. The verifier checks that transfer independently; ordinary
  function parameters still borrow. String buffers carry byte length and
  capacity: a transferred unique buffer appends in place when capacity suffices
  and otherwise grows geometrically. Shared buffers copy, preserving value
  semantics. Concat-only accumulation can transfer a nearest-loop-owned String
  in a terminal arm; captured outer owners and continuing joins stay borrowed.
  `append_int` still uses its ordinary borrowed wrapper and a temporary decimal
  String, so this increment does not remove its growing-prefix copies.
  [Buffer-reuse measurements](../benchmarks/results/blorp2-string-buffer-reuse-2026-10-23.md)
  record allocation/instruction results and the validation boundary.
- Union-only recursive layouts, generic self-reinstantiation,
  guards, Char patterns, constructor UFCS,
  and function
  values are outside this increment. `Bool` is an ordinary fixed union declared
  once in the base module, alongside Option and Result. Local functions and
  explicitly imported functions support both call notations; type selections
  expose receiver functions only through UFCS.
- Syntax and semantic errors carry a source location, an explanation, and help.
  Rejected source produces no C output and does not overwrite an existing output.

## Local modules

[`import/basic/main.brp`](test/e2e/fixtures/import/basic/main.brp) selects a function
from its sibling `helper.brp`:

```blorp
import:
    ./helper: answer
func main() -> Int:
    answer()
```

Its sibling `helper.brp` declares:

```blorp
pure func answer() -> Int:
    42
```

The executable exits 42. Each import row starts with `./`
or leading `../` segments, omits `.brp`, and selects local functions or fixed
unions. The selections follow the path on its line, or on an indented block
of lines under a path ending in `:`; each line may end with a comma. A row
names each selection, and each listed constructor, once. Repeating a selection
is a parser error; its help teaches one combined selection, such as
`Shape(Circle, Square)`. `path as
Alias` names the module, alone or before `:` and selections, for qualified
access such as `Alias.name`; an alias is scoped to its module, cannot reuse a
declared or imported name there, and each module is imported once (GUIDE,
One Import Per Module), so an alias and selections of one module share a
row. A bare selector selects a local function or a type the module declares;
if both exist, the selection is ambiguous. `Option(Some, None)` selects a union and those
constructors, while `Option()` selects the union without constructors. Both
forms also enable local receiver functions. `Foo methods_only` adds receiver
functions and requires the exact type independently visible in the caller.
Imports precede declarations. Bare paths select target-library modules when
the required explicit library root is supplied. Record type imports are
supported; a module offers only the types it declares, so an imported type is
never selected through a module that only imports it. Aliases, qualified names
and `private` are supported;
wildcards and reexports are unsupported. Qualified constructor patterns
use the same constructor identity, field arity and coverage as bare heads.

Each module owns its declarations; same-spelled declarations in different
modules have distinct identities. Imported functions resolve their annotations
and calls in their defining module, and importing them does not expose their
siblings or types. Their nominal signature types remain usable as inferred
values. Direct calls and UFCS use the caller's visible functions. Only a local
`main` in the root file provides the entrypoint; another module's `main` is an
ordinary function.

Paths are normalized absolute logical paths for one invocation; symlink aliases
are not canonicalized. A diamond loads a shared path once. Import cycles,
including a module importing itself, are rejected when the program is sealed,
before checking: a depth-first walk over resolved targets in load order reports
the first cycle at the import that closes it, and the loader names its modules
by display path. Assembly rejects a second import of one module as it is
appended.
Every loaded module is checked, including unused declarations. Diagnostics
retain the source file for primary errors and secondary notes independently.

The [module validation report](../benchmarks/results/blorp_2_modules_2026-10-11.md)
retains the independent reviews and measurements; the
[module reference](#local-modules) defines the current visibility rules.

## Temporary target library and Int addition

[`int/add.brp`](test/e2e/fixtures/int/add.brp) imports a concrete function:

```blorp
import:
    int: add

func main() -> Int:
    add(20, 22)
```

It exits 42. `20.add(22)` uses the same declaration through UFCS. Int addition
wraps at the signed 64-bit limits. Arithmetic operators remain unsupported.
[Concrete authored traits](#concrete-traits) are available; the production
arithmetic helpers retain their ordinary APIs until the later library migration.

Supply the target library explicitly:

```sh
blorp_2/build/compiler --library-root blorp_2/standard_library \
  blorp_2/test/e2e/fixtures/int/add.brp \
  blorp_2/build/add.c
```

Bare import paths resolve only under that directory. Relative imports resolve
beside their importer, including inside library modules. Missing roots and files
produce diagnostics; there is no local-file or host-library fallback. Library
modules use the ordinary module pipeline and preserve declaration identities.

The [temporary library](standard_library/README.md) adapts modules from
the [standard library](../standard_library/src/), with original source revisions
and hashes retained in its adapter headers. Its active declarations provide
the calculator's ordinary unions and concrete numeric, conversion and IO functions.
Their explicit builtin bodies select closed compiler-known operations. Module functions
may declare these builtin bodies with the exact concrete runtime signature,
without statement prefixes or tail annotations. List repeat, length, get, append, set and concat wrappers may also declare generic parameters; other builtin wrappers remain nongeneric. Unknown
labels and signature mismatches are errors. There is no arbitrary foreign
symbol binding. The base types module owns `Int`, `Float`, `String`, `Void` and unary `List`.
The [validation report](../benchmarks/results/blorp_2_int_add_2026-10-11.md) records
strict tests, native fixtures, matched costs and the existing compiler's
different trait-based `add` import surface.
The [target API reference](standard_library/README.md) documents the current
library contracts and temporary implementation limits.

## Quoted UTF-8 String literals

Literal construction uses the same immutable managed String representation as
integer conversion:

```blorp
pure func greeting() -> String:
    "hello"

func main() -> Int:
    greeting().length()
```

It exits 5. A literal may also appear directly in calls, bindings, supported
union payloads and match arms. Copies, returns, reassignment and unused values
follow the existing ownership rules. Each evaluated literal creates one mortal
String allocation; a borrowed result acquires its own ownership obligation.

Quoted contents accept valid UTF-8. `length` counts UTF-8 bytes, matching the
existing library: `"é".length()` is 2 and `"🙂".length()` is 4. Composed and
decomposed text is preserved without normalization. Source spans and diagnostic
columns continue to count bytes; identifier and comment syntax retains its
current ASCII restriction.

Every String's required contract is valid UTF-8, including counted NUL. Native
argv admission validates each argument before constructing its String. Legacy
host byte APIs still have enforcement gaps. Target checked slicing preserves
scalar boundaries; byte access remains useful.
An ASCII refinement type is deferred.

The fixed escapes are `\n`, `\r`, `\t`, `\0`, `\\`, `\"`, `\'`, `\{` and
`\}`. A Unicode escape `\u{X...}` has one to six hexadecimal digits and names a
valid scalar from U+0000 through U+10FFFF, excluding U+D800 through U+DFFF.
Embedded NUL counts toward length and is preserved. Raw ASCII control bytes,
DEL, malformed UTF-8, invalid escapes and missing quotes are errors with help.
Quoted literals stay on one source line. Pipe Strings join marker lines with
LF without escapes; `raw` blocks preserve literal `${` text. Write `"$\{"` in
a quoted literal to preserve literal `${` text.

Quoted and pipe Strings support `${expression}` holes. Each hole holds one
expression on one physical line and must produce a `String`; convert `Int`
and `Float` explicitly with their concrete `to_string` functions:

```blorp
import:
    int as IntOps
pure func describe(name: String, count: Int) -> String:
    "${name}: ${IntOps.to_string(count)}"
```

Holes use normal scope, calls, UFCS, generic inference and purity checks.
Plain quoted values and record braces may occur inside a hole; another
interpolated String may not. Bind an inner interpolated value before the
outer String. Interpolation is rejected in patterns, builtin labels and
closed constant initializers. Each hole evaluates exactly once in written
order. Checking balances the existing binary String concatenations to keep
their tree depth logarithmic; their allocation association differs from a
handwritten left fold. No interpolation representation reaches the backend.

Builtin declaration labels retain their exact raw spelling; String escape
decoding does not create aliases for closed runtime operations. The
[String report](../benchmarks/results/blorp_2_strings_2026-10-11.md) records construction and validation evidence.
Emission uses flat static byte arrays scoped to their function and named from
existing value identities. Backing bytes require no stack initialization and
avoid C string-token length limits; the runtime copies them into an ordinary
owned String on each evaluation.

[Retained validation and costs](../benchmarks/results/blorp_2_strings_2026-10-11.md)
cover the 15 new native fixtures, exact byte/lifetime tests, full suites and
frozen existing-workload comparison. Long-literal probes also identify a
bounded follow-up: the current host concat helper copies growing buffers in
byte emission (`append_string_bytes`). Escape decoding no longer does; the
[String decoding report](../benchmarks/results/blorp_2_string_decoding_2026-10-16.md)
has the measurements.

## Void, ordered statements and print

The [Hello World fixture](test/e2e/fixtures/effects/hello.brp) imports concrete
printing from the temporary target library:

```blorp
import:
    io: print
func main() -> Int:
    print("Hello, World!")
    0
```

Its stdout is exactly `Hello, World!\n`, stderr is empty and exit status is 0.
Import `io: print_error` for impure `print_error(message: String) -> Void`.
It borrows the String and requests its counted bytes once on stderr. A short
transfer, including EINTR, returns without LF or retry; a full transfer attempts
one LF. Empty input still attempts LF. Void conveys no delivery status or
buffer-flush guarantee. The host currently attempts LF even after a short write;
this target policy intentionally differs on that failure path.

`print(value: String) -> Void` writes every String byte and adds LF. UTF-8 and
embedded NUL are preserved. It borrows its argument; an owned temporary is
released after its last use. Print is impure, so a pure caller receives a
purity error. Import it explicitly with the configured target-library root;
it is not automatically available from the prelude.

`Void` has one value, `void`, and requires no ownership. Helpers may take and
return it; locals, record fields and ordinary union fields may contain it.
Internally C uses a
canonical zero `uint8_t` carrier for all Void values; this does not add another
surface numeric type.

Bindings, reassignment and bare Void expressions execute in source order. A
non-final bare expression of another type is rejected with help to bind or
return its result. Every block still needs a final expression. Omitting a
function's return annotation means `Void`, exactly like writing `-> Void`.
A Void-returning function evaluates and discards its final expression,
regardless of its type, and returns `void`. A discarded managed result is
released through the ordinary ownership pipeline. Each selected match arm
follows the same rule, so its final expression may differ in type from other
arms. Discarding does not suppress errors or side effects in that expression.

`main` accepts either `Int` or `Void`. An Int result supplies the process exit
status; a Void result always exits 0. Both forms accept no parameters or one
`List[String]` parameter. Pure functions follow the same Void return conventions,
whether explicitly annotated, omitted, or established by generic instantiation.
They still cannot call impure functions.

```blorp
import:
    io: print
func main():
    print("Hello, World!")
```

This has the same behavior as `func main() -> Void:`. A final `17` would also
exit 0 after being evaluated and discarded. A `pure func main()` declaration
also exits 0 and must obey the ordinary purity rules. The
[main signature fixtures](test/e2e/test_main_signatures.brp) cover pure and
impure Int entrypoints and explicit and omitted Void entrypoints, with and
without arguments, through their ordinary native main functions.

Argument-taking main rejects malformed UTF-8, including in the executable name,
before calling language code. It releases the initialized argument prefix,
exits 1, writes no stdout, and writes exactly this stderr:

```text
error: command-line argument is not valid UTF-8
help: pass UTF-8 encoded arguments
```

No-argument main retains its existing behavior and publishes no argv Strings.

Managed prefixes, including printing a literal before an ordinary terminating
tail match, are supported. Managed temporaries in annotated tail loops retain
their existing restrictions. A Void-only helper call introduces no managed
prefix.

One ordered statement list carries evaluation order through parsing, checking
and specialization. Discards create no synthetic binding; lowering retains
their ordinary value definitions so unused Void results still execute calls.
Emission selects a small print runtime fragment only when its typed operation
is used. The [validation report](../benchmarks/results/blorp_2_void_print_2026-10-12.md)
records phase tests, native output, ownership checks and matched costs.

## Calculator input and results

`Option[T]`, `Result[Value, Error]` and `Bool` come from ordinary
fixed unions in `standard_library/_base.brp`; none of them receives
a compiler-specific representation. The prelude supplies their types and
constructors to user modules; library modules import them from `_base`:

```blorp
import:
    string: parse_int
pure func number(text: String) -> Option[Int]:
    parse_int(text)
```

`parse_int` borrows the complete counted String. It accepts an optional ASCII
sign and one or more decimal digits, including leading zeros. It returns None
for empty input, whitespace, embedded NUL, non-ASCII digits, suffixes or values
outside Int64. No partial conversion or whitespace trimming is implicit.

Input enters through `main(args: List[String])`. The C wrapper copies the
argument bytes into an immutable owned list, including the executable name at
index zero; `main` borrows it. The `list` adapter exposes pure `length` and
`get`. `get` returns ordinary `Option[String]`: a present result owns a retained
String, while negative or out-of-range indices return None. No trimming or
splitting is implicit. OS argument strings cannot contain NUL; source-literal
tests cover counted NUL bytes separately. Lists accept every supported finite element type: Void, Int, Float, String,
records, unions, and nested Lists. `main` continues to accept exactly
`List[String]` for its argument parameter.

The target `list` module provides these ordinary pure generic functions:

```blorp
pure func repeat[T](element: T, count: Int) -> List[T]:
    builtin("list.repeat")
pure func length[T](values: List[T]) -> Int:
    builtin("list.length")
pure func get[T](values: List[T], index: Int) -> Option[T]:
    builtin("list.get")
pure func append[T](values: List[T], value: T) -> List[T]:
    builtin("list.append")
pure func set[T](values: List[T], index: Int, value: T) -> List[T]:
    builtin("list.set")
pure func concat[T](left: List[T], right: List[T]) -> List[T]:
    builtin("list.concat")
pure func set_index[T](values: List[T], index: Int, value: T) -> Option[List[T]]:
    match get(values, index):
        Some(_): Some(set(values, index, value))
        None: None
```

The target List module also provides ordinary generic callback helpers:
`any[T](List[T], pure (T) -> Bool) -> Bool`,
`map[T, U](List[T], pure (T) -> U) -> List[U]`, and
`filter[T](List[T], pure (T) -> Bool) -> List[T]`.
Pass pure named functions or forward callable parameters. `any` stops at the
first True result; `map` and `filter` preserve input order. Empty inputs return
False or an empty List. The temporary balanced implementation uses logarithmic
C stack and copies O(n log n) List slots for map/filter; it has no COW fast path.
The [target API reference](standard_library/README.md) records these limits.

`repeat` evaluates its element and count once. A nonpositive count produces an
empty List, including the minimum Int value. Each repeated occurrence owns its
stored value. `length` returns the initialized element count; `get` returns
None for a negative or out-of-range index and an independently owned Some value
otherwise. Zero, Void, an empty String and a nullary union case are valid Some
payloads. Retaining a List root does not acquire its children again; its final
release destroys each initialized slot exactly once.

`append`, `set` and `concat` borrow their inputs and return a fresh owned
List; every old alias keeps its original elements. Each stored occurrence of
the result, surviving or replacement, is acquired independently, so one
managed value may appear in both the input and the result. `set` with a
negative or out-of-range index returns an unchanged value; `append` and
`concat` always produce the longer List. The runtime helper for an update
exists only where its operation is called.

Checked `set_index` returns `Some(updated)` for a valid index and `None` otherwise.
Both update APIs evaluate their replacement argument eagerly, including invalid
indices. These names match the host library so the same compiler source can
be compiled by both compilers. A future coordinated rename to checked `set`
and no-op `set_or_keep` must update both libraries and all callers together.

A list literal `[a, b]` constructs one fresh root of exactly n slots inline
at its site, storing each element once; `[x, x]` acquires `x` twice, as a
variant payload would. Every element must have one type: the first element
decides it, and a later element of another type is rejected at that element
(`list elements must have one type: element 2 is Float, element 1 is Int`).
Once E is known, every later element is checked with E as its expected
type, so `[[1, 2], [], [3]]` gives the inner `[]` the type `List[Int]`.
`[]` takes its element type from an expected List type. The routes that
supply one are: an annotated binding; a function's non-Void return value; a `var` reassignment; a
call argument whose parameter is a List, including a generic `List[T]` such
as `append([], 7)`, which then infers `T`; a record literal or update field;
a variant payload field; and a later element of a list literal whose E is
already decided. Without such a context `[]` is rejected (`cannot infer the
element type of an empty list literal`): an unannotated binding initializer supplies no
expected type, `[[], [3]]` has nothing deciding E
before the empty element, and a UFCS receiver such as `[].get(0)` is accepted
with E = `T` and then reports `cannot infer the type parameter from the
argument`. No
removal syntax is included yet.

For example, a managed record can escape after its containing List is retired:

```blorp
import:
    list: repeat, get
fixed record Entry { number: Int, text: String }
pure func make_entry() -> Entry:
    { number = 7, text = "kept" }
pure func selected_entry() -> Option[Entry]:
    values = repeat(make_entry(), 2)
    values.get(1)
func main() -> Int:
    saved = selected_entry()
    0
```

The make_entry return annotation establishes the record literal's Entry identity. Concrete nongeneric wrappers and generic wrappers
with structured element types use the same closed contracts. For example,
`Pair[A, B]` can be a wrapper's element type; the compiler does not impose a
one-bare-parameter rule.

Emission derives a disposable list-layout table from accepted concrete types,
including local definitions. Helpers retain full
record and union instance identities, including phantom type arguments. A flat
key records outer List depth and terminal type/identity; it is an emission
projection, never a layout or ownership authority. The table is sorted and
deduplicated once, and C names project from the same key without per-use scans.
Nested helper dependencies reuse their suffix keys rather than rewalking type
ancestry. The finite concrete layouts remain the authority for element storage
and destruction.

The [argument validation report](../benchmarks/results/blorp_2_arguments_2026-10-12.md)
records the entrypoint contract, ownership checks, native tests and matched costs.

`string.equals(first, second) -> Bool` compares complete byte sequences.
`int` exposes concrete `add`, `subtract`, `multiply`, `divide`, `remainder`
and `to_string`, plus `equals(Int, Int) -> Bool`. Equality uses the complete
signed 64-bit values and ordinary explicitly bound Bool constructors.
`less_than` uses signed64 ordering; `greater_than`, `less_than_or_equal`,
`greater_than_or_equal`, `not_equals`, `min` and `max` are ordinary pure functions
over that primitive or equality. Equal operands satisfy both inclusive relations.
`INT_MIN` and `INT_MAX` are ordinary imported scalar constants with values
`-9223372036854775808` and `9223372036854775807`; comparisons never subtract.
The first three arithmetic operations wrap at Int64 bounds. Division and remainder
return zero for a zero divisor; minimum Int divided by -1 wraps to minimum,
with zero remainder. These operations avoid signed C overflow.

The [addition calculator](test/e2e/fixtures/calculator/addition.brp) consumes two
arguments and prints their sum. The [integer calculator](test/e2e/fixtures/calculator/integer.brp)
consumes an operation followed by two operand arguments. Operations are exactly
`add`, `subtract`, `multiply`, `divide` and `remainder`, selected through ordinary
String equality and union matching. It prints the result followed by LF and
exits zero; stderr is empty.

Pure helpers decode, parse and calculate, returning `Result` values. A small
reporting helper prints the result or error and chooses the exit status.

Invalid operands print `invalid integer`, missing required arguments print
`missing input`, and unknown operations print `unknown operation`, followed by
LF and exit status one. The operation is decoded before operands are parsed,
and the first operand is validated before the second. Extra arguments are
ignored. Empty, spaced, CR-containing and newline-containing arguments remain
intact and fail strict numeric validation.

Runtime declarations name only their operation, for example
`builtin("string.parse_int")`. Its contract returns the foundation's designated
`Option[Int]`, and `int.equals`, `int.less_than` and `string.equals` return the designated
`Bool`; checking accepts the exact result type, arity and purity once.
Specialization translates the designated constructors to the result instance's
constructor identities, and emission receives those directly. The verifier
sees instances, not declarations, and deliberately does not repeat that check.

## Counted String operations

`string.slice(value: String, start: Int, end: Int) -> Option[String]` takes
half-open UTF-8 byte offsets. It returns None unless
`0 <= start <= end <= value.length()` and both endpoints are scalar boundaries.
Valid empty and full slices return Some with an independently owned String;
NUL bytes are preserved and the input and its aliases remain valid. For example,
`slice("éx", 0, 2)` yields `Some("é")`, while `slice("éx", 1, 2)` yields None.
This is the checked target replacement for source substring operations.

`string.starts_with(value: String, prefix: String) -> Bool` compares counted bytes.
Empty prefix is True; UTF-8/NUL spelling is exact. The temporary implementation
uses native stack linear in the matching prefix; no constant-stack claim is made.

`string.append_int(self: String, value: Int) -> String` appends signed Int64 decimal digits.
The ordinary pure wrapper preserves UTF-8/NUL prefix bytes and earlier aliases.
The [edge fixture](test/e2e/fixtures/string_operations/append_int_edges.brp)
checks signed extrema, counted bytes and aliases; its owning suite retains the resource limits.

The target `string.add(left: String, right: String) -> String` is pure and
returns one fresh concatenation. It borrows both operands, including when they
alias, and preserves exact counted bytes, including NUL and UTF-8. Empty
operands follow the same ownership contract. The native helper copies each
operand once; the ordinary List join wrapper is documented separately.
The [normal-main fixture](test/e2e/fixtures/string_operations/concat.brp)
prints a doubled multilingual String with NUL and then its unchanged source.

The target `string` module provides two pure operations with ordinary foundation
Option results:

```blorp
pure func byte_at(value: String, index: Int) -> Option[Int]:
    builtin("string.byte_at")
pure func from_codepoint(value: Int) -> Option[String]:
    builtin("string.from_codepoint")
```

Indices and lengths count UTF-8 bytes. `byte_at("é", 1)` returns `Some(169)`;
negative or out-of-bounds indices return None. Reading borrows the String and
allocates nothing. A NUL byte returns `Some(0)`.

`from_codepoint` accepts Unicode scalars, including NUL and noncharacters, and
returns one fresh String. It rejects negative Int64 values, surrogates
U+D800–U+DFFF and values above U+10FFFF before narrowing. Some owns the String:
ordinary matching, copying and destruction preserve its lifetime. The
[ownership fixture](test/e2e/fixtures/option_input/from_codepoint_ownership.brp)
returns a String through a Some-pattern and separately discards an encoded result.
Compiler source uses the byte/scalar interface; a public target Char type
remains outside this bootstrap increment.

The temporary [List helpers](standard_library/README.md#list-queries-and-copies)
and [logical path helpers](standard_library/README.md#logical-paths) use ordinary
Blorp bodies over these counted-byte operations. Their concrete restrictions and
copying costs remain explicit.

## Current directory

Import `system: get_current_directory` to call the impure, zero-argument
`get_current_directory() -> Result[String, String]`. Match its ordinary
`Ok(path)` and `Err(error)` constructors; see the
[complete program](test/e2e/fixtures/current_directory/basic.brp).
Success owns a fresh, nonempty absolute pathname with exact validated UTF-8
bytes. Native storage grows as needed. Empty, relative or malformed native
paths return a useful valid-text error. OS errors include a saved numeric errno,
and EINTR returns immediately. The operation prints nothing.
Both Result branches own their String; matching, copying, discarding and
[escaping a payload](test/e2e/fixtures/current_directory/ownership.brp) use the
existing union ownership rules. The integrated loader obtains this runtime path
explicitly before normalizing module identities; full M6 and self-compilation
acceptance remain pending.

## File reading

Import `system: read_file` for impure
`read_file(path: String) -> Result[String, String]`; see the
[complete program](test/e2e/fixtures/file_read/basic.brp).
Success owns exact counted UTF-8 contents, preserving empty files, CRLF, BOM
and embedded NUL. Stable regular files are supported; streams and concurrent
snapshots are outside this contract. NUL paths reject before opening.
IO failures return saved numeric errno text; short reads and malformed UTF-8
return useful fixed text. The target advises saving malformed files as UTF-8;
`read_bytes` is unavailable. Read errors take precedence over close errors,
and close errors over encoding errors. Every opened stream receives one close
attempt, including EINTR, without retry. Nothing is printed. Both Result branches own
one fresh String under ordinary union ownership. The integrated loader uses
this interface; full compiler acceptance remains pending.

## File writing

Import `system: write_file` for impure
`write_file(path: String, contents: String) -> Result[Void, String]`.
It creates or truncates a file and writes exact counted UTF-8 bytes, including
BOM, CRLF and embedded NUL contents. Empty contents still create/truncate.
Ok contains Void and follows successful write and close; Err owns one fresh
String. Both inputs stay borrowed, including when they alias.
NUL paths reject before opening, with `write_file: path contains embedded NUL;
use a path without NUL`. The host uses `string contains embedded NUL` instead.
Open, short-write and close errors report their saved numeric errno. Write
errors take priority over close errors; every opened stream receives exactly
one close attempt, including EINTR, without retry. Partial output is allowed;
atomic replacement and durability are outside the contract. Nothing is printed.
See the [complete program](test/e2e/fixtures/file_write/bytes.brp) and
[acceptance report](../benchmarks/results/blorp_2_target_write_file_2026-10-18.md). The
integrated compiler shell uses this interface; full compiler acceptance remains pending.

## Float64 calculator

The designated foundation `_base.brp` owns `Float`, a binary64 unmanaged value. Decimal source
literals require a decimal point with digits on both sides, an exponent, or
both: `6.5`, `1e2`, `-0.0`, `2.5e-3`. Leading plus, leading-zero integer parts,
`.5`, `1.`, hexadecimal literals and separators are rejected. Source literals
must round to a finite Float; subnormals and underflow to signed zero are
accepted. Integer literals retain Int type; there is no implicit Int-to-Float
conversion. Integer UFCS such as `1.identity()` remains unambiguous.

```blorp
import:
    float: multiply, to_string
    io: print
func main() -> Int:
    print(to_string(multiply(6.5, 2.0)))
    0
```

This prints `13\n`. The concrete Float module provides the same five arithmetic
function names as Int, plus `to_string`, `copysign`, `equals`, `less_than`,
`is_nan`, `is_finite`, `abs` and `greater_than_or_equal`. Named function imports permit direct
calls and UFCS; type imports expose the module's associated functions through
UFCS. Receiver types distinguish Int and Float methods. Importing both Int and
Float `to_string` for direct calls is an error; neither declaration takes
precedence.
Following the pilot's infallible arithmetic rule, Float division and remainder
by either signed zero return positive zero. Other arithmetic can produce
infinity or NaN, with NaN sign and payload unspecified. Remainder uses a quotient
truncated toward zero. The existing
host Float library currently uses IEEE division by zero; the pilot's explicit
rule is defined here.

`string.parse_float` borrows a complete String and returns ordinary
`Option[Float]`. It accepts an optional ASCII sign, digits, an optional decimal
point with following digits, and an optional signed exponent. Integer-only
mantissas and leading zeros are allowed in runtime input. Whitespace, CR, NUL,
suffixes, non-ASCII, hex, `nan`, `inf` and overflow are rejected. Underflow
and subnormals use binary64 rounding and preserve the sign of zero.

Formatting spells nonfinite values `nan`, `inf` and `-inf`, and preserves `-0`.
Finite values use six significant decimal digits when those digits round-trip
to the exact value, otherwise the first successful precision from seven
through seventeen. Thus `0.1 + 0.2`, expressed through `add`, prints
`0.30000000000000004`; this contract does not promise universally shortest
decimal strings. Literal emission projects the parsed value as an exact C
hexadecimal literal rather than retaining its source spelling.

The [Float calculator](test/e2e/fixtures/calculator/float.brp) uses the integer
calculator's three-argument protocol and error precedence, with `invalid float`
for rejected operands. Its native cases exercise precision, signed zero,
subnormals, arithmetic overflow and invalid conversion.

Build and run it from the repository root:

```sh
make -C blorp_2 test-compiler
blorp_2/build/compiler --library-root blorp_2/standard_library \
  blorp_2/test/e2e/fixtures/calculator/float.brp \
  blorp_2/build/calculator.c
clang -std=c11 -Wall -Wextra -Werror -pedantic -O0 \
  blorp_2/build/calculator.c -lm -o blorp_2/build/calculator-program
blorp_2/build/calculator-program multiply 6.5 2
```

The output is `13` followed by LF. Float programs link the C math library.

The native model is binary64 with subnormals, ordinary arithmetic without fast
math or contraction, C startup locale and nearest/ties-even rounding. Generated code
checks representation requirements; target programs cannot change locale or
rounding in this subset. Float remains unmanaged in parameters, locals and
ordinary union fields and fixed-record fields.

Generated C disables contraction with GCC's `fp-contract=off` optimization
pragma or Clang's standard `STDC FP_CONTRACT OFF` pragma. The policy remains
active for generated functions so inlined arithmetic helpers still round each
operation separately under ordinary `-O2`, in both default GNU C and strict
C11 builds. The [native Float runtime tests](test/runtime/test_float.brp)
check exact runtime results and strict warning acceptance.

The [calculator component tests](test/unit/test_lower/test_option_contracts.brp),
[input ownership tests](test/unit/test_verify/test_option_ownership.brp),
[Float projection tests](test/unit/test_emit/test_float_literal.brp) and normal-main
fixtures protect different boundaries independently.

All nine calculator increments are complete. The
[validation report](../benchmarks/results/blorp_2_calculator_2026-10-12.md)
records 1,456 passing Blorp component checks, 40 native runtime cases, 299 native
e2e executions, independent reviews and matched cost measurements.

## Architecture

The command reads the root program, the configured foundation and ordinary
prelude, and their dependencies once per normalized path, then writes C:

```sh
bin/blorp run --no-format blorp_2/src/main.brp -- --library-root blorp_2/standard_library input.brp output.c
```

The impure command shell owns file I/O and printing. Compilation and
diagnostic rendering are pure. The pipeline publishes these complete results:

1. Lexing produces tokens with source spans and an explicit end-of-source span.
   It receives the name table so far, mints one opaque `NameId` per identifier
   spelling, and publishes the table it was given (`base_names`) and its
   extension (`names`); identifier tokens carry only the `NameId`.
   Reserved words carry `KeywordToken(Keyword)`; punctuation and layout carry
   `SymbolToken(Symbol)`, including the lone `_`. The lexer's forward match is
   their sole spelling authority. `LexedProgram` shares the original input
   String until parsing finishes so diagnostics can quote validated spans.
   A standalone retained `LexedProgram` therefore retains that input; parsed
   modules retain semantic names and literal values, not the full source.
   Integer tokens retain their complete raw spelling; indent and dedent tokens
   span the indentation prefix, and each token records whether a space precedes
   it. Trivia is skipped over the original
   source bytes; no rewritten source or comment metadata crosses the boundary.
2. Parsing produces function and union declarations, payload and parameter
   annotations, written names, ordered statement syntax, expression syntax, and structured match bodies.
   Match patterns preserve written names and recursive field syntax. Checking
   resolves constructors and validates each named capture. Each expression has a literal,
   name, or direct application base with ordered recursive arguments, followed by
   receiver applications with ordered explicit arguments. Direct and receiver
   syntax stay distinct because their target lookup differs.
   Every expression records its consumed token span directly, without reconstructing
   locations from names or literal values.
   The parser reads identifier IDs and never looks a spelling up; it recognises
   the few non-reserved header words such as `fixed` by the IDs the name seed gives them. Program
   assembly ([assemble.brp](src/parse/assemble.brp)) seals the complete syntax and immutable name table in an opaque `ParsedProgram`.
   Its [declaration inventory](src/utils/ids.brp) issues function, record,
   union and owner-qualified variant IDs once from the raw syntax. Consumers
   carry those IDs through accepted and checked rows; vector positions are
   traversal counters, not another identity producer.
   Sealing walks typed written-import and implicit-prelude edges with an
   explicit stack of module IDs and edge cursors. One visit-state vector
   distinguishes unvisited, active and complete modules. The transient edges
   are discarded after publishing dependency order.
   Integer conversion accumulates negatively against derived range cutoffs,
   checking before multiplication so even the minimum is represented safely.
3. A frozen namespace gives each module one scope, built in dependency order:
   its declarations, its import rows' names and, for a user module, the
   prelude's selections. In one module a spelling denotes at most one entity
   per space; functions and constructors share the value space, types have
   their own, and a module alias claims both. One rule enters every name, so
   two unions of one module cannot share a constructor name, and one rule
   decides what a module offers: only its own public declarations. Building
   stops at the first module with a problem and reports that one problem,
   before signature annotation errors. Checking asks the namespace what a name
   means in a module and what a module offers, one query per space, without
   repeating uniqueness checks.
   Selective imports do not reexport imported names, and an
   imported function retains its defining scope. Checking resolves nominal union and owned variant identities, then publishes
   one authoritative signature per function. A private resolution context borrows
   accepted declarations, signatures and namespace facts. Target resolution returns a complete
   call and signature after one lookup. Call boundaries compare parameter and argument
   counts once, including the UFCS receiver, then check purity. Transient contracts
   retain the resolved target, accepted signature and callee span. Checking infers one
   consistent substitution across all argument positions before validating every edge;
   contracts become checked calls only after validation. Published function
   signatures remain the sole signature authority. Constructor operations are
   distinct from function calls and use the owning variant's declared field shape.
   Local reads carry a function-owned `BindingId`, distinguishing the parameter,
   body locals and each arm's binding. Binding definitions own type, mutability,
   origin (including each parameter's explicit signature position) and declaration span; typed expression occurrences retain their own
   spans. Match checking resolves patterns and result types,
   and establishes usefulness and exhaustiveness before publishing checked arms.
   Each arm publishes its ordered statements and result. The current block's
   first local ordinal establishes which declarations belong to that block;
   semantic origin alone does not determine scope membership.
   Constructors retain their owning union and variant identities. Checking
   publishes an opaque program with its entrypoint identity. Call notation is erased
   after target resolution. A user call carries its checked substitution in its
   target variant; a runtime call cannot carry one. Rigid type parameters have
   explicit function-, union- or record-declaration owners.
   Scalar constant reads become ordinary checked literals at their existing lookup,
   retaining each read's occurrence span. Constant identities and accepted rows remain
   checker-local; the successful program carries neither references nor a constant table.
   Checking returns either the complete `CheckedProgram` or an opaque
   `CheckFailure` retaining the original parsed program and a nonempty
   `CheckErrors` collection. The current checker stops at the first error, so
   that collection is a singleton. Failures contain closed semantic variants,
   types, owner-qualified identities, argument positions and source occurrences;
   temporary builders do not escape. [render.brp](src/check/render.brp)
   keeps pure presentation outside the checker. Its `render_failure` produces
   every diagnostic using the failure's original parsed name authority.
   The CLI preserves the entire
   rendered collection. Semantic unit tests inspect typed facts directly;
   renderer and pipeline tests pin wording independently. UFCS receiver mismatch
   occurrences retain the existing call-span limitation. Expression synthesis
   owns one private expression-local work loop with structural constraints. New bindings
   and match scrutinees synthesize their types; non-Void returns, non-Void arms
   and reassignment explicitly check a known type and its source. Void function
   tails synthesize and then discard their values before returning canonical
   void. Argument checking elaborates all
   children before instantiation and mismatch validation, preserving error order.
   Complete outer receiver contracts are resolved before their children. Private
   call variables unify argument-first, then use the declared expected result;
   caller-owned parameters stay rigid. Closed nested errors are checked before
   later siblings. Deferred descendants finish child-first after solving; a later
   fatal name error can precede their unresolved ambiguity. Publication freezes
   complete calls and discards the temporary solver. A construct waiting for
   a nominal head retains one expression-local suspension, including its
   resolved variant identity and lexical scope. Ordinary equations provide
   that head; the same worklist resumes its fields or payloads once before
   publication. Unresolved suspensions retain their context diagnostic. If
   both a construction and a lambda remain unresolved after joint progress
   stops, the earlier written diagnostic wins. This does not infer a field
   projection from a call whose result type is still unknown.
   Nominal requirements introduced by generic calls are checked child-first
   during freezing; a later fatal name error can precede that new requirement
   failure. Existing direct List and pure-result readiness checks retain their
   established priority.
   [check.brp](src/check/check.brp) only composes the phases and seals their result.
   The phases follow the data: [declarations.brp](src/check/declarations.brp) checks types and
   declarations, [signatures.brp](src/check/signatures.brp) accepts function headers and builtin bodies,
   and [callables.brp](src/check/callables.brp) selects methods and proves call contracts. Bodies then
   use [inference.brp](src/check/inference.brp), the body-local inference state,
   [constructors.brp](src/check/constructors.brp), which plans record and variant construction (contextual
   record-literal and update checking), and [expressions.brp](src/check/expressions.brp), which elaborates
   and freezes one expression. [bodies.brp](src/check/bodies.brp) checks statements and matches and calls
   `check_execution` while it resolves each body; [recursion.brp](src/check/recursion.brp) holds that analysis
   and also checks the finished bodies for growing recursive instantiation.
   [model.brp](src/check/model.brp) owns published semantic data,
   [errors.brp](src/check/errors.brp) owns typed rejections, carrying a
   namespace problem unchanged for rendering.
   Accepted record fields and variants retain their declaration identities and
   written names alongside complete field annotations, so later checking does
   not rejoin parsed declarations to recover those facts.
4. Pure specialization starts from the accepted `main` identity and expands
   its complete call graph through the existing instance worklist. Checking
   still validates every declaration, including unreachable functions. Only
   reachable function instances and their required record and union layouts
   are published. Every variant's payload layout is retained when its union is
   required, even if the program never constructs that variant. One local instance list reuses
   equal declaration/type keys and distinguishes nominal union arguments. It
   translates complete signatures, bindings, statements, values, calls, variants and matches
   without checking bodies or resolving names again, then seals a
   `SpecializedProgram`. Concrete types cannot contain type parameters; concrete
   function, union and variant identities have separate instance domains.
   Parsed variant annotations and constructor patterns retain ordered field
   vectors. Each checked variant publishes one `List[TypeUse]`; each checked
   selection retains typed routes through union fields and List elements,
   exact or minimum List length tests, exact String byte tests, and edges to
   canonical arm inputs. Each arm body is published once. An edge either borrows
   its typed place or constructs a fresh List suffix; specialization preserves
   that distinction and translates union field routes to nominal field instances.
   Concrete union layouts publish one `List[TypeRef]` per variant; inline child
   layouts precede their parents. Construction carries the concrete variant
   owner and positional child values. Standalone projections retain a validated
   `VariantFieldInstanceId`, pairing the complete variant instance with its field
   ordinal through lowering and ownership. Independent verification checks the
   exact receiver, selected variant and field type; emission uses that identity's
   C storage. Optional diagnostics retain their typed note and declaration span.

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
   type and source span. A call definition chooses its callee span once;
   lowered and owned call operations carry the concrete target and arguments,
   while their enclosing definition owns the diagnostic anchor.
   Match-arm computations remain in their branches.
   Successful selection edges project typed places or construct List suffixes,
   then transfer their values into canonical arm inputs. Every shared arm starts
   with those inputs and the enclosing binding map, lowers its statement sequence,
   and publishes a branch-local value block. Sibling arms
   share only the function's value allocator, preserving distinct identities.
6. Concrete specialization owns storage and child-ownership representation.
   Its read-only ownership query classifies a concrete value as having no
   ownership, being a managed String leaf, List or record root, or
   containing owned inline union fields. Ownership insertion and verification
   both consume that upstream fact; the query does not inspect or prescribe
   insertion's operations. Producer tests independently cover each supported
   representation, including repeated stored children and phantom arguments.
   Ownership insertion publishes ordered definitions, owner acquisitions, drops and return
   transfers. `OwnerId` names one obligation;
   `ValueId` still names the computed value. Borrowed operands name the owner
   they depend on, the exact borrowed parameter value identity, or the immediate
   parent value of a projected field. Every managed stored occurrence acquires
   a fresh child obligation, even when two slots contain the same value; construction
   transfers those obligations sequentially. Last-use cleanup keeps an argument alive
   until a call has established its result owner. A consuming String concat
   argument instead transfers its obligation into the call; its result receives
   a distinct owner identity even when storage is reused. That transferred
   obligation is not also dropped. Loop edges retain their acquire-before-retire
   batches, including repeated outgoing values. Tail-match
   arms publish the same ownership operations and typed return transfers as a
   straight-line block. Value and owner identities remain function-wide; sibling
   arms cannot observe each other's values or obligations.
7. Independent verification checks the actual operations against representation
   and call contracts, rejecting dead/wrong owners, invalid borrows and
   undisposed obligations. Raw ownership IR does not preserve checking's sealed
   match proof, so verification independently checks the acyclic decision graph,
   reachable nodes and arms, nominal variant and List-length guards, and dense
   canonical arm identities with correctly typed input transfers. Nested tests
   and projections require the guards for every ancestor place.
   It also enforces the accepted entry argument/result conventions, rejects
   invalid prefix/arm owner identities and checks each arm's prefix and local
   owner discharge/transfer independently. Payload reads validate the actual
   scrutinee backing, including unmanaged payloads whose read still needs a
   live parent.
   Only it can seal a
   `VerifiedProgram`; it neither repairs ownership nor uses insertion's
   liveness decisions as its oracle. Type, layout, arity and coverage checks at
   this boundary validate the actual transformed IR against accepted contracts;
   they do not perform source-language acceptance again.
8. Emission consumes that verified program and produces C. Computed values use
   immutable C locals; scalar reassignment requires no runtime mutable cell.
   A match uses its evaluated scrutinee once. Structural tests jump through
   selection nodes; successful edges project fields and transfer inputs before
   entering one shared body per source arm. A wildcard arm may read an existing
   binding for the whole scrutinee. Emission consumes resolved lowered labels and values without repeating
   resolution, arity, purity, or coverage checks. Its result can report an
   internal lowered-reference error instead of silently choosing a C layout;
   source-language acceptance is already complete. Retains/releases project the
   explicit operations; emission does not invent owners or cleanup.

The names module owns the spelling table and its seed: the entrypoint's `main`
identity and the parser's contextual words. Every module's lexing extends that
shared authority, including the designated foundation's five builtin declarations. The sealed program retains
the entrypoint spelling identity and designated module identities; checking
validates builtin authority once before constructing the namespace. Lexing interns
each module's spellings in one batch and publishes the immutable table.
Written names contain only a `NameId` and source span. Checking compares identities;
spelling lookup is reserved for diagnostics and rejects a missing table entry
as an internal compiler error. IDs are meaningful only within their owning
parse and table; equality and lookup do not validate table ownership. Only
assembly can construct the sealed program that checking accepts. The declaration
inventory's raw ID constructors are private. `FunctionId` remains a separate
nominal identity issued in declaration order. Checking retains call spans;
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
A lowered block contains `Define` and `Join` steps. Ordinary definitions retain
their value facts; a join publishes typed result/carried parameters separately
from its arms' outgoing values. The checker publishes ordered reassigned binding
identities; lowering publishes the result and a fresh parameter per carrier.
Use rows count introduced values and record step positions;
drop buckets count steps. Arms' values and owners follow their complete block,
so every block keeps consecutive identities. Ownership publishes `ExecuteJoin`,
and independent verification checks the complete signature and outgoing batch
before sealing the program.
General pass infrastructure remains future work.

The target library's [`_base.brp`](standard_library/_base.brp)
owns the builtin Int, Float, String, Void and List identities, and the ordinary
Bool, Option and Result unions. It is the only module that may declare builtin
types, and any module may import it as `_base`.

The foundation check designates those three unions once, by name and only in
`_base.brp`, and publishes their constructor identities for checking to read:
`Bool` must declare exactly `True` and `False` without payloads, `Option[A]`
exactly `Some(A)` and `None`, and `Result[Value, Error]` exactly `Ok(Value)`
and `Err(Error)`, in any order. A missing or differently shaped union is a
foundation error. The designation is an identity fact only: layout follows
declaration order, as for any union, and a same-named union in another module is
an ordinary declaration (a user module cannot declare one, because the prelude
already exposes the designated type). [`prelude.brp`](standard_library/prelude.brp)
is the only implicit import: it supplies its written import scope to application
roots and user helper modules, and cannot be imported explicitly. Library
modules receive nothing implicitly; each imports what it uses, including base
types, and none may import a user module. The compiler requires
`--library-root DIRECTORY INPUT.brp OUTPUT.c`; there is no separate prelude
input or host-library fallback.

```blorp
import:
    ./foo: Foo
    ./foo_ops: Foo methods_only
    int: add

func main() -> Int:
    add(20, 22).to_string().length()
```

`module: Type` imports a type the module declares and enables its locally
declared receiver functions through UFCS. `Type methods_only` enables those
functions for a type the module declares or only imports, when the exact type
is independently visible; it imports no type or constructors. Named function
imports enable both direct and receiver calls. Imported and implicit types and
methods are never reexported by ordinary modules.

The checker associates receiver functions after accepting signatures, using
type identities and full applied arguments. It merges overlapping exposures of
the same function, distinguishes direct/UFCS availability in scope-owned typed
bindings, and reports competing applicable declarations without ranking by
import order. An unconstrained generic receiver is available through an
explicit named function import; it is not associated with every type.
The module rules above specify rejection behavior at the tested namespace/checker
boundary.

Closed builtin bodies remain ordinary module declarations. Parsing translates
quoted runtime keys to typed operations; checking validates their purity,
parameter and result contracts. Builtin type declarations belong only in the
designated base module. All diagnostics retain the source module and byte span.

C emission uses the whitespace required to separate C tokens and a final LF.
It adds no indentation or internal line breaks for presentation.
Nonnegative literals use `INT64_C`; negative literals negate a representable
positive magnitude. The minimum uses `<stdint.h>`'s `INT64_MIN`, avoiding an
unrepresentable positive magnitude. The new
[`return/42.brp`](test/e2e/fixtures/return/42.brp) example exits 42. Parser and
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

The [roadmap](ROADMAP.md) records upcoming language and memory responsibilities,
including the limits of current verification and required per-phase tests.
Fixed records support finite mixed fields, construction and field reads. The
[Pair example](test/e2e/fixtures/record/basic.brp) returns 7 with empty streams;
the generated record is a C struct passed by value without heap allocation or
reference counting. The [aggregate composition roadmap](ROADMAP.md#status-and-order)
tracks accepted mixed/generic records and plans general collections and recursive
data. Those later increments are not implemented here; correctness comes before
memory optimization.

Compiler source under `src/` stays within the agreed eventual subset: `String`, `Int`
(64-bit), `Float` (64-bit), `Bool`, `Char`, `Void`, `List`, `Option`, `Result`, `Dict`,
`Set`, records/unions and their fixed spellings, opaque types, generics,
purity, matching, loops, `var`, `?=`, imports, UFCS, anonymous functions
(`func(...)` values and closures), and quoted and multiline String literals.
Supporting every one of these in input programs is future work, not a claim
about this increment. Equality is written with concrete functions such as
`IntOps.equals` and pattern matching, never `==` or `!=`.

The compiler accepts tuple input as described above, but its own source keeps
avoiding tuple syntax until the pinned seed is rotated. Concurrency, parallelism,
tensors and dimension types, tuples in compiler source, `debug:`, other
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

Compare both compilers through C emission on the unmodified e2e fixtures:

```bash
blorp_2/scripts/compare-compilers --samples 3 --output blorp_2/build/comparison
# Narrow feedback loop; every output directory must be new.
blorp_2/scripts/compare-compilers --samples 1 \
  --fixture blorp_2/test/e2e/fixtures/return/zero.brp \
  --output blorp_2/build/comparison-zero
```

The macOS script checks host build freshness, builds the pilot once outside the
measurement, and runs both compilers serially on every selected `.brp` file.
Sample order alternates. It never edits fixtures, compiles their generated C,
or executes their programs. `--fixture` also accepts a directory. Explicit
`--existing-compiler` and `--pilot-compiler` paths select supplied executables;
the latter skips the pilot build. Supplied executables' source correspondence
and optimization settings are unverified unless provided by their version
output.

Pilot samples receive `standard_library` as an explicit library root,
recorded with its source snapshot.

`summary.tsv` reports minimum elapsed seconds and retired instructions across
samples, with existing/pilot ratios; values above one favor the pilot.
`samples.tsv` retains every sample, exit status, metric, C hash and size.
`fixtures.tsv`, `inputs/`, `sources.tar`, `provenance.txt` and `setup/` retain
input/source snapshots, binary hashes, optimization settings and build commands.
`raw/` holds exact command arguments, stdout, stderr, macOS time reports and C
outputs. Compiler/input/source/script changes detected during the run invalidate
all ratios. Failed or empty-output compilations are recorded, comparisons for
that fixture are withheld, and the command exits 1. Argument/setup errors exit 2;
existing output directories are preserved.

These are whole-process measurements, including startup, input reading and each
compiler's own prelude/library loading. The high-resolution wall clock also
includes the time/env wrapper overhead; retired instructions come from macOS
`time -l` and are explicitly unavailable if absent. Allocation instrumentation
is disabled, so allocations are unavailable. The default pilot and its runtime
are built at `-O0` without memory diagnostics. The host keeps its current build
settings, currently CLI `-O0` and runtime `-O2`; read its recorded version before
interpreting ratios. These fixture measurements do not establish self-compile
performance or isolate an individual compiler phase.

Self-compilation has one measurement and one gate, both in
`scripts/blorp2-fixpoint` (details in [scripts/README.md](../scripts/README.md#blorp-2-fixpoint)):

```bash
scripts/blorp2-fixpoint --frontier   # files of src that parse, then the first failing stage; exits 0
scripts/blorp2-fixpoint --prove      # A builds B, B builds C, all at -O0; B == C, A == B on every fixture, e2e under B
```

Both link every stage through this Makefile's `test-compiler` and
`link-test-compiler` recipes and keep their artifacts and `provenance.txt`
under `build/fixpoint/`. The parse count is the one
[`test_parse/test_source_tree`](test/unit/test_parse/test_source_tree.brp)
reports. If stage A (the host building the pilot) fails, or in `--frontier`
that suite fails or prints no count, the script exits 2: that is a setup error,
not a measurement.

The macOS command-behavior suite is separate from portable compiler unit tests:

```bash
bin/blorp test --suite --timeout 180 blorp_2/test/tooling
```

Each next increment adds an example, the exact grammar and semantic rules it
needs, positive and negative tests, and independently reviewed implementation.
Builders remain local; published results remain immutable; each semantic fact
has one authority. Function identity is declaration-list position; checked calls
contain resolved identities and diagnostic spans, and the checked program owns the
entrypoint. Checking permits ordinary self and mutual recursion, and rejects
generic recursive cycles that grow a type parameter beneath a union application.
The dependency analysis uses checked call substitutions and is discarded before
publication. Each checked function retains its validated signature beside its
resolved body. Emission reads only validated
facts and does not recheck purity or name scope. C function and parameter names are
synthetic, and unused parameters are explicitly discarded to keep warning checks
clean. Existing compiler internals are not pilot dependencies.

The compilation pipeline is entirely pure once its source inputs have been
loaded. `load_program` reads dependencies and invokes pure lexing and parsing to
assemble one complete `ParsedProgram` with shared names and module identities.
`compile(ParsedProgram)` composes pure checking, specialization, ordered-value
lowering, ownership insertion, independent verification and C emission;
diagnostic rendering is pure too. Local builders and `var` are allowed within
pure functions. The surrounding shell owns reading and writing files, printing,
process execution and timing. Loading publishes the complete parsed program and
source inventory explicitly to the pure pipeline and diagnostic renderer. Compiler phases must not
consult the filesystem, environment, clock or shared mutable caches. Any reports
or measurements produced by a phase are returned as data for the shell to present.

Compiler source calls concrete arithmetic, comparison and concatenation functions;
it does not use trait-dispatched operators. Concrete input traits do not expand
that compiler-source subset. The target library continues to expose ordinary
functions until the later Equatable library rollout; operator syntax remains
separate later work. The legacy host library's trait implementations do not
permit trait declarations or dispatch in compiler source.
Exact String equality uses the ordinary `string.equals` API in both libraries;
`src/utils/text.brp` retains only its concatenation bridge.
