# Blorp 2

A new compiler written in Blorp that emits C. Each increment starts with a
small program, defines the grammar it needs, and tests that program through
native execution. The existing compiler builds this compiler until it can
build itself.

The [imports and prelude reference](IMPORTS_AND_PRELUDE_PLAN.md) defines explicit
type/method visibility and a shared base/prelude for the temporary target
library. Its syntax and layout are implemented in this pilot.

Current language examples and limits are below; [grammar.ebnf](grammar.ebnf)
owns the formal syntax. The [roadmap](ROADMAP.md) owns planned increments,
immutable-fact and ownership contracts, and required validation. It consolidates
the earlier memory, aggregate, generics and recursion plans.

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
An unshadowed bare variant pattern selects that variant; another bare name
binds the complete matched value. Matches require exhaustive, useful arms.
The scrutinee runs once and only the first matching arm's result runs.
The companion [`match/values.brp`](test/e2e/fixtures/match/values.brp) covers
whole-value capture and field preservation; the separate
[`match/shadow.brp`](test/e2e/fixtures/match/shadow.brp) covers shadowing. Small
source fixtures expose these behaviors through `main`; exact full-width
values and evaluation order are checked directly at phase boundaries.
Pattern captures are immutable.

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
parameter shadowing and union values. Phase tests check exact full-width values
and evaluation order.

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
indented one level deeper than its pattern. Inline and block arms can coexist.
Each arm has its own scope; sibling arms can declare the same name. An explicit
`var` may shadow an enclosing binding, and its initializer sees the earlier
binding. Ordinary `=` still reassigns the nearest mutable binding or rejects
assignment to an immutable one. Companion fixtures return the
[updated value](test/e2e/fixtures/match/binding_current.brp), exercise the
[other branch](test/e2e/fixtures/match/binding_empty.brp), and preserve an
[outer value](test/e2e/fixtures/match/binding_outer.brp) across shadowing.

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
Nested/non-tail matches and joins are deferred.

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
inspection. The tests use temporary directories. `BLORP_CC` selects a C
compiler executable (default `clang`).
To run only end-to-end tests, use:

```sh
bin/blorp test --timeout 0 blorp_2/test/e2e
```

The host test runner's default 30-second deadline applies to the entire
generated suite, including the pilot build and every fixture. End-to-end runs
disable that deadline. `make -C blorp_2 test` runs e2e separately with
`--timeout 0`; the other suites retain their 180-second deadline.

Each end-to-end run builds the pilot at the beginning: the host compiler
generates `build/compiler.c` once, then the C compiler links one `-O0` executable
with allocation diagnostics enabled. Its executable path is passed
explicitly to every test group. Build failure stops the run before any fixture
executes. Existing artifacts are overwritten on the next run; there is no
persistent compiler cache or input manifest. For manual inspection,
`make -C blorp_2 test-compiler` performs the same unconditional build; it is
not a prerequisite for running the tests.

CI's macOS Blorp 2 lane waits for the existing compiler's build and restores
that toolchain artifact. It runs unit, runtime, grammar and tooling suites,
then the e2e suite with `--timeout 0`. The e2e suite uses that host compiler to
build the pilot once and test every fixture. Hosted macOS runners may omit
retired-instruction counters, so that CI step explicitly sets
`BLORP_2_INSTRUCTION_CHECK=disabled`. Allocation caps, strict leak reports and
all native ASan/UBSan cases still run. A failing suite blocks packaging and
uploads its test log.

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

Every host-compiled source module has a matching unit suite under `test/unit/`.
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
| union_values | 4,000 | 45,000,000 |
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
be Int, Float, String, Void, List[String], a finite record, or another finite inline union. Specialization
publishes complete payload types and defines child layouts before parents.
Constructors and projections carry the selected variant identity through
lowering, ownership and independent verification. Heterogeneous variants use
distinct members of a tagged C union. String-bearing unions remain inline and
own only their active variant's children. Their generated dup/drop helpers visit
that child path; the union root has no heap allocation or reference count.
Nullary and unmanaged active variants keep the same aggregate obligation while
performing no child ownership work. Finite nesting composes through child-first
helpers and managed record roots; recursive layouts remain unsupported.
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
and `Variant(Int, String)` declares two ordered fields. `Variant(Pair[Int, String])` names one payload and is valid. Lists retain
the existing String-only concrete element restriction.

Constructors evaluate each field expression once in written order. Patterns
write one distinct binder or `_` for each position, such as `Pair(left, _)`.
Each managed stored occurrence acquires an independent obligation, including
`Pair(text, text)`; an escaped managed child remains live after its parent retires.
Nonempty variants use inline C field structs, while nullary variants have no
payload member. Lists, nested patterns and recursive aggregate types retain
their existing restrictions.

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
part of this increment. Recursive data remains a separate ownership increment;
cyclic runtime data is forbidden.
The [recursive-data roadmap](ROADMAP.md#recursive-data) defines the independently validated
increments and the ownership requirements for later recursive data.
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
mutation oracle. The [tail-loop roadmap](ROADMAP.md#tail-recursion-follow-ups)
retains the unfinished generic and managed loop requirements.

The [numeric accumulator](test/e2e/fixtures/tail_recursion/accumulator.brp)
decrements an Int while adding one to a second Int. The regular suite checks
exact stdout for zero, one, seventeen and one million iterations under `-O0`
and sanitizers. This observes the completed count independently of the process
exit status. The older hexadecimal countdown remains a separate carry/borrow
case; its constant result alone does not prove the iteration count.

For a longer stress run, compile the same fixture and run its normal entrypoint
with a nonnegative iteration argument:

```sh
blorp_2/build/compiler --library-root blorp_2/standard_library_temp \
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


## Finite mixed records

Fixed records can contain any currently supported finite concrete type, including
Float, String, Void, List[String], other records and instantiated unions:

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
declarations, recursive data, field assignment and record-update syntax remain
unsupported. Recursive declaration references reject before layout expansion.
The [roadmap](ROADMAP.md#first-increment-mixed-finite-records) tracks final
integrated acceptance and later aggregate extensions.

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
specialization expands them. Record-owned List[T] fields retain the current
concrete List[String] limit.

Checking validates concrete List requirements through every nested record and
union application, including annotations on unused functions. A finite
declaration walk records which parameters must be String once, then concrete
annotations and inferred call signatures consult those requirements. Symbolic parameters
remain valid until their concrete arguments are known. Phantom parameters impose
no stored-field requirement, but their supplied types must still be valid.
Void remains a valid type argument; the separate rule forbidding pure functions
from returning Void still applies. When generic forwarding exposes that rule
only during specialization, diagnostics retain a call-site origin per
instantiation chain. Concrete written type arguments establish their own origin;
caller-dependent arguments carry the outer origin. Mixed fixed and symbolic
arguments can therefore retain an outer location. Argument-specific provenance
remains future work. Requirements hidden only inside a generic function's body can still become
known during specialization: the checker does not propagate body constraints
through the generic call graph yet. Specialization retains that rejection guard
at the aggregate field's written annotation.

## Grammar for this increment

This specification defines only the examples' language: functions with an optional
return annotation (omission means `Void`), an ordered list of explicitly typed parameters, an optional ordered list of type
parameters on functions, fixed unions and fixed records with
one or more finite fields after substitution. Union variants have zero or more ordered fields using ordinary type annotations; concrete fields
specialize to Int, Float, String, Void, List[String], a finite record, or another finite inline union. A function
body has zero or more ordered binding or Void expression statements followed
by a final expression or a tail match with inline arm results or statement blocks. Expressions
start with `void`, a signed Int64 or decimal Float64 literal, a quoted UTF-8 String literal, a binding or variant name, a record literal,
or an application with an ordered list of arguments. UFCS calls and record
field suffixes may follow that expression.
Arguments use the same expression grammar, so direct and receiver calls may nest.
No other declarations, expressions, literals, or statements are supported.
Single-line comments begin with `--`; docstrings remain deferred.

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
  comments cannot continue expressions across lines. `---` is also an ordinary
  line comment. Comments permit ASCII bytes, including tabs; CR and non-ASCII
  bytes are rejected at their original byte offsets. There is no docstring
  metadata or documentation fence syntax yet.
- The entire indentation prefix of a real code line uses tabs only or spaces in groups of four.
  Body and variant lines require depth one: one tab or four spaces. Match arms
  require depth two: two tabs or eight spaces. Arm-block lines require depth
  three: three tabs or twelve spaces. Mixed indentation is invalid. The lexer
  emits a newline token ending each code line, an indent token for a line one
  level deeper and a dedent token per closed level, rejecting a deeper jump;
  the parser reads blocks from those tokens and never compares depths.
- Spaces may separate tokens and trail each line. They are required between
  `func` and the function name, and between `fixed`, `union` and the type name.
  Identifiers are scanned as whole words, so
  `funcmain` is one identifier. The two characters of `->` are adjacent.
  Spaces may surround a UFCS dot and its parentheses, as in `1 . one ( )`.
  Outside comments, tabs occur only in the indentation prefix. Each expression stays on one line,
  including match scrutinees, binding initializers and final arm results.
- `func`, `pure`, `match`, `var`, `void`, and lone `_` are reserved. The optional `pure` qualifier precedes `func`
  with spaces between the two keywords. Function, parameter and type names are
  identifiers whose meaning is checked after parsing.
- A function may declare ordered type parameters, as in
  `pure func second[A, B](first: A, second: B) -> B:`. Each name starts with a
  capital ASCII letter and contains only ASCII letters and digits. Names must
  be distinct within a declaration. Explicit function type arguments at calls
  are unsupported; argument types and known expected results constrain the type
  parameters.
- `fixed union Type:` introduces one or more variants on indented
  lines. `fixed` and `union` are contextual header words and remain valid names
  elsewhere. A variant is bare or declares an ordered list of field types, as in
  `Number(Int)`, `Box(T)` or `Pair(String, String)`. A union may declare ordered
  parameters with `fixed union Result[T, E]:`. Every field annotation uses ordinary
  type syntax in the union declaration's module and parameter scope, including
  recursive type arguments such as `Box[Box[Int]]` or `Result[T, Box[E]]`.
  Empty declaration parentheses remain unsupported. Concrete field layouts may
  contain Int, Float, String, Void, List[String], finite inline unions or records.
- `fixed record Pair { first: Int, second: Int }` declares a nominal record
  on one line. Field names must be distinct and have supported finite concrete
  types after specialization. `fixed record Box[T] { value: T }` declares ordered
  type parameters; their identity belongs to this record. `record` remains a
  contextual header word. Empty and recursive records remain unsupported. Representation follows the
  inline-versus-managed field policy described above.
- `{ second = 9, first = 7 }` constructs the nominal record required by a
  helper return type, receiving parameter or existing binding reassignment.
  Every field appears exactly once. Expressions evaluate in written order;
  field order in the literal may differ from declaration order. A new inferred
  binding alone supplies no record context. `{}` parses and reports the first
  missing field. Declarations and literals stay on one line; trailing commas,
  updates and field assignments are unsupported.
- `pair.first` reads a declared field; `pair.read_first()` remains a UFCS call.
  A uniquely resolved immediate UFCS receiver parameter may supply a nominal
  literal context, including a head with unresolved generic arguments.
  Literal fields constrain those arguments on the same expression-local inference
  state. A field read supplies
  none, and later operations never infer a literal's type through an earlier
  field read. Earlier generic sibling evidence alone does not choose a record
  literal's owner. Records pass and return by
  value, including through existing generic functions whose arguments infer
  a concrete record. Copies and whole-binding reassignment preserve old aliases.
- `match expression:` starts a nonempty sequence of depth-two arms written
  `Pattern: expression` or `Pattern:` followed by a depth-three block of
  ordered binding or Void expression statements and a mandatory final expression. A pattern is a bare name,
  `_`, or a constructor name
  followed by parentheses containing zero or more comma-separated field patterns. A field
  pattern is a binder or `_`; literal and nested field patterns are unsupported.
  A nullary constructor pattern may be written `Empty` or `Empty()`. `Number()`
  is valid syntax but fails semantic arity checking for a one-field constructor.
- A binding line is `name = expression` or `var name = expression`, at depth
  one in a function or depth three in an arm block. Its initializer occupies
  the same line. Bindings and bare expression statements may interleave before
  the mandatory final expression or function tail match. A non-final bare
  expression must return Void; bind or return other values. Bindings inside
  arguments and annotations are unsupported. An arm block cannot contain a
  nested match.
- Integer literals are decimal values from `-9223372036854775808` through
  `9223372036854775807`, with an optional adjacent minus. `-0` is accepted
  and has value zero. Leading zeros (`00`, `-01`), plus signs, separated minus
  signs and arithmetic operators are rejected. The lexer preserves the whole
  digit run; the parser validates spelling and range before converting it.
  A dot followed by a function name starts UFCS: `42.identity()` is a call;
  `42.5` is a Float literal.
  Non-ASCII bytes outside quoted Strings and CRLF source line endings are rejected.
- Every token must be consumed. Malformed declarations and statements are errors.

Semantic rules:

- Exactly one root function must be named `main`. It takes no parameters or one
  `List[String]` parameter, and returns `Int` or `Void`. The argument list includes the
  executable name at index zero. A helper
  takes zero or more explicitly typed parameters with distinct names. Helper
  annotations use the supported scalar, finite record/union, List[String] or
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
  Variants in different unions may share a spelling; expected type chooses the
  owner. `First()` is invalid because a payload-free constructor is a value;
  `Number(expression)` supplies its one field; `Pair(left, right)` supplies two.
  Each complete field type is established by the receiving union instance.
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
- Each argument must match its receiving type, as must the final expression
  of a non-Void function. A Void function's final expression synthesizes its own type
  and is evaluated and discarded.
  Unary call-edge mismatches highlight the callee name; multiple-argument
  mismatches highlight the disagreeing argument occurrence;
  constructor lookup errors highlight the variant name. Return mismatches highlight
  the complete expression, excluding indentation and trailing spaces.
- A match scrutinee must synthesize a declared union type from a binding or
  function result. `match Empty:` and `match Number(42):` lack a receiving type;
  no type is guessed from patterns or the containing function's return type.
  Integer scrutinees are outside this increment. Each arm of a non-Void function
  must match that function's declared result type, which may differ from
  the matched union. Void functions evaluate and discard the selected arm's
  result. All arms are checked, including ones a constant scrutinee
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
  an existing value refer back to its replacement. Recursive data declarations
  remain deferred until their managed layouts and bounded-stack destruction are
  supported and independently verified.
- Generic declarations are checked once with distinct rigid type parameters, including
  unused bodies. An arbitrary `T` cannot return an Int literal or call a
  concrete Int/String runtime operation. Parameters cannot share a name with
  `Int`, `String`, or any declared union; separate declarations may reuse `T`.
  `main` and functions with closed builtin bodies cannot declare type parameters.
  Direct and UFCS calls solve private call variables structurally, processing
  argument constraints before a declared expected result. Later sibling evidence
  can solve an earlier pending call. Repeated occurrences, including structural
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
  owning inline unions and managed records before lowering. Recursive declaration
  forms remain unsupported.
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
  fresh ordinary String owner. COW, joins and managed annotated loops are deferred.
- Parenthesized expressions, recursive layouts, nested matches,
  guards, qualified/nested/literal patterns, constructor UFCS, multiline chains,
  non-tail matches, and function
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
unions. A bare selector selects a local function or a visible type; if both
exist, the selection is ambiguous. `Option(Some, None)` selects a union and those
constructors, while `Option()` selects the union without constructors. Both
forms also enable local receiver functions. `Foo methods_only` adds receiver
functions and requires the exact type independently visible in the caller.
Imports precede declarations. Bare paths select target-library modules when
the required explicit library root is supplied. Record type imports and type
forwarding are supported. Aliases, wildcards, explicit reexport syntax, qualified
calls and `private` are deferred.

Each module owns its declarations; same-spelled declarations in different
modules have distinct identities. Imported functions resolve their annotations
and calls in their defining module, and importing them does not expose their
siblings or types. Their nominal signature types remain usable as inferred
values. Direct calls and UFCS use the caller's visible functions. Only a local
`main` in the root file provides the entrypoint; another module's `main` is an
ordinary function.

Paths are normalized absolute logical paths for one invocation; symlink aliases
are not canonicalized. A diamond loads a shared path once. Import cycles,
including a module importing itself, are rejected after loading and before
checking: a depth-first walk over resolved targets in load order reports the
first cycle at the import that closes it, naming its modules by display path.
Every loaded module is checked, including unused declarations. Diagnostics
retain the source file for primary errors and secondary notes independently.

The [module validation report](../benchmarks/results/blorp_2_modules_2026-10-11.md)
retains the independent reviews and measurements; the
[imports reference](IMPORTS_AND_PRELUDE_PLAN.md) defines the current visibility rules.

## Temporary target library and Int addition

[`int/add.brp`](test/e2e/fixtures/int/add.brp) imports a concrete function:

```blorp
import:
    int: add

func main() -> Int:
    add(20, 22)
```

It exits 42. `20.add(22)` uses the same declaration through UFCS. Int addition
wraps at the signed 64-bit limits. Arithmetic operators and traits remain
unsupported.

Supply the target library explicitly:

```sh
blorp_2/build/compiler --library-root blorp_2/standard_library_temp \
  blorp_2/test/e2e/fixtures/int/add.brp \
  blorp_2/build/add.c
```

Bare import paths resolve only under that directory. Relative imports resolve
beside their importer, including inside library modules. Missing roots and files
produce diagnostics; there is no local-file or host-library fallback. Library
modules use the ordinary module pipeline and preserve declaration identities.

The [temporary library](standard_library_temp/README.md) retains upstream
provenance; full [reference copies](reference/standard_library/README.md) live
outside compilation inputs. Its active declarations provide the calculator's
ordinary unions and concrete numeric, conversion and IO functions.
Their explicit builtin bodies select closed compiler-known operations. Module functions
may declare these builtin bodies with the exact concrete runtime signature,
without statement prefixes, generic parameters or tail annotations. Unknown
labels and signature mismatches are errors. There is no arbitrary foreign
symbol binding. The base types module owns `Int`, `Float`, `String`, `Void` and unary `List`.
The [validation report](../benchmarks/results/blorp_2_int_add_2026-10-11.md) records
strict tests, native fixtures, matched costs and the existing compiler's
different trait-based `add` import surface.

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

The fixed escapes are `\n`, `\r`, `\t`, `\0`, `\\`, `\"`, `\'`, `\{` and
`\}`. A Unicode escape `\u{X...}` has one to six hexadecimal digits and names a
valid scalar from U+0000 through U+10FFFF, excluding U+D800 through U+DFFF.
Embedded NUL counts toward length and is preserved. Raw ASCII control bytes,
DEL, malformed UTF-8, invalid escapes and missing quotes are errors with help.
Quoted literals stay on one source line. Interpolation, raw strings and
multiline literals are deferred; write `"$\{"` to preserve literal `${` text.

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
byte emission and repeated escape decoding.

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
`List[String]` parameter. A pure function cannot return Void, whether explicitly
annotated, omitted, or established by generic instantiation.

```blorp
import:
    io: print
func main():
    print("Hello, World!")
```

This has the same behavior as `func main() -> Void:`. A final `17` would also
exit 0 after being evaluated and discarded. A `pure func main()` declaration
is rejected; pure main must return Int. The
[main signature fixtures](test/e2e/test_main_signatures.brp) cover pure and
impure Int entrypoints and explicit and omitted Void entrypoints, with and
without arguments, through their ordinary native main functions.

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
fixed unions in `standard_library_temp/_base.brp`; neither spelling receives
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
tests cover counted NUL bytes separately. Only concrete `List[String]` is
supported in this increment; generic helpers may abstract over it.

The [argument validation report](../benchmarks/results/blorp_2_arguments_2026-10-12.md)
records the entrypoint contract, ownership checks, native tests and matched costs.

`string.equals(first, second) -> Bool` compares complete byte sequences.
`int` exposes concrete `add`, `subtract`, `multiply`, `divide`, `remainder`
and `to_string`, plus `equals(Int, Int) -> Bool`. Equality uses the complete
signed 64-bit values and ordinary explicitly bound Bool constructors.
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

Runtime declarations explicitly bind result roles, for example
`builtin("string.parse_int", Some, None)`. Checking accepts the exact nominal
union, constructor payloads, arity and purity once. Specialization translates
declaration identities to concrete constructor identities. Emission receives
those roles directly; constructor names and ordering carry no hidden semantics.

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
function names as Int, plus `to_string`. Named function imports permit direct
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
blorp_2/build/compiler --library-root blorp_2/standard_library_temp \
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

The [calculator component tests](test/unit/test_option_contracts.brp),
[input ownership tests](test/unit/test_option_ownership.brp),
[Float projection tests](test/unit/test_float_literal.brp) and normal-main
fixtures protect different boundaries independently.

All nine calculator increments are complete. The
[validation report](../benchmarks/results/blorp_2_calculator_2026-10-12.md)
records 1,456 passing Blorp component checks, 40 native runtime cases, 299 native
e2e executions, independent reviews and matched cost measurements.

## Architecture

The command reads the root program, the configured foundation and ordinary
prelude, and their dependencies once per normalized path, then writes C:

```sh
bin/blorp run --no-format blorp_2/src/main.brp -- --library-root blorp_2/standard_library_temp input.brp output.c
```

The impure command shell owns file I/O and printing. Compilation and
diagnostic rendering are pure. The pipeline publishes these complete results:

1. Lexing produces tokens with source spans and an explicit end-of-source span.
   Integer tokens retain their complete raw spelling; indent and dedent tokens
   span the indentation prefix, and each token records whether a space precedes
   it. Trivia is skipped over the original
   source bytes; no rewritten source or comment metadata crosses the boundary.
2. Parsing produces function and union declarations, payload and parameter
   annotations, written names, ordered statement syntax, expression syntax, and structured match bodies.
   Match patterns preserve names and field syntax without deciding whether a
   bare name denotes a constructor or binding. Each expression has a literal,
   name, or direct application base with ordered recursive arguments, followed by
   receiver applications with ordered explicit arguments. Direct and receiver
   syntax stay distinct because their target lookup differs.
   Every expression records its consumed token span directly, without reconstructing
   locations from names or literal values.
   A shared interning builder assigns one opaque `NameId` per spelling across the module inventory. Program
   assembly ([assemble.brp](src/assemble.brp)) seals the complete syntax and immutable name table in an opaque `ParsedProgram`.
   Its [declaration inventory](src/declarations.brp) issues function, record,
   union and owner-qualified variant IDs once from the raw syntax. Consumers
   carry those IDs through accepted and checked rows; vector positions are
   traversal counters, not another identity producer.
   Integer conversion accumulates negatively against derived range cutoffs,
   checking before multiplication so even the minimum is represented safely.
3. A frozen namespace maps each module's visible function names to original
   declaration IDs. Selective imports do not reexport imported names, and an
   imported function retains its defining scope. Checking resolves nominal union and owned variant identities, then publishes
   one authoritative signature per function. A private resolution context borrows
   accepted declarations, signatures and namespace facts. Target resolution returns a complete
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
   Each arm publishes its ordered statements and result. The current block's
   first local ordinal establishes which declarations belong to that block;
   semantic origin alone does not determine scope membership.
   Constructors retain their owning union and variant identities. Checking
   publishes an opaque program with its entrypoint identity. Call notation is erased
   after target resolution. A user call carries its checked substitution in its
   target variant; a runtime call cannot carry one. Rigid type parameters have
   explicit function-, union- or record-declaration owners.
   Checking returns either the complete `CheckedProgram` or an opaque
   `CheckFailure` retaining the original parsed program and a nonempty
   `CheckErrors` collection. The current checker stops at the first error, so
   that collection is a singleton. Failures contain closed semantic variants,
   types, owner-qualified identities, argument positions and source occurrences;
   temporary builders do not escape. [check_render.brp](src/check_render.brp)
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
   complete calls and discards the temporary solver.
   Nominal requirements introduced by generic calls are checked child-first
   during freezing; a later fatal name error can precede that new requirement
   failure. Existing direct List and pure-result readiness checks retain their
   established priority.
   [check.brp](src/check.brp) only composes these checks and seals their result;
   [check_model.brp](src/check_model.brp) owns published semantic data,
   [check_errors.brp](src/check_errors.brp) owns typed rejections, and
   [check_values.brp](src/check_values.brp) privately owns expression inference.
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
   pattern retains every position as an optional `BindingId`, with `None` for a
   wildcard. A zero-field vector remains distinct from a wildcard position.
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
   type and source span. Match-arm computations remain in their branches.
   Every arm starts with the enclosing binding map, lowers each named capture
   at its declared field ordinal and then its statement sequence, and publishes
   a branch-local value block. Sibling arms
   share only the function's value allocator, preserving distinct identities.
6. Concrete specialization owns storage and child-ownership representation.
   Its read-only ownership query classifies a concrete value as having no
   ownership, being a managed String leaf, List[String] or record root, or
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
   until a call has established its result owner. Tail-match
   arms publish the same ownership operations and typed return transfers as a
   straight-line block. Value and owner identities remain function-wide; sibling
   arms cannot observe each other's values or obligations.
7. Independent verification checks the actual operations against representation
   and call contracts, rejecting dead/wrong owners, invalid borrows and
   undisposed obligations. Raw ownership IR does not preserve checking's sealed
   match proof, so verification independently requires nonempty, exhaustive,
   useful arms with valid unique variants and at most one final default.
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
   A match uses its evaluated scrutinee once and switches on its tag. Arm-local field
   projections occur only in the selected branch; a whole-value binder reads
   the saved value. Emission consumes resolved lowered labels and values without repeating
   resolution, arity, purity, or coverage checks. Its result can report an
   internal lowered-reference error instead of silently choosing a C layout;
   source-language acceptance is already complete. Retains/releases project the
   explicit operations; emission does not invent owners or cleanup.

The names module owns the spelling table and constructs the entrypoint's `main`
identity. Every module parse extends that shared authority, including the
designated foundation's five builtin declarations. The sealed program retains
the entrypoint spelling identity and designated module identities; checking
validates builtin authority once before constructing the namespace. Parsing uses
string lookup only in its local interning builder and publishes the immutable table.
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
Managed control-flow joins and general pass infrastructure remain future work.

The target library's [`_base.brp`](standard_library_temp/_base.brp)
owns the builtin Int, Float, String, Void and List identities, and the ordinary
Bool, Option and Result unions. It is the only module that may declare builtin
types, and any module may import it as `_base`. [`prelude.brp`](standard_library_temp/prelude.brp)
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

`module: Type` imports the type and enables the selected module's locally
declared receiver functions through UFCS. `Type methods_only` enables those
functions when the exact type is independently visible; it imports no type or
constructors. Named function imports enable both direct and receiver calls.
Forwarded types retain their original declaration identity. Constructor
selection through a forwarding module resolves the original union's variants.
Imported and implicit methods are never forwarded by ordinary modules.

The checker associates receiver functions after accepting signatures, using
type identities and full applied arguments. It merges overlapping exposures of
the same function, distinguishes direct/UFCS availability in scope-owned typed
bindings, and reports competing applicable declarations without ranking by
import order. An unconstrained generic receiver is available through an
explicit named function import; it is not associated with every type.
[The imports design](IMPORTS_AND_PRELUDE_PLAN.md) specifies rejection behavior
and the tested namespace/checker boundary.

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
(64-bit), `Float` (64-bit), `Bool`, `Void`, `List`, `Option`, `Result`, `Dict`,
`Set`, records/unions and their fixed spellings, opaque types, generics,
purity, matching, loops, `var`, `?=`, imports, UFCS, and quoted and multiline
String literals. Supporting every one
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

Pilot samples receive `standard_library_temp` as an explicit library root,
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
it does not use trait-dispatched operators. Future traits and operator syntax can
select these same functions, keeping one implementation per operation. The current
host library declares some concrete functions inside trait implementations; the
future subset library will expose ordinary function declarations instead.
`src/text.brp` supplies exact string equality using equal byte lengths and an exact
prefix check because the host library has no ordinary string-equality function.
