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

[BOOTSTRAP_SOURCE_PLAN.md](BOOTSTRAP_SOURCE_PLAN.md) now owns the reviewed
source-simplification direction. Source convenience alone does not justify a
new compiler mechanism. Retain implemented language behavior and migrate the
compiler source before removing a deferred feature from the prerequisite set.
The M8 proof below is unchanged.

After M8 passes, [M9](#m9-post-self-compilation-architecture-audit) audits the
complete compiler against actual self-compilation evidence before the next major
feature expansion. This audit does not defer existing correctness work or gates.

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
(historical inventory: 59.5k lines, 1,554 tuples, 2,285 `==`, process and filesystem APIs) and need
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
  review, before a dependent slice relies on it. Parallel work owns disjoint
  files or explicitly assigned function regions under stable contracts; each
  shared schema has one writer. After successful serial warmup of the exact
  pinned host/runtime configuration, up to two focused correctness suites may
  run in separate worktrees with separate artifacts. Cold or different cache
  configurations, cache-mutating tests and shared builds remain serialized.
  All measurements and e2e cost gates require an exclusive quiet window.
  Stop and serialize focused runs if macOS execution stalls recur.
  Before archiving a completed chat, copy still-needed ignored evidence outside
  its managed worktrees and verify the copies. Chat archival may remove those
  worktrees; their Git recovery snapshots omit ignored build files.
- **The frontier.** One number across the path, reported by
  `scripts/blorp2-fixpoint --frontier`: files of `src` that parse (report the
  discovered numerator and denominator, 35/37 at the final quality gate),
  then the phase reached on `main.brp` (load, check, specialize, lower, own,
  verify, emit, C compiles, B passes e2e, B == C).

## Status and order

Corrections, language rules and cleanups decided at the 2026-10-16 quality reset,
including the namespace redesign, the `?=` placement rule, pattern and binding
names, private types and UFCS clashes, are complete and published; see
[QUALITY_ROADMAP.md](QUALITY_ROADMAP.md). Deferred cost experiments remain
separate from that completed correctness and maintenance queue.

The [architecture audit](ARCHITECTURE_AUDIT_2026-10-16.md) supports the existing
phase/ownership design. It prioritizes native UTF-8 file admission and replacing
byte-classification substrings before claiming every String is valid UTF-8. Actual
bootstrap-product destruction-depth acceptance remains open; native nested joins
passed the audited toolchain's default limits through depth 256.

| Milestone | Scope | Status |
| --- | --- | --- |
| [M0](#m0-foundation-closeout) | Re-cut, perf fixes, parser statement loop, fixpoint script, parity table | Landed. M3 owns the recorded managed-value call limits. |
| [M1a](#m1a-surface-syntax-parity) | Layout and parsed source syntax | Accepted frontier 36/38. Char/function-type source migrations target the remaining two files; no new frontier is claimed. |
| [ML](#ml-list-construction) | `append`, `set`, `concat`, list literal | Done. |
| [M1b](#m1b-names-and-the-foundation) | Namespace: private, aliases, qualified names, designated `Bool`/`Option`/`Result` | Parts A and B done; control-flow consumers follow in M2/M3. |
| [M5](#m5-constants) | Literal scalar/String constants | Implemented. Source construction functions replace the need for record/opaque constants and initializer dependencies. |
| [M2](#m2-the-join) | Restricted control positions, outer-variable joins, Boolean operators, `?=` and annotations | M2.1 implemented; reviewed logical candidate preserved. General expression-control recut deferred. |
| [M2b](#m2b-pattern-compilation) | Qualified flat heads and non-binding constructor groups | Not started. Nested/list/literal source-pattern migration has bounded decision gates. |
| [M3](#m3-loops-and-tail-recursion) | Managed List/while loops, explicit exits and existing scalar TCO | Not started. Source flat recursion/ranges become loops; broader managed TCO deferred. |
| [M4](#m4-recursive-types) | Existing unary/mixed recursive shapes plus ordinary opaque semantics | Steps 1/2a done. Opaque completion remains. No current source witness requires unlanded 2b/2c. |
| [M6](#m6-library-and-shell) | First-order library parity, integer-facing String APIs and seven shell/path functions | String byte/scalar APIs and the bounded current-directory Result slice implemented and validated; source migration, remaining library and shell/path work pending. Target Char/Bytes are not planned prerequisites after source migration. |
| [M7](#m7-lambdas) | Broader language function types/lambdas | Source-removal pilots precede any retirement of this bootstrap dependency. |
| [M8](#m8-the-fixpoint-gate) | Fixpoint gate | Not started. |
| [M9](#m9-post-self-compilation-architecture-audit) | Complete architecture audit using the self-compiled compiler | Planned immediately after M8, before the next major feature expansion. |

Remaining dependency order (source migrations may overlap disjoint work):

```
reviewed source plan + small constructor/control preparations
host library/runtime prerequisites, then freeze the supporting host
M6 String byte/scalar APIs + source Char/classification migration
M6 native current-directory Result witness (accepted slice; loader migration pending)
first-order source pilots + callback removal                     [M7 gate]
M2 restricted control, outer-variable flow, propagation/annotations
M3 managed List/while loops + source flat-walk/range migration
M4 ordinary opaque semantics over retained recursive layouts
M2b qualified flat groups + bounded source-pattern migration
M6 remaining first-order library + shell/path integration
M8 actual O2 A/B/C and fixture identity proof
```

Host library work can overlap disjoint source preparations. Shared compiler
schemas and builtin wiring have one writer; disjoint helpers and explicitly
assigned function regions can proceed on separate branches. M3 reuses M2's
join and ownership edges; target library Blorp bodies depend on the retained
control/loop subset. Every writing subthread has its own worktree/branch, with
coordinator integration. Up to ten active subthreads, without forced parallelism.

### Acceptance order for the parallel work

Quality and M5a.1 are accepted. Preserve the logical candidate for current-base
review. Hold record/reference constants, the general compositional workloop,
primitive Char and union-only recursion candidates off the bootstrap path while
their source requirements are removed or disproven. Keep their reviewed designs
and evidence; neither delete them nor count them as accepted implementation.
The source plan names pilot stop rules before the larger migrations. M4.2b/2c
reopen only with a concrete retained stored-payload witness.

Standalone evidence proves the exact frozen source and boundary that produced
it. After integrating onto an accepted base, review the source/API delta and
rerun affected focused suites. Run the remaining full pilot/cost acceptance
once against that immediately preceding accepted base, followed by the actual
main destination gate. Preserve old unexecuted cost packets as preparation;
never relabel old-base samples as current-stack measurements. This avoids
duplicating broad acceptance while retaining independent integration evidence.

Each new cost packet freezes the full fixture corpus on that accepted base;
its count may differ from earlier packets. Enumerate intentional outcome or
diagnostic changes separately, preserving unchanged inputs and full oracles.
Existing ceilings remain in force. No new cache, runner or fallback follows.
A separately reviewed native-library prerequisite may require one supporting
host rebuild; freeze it before subsequent matched comparisons.

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

- **Parser statement loop.** `parse::consume_function_lines` uses a loop
  rather than recursion per statement. Oracle: the pilot on a 4K-statement
  input under `ulimit -s 512` exits 0. The declaration and function walks
  retain their direct recursive form; M3 owns their managed-value tail-call
  limits rather than promising separate loop rewrites here.
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
fixpoint script and the `BLORP2_COMPILER` harness have landed.

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

**Decision.** `?=` is allowed only among a function body's own top-level
statements, and the parser enforces this from its statement context. Every
`if`/`match` block, loop body and lambda body rejects it. The host agrees for
loops ([GUIDE](../docs/GUIDE.md)); it remains more permissive in the other
contexts. The compiler-source rewrite removes those nested uses while keeping
the host unchanged. Keeping loop exits at two variants (M3) and propagation
out of join arms (M2.3) depends on this rule.

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
enumerates `blorp_2/src/**/*.brp`, parses each and reports N/M (a direct phase
test; no new entry point). All discovered files must parse. Conformance suites and
the EBNF move together.

**Status.** Checkpoints 1, 2a, 2b and 3 slices 1 to 7a landed (layout and
literals, declaration forms, patterns, `if`/`else`, `and`/`or`/`not`, `match`,
propagating binding, loops and loop controls, bracketed blocks, levels-stack
indentation). Checkpoint 3 also covers lambdas, inline statement arms, method chains
across lines and `for _`. That historical naming acceptance parsed 33/35 files;
the current accepted frontier is 36/38. The remaining files contain Char
(`lex.brp`) and function-type (`specialize.brp`) source dependencies. The source
plan migrates those uses; the frontier alone does not require either feature.

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
  `ListLength(E)`, `ListGet(E, option)`); `option` holds the designated
  Option's Some/None constructor identities, translated per result instance.
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
pattern heads wait for M2b). Part B done: the foundation check publishes the
designation and builtin contracts refer to it; the `if`, `and`/`or`/`not`, `?=`
and `for` consumers arrive with M2.2, M2.3 and M3.

## M5: constants

**Bootstrap goal.** Use the accepted literal Int/Float/String constant path.
The baseline 99-global inventory had 71 such declarations; the other 27 records
and one opaque marker are now named construction functions under the source plan.
This explicit bootstrap compromise removes initializer references, graph-cycle
validation and opaque constant initialization from the prerequisite set.

The [constants plan](CONSTANTS_PLAN.md) retains the reviewed M5a.2/M5b feature
design for later language work. Do not implement it solely to bootstrap these
28 source declarations. Ordinary opaque semantics still belong to M4.

**Decision.** Accepted constants materialise at use: no static data, immortal
storage class or runtime change. Static data/CTFE remain future language work,
not bootstrap prerequisites; their ownership policy needs its own reviewed slice.

**Bootstrap exit proof.** No own-source initializer needs more than the accepted
literal path; constructor functions preserve identities and behavior. Generated
C/diagnostics and granular ownership tests remain unchanged on shared fixtures.

**Status.** M5a.1 scalar/String facts, identity/ownership tests, six mutation
oracles, matched costs and the actual-main 2894-component/452-e2e gate pass.
The [scalar report](../benchmarks/results/blorp_2_scalar_constants_2026-10-16.md)
records that bounded path. M5a.2's shared field-admission preparation passes
focused, mutation and matched cost checks, plus actual-main 2902-component/
452-e2e acceptance and the unchanged 36/38 frontier.
The [admission report](../benchmarks/results/blorp_2_record_field_admission_2026-10-16.md)
records its 42 added / +7 net production lines. Closed records, initializer
references/cycles and opaque constant forms are deferred language features.
No M5a.2 production implementation had begun when this scope changed.
The [construction migration](../benchmarks/results/blorp_2_construction_values_2026-10-16.md)
now replaces all 28 aggregate/opaque globals in compiler source. Fresh host Core
retains only 71 literal globals; shared fixture behavior and diagnostics match,
and all 452 e2e cases pass. Ordinary opaque semantics remain a separate M4 task.

## M2: the join

**Bootstrap boundary.** Keep statement/binding/function-tail/arm-tail control,
qualified flat matching, restricted if, outer-variable flow, local annotations
and function-top-level propagation. The
[16 source argument matches are now lifted](../benchmarks/results/blorp_2_argument_controls_2026-10-16.md),
removing their need for general expression inference. The reviewed
[compositional plan](COMPOSITIONAL_CONTROL_PLAN.md) remains a broader language
design; its workloop relocation and arbitrary-expression match/if are deferred.
Omitted else is permitted in explicit statement roles, including inherited
statement arms, and in the final control position of a function whose accepted
signature returns Void, including an omitted return annotation. Every normally
completing then-path must produce Void. Other value positions require else;
general VoidTail discard does not relax this branch requirement.
Updating an outer variable needs carried-binding edges on both branches,
including the false edge; the current Void-only join is insufficient. The design sketches
below still describe the shared join/ownership mechanisms, not permission to
expand this restricted placement boundary.

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

`?=` desugars only among a function body's own top-level statements. It is
rejected inside every `if` and `match` block, as well as loop and lambda bodies
(see the [quality rule](QUALITY_ROADMAP.md#parser-contexts)). Its failure arm
returns from the function and discharges the function's live owners; it never
exits an enclosing join. There is no CPS nesting or depth growth. The compiler
source uses `Result` propagation. An `if` origin stays in the checker's error type for
diagnostics, not in the tree. Local type annotations (an expected type) land
here.

Steps: **M2.1** the join mechanism across lower, own, verify and emit, with
non-tail `match` (needs no `Bool`); **M2.2** `if` and `and`/`or`/`not` (needs the
designated `Bool`); **M2.3** `?=` and local annotations (needs the designated
`Result`; the early return must discharge every live function owner).

The [compositional control plan](COMPOSITIONAL_CONTROL_PLAN.md) preserves the
future general-expression design. Bootstrap instead uses the body owner's
existing position, identity and inference checkpoints for restricted control.

**Exit proof.** Fixtures for each desugaring; top-level `?=` success and failure
with two live managed locals; parser rejections for propagation in join arms;
the existing fixtures byte-identical; a nesting stress fixture with recorded C
depth.

**Status.** M2.1 implemented: bound and statement `match`, nested joins and
joins in tail arms, with byte-identical C for every existing fixture; see the
[join report](../benchmarks/results/blorp_2_join_2026-10-16.md). It settled
three details of the sketch above. The original `JoinValue` definition is replaced
by `LoweredStep.Define/Join` and explicit typed parameters in the written unary
preparation. M2.1b now also publishes the reassigned enclosing bindings as
ordered carried parameters, alongside the result (Void for a statement match).
A join arm yields its value and those bindings: only a
tail arm returns or loops, so a yield cannot end a function and a backedge
cannot leave a join. The checker records each enclosing `var` reassigned by an
arm; lowering publishes its selected immutable version after the join. The reviewed
[carried-bindings plan](CARRIED_BINDINGS_PLAN.md) defines structured multi-output
steps, first as a behavior-preserving preparation. Preparation budgets are
accepted and the early physical screen is measured. The current unary port at
accepted main `782824efb` includes the later concat/write-file typed consumers;
its functional gates and 3,944 fixed-epoch cost calls pass. See the
[preparation report](../benchmarks/results/blorp_2_unary_preparation_2026-10-18.md)
for current evidence and the separate historical R0 limitation. The carried
feature's approved budgets and
implementation acceptance remain separate from the preparation. The
[carried-feature report](../benchmarks/results/blorp_2_carried_bindings_2026-10-18.md)
records current functional validation and the 3,976-call frozen cost campaign.
The checked form is `Match(CheckedJoin)` with value arms; the tail match keeps
`CheckedMatchBody`. A match at a Void function's tail discards each arm's
value, as a plain Void tail does. A self call at the tail of a nested match
is rejected until the loops milestone gives joins a backedge. M2.2 after M1b
part B (designated `Bool`). M2.3 after M2.2; it needs M1b part B's
designated `Result`, and adds top-level propagation with the function return's
ownership discharge and independent verification. It requires no early-return
form for a join arm: nested propagation is a parser error.

## M2b: pattern compilation

**Bootstrap scope.** Qualified flat constructor heads and non-binding constructor
groups with wildcard payloads. Each group has complete accepted VariantIds,
no captures, one body and exact coverage diagnostics. Current source has 106
or-groups: 99 fit directly; seven factor a common outer constructor.
Canonical duplicate/covered alternatives fail at the offending alternative's
span. The group remains one body through lowering and ownership. Independent
verification checks every label but grants no payload-projection permission.
This feature is bounded to 650 gross added / +450 net production lines.

The approved [six-site first-order source pilot](QUALIFIED_PATTERN_SOURCE_PLAN.md)
depends on qualified-feature acceptance. Source implementation waits for actual
accepted-base/region pins and a separate grant. Source cost setup remains held
for the baseline policy decision.

The source plan pilots successive matches for 236 nested-test arm headers,
and length/get/equality replacements for list/String patterns. Do not duplicate
substantial actions to force a ban: full source-growth and cost gates apply.
General nested patterns, binder-unifying alternatives and list/literal pattern
compilation remain deferred only after their source uses are actually removed.
Keep parsed data and precise unsupported-input diagnostics.

The broader language design remains a checker-owned Maranget decision tree,
column-wise exhaustiveness and list length/index tests. It is not a bootstrap
prerequisite merely because M1a can parse those forms.

**Exit proof.** Group/qualified identity and coverage tests, one-body emission,
ignored managed-payload cleanup, source migration and exact rejections for
deferred cases. No general pattern-matrix implementation is implied.

**Status.** Not started.

## M3: loops and tail recursion

The first two bounded slices and their review gates are specified in
[M3_LOOP_PLAN.md](M3_LOOP_PLAN.md): scalar representation preparation, then
managed String while. They precede the broader exit proof below; neither
slice alone completes M3.

**Goal.** Managed List/while loops, with one explicit edge/ownership mechanism.
Retain existing scalar `@tail_recursive` behavior; broader managed/generic tail-
call optimization is not a bootstrap prerequisite. Rewrite the source's flat
managed walks into loops. **Scope.** A loop is a statement with a carried-binding set and
two exits:

```
CheckedStatement.Loop(carried: List[BindingId], body)   -- body exits: Break | RecurWith
```

The carried set is a checker fact: the outer `var` bindings reassigned in the body
plus the iteration index. Lowering makes them header-block parameters; own carries
one obligation per managed carried value on every edge. A List `for` evaluates
its source once and carries its iterator; `while` checks its condition at the
header. Resolve break/continue to their actual enclosing loop, preserving List
iteration advancement. The six source ranges become Int while loops preserving
evaluated-once bounds and both directions; Range execution/types are deferred.

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
variants. Bootstrap uses named fallible helpers and an explicit Result match
with an error accumulator/break; it does not introduce lambda workarounds.

**Managed carried values** (179 loops carry a `List`/`String`, 173 an
`Option`/`Result`) are the larger half. Keep the external borrowed ABI; internal
carried obligations are explicit. Entry acquires internal loop owners from
borrowed parameters and never retires the caller's obligation. Each managed
parameter occurrence carries its own obligation, including duplicate aliases.
On the back edge: evaluate the next values, acquire or transfer next owners,
retire the old obligations, rebind and jump; no pending cleanup follows the back
edge. Base returns transfer the result and discharge remaining owners.
Existing supported `@tail_recursive` functions become a body loop carrying their
parameters, so `FunctionExecution`/`SelfTailLoop` are replaced in the same bounded
representation change; preserve their current accepted/rejected cases. A back
edge outside a loop becomes unrepresentable by the exit types. Broader language
follow-ups are deferred, not prerequisites for the source loop migration:

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
balance; nested loops and explicit exits; the source range/walk migrations;
malformed-IR negatives; `SelfTailLoop` gone with existing scalar TCO preserved.

**Status.** Not started.

## M4: recursive types

**Bootstrap scope reset.** The frozen source inventory covers all 549 type
headers and their substituted fields/aliases: 206 union instances, 112 stored
union edges, five unary self families, no multi-instance union-only cycle and
no multiple direct self slots. Root independently checked that graph; the host
Bool leaf is accounted for separately. No current generic family requires
own-parameter recursive reapplication. Thus unlanded 2b/2c leave the critical
path; preserve their designs/candidates and rejections. Reopen only with an exact
retained source/library witness. Ordinary opaque semantics and existing unary/
mixed record/List recursion remain required. The broader recursive-language
design below records future work, not additional bootstrap prerequisites.

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
   [The reviewed union-only step 2b plan](RECURSIVE_UNION_CYCLES_PLAN.md)
   admits non-generic mutual cycles and multiple self payloads, with independent
   storage verification and per-occurrence destruction tests. It preserves the
   existing unary iterative release; generic cycles and opaque types follow
   separately. Plan approval does not establish implementation or measured costs.
3. **Release graph.** **Decision:** recursive release helpers are accepted,
   including mutual recursion within recursive layout groups; step 1's iterative
   chain release stays. A worklist release is a recorded potential optimisation,
   taken only if measured recursion depth or cost demands it. Admitting a shape
   needs a measured release-depth table, not a bound proved in advance. Step
   2a's table: a self-linked chain overflows at 75,003 levels on an 8 MiB stack
   and 4,786 on 512 KiB (`-O0`), an alternating record/List chain at 58,335 and
   3,722. The historical "below about 200" source comparison was an indentation/
   bracket/UFCS scan, not measured live product destruction depth. Inventory the
   actual post-migration products and release paths before claiming adequate
   margins. The worklist design is kept on branch
   `blorp2/recursive-worklist-ref`; it is taken if data approaches that table
   or release must run on small thread stacks. Test
   shared-tail diamonds, repeated slots, mixed inline owning children, all
   variants and deep branching teardown.

**Managed-value tail calls.** The direct recursive walks in `check_functions`,
`declare_types` and `accept_functions` carry managed values, so neither compiler
currently turns them into loops. Retained measurements at `-O0` overflow at
2,697 functions and 1,909 types; `accept_functions` is unmeasured. These are
historical measurements from the quality investigation, not renewed limits for
every host or build. M3's source loop migration addresses these flat walks;
broader managed tail-call optimization remains deferred. Tree traversal and
destruction depth still need their separate measured evidence.

**Opaque types** are a checked `TypeRef.OpaqueType(id)`. Public opaque type
references may cross modules; only construction and projection are restricted
to the declaring module, using namespace-owned declaration authority.
Specialize substitutes the underlying type after instance keys are formed,
so the concrete `TypeRef` has no opaque variant.
The reviewed [ordinary opaque types plan](OPAQUE_TYPES_PLAN.md) separates semantic-key
preparation from the witnessed nongeneric feature; implementation is unstarted.

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

**Status.** Step 1 done. Step 2a done: non-generic recursion through record
fields and `List` elements, released by recursive helpers; see the
[recursive group report](../benchmarks/results/blorp_2_recursive_mixed_2026-10-15.md).
Bootstrap remaining: ordinary opaque types and actual source-product depth
acceptance. Union-only cycles (2b) and own-parameter recursion (2c) are deferred
language extensions with no current bootstrap witness.

## M6: library and shell

**Status.** Reviewed acceptance of matching host/target `string.byte_at` and
`string.from_codepoint` interfaces. Target phase/native ownership tests, six mutations,
the full 456-case e2e gate and 3,640 matched cost calls pass hard ceilings.
The [API report](../benchmarks/results/blorp_2_string_integer_apis_2026-10-16.md)
retains all 105 allocation misses of the +5% target (maximum +5.62%); normal
instructions stay within +5%. Implementation, cost and documentation reviews are
complete.
Source Char and ASCII classification migration is complete in `abd0aa1a0`:
all 39 compiler modules reconcile to fresh pre-DCE facts, with 3,109 component
checks and 461 e2e fixtures passing. The [migration report](../benchmarks/results/blorp_2_source_byte_lazy_screen_2026-10-17.md)
preserves the failed historical cost screen and the separately reviewed fixed-A/D
acceptance. Slicing, remaining library and shell/path work still leave M6 open.

The standalone [target current-directory Result slice](TARGET_CURRENT_DIRECTORY_PLAN.md)
is implemented and validated: ordinary owning Result, phase/native tests, six
effective/restored mutations and all 483 logical cost cases meet their gates.
The [cost report](../benchmarks/results/blorp_2_target_current_directory_2026-10-17.md)
records host proxy allocation/instruction ceilings passing under the explicit
host-only bootstrap leak exception; both host strict memory observations remain
failed. No pilot/native memory exception applies. Compiler loader migration and
all broader M6 shell/library integration retain the dependency order above;
this accepted bounded witness establishes no self-compilation or M6 completion.

[Target file reading](TARGET_FILE_READ_PLAN.md) is implemented and validated with phase/native,
mutation, full-suite and matched-cost gates; [evidence](../benchmarks/results/blorp_2_target_file_read_2026-10-17.md)
retains failed host strict checks. Destination e2e passed; loader migration remains pending.

The bounded [target file-writing slice](TARGET_WRITE_FILE_PLAN.md) implements
ordinary `Result[Void, String]` with two borrowed Strings. Its phase/native, full
functional and matched FEATURE cost gates pass; [evidence](../benchmarks/results/blorp_2_target_write_file_2026-10-18.md)
retains the failed supporting-host strict checks. Main/loader migration remains
a separate gate. This does not complete M6.

The [String integer-appending plan](APPEND_INT_PLAN.md) specifies one ordinary
temporary-library wrapper over accepted formatting and concat; implementation
remains pending.

The [Option/Result helper plan](OPTION_RESULT_HELPERS_PLAN.md) specifies five
ordinary functions selected by explicit imports, with the prelude unchanged.
Implementation and the separate compiler-source import migration remain pending.

**Goal.** The real compiler source loads and checks against the real temporary
library, with no remaining required parity row missing. Use the reduced resolved
dependency inventory after source migration, not the old callback/Char rows.

**Scope.** Existing Int/Float/String/List representation and machine operations;
remaining first-order numeric comparisons/classification; ordinary Option/Result
helpers; byte-exact String operations; and the shell/path surface below. Implemented
`string.byte_at -> Option[Int]` and `string.from_codepoint -> Option[String]`
avoid target Char/Bytes. Strings contain valid UTF-8; byte observation retains
byte coordinates, and scalar encoding validates before narrowing. Planned
[`string.slice`](STRING_SLICE_PLAN.md) checks half-open byte bounds and scalar
boundaries. See the source plan for exact contracts and the owning Some[String]
transfer tests.

Write ordinary helpers in Blorp where the reduced subset and measured cost allow.
Do not reconstruct raw substring bytes through scalar encoding. `starts_with`
can compare counted bytes without per-position substring allocation. Remove
Unicode case mapping or search from the prerequisite set only after the parser's
actual ASCII-classification calls disappear. Large String concatenation/join
has a bounded [concrete List[String].join plan](LIST_STRING_JOIN_PLAN.md) for
counted copying with one fresh result root. Implementation and acceptance remain
pending; no generic builder or M6 completion follows.

```blorp
pure func starts_with(text: String, prefix: String) -> Bool:
	match IntOps.less_than(text.length(), prefix.length()):
		True: False
		False: chars_equal_at(text, prefix, 0)
```

**Char status.** Preserve the reviewed [Char plan](CHAR_PLAN.md) and its held
extraction candidate as future language work. It is not the active bootstrap
route. The compiler's 72 ASCII literals, 14 Char patterns and Char API consumers
remain to be migrated explicitly; input UTF-8 support is retained.

Target `io.print_error(String) -> Void` now borrows counted bytes for stderr;
short writes stop before LF without retry. Compiler-shell migration remains pending.

### Seven shell and path functions

Paths and OS errors remain String for this macOS/Linux bootstrap increment.
Opaque Path, filesystem canonicalization, process execution, directory scanning,
environment APIs, durability and atomic output publication are outside it.

```blorp
-- system
func get_current_directory() -> Result[String, String]
func read_file(path: String) -> Result[String, String]
func write_file(path: String, contents: String) -> Result[Void, String]

-- io
func print_error(message: String) -> Void

-- path: retain existing public names, with these strengthened contracts
pure func join(base: String, child: String) -> String
pure func dirname(path: String) -> String
pure func normalize(path: String) -> String
```

The last three implement the proposed join_paths/parent_directory/normalize_path
semantics. Keeping the existing module names avoids parallel synonyms and a
cosmetic cross-repository rename. The host's broader generic print_error still
provides this String instantiation; the temporary twin is concretely String,
as explicitly recorded in the parity table. No host trait enters target code.

- **Current directory:** owned, nonempty absolute path on success; useful Err
  otherwise. Grow storage as required by the OS; no fixed buffer or empty failure
  sentinel. Query once before loader identities. Failure uses the real compiler
  SourceId and an empty source inventory, not a fabricated module/file row.
  Validate native encoding before String publication; invalid UTF-8 returns Err.
- **Read:** target adapter/native contract implemented; loader migration pending.
  Preserve valid UTF-8 contents exactly, including CRLF, BOM and NUL.
  Target encoding help omits the host read_bytes suggestion because that API
  is unavailable; both reject malformed UTF-8 before String publication.
  Malformed UTF-8 returns Err before publishing contents as a String. The native
  [file-admission pilot](BOOTSTRAP_SOURCE_PLAN.md#native-file-admission-pilot)
  pins its diagnostic and priority. Preserve malformed-input coverage here.
  Reject NUL in a path before opening. Missing/unreadable input, incomplete reads
  and close failure return Err; clean up every opened handle. This increment
  needs stable source files, not arbitrary streams or concurrent snapshots.
- **Write:** implemented and validated; the [plan](TARGET_WRITE_FILE_PLAN.md)
  and [acceptance report](../benchmarks/results/blorp_2_target_write_file_2026-10-18.md)
  retain the contracts and evidence.
  Create/truncate, write all counted contents and close successfully
  before Ok(void). Reject NUL paths; missing parents fail. A failure may leave
  partial output. Neither file operation prints. Preserve the primary failure
  while attempting cleanup; never report success after a short transfer/close
  failure. Interruption/retry policy needs explicit native tests.
  All fallible OS operations, including current-directory lookup, return valid-text
  errors. OS failures use fixed operation text and numeric OS codes rather than
  unchecked locale-dependent native messages.
- **Stderr:** attempt the complete counted message plus one additional LF,
  preserving internal newlines/NUL and writing nothing to stdout. Void reports
  no delivery status; stop on unrecoverable output error.
  The [target stderr plan](TARGET_STDERR_PLAN.md) is implemented and validated;
  migration of the compiler shell to this target API remains pending.
- **Join:** an absolute child replaces base. Empty base returns child, including
  join("", "") == "". Otherwise retain a trailing separator or add one;
  join("/library", "") == "/library/". Do not normalize components/separators.
- **Parent:** ignore all trailing separators, remove the final component and
  its preceding separator run; preserve root. Empty/basename becomes ".";
  dirname("/a///") == "/", dirname("a//b//") == "a", and
  dirname("a/..") == "a". Do not resolve interior parent components.
- **Normalize:** collapse repeated '/' and '.', cancel ordinary components
  against following '..', preserve unresolved leading relative parents and stop
  absolute parents at root. Empty becomes ".". No filesystem/symlink lookup.

The loader continues using normalized absolute **logical** paths as module
identity. The trailing-separator prefix distinguishes /library/module.brp from
/library-extra/module.brp; preserve root-library and cycle/alias tests. Pure path
helpers preserve Strings, including NUL; fallible OS boundaries reject NUL.

Retain main(args: List[String]) -> Int, including executable name at index zero,
and `compiler --library-root DIRECTORY INPUT.brp OUTPUT.c`. Return 0 with empty
stdout/stderr on success; return 1 with stderr diagnostics for usage/loading/
compilation/publication failures. Relative paths use process CWD. The existing
relative output path passed to write_file needs no new shell context carrier.
After loading, compilation and diagnostic rendering remain pure.
Validate every native argument, including the executable name, before invoking
argument-taking user main. No-argument main publishes no argv Strings and keeps
its current behavior. Malformed UTF-8 produces a fixed ASCII stderr diagnostic and status 1,
with all partially acquired argument ownership released. The native validator,
ordinary prefix destruction and shared Int/Void wrapper enforce this boundary.

Ordinary Blorp implements paths; native bindings implement the four impure
operations. The [host get_current_directory](HOST_CURRENT_DIRECTORY_PLAN.md) is validated.
Target wiring and any source-refactor host epoch transition remain pending.
A disk stdlib edit does not update an executable's embedded runtime.

Target Result contracts must carry designated constructor identities and exact
payload types once. Inputs are borrowed; successful/error Strings are owned.
Specialization, ownership and independent verification consume those facts;
do not recover a branch from error spelling or duplicate the signature solver.

**Acceptance.** Pure path edge tables, byte-exact valid-UTF-8 file/stderr tests, NUL paths,
missing/permission/incomplete/close errors, multiple-CWD relative invocations,
prefix identity and source cleanup. Raw-buffer tests reject overlong encodings,
isolated continuations, truncation, surrogates and values above U+10FFFF before
String publication. Preserve valid NUL, multibyte, scalar and ownership cases.
Use granular phase tests and runtime helpers
as well as real-main e2e. A deterministic failure-injection test needs its own
reviewed test-local design; no new production failure framework. Every slice
sets LOC/cost ceilings before code. Source-only preparations retain shared-fixture
C/diagnostic identity. Feature slices enumerate, review and measure intentional
C changes, including new helper definitions in existing String programs. M8
still proves real rebuilt-compiler output identity.

**Exit proof.** No required MISSING parity row; real src reaches load/check.

**Status.** Not started.

## M7: lambdas

**Bootstrap decision.** Migrate the current 53 pure lambda literals, 64
higher-order calls and one function-typed helper parameter to first-order source
under the bounded source plan. Retire this dependency only after sorting,
translation/source-growth pilots and the complete resolved inventory pass.
No stored/returned closure was found in the reviewed current source. Broader
language function values remain future work; existing parser/rejection behavior
is preserved.

The bounded [three-site type-argument translation](TYPE_ARGUMENT_TRANSLATION_PLAN.md)
is implemented and validated: [3,920 matched calls](../benchmarks/results/blorp_2_first_order_type_arguments_2026-10-18.md)
pass the +3% per-input and original-checkpoint-proxy limits. Historical R0
compliance remains UNVERIFIED; eight callbacks and the broader M7 dependency remain.

The [stable layout ordering pilot](STABLE_LAYOUT_ORDER_PLAN.md) has a reviewed
design; implementation and measurements have not started.

The [constant-fill plan](FIRST_ORDER_FILLS_PLAN.md) maps six remaining source maps
to existing `repeat`; unary preparation already migrated the seventh historical
site. Implementation and the unwaived SOURCE cumulative acceptance remain pending;
the historical overall callback census is not refreshed by this bounded mapping.

**Retained future design.** Lambdas at known callees, including managed captures.
The model, not an
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

**Future language exit proof.** Fixtures for a capturing and a non-capturing lambda at a library
combinator and at a user generic; ownership of borrowed managed captures
verified; frontier reaches emit.

**Status.** Future language implementation not started; bootstrap dependency
retirement remains conditional on the source migration and inventory.

## M8: the fixpoint gate

**Goal.** The definition of done. **Scope.** `scripts/blorp2-fixpoint` exits 0:
B == C, A == B on every fixture, e2e under B, all at `-O2`. Measure the
self-compile cost row (allocations and instructions per phase) under
always-fresh `append`; if quadratic, unique-root reuse is the first post-fixpoint
optimization candidate for M9 to assess before implementation.
**Decision (harness).** The e2e harness has no closure values: tests
are dispatched by name. It does not add a lambda prerequisite to bootstrap.
The `BLORP2_COMPILER` harness is expected to
be rewritten once blorp_2 is mature. The unit-test migration is a separate plan.

**Exit proof.** The fixpoint script exits 0.

**Status.** Not started.

## M9: post-self-compilation architecture audit

**Trigger.** Start immediately after the real M8 proof passes. M8 still defines
self-compilation; M9 is the next required review, before major feature expansion.
Earlier audits and passing fixtures inform this audit but do not replace it.

**Scope.** Independent compiler experts and the coordinator review every phase,
the temporary target library/runtime, shell, build path and validation tooling:

- Map facts from producer through consumers: identity, owner, lifetime,
  construction boundary and immutable publication. Check local builders, sealed
  products, pure compilation after loading and semantic decisions through
  resolved identities rather than recovering meaning from spellings.
- Review checking, specialization, recursive instance publication and complete
  runtime layouts, including distinctions between semantic and storage identity.
- Audit ownership obligations, borrow dependencies, transfer ordering and
  exhaustive destruction across calls, aggregates, joins and loop exits. Check
  insertion and independent verification separately; test actual destruction
  depth and retained memory, not only balanced counts.
- Profile the real self-compile by phase. Inspect physical allocations, boxing,
  COW, repeated scans and collection growth with representative scaling cases.
  Investigate measured causes before choosing optimizations or new indexes.
- Review generated C and runtime behavior, structural depth and toolchain
  limits. Explain expected C changes; retain exact deterministic fixpoint checks.
- Check UTF-8 admission, module/path identity and CLI I/O against the matching
  host and target-library contracts, including failure cleanup.
- Review organization, duplicated authorities, implicit behavior, temporary
  bootstrap accommodations and test quality. Confirm inventories cover all
  supported forms and mutation tests fail for their intended reasons.

**Acceptance.** Publish a report pinned to compiler/source/library/toolchain
identities, with phase contracts, measured self-compile and scaling evidence,
reproducible findings, severity, coverage limits and bounded follow-ups. Obtain
at least two independent reviews including the coordinator. Resolve correctness
and ownership blockers before expansion; document minor inefficiencies with
their cause, evidence and a credible route to improvement. The audit authorizes
no speculative rewrite, new framework or automatic optimization.

**Status.** Planned; begins after M8. No audit result is claimed yet.

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

Supporting-host compile-time leaks follow the
[documented bootstrap limitation](HOST_BOOTSTRAP_LIMITATIONS.md).

- **Preparatory refactors** freeze a matched same-toolchain baseline, emit
  identical existing target C and stay within +3% allocations and minimum
  retired instructions per frozen input. Source migrations also stay within
  +3% cumulatively against the frozen reset source baseline, including the
  host source-to-C proxy. A required native-host transition is measured
  separately and both sources are rebuilt under one frozen measurement epoch.
  A lowering preparation stops for design
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

For the unary typed-step preparation only, the
[reviewed fixed-current contract](CARRIED_BINDINGS_PLAN.md#prospective-unary-preparation-cost-contract)
was approved before current cost sampling. One fixed final accepted B and complete
C must pass +3% allocations and normal min3 instructions per current input and the
original construction-checkpoint proxy, with all absolute/LOC/strict-zero/identity
gates unchanged. Historical
cumulative criteria and actual outcomes remain preserved, with original compliance
UNVERIFIED unless actually measured. This contract grants no automatic widening,
later carried-feature waiver or implementation approval.

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

Record/reference and opaque constants, general expression-child control,
general nested/binder-unifying/list/literal patterns, Char/Bytes primitives,
union-only and own-parameter recursive extensions, and lambdas/function values
are outside the intended bootstrap subset. Their deferral is discharged only
when the corresponding complete source-plus-library migration/inventory gate
passes. Preserve reviewed future designs and held candidates. A retained stored
payload witness can reopen the appropriate recursive-type prerequisite.

Unique-root COW and allocation reuse (first candidate if M8 shows quadratic
`append`), retain elimination, consuming-ABI inference, List removal, Set/Dict
key semantics (storing a type does not make it a key), mutual tail calls,
tail-modulo-constructor, closure escape and closure values, and the unit-test
migration plan. When reuse is introduced, its enabled and always-fresh paths must
agree on observable values and safe destruction.

`utils/int_map.brp` is a stopgap Int-keyed map for compiler tables; once Blorp
has a dict implementation it is deleted and its users move to it.

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
