# Guaranteed self-tail recursion

Status: delivered MVP, 2026-10-10: checked direct-self loops for nongeneric,
unmanaged functions. Generic and managed loops, mutual recursion and trampolines
remain deferred as specified below. Read this directory's
[AGENTS.md](AGENTS.md) and the [parent instructions](../AGENTS.md).
The [README](README.md) and [grammar](grammar.ebnf) describe current support.
This extends the function-recursion increment in [RECURSION_PLAN.md](RECURSION_PLAN.md).

## Contract and first working example

Contract: an `@tail_recursive` function's direct self calls must all
be in supported tail positions and become explicit loop backedges. Otherwise
compilation fails. The guarantee holds at `-O0`, independently of C optimizer
tail-call elimination. It bounds stack growth attributable to these self edges;
it does not prove termination, bound heap use, eliminate other calls, or bound
stack use through a cycle of different functions.

Start with a nongeneric function using today's unmanaged values:

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

Expected exit status: 7, with empty stdout and stderr. This exercises a base
arm, a backedge and simultaneous argument replacement: the incorrect sequential
overwrite `left = right; right = left;` would return 9. A companion returns
the new left value, expecting 9. A smaller companion
uses `walk(step: Step)` and returns 7, as in the existing recursion fixture.
Place the new real-main inputs under `test/e2e/fixtures/tail_recursion/`.

### First increment

- Support direct calls and UFCS self calls, both pure and impure functions,
  binding prefixes, arm-local bindings, and existing tail matches.
- Accept nongeneric functions whose parameters, result and every evaluated
  intermediate value are unmanaged under the current concrete contracts:
  `Int`, supported fixed records, and supported fixed union instances. An
  unmanaged phantom `Marker[String]` is not a managed String value.
- Reject an annotated generic declaration for now, including an unused one.
  Ordinary generic and recursive functions retain their current behavior.
- Reject any evaluated String value in the annotated function, including an
  unused initializer or a value already dropped before its tail. Calls to
  helpers returning unmanaged values are allowed; their internal behavior is
  outside this function's guarantee.
- Require at least one direct self call. An annotation on a nonrecursive or
  mutual-only function is an error, preventing a misleading promise.
- Zero-parameter self recursion is valid, including the language's `main`.
  It need not terminate. Test this through phases, without running an infinite
  native fixture. The external C main wrapper retains its existing ABI.
- Do not change unannotated C output or add automatic tail-call optimization.

No mutual-recursion trampoline, CPS conversion, general CFG/SSA framework,
closure support, arithmetic, recursive datatype, or tail-modulo-constructor
transformation is required by this example.

## Established precedents and deliberate choices

These primary sources were checked on 2026-10-10:

- Scala's [annotation contract](https://www.scala-lang.org/api/3.x/scala/annotation/tailrec.html)
  makes failure to generate a loop a compilation error. Its
  [tagged compiler implementation](https://github.com/scala/scala/blob/v2.13.8/src/compiler/scala/tools/nsc/transform/TailCalls.scala#L209-L275)
  uses symbol identity, rejects mandatory annotations without recursive calls,
  and checks for self calls left after transformation. Borrow those principles,
  without importing JVM constraints or Scala's whole transformation.
- Elm's [optimizer](https://github.com/elm/compiler/blob/main/compiler/src/Optimize/Expression.hs)
  distinguishes `TailCall` from ordinary calls and traverses tail branches
  separately from their arguments and scrutinees. Use an explicit typed
  control-flow distinction, with Blorp identities instead of spellings.
- OCaml's [tailcall attribute](https://ocaml.org/manual/5.5/attributes.html)
  checks an individual application and warns when it is not optimized. Blorp's
  proposed function annotation is deliberately a hard error covering every
  direct self call. OCaml's
  [tail-modulo-constructor transformation](https://ocaml.org/manual/5.5/tail_mod_cons.html)
  addresses a different class of calls; construction after recursion remains
  non-tail here.
- Lean's [borrow inference documentation](https://lean-lang.org/doc/api/Lean/Compiler/LCNF/InferBorrow.html)
  explicitly accounts for decrements that would follow recursive tail calls.
  This is why managed support needs an ownership design, beyond recognizing
  source tail positions. Lean's solution does not imply changing the pilot's
  entire borrowed-argument ABI.
- Clang's [musttail attribute](https://clang.llvm.org/docs/AttributeReference.html#musttail)
  can guarantee tail calls but has type, calling-convention and lifetime
  constraints. For self recursion, an ordinary C loop provides the required
  guarantee without a compiler-specific attribute or an optimizer assumption.

The existing Blorp checker
([decl.brp](../blorp/src/compiler/stage_06_typecheck/decl.brp),
`check_tail_recursive_function_body`) checks tail position and permits an
annotation without self calls. Its supported Core lowering
([tailrec.brp](../blorp/src/compiler/stage_09_core/tailrec.brp),
`should_lower_unmanaged`) is separate and excludes entrypoints and functions
without parameters. The pilot proposal deliberately tightens the annotation
to a lowering guarantee and rejects annotations without self calls. This
proposal does not change the existing compiler's contract or repair its
recursive internal tree traversals.

## Syntax, tail positions and diagnostics

Recognize exactly `@tail_recursive`, once, before a function's optional `pure`.
Accept both the standalone spelling above and `@tail_recursive pure func ...`.
Do not reserve `tail_recursive` as an ordinary identifier or introduce a
general annotation framework. Runtime prelude declarations do not accept it.
The proposed change to the restricted EBNF is:

```ebnf
tail_annotation = "@tail_recursive" (required_spaces | spaces newline) ;
function        = [ tail_annotation ] function_header body ;
```

Existing rules for blank lines, indentation, comments and function headers
remain in force. Unknown, duplicate, misplaced, dangling and argument-bearing
annotations receive parser diagnostics with exact spans and useful help.
Parsing stores `Option[Span]` for this one optional annotation; its spelling
does not travel into semantic stages.

Checking first establishes ordinary name, arity, type and purity facts. It
then validates the annotation against resolved `FunctionId`s. A function or
binding with the same spelling is not evidence of recursion. Check unused
functions and every arm as usual; do not infer reachability from constant
arguments or rely on later C optimization to remove a bad call.

| Occurrence of a direct self call | Tail position? |
| --- | --- |
| Whole final function expression | Yes. |
| Whole final expression of a tail-match arm | Yes. |
| Last UFCS invocation producing that final result | Yes; its receiver and explicit arguments are not tail contexts. |
| Binding initializer, including `result = walk(...); result` on separate lines | No in this increment; alias-tail analysis is deferred. |
| Match scrutinee, call argument, record field or constructor payload | No. |
| Call followed by another invocation or field read | No. |

For example, `walk(Stop, right, left).identity()` is non-tail even if
`identity` returns its argument. So is `identity(walk(Stop, right, left))`.
Other helper calls may occur while preparing the next arguments and must keep
their existing source evaluation order.

Extend the closed `CheckErrorKind`, with semantic payloads and occurrence
spans; only `check_render.brp` constructs these messages. Proposed errors:

| Typed error | Primary span | Message and help |
| --- | --- | --- |
| `NonTailSelfCall(FunctionId)` | Offending call | “recursive call is not in tail position”; “return this call directly, or remove @tail_recursive”. |
| `NoSelfRecursion` | Annotation | “@tail_recursive function has no direct self call”; “remove @tail_recursive; mutual recursion is not covered by this annotation”. |
| `GenericTailRecursionUnsupported` | Annotation | “generic @tail_recursive functions are not supported yet”; “use a nongeneric helper, or remove @tail_recursive”. |

Within an annotated function, preserve ordinary checking errors first, then the
annotation's generic restriction, the first non-tail self call, absence of
self calls, and finally concrete ownership admission. Pin this order
in tests. Preserve annotation and complete call spans directly; do not recover
locations from names or rendered text.

Ownership insertion owns the unmanaged admission check, reusing
`own.brp:value_ownership` on the concrete signature and every evaluated value.
Do not duplicate physical representation classification in the checker.
Use its existing diagnostic result with the annotation span for a managed
signature, or the offending definition span for a managed intermediate,
message “managed values in @tail_recursive functions are not supported yet”,
and help “use an unmanaged helper, or remove @tail_recursive”. Tests assert
this diagnostic at its owning boundary. The independent verifier checks the
restriction again against actual raw IR, including managed definitions
already dropped; it does not trust insertion's result flags.

## Complete facts through the existing phases

Do this inside existing phases; [main.brp](src/main.brp) keeps the same pure
pipeline. The following names illustrate the data, rather than mandating
extra public types or modules:

```text
FunctionExecution = OrdinaryCalls | SelfTailLoop(annotation span)
CheckedExit       = ReturnExpression(CheckedValue)
                  | RecurWith(ordered argument expressions, call span)
LoweredExit       = ReturnValue(ValueId)
                  | RecurValues(ordered ValueIds, call span)
OwnedExit         = ReturnTransfer(existing return contract)
                  | RecurValues(ordered unmanaged ValueIds, call span)
```

One execution variant records the accepted self-tail control flow; there is no
additional `has_recur` or `validated` flag. `Recur` is implicitly an edge to
the enclosing function's entry, so it cannot name a different function. The
execution contract belongs on the function, separately from its callable ABI
signature. For a final UFCS self call, its receiver argument contains the
original base and preceding operations, followed by the explicit arguments;
each is evaluated once in source order. The normal recursive call target and
fictitious call result are removed when that
terminal is constructed. This is a control-flow operation, not a `ValueId`
that happens to contain a call.

| Producer and lifetime | Owned fact and consumer contract |
| --- | --- |
| Parsing; one source bundle | Optional annotation occurrence and typed syntax; spelling is used here and for diagnostics. |
| Checking; one sealed checked program | Validates every self-call context using its declaration `FunctionId`, then publishes execution kind and explicit terminal self calls. Direct and UFCS syntax converge here. |
| Specialization; one sealed concrete program | Translates argument values and preserves terminals/execution kind. Current-function identity becomes its `FunctionInstanceId`; it does not resolve names or redo source tail-position checking. |
| Lowering; one concrete function | Evaluates next arguments once, left to right, and publishes their `ValueId`s. Parameter value definitions describe each iteration's input; source binding reassignment still creates distinct values. |
| Ownership insertion; one body/edge | Admits only unmanaged concrete signatures and evaluated values using the existing classification authority, then marks every terminal argument as used at the exit. This first slice has no loop-carried owners or retain/release operations. Existing last-use helpers live in `own.brp`; there is no separate uses phase. |
| Independent verification; raw ownership input to sealed `VerifiedProgram` | Checks the loop context, exact terminal arity/types, defined and in-scope operands, unmanaged representation, and absence of live owners on every backedge. Rejects a surviving ordinary call to the enclosing concrete function anywhere in a loop body. |
| Emission; verified input | Projects identities to C names and emits parameter replacement plus `continue`; it makes no new tail-position or ownership decisions. |

Share the leaf terminal between function tails and match-arm results.
Currently [lower.brp](src/lower.brp) has a mandatory `ValueBlock.result`, and
[own.brp](src/own.brp) has a mandatory `OwnedArm.result: ReturnTransfer`.
Replace those assumptions in the same slice; adding only a function-level
`RecurTail` would leave match arms unable to express recursion. Keep matches
at their current grammar positions; no nested-match feature is needed.

`FunctionId`, `FunctionInstanceId`, `BindingId`, `ValueId` and `OwnerId` keep
their existing authority and lifetimes. A backedge binds a new iteration's
parameter values; it does not mutate source value identities. No cross-function
index or cache is needed. Local builders publish once and are discarded.
The verifier starts each iteration from the same typed parameter contract;
without managed carriers, there is no ownership fixed-point analysis.

## C shape and simultaneous replacement

The working example should have this shape (illustrative names and layout):

```c
static int64_t walk(enum Step step, int64_t left, int64_t right) {
    while (1) {
        /* Parameter snapshots and all binding-prefix work belong here. */
        switch (step) {
        case Stop: { return right; }
        case Once: {
            enum Step next_step = Stop;
            int64_t next_left = right;
            int64_t next_right = left;
            step = next_step;
            left = next_left;
            right = next_right;
            continue;
        }
        }
    }
}
```

All next arguments are captured before any parameter slot changes. Sequential
`left = right; right = left;` would silently lose the old left value. Reuse
the existing immutable `ValueId` C locals as these captures; illustrative
`next_left`/`next_right` above do not require a second layer of copies.
The current emitter already captures parameter reads in `const vId` locals,
so assign parameter slots directly from the prepared argument value locals.
Keep parameter snapshots, prefix definitions and match-arm operations inside the
loop so they execute again with the next iteration's inputs. Use fixed-size
locals and ordinary control flow, with no per-iteration `alloca`, recursive
driver, continuation allocation or accumulating C nesting. Formatting of
emitted C is not an acceptance goal.

## Tests and acceptance

Write failing named Blorp `TestSuite` callbacks before implementation. Use
multiline source strings and direct phase inputs; retain raw malformed
ownership inputs for independent verifier tests.

| Boundary | Required observations |
| --- | --- |
| Lexer/parser/EBNF | Both placements, `@` and annotation spans, unchanged identifier handling; precise unknown/duplicate/misplaced/dangling/argument-bearing/prelude rejection. |
| Checking and rendering | Direct and UFCS self identity; both tail-arm forms; every non-tail context above; mixed good/bad arms; unused helpers; zero arguments; pure/impure; generic restriction; no-self error; exact kind, span, help and precedence. |
| Specialization/lowering | Correct enclosing instance; branch-local terminal; no fictitious recursive result; next arguments computed exactly once in order; aliases and mutable-binding versions; parameter snapshots and prefixes repeated per iteration. |
| Last uses/ownership | Every recur operand has a terminal use, including repeated/permuted arguments and arm captures; no fabricated return transfer or loop owner. Reject String signatures and every managed intermediate with exact source span/message/help; admit unmanaged phantom String applications. |
| Independent verification | Reject wrong arity/type, undefined/forward/sibling values, managed operands, live owners, recur outside a loop, and an ordinary self call left anywhere in a loop. Independently reject a loop marked as required but containing no backedge. |
| Emission | Every backedge captures all arguments before assignments and continues the enclosing loop; no emitted self call; prefix work inside loop; valid zero-argument loop; fixed structural depth. |
| Native real-main fixtures | Base arm, direct/UFCS backedge, swaps/duplicates, record/union arguments and prefix recomputation; exact exit status and empty output, generated C at `-O0` under existing ASan/UBSan path. |

Deliberately break the tail-context propagation, read an overwritten parameter
instead of its immutable value capture during replacement,
hoist a parameter snapshot/prefix outside the loop, leave a self call instead
of a backedge, and remove a verifier check. Each relevant unchanged test must
fail; then restore the implementation. Phase tests must observe their own
outputs, not merely run the whole compiler repeatedly.

### Deep execution without another language feature

Add a small hand-written four-digit base-16 countdown fixture. `Digit` has
variants D0 through D15; `Carry` has variants Decrement and Keep.
`predecessor` maps D1 to D0 through D15 to D14 and wraps D0 to D15.
`borrow(digit, incoming)` returns incoming only for D0, otherwise Keep.
`adjust` decrements only for Decrement. `nonzero` and `either` compute
whether any digit is nonzero, using ordinary helper tail matches. These
unannotated helpers have fixed call depth. The least significant digit is a.
Illustrative excerpt; the helper declarations are described above:

```blorp
@tail_recursive
pure func countdown(a: Digit, b: Digit, c: Digit, d: Digit) -> Int:
    active = either(nonzero(a), either(nonzero(b), either(nonzero(c), nonzero(d))))
    match active:
        Keep: 7
        Decrement:
            carry_b = borrow(a, Decrement)
            carry_c = borrow(b, carry_b)
            carry_d = borrow(c, carry_c)
            countdown(predecessor(a), adjust(b, carry_b), adjust(c, carry_c), adjust(d, carry_d))
func main() -> Int:
    countdown(D15, D15, D15, D15)
```

With the specified helper tables this executes 65,535 backedges and returns
7 before zero wraps. Pin all predecessor cases and borrow/adjust truth tables
in direct phase tests, plus small native fixtures observing carry boundaries.
Exit 7 alone does not prove the iteration count or helper correctness. Combine
those tests with explicit IR/C loop assertions and real-main `-O0` ASan/UBSan
execution. Temporarily emit an ordinary self call in place of the backedge;
the unchanged deep fixture must fail with demonstrated stack exhaustion.
Restore the loop and require success. If this depth does not expose the
mutation on a supported toolchain, calibrate a named larger depth (one more
digit) and document its cost before relying on the oracle. An unexplained
timeout is not evidence of stack exhaustion. If the oracle is unreliable or
requires new test infrastructure, stop and report; do not waive this acceptance
criterion or add hidden stack settings.

Inject the native mutation in emission from the verified recur terminal;
do not weaken verification to allow a malformed ordinary self call through.

This needs no arithmetic, recursive datatype, generated state-machine
framework, infinite-loop timeout oracle or C driver. Iterative destruction
remains a separate obligation; the annotation cannot make a recursive
destructor safe. Add deep data traversal/destruction tests with that increment.

Use the existing commands serially, starting with affected unit suites:

```sh
scripts/compiler-build-status
bin/blorp test --suite --timeout 180 blorp_2/test/unit/test_parse.brp
bin/blorp test --suite --timeout 180 blorp_2/test/unit
bin/blorp test --suite --timeout 180 blorp_2/test/test_grammar
make -C blorp_2 test
```

`make -C blorp_2 test` includes runtime tests and one unconditional `-O0`
pilot build for the e2e run; its e2e wrapper has timeout 0. Require FRESH host
status before these commands; run `make` and recheck if status is STALE or
UNKNOWN. Pilot-only edits do not otherwise require rebuilding the host.
Preserve byte-identical C for existing
unannotated fixtures and their cost ceilings. New small fixtures start with
the existing recursion ceilings: 10,000 compiler allocations and 100,000,000
retired instructions each. The larger countdown fixture starts with the
existing structural-stress ceilings: 100,000 allocations and 500,000,000
instructions. These measure compilation, not the target program's iterations.
Freeze the owned-input baseline and toolchain before
editing, compare matched allocation/instruction samples and report production
and test LOC separately. A repeatable increase above 5% on the existing
owned-input corpus stops the slice for investigation; this is a proxy, not a
self-compilation measurement. No speedup claim is required.

Update the restricted grammar and conformance tests with implementation.
Update the pilot README and the existing language references' annotation
sections as appropriate, explicitly distinguishing the pilot guarantee.
Require compiler-expert, code-reviewer and test-runner review of the complete
producer-to-consumer path before committing implementation.

## Subsequent bounded increments

Pending follow-up: extend the existing base-16 countdown from four digits
(65,535 recursive calls) to five, seeded with `0xF4240`, for exactly 1,000,000
iterations. Run its real main at `-O0` with the default stack limit, an exact
result and empty streams; pair that outcome with the existing explicit-backedge
emission oracle to establish bounded self-edge stack use. An optional eight-digit
`0x3B9ACA00` case may exercise 1,000,000,000 iterations as a separate long stress
run. This needs no new language feature, stack instrumentation or test controller.
Neither larger case is implemented or covered by current gates.

1. **Same-instance generics.** Accept a self call only when its substitution
   preserves every enclosing declaration-owned type parameter in order. A
   source declaration recurring at different concrete arguments cannot jump
   into one function's parameter slots, even when C layouts happen to match.
   Define support/rejection for managed instantiations before enabling generic
   annotations; retain the existing growing-instantiation check separately.
2. **Managed values.** Start with one String carrier and a terminating match
   example after the managed match-prefix restriction is addressed. Keep the
   external borrowed-parameter ABI; give internal loop-carried obligations
   explicit ownership/provenance. Evaluate next arguments, acquire or transfer
   every required next obligation, then retire old obligations, then rebind.
   No pending cleanup may remain after the jump. Base returns transfer their
   result and discharge all remaining obligations. Test unchanged carriers,
   fresh replacements, aliases, duplicate/swap arguments, unused intermediates
   and returns at every phase before adding projected aggregate children.
3. **Recursive managed data.** Compose the validated loop transition with the
   unary union ownership increment. Acquire a borrowed child before retiring
   its parent; verify provenance and exact active-child destruction separately.
   Add the deep traversal/destruction native oracles here.

Mutual tail-call guarantees and tail-modulo-constructor remain separate future
designs. A failing premise, an ownership shape outside the current slice, or
a need for new execution/test infrastructure is a stop-and-report boundary.
Implementation handback must include exact commands, source/binary provenance,
phase and native results, mutation evidence, measured costs, review findings
and unresolved coverage.
