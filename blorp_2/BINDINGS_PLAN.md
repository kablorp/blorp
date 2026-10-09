# Scalar bindings and ordered values

Status: implemented and validated, 2026-10-09. The
[binding increment record](../benchmarks/results/blorp_2_bindings_2026-10-09.md)
retains costs, provenance and passing gates. The
[arm-binding extension record](../benchmarks/results/blorp_2_arm_bindings_2026-10-09.md)
retains the next increment's evidence.
Read [AGENTS.md](AGENTS.md) and
the parent instructions first. The [architecture review](../benchmarks/results/blorp_2_architecture_review_2026-10-09.md)
and [memory plan](MEMORY_PLAN.md) establish the intended boundaries.

## Working example

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

Expected exit status 1, empty stdout/stderr. Local mutation in `preserve` is
pure. Source companions expose the new `current` value, old aliases and
self-assignment through their entrypoints. Direct phase tests distinguish
call order and retained unused calls; native effect counts are unobserved.

## Grammar and scope

A function contains zero or more depth-one binding lines followed by its
mandatory existing final expression or tail match. Each RHS uses the current
single-line expression grammar. Add `=` and the whole-word reserved keyword
`var`. Prefix lines are `name = expression` or `var name = expression`.
The initial increment adds no annotations, discards, expression statements,
block-arm bindings, nested matches, loops, closures, imports or arithmetic
operators. The arm-block extension below composes bindings with tail matches.

Checking resolves an ordinary `name = rhs` to a new immutable binding when
there is no visible local, or to reassignment of the nearest visible mutable
binding. An existing immutable binding cannot be assigned. Explicit `var`
creates a mutable local; duplicate body-local declarations are rejected.
An explicit mutable declaration may shadow a parameter, with its initializer
resolved before the new binding becomes visible. Match captures remain fresh
immutable bindings scoped to their arms and may shadow enclosing locals.
Sibling arms never share captures.

Infer each new local's type from its initializer; reassignment receives the
binding's established type. Support the existing unmanaged `Int` and union
types without adding new representation rules. A union initializer must
synthesize its type from a typed binding or function result; bare constructors
without a receiving type retain the current diagnostic. Calls and constructor
arguments retain current contextual type resolution. Every statement is
checked, including unused bindings and unreachable helpers.

The existing host's `infer_assign_expr` rejects assignment to visible immutable
variables; the pilot follows that behavior. The main language reference already
defines ordinary `=` versus mutable reassignment. Keep the pilot's restricted
grammar in [grammar.ebnf](grammar.ebnf), with source/diagnostic conformance cases.

## Identities, published data and lowering

Before this increment, `BindingId` wrapped `SoleParameter | ArmBinding(Int)`
in `check.brp`. It now uses a function-local ordinal; only checking
mints it. One binding definition per parameter/local/capture carries
origin, mutability, type and declaration span. Scope contains name-to-binding
references; spelling IDs never become computed value identities. A reassignment
preserves its binding identity. Function seals delimit ID ownership.

Previously `CheckedValue` published only a base and operations while private
contracts computed and discarded intermediate types. It now publishes typed
base/step occurrences with their source spans, preserving accepted facts rather than
re-resolving names or repeating arity/purity checks. Function signatures remain
the declaration authority; occurrence types describe computed results.

Checking publishes prefix initialization/reassignment operations plus a tail
body. A new pure `lower` boundary consumes the sealed checked program and
publishes a sealed ordered-value program. A local builder maps each binding
to its current `ValueId`; reads alias that value and reassignment updates only
the builder mapping. Each computed value is defined once with an exact type,
operation and occurrence span. IDs are scoped to the lowered function/body.

For `preserve`, illustrative output is:

```text
v0: Int = constant 1
v1: Int = constant 42
v2: Int = call identity(v1)
return v0
```

Two source bindings initially map to `v0`. Emission consumes ordered values,
uses ID-derived C temporaries and executes each call/construction exactly once.
Keep existing tail-match selection and payload projection, with branch-local
definitions and a shared function-owned value allocator. No joined assignments
or general CFG/phi/dominance framework is needed. No hidden mutable cells,
ownership operations or target heap allocations are introduced.

Ordered C intentionally changes old fixture bytes. Preserve native outcomes,
evaluation order and exact golden output where specified; update golden C and
structural expectations deliberately. Do not retain two competing
emission paths. Keep declarations/layout/signature facts available once in
each sealed phase product, with checked translations between phases.

## Direct tests and acceptance

Write failing Blorp `TestSuite` cases before implementation. Each new module
needs its own unit suite. Parser units construct token inputs directly;
checking/lowering units use minimal valid typed fixtures through sealed
construction boundaries. Do not weaken production seals for test convenience.
Give each invariant and each negative diagnostic a named callback.

Required tests: immutable/mutable declarations; stable reassignment type;
initializer visibility; unknown/self initializer; immutable assignment; missing
RHS and mandatory final value; parameter and arm shadowing; sibling isolation;
source spans and every intermediate type; old alias preservation; self-update;
effect order and unused call execution; union locals and reassignment; tail
matches after locals; local mutation allowed in pure functions but impure calls
still rejected. Existing match coverage, UFCS and cycle rules remain enforced.

End-to-end fixtures expose each observable behavior through their real `main`
and expected exit/output. Compile them with the pilot and run the unmodified
emitted program. Do not add C assertion drivers or generated-symbol
instrumentation. Full-width literals, exact intermediate values and evaluation
order belong in direct phase tests where the current source subset cannot
observe them. Exit status alone does not prove a full Int64 value or effect
count; record that native coverage limitation explicitly. Deliberately break
one binding mapping and one evaluation-order decision and require the matching
unchanged unit tests to fail, then restore exact source.

Feedback and final commands, serially on macOS:

```sh
scripts/compiler-build-status
bin/blorp test --suite --timeout 180 blorp_2/test/unit
bin/blorp test blorp_2/test/e2e
make -C blorp_2 test
bin/blorp test --suite --sanitize=undefined --leak-check --timeout 180 \
  blorp_2/test/unit blorp_2/test/e2e blorp_2/test/test_grammar
```

Run native UBSan checks on the unmodified fixtures, inspect generated C, and
confirm one fresh pilot build at the beginning of each end-to-end run. ASan and
detailed lifetime probes belong to the managed-value increments or a concrete
supported bug. Host
compiler sources are unchanged;
report host defects separately instead of repairing them in this slice.

## Cost and scope boundaries

The completed feature gate froze source/configuration and both original `-O2`
compiler modes before editing. Its matched results remain in the binding record;
the current e2e tests use one `-O0` compiler and one measured run per fixture.
Until self-compilation is possible, use matched owned-input compilation proxies
and label them explicitly. Ceilings for this feature: at most +100% allocations
and +10% minimum retired instructions on each old fixture; first bindings
fixture at most 10,000 allocations / 100,000,000 instructions; formatted
production at most 5,500 physical lines. Tests have no growth ceiling that
would excuse missing coverage. Require zero diagnostic leaks/UBSan failures.
Investigate repeatable ceiling violations before adjusting scope or limits.

Record before/after production and test lines separately, allocations,
instructions, source/binary/toolchain provenance and raw sample locations.
Intentional emission changes mean old C byte identity is not an acceptance
criterion; native behavior and the specified golden output are required.
No speedup is claimed. Interning and cycle-check optimizations remain separate
slices. Managed representations, dup/drop, ARC/COW and destructors remain
future work with the memory plan's independent proof and runtime-test contracts.

## Match-arm binding extension

The arm-block working example is
[match_binding_original.brp](test/e2e/fixtures/match_binding_original.brp):
the `Number(payload)` arm declares `var current = payload`, saves
`original = current`, reassigns `current = identity(42)`, and returns
`original`. `main` passes `Number(7)`, so the executable exits 7.
Companions return 42 and 0, and exercise shadowing of an outer body local.

An arm keeps its inline expression form or opens a depth-three block with
zero or more existing binding lines and one final single-line expression.
Nested matches and non-tail matches remain outside this increment.
Parsed arms publish their binding prefix; checked arms publish ordered
assignments; lowering uses the existing branch-local `ValueBlock`.
All binding and value identities remain function-owned.

Current-block membership is explicit during checking. A block's first local
ordinal distinguishes its declarations from enclosing locals; a capture is
introduced before that boundary. An explicit `var` may shadow an enclosing
local or capture, while a duplicate declaration in the same block is rejected.
Ordinary `=` keeps its nearest-binding behavior. Every arm starts from the
enclosing scope and binding map; siblings propagate identity allocation only.
All arm initializers participate in purity and cycle checking.

Direct phase tests cover parsing and spans, block indentation and final-result
errors, capture/local shadowing, sibling isolation, immutable/type/purity/cycle
rejections, ordered branch definitions, alias preservation and independent
branch mappings. Native fixtures use their real `main`, unchanged emitted C,
strict C11 at `-O0`, and UBSan. Deliberately corrupt a lowering mapping and
require the regression test to fail before restoring the source.

Freeze the existing 39-fixture workload before editing. This feature's
ceilings are +25% allocations and +10% retired instructions per existing
fixture, 10,000 allocations / 100,000,000 instructions per new fixture, and
5,000 physical production lines. Compare identical `-O0` diagnostic toolchains
and require byte-identical emitted C for existing fixtures. Until self-hosting,
these owned-input costs remain proxies. The baseline default e2e command
passes 53 cases in 25.61 seconds; raw evidence is under the ignored
`build/arm-bindings-evidence/` directory.
