# Blorp 2 roadmap

This is the single plan for getting Blorp 2 to compile itself, and for the
aggregate, ownership, generics and recursion contracts that path depends on. It
replaces MEMORY_PLAN, MANAGED_RECORDS_PLAN, GENERICS_PLAN and RECURSION_PLAN;
completed evidence stays in Git and
[benchmarks/results](../benchmarks/results/). Read both [AGENTS.md](AGENTS.md)
and the [parent AGENTS.md](../AGENTS.md).

[README.md](README.md) and [grammar.ebnf](grammar.ebnf) describe implemented
behavior. The [imports/prelude reference](IMPORTS_AND_PRELUDE_PLAN.md) describes
that implemented subsystem. [LIBRARY_PARITY.md](LIBRARY_PARITY.md) is the
authority for which library functions the compiler source may use while the
host still builds it. Examples and unfinished milestones here are planned
capabilities, not claims that the current compiler accepts them.

Correctness and useful composition come before memory optimization. Extra
retains, copies and fresh allocations are acceptable; unique-root COW,
allocation reuse, retain elimination and consuming-ABI inference are deferred.
Existing test cost guards remain; adjust them deliberately with evidence rather
than distorting the design to avoid a host-compiler cost.

## Definition of done

The fixpoint the old compiler already uses, strengthened:

1. The host builds `blorp_2/src` and `standard_library_temp` into compiler **A**.
2. **A** compiles the same source into **B**; **B** compiles it into **C**.
3. **B** and **C** emit byte-identical C. **B** passes the full e2e suite. For
   every e2e fixture, **A** and **B** emit byte-identical C. A self-consistent
   fixpoint alone can hide a deterministic miscompile; A == B on fixtures
   localises host-versus-pilot drift.
4. A, B and C are built at `-O2`: the first time emitted C runs optimised.

Unit tests are outside this definition. They depend on the host `TestSuite`
(59.5k lines, 1,554 tuples, 2,285 `==`, process and filesystem APIs) and need
their own inventory and plan after M8.

## Rules for every milestone

- **Dual-compile.** Until the fixpoint the host keeps building A, so the source
  stays host-compilable: only syntax the host already accepts enters `src`, and
  every library function `src` imports exists in both the host library and
  `standard_library_temp` with the same module, name and signature.
  [LIBRARY_PARITY.md](LIBRARY_PARITY.md) is the authority.
- **Fixture first.** Each increment starts with a small real-main e2e fixture
  shaped like the source's own use, failing granular tests, runnable acceptance
  criteria and `should_fail` fixtures with exact text, under a bounded handoff
  per [HANDOFF_SPEC](../docs/HANDOFF_SPEC.md).
- **One path, no shims.** Grammar, parser, checker, lowering, ownership,
  verification and emission land together for one producer-to-consumer path;
  the replaced representation goes in the same change. A construct the parser
  reads before its milestone is rejected by the checker with an exact message.
  No cache, registry, extra pipeline or test driver for a hypothetical need.
- **One authority per fact.** Each milestone names its new facts, the phase
  that establishes each, and the product that carries it.
- **Identity proofs.** Existing fixtures stay byte-identical in C and
  diagnostics unless the milestone changes them deliberately and says why.
- **Library over builtins**, except representation and machine operations.
- **Measure.** See [Cost and evidence rules](#cost-and-evidence-rules).
- **Independent review.** A slice is accepted, with independent code and test
  review, before a dependent slice relies on it. Parallel work needs disjoint
  files and contracts; compiled validation and measurements stay serialized.
- **The frontier.** One number across the path, reported by
  `scripts/blorp2-fixpoint --frontier`: files of `src` that parse (0 to 34),
  then the phase reached on `main.brp` (load, check, specialize, lower, own,
  verify, emit, C compiles, B passes e2e, B == C).

## Status and order

| Milestone | Scope | Status |
| --- | --- | --- |
| [M0](#m0-foundation-closeout) | Re-cut, perf fixes, recursion-site loops, fixpoint script, parity table | Landed: checker re-cut, emit and name-interning fixes, parity table, parser statement loop, `scripts/blorp2-fixpoint`, `BLORP2_COMPILER` harness. Open: the per-item recursions in `check_functions` and `declare_types`. |
| [M1a](#m1a-surface-syntax-parity) | Layout, `\|`/`raw` strings, pattern/opaque/range syntax | Checkpoints 1, 2a, 2b and 3 landed. 32 of 34 files parse; the other two need a `Char` type (`lex.brp`) and function types (`specialize.brp`, M7). |
| [ML](#ml-list-construction) | `append`, `set`, `concat`, list literal | Done. |
| [M1b](#m1b-names-and-the-foundation) | Namespace: private, aliases, qualified names, designated `Bool`/`Option`/`Result` | Part A done. Part B in progress. |
| [M5](#m5-constants) | Module-level constants | Not started. |
| [M2](#m2-the-join) | Blocks with parameters; non-tail match, `if`, `and`/`or`/`not`, `?=` | M2.1 in progress; M2.2 after M1b part B; M2.3 after M2.2 and M1b part B (designated `Result`). |
| [M2b](#m2b-pattern-compilation) | Nested, or-, list and literal patterns | Not started. |
| [M3](#m3-loops-and-tail-recursion) | Loops with managed carried values; `SelfTailLoop` retired | Not started. |
| [M4](#m4-recursive-types) | Recursive types, release rule, opaque erasure | Step 1 done; step 2a in progress. |
| [M6](#m6-library-and-shell) | Library and shell per the parity table | Not started. |
| [M7](#m7-lambdas) | Lambdas at known callees; function types | Not started. |
| [M8](#m8-the-fixpoint-gate) | Fixpoint gate | Not started. |

Dependency order:

```
M0   foundation closeout
M1a  layout, `|`/`raw` strings, pattern/opaque/range syntax        [lex, parse]
ML   List construction intrinsics                                  [all phases, runtime]
M1b  namespace: private, aliases + qualified names, designated Bool/Option/Result
M5   constants
M2   the join: blocks with parameters                              [all phases]
M2b  pattern compilation                                           [check, lower]
M3   loops with managed carried values; SelfTailLoop retired       [all phases, runtime]
M4   recursive types, release rule, opaque erasure
M6   library and shell per the parity table
M7   lambdas at known callees; no closure values
M8   fixpoint gate
```

Parallel pairs with disjoint files: M1a with the M0 fixpoint script and parity
table; ML with M1a; M1b with M5; M4 with M3; M6's Blorp bodies with M4 once M3
lands. M2.2 and M2.3 wait for M1b part B; M2b waits for M2; M3 reuses M2's join.

## Delivered foundation

Accepted, each with independent reviews, mutation oracles and matched costs in
its report. Later milestones build on these and do not reopen them.

- **Scalars to recursion.** [Bindings](../benchmarks/results/blorp_2_bindings_2026-10-09.md),
  [arm blocks](../benchmarks/results/blorp_2_arm_bindings_2026-10-09.md),
  [managed Strings](../benchmarks/results/blorp_2_managed_strings_2026-10-09.md),
  [tail-arm ownership](../benchmarks/results/blorp_2_tail_strings_2026-10-09.md),
  [typed errors](../benchmarks/results/blorp_2_typed_checker_errors_2026-10-09.md),
  [checking/synthesis](../benchmarks/results/blorp_2_synthesis_checking_2026-10-09.md),
  [function parameters](../benchmarks/results/blorp_2_function_type_parameters_2026-10-09.md),
  [union parameters](../benchmarks/results/blorp_2_union_type_parameters_2026-10-10.md),
  [nested applications](../benchmarks/results/blorp_2_generic_nested_2026-10-10.md),
  [managed union payloads](../benchmarks/results/blorp_2_managed_union_payloads_2026-10-11.md),
  [fixed records](../benchmarks/results/blorp_2_fixed_records_2026-10-10.md),
  [function recursion](../benchmarks/results/blorp_2_function_recursion_2026-10-10.md),
  [tail loops](../benchmarks/results/blorp_2_tail_recursion_2026-10-10.md) (unmanaged,
  nongeneric, direct-self; the billion-iteration run is in the
  [argument report](../benchmarks/results/blorp_2_arguments_2026-10-12.md)),
  [argv](../benchmarks/results/blorp_2_arguments_2026-10-12.md) and
  [ownership reconciliation](../benchmarks/results/blorp_2_argv_reconciliation_2026-10-12.md).
- **Finite aggregates.** [Mixed finite records and safe projections](../benchmarks/results/blorp_2_mixed_records_2026-10-13.md),
  [generic records](../benchmarks/results/blorp_2_generic_records_2026-10-13.md),
  [direct union payload types](../benchmarks/results/blorp_2_direct_union_payloads_2026-10-13.md),
  [multiple union fields](../benchmarks/results/blorp_2_multiple_union_fields_2026-10-13.md),
  [owned match-prefix values](../benchmarks/results/blorp_2_owned_match_prefix_2026-10-13.md)
  and [record updates](../benchmarks/results/blorp_2_record_updates_2026-10-14.md).
  A record update evaluates the base once, then the replacements in written
  order, then reads the inherited fields in declaration order into one fresh
  construction; old aliases never change. Checking publishes the exact
  replacement/inherited partition, so lowering needs no ordinal table.
- **Contextual inference.** [Report](../benchmarks/results/blorp_2_contextual_inference_2026-10-13.md).
  One expression-local work loop owns temporary variables; caller-owned
  parameters stay rigid; nothing tentative escapes into a published product.
  Explicit call type arguments, let polymorphism, traits and bounds,
  higher-kinded types and polymorphic function values remain deferred.
- **Lists.** [General `List[T]`](../benchmarks/results/blorp_2_general_lists_2026-10-14.md):
  `repeat`, `length` and owned `get` over every supported finite element type,
  with typed concrete slots and per-occurrence ownership.
- **Preparation and authority repairs.** [Use-vector builders](../benchmarks/results/blorp_2_ownership_builders_2026-10-13.md),
  [block-local lowering](../benchmarks/results/blorp_2_block_lowering_2026-10-14.md)
  (recursive expression-local copying remains documented debt),
  [authority fixes](../benchmarks/results/blorp_2_authority_fixes_2026-10-13.md),
  [namespace publication](../benchmarks/results/blorp_2_namespace_publication_2026-10-14.md),
  [milestone integration](../benchmarks/results/blorp_2_milestone_integration_2026-10-13.md),
  [main rebase](../benchmarks/results/blorp_2_main_rebase_2026-10-14.md) and
  [performance fixes](../benchmarks/results/blorp_2_perf_fixes_2026-10-15.md)
  (linear emission, indexed name lookup).
- **Library cost.** Each generic library wrapper costs every compile about 340
  allocations (lexing 146, parsing 104, checking 90). Checking only referenced
  library declarations was measured and rejected, because loading must stay
  complete for the prelude's `methods_only` imports; see the
  [referenced library check report](../benchmarks/results/blorp_2_referenced_library_check_2026-10-15.md).
- **Not claimed.** No whole-compiler linearity. The pilot cannot self-compile.

## M0: foundation closeout

**Goal.** A foundation the fixpoint can be measured against. **Scope.**

- **Recursion-site loops.** `parse::consume_function_lines`,
  `check/bodies::check_functions` and `check/declarations::declare_types` recurse
  once per statement, function or union only because the host forbids `?=` in
  loop bodies; the pilot dies at about 2K items per module. Each becomes
  `while` + `match` + `break` (host-legal). Oracle: the pilot on a 4K-statement
  input under `ulimit -s 512` exits 0.
- **[scripts/blorp2-fixpoint](../scripts/blorp2-fixpoint)**: the three stages, a
  SHA-256 per stage with the first differing line, A == B over fixtures, e2e
  under B, `-O2`, and `--frontier`.
- **Parity table:** [LIBRARY_PARITY.md](LIBRARY_PARITY.md), landed. Regenerate it
  whenever `src` gains or loses a library dependency.
- **Source corrections.** No `+` String operator in `src`; inventory
  corrections: 61 lambdas, 64 constants, sibling imports already relative.

**Decision (harness).** The e2e harness takes the compiler under test from a
required `BLORP2_COMPILER` environment variable, set by
`make -C blorp_2 test-e2e` ([Makefile](Makefile)). This is expected to be temporary: once blorp_2 is
mature the test code will likely be rewritten (M8).

**Exit proof.** The 4K-statement input compiles under `ulimit -s 512`; the
fixpoint script reports frontier 0.

**Status.** The checker re-cut by phase ([check/](src/check/)), the emit and
name-interning fixes, the parity table, the parser's statement loop, the
fixpoint script and the `BLORP2_COMPILER` harness have landed. Open: the
per-item recursions in `check_functions` and `declare_types`.

## M1a: surface syntax parity

**Goal.** Lex and parse everything the source uses that needs no semantics.
**Scope.** Continuation lines, trailing commas, multi-line headers, records,
imports and calls, parenthesised grouping, `---` doc blocks, block depth beyond
3, `else if`, a comment inside an open bracket, multi-line `|` and `raw` String
literals (160 lines, the C runtime text), pattern syntax (or-, nested, list,
String/Char literal, qualified) parsed into the AST and rejected by the checker
until M2b with an exact message, `opaque type` / `into_opaque` / `from_opaque`,
`a..b` ranges and `Char` literals as tokens. The language reserves every word
GRAMMAR [§1.4](../docs/GRAMMAR.md#14-keywords) reserves, and indentation follows
the host's levels stack: a deeper line opens a level whatever the step, a
dedent must land on an open level, and a bracketed block closes at its base.

**Decision.** `?=` is rejected in loop bodies and in lambda bodies, and the
parser enforces it from its statement context. The host agrees for loops
([GUIDE](../docs/GUIDE.md), `?=` is rejected inside loop bodies); blorp_2 is
stricter for lambdas, which the host allows. The host divergence applies to
lambdas only, and the source has no such use. Keeping loop exits at two
variants (M3) and `?=` a function-body construct (M2.3) depend on it.

```blorp
import:
	../utils/syntax: Span
	int as IntOps

---
A span's width, in bytes.
---
private pure func width(
	span: Span,
) -> Int:
	IntOps.subtract(
		span.end,
		span.start,
	)
```

**Exit proof.** [test_source_tree.brp](test/unit/test_parse/test_source_tree.brp)
enumerates `blorp_2/src/**/*.brp`, parses each and reports N/34 (a direct phase
test; no new entry point). The frontier reaches 34 here. Conformance suites and
the EBNF move together.

**Status.** Checkpoints 1, 2a, 2b and 3 slices 1 to 7a landed (layout and
literals, declaration forms, patterns, `if`/`else`, `and`/`or`/`not`, `match`,
propagating binding, loops and loop controls, bracketed blocks, levels-stack
indentation). Checkpoint 3 also covers lambdas, inline statement arms, method chains
across lines and `for _`. 32 of 34 files parse; the remaining two need a `Char`
type (`lex.brp`) and function types (`specialize.brp`, M7).

## ML: List construction

**Goal.** Build a list of n+1 distinct elements. **Scope.** `append` (268 uses
in `src`), `set` (47), `concat` and the literal `[a, b]` / `[]` (276) are
intrinsics by the library-over-builtins rule, with fresh-result semantics: borrow
the inputs, acquire each surviving or replacement stored occurrence, allocate a
new result, preserve every old alias. Unique-root reuse is deferred and measured
at M8. The literal constructs one fresh root inline with n stored occurrences
under the acquisition rule for variant payloads; `[]` needs an expected `List`
type. List removal is outside the self-compile path until a fixture needs it.

```blorp
pure func append(values: List[E], value: E) -> List[E]:
	builtin("list.append")
```

The List storage contract holds for every list operation:

- Logical length and initialized owned slots are explicit, separate from capacity.
  Publish a constructed root only after its admitted slots are initialized;
  never read or destroy uninitialized spare capacity.
- Replacement and growth account for each old element obligation exactly once and
  each new stored occurrence independently, including duplicate pointers. Moved-
  from slots no longer own elements.
- Accepted operations carry their element type (`ListRepeat(E)`,
  `ListLength(E)`, `ListGet(E, roles)`); Some/None roles are compile-time
  constructor identities from the declared result union.
- A disposable emitter-local inventory derives needed List element types in one
  walk and owns no layouts or identities; C names project from semantic types,
  with no per-value linear lookup. Avoid depth quadratics.
- The feature budget for a List change is at most +5% allocations and minimum
  retired instructions per frozen shared input, with +10% per input the hard
  rejection ceiling. Runtime slot count must not grow helper C size: one root
  allocation and exactly n applications of the element's duplication/drop.

**Exit proof.** Fixtures for append/set/concat/literal with managed elements,
ownership verified, C read, ceilings measured; see the
[list intrinsics report](../benchmarks/results/blorp_2_list_intrinsics_2026-10-15.md).

**Status.** Done (`append`, `set`, `concat`, literal).

## M1b: names and the foundation

**Goal.** The source's 34 namespaces resolve. **Scope.**

- **Part A.** `private` is a `Visibility` fact on each namespace declaration row,
  rejected at import selection with an exact message. Aliases and qualified names:
  the parser mints a qualified-name form from the module's import block, and the
  checker resolves it in expressions, types (`Builtins.RuntimeType[T]`),
  constructors and patterns. See the
  [namespace aliases report](../benchmarks/results/blorp_2_namespace_aliases_2026-10-15.md).
- **Part B.** **Decision:** `Bool`, `Option` and `Result` are designated
  foundation unions. One fact, established by the builtin check from `_base`,
  names the unions and their variant ids. `if`, `and`/`or`/`not`, `?=` and `for`
  consume it by identity. The representation is identical to any other union.
  The per-operation `BooleanRoles`/`OptionalRoles` lists are deleted, so
  `int.equals` returns the designated `Bool`.

**Exit proof.** The tree resolves all 34 namespaces; `private` rejections pinned.

**Status.** Part A done (aliases, `private`, qualified values and types; qualified
pattern heads wait for M2b). Part B in progress.

## M5: constants

**Goal.** The 64 module-level constants in `src` compile: 44 scalar/String
literals and 20 record literals of literals; two reference another constant
(`COMPILER_SOURCE` via `into_opaque`, `INTERNAL_SPAN` across modules). **Scope.**
The checker publishes `CheckedConstant` rows with a dependency DAG (a cycle is
an error); lowering adds `ConstantReference`; `evaluate` is the identity phase
that rejects any initializer that is not a closed literal term (literals, record
literals of such, references to other constants, `into_opaque` of such). No
interpreter.

**Decision.** Constants are materialised at use in increment 1, as literals are
today: no static data, no immortal storage class, no runtime change. They
transition to static C data when CTFE lands: that increment introduces the
immortal storage rule (every release helper honours it for a static managed
record) and measures the per-use cost it removes.

**Exit proof.** All 64 constants of `src` shapes compile; C read.

**Status.** Not started.

## M2: the join

**Goal.** Give a bound match, a statement-position match, a void `if` and
`a and b` somewhere to converge. Today a lowered function is a flat definition
list plus one tail. **Scope.** The one real mechanism of the plan, pre-approved
as "typed block arguments and explicit edge transfers". Only the selected branch
executes; no blanket cleanup after a match. A lowered block is
`{ parameters, definitions, exit }`, with the exit by context:

```
in a function body        ReturnExpression(value)
in a non-tail match arm   Yield(values) -> the join block's parameters | ReturnExpression
in a loop body (M3)       Break(values) | RecurWith(values)
```

Own transfers each yielded value's owner on the edge exactly as `ReturnTransfer`
does for a return; verify checks every edge like `verify_return`; emit writes the
join as assignments to the join's C locals. Precedent: SIL/MLIR/Cranelift block
arguments; MIR `SwitchInt` with a join block.

Checked side: one form, `Match(CheckedMatch[CheckedExpr])`, a tail match always
being the body form. Desugarings happen in the checker, never the parser, which
must not know `Bool`:

```
x = if ready: 1 else: 0        Match on Bool: True -> yield 1, False -> yield 0
if ready: print("go")          Match on Bool: True -> yield void, False -> yield void
a and b                        Match a: True -> yield b, False -> yield False
not a                          Match a: True -> yield False, False -> yield True
value ?= parse(text)           value = Match parse(text):
                                   Ok(v)  -> yield v
                                   Err(e) -> ReturnExpression(Err(e))      -- diverging arm
```

`?=` desugars only in function-body positions (it is rejected in loop and lambda
bodies, see M1a). It is a value match with one diverging arm: no CPS nesting, no depth growth (the
source's deepest chain is 13). All 668 uses are in `Result` functions, so `Err`
propagation suffices. An `if` origin stays in the checker's error type for
diagnostics, not in the tree. Local type annotations (an expected type) land
here.

Steps: **M2.1** the join mechanism across lower, own, verify and emit, with
non-tail `match` (needs no `Bool`); **M2.2** `if` and `and`/`or`/`not` (needs the
designated `Bool`); **M2.3** `?=` and local annotations (needs the designated
`Result`; the early return must discharge every enclosing owner).

**Exit proof.** Fixtures for each desugaring; a `?=` in a non-tail arm with two
live managed locals; the existing fixtures byte-identical; a nesting stress
fixture with recorded C depth.

**Status.** M2.1 in progress. M2.2 after M1b part B (designated `Bool`). M2.3 after M2.2; it needs M1b part B's designated `Result`.

## M2b: pattern compilation

**Goal.** The source's pattern shapes check and lower: nested constructor (54),
or- (51), list (34), String-literal (36), Char (14) and qualified (28).
**Decision.** A decision-tree match compiler in the checker (Maranget), with
column-wise exhaustiveness and list patterns as length and index tests. The
source is not rewritten to flat patterns. M1a parses these forms; M2b replaces
the checker's rejection.

**Exit proof.** The source's pattern shapes as fixtures; exhaustiveness errors
exact.

**Status.** Not started.

## M3: loops and tail recursion

**Goal.** Loops with managed carried values, and the one loop mechanism for
`@tail_recursive`. **Scope.** A loop is a statement with a carried-binding set and
two exits:

```
CheckedStatement.Loop(carried: List[BindingId], body)   -- body exits: Break | RecurWith
```

The carried set is a checker fact: the outer `var` bindings reassigned in the body
plus the iteration index. Lowering makes them header-block parameters; own carries
one obligation per managed carried value on both edges. A `for` over a list is an
index-carried loop over `values.get(index)`; `a..b` is the same with bounds;
`while` has no index. `break` is always bare in the source; a non-tail `break` (70
uses) reuses the join.

```blorp
var total = 0
for value in values:
	if stop(value): break
	total = IntOps.add(total, value)
```

```
Loop(carried = [index, total]):
	Match values.get(index):
		None -> Break([total])
		Some(value) -> Match stop(value):
			True  -> Break([total])
			False -> RecurWith([IntOps.add(index, 1), IntOps.add(total, value)])
```

`?=` is rejected in loop bodies (see M1a), which keeps loop exits at two
variants; lambda-based workarounds stay valid.

**Managed carried values** (179 loops carry a `List`/`String`, 173 an
`Option`/`Result`) are the larger half. Keep the external borrowed ABI; internal
carried obligations are explicit. Entry acquires internal loop owners from
borrowed parameters and never retires the caller's obligation. Each managed
parameter occurrence carries its own obligation, including duplicate aliases.
On the back edge: evaluate the next values, acquire or transfer next owners,
retire the old obligations, rebind and jump; no pending cleanup follows the back
edge. Base returns transfer the result and discharge remaining owners.
`@tail_recursive` becomes a function whose body is one loop carrying its
parameters, so `FunctionExecution`/`SelfTailLoop` are the replaced representation
and go in the same change; a back edge outside a loop becomes unrepresentable by
the exit types. Follow-ups, each separately accepted:

1. **Same-instance generics.** Accept an annotated self edge only when
   substitution preserves every enclosing rigid parameter in order; equal C
   layouts are not equal concrete instances. Define managed-instantiation
   rejection or support first, and keep growing-instantiation checking separate.
2. **Managed values.** Start with one `String` carrier and a terminating match.
3. **Recursive managed data.** Compose the transition with M4's unary data:
   acquire the next projected child before retiring its parent, then add deep
   traversal and destruction oracles.

Test entry acquisition and caller survival, unchanged and fresh carriers,
aliasing, duplicate and swap arguments, unused intermediates, projected children
and every return or edge at each affected phase. Mutual tail calls and
tail-modulo-constructor are separate future designs; traversal depth and
measured release depth are separate acceptance criteria.

**Exit proof.** A `List[String]` accumulator loop under ASan with exact allocator
balance; nested loops; a range loop;
malformed-IR negatives; `SelfTailLoop` gone.

**Status.** Not started.

## M4: recursive types

**Goal.** `CheckedExpr`-shaped data: `TypeRef`, `InferenceType`,
`PendingOperations` recurse through inline payloads with no pointer today. Runtime
values stay finite DAGs: roots are constructed from completed children, with no
recursive bindings, backpatching or lazy knot tying. **Scope.** Three steps:

1. **Unary self-recursive unions.** The `Nat` example (`Zero`, `Next(Nat)`;
   `walk(make())` exits 7): self-reference resolves to `UnionId`; the concrete
   instance is reserved in a local builder before its children expand and
   published complete. Every variant, leaves included, is boxed
   (`BoxedRecursive`); forward C declarations and pointer fields give finite
   storage; a verifier rule requires a layout to refer to itself only through a
   boxed payload. Final release iterates: decrement the root, stop if shared,
   otherwise save the active child, free the root once and continue.
2. **Mutual and generic recursion** through records and `List` (`CheckedExpr`,
   `PendingValue`, ...): separate examples for mutual references and regular
   generic recursive instances; reserve canonical declaration/argument keys
   before following children; reject type-changing recursion with an unbounded
   instance graph; distinguish by-value size dependencies, stored pointer edges
   and phantom arguments. Forward declarations in emit; the checker's
   `RecursiveAggregateType` rejection becomes the admission rule. A useful
   union-based list needs head and tail through multiple constructor fields or a
   record payload.
3. **Release graph.** **Decision:** recursive release helpers are accepted,
   including mutual recursion within recursive layout groups; step 1's iterative
   chain release stays. A worklist release is a recorded potential optimisation,
   taken only if measured recursion depth or cost demands it. Admitting a shape
   needs a measured release-depth table, not a bound proved in advance. Test
   shared-tail diamonds, repeated slots, mixed inline owning children, all
   variants and deep branching teardown.

**Opaque types** are a checked `TypeRef.OpaqueType(id)`, legal only in the
declaring module (a namespace-row fact). Specialize substitutes the underlying
type after instance keys are formed, so the concrete `TypeRef` has no opaque
variant.

Isolate deep destruction from construction and traversal depth: in an approved
runtime-helper test, build a long chain iteratively from completed children,
retain a middle tail, release the prefix, then release the tail and check exact
per-object frees. A deliberately recursive release must fail the constrained-
stack case for step 1. Source construction of a long chain still uses call depth
until M3 manages loop-carried values, so a build or walk overflow is not
destructor evidence. Always-fresh updates preserve acyclicity; later COW would
need a consumed root obligation, no conflicting live projection and independently
secured replacement children, because RC == 1 alone cannot authorize mutating a
borrowed input.

**Exit proof.** A `CheckedExpr`-shaped fixture; a release-depth table for the
admitted shapes at the source's deepest nesting under `ulimit -s 512`; step 1's
100,000-node chain still passes. See the
[unary recursion report](../benchmarks/results/blorp_2_recursive_unary_2026-10-15.md).

**Status.** Step 1 done. Step 2a in progress. Step 3 follows step 2.

## M6: library and shell

**Goal.** `src` loads: the parity table drives it. **Scope.** Intrinsics
(representation or machine): byte access `string.get -> Option[Char]` (the
host's own signature), `Char` with `to_int`/`to_char`, `Int` ordering, `Float`
ordering/`equals`/`is_nan`/`is_finite`/`copysign`, String from chars, and the
shell's `read_file`, `write_file`, `print_error`, `getcwd`, `argv` and exit
status, in `main.brp` only. Everything else the source uses is written in Blorp
in `standard_library_temp`: `substring`, `starts_with`, `index_of`, `join`,
`take`, `is_empty`, `any`, `sort_by`, `min`, `append_int`, the Option/Result
helpers, `Path`. `concat`/`join` get a measured decision (the emitter joins
thousands of fragments).

```blorp
pure func starts_with(text: String, prefix: String) -> Bool:
	match IntOps.less_than(text.length(), prefix.length()):
		True: False
		False: chars_equal_at(text, prefix, 0)
```

**Open item: a `Char` type.** The pilot's `lex.brp` uses `Char` literals (about 52)
and 13 `Char` patterns, and M1a stops there. Placement is pending the owner; proposed:
M6, with the `Char` intrinsics above.

**Exit proof.** No MISSING parity row; `src` loads (frontier at least load).

**Status.** Not started.

## M7: lambdas

**Goal.** The 61 lambda literals in `src` compile. All are `pure`, all are
arguments to a known callee (`map` 30, `and_then` 5, `any` 3, `sort_by` 3,
`translated_list` 7, others 13); none is bound, stored or returned; none captures
a `var`; captures include managed values. **Scope.** The model, not an
optimisation: each lambda literal is a unique nominal record type of its
captures; a callee with a function parameter is specialised per lambda type (one
more component in specialize's instance key); the call inside the callee is a
direct call to the lambda body with the capture record as receiver, captures
passed borrowed. No function pointers, no closure values, no new runtime
representation. Function types in signatures (`pure (T) -> U`) are the one new
type form. The escape case waits for a fixture that needs it; none is expected.
`?=` in a lambda body stays rejected (see M1a).

```blorp
offsets.map(pure func(value): IntOps.add(value, base))
-- specialize: map instantiated for this lambda's capture type; a direct call inside
```

**Exit proof.** Fixtures for a capturing and a non-capturing lambda at a library
combinator and at a user generic; ownership of borrowed managed captures
verified; frontier reaches emit.

**Status.** Not started.

## M8: the fixpoint gate

**Goal.** The definition of done. **Scope.** `scripts/blorp2-fixpoint` exits 0:
B == C, A == B on every fixture, e2e under B, all at `-O2`. Measure the
self-compile cost row (allocations and instructions per phase) under
always-fresh `append`; if quadratic, unique-root reuse is the first post-fixpoint
increment. **Decision (harness).** The e2e harness has no closure values: tests
are dispatched by name. This keeps one lambda model (lambdas only at known
callees, M7) and a simpler harness. The `BLORP2_COMPILER` harness is expected to
be rewritten once blorp_2 is mature. The unit-test migration is a separate plan.

**Exit proof.** The fixpoint script exits 0.

**Status.** Not started.

## Identity and immutable facts

These are responsibilities within the existing pure pipeline, not a demand for
new passes or tables. Local builders may be mutable and incomplete; published
results are complete, typed and immutable. After explicit source loading, all
compilation and diagnostic rendering remains pure.

| Consumer question | Authority and lifetime |
| --- | --- |
| Which source binding is this? | Function-owned BindingId; rebinding changes its current value mapping, not the identity of a computed value. |
| Which declaration/field/variant was accepted? | CheckedProgram, with declaration-owned IDs, exact accepted types and owner-qualified field/variant identities. |
| Which concrete instance is used? | SpecializedProgram, keyed by declaration identity and complete ordered concrete arguments, never spelling or physical ABI equality. |
| How is it stored and what does it own? | A complete representation derived from the concrete shape and storage policy; every stored slot appears, even if cleanup is trivial. |
| Which computed value is used? | Function-local ValueId in one lowered body revision; aliases may share it. |
| Which lifetime obligation is used? | OwnerId, or a borrow backed by a live owner/parameter; distinct storage occurrences need distinct obligations. |
| How do callers/callees agree? | Explicit argument/result ownership contracts, separate from the sole semantic call signature. |
| Which control-flow edge transfers values? | Typed block/edge parameters when joins/loops need them; do not compensate for ambiguous control flow in ownership insertion. |

Resolve calls once; lowering must not repeat name resolution or signature checks.
Keep names for diagnostics and ABI projection. Use checked translations between
identity domains. Rewrites invalidate affected use/liveness and verification
facts; reverify actual ownership-changing output before emission.

While one concrete instance has one representation, its existing instance ID
can identify that layout. Introduce another identity domain only when an actual
consumer must distinguish multiple layouts. No second semantic field catalogue,
hand-maintained managed-field inventory or missing-layout-as-unmanaged fallback.

IDs are interpreted within their owning published program. Raw verification
checks membership, nominal owners and layout consistency against that program;
it cannot infer historical provenance when an equal integer was copied from
another compilation. Negative tests must exercise distinguishable wrong owners
or incompatible layouts, rather than claim equal-ordinal foreign IDs are rejected.

## Ownership and destruction

Value semantics is the source contract: assignment copies a logical value and
var rebinds a local. Source mutability promises neither unique storage nor a
runtime mutable cell. Pure functions may mutate locals.

Perceus describes compiler placement of ownership operations; ARC is their
runtime mechanism. COW/reuse are optional implementation techniques for updates.
A last use of one reference is not proof that the allocation has no other owners.

Storage and child ownership are independent:

- Int, Float and Void require no ownership operations.
- Inline aggregates can own managed children; dup/drop visits their active
  owned fields without releasing a nonexistent root.
- Managed values retain/release their root. Nonfinal release touches no children;
  final release destroys each owned stored occurrence and frees the root once.

Preserve the parent storage rule: ordinary record is always managed. Fixed record
is inline only for recursively eligible numeric/Char fixed-record fields;
otherwise it is managed. Char is not yet in the pilot. Thus a record containing
Option[Int] or Void can have a managed root without owning child allocations.
Phantom generic arguments are not stored children. Mortal, immortal and boxed
storage must have explicit lifetime contracts, never inferred freshness flags.

### Required ownership invariants

Use these Swift-inspired verification rules in the existing IR, without importing
SIL's entire ownership lattice or adding a general borrow-checking framework:

1. Every locally created/acquired obligation has exactly one terminal action on
   each reachable return path: drop or transfer into storage, a consuming call
   or the result. Ordinary borrowed calls do not consume it. No use follows its
   consumption. Future loops/joins must explicitly carry obligations on edges.
2. A borrow is backed by a live owner/parameter for its entire use. A projected
   borrow depends on its immediate parent; selector identity stays in the typed
   projection operation. Acquisition validates that dependency while it is live.
3. After acquisition, later uses can depend on the new owner independently of
   the old parent. Do not leave source selection pointing only to a dead parent.
4. Each owning storage slot receives one obligation, including repeated pointers.
   One OwnerId cannot be consumed into two fields. Each active slot is destroyed
   once; inactive variants and uninitialized storage are never destroyed.
5. Reassignment/update establishes all replacement obligations before retiring
   old storage. Returning an alias/projection acquires an owner before escape.
6. Verification reads actual operations and complete layout/call contracts,
   independently of insertion's intended edits. Unknown shapes reject; emission
   neither repairs ownership nor invents cleanup. Reverify after changing it.

Compiler verification relies on runtime contracts; it cannot prove their C
implementation. One generated release authority owns final child cleanup and
root deallocation. Test layout completeness against accepted declarations
independently of cleanup generated from that layout. Balanced retain/release
totals can conceal wrong-object releases, leaks and invalid ordering.

Keep ordinary synchronous parameters borrowed and results owned initially. An
owned result may alias its argument and need not be fresh. Runtime consuming
operations, if introduced later, must carry explicit contracts across callers
and callees. Conservative acquisition and copy are correct defaults.

### Construction and projection

Acquire independently for each owning slot; a direct last-use transfer is
optional where already sound, and a definition-position last-use test never
authorizes transferring one obligation twice. StoredPayload is the common
stored-slot contract for records, unions and Lists. Prefer immediate acquisition
for a managed projection: acquire the child, backed by its parent, before the
parent drops, and make later uses select the acquired owner. Unmanaged fields are
copied while the parent is live. The independent verifier validates a managed
receiver's live backing even when the projected result is unmanaged. Test a call
after the parent drops, a nested projection after the intermediate parent drops,
and returned or stored child escape.

## Typechecking and specialization

Generic bodies are checked once with rigid declaration-owned parameters,
including unused bodies. Calls record complete checked substitutions.
Specialization translates signatures, bindings, calls, constructors and patterns
into concrete identities before lowering. All ordered type arguments belong in
the instance key, including phantom arguments, even when layouts coincide.
Substitution is simultaneous; supplied caller-owned parameters are not treated
as fresh callee parameters.

The publication boundary remains `Result[CheckedProgram, CheckFailure]`:
a complete checked program or an opaque failure with a nonempty typed error
collection and its sealed parsed authority. Render semantic error variants,
identities, expected/actual types, argument positions and spans separately.
No temporary inference variable, tentative substitution or mutable builder escapes.
A checked generic body may contain its rigid parameters; concrete specialization
must eliminate them. Checking currently stops at the first error; collecting
independent failures needs an explicit recovery policy, not partial acceptance.

## Phase-level test contract

Use named Blorp TestSuite callbacks; no subprocess per phase assertion and no
Python tests. Small typed inputs exercise each boundary directly. Obtain sealed
identities through their authority, but keep malformed raw ownership input
separate from verified products. Do not weaken production APIs for tests.

| Boundary | Required observations as each feature enters scope |
| --- | --- |
| Checking and typed errors | Exact accepted field/payload types; binding mutability/scope/purity; deferred recursion rejection; diagnostic kind, expected/actual identities, span/help and nonempty failure. |
| Inference/specialization | Rigid/local variable distinction, ordered complete substitutions, owner/position identity, nominal keys and phantom arguments; unused/pass-through instances; recursive reservation with no published placeholders. |
| Representation | Root versus child ownership, every declared slot, nested record/union dependencies, active variant, Void and phantom fields; reject missing, wrong-owner or incompatible layouts within the supplied program. |
| Value/control-flow lowering | Source order exactly once; immutable value versions, old aliases, captures only in selected arms, no sibling visibility; later joins/loop edges carry exact types. |
| Call ownership ABI | Borrowed inputs remain live; independent owned results may alias; consuming operands transfer once where supported; malformed runtime-operation contracts reject. |
| Uses/borrow dependencies | Exact last uses, unused values and function-local identity bounds; acquired child survives parent drop, nested acquisition survives intermediate-parent drop; delayed borrows keep ancestors live when supported. |
| Ownership insertion | Per-slot multiplicity, repeated child values, borrowed acquisition, unused-root cleanup, returned/stored escape, RHS-before-old-drop, selected-path owner discharge. |
| Independent raw verifier | Missing/double consume on one path, early owner drop, borrowed escape, wrong parent/field/type, use after transfer, leaked roots, sibling facts and invalid match coverage; inspect actual operations, not insertion decisions. |
| C emission | Independently expected small typed operation sequences, correct helpers/operands, acquire-before-retire, active-field cleanup, no invented owners; inspect layout order and structural depth. |
| Target runtime | Nonfinal release preserves children; final release destroys each occurrence/root once; repeated pointers and independent owners; mixed inline children; recursive shared tails and measured release depth. |
| General collections | Initialized length distinct from capacity; empty/boundary/absent access; insert/replace/remove/grow cleanup, no stale owned tail slots, old snapshots unchanged. |
| Real-main e2e | Mixed numeric/managed fields observed, temporary-parent escape, duplicate child fields, nested/generic elements, old aliases, recursive snapshots and deep destruction. |
| Future COW/reuse only | Shared aliases preserved; unique update has consumed permission and no conflicting borrow; replacement acquisition precedes uniqueness; safe capacity/layout fallback. |

When reuse is introduced, its enabled and always-fresh paths must agree on
observable values and safe destruction. This future equivalence oracle is not a
requirement to implement reuse now.

Existing direct stage suites include [test_lower.brp](test/unit/test_lower/test_lower.brp),
[test_own.brp](test/unit/test_own/test_own.brp), [test_verify.brp](test/unit/test_verify/test_verify.brp)
and [test_emit.brp](test/unit/test_emit/test_emit.brp). The
[String-runtime suite](test/runtime/test_string.brp) independently checks
bytes/length, retain, nonfinal release, final free and independent lifetimes.
These do not establish future aggregate runtime coverage.

### Required negative and mutation oracles

For each admitted shape, use direct raw-verifier negatives for missing acquisition,
one-path leak, duplicate transfer, wrong field/parent, early drop and invalid
escape. Assert the exact violated obligation and operation/edge, not any error.
Test complete layouts independently against declarations, including unused rows.

Deliberately omit one child drop, target a different child, remove required
acquisition, or free a root twice and require its protected test to fail. Where
branching exists, defect only one arm. Collection tests must detect a forgotten
removed child and a double-dropped shifted child. Later update tests must fail if
an old alias changes; the unary-chain test must detect recursive C teardown.
Restore exact sources before final gates. These are bounded oracle checks, not
permission for a mutation framework.

Balanced totals, line coverage and sanitizer silence do not prove exhaustive
release. Runtime evidence must distinguish actual object lifetimes from compiler
allocation counters. ASan/UBSan and a supported native leak checker supplement
phase and runtime tests; prove the leak oracle detects omitted cleanup before
relying on it.

The user approved extending the existing String direct-C runtime-test pattern
to concrete aggregate helpers on 2026-10-13. Blorp TestSuite compiles the same
pure production fragments with test-local real allocation/free observations,
starting with the reviewed finite-record cases. Each new shape still needs its
own independent cases; permission for the method is not evidence of coverage.
Use actual emitted fragments with no production tracing or alternate emitter;
keep real-main fixtures unmodified. Missing aggregate destruction evidence is an
implementation acceptance dependency to report, not permission for an implicit
test driver or a claim that compiler leak checks prove target cleanup.

## Cost and evidence rules

Allocations and retired instructions may increase as capabilities grow. Record
both on frozen baseline and candidate inputs with the same toolchain, serially
and separately from target lifetime evidence, with source, binary, flags, inputs,
raw samples and output identity retained in one report and raw artifacts under
ignored `build/`. Report production and test lines separately. Owned-input
costs are proxies for self-compilation until M8 gives the self-compile cost row.

- **Preparatory refactors** freeze a matched same-toolchain baseline, emit
  identical existing target C and stay within +3% allocations and minimum
  retired instructions per frozen input. A lowering preparation stops for design
  review above +50 production lines or a wider algorithmic change.
- **Features** may change emitted C and increase costs: set numerical fixture
  limits before implementation, report new-feature work separately from the
  shared corpus, and take the +5% target and +10% per-input hard ceiling as the
  default shared-input budget. No average conceals an individual breach.
  Existing fixture ceilings stay unchanged unless a reviewed, measured
  adjustment says otherwise. A line threshold is never pressure to compress
  formatting, delete tests or weaken handling.
- **Scaling.** For a new traversal or builder, state its input-size dimensions
  and expected work and exercise a 16/32/64/128 series; investigate repeatable
  near-quadratic doubling and repeated whole-body or layout scans. Where a
  milestone adds accumulating nesting, add a moderately sized stress case,
  compile it with the supported C toolchains at default limits and record the
  emitted nesting depth. Report inherited scaling separately and add an index
  only when a measured query justifies its key, authority and lifetime.
- **Not required.** No feature requires fewer allocations, minimal retains, unique
  reuse or a new optimization benchmark. Keep local uniquely owned builders and
  one published row or slot per concrete fact.

Every affected phase gets granular typed-input and typed-output tests; insertion
and raw verification are tested independently; runtime-helper tests observe
individual objects. A worker reports an ambiguous boundary, unexpected cost or
scope expansion before adding a mechanism. Hand back exact supported shapes and
contracts, red/green and mutation outcomes, C observations, gate verdicts and
remaining limits. Stop and report host defects, unapproved mechanisms, missing
destruction oracles and incomplete representation; never work around them with
partial publication or unchecked emission.

From the repository root, check host freshness and use focused suites first:

```sh
scripts/compiler-build-status
bin/blorp test --suite --timeout 180 blorp_2/test/unit/test_own/test_own.brp
bin/blorp test --suite --timeout 180 blorp_2/test/unit/test_verify/test_verify.brp
bin/blorp test --suite --sanitize --leak-check --timeout 180 blorp_2/test/unit
make -C blorp_2 test
git diff --check
```

If the host is not FRESH, run `make` then recheck before direct tests. E2e builds
the pilot once at O0, compiles unmodified fixture C at O0 and uses timeout 0; no
persistent compiler cache.

## Deferred beyond the fixpoint

Unique-root COW and allocation reuse (first candidate if M8 shows quadratic
`append`), retain elimination, consuming-ABI inference, List removal, Set/Dict
key semantics (storing a type does not make it a key), mutual tail calls,
tail-modulo-constructor, closure escape and closure values, and the unit-test
migration plan. When reuse is introduced, its enabled and always-fresh paths must
agree on observable values and safe destruction.

## Established references and local choices

These references support specific decisions, not a transfer of another compiler's
proof or runtime model. Swift/Go/Rust ownership references were checked on
2026-10-12. Adopt their correctness lessons within the current typed pipeline;
no full borrow checker, GC, ownership lattice or optimization pass is implied.

| Reference | Lesson and Blorp application |
| --- | --- |
| [Swift Ownership SSA](https://github.com/swiftlang/swift/blob/main/docs/SIL/Ownership.md) | Owned values have one consuming end per path; dependent borrows require a live base. Apply the explicit obligation/use rules and independent verifier above. |
| [Rust destruction](https://doc.rust-lang.org/reference/destructors.html) and [drop elaboration](https://rustc-dev-guide.rust-lang.org/mir/drop-elaboration.html) | Cleanup follows complete field/active-variant structure. Generate it from canonical layouts. Partial-move flags and user destructors are unnecessary for the first whole-value constructors. |
| [Go generic slice lifetimes](https://go.dev/blog/generic-slice-functions) | Obsolete backing-array references can keep removed objects alive. Translate this into explicit initialized ARC slots and exact removal/growth obligations, not Go's shared-mutable slice semantics. |
| [Koka/Perceus](https://www.microsoft.com/en-us/research/uploads/prod/2021/06/perceus-pldi21.pdf) | Explicit dup/drop and reuse are distinct concerns. Use explicit ownership operations; postpone reuse and minimal-memory goals. |
| [Lean: Counting Immutable Beans](https://arxiv.org/pdf/1908.05647) and [RC documentation](https://lean-lang.org/doc/reference/latest/Run-Time-Code/Reference-Counting/) | Borrowed references depend on owners; storing one value twice consumes two obligations. Take those contracts without requiring borrow inference or unique updates. |
| [Rust recursive layouts](https://doc.rust-lang.org/book/ch15-01-box.html) and [LinkedList teardown](https://doc.rust-lang.org/src/alloc/collections/linked_list.rs.html#1177-1195) | Indirection gives finite recursive size; iterative destruction avoids chain-depth C stack use. ARC shared tails/mixed graphs need our own proof and tests. |
| [Rust concrete-instance collector](https://doc.rust-lang.org/nightly/nightly-rustc/rustc_monomorphize/collector/index.html) and [Instance identity](https://doc.rust-lang.org/nightly/nightly-rustc/rustc_middle/ty/struct.Instance.html) | Discover dependencies using complete nominal instance keys; keep local construction and immutable publication rather than copying Rust's entire pipeline. |
| [OCaml representation](https://ocaml.org/docs/memory-representation) and [recursive values](https://ocaml.org/manual/5.5/letrecvalues.html) | Tagged payload blocks are a useful model; immutable values alone do not rule out cycles. Our completed-child construction rules must establish acyclicity. |
| [Bidirectional Typing](https://arxiv.org/abs/1908.05839) and [rustc inference](https://rustc-dev-guide.rust-lang.org/type-inference.html) | Separate synthesis/checking, rigid parameters and local solvable variables; preserve origins and publish only complete accepted facts. |
| [OCaml tail-modulo-constructor](https://ocaml.org/manual/5.5/tail_mod_cons.html) | Constant-stack traversal needs an explicit qualifying transformation. Our direct-self guarantee does not imply mutual or constructor-tail guarantees. |

The first compiler remains a source of bounded precedents:
[ownership contracts](../docs/OWNERSHIP_MODEL.md),
[concrete record representation](../blorp/src/compiler/stage_09_core/record_representation.brp),
[managed record layouts](../blorp/src/compiler/stage_09_core/managed_record_layout.brp)
and [cleanup preparation](../blorp/src/compiler/stage_09_core/prepare.brp).
Carry useful contracts forward, not broad mutable environments or string-keyed
semantic rediscovery. Historical aggregate-child protection and builder-COW
failures supply regression ideas, not claims about current bugs.

## Retained evidence

Completed experiments, counts, historical budgets and host-compiler limitations
live in the reports linked under [Delivered foundation](#delivered-foundation)
and in the milestones above, plus the
[host temporary-projection repair](../benchmarks/results/compiler_nested_temporary_projection_2026-10-11.md);
passing pilot checks do not imply an incomplete broader host gate passed.
Old slice-specific thresholds and counts are historical evidence, not current
budgets.
