# Blorp 2 roadmap

This is the single plan for getting Blorp 2 to compile itself, and for the
aggregate, ownership, generics and recursion contracts that path depends on. It
replaces MEMORY_PLAN, MANAGED_RECORDS_PLAN, GENERICS_PLAN and RECURSION_PLAN;
completed evidence stays in Git, with reports at
[their last revision](https://github.com/kablorp/blorp/tree/1e07c4dce85e51cd7ad911142e9bc96a5e0d91c7/benchmarks/results). Read both [AGENTS.md](AGENTS.md)
and the [parent AGENTS.md](../AGENTS.md).

The milestone status below distinguishes implemented capabilities from pending
contracts. Dated candidate handoffs and local worktree registers are recoverable
from Git; they are not current source or acceptance authorities.

[README.md](README.md) and [grammar.ebnf](grammar.ebnf) describe implemented
behavior. The [imports/prelude reference](README.md#local-modules) describes
that implemented subsystem. The [target API reference](standard_library/README.md)
owns the current library contracts. Examples and unfinished milestones here are
planned capabilities, not claims that the current compiler accepts them.

Source convenience alone does not justify a new compiler mechanism. Retain
implemented language behavior and migrate the compiler source before removing a
deferred feature from the prerequisite set. The M8 proof below is unchanged.
Completed source-migration plans and superseded inventories are retained in Git.
The unique deferred designs for [Char](CHAR_PLAN.md),
[general expression control](COMPOSITIONAL_CONTROL_PLAN.md) and
[union-only recursive storage](RECURSIVE_UNION_CYCLES_PLAN.md) remain separate;
their historical budgets and anchors are not current execution approval.

The [incremental layout roadmap](LAYOUT_MIGRATION.md) owns the proposed in-place
representation migration and its measured acceptance gates. It preserves this
roadmap's ownership and phase-test contracts; it starts after CI/bootstrap repair
and the bounded test migration.

After M8 passes, [M9](#m9-post-self-compilation-architecture-audit) audits the
complete compiler against actual self-compilation evidence before the next major
feature expansion. This audit does not defer existing correctness work or gates.

Correctness and useful composition come before memory optimization. Extra
retains, copies and fresh allocations are acceptable. Unique-owner String and
List buffer reuse has landed (see [List buffer reuse](#list-buffer-reuse-roadmap));
consuming-ABI inference is planned in
[Ownership contracts](#ownership-contracts-roadmap); retain elimination remains
deferred.
Existing test cost guards remain; adjust them deliberately with evidence rather
than distorting the design to avoid a host-compiler cost. During integration,
ordinary allocation-cap overruns are deferred cost debt and do not block
self-compilation progress unless egregious. Preserve measured failures and
instruction history; prioritize functional correctness, ownership, leak and
sanitizer checks, exact diagnostics and the actual source frontier. Unexpected
runaway growth or leaks require investigation. This records no resource PASS
and changes no existing ceiling.

For the initial self-built bootstrap switch, the user approved the recorded
compiler cost overruns described in the [self-compilation acceptance
report](https://github.com/kablorp/blorp/blob/1e07c4dce85e51cd7ad911142e9bc96a5e0d91c7/benchmarks/results/blorp_2_self_compiled_bootstrap_2026-10-20.md).
That exception preserves every limit and resource FAIL and remains conditional
on actual identity, behavior, ownership, sanitizer and platform qualification.
It does not mark the complete M8 resource gate green.

## Definition of done

The fixpoint the old compiler already uses, strengthened:

1. The pinned B2 seed builds `blorp_2/src` and the target library into compiler **A**.
2. **A** compiles the same source into **B**; **B** compiles it into **C**.
3. **B** and **C** emit byte-identical C. **B** passes the full e2e suite. For
   every e2e fixture, **A** and **B** emit byte-identical C. A self-consistent
   fixpoint alone can hide a deterministic miscompile; A == B on fixtures
   localises host-versus-pilot drift.
4. A, B and C are built at `-O0`: the proof exercises unoptimised generated C.

Unit tests are outside this definition. They depend on the host `TestSuite`
(historical inventory: 59.5k lines, 1,554 tuples, 2,285 `==`, process and filesystem APIs) and need
their own inventory and plan after M8.

## Rules for every milestone

- **Dual-compile.** Until the fixpoint the host keeps building A, so the source
  stays host-compilable: only syntax the host already accepts enters `src`, and
  every library function `src` imports exists in both the host library and
  `standard_library` with the same module, name and signature.
  The [target API reference](standard_library/README.md) records the contracts.
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
names, private types and UFCS clashes, are complete and published. Their reports
are retained at [their last revision](https://github.com/kablorp/blorp/tree/1e07c4dce85e51cd7ad911142e9bc96a5e0d91c7/benchmarks/results). Deferred scaling work
below stays separate from that completed correctness and maintenance queue.

The [phase and ownership contracts](#identity-and-immutable-facts) remain the
architecture authority. Actual bootstrap-product destruction-depth acceptance
remains open. The historical Apple Clang21 audit compiled nested joins through
depth256 (513 lexical braces) with default limits; that is bounded native success,
not a portable nesting threshold or a product-destruction proof.

| Milestone | Scope | Status |
| --- | --- | --- |
| [M0](#m0-foundation-closeout) | Re-cut, perf fixes, parser statement loop, fixpoint script, parity table | Landed. M3 owns the recorded managed-value call limits. |
| [M1a](#m1a-surface-syntax-parity) | Layout and parsed source syntax | Pure lambda and callback syntax is implemented; current source-frontier evidence remains separate. |
| [ML](#ml-list-construction) | `append`, `set`, `concat`, list literal | Done. Checked `set_index` is an ordinary target-library wrapper. |
| [List buffer reuse](#list-buffer-reuse-roadmap) | Ownership-aware updates, four-slot first growth, doubling and simpler library loops | L1 append (`85c1eabc3`) and L2 set/concat (`90f684248`) landed. L2b.1 (loop entry) and L2b.2 (joins) landed; L2b seed `blorp2-seed-50d3922f3449` pinned. L3/L4 next. |
| [Ownership contracts](#ownership-contracts-roadmap) | Owned/borrowed parameter contracts inferred from in-place runtime operations; record update binds before rebuilding; cell reuse | Planned and approved 2026-10-28. O0 measured; the O1 step-0 spike measured and its ceilings accepted 2026-10-29, so O1 proper is next. Cell reuse awaits a decision on the O0 evidence. |
| [M1b](#m1b-names-and-the-foundation) | Namespace: private, aliases, qualified names, designated `Bool`/`Option`/`Result` | Parts A and B done; control-flow consumers follow in M2/M3. |
| [M5](#m5-constants) | Literal scalar/String constants | Implemented. Source construction functions replace the need for record/opaque constants and initializer dependencies. |
| [M2](#m2-the-join) | Restricted control positions, outer-variable joins, ordinary Boolean calls, `?=` and annotations | Joins, Result propagation, annotations, ordinary Boolean calls and restricted value/statement `if` implemented in integration; acceptance pending. General operand controls remain deferred. |
| [M2b](#m2b-pattern-compilation) | Structural constructor, Or, List and String patterns | Implemented in integration with one body per arm and exact coverage diagnostics; acceptance pending. Char patterns remain deferred. |
| [M3](#m3-loops-and-tail-recursion) | Managed List/while loops, explicit exits and existing scalar TCO | Common source while/for, managed headers and lexical exits implemented in integration; acceptance pending. Managed/generic annotated TCO remains deferred. |
| [M4](#m4-recursive-types) | Existing unary/mixed recursive shapes plus ordinary opaque semantics | Steps 1/2a and ordinary opaque semantics implemented. Actual source-product depth acceptance remains. No current source witness requires unlanded 2b/2c. |
| [M6](#m6-library-and-shell) | First-order library parity, integer-facing String APIs and seven shell/path functions | String byte/scalar APIs, checked Slice, concrete library helpers and shell/path integration implemented in the combined candidate; final composition and acceptance pending. Target Char/Bytes remain outside the bootstrap prerequisite set. |
| [M7](#m7-lambdas) | Pure function types/lambdas | Historical pre-stored-callable checkpoint: pure lambdas, immutable captures, forwarding and direct-call specialization implemented in integration; acceptance was pending. Current callable behavior and evidence are linked below. |
| [M8](#m8-the-fixpoint-gate) | Fixpoint gate | Own-source self-compilation, identical compiler C and all 556 A/B fixture comparisons pass. All 559 e2e functional callbacks pass with the approved initial cost-debt policy; resource FAILs remain recorded and platform qualification is pending. |
| [M9](#m9-post-self-compilation-architecture-audit) | Complete architecture audit using the self-compiled compiler | Planned immediately after M8, before the next major feature expansion. |

Historical dependency order for the self-compilation integration (not a current
work assignment):

```
reviewed source plan + small constructor/control preparations
host library/runtime prerequisites, then freeze the supporting host
M6 String byte/scalar APIs + source Char/classification migration
M6 native current-directory Result witness (accepted slice; loader migration pending)
M7 lambdas and immutable captures, building on accepted named callbacks
M2 restricted control, outer-variable flow, propagation/annotations
M3 managed List/while loops + source flat-walk/range migration
M4 actual source-product destruction-depth acceptance
M2b qualified flat groups + bounded source-pattern migration
M6 remaining first-order library + shell/path integration
M8 actual O0 A/B/C and fixture identity proof
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
The historical source pilots had independent stop rules. M4.2b/2c reopen only
with a concrete retained stored-payload witness.

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

- **Scalars to recursion.** [Bindings](https://github.com/kablorp/blorp/blob/1e07c4dce85e51cd7ad911142e9bc96a5e0d91c7/benchmarks/results/blorp_2_bindings_2026-10-09.md),
  [arm blocks](https://github.com/kablorp/blorp/blob/1e07c4dce85e51cd7ad911142e9bc96a5e0d91c7/benchmarks/results/blorp_2_arm_bindings_2026-10-09.md),
  [managed Strings](https://github.com/kablorp/blorp/blob/1e07c4dce85e51cd7ad911142e9bc96a5e0d91c7/benchmarks/results/blorp_2_managed_strings_2026-10-09.md),
  [tail-arm ownership](https://github.com/kablorp/blorp/blob/1e07c4dce85e51cd7ad911142e9bc96a5e0d91c7/benchmarks/results/blorp_2_tail_strings_2026-10-09.md),
  [typed errors](https://github.com/kablorp/blorp/blob/1e07c4dce85e51cd7ad911142e9bc96a5e0d91c7/benchmarks/results/blorp_2_typed_checker_errors_2026-10-09.md),
  [checking/synthesis](https://github.com/kablorp/blorp/blob/1e07c4dce85e51cd7ad911142e9bc96a5e0d91c7/benchmarks/results/blorp_2_synthesis_checking_2026-10-09.md),
  [function parameters](https://github.com/kablorp/blorp/blob/1e07c4dce85e51cd7ad911142e9bc96a5e0d91c7/benchmarks/results/blorp_2_function_type_parameters_2026-10-09.md),
  [union parameters](https://github.com/kablorp/blorp/blob/1e07c4dce85e51cd7ad911142e9bc96a5e0d91c7/benchmarks/results/blorp_2_union_type_parameters_2026-10-10.md),
  [nested applications](https://github.com/kablorp/blorp/blob/1e07c4dce85e51cd7ad911142e9bc96a5e0d91c7/benchmarks/results/blorp_2_generic_nested_2026-10-10.md),
  [managed union payloads](https://github.com/kablorp/blorp/blob/1e07c4dce85e51cd7ad911142e9bc96a5e0d91c7/benchmarks/results/blorp_2_managed_union_payloads_2026-10-11.md),
  [fixed records](https://github.com/kablorp/blorp/blob/1e07c4dce85e51cd7ad911142e9bc96a5e0d91c7/benchmarks/results/blorp_2_fixed_records_2026-10-10.md),
  [function recursion](https://github.com/kablorp/blorp/blob/1e07c4dce85e51cd7ad911142e9bc96a5e0d91c7/benchmarks/results/blorp_2_function_recursion_2026-10-10.md),
  [tail loops](https://github.com/kablorp/blorp/blob/1e07c4dce85e51cd7ad911142e9bc96a5e0d91c7/benchmarks/results/blorp_2_tail_recursion_2026-10-10.md) (unmanaged,
  nongeneric, direct-self; the billion-iteration run is in the
  [argument report](https://github.com/kablorp/blorp/blob/1e07c4dce85e51cd7ad911142e9bc96a5e0d91c7/benchmarks/results/blorp_2_arguments_2026-10-12.md)),
  [argv](https://github.com/kablorp/blorp/blob/1e07c4dce85e51cd7ad911142e9bc96a5e0d91c7/benchmarks/results/blorp_2_arguments_2026-10-12.md) and
  [ownership reconciliation](https://github.com/kablorp/blorp/blob/1e07c4dce85e51cd7ad911142e9bc96a5e0d91c7/benchmarks/results/blorp_2_argv_reconciliation_2026-10-12.md).
- **Finite aggregates.** [Mixed finite records and safe projections](https://github.com/kablorp/blorp/blob/1e07c4dce85e51cd7ad911142e9bc96a5e0d91c7/benchmarks/results/blorp_2_mixed_records_2026-10-13.md),
  [generic records](https://github.com/kablorp/blorp/blob/1e07c4dce85e51cd7ad911142e9bc96a5e0d91c7/benchmarks/results/blorp_2_generic_records_2026-10-13.md),
  [direct union payload types](https://github.com/kablorp/blorp/blob/1e07c4dce85e51cd7ad911142e9bc96a5e0d91c7/benchmarks/results/blorp_2_direct_union_payloads_2026-10-13.md),
  [multiple union fields](https://github.com/kablorp/blorp/blob/1e07c4dce85e51cd7ad911142e9bc96a5e0d91c7/benchmarks/results/blorp_2_multiple_union_fields_2026-10-13.md),
  [owned match-prefix values](https://github.com/kablorp/blorp/blob/1e07c4dce85e51cd7ad911142e9bc96a5e0d91c7/benchmarks/results/blorp_2_owned_match_prefix_2026-10-13.md)
  and [record updates](https://github.com/kablorp/blorp/blob/1e07c4dce85e51cd7ad911142e9bc96a5e0d91c7/benchmarks/results/blorp_2_record_updates_2026-10-14.md).
  A record update evaluates the base once, then the replacements in written
  order, then reads the inherited fields in declaration order into one fresh
  construction; old aliases never change. Checking publishes the exact
  replacement/inherited partition, so lowering needs no ordinal table.
- **Contextual inference.** [Report](https://github.com/kablorp/blorp/blob/1e07c4dce85e51cd7ad911142e9bc96a5e0d91c7/benchmarks/results/blorp_2_contextual_inference_2026-10-13.md).
  One expression-local work loop owns temporary variables; caller-owned
  parameters stay rigid; nothing tentative escapes into a published product.
  Explicit call type arguments, let polymorphism, traits and bounds,
  higher-kinded types and polymorphic function values remain deferred.
- **Lists.** [General `List[T]`](https://github.com/kablorp/blorp/blob/1e07c4dce85e51cd7ad911142e9bc96a5e0d91c7/benchmarks/results/blorp_2_general_lists_2026-10-14.md):
  `repeat`, `length` and owned `get` over every supported finite element type,
  with typed concrete slots and per-occurrence ownership.
- **Preparation and authority repairs.** [Use-vector builders](https://github.com/kablorp/blorp/blob/1e07c4dce85e51cd7ad911142e9bc96a5e0d91c7/benchmarks/results/blorp_2_ownership_builders_2026-10-13.md),
  [block-local lowering](https://github.com/kablorp/blorp/blob/1e07c4dce85e51cd7ad911142e9bc96a5e0d91c7/benchmarks/results/blorp_2_block_lowering_2026-10-14.md)
  (recursive expression-local copying remains documented debt),
  [authority fixes](https://github.com/kablorp/blorp/blob/1e07c4dce85e51cd7ad911142e9bc96a5e0d91c7/benchmarks/results/blorp_2_authority_fixes_2026-10-13.md),
  [namespace publication](https://github.com/kablorp/blorp/blob/1e07c4dce85e51cd7ad911142e9bc96a5e0d91c7/benchmarks/results/blorp_2_namespace_publication_2026-10-14.md),
  [milestone integration](https://github.com/kablorp/blorp/blob/1e07c4dce85e51cd7ad911142e9bc96a5e0d91c7/benchmarks/results/blorp_2_milestone_integration_2026-10-13.md),
  [main rebase](https://github.com/kablorp/blorp/blob/1e07c4dce85e51cd7ad911142e9bc96a5e0d91c7/benchmarks/results/blorp_2_main_rebase_2026-10-14.md) and
  [performance fixes](https://github.com/kablorp/blorp/blob/1e07c4dce85e51cd7ad911142e9bc96a5e0d91c7/benchmarks/results/blorp_2_perf_fixes_2026-10-15.md)
  (linear emission, indexed name lookup).
- **Library cost.** Each generic library wrapper costs every compile about 340
  allocations (lexing 146, parsing 104, checking 90). Checking only referenced
  library declarations was measured and rejected, because loading must stay
  complete for the prelude's `methods_only` imports; see the
  [referenced library check report](https://github.com/kablorp/blorp/blob/1e07c4dce85e51cd7ad911142e9bc96a5e0d91c7/benchmarks/results/blorp_2_referenced_library_check_2026-10-15.md).
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
  under B, `-O0`, and `--frontier`.
- **Library dependencies:** check actual source imports against the
  [target API reference](standard_library/README.md) when dependencies change;
  historical parity counts are not a current inventory.
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
in the historical `src` inventory), the no-op-on-invalid update (47 host `set`
uses; also target `set`), `concat` and the literal `[a, b]` / `[]` (276) are
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

For the checked List update increment (initially named `set`/`set_or_keep`,
now host-compatible `set_index`/`set`), the user approved a
bounded allocation exception on 2026-10-18: +15% against fixed baseline
`bc6168b483a6680628a2d915ff18f22bd314ab69` for its eight frozen controls only.
The +5% assessment targets and +10% instruction hard limit remain unchanged;
missed targets and original failures remain reported. Six existing native
allocation constants increase by 1,500; all other allocation limits and all
instruction limits stay unchanged. This grants no future List allowance; see
the [validation report](https://github.com/kablorp/blorp/blob/1e07c4dce85e51cd7ad911142e9bc96a5e0d91c7/benchmarks/results/blorp_2_list_set_names_2026-10-18.md).

**Exit proof.** Fixtures for append/set/concat/literal with managed elements,
ownership verified, C read, ceilings measured; see the
[list intrinsics report](https://github.com/kablorp/blorp/blob/1e07c4dce85e51cd7ad911142e9bc96a5e0d91c7/benchmarks/results/blorp_2_list_intrinsics_2026-10-15.md).

**Status.** Done (`append`, `set`, `concat`, literal). Target `set_index`
returns `Option[List[T]]` through an ordinary `get`/match wrapper, matching the
host interface. A coordinated rename to checked `set` and no-op `set_or_keep`
must update both libraries and all callers together.

## List buffer reuse roadmap

### Problem and established boundaries

Status: L1 landed as `85c1eabc3` with its seed pinned in `8d44d250b`; L2
landed as `90f684248` with seed `blorp2-seed-90f684248521`.
[L2b](#l2b-transfer-ownership-into-joins-and-loop-entry) landed and its seed
`blorp2-seed-50d3922f3449` is pinned; L3 is next.
The earlier eager four-slot empty-literal variant passed
functional gates but exceeded the RSS investigation threshold; its measurements
remain recorded below. Implement in order, with code-reviewer and
test-runner approval at every mergeable milestone. This section is the handoff;
do not introduce companion planning documents.

`src/runtime/list.brp:185` emits roots containing a reference count, length and
inline element slots, but no capacity. Its update helpers at line 226 borrow
their inputs, allocate exactly the output size and acquire every copied
managed occurrence. This ordinary compiler-source loop therefore copies
`n * (n - 1) / 2` old slots:

```blorp
pure func collect(count: Int) -> List[Int]:
    var values: List[Int] = []
    for index in 0..count:
        values = values.append(index)
    values
```

The retained workload is `benchmarks/blorp_2/list_ops.brp`; reproduce with the
Blorp 2 compiler directly (same native flags for baseline and candidate):

```bash
mkdir -p build/list-buffer-reuse
blorp_2/build/compiler --library-root blorp_2/standard_library \
  benchmarks/blorp_2/list_ops.brp build/list-buffer-reuse/list_ops.c
clang -O2 build/list-buffer-reuse/list_ops.c -lm -lpthread \
  -o build/list-buffer-reuse/list_ops
build/list-buffer-reuse/list_ops
```

This is the existing benchmark's ordinary main, not a new timing harness.
See `benchmarks/README.md` for its broader comparison route. Compiler token accumulation
in `src/lex/lex.brp` is a real consumer of the same pattern. Assignment shares
a counted root; updates, rather than assignment, cause these element copies.

The legacy runtime confirms the intended precedent:
`blorp/src/lib/runtime/native/runtime.c:8004` defines default capacity four;
`blorp_list_append` doubles full buffers, and `blorp_list_move_to_capacity`
relocates unique slots without retaining/dropping their children. Read these
as reference, not code to port: legacy storage modes and ownership ABI differ.

Blorp 2 already has the required architecture for Strings:
`check/callables.brp:118` maps an accepted String builtin declaration's direct
calls to `RuntimeTarget`, while callable values retain the borrowed wrapper;
`own/own.brp:1015` selects a safe last-use transfer;
`verify/verify.brp:580` and `discharge_string_argument` check it independently;
`emit/emit.brp:1046` selects the consuming helper;
`runtime/string_concat.brp:25` implements geometric capacity and shared fallback.
Use the existing `ConsumedArgument(ValueId, OwnerId)` representation for Lists.
Do not add consumption facts to parsed/checked expressions or type inference.

### Capacity and ownership contract

Four means **four element slots**, not four bytes or four times the current
length. Name the internal constant `BLORP_LIST_DEFAULT_CAPACITY`. Every literal
reserves exactly its known element count: `[]` owns a counted header with zero
element slots. Growth from zero starts at `min(4, maximum)`; growth from an
exact-sized nonempty root starts at `max(current, min(4, maximum))` and doubles
until sufficient. Thus an append-built buffer grows `4, 8, 16, 32, ...` after
its first append. Reserve enough for a whole concat in one growth operation.
`repeat`, argv and borrowed-copy results also allocate their known size directly,
including zero. This avoids reserving large inline elements for retained empty
values. No public reservation API is needed. This explicitly revises the initial
proposal that `[]` eagerly reserve four slots.
Emit the shared constant once, not once per concrete element helper.

The emitted structure changes only at the runtime boundary. Schematic C:

```c
/* Before: */
struct list_E { atomic_size_t references; int64_t length; E values[]; };
/* After: every constructor initializes capacity, even exact-sized roots. */
struct list_E {
    atomic_size_t references;
    int64_t length;
    size_t capacity;
    E values[];
};
```

Keep `0 <= length <= capacity <= min(INT64_MAX, byte-size limit)`; only
`[0, length)` contains initialized owned
occurrences. Destruction never visits spare capacity. Check required length
against both `INT64_MAX` and `(SIZE_MAX - sizeof(root)) / sizeof(E)` **before**
addition, multiplication or doubling. Cap doubling at that maximum; tiny
theoretical maximum capacities must not make the default four invalid.
Reuse the existing allocator/resize authority, including strict accounting.
Relocating unique slots transfers their existing obligations; it must not run
the old root's element destructor or acquire each element again.

There are two independent permissions:

1. Ownership insertion proves a particular owner can transfer at this call;
   all remaining arguments/borrows must remain valid after the transfer.
2. The runtime checks the transferred root's reference count. Only count one
   permits in-place mutation; independently counted aliases require a copy.

Reference count one alone does not make a borrowed parameter mutable. General
function parameters, record fields and stored-callable wrappers continue to
borrow. No interprocedural consuming ABI or record-update optimization is part
of this roadmap. Record missed opportunities for later measured work.

The superseded eager-four experiment passed 251 component checks, 43 native/
runtime checks, 592-fixture parity and A/B/C source identity. Its measured
self-compilation costs against actual self-built B at `7f0e8c9a6` were:

| Metric | Baseline | Eager-four candidate | Change |
| --- | ---: | ---: | ---: |
| Allocations | 30,423,838 | 29,782,037 | −2.11% |
| Normal retired instructions, minimum of three | 1,098,945,173,101 | 1,055,666,253,468 | −3.94% |
| Normal peak RSS, maximum of three bytes | 317,685,760 | 351,993,856 | +10.80% |
| Diagnostic peak RSS, bytes | 315,047,936 | 356,663,296 | +13.21% |

These serial `-O0` compiler runs used one frozen final input/library, normal
warmups and three samples, then one separate strict diagnostic sample. All
strict reports balanced; emitted C matched within each compiler version.
The 4,096-element native append workload (`-O2`) reduced logical allocations
4,099→4 and minimum instructions 26,671,596→11,697,239 (−56.14%), with identical
ordinary-main stdout. Native totals include process startup. Forced-relocation
runtime tests separately establish linear moved slots and no old-child RC churn.
Production grew 37 net lines; tests grew 1,437 lines, counted separately.

Lower instructions do not waive the repeatable whole-compiler RSS increase.
This variant is not accepted. The exact-sized literal revision below resolves
that threshold miss in the measured workload; the historical comparison does
not isolate how much peak memory was caused by padding.
Raw commands, hashes and samples remain in ignored
`build/list-buffer-reuse/measurement/{compilation-final,native-final}` with
`eager4-results.json`; do not reuse those as final exact-literal results.

### L1 exact-literal validation

The final policy passed 252 component checks across 41 suites, 43 runtime/native
checks and all 592 A/B fixture comparisons (497 successes and 95 rejections).
A, B and C emit identical compiler C (`d3269ecf4de2`); all 43 strict accounting
reports balance with zero leaks. The 1,249 proof inputs remained unchanged.
Two independent source and final evidence reviews approve the change with no
issues; the test-runner and performance reviews also approve it.

Fresh serial measurements compare the original self-built B at `7f0e8c9a6`
with the proved exact-literal B against one frozen final source/library. Both
compilers use Apple Clang 21 at `-O0`, with one normal warmup, three normal
samples and one separate strict sample per workload:

| Whole self-compilation metric | Baseline | Exact-literal candidate | Change |
| --- | ---: | ---: | ---: |
| Allocations | 30,420,198 | 29,775,893 | −2.12% |
| Normal retired instructions, minimum of three | 1,097,350,589,227 | 1,053,979,299,199 | −3.95% |
| Normal peak RSS, maximum of three bytes | 324,747,264 | 335,200,256 | +3.22% |
| Diagnostic peak RSS, bytes | 321,388,544 | 339,951,616 | +5.78% |

Normal RSS ranges overlap: baseline 321,912,832–324,747,264 bytes; candidate
322,813,952–335,200,256. Both normal and diagnostic increases are below the
10% investigation threshold. The `return 0` compiler control reduced allocations
1.17% and normal instructions 1.35%, with normal peak RSS up 0.66%.

Native append controls at 1,024 / 2,048 / 4,096 elements reduce logical
allocations 1,027 / 2,051 / 4,099 → 4 / 4 / 4. The largest control reduces
normal instructions 26,853,580 → 11,799,614 (−56.06%). These totals include
process startup; forced-relocation runtime tests separately verify growth work
and preservation of old child obligations. The unchanged retained `list_ops.brp`
main reduces allocations 139,923,218 → 134,893,722 and normal instructions
111,225,998,056 → 67,391,995,532 (−39.41%). All six checksum lines match.
Native executables use the same `-O2` warmup/three-normal/strict protocol.

Production grows 34 net lines (44,684 → 44,718); tests grow 1,449 lines
(142,678 → 144,127), counted separately. Every strict measurement balances;
normal and diagnostic C match within each compiler version. Intentional
baseline/candidate code generation differs. All 85 compiler and 120 native
artifact/input hash guards match. Raw samples, commands, flags and provenance
are under ignored `build/list-buffer-reuse/exact-literals/measurement/`; the
maintained correctness proof is under
`build/list-buffer-reuse/exact-literals/proof/`. No cost limits or bootstrap
pins changed.

### L0: freeze the baseline and prove the seam

No standalone planning-only landing. Include this evidence with L1.
Freeze current source, library, seed, C compiler and flags. Build actual
self-built B compilers, normal and diagnostic; a runtime source edit cannot
change the executable that was previously built from it. Measure append sizes
1,024 / 2,048 / 4,096, the retained list workload and whole self-compilation.
Keep output checksums, allocation/release counts, copied-slot evidence, normal
retired instructions, peak RSS and production/test line counts separately.

Before broad implementation, inspect the lowered and owned form of `collect`.
Locate its loop-header owner, last-use row, outgoing transfer and drop. Show
that changing the intrinsic to consume that owner preserves the existing loop
contract; do not assume the String selector covers every loop. Currently direct
List calls remain declared wrapper calls, whose parameters borrow. Extend the
existing typed `declared_call_target` match for the admitted List operation,
then prove generic element substitution, UFCS and direct calls all reach the
same runtime target. Callable values must retain their borrowed wrappers.
Review this seam early. If accumulator loops require a new ownership model, stop
and present the small failing case before adding one.

### L1: append, capacity and ownership as one vertical slice

Extend the existing `check/callables.brp` direct-builtin match to `ListAppend`;
retain all existing signature, inference, purity and operand-order checks.
Generic publication needs one corresponding change in
`check/inference.brp:1694`: `publish_pending_call` currently publishes
`PendingRuntime(operation)` unchanged. Unlike String operations, List operations
contain a callee-owned element parameter. Substitute through the existing solved
call context before publishing the checked target. The relevant match becomes,
schematically inside the runtime-operation branch:

```blorp
ListAppend(element):
    admit_call_type(element, call, slots, call.span).map(
        pure func(concrete): RuntimeFunction(ListAppend(concrete))
    )
```

L2 does the same for `ListSet` and `ListConcat`. Do not apply a later caller
substitution to an unsubstituted callee parameter, or recover types from names.
Keep signature trait-requirement proofs when a declared call becomes a runtime
call: the current `PendingRuntime` proof arm is a no-op because previously
eligible String declarations are nongeneric. Reuse `prove_requirements` with
the solved signature arguments; do not skip a builtin declaration's bounds.
Test direct/UFCS calls from both concrete and generic callers, distinct element
types, and rejected unsatisfied bounds. No callee-owned parameter may survive
checked publication; a caller's properly substituted parameter may remain.

Change `runtime/list.brp`, list construction in `emit/emit.brp`, ownership
selection and independent verification together. Update every root constructor,
including argv, literals, repeat, suffix and existing update results. Keep
borrowed append available when transfer cannot be proved. Rename narrowly
String-specific ownership helpers only where their existing implementation is
actually shared; prefer a small typed `match` on runtime operations to another
policy registry or parallel ownership analysis.

The desired call sequence is schematic, not a new IR:

```text
Before:
  append(borrow list, borrow element) -> fresh list
  drop old list owner
After, when independently verified safe:
  append(consumed list owner, borrow element) -> owned result
  -- no second drop of the transferred owner
```

The consuming runtime helper chooses:

```text
shared root: copy live slots/acquire copied children, then release one input root
unique root: reserve geometrically if needed; retain existing slot obligations
both paths: acquire the newly stored element occurrence, initialize it, extend length
```

The element must remain independently live across relocation. A borrow derived
from the consumed list cannot simply be passed through; initially keep that
call borrowed, using the existing dependency/ancestry checks. Apply these checks
to nested projections as well as direct values. No source spelling heuristics.

Acceptance: the actual local accumulator selects the consuming helper; appends
within capacity allocate no new buffer, growth follows the policy, and growing
from four to `n` has logarithmic growth events and linear cumulative relocation
work. Test counters must observe growth even if `realloc` returns the same
address. The diagnostic allocator counts logical allocations, not resize calls;
allocation counts alone cannot establish the improvement.

### L2: set and concat reuse

After L1 lands, extend direct-builtin selection and the same transfer path to
the first List operand of `ListSet(E)` and `ListConcat(E)`. Set has **three**
arguments; remove hard-coded
two-argument assumptions in selection, consumed-owner tracking and verification
without introducing another representation. Verify every remaining argument
against the discharged state. Emitter chooses helpers from the typed runtime
target and verified operand, never a source function name.

For unique `set`, acquire the incoming occurrence before dropping the replaced
occurrence, including equal pointers. Invalid indices retain the current
unchanged-value behavior and do not acquire the unused replacement. A consumed
invalid update can return the transferred root. Shared updates copy; existing
aliases remain unchanged.

For unique left concat, reserve once, keep left slots and acquire right slots.
The right input stays borrowed and valid throughout. Same-owner or dependent
right borrows remain on the copying path initially. Independently counted
aliases, including two owners of the same root, trigger runtime shared fallback.
Empty inputs must preserve ownership obligations even when no slots are copied.
Right consumption and symmetric reuse are deferred until profiling warrants them.

Acceptance: unique `set` is constant work independent of list length; unique
concat with sufficient capacity copies/acquires only right-hand slots. Preserve
all current contents, error/Option behavior and value semantics.

### L2 validation

The complete proof passes 301 component checks across 41 suites, 52 runtime/native
checks and all 593 A/B fixture comparisons. A/B/C compiler C is identical
(`cdd5e9e7405e`); all 43 strict suite reports balance with zero leaks.
Forcing Set/Concat to copy produces exactly five expected runtime failures;
releasing before acquiring produces exactly the same-child ASan failure.
Both mutations use source snapshots; the real source and proved B stay unchanged.

Matched measurements compare original self-built B at `7f0e8c9a6` with L2 on one
frozen final L2 input/library. These are cumulative L1+L2 effects, not isolated
incremental L2 gains. Compiler runs use Clang 21, `-O0`, one warmup, three normal
pairs and one separate strict pair:

| Whole self-compilation metric | Baseline | L2 candidate | Change |
| --- | ---: | ---: | ---: |
| Allocations | 30,494,724 | 28,617,145 | −6.16% |
| Normal retired instructions, minimum of three | 1,101,555,890,537 | 1,053,827,395,104 | −4.33% |
| Normal peak RSS, maximum bytes | 324,534,272 | 321,961,984 | −0.79% |
| Diagnostic peak RSS, bytes | 323,043,328 | 324,796,416 | +0.54% |

The user approved less repetition while measurement was underway. All three
compiler normal pairs had already completed; native checks therefore use one
normal and one strict observation per version, with no warmup, at `-O2`.
Those approximate native totals include startup. The unchanged `list_ops.brp`
main reduces allocations 139,923,218 → 95,171,822 (−31.98%) and normal instructions
111,432,838,684 → 78,423,945,557 (−29.62%), with all six checksum lines identical.
Append controls still reduce 1,027 / 2,051 / 4,099 allocations to four each.
Do not infer an exact incremental speedup from historical L1 native samples.

All 20 strict measurement reports balance with zero leaks; output identities and
frozen guards pass. L2 adds 66 production and 977 test lines separately, within
its production bound. Raw commands, source/binary hashes, actual sample counts,
baseline snapshot repair and caveats are retained under ignored
`build/list-buffer-reuse/l2/{proof,mutations,measurement}/`. No resource limits
changed. Two independent source/cost/document reviews and the functional test
review approve the complete change.

The pinned L2 seed gives the L3 library loops consuming `set` and `concat` in
the first compiler it builds. Publish and pin a seed carrying
[L2b](#l2b-transfer-ownership-into-joins-and-loop-entry) before landing them,
so appends inside their branches consume too. Draft validation may use the explicitly proved
L2 compiler while platform publication runs; the maintained proof follows pin
activation. No implicit fallback or mixed library producer is permitted.

### L2b: transfer ownership into joins and loop entry

Status: L2b.1 (loop entry, [validation](#l2b1-validation)) and L2b.2
(joins, [validation](#l2b2-validation)) landed, and the seed carrying them,
`blorp2-seed-50d3922f3449`, is pinned. L3 is next.

#### Problem

L1/L2 reuse a List or String buffer only when a consuming call holds its last
owner with reference count one. Two conservative rules defeat that inside
control flow, and each copies the whole accumulator:

1. **Loop entry always acquires.** Each managed header takes a fresh
   acquisition of its initial value while the enclosing owner stays live until
   after the loop, so the loop's first update sees count two and copies, once
   per entry of an inner loop.
2. **A join arm cannot discharge an enclosing owner.** An update inside an arm
   borrows and copies every slot; the enclosing block drops the old owner after
   the join, once per iteration.

Both are quadratic for an accumulator. L2b.1 retains the reproduction as
`benchmarks/blorp/control_flow_accumulators.brp` with its Blorp 2 port in
`benchmarks/blorp_2/`, an `args` file and an `EXTRA_BENCHMARKS` entry, per
`benchmarks/README.md`. Acceptance runs invoke the built native program
directly with each mode and size. Its ordinary `main(args)` reads a mode and
a total append count:

```blorp
import:
	io: print
	string: parse_int

pure func in_arms(count: Int) -> List[Int]:
	var values: List[Int] = []
	for index in 0..count:
		match index.remainder(2).equals(0):
			True:
				values = values.append(index)
			False:
				values = values.append(index.add(1))
	values

pure func nested(count: Int) -> List[Int]:
	var values: List[Int] = []
	for row in 0..count.divide(16):
		for column in 0..16:
			values = values.append(column)
	values

pure func flat(count: Int) -> List[Int]:
	var values: List[Int] = []
	for index in 0..count:
		values = values.append(index)
	values
```

`main` selects `in_arms`, `nested`, `flat` or a `none` control by its first
argument, and prints the length. Measured at `9227d0418` with these
functions, `blorp_2/build/compiler` from `make -C blorp_2 compiler`, then
`clang -O2 x.c -lm -lpthread` and `/usr/bin/time -l` (retired instructions,
about 12M of which is process startup):

| Workload (n) | n | 2n | 4n |
| --- | ---: | ---: | ---: |
| in arms, 10,000 | 99,749,284 | 342,127,670 | 1,276,769,701 |
| flat, 10,000 | 11,972,994 | 12,423,719 | 13,177,646 |
| nested, 1,000 rows × 16 | 28,893,362 | 68,381,329 | 224,037,602 |

Generated C confirms both mechanisms. In arms, the borrowed helper copies and
the header owner retires only at the back edge:

```c
blorp_selection_15_arm_0:{
  struct blorp_l_0_i* const blorp_vl_17=blorp_list_append_0_i(blorp_vl_6,blorp_vl_5);
  blorp_list_dup_0_i(blorp_vl_17); blorp_list_drop_0_i(blorp_owner_6);
  goto blorp_selection_15_done;
...
blorp_list_drop_0_i(blorp_owner_3);   /* old header, live through the arm */
goto blorp_loop_3_header;
```

Nested, inner entry emits `blorp_list_dup_0_i(blorp_vl_6)` before the consuming
`blorp_list_append_take_left_0_i`, whose shared fallback then copies once per
row. An accumulator matched on itself, `match acc: Some(list): acc =
Some(list.append(x))`, also takes the shared fallback every iteration in
generated C (observed, not timed): `acc` stays live through the arm, so its
payload is shared.

Self-compilation has the same shape. A diagnostic `sample` profile (1 ms) of
the seed-generated `blorp_2/build/compiler.c` (compiler A) rebuilt
`-O2 -g -fno-omit-frame-pointer`, compiling `blorp_2/src/main.brp`, took
32.1 s and 265,218,331,153 instructions. Of 24,689 samples, `lex`
(`src/lex/lex.brp:1432`) held about 55% inclusive and `program_inventory`
(`src/emit/emit.brp:2698`) about 28%, plus 8% dropping its `TypeRef` copies
under `emit`. Both append in arms and nested loops. These are proxies; the
matched baseline is self-built B (see [L2 validation](#l2-validation)).

#### Background

- Entry rule before L2b.1: `insert_loop` always called
  `leave_with(header.initial, borrowed_result(source), ...)`, and the
  verifier's `consume_loop_transfer` rejected a `DefinedOwner` with "loop
  transfer must use a fresh acquisition" at entry and on back edges. Since
  L2b.1 it checks only entry acquisitions and back edges; a taken header is
  checked at `ExecuteLoop`. M3 said "Entry acquires internal loop owners from
  borrowed parameters and never retires the caller's obligation."
- Arm rule: yielding arms get `KeepsEnclosing` (`verify.brp:3144`; rationale
  at `verify.brp:2341`). `insert_yielding_arm` (`own.brp:1602`) passes no
  consumable rows to `insert_steps` (`own.brp:1622`), so `consume_update_left`
  (`own.brp:1017`) never sees an enclosing owner's last use in an arm.
- Existing pieces this reuses: `loop_consumption_uses` (`own.brp:1072`), the
  owner-keyed last-use scan that gives loop terminals consumable rows;
  `consumed`, inherited by nested blocks from their snapshot (`own.brp:1118`),
  which suppresses the post-step drop (`own.brp:1280`) and edge retirement
  (`retire_live`, `own.brp:1799`); `complete_loop_owners`, which compares
  owners discharged since a captured state.
- The selector `consume_update_argument` (`own.brp:1054`) is shared by
  `StringConcat`, `StringAppendInt`, `ListAppend`, `ListSet` and `ListConcat`,
  so String accumulators benefit equally.
- [Invariant 1](#required-ownership-invariants) requires loops and joins to
  carry obligations explicitly on edges.

#### Proposed solution

One rule: **an obligation whose last use in its block is a loop entry or a
join transfers into that construct instead of being dropped after it.** A
header initial and a join become consuming positions, beside the first
operand of an admitted runtime update.

- **L2b.1 loop entry.** At a `Loop` step, an owner transfers to a header when
  it is last used at this step (its drop bucket, or inside a loop its loop
  row), not consumed, holds the initial itself (`OwnedResult`), and backs no
  other read of the step: no other header initial and no body read, counted
  through `dependency_owner`.
  The header's initial becomes `OwnedReturn(initial, owner)`: no entry
  acquisition and no later retirement. Any other shared use keeps today's
  acquisition, so two headers fed by one owner both acquire.
- **L2b.2 joins.** At a `Join` step, the owners last used there and not
  consumed (the step's drop bucket, loop rows and entering rows) become the
  join's `entering` owners. Each yielding arm discharges each one exactly
  once, at its last use within the arm: consumed by an update, transferred
  into a nested join or loop header, dropped after its last read, dropped on
  arm entry (after the selection edge's acquisitions) when unread, or retired
  after the yield's acquisitions when the yield reads it. Abrupt arms already
  retire every live loop-scope owner at the edge and can consume through loop
  rows, so they need nothing new. Selection edges keep every owner live.

This is the Perceus branch rule ([references](#established-references-and-local-choices);
Lean's RC insertion does the same): an owned variable not live in the
continuation belongs to the branches. The verifier checks the stated
contract against actual operations, as it does for `ConsumedArgument`. Doing
L2b.1 first is smaller and establishes the pattern L2b.2 reuses: the
continuation records the discharge at the construct, and the construct's
blocks are checked against it.

Rejected alternatives:

1. **Rewrite `lex`, `program_inventory` and L3's `filter`** around the limit.
   That fixes one site at a time, distorts source (Blorp 2 principle 6) and
   leaves every other accumulator quadratic.
2. **Infer the entering set in the verifier.** Verification checks the
   continuation before the arms, so it needs the set first; inferring it from
   arm discharges would also make errors depend on arm order.
3. **Pass entering values as new arm parameters.** Lowering would need
   ownership facts and every arm reference would be renamed.
4. **Enter only owners some arm consumes.** The enclosing drop decision would
   wait on arm insertion, needing a second pass. Reconsider only if the
   emitted-C ceiling fails.
5. **Acquire at entry and drop the outer owner immediately.** Acquisitions
   live inside `ExecuteLoop`, so that drop needs a new entry-drop list on
   `OwnedLoop`; the transfer needs no new field, because a header transfer
   naming an enclosing owner already states it.
6. **A new `EnclosingDischarge` variant** restricting which owners an arm may
   discharge. That would enforce one invariant in two places (each discharge
   and the yield). One exact-set check at the yield suffices, mirroring
   `complete_loop_owners`.
7. **Count occurrences in today's `LoweredLoop.reads`** to tell whether the
   body reads an owner. `reads` repeats every header initial, so the answer
   would rest on an unstated counting convention; publishing body reads
   alone states it and removes the duplicate.

Phases: lower publishes body reads; own decides; verify checks. Check,
specialize, emit and the runtime do not change: emit writes drops where they
occur and initializes headers from `transfer_value(header.initial)`
(`src/emit/emit.brp:2318`) whatever the owner. Parameters stay borrowed and
never transfer.

#### Code

The "after" sketches are schematic; helper names are proposals.

**L2b.1, lower.** `LoweredLoop.reads` (`src/lower/lower.brp:255`) repeats the
initials (`lower.brp:1492`; tail-recursion loops at `lower.brp:2001`). It
becomes `body_reads`; `step_reads` (`lower.brp:266`) returns
`loop.headers.map(initial).concat(loop.body_reads)`, so use analysis and C are
unchanged. Tail-recursion loops publish empty `body_reads`.

**L2b.1, own.** The `Loop(loop)` case of `insert_steps` (`own.brp:1177`)
records one decision per header in `PendingOwnedLoop`:

```blorp
-- A header takes its initial's obligation when this entry is the owner's last
-- use and nothing else in the loop depends on it.
private fixed union HeaderEntry:
	AcquireAtEntry
	TakeOwner(OwnerId)
```

`TakeOwner` owners join `consumed`. `insert_loop` (`own.brp:1940`) reads the
decisions: `TakeOwner(owner)` emits `OwnedReturn(header.initial, owner)`;
`AcquireAtEntry` keeps `leave_with(..., borrowed_result(source), ...)`.

**L2b.1, verify.** Today `ExecuteLoop` (`verify.brp:2077`) leaves the
continuation's `discharged` unchanged and `initialize_loop` runs later from
`enter(pre, ...)`. After the change, at `ExecuteLoop`, each header initial
whose owner is not one of `loop.entry_acquisitions` (membership, not
`OwnerOrigin`: a projected owner is `AcquiredOwner`) is checked exactly as a
`DropOwner` there via `verified_drop`, plus a new check that the owner owns
that initial, and is marked discharged. `VerifyLoop` receives that one
post-transfer state: under the exactly-one rule no entry acquisition borrows a
transferred owner, and the body inherits its flags, so a body read or drop of
a transferred initial is rejected as a use of a discharged owner. Back edges
keep requiring fresh acquisitions.

**L2b.2, own.** `OwnedJoin` (`own.brp:177`) gains the contract:

```blorp
fixed record OwnedJoin {
	result: OwnedJoinParameter,
	carried: List[OwnedJoinParameter],
	-- Obligations whose last enclosing use is this join; every yielding arm
	-- discharges each exactly once, and abrupt arms retire them at the edge.
	entering: List[OwnerId],
	selection: OwnedSelection,
	arms: List[OwnedJoinArm]
}
```

In `insert_steps`, the `Join(join)` case (`own.brp:1159`) snapshots the block
for the arms **before** recording the transfer, so arms do not inherit the
entering owners as consumed:

```blorp
Join(join):
	entering = last_used_here(pre_step_drops, loop_uses, entering_rows, consumed, step_position)
	snapshot = enclosing.append({ ..., consumed = consumed })   -- excludes entering
	entries = entries.append(AwaitingArms({ join = join, entering = entering, enclosing = snapshot, ... }))
	consumed = consumed.concat(entering)                          -- continuation only
```

`loop_consumption_uses` splits into candidate selection and a shared
owner-keyed scan, `enclosing_owner_uses`. `insert_yielding_arm` calls it for
`pending.entering` and passes the rows to `insert_steps` as `entering_rows`.
These rows go into drop buckets, never into the arm's `owners`, so the
enclosing snapshot keeps the single row that abrupt arms retire. A row with
no use drops on entry; a terminal row is retired by `leave_join` after the
yield's acquisitions (`retire_terminal_sources`, `own.brp:1499`, cannot: the
owner has no local slot). Every discharge of an entering row in the arm
(consume, drop, nested join, header) appends it to the arm's `consumed`, as
`own.brp:1200–1201` already does for loop rows, so a later `break` cannot retire
it again. Abrupt arms receive no entering rows.

**L2b.2, verify.** At `ExecuteJoin` (`verify.brp:2064`) each entering owner is
checked as a `DropOwner` there and marked discharged in the continuation; the
arms start from the pre-join `start`. Yielding arms receive
`MayDischargeEnclosing` instead of `KeepsEnclosing` (`verify.brp:3144`), and
`verify_join_transfers` (`verify.brp:2409`) requires the enclosing owners
newly discharged since arm entry to equal `join.entering` exactly, reporting
"join arm leaves entering owner N live" or "join arm discharges owner N, which
does not enter its join". `KeepsEnclosing` remains for selection edges. Those
edges already admit only local drops and transfers (`verify.brp:2975`), so
confirm whether its arm of `discharge` (`verify.brp:280`) becomes
unreachable; if so, delete `EnclosingDischarge` in the same change.

#### Scope and non-goals

Production: `src/lower/lower.brp` (`body_reads`), `src/own/own.brp`,
`src/verify/verify.brp`. Every `OwnedJoin` and `LoweredLoop` literal in active
and deferred suites is updated mechanically in the same change (`ExecuteJoin(`
appears 93 times in 41 test files; `reads =` 24 times in `.brp` tests). Expectations that
encode a replaced rule change deliberately. In L2b.1, `InitialConsumesPre`
(`test/unit/test_verify/test_source_loop_control.brp:199`) becomes an
accepted transfer or a sharper rejection. In L2b.2, four deferred raw-IR cases expect
"owner N is discharged before its join" from a yielding arm
(`test_verify/test_join.brp:320,513`, `test_carried_join.brp:288`,
`test_string_concat.brp:453`); that message becomes unreachable there, and
they expect "join arm discharges owner N, which does not enter its join" at
the yield's span. The source cases `test_own/test_list_updates.brp:366,369`
still hold for owners read after the join and are only renamed.

Documentation updated with the code: README.md:603–607 and 1967; the
`verify.brp` comments at 150–152 and 2339–2342; the M3 entry sentence.

Out of scope: emit, runtime, check, specialize, the target library, the
compiler-source witnesses, consuming parameters, record-update reuse
(`{ s | items = s.items.append(x) }` stays quadratic and may appear in the
re-profile), loop-invariant obligations discharged at exits, transferring
carried yield outputs, and the `DropInEachArm` loop-match prefix. Report a
need to change these.

#### Risks and unknowns

- **Double discharge at an abrupt edge** is the central trap; the snapshot and
  `consumed` rules in L2b.2 own exist for it.
- **Emitted C grows** where unconsumed entering owners drop in each arm,
  multiplied by nesting depth in `?=` and else-if chains (1,046 `?=` lines in
  `src`). A static scan of today's generated compiler C, counting drops that
  directly follow a join's completion (5,056 after 3,711 joins), estimates
  +0.98% before the nesting multiplier.
- **Bootstrap.** Compiler A applies the new rules to what it compiles, but its
  own code was built by the L1 seed; cost claims use self-built B, and
  `make -C blorp_2` stays slow until the L2b seed is pinned.
- **Another quadratic pattern** may surface; re-profile and report it rather
  than adding a source workaround.

#### Dependencies

Keith's approval of this plan, including the `OwnedJoin.entering` contract and
the transfer rule. L2 has landed; no seed is needed to start.

#### Testing

New suites, each added to `TARGET_COMPONENT_SOURCES` (`blorp_2/Makefile:15`)
so `make -C blorp_2 test` and `--prove` run them:

- `test/unit/test_lower/test_loop_reads.brp`: `body_reads` excludes initials;
  `step_reads` keeps them; tail-recursion loops publish none.
- `test/unit/test_own/test_ownership_transfer.brp`:
  - L2b.1: a dying owner transfers; acquire when the body also reads it and
    when two headers share it; a
    projected owner (`var items = state.items`) transfers, and two headers
    initialized from projections of one record each take their own acquired
    owner; a String accumulator.
  - L2b.2: the entering set of a statement `if`, a value `match`, a `?=`
    chain with live prefix owners, and an else-if chain; no entry for an owner
    read after the join or kept by `old = values`; an owner unread in one
    arm, read in another, consumed in a third; nested forwarding, including
    into a join with a `break` arm; a `break` after an in-arm consumption
    retires nothing again; the Option accumulator matched on itself consumes
    its payload; a String accumulator; a loop inside a join arm taking an
    entering owner.
- `test/unit/test_verify/test_ownership_transfer.brp`, raw negatives with
  exact messages; the header cases land in L2b.1, the join cases in L2b.2: a drop or read of a transferred header owner after the loop
  or in its body; a header owner that does not own its initial; a loop in a
  yielding arm taking a non-entering owner ("owner N is discharged before its
  join" in L2b.1, the yield's exact-set message after L2b.2); an inactive or duplicate entering
  owner; a drop after the join; an arm leaving an entering owner live; an arm
  discharging a non-entering owner; a selection edge discharging an entering
  owner; an abrupt arm discharging an entering owner twice; a borrow of an
  entering owner's value after the join.
- `test/unit/test_emit/test_ownership_transfer.brp` (L2b.2): the consuming
  helper in each arm; per-arm drops and none after the join. L2b.1 has no
  emit suite: emit is unchanged, and the loop-entry e2e fixture checks its C
  under strict accounting and sanitizers without pinning generated text.
- E2e: `test/e2e/fixtures/list/loop_entry_accumulator.brp` and
  `branch_accumulator.brp`, registered in `self_hosted_harness.brp` with exact
  stdout and allocations, covering snapshots printed after updates, nested
  `List[String]` elements, a String accumulator, the Option accumulator and
  a `break` arm, under
  strict accounting and ASan/UBSan.

Oracle mutations (restore before gates):

| Mutation | Expected failures |
| --- | --- |
| own: always `AcquireAtEntry` | loop-entry e2e allocations, own and emit L2b.1 transfer cases |
| verify: skip the new owns-its-initial check | the not-its-initial negative only |
| verify: skip the `ExecuteLoop` discharge | the after-loop drop and body-read negatives, and every own-produced transfer, which then fails at return, yield or an edge because its owner stays live |
| own: `entering = []` | branch e2e allocations, own and emit L2b.2 entry cases |
| own: snapshot includes `entering` in `consumed` | own-produced IR rejects with "join arm leaves entering owner N live", and abrupt arms with "loop-local owner remains live at an edge" |
| own: entering rows also in the arm's `owners` | the `break` own case and the e2e `break` case fail verification |
| verify: skip the yield exact-set check | the two arm-discharge negatives only |

Commands, narrowest first:

```bash
make -C blorp_2 test-compiler
make -C blorp_2 test-target-components \
  TARGET_COMPONENT_SOURCES=blorp_2/test/unit/test_own/test_ownership_transfer.brp
make -C blorp_2 test-target-components \
  TARGET_COMPONENT_SOURCES=blorp_2/test/unit/test_verify/test_ownership_transfer.brp
make -C blorp_2 test
scripts/blorp2-fixpoint --prove
git diff --check
```

Profile recipe, run once at the base commit and once at the candidate
(macOS `sample`). `fixpoint/b.c` is the C that B emits, identical to B's own
source at the fixpoint; `--prove` overwrites `blorp_2/build/fixpoint/`, so
copy each run's artifacts first:

```bash
side=base   # or candidate
mkdir -p build/l2b/$side
scripts/blorp2-fixpoint --prove
cp blorp_2/build/fixpoint/b.c build/l2b/$side/b.c
clang -O2 -g -fno-omit-frame-pointer -DBLORP_MEMORY_DIAGNOSTICS=0 \
  build/l2b/$side/b.c -o build/l2b/$side/b_profile -lm -lpthread
build/l2b/$side/b_profile --library-root blorp_2/standard_library \
  blorp_2/src/main.brp build/l2b/$side/self.c &
sample $! 600 1 -mayDie -file build/l2b/$side/sample.txt
```

#### Acceptance criteria

For each stage:

1. The new suites and fixtures fail before and pass after; each oracle
   mutation fails exactly its listed tests.
2. **Scaling.** `control_flow_accumulators.brp` at 16,384 / 32,768 / 65,536 /
   131,072 appends, in mode `nested` for L2b.1 and `in_arms` for L2b.2: logical allocations are equal at
   every size (growth resizes; the [capacity
   contract](#capacity-and-ownership-contract) counts logical allocations),
   and native normal instructions minus the `none` control grow at most 2.3×
   per doubling.
3. **Compile-time scaling.** B compiling inputs of 16 / 32 / 64 / 128
   sequential and nested `if` arms that append, generated by a scratch script
   under `build/l2b/` that is not retained: candidate whole-compile
   instructions are within 1.10× of base B at every size, and no repeatable
   near-quadratic doubling appears that base lacks.
4. `scripts/blorp2-fixpoint --prove` passes; every strict report balances.
5. **Fixtures.** No e2e allocation count increases. Every differing emitted
   fixture C (A, base versus candidate) is classified as drops moved into
   arms, a borrowed update becoming consuming, or a removed entry
   acquisition, with counts reported; any other difference is investigated.
6. **Self-compilation** on one frozen input, B at `-O0`, one warmup, three
   normal samples and one strict, against self-built B at `9227d0418`:
   allocations and normal minimum instructions do not increase; peak RSS is
   investigated above +10%; emitted C bytes are investigated above +5% with a
   +10% ceiling (the roadmap's feature default; the static estimate is about
   +1%). After L2b.2, the target is at least 50% fewer instructions, with
   `lex` and `program_inventory` each under 5% of inclusive samples in the
   matched profile; a miss means re-profiling and reporting.
7. **Production lines**, formatted, tests separate: L2b.1 investigate above
   +60, ceiling +100 (raised from +80 after measuring +92: the decision plus
   `for`-loop error plumbing); L2b.2 investigate above +120, ceiling +150.

#### Release strategy

Land L2b.1 and L2b.2 as separate squash commits, each after code review, test
review and its measurements. Then publish and pin a seed carrying L2b (the
L2 seed is already pinned) through the qualified process; that pin unblocks
L3. Each commit backs
out by revert: no format, ABI or library contract changes.

#### Handback

Return commits, review verdicts, test counts and failures, mutation outcomes,
matched metrics, line counts, profile tops before and after, evidence paths
under `build/l2b/`, and remaining borrowed updates in `lex` and
`program_inventory`. Stop and ask when the verifier needs a permission kind
beyond the existing two, emit or the runtime must change, a ceiling fails,
the shared scan shows in the profile, or a premise above proves wrong.

### L2b.1 validation

L2b.1 as landed includes its review follow-up. With the follow-up, `make -C
blorp_2 test` reports 47 suites and 375 tests with no failures, native e2e 9
of 9; `scripts/blorp2-fixpoint --prove` reaches the fixpoint: A, B and C emit
identical compiler C (`af1ca68e54d1`), all 594 fixtures match under A and B,
and B passes the components (322 tests, every strict report balanced) and the
native e2e selection. The new loop-entry fixture prints identical output and
allocates 29 times instead of 42; `append_reuse` drops from 31 to 27. Against
the base own and verify, the new suites fail: own 6 of 8 (its two acquire
controls hold) and verify 10 of 10. L2b.1 has no emit suite: emit is
unchanged, and a generated-C check would only pin owner numbering.

Mutations are applied to source snapshots compiled by the unmutated A, with
the follow-up:

| Mutation | Failures |
| --- | --- |
| own: always `AcquireAtEntry` | own transfer 6 of 8 (all but the two acquire controls), e2e `loop_entry_accumulator` and `append_reuse` |
| verify: skip the owns-its-initial check | only "a taken owner must own its header initial" |
| verify: skip the `ExecuteLoop` discharge | verify 10 of 10 (the accepted baseline leaks at return), own transfer 6 of 8, own List updates 4 of 22 |
| own, probe: ignore loop rows | the two nested accumulators and the abrupt-arm loop-row case; the earlier-break case uses the drop bucket and passes |

`control_flow_accumulators` in mode `nested` (`-O2`, minimum of three, normal
instructions minus the `none` control):

| Appends | Allocations, base → L2b.1 | Base | L2b.1 | L2b.1 per doubling |
| ---: | ---: | ---: | ---: | ---: |
| 16,384 | 1,032 → 8 | 17,651,439 | 721,860 | |
| 32,768 | 2,056 → 8 | 60,011,877 | 1,540,505 | 2.13× |
| 65,536 | 4,104 → 8 | 222,571,107 | 2,838,012 | 1.84× |
| 131,072 | 8,200 → 8 | 921,700,562 | 5,641,800 | 1.99× |

`in_arms` is unchanged (L2b.2). Compiling 16 to 128 sequential and nested
appending `if` arms, B takes 0.994 to 0.998 of base instructions, with
identical C. Of 593 shared fixtures, A emits identical C for 493; the rest
differ only by removed entry acquisitions (10 acquire/release pairs in 5
fixtures). All exits, stdout and diagnostics match.

Self-compilation of the first implementation, before the review follow-up, on one frozen input against self-built base
B, both at `-O0`, one warmup, three normal samples and one strict:

| Whole self-compilation metric | Base | L2b.1 | Change |
| --- | ---: | ---: | ---: |
| Allocations | 28,731,623 | 28,415,377 | −1.10% |
| Normal retired instructions, minimum of three | 1,060,582,567,898 | 1,023,088,165,772 | −3.54% |
| Normal peak RSS, maximum bytes | 332,595,200 | 334,217,216 | +0.49% |
| Emitted C bytes | 22,704,582 | 22,570,583 | −0.59% |

| Code lines (formatted, excluding blanks and comments) | Change |
| --- | ---: |
| `own.brp` | +73 |
| `verify.brp` | +31 |
| `lower.brp` | −4 |
| Production | +100 |
| Tests | +730 |

These include the follow-up, against `25dffb1de`; the first implementation
measured +92. The follow-up pairs each header with its decision and shares one
transfer predicate with update consumption. The `step_reads` change in
`lower.brp` predates the follow-up, so its cost is inside the self-compile
table above.

Remaining borrowed updates, left for L2b.2: in `lex`, the per-token appends
to `tokens`, `spellings`, `levels` and `bodies` sit in `if` and `match` arms
(L2b.1 removes only the copy at each line's inner loop entry); in
`program_inventory`, the appends to `types`, `runtime_calls`, `list_updates`
and `callable_entries` sit in `match operation` arms (its nested loop entries
now transfer). Raw samples, commands and logs are local, under ignored
`build/l2b/` in the implementing worktree.

### L2b.2 validation

Measured against `de2d4e4dd` (L2b.1 on main). With the review follow-up,
`scripts/blorp2-fixpoint --prove` reaches the fixpoint: A, B and C emit
identical compiler C (`2975e872a5f2`), all 595 fixtures match under A and B,
and B passes the components (347 tests, every strict report balanced) and
the native e2e selection. `make -C blorp_2 test` passes 401 tests. The new `branch_accumulator` fixture prints
identical output and allocates 33 times instead of 78; no other e2e
allocation count changes. Against the base own and verify, with only the
`entering` field added, the new suites fail: own 9 of 19 (all L2b.2 cases
but the two controls whose owner stays out of the join) and verify 12 of 21
(every L2b.2 case), before the follow-up added one own case (an entering
owner read only by a nested loop's body drops after the loop step) and two
verify cases (storing an entering owner in a payload, accepted, and storing
a non-entering one, rejected at the yield).

As planned, `OwnedJoin.entering` lists the owners a join takes, decided from
the step's drop bucket and loop rows through the shared `transferable_here`;
a scan shared with loop rows finds each one's last read in each yielding
arm, recorded as `DropOnEntry` or `LastReadInArm`. The verifier drops them at
`ExecuteJoin` and checks the exact set at each yield; `EnclosingDischarge`
is deleted, since only selection edges used `KeepsEnclosing` and they admit
only local drops and transfers. One more own expectation encoded the old
rule: in `match values: [first, ..._]: append(values, first)` the edge
acquires `first`, so the dying `values` now enters the join and is consumed
(checked natively under ASan). Emit gets no suite, as for L2b.1: the
emit rows of the mutation table are covered by the own cases and the e2e
allocation count.

Mutations are applied to source snapshots compiled by the unmutated A, with
the follow-up:

| Mutation | Failures |
| --- | --- |
| own: `entering = []` | own transfer 10 of 20, verify transfer 1 (its own-produced join has no entering owner), own List updates 1 of 22, e2e `branch_accumulator` only |
| own: snapshot includes `entering` in `consumed` | own transfer 10 of 20, verify transfer 1, own List updates 1; the compiler rejects the e2e driver: "join arm leaves entering owner 3 live" |
| own: entering rows also in the arm's `owners` | own transfer 1 (the nested `break` case); the compiler rejects the e2e driver: "owner 313 has already been discharged" |
| verify: skip the yield exact-set check | verify transfer 4: the three arm-discharge negatives (drop, store and leaving live) and the L2b.1 loop-in-arm negative, which now reports at the yield |

`control_flow_accumulators` in mode `in_arms` (`-O2`, minimum of three, normal
instructions minus the `none` control):

| Appends | Allocations, base → L2b.2 | Base | L2b.2 | L2b.2 per doubling |
| ---: | ---: | ---: | ---: | ---: |
| 16,384 | 16,392 → 8 | 225,607,258 | 882,817 | |
| 32,768 | 32,776 → 8 | 857,948,034 | 1,689,789 | 1.91× |
| 65,536 | 65,544 → 8 | 3,331,133,918 | 3,266,038 | 1.93× |
| 131,072 | 131,080 → 8 | 13,114,219,549 | 6,473,968 | 1.98× |

Compiling 16 to 128 sequential and nested appending `if` arms, B takes 0.19
to 0.36 of base instructions. Nested inputs grow faster than linearly in both,
and base's increments grow faster than L2b.2's. Of 500 fixtures A compiles to
C, 409 are identical; 90 differ only in drops moved into arms and one, the new
fixture, also in borrowed updates that became consuming. No entry acquisition
or other statement changes, and every exit, stdout and diagnostic matches.

Self-compilation of one frozen input (the base source) by self-built B, all at
`-O0`, one warmup, three normal samples and one strict:

| Whole self-compilation metric | `9227d0418` | Base | L2b.2 | Change from base |
| --- | ---: | ---: | ---: | ---: |
| Allocations | 28,728,628 | 28,413,965 | 24,959,532 | −12.2% |
| Normal retired instructions, minimum of three | 1,061,283,388,595 | 1,023,690,790,433 | 96,454,731,373 | −90.6% |
| Normal peak RSS, maximum bytes | 335,200,256 | 328,089,600 | 273,317,888 | −16.7% |
| Emitted C bytes | 22,701,325 | 22,567,324 | 22,849,621 | +1.25% |

Against `9227d0418` that is 90.9% fewer instructions, past the 50% target.
In the matched profile (B's C at `-O2 -g`, compiling `blorp_2/src`, 1 ms),
samples fall from 24,213 to 1,680. `program_inventory` falls from 23.2% to
0.7% inclusive. `lex` falls from 15,300 samples (63.2%) to 197 (11.7%), above
the 5% target: 140 of them are in `intern_names`, which rebuilds its bucket
index as names grow (`index_spellings`, 96) and updates a borrowed bucket
table through `with_bucket_entry` (24), a parameter that cannot be consumed.
`lex` without it is about 3.4%. No borrowed update remains in either
function (`lex` had 11 and `program_inventory` 6).

| Code lines (formatted, excluding blanks and comments) | Change |
| --- | ---: |
| `own.brp` | +75 |
| `verify.brp` | +10 |
| `lower.brp` | 0 |
| Production | +85 |
| Tests | +680 |

The tables above were measured before the review follow-up, which only
restructures `own` and `verify`. Rebuilt with it, B emits byte-identical C
for the frozen input; its instructions rise 0.04% and its allocations 0.21%,
from a closure that replaced a duplicated list of entering rows.

These deferred suites pin a drop after a join, mostly of a selection's
parent, and so still encode the old rule. They cannot compile under Blorp 2;
when ported, each expects the owner to enter its join instead, so their
failures are not regressions: `test_emit/test_owned_prefix.brp:70`, `:118`
and `:190`; `test_own/test_source_loop_control.brp:184`;
`test_own/test_generic_list_phases.brp:458`; `test_own/test_write_file.brp:44`
and `:63`; `test_own/test_managed_union.brp:314`;
`test_own/test_string_from_codepoint.brp:17`; `test_own/test_join.brp:146`
and `:413`; `test_own/test_file_read.brp:36`;
`test_own/test_selection_inputs.brp:274`; `test_own/test_list_join.brp:58`;
`test_own/test_string_slice.brp:71`; and
`test_own/test_current_directory.brp:35`. The deferred verify cases in
`test_join.brp`, `test_carried_join.brp` and `test_string_concat.brp` were
restated for the new contract by reasoning, and are equally unverified. Raw samples, commands and logs are
local, under ignored `build/l2b2/` in the implementing worktree.

### L3: replace temporary balanced library copying

`standard_library/list.brp:123` implements map/filter through recursive splitting
and concat; `copy_range` and `reverse_range` do similar work. After L1, replace
these with ordinary loops and a local append accumulator. For example:

```blorp
pure func map[T, U](values: List[T], callback: pure (T) -> U) -> List[U]:
    var mapped: List[U] = []
    for value in values:
        mapped = mapped.append(callback(value))
    mapped
```

This keeps source order and evaluates each callback once. Filter keeps matching
elements in order; take/drop/copy-range clamp bounds exactly as today; reverse
walks source indices backward. Port remove only through these existing helpers.
After L2b, an append inside a branch consumes the accumulator, so filter appends
each matching element in its branch, and bounded copying/reverse append inside
the match on fallible `get`. Require an owned-IR witness that each append
consumes the accumulator before claiming linearity.
Delete replaced recursion and temporary concatenation paths in the same change.
Do not rewrite unrelated compiler call sites to compensate for a missing fast
path. Acceptance: linear element visits/output construction, constant traversal
stack and fewer production lines; retain exact callback order and all boundary
cases. Check the resulting owned calls actually consume the accumulator.

### L4: simplify stable sorting

Separately replace `MergedPrefix`, `merge_first` and recursive `merge_prefix`
with one ordinary linear merge loop. Preserve stable left-first tie selection
and existing key/callback semantics; key caching is a separate API decision.
The outer merge sort may keep its bounded recursion. Delete superseded state
and helpers. Acceptance: O(n) work per merge and O(n log n) total sorting work
for constant-cost keys, stable duplicates, bounded stack, and fewer production
lines. Do not add a new sorting algorithm or mutable public builder.

### Tests, measurements and landing

Add ordinary self-hosted TestSuite cases at each changed boundary: selection,
independent verification (including malformed consumed arguments), emitter and
runtime helper. Existing runtime cases are in
`test/runtime/test_generic_list.brp`; port only the bounded required cases if
their current harness is deferred. Keep unaffected borrowed-helper tests and
add consuming-helper tests; do not delete shared-alias coverage to accommodate
reuse. Runtime allocator wrappers may observe/force relocation under the existing
direct-C test exception; do not add production tracing or alternate fixture mains.

Cover lengths 0/1/3/4/5/8/9, exact-sized constructors, shared roots, repeated
child pointers, self/dependent operands, nested Lists, Strings, inline records,
managed records, unions, callable elements and Void. Check no double drops,
uninitialized reads or alias mutation. Add a real-main source accumulator fixture
with strict accounting and ASan/UBSan, and a retained large growth workload.
Prove oracles by disabling reuse or breaking a transfer/drop, observing the
specific failing test, then restoring it. Runtime bounds receive synthetic
boundary tests without attempting enormous allocations.

Run one narrow suite before the broad gates, for example:

```bash
make -C blorp_2 test-compiler
make -C blorp_2 test-target-components \
  TARGET_COMPONENT_SOURCES=blorp_2/test/unit/test_own/test_list_reuse.brp
scripts/blorp2-fixpoint --prove
```

`test_list_reuse.brp` is a proposed new suite, not an existing test. Wire the
necessary granular suites and new fixture into the active self-hosted selection
in the same milestone. Never run deferred cases using the legacy compiler.
`--prove` includes the active component/e2e gates; `make -C blorp_2 test` is
the shorter broad iteration gate, not an extra required repeat after the proof.
Run serialized matched baseline/candidate self-built B measurements at identical
optimization levels, with three normal samples after warmup and separate strict
diagnostics. Retain exact commands, hashes, toolchain and raw samples in ignored
`build/`; summarize the results in this maintained section rather than creating
another report. Intentional emitted-C changes require semantic checks and a new
fixpoint; baseline/candidate C identity is not an acceptance requirement.

The existing ML bounds remain: investigate above +5% allocations or normal
minimum retired instructions per frozen control; +10% is the rejection/rescope
ceiling. Also investigate peak RSS increases above 10%; do not trade large
padding/retention growth for a favorable counter. Target at least 50% fewer
logical old-slot copies on the largest unique-append control, logarithmic growth
events and linear relocation scaling. These are design targets to verify, not
predicted compiler-wide speedups. Initial production-growth design bounds are
+250 net lines for L1 and +150 for L2, including removal of replaced code;
L3/L4 must reduce production lines. Report test growth separately. A missed
bound calls for examining the responsible code and rescoping, not an expanding
framework or repeated trivial allowance requests.

Land each complete approved slice as one squash commit; no plans-only or
capacity-only production commits. Keep bootstrap activation separate: prove the
candidate self-hosts, then use the existing qualified seed publication/pin
process when the change should reach the default builder. Return the commit,
two review verdicts, test counts/failures, matched metrics/line counts, evidence
path and remaining borrowed-call opportunities. Stop for coordinator guidance
on an ownership ambiguity, an ABI change beyond this reviewed List capacity
layout/ownership contract, or a material regression.

## Ownership contracts roadmap

Status: planned 2026-10-28; two design reviews approved the plan. Keith
adopted owned-parameter contracts and the step-0 spike; pinned callables, the
entry and `foreign` as borrowed, with no tail-call owning use, provided that
stays simpler than the alternatives; approved the test-only labelling
parameter; and approved reordering record-update projections. Cell reuse (O3)
is decided after the O0 measurement. O0 and O1 wait for L2b.2 and its seed
pin; O2 touches only lowering and may land at any time. On 2026-10-29 Keith
accepted the step-0 spike's ceilings, keeping inference over insertion's own
decisions ([step-0 results](#step-0-results)).

| Step | Scope | Status |
| --- | --- | --- |
| [O0](#o0-re-measure-after-l2b) | Re-run the self-compile copy attribution and count atomic RC operations | Measured ([results](#o0-results)) |
| [O1](#o1-owned-parameter-contracts) | Per-parameter owned/borrowed contracts, inferred from in-place runtime operations | Approved; step 0 measured ([results](#step-0-results)), ceilings set |
| [O2](#o2-record-update-binds-before-it-rebuilds) | Project the base fields an update reads before its replacements run | Approved; may land before O1 |
| [O3](#o3-cell-reuse-for-records-and-union-nodes) | Reuse tokens for unique record cells and boxed union nodes | Undecided; O0 found no allocation witness |

### Problem

L1/L2 reuse a List or String buffer only when a consuming runtime call holds
the value's last owner. Every user parameter borrows (`own/own.brp:754`
publishes `BorrowedResult(ParameterBorrow(...))`), so a callee can never reuse
its argument, and an accumulator threaded through a helper is copied on every
call:

```blorp
pure func emit_line(output: String, line: String) -> String:
	"${output}${line}\n"                  -- StringConcat on a borrowed output copies it

pure func render(lines: List[String]) -> String:
	var output = ""
	for line in lines:
		output = emit_line(output, line)  -- O(total bytes × lines)
	output
```

The same shape copies the whole bucket table in `with_bucket_entry`
(`utils/names.brp:154`) and the list in the library's `set_index`. A record
update copies a field accumulator because the base is still alive when the
replacement runs (`lower/lower.brp:538-557`):

```blorp
record State { items: List[Int], count: Int }

pure func push(state: State, item: Int) -> State:
	{ state | items = state.items.append(item), count = state.count.add(1) }   -- n pushes: O(n²)
```

Self-compile attribution at `de2d4e4dd`, by a marker-instrumented B that
emits identical C, found:

| Path | Calls | Copied |
| --- | ---: | ---: |
| List borrowed update | 4,062,692 | 9,984,472,912 slots |
| List shared fallback | 714,382 | 431,986,070 slots |
| String borrowed update | 1,168,464 | 725,080,074 bytes |
| String shared fallback | 348,224 | 191,986,727 bytes |

`lex`, `program_inventory` and `intern_names` hold 10.2 B of the 10.4 B
slots; they are appends in join arms and loops inside arms, which L2b.2
targets; [O0](#o0-results) measured L2b closing 99% of the List copies and
`append_byte_array`'s String copies. What L2b leaves is the parameter case:
190 MB of String from `append_owner_alias`, `append_selection` and
`append_loop`, whose `output` parameter borrows, and 65.6 M slots from
`with_bucket_entry`. Four emit helpers
(`emit/emit.brp:1827`, `1956`, `2860`, `2931`) work around it with a local
`fragments` list.

The reproduction is `helper_accumulators`, with modes `list_helper`,
`string_helper`, `set_helper` and `none`, one helper call per update. Normal
instructions minus the `none` control grow 2.7-4.1× per doubling between
4,096 and 65,536 updates ([O0](#o0-results)); linear is 2×.

### Background

The model follows Perceus (Reinking et al., 2021) and Lean 4's borrow
inference (Ullrich and de Moura, "Counting Immutable Beans", 2019). Lean
infers labels starting from borrowed, and its owning uses include constructor
arguments, closure application, `reset` and tail calls. Blorp keeps only
reuse: returning or storing a borrowed parameter costs one acquisition, so
only reuse inside the callee changes the asymptotics. Reference counts are
atomic, so every unneeded transfer costs two atomic operations.

The [ownership invariants](#ownership-and-destruction) remain the authority.
The verifier proves exactly-once discharge and live borrow backing; it does not
prove placement minimal, and correctness never depends on the inference.

### Proposed solution and code

**Labels come from the runtime operations that may update in place.** The
compiler names them in one function. A managed user parameter becomes owned
when its obligation can reach such an operand, or another function's owned
parameter. Labels are per parameter and per concrete instance, so a caller of
a mutating helper is itself labelled only in the positions that flow there.

**A caller not at its last use acquires and transfers.** A reference count
cannot see a borrow. Passing a still-needed value without a counted reference
would let the callee's `references == 1` check pass and mutate a live value:

```blorp
pure func caller(xs: List[Int]) -> Int:
	ys = grow(xs, 1)      -- grow's `items` is owned; xs is still used below
	xs.length().add(ys.length())
```

Own inserts `AcquireOwner` before the call and transfers that fresh owner;
`grow` sees count two and copies, as today, for two extra atomic operations.

**The ownership stage refines the signature**, rather than keeping a parallel
table. Every function carries its passing by construction:

```blorp
-- How the ownership stage passes one parameter. Replaces
-- FunctionSignature.parameters in the published OwnedFunction.
fixed record ManagedPassing {
	value_type: TypeRef,
	-- The caller transfers one obligation; the callee discharges it.
	owned: Bool
}

fixed union OwnedParameter:
	UnmanagedParameter(TypeRef)
	ManagedParameter(ManagedPassing)

fixed record OwnedFunction {
	parameters: List[OwnedParameter],
	return_type: TypeRef,
	operations: List[OwnershipOperation],
	result: ReturnTransfer
}
```

A `ParameterDefinition`'s result kind is built from its row, and the existing
result-shape rule (`verify/verify.brp:1485`) reads the row.

**Pins.** Instances taken as callables (`FreeCallableDefinition`,
`CapturedCallableDefinition` targets), the entrypoint and future `foreign`
functions are pinned borrowed. One function, `pinned_instances(program)`, in
`own/own.brp`, which defines the ownership IR, finds them; own and verify both
call it. Invocation keeps today's borrowed callable ABI and needs no adapters. The
cost is that `rows.map(add_zero)` still copies each row, and so do direct calls
of a pinned `add_zero`. Keith accepted the pins "so long as this is simpler
than the alternative" and would like the callable restriction lifted in
future. A suggested trigger, not his condition: callbacks specialising into
direct calls.

**No tail-call owning use.** Only annotated self tail recursion is
guaranteed, and it becomes a loop that L2b.1 handles. Suggested revisit: the
mutual-tail-call design.

**Runtime-operation contract.** A builtin's reusable operand takes a move when
one is available and otherwise accepts a plain borrow, which selects the copying
helper with no atomic operations. User owned positions always receive a
transfer. One function next to `Builtins` is the only authority:

```blorp
-- namespace/builtins.brp. Whether a runtime operation may reuse operand 0's
-- buffer in place when it receives that operand's obligation.
pure func reuses_first_operand[V, T](operation: RuntimeOperation[V, T]) -> Bool:
	match operation:
		StringConcat | StringAppendInt | ListAppend(_) | ListSet(_) | ListConcat(_): True
		_: False
```

It replaces the four hard-coded copies at `own/own.brp:1083-1090`,
`verify/verify.brp:578-586` (`consuming_update_borrows`),
`emit/emit.brp:1049-1065` and `call_list_update` (`emit/emit.brp:2831`).

**Inference is a monotone fixpoint over insertion's own decisions**, not a
second copy of the move rules. The analysis runs insertion with the current
contracts and with every managed parameter of the analysed function
provisionally owned, giving each an owner o_p. Parameter p is labelled owned
only if o_p itself reaches a `ConsumedArgument` at a reusing builtin operand
or an owned user position, directly or through an L2b.1 header take, an L2b.2
join entry, or a projection acquired after o_p is discharged. A fresh
acquisition at a non-last-use call does not count, nor does a take that is
only dropped or returned. For
`pure func f(a: List[Int], b: List[Int]) -> List[Int]: a.append(b.length())`
the provisional pass consumes o_a and drops o_b, so `a` is owned, `b`
borrowed, and insertion re-runs.

Labels only move from borrowed to owned. A flip adds a consuming position and
turns a `BorrowedArgument`, which can block a move, into an acquisition, which
cannot; if position 1 of `g(xs, xs)` becomes owned, `xs` can move into
position 0. The worklist is seeded with functions that have a managed
parameter and any `reuses_first_operand` call (the operand need not be the
parameter: a loop header fed by it qualifies). Afterwards only callers of
flipped functions are re-analysed, and a function whose final labels equal its
provisional ones keeps that result. Each parameter flips at most once, so the
work is O(S + P·C) analyses for S seeds, P managed parameters and C the
largest caller count; strongly connected components need nothing special.

**Call sites:**

```text
user call, owned position j, argument backed by owner o:
	o dies at this step, no BorrowedArgument of the call depends on o,
	and no earlier owned position of the call received o      -> ConsumedArgument(v, o)
	otherwise                                                -> AcquireOwner(fresh) before the call;
	                                                            ConsumedArgument(v, fresh)
builtin operand 0 where reuses_first_operand                 -> move if o may move, else BorrowedArgument
borrowed position                                            -> BorrowedArgument (today)
```

The dependency check generalises `consume_update_left` (`own/own.brp:1041`)
to every owned position, through projection ancestry (`dependency_owner`).
An owned parameter is then an ordinary local obligation: drop buckets, header
takes, join entering and return moves apply unchanged.

**Verifier.** Contracts are a specification; the verifier does not re-infer
them. Rows must match specialization types and `value_needs_ownership`, and
every row of a pinned instance is borrowed. Call sites are checked in two
passes: first discharge consumed owners in argument order (a second discharge
fails with "owner N has already been discharged"; a consumed argument appears
only at an owned position or a reusing operand, and an owned position must
receive one), then recheck every borrow against the post-discharge state
through projection ancestry, as `discharge_update_argument` does today. An
owned parameter introduces `ActiveOwner(DefinedOwner)`, which the existing exit
checks must discharge.

**Emitted C** keeps its types; only who drops changes, and a transferring call
becomes eligible for a C sibling call:

```c
/* Borrowed: the caller drops after the call, and the callee copies. */
struct blorp_l_0_i* const blorp_vl_9=blorp_f_42(blorp_vl_7,blorp_vl_8);
blorp_list_drop_0_i(blorp_owner_3);
return blorp_vl_9;
/* Owned: the caller transfers, and the callee consumes or drops. */
struct blorp_l_0_i* const blorp_vl_9=blorp_f_42(blorp_vl_7,blorp_vl_8);
return blorp_vl_9;
```

Passing changes no semantics, so it needs no syntax.

**Rejected.** Case-by-case fixes, because the parameter gaps need an
interprocedural fact anyway. A Perceus rewrite of `own`, which already places
drops by liveness; a rewrite adds the largest bootstrap risk for no capability
this lacks.

### O0: re-measure after L2b

After L2b.2 and its seed pin, re-run the copy attribution on the new B. Add
exact atomic increment and decrement counters at the RC sites and a sampled
instruction profile; today's record and union dup counts include nested and
no-op visits, so they are not atomic-operation counts. Report which copies
L2b closed and the record, union and String RC traffic. O1 does not start
before this report; O3 is decided from it.

O0 also compares Blorp 2 against the legacy compiler. Its Core passes in
`blorp/src/compiler/stage_09_core/` already infer consumed user-call arguments
(`ownership_contracts.brp`), clone consuming record callees
(`consume_specialize.brp`) and reuse record and union cells (`reuse.brp`, `record_update.brp`). The plan must match that
reach with independent verification and far less code. Land `helper_accumulators` (modes `list_helper`,
`string_helper`, `set_helper`, `none`) in `benchmarks/blorp/` and
`benchmarks/blorp_2/` with an `args` file and an `EXTRA_BENCHMARKS` entry,
like `control_flow_accumulators`. Build `helper_accumulators`,
`control_flow_accumulators`, `compiler_ast`, `binary_trees` and
`compiler_emit` with both compilers from the same commit, with the same C
compiler and flags. Run each native program directly and serially. Report
normal instructions and logical allocations per mode and size, and growth per
doubling. The List and String modes set O1's legacy parity criterion;
`compiler_ast` and `binary_trees` measure the record and union gap that
decides O3.

#### O0 results

Measured at `a4ad3113e` (L2b seed `blorp2-seed-50d3922f3449`) on an Apple
M4 with Apple clang 21, one sample per point. B is `make -C blorp_2
compiler`; its self C is `2975e872a5f2`, as the seed workflow expects.

**Copies in self-compilation**, by the gap-analysis attribution method
(a marker-instrumented B, every update helper attributed to its Blorp
caller), against the same method at `de2d4e4dd`:

| Path | `de2d4e4dd` calls | Copied | `a4ad3113e` calls | Copied | Change |
| --- | ---: | ---: | ---: | ---: | ---: |
| List borrowed update | 4,062,692 | 9,984,472,912 slots | 755,882 | 93,224,709 slots | −99.1% |
| List shared fallback | 714,382 | 431,986,070 slots | 581,228 | 29,104,926 slots | −93.3% |
| String borrowed update | 1,168,464 | 725,080,074 bytes | 617,542 | 285,267,151 bytes | −60.7% |
| String shared fallback | 348,224 | 191,986,727 bytes | 223,398 | 85,934,248 bytes | −55.2% |

Allocations fall from 28,413,897 to 25,168,207 (−11.4%), balanced under
strict accounting. L2b closed the join and loop-entry copies (`lex`,
`program_inventory`, `intern_names`). The largest remaining copies are the
parameter cases O1 targets: `append_owner_alias` (105.6 MB) and
`append_selection` (76.1 MB) append to a borrowed `output`, and
`with_bucket_entry` copies 65.6 M slots. `emit` still copies its
23 MB result three times (69.0 MB, cause not traced), and the library's
`join_range` falls back on 60.4 MB of shared elements. Tail-position user calls: 146 with nothing before the
return, 21 followed only by drops.

**Atomic reference-count operations**, counted exactly at every
`atomic_fetch_add`/`atomic_fetch_sub` on a `references` field in B's self C
(1,480 sites), during one `-O2` self-compilation whose output is identical:

| Kind | Increments | Decrements |
| --- | ---: | ---: |
| Record | 368,806,790 | 377,441,570 |
| List | 162,715,026 | 169,213,920 |
| Union (boxed) | 60,138,484 | 61,139,629 |
| String | 17,716,259 | 26,749,527 |

That is 1.24 B atomic operations, 60% of them on records. Their call sites
are not attributed; own inserts `AcquireOwner` at `own/own.brp:1371`,
`1376`, `1502`, `1553` and `1558`. The `-O2 -g` self-compilation retires 29.7 B instructions in 2.24 s
with 278 MB peak RSS. A 1 ms `sample` profile of the same run took 1,717 samples. By top of
stack, over all 1,717: allocator frames 29%, reference-count helper frames
12%, `memmove`, `memset` and `bzero` 10%. Specialization instance lookup
(`find_instance`, `slot_has_union_key`, `find_union_instance`,
`slot_has_record_key`, `same_type`, `find_union_slot`,
`find_record_instance`) holds 20%: the linear lookup already listed under
[deferred work](#deferred-beyond-the-fixpoint).

**Against the legacy compiler.** Each benchmark built by `bin/blorp compile`
and by B from the same worktree, `clang -fwrapv -O2`. Instructions are normal
retired instructions minus the `none` control at the same size; allocations
are whole-process totals from a `-DBLORP_MEMORY_DIAGNOSTICS=1` build. Sizes
run from 4,096 to 65,536; `set_helper` stops at 32,768, because its
quadratic run would need about 4.3e10 instructions at 65,536 and 1.7e11 at
131,072. Growth per doubling omits the 4,096 to 8,192 step, where startup
jitter of about 1 M instructions exceeds the work:

| Mode at 65,536 | Legacy | Blorp 2 | Legacy per doubling | Blorp 2 per doubling | Allocations, legacy / Blorp 2 |
| --- | ---: | ---: | ---: | ---: | ---: |
| `list_helper` | 2.40 M | 3,330 M | 1.69-2.08× | 3.75-3.88× | 21 / 65,544 |
| `string_helper` | 9.80 M | 523 M | 1.92-2.07× | 2.78-3.66× | 23 / 65,544 |
| `set_helper` (32,768) | 1.69 M | 10,794 M | 1.71-2.05× | 3.96-3.98× | 7 / 32,776 |
| `in_arms` | 2.63 M | 3.27 M | 1.79-1.89× | 1.90-1.99× | 21 / 8 |
| `nested` | 2.52 M | 2.81 M | 1.81-1.97× | 1.80-1.95× | 21 / 8 |
| `flat` | 2.49 M | 2.79 M | 1.64-1.93× | 1.92-1.99× | 21 / 8 |

Blorp 2's helper modes allocate once per update at every size (count plus 8:
4,104 at 4,096 to 65,544 at 65,536); the legacy compiler's stay between 7 and
23 in every mode and size. The legacy compiler is
linear in every mode. After L2b, Blorp 2 is linear inside one function but
copies on every helper call, which is exactly O1's scope; O1's parity
criterion is unmet today by one to three orders of magnitude (53× for
`string_helper`, 1,387× for `list_helper`, 6,400× for `set_helper`).

| Benchmark | Legacy instructions | Blorp 2 | Allocations, legacy / Blorp 2 |
| --- | ---: | ---: | ---: |
| `compiler_ast` | 177.5 M | 195.0 M | 310,316 / 310,315 |
| `binary_trees 15` | 3,299 M | 3,529 M | 6,444,438 / 6,444,423 |
| `compiler_emit` | 33.0 M | 69.9 M | 8 / 52,328 |

Legacy cell reuse saves no allocations on `compiler_ast` or
`binary_trees`, so neither is a witness for O3; Blorp 2 trails them by 7-15%
of instructions after startup. In `compiler_emit`, a counter added to
`blorp_string_from_bytes` in a scratch copy of the generated C counts 52,327
calls, so all but one of Blorp 2's 52,328 allocations materialise String
literals, which the legacy compiler emits as static data. The instruction gap
(about 15 M against 58 M after startup) is not attributed.

**Conclusions.** L2b closed about 99% of the List copying in
self-compilation. O1 remains justified chiefly by user code: the helper
benchmark is the legacy compiler's largest lead. Its self-compile gain is
bounded by the remaining parameter copies (190 MB of String from
`append_owner_alias`, `append_selection` and `append_loop`, and 66 M slots
from `with_bucket_entry`) and `with_bucket_entry`'s 3% of samples. Neither
record benchmark is an allocation witness for O3. Self-compilation allocations
were not split by kind, and record reference counting (746 M atomic
operations) was not attributed, so O0 does not settle O3 either way.

### O1: owned-parameter contracts

**Preparation (separate commit).** One function, `consuming_helper_name`,
produces the symbol of the in-place helper for a `RuntimeFunction` target
where `reuses_first_operand` holds, never for a user call. The runtime
definitions (`runtime/list.brp:268`, `282`, `302`; the literal C at
`runtime/string_concat.brp:54` and `70`) and emit use it. A new fixture calls
all five operations consumingly, so a missing helper fails to link.

**Step 0: a bounded spike, reviewed before the main work (done).** The
contract and inference were implemented on a scratch branch that never lands.
Diffing generated C confirmed that emit needs only the shared contract. The
spike counted transfers that needed an acquisition because the call was not
the last use, statically and at run time, and reported `own`'s share of
self-compile instructions, the inference's added instructions and
allocations, the pinned-instance count, and seed and re-analysis counts. It
set the binding ceilings below.

#### Step-0 results

Measured 2026-10-28/29 on a scratch branch from d9ad15e35 that never lands.
Self-compiles use the frozen d9ad15e35 source as input, `-O2`, minimum of
three runs, serial:

| | Instructions | Allocations |
| --- | ---: | ---: |
| Base B | 29,746 M | 25.17 M |
| Spike B, seeds narrowed to parameter-fed operands | 31,718 M (+6.6%) | 27.60 M (+9.7%) |
| Spike C | 29,391 M (−1.19%) | 26.32 M (+4.6%) |

- **Correctness.** `make -C blorp_2 test` and `scripts/blorp2-fixpoint --prove`
  passed. All 595 e2e fixtures behaved identically under `AllBorrowed`,
  `InferredLabels` and `AllOwnedExceptPinned`, and the verifier accepted
  every labelling. The spike also reported, without a retained log, that
  dropping the verifier's post-discharge recheck, or moving an owner before
  its last use, makes the verifier reject the result.
- **Benefit.** `helper_accumulators` became linear with constant
  allocations (raw instructions, not net of the `none` mode's 11.5 M):
  - `list_helper`: 3,341 M to 14 M instructions at 65,536.
  - `set_helper`: 10,805 M to 13 M at 32,768.
  - `string_helper` is linear but, net of `none` as in O0, about 4.8×
    legacy at 65,536.
- **Where the cost goes.** Base `own` is 1.82 B instructions.
  - Contracts with no inference (`AllBorrowed`) add 0.20 B (+0.66% of B) and
    0.30 M allocations.
  - The worklist adds 1.69 B and 2.0 M allocations. About 61% is analysis
    insertions that are later discarded, 34% the reach walk, and at most 5%
    label bookkeeping.
- **Counts.**
  - 2,767 functions and 4,829 managed parameters.
  - 265 owned labels in 233 functions; 2 pinned instances.
  - 274 seeds and 633 analyses, of which 245 flip a label.
  - 719 owned calls move and 181 acquire.
  - At run time, self-compiling the instrumented spike source (2,853
    functions, not the frozen input), owned calls make 2.66 M moves and
    0.91 M acquisitions. The acquisitions cost about 1.8 M atomic
    operations, 0.15% of the 1.24 B O0 counted.
  - No owned label went unconsumed.
- **Rejected redesign.** A separate summary walk with a label solver and a
  single insertion was reviewed three ways and rejected.
  - Its facts depend on callee labels at calls that pass one owner twice.
  - It could not share insertion's owner tracking, so it would be the
    second copy of the move rules this plan excludes.
  - Its estimated cost, +1.8% to +4.0%, did not clearly beat the cap.
- **Decision.** Keith accepted the ceilings below and kept inference over
  insertion's own decisions. The +0.5% B target is unreachable, because the
  contracts alone cost +0.66%.
- **What O1 proper must change from the spike.** The spike misses the B
  ceilings and C's allocation ceiling (+4.6% against +2%). O1 proper meets
  them by discarding fewer analysis insertions and re-analysing fewer
  callers. Labels become rows on `OwnedFunction`; the spike kept them in
  each parameter's definition. When one owner fills two owned positions, the
  first moves and later ones acquire.

**Then O1 proper**, test-first (see Testing). Production `own(program)` keeps
its signature and calls an internal `insert_ownership(program, labelling)`
with `InferredLabels`; tests call it with `AllBorrowed` or
`AllOwnedExceptPinned` to prove labels never change behaviour (approved
2026-10-28 as a test-only mechanism).

O1 deletes the four copies of the five-target set, `consuming_update_borrows`, the
operand-0 restriction and its message, and replaces these statements:
`README.md` "Parameters borrow" (1230, 1950, 1963, 2334) and "Parameters
never transfer" (2843); in this roadmap L1's "List calls remain declared
wrapper calls, whose parameters borrow", "No interprocedural consuming ABI" under
[capacity and ownership](#capacity-and-ownership-contract), the L2b
statements that loop entry never retires the caller's obligation, and
"Keep ordinary synchronous parameters borrowed" under
[required ownership invariants](#required-ownership-invariants).
`README.md:547` (a returned borrowed parameter) stays true.

### O2: record update binds before it rebuilds

Today lowering runs the base, the replacement expressions, then projections
of unchanged fields, then a fresh construction. O2 projects the base fields
the update reads first, and points replacement reads of `base.field` at those
projections through typed field and value identities. That is sound because
the base is immutable and projections have no effects:

```text
items0 = state.items      -- projected first
count0 = state.count
drop state                -- last use; items0 is unique if state was
items1 = items0.append(item)
count1 = count0.add(1)
{ items = items1, count = count1 }
```

Replacement expressions still run once in written order, and the order
fixture's output is unchanged. It replaces the evaluation-order text at
`README.md:1320-1322` and the order comment at `lower/lower.brp:536-537`. O2 touches only lowering and may land before O1, but
`push` becomes linear only once O1 makes `state` owned.

### O3: cell reuse for records and union nodes

Undecided until O0. Every update and rebuild allocates a fresh root
(`README.md:1326`):

```blorp
pure func rename_all(path: Path, suffix: String) -> Path:
	match path:
		End: End
		Step(name, rest): Step(name.add(suffix), rename_all(rest, suffix))   -- new node per step
```

The design is a reuse-token obligation: drop-for-reuse of a unique cell yields
a token, and construction of the same instance consumes it; the token joins
`reuses_first_operand`'s root match, which stays sound. It is a constant
factor, adds a verifier owner state and two runtime helpers per layout, and
spreads parameter labels, so it proceeds only if O0 shows record and union
allocation traffic worth it. Without O3, Blorp 2 stays behind the legacy
compiler on record and union rebuilding; O0's `compiler_ast` and
`binary_trees` comparison sizes that gap.

### Scope and non-goals

O1 touches `own`, `verify`, `namespace/builtins.brp`, the runtime helper names and their tests. Emit changes only through the
shared contract. Not in this plan: moves at stores and control edges
(acquire-then-drop costs two atomic operations each; revisit after O0
counts), a report, LSP or `@in_place` (new surface, needs approval),
Lean-style owning uses beyond reuse (only after O3), owned callable parameters
and tail-call owning use (see Pins). Do not touch L2b's worktrees or reopen
its design.

### Risks and unknowns

- **B cost.** The seed-built B pays for the inference and gets none of its
  benefit. The spike's B was +6.6% even with seeds narrowed to operands fed
  by parameters, above the +4.5% ceiling, and its C allocated 4.6% more,
  above +2%. O1 proper has to recover the gap from discarded analysis
  insertions and needless caller re-analysis; if it cannot, stop and ask.
- **Atomic cost of acquisitions.** A labelled parameter whose callers are
  rarely at a last use costs two atomics per call for no gain. Step 0 found
  181 acquiring call sites and no label never consumed; the wasteful-label
  test keeps it that way.
- **Pins.** Step 0 found 2 pinned instances, because specialization already
  turns known callable arguments into direct calls. A large count would mean
  callbacks dominate and the callable restriction should be revisited.
- **Bootstrap.** The old seed compiles O1, so the inference itself uses local
  loops and never threads an accumulator through a helper.

### Dependencies

L2b.2 landed and its seed pinned; the O0 report. The preparation commit
precedes O1. O2 is independent.

### Testing

Failing tests first:

- **Own units:** roots; propagation through a chain, a strongly connected
  component, a header take and a join entry; pins; generic instances; the
  provisional-differs case above; one owner filling two owned positions,
  where the first moves and the later acquires.
- **Verify negatives:** `f(x, x)` with both positions owned (double
  discharge); `f(xs, xs)` with position 0 owned and position 1 borrowed (the
  borrow is backed by the moved owner); the same with position 1 a raw-IR
  `ListElementDefinition` of `xs`, for projection ancestry; a consumed
  argument at a borrowed position; a borrowed argument at an owned position;
  an owned parameter live at return; a pinned owned row; a row that disagrees
  with its type. Each checks its diagnostic text.
- **Benchmark:** `helper_accumulators`, landed by O0 for both compilers. It
  fails before O1.
- **E2E fixtures** under strict accounting and ASan/UBSan: an owned parameter
  on a return that lowers to `Break` (`lower_exit`, `lower/lower.brp:784-798`); on `?=`
  exits; and a `@tail_recursive` List accumulator whose header takes the owned
  parameter (the first managed tail-recursion fixture; stop and report if it
  fails for unrelated reasons).
- **Wasteful labels:** every owned label in self-compile and the fixtures is
  consumed on some path; a violation fails the test gate, not compilation.

| Mutation | Expected failures |
| --- | --- |
| Oracle: all borrowed | only benchmark and fixture cost ceilings; outputs identical |
| Oracle: all owned except pins | no output change; every program verifies |
| own: no acquisition before a non-last-use transfer | verify rejects a use of a discharged owner |
| own: ignore borrowed dependencies in the move rule | the `f(xs, xs)` case, rejected by verify |
| own: drop the pin scan | the callable-taken fixture: "pinned instance has an owned parameter" |
| verify: skip the post-discharge recheck | the two dependency negatives only |
| verify: skip the contract check | consumed-at-borrowed and borrowed-at-owned |
| inference: one round only | the chain and SCC unit cases |

Test migration: 58 test files reference `OwnershipProgram`, 57 build
`BorrowedArgument` and 39 build `ParameterDefinition`; each `OwnedFunction`
literal states its rows with explicit `owned = False`.

Commands, narrowest first. The own and verify suites are new files beside
`test_ownership_transfer.brp`, registered in `blorp_2/Makefile`:

```bash
make -C blorp_2 test-target-components \
  TARGET_COMPONENT_SOURCES=blorp_2/test/unit/test_own/test_owned_parameters.brp
make -C blorp_2 test-target-components \
  TARGET_COMPONENT_SOURCES=blorp_2/test/unit/test_verify/test_owned_parameters.brp
make -C blorp_2 test
scripts/blorp2-fixpoint --prove
git diff --check
```

Benchmarks, for both compilers at one commit, with `side` set to `base` or
`candidate`. Allocations come from a second build with
`-DBLORP_MEMORY_DIAGNOSTICS=1`, as `BENCH_ALLOC_STATS=1` does in
`benchmarks/bench.sh`. Run every binary serially:

```bash
make && make -C blorp_2 compiler
out=build/ownership/$side && mkdir -p $out
for name in helper_accumulators control_flow_accumulators compiler_ast binary_trees compiler_emit; do
  bin/blorp compile benchmarks/blorp/$name.brp -o $out/${name}_legacy.c
  blorp_2/build/compiler --library-root blorp_2/standard_library \
    benchmarks/blorp_2/$name.brp $out/${name}_blorp2.c
  for compiler in legacy blorp2; do
    clang -fwrapv -O2 -DBLORP_MEMORY_DIAGNOSTICS=0 $out/${name}_$compiler.c \
      -o $out/${name}_$compiler -lm -lpthread
  done
done
# Each mode at 4,096 doubling to 131,072; subtract the `none` control.
/usr/bin/time -l $out/helper_accumulators_blorp2 list_helper 4096
```

### Acceptance criteria

Binding since step 0 (accepted 2026-10-29):

- **Benchmark:** at most 2.1× normal instructions per doubling in every mode,
  and equal logical allocations across sizes for `list_helper` and
  `set_helper`.
- **Legacy parity:** in every List and String mode of `helper_accumulators`
  and `control_flow_accumulators`, at the largest size, Blorp 2's normal
  instructions and logical allocations are at most the legacy compiler's,
  and its growth per doubling is no worse. Report `compiler_ast`,
  `binary_trees` and `compiler_emit` against O0 without a ceiling; they
  belong to O3.
- **Self-compile B** (built by the seed): at most +4.5% instructions and
  +7% allocations.
- **Self-compile C** (built by B): at least −1% instructions, at most +2%
  allocations; identical behaviour on all e2e fixtures.
- **Peak RSS:** investigate above +5%, ceiling +10%. **Emitted C bytes:**
  investigate above +1%, ceiling +3%.
- **Compile-time scaling:** generated chains of 16-128 helpers, 8-64 owned
  parameters and strongly connected rings of 8-64 functions each compile
  within 1.06× of base B, with no near-quadratic doubling; report worklist
  analyses.
- **Size:** at most +520 production code lines, tests reported separately.
  The spike used own +464 (about 20 of them counters), verify +40 and
  builtins +4. Legacy needs about 41,400 lines for comparable reach
  (`perceus.brp`, `perceus/`, `ownership.brp`, `ownership_contracts.brp`,
  `reuse.brp`, `consume_specialize.brp` and `record_update.brp` in
  `blorp/src/compiler/stage_09_core/`), with special-case rewrites such as destination
  forwarding and clone classification. If O1 needs a rewrite that the
  contracts and the call-site rule cannot express, stop and ask instead of
  adding one.

### Release strategy

Separate landings, each green: the helper-name preparation, O1, O2 (any time),
O3 if approved. O1 needs no seed for correctness; publish a seed after it so
the default builder gains the savings. Back out O1 by switching production to
`AllBorrowed`, which the oracle proves equivalent, then revert.

### Handback

Return the branch and commits, evidence
for each criterion, the two review verdicts and remaining borrowed-call
opportunities. Stop and ask on a premise that proves wrong, a ceiling breach,
an ABI change beyond these contracts, or a result that looks like a compiler
bug.

## M1b: names and the foundation

**Goal.** The source's 34 namespaces resolve. **Scope.**

- **Part A.** `private` is a `Visibility` fact on each namespace declaration row,
  rejected at import selection with an exact message. Aliases and qualified names:
  the parser mints a qualified-name form from the module's import block, and the
  checker resolves it in expressions, types (`Builtins.RuntimeType[T]`),
  constructors and patterns. See the
  [namespace aliases report](https://github.com/kablorp/blorp/blob/1e07c4dce85e51cd7ad911142e9bc96a5e0d91c7/benchmarks/results/blorp_2_namespace_aliases_2026-10-15.md).
- **Part B.** **Decision:** `Bool`, `Option` and `Result` are designated
  foundation unions. One fact, established by the builtin check from `_base`,
  names the unions and their variant ids. `if`, `and`/`or`/`not`, `?=` and `for`
  consume it by identity. The representation is identical to any other union.
  The per-operation `BooleanRoles`/`OptionalRoles` lists are deleted, so
  `int.equals` returns the designated `Bool`.

**Exit proof.** The tree resolves all 34 namespaces; `private` rejections pinned.

**Status.** Part A done (aliases, `private`, qualified values and types; qualified
flat pattern heads use the same constructor identities under M2b). Part B done: the foundation check publishes the
designation and builtin contracts refer to it; the `if`, `and`/`or`/`not`, `?=`
and `for` consumers arrive with M2.2, M2.3 and M3.

## M5: constants

**Bootstrap goal.** Use the accepted literal Int/Float/String constant path.
The baseline 99-global inventory had 71 such declarations; the other 27 records
and one opaque marker became named construction functions in that historical
source migration.
This explicit bootstrap compromise removes initializer references, graph-cycle
validation and opaque constant initialization from the prerequisite set.

This source migration is historical. The [current constant contract](README.md)
describes implemented aggregate construction and its initializer restrictions.
Ordinary opaque semantics still belong to M4.

**Decision.** Accepted constants materialise at use: no static data, immortal
storage class or runtime change. Static data/CTFE remain future language work,
not bootstrap prerequisites; their ownership policy needs its own reviewed slice.

**Bootstrap exit proof.** No own-source initializer needs more than the accepted
literal path; constructor functions preserve identities and behavior. Generated
C/diagnostics and granular ownership tests remain unchanged on shared fixtures.

**Status.** M5a.1 scalar/String facts, identity/ownership tests, six mutation
oracles, matched costs and the actual-main 2894-component/452-e2e gate pass.
The [scalar report](https://github.com/kablorp/blorp/blob/1e07c4dce85e51cd7ad911142e9bc96a5e0d91c7/benchmarks/results/blorp_2_scalar_constants_2026-10-16.md)
records that bounded path. M5a.2's shared field-admission preparation passes
focused, mutation and matched cost checks, plus actual-main 2902-component/
452-e2e acceptance and the unchanged 36/38 frontier.
The [admission report](https://github.com/kablorp/blorp/blob/1e07c4dce85e51cd7ad911142e9bc96a5e0d91c7/benchmarks/results/blorp_2_record_field_admission_2026-10-16.md)
records its 42 added / +7 net production lines. Closed records, initializer
references/cycles and opaque constant forms are deferred language features.
No M5a.2 production implementation had begun when this scope changed.
The [construction migration](https://github.com/kablorp/blorp/blob/1e07c4dce85e51cd7ad911142e9bc96a5e0d91c7/benchmarks/results/blorp_2_construction_values_2026-10-16.md)
now replaces all 28 aggregate/opaque globals in compiler source. Fresh host Core
retains only 71 literal globals; shared fixture behavior and diagnostics match,
and all 452 e2e cases pass. Ordinary opaque semantics remain a separate M4 task.

## M2: the join

**Integration status.** Restricted value/statement `if`, ordinary Boolean calls,
outer-variable flow and top-level Result propagation are implemented. The README
and grammar describe current placement rules. The design history below does not
establish integrated functional or resource acceptance.

**Bootstrap boundary.** Keep statement/binding/function-tail/arm-tail control,
qualified flat matching, restricted if, outer-variable flow, local annotations
and function-top-level propagation. The
[16 source argument matches are now lifted](https://github.com/kablorp/blorp/blob/1e07c4dce85e51cd7ad911142e9bc96a5e0d91c7/benchmarks/results/blorp_2_argument_controls_2026-10-16.md),
removing their need for general expression inference. The reviewed
[compositional plan](COMPOSITIONAL_CONTROL_PLAN.md) remains a broader language
design; its workloop relocation and arbitrary-expression match/if are deferred.
An omitted else yields Void, including in a binding; its then block must be
Void or statement-only. A non-Void result requires else. Updating an outer
variable uses carried-binding edges on both branches, including the false edge. The design sketches
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
must not know `Bool`. The operator rows below are historical and superseded by
[ordinary Boolean calls](standard_library/README.md); the `.not()` source
migration is implemented in the combined source, with no
further legacy parser, host-library or bootstrap-pin work.

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
(see the [current language reference](README.md)). Its failure arm
returns from the function and discharges the function's live owners; it never
exits an intermediate value join. The accepted Result-only implementation
resolves the remaining function prefix inside an ordinary successful match arm;
it records nesting for realistic1/2/5/9/16 chains. The earlier flat sketch above
is historical, not the current representation. Local type annotations and Result
propagation and restricted `if` are implemented in integration; acceptance
remains separate.

Steps: **M2.1** the join mechanism across lower, own, verify and emit, with
non-tail `match` (needs no `Bool`); **M2.2** restricted `if` (needs the
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
[join report](https://github.com/kablorp/blorp/blob/1e07c4dce85e51cd7ad911142e9bc96a5e0d91c7/benchmarks/results/blorp_2_join_2026-10-16.md). It settled
three details of the sketch above. The original `JoinValue` definition is replaced
by `LoweredStep.Define/Join` and explicit typed parameters in the written unary
preparation. M2.1b now also publishes the reassigned enclosing bindings as
ordered carried parameters, alongside the result (Void for a statement match).
A yielding join arm publishes its value and continuation outputs. An abrupt
arm instead transfers to its resolved enclosing loop through `TransferLoop`;
it publishes no join outputs. The checker records each enclosing `var` reassigned by an
arm; lowering publishes its selected immutable version after the join. The reviewed
[carried-bindings report](https://github.com/kablorp/blorp/blob/1e07c4dce85e51cd7ad911142e9bc96a5e0d91c7/benchmarks/results/blorp_2_carried_bindings_2026-10-18.md) defines structured multi-output
steps, first as a behavior-preserving preparation. Preparation budgets are
accepted and the early physical screen is measured. The current unary port at
accepted main `782824efb` includes the later concat/write-file typed consumers;
its functional gates and 3,944 fixed-epoch cost calls pass. See the
[preparation report](https://github.com/kablorp/blorp/blob/1e07c4dce85e51cd7ad911142e9bc96a5e0d91c7/benchmarks/results/blorp_2_unary_preparation_2026-10-18.md)
for current evidence and the separate historical R0 limitation. The carried
feature's approved budgets and
implementation acceptance remain separate from the preparation. The
[carried-feature report](https://github.com/kablorp/blorp/blob/1e07c4dce85e51cd7ad911142e9bc96a5e0d91c7/benchmarks/results/blorp_2_carried_bindings_2026-10-18.md)
records current functional validation and the 3,976-call frozen cost campaign.
The checked form is `Match(CheckedJoin)` with value arms; the tail match keeps
`CheckedMatchBody`. A match at a Void function's tail discards each arm's
value, as a plain Void tail does. A self call at the tail of a nested match
remains unsupported by annotated tail-call admission. Restricted `if`
uses M1b part B's designated `Bool`; implemented Result propagation uses the
designated `Result` independently of restricted `if`, with the function return's
ownership discharge and independent verification. It requires no early-return
form for a join arm: nested propagation is a parser error.

The [language reference](README.md) owns current `if` and propagation behavior.
The [Result propagation report](https://github.com/kablorp/blorp/blob/1e07c4dce85e51cd7ad911142e9bc96a5e0d91c7/benchmarks/results/blorp_2_result_propagation_2026-10-19.md)
retains its historical ownership, test and cost evidence.

## M2b: pattern compilation

**Integration status.** Recursive constructor, binder-unifying Or, List and
String patterns are implemented through a checker-owned typed pattern matrix
and selection graph. Alternatives enter one canonical arm body; List suffix
captures own their copied roots and String tests compare complete decoded bytes.
The README and grammar define current syntax, name rules and exact coverage.
Char patterns remain unsupported. Focused evidence does not close current
integration, self-compilation or resource acceptance.

**Historical bootstrap scope and source-removal proposal.** Qualified flat constructor heads and non-binding constructor
groups with wildcard payloads. Each group has complete accepted VariantIds,
no captures, one body and exact coverage diagnostics. Current source has 106
or-groups: 99 fit directly; seven factor a common outer constructor.
Canonical duplicate/covered alternatives fail at the offending alternative's
span. The group remains one body through lowering and ownership. Independent
verification checks every label but grants no payload-projection permission.
This feature is bounded to 650 gross added / +450 net production lines.

The qualified-head-only port passed current-composition acceptance; see its
[report](https://github.com/kablorp/blorp/blob/1e07c4dce85e51cd7ad911142e9bc96a5e0d91c7/benchmarks/results/blorp_2_qualified_patterns_2026-10-19.md).
Its fixed accepted B is `ea881c84d0df9df04a6ec5c4406a3b69cf406735`.
The implementation is 42 ADD / 19 DEL / +23 production; the earlier
41 ADD / 20 DEL / +21 forecast remains historical evidence.
Hard limits are 100 gross / +85 net production, 400 nonfixture test,
100 fixture and 30 active documentation additions. The new native fixture
keeps 140,000 allocations / 500,000,000 instructions and its ordinary main.
Each unchanged owned input and the original schema1 host-construction proxy
keeps independent +3% allocation and normal min3 instruction ceilings.
Historical focused passes do not establish current acceptance. Qualified heads
reuse exported constructor identities and existing flat-field checking;
constructor groups and broader source-pattern rewrites remain separate.

The historical six-site first-order source pilot is not an active bootstrap
requirement. Its plan and source-growth forecasts remain available in Git.

The historical source proposal piloted successive matches for 236 nested-test
arm headers, and length/get/equality replacements for list/String patterns. Do not duplicate
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

**Status.** Structural matching is implemented in the combined candidate;
current integration and resource acceptance remain pending. The qualified-head
report and source-removal forecasts above retain their original boundaries.

## M3: loops and tail recursion

The historical implementation began with scalar representation preparation,
then managed String while. Neither slice alone establishes the broader exit
proof below; the current loop contract is in [README.md](README.md).

**Goal.** Managed List/while loops, with one explicit edge/ownership mechanism.
Retain existing scalar `@tail_recursive` behavior; broader managed/generic tail-
call optimization is not a bootstrap prerequisite. Rewrite the source's flat
managed walks into loops. **Scope.** A loop is a statement with a carried-binding set and
two exits:

```
CheckedStatement.Loop(carried: List[BindingId], body)   -- body exits: Break | RecurWith
```

The checker publishes enclosing mutable bindings reassigned in the body,
excluding iteration locals. Lower adds a private for cursor. List iterables and
ascending, end-exclusive Int range bounds evaluate once before iteration.
While conditions run at the header. Break/continue resolve to the nearest loop;
continue advances a for cursor. General Range values and descending iteration
remain deferred. The earlier six-range source census is historical inventory.

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
borrowed parameters and never retires the caller's obligation. A header instead
takes an owned initial's obligation when the loop step is that owner's last use,
the owner holds the initial and backs no other header initial or body read
([L2b](#l2b-transfer-ownership-into-joins-and-loop-entry)); a join likewise
takes the obligations last used there, which each yielding arm discharges
exactly once. Each managed
parameter occurrence carries its own obligation, including duplicate aliases.
On the back edge: evaluate the next values, acquire or transfer next owners,
retire the old obligations, rebind and jump; no pending cleanup follows the back
edge. Base returns transfer the result and discharge remaining owners.
Supported scalar annotated functions lower to the same runtime Loop. Checked
and concrete `FunctionExecution`/`SelfTailLoop` facts remain for annotation
admission; Lower removes that distinction from runtime control, preserving
current accepted/rejected cases. A back
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
malformed-IR negatives; one runtime Loop with existing scalar TCO preserved and checked/concrete
annotation facts retained.

**Status.** Common source while/for, managed headers and lexical loop transfers
are implemented in integration; acceptance remains pending. Managed and generic
annotated tail recursion remain deferred.

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
Specialize projects the accepted underlying type before forming runtime keys,
so equal representations may share instances and the concrete `TypeRef` has no
opaque variant. Ordinary declaration identities and resolved callback choices
remain authoritative. The [ordinary opaque types plan](https://github.com/kablorp/blorp/blob/1e07c4dce85e51cd7ad911142e9bc96a5e0d91c7/benchmarks/results/blorp_2_opaque_types_2026-10-18.md)
is implemented without SemanticRef/key preparation or backend/runtime changes;
the [validation report](https://github.com/kablorp/blorp/blob/1e07c4dce85e51cd7ad911142e9bc96a5e0d91c7/benchmarks/results/blorp_2_opaque_types_2026-10-18.md)
records current-base acceptance and its limits. After restoring host-compatible
List update names, the actual source probe stops at the missing public
`list.contains` export in `verify/verify.brp:8:8`, before complete source checking.

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
[unary recursion report](https://github.com/kablorp/blorp/blob/1e07c4dce85e51cd7ad911142e9bc96a5e0d91c7/benchmarks/results/blorp_2_recursive_unary_2026-10-15.md).

**Status.** Step 1 done. Step 2a done: non-generic recursion through record
fields and `List` elements, released by recursive helpers; see the
[recursive group report](https://github.com/kablorp/blorp/blob/1e07c4dce85e51cd7ad911142e9bc96a5e0d91c7/benchmarks/results/blorp_2_recursive_mixed_2026-10-15.md).
Ordinary opaque semantics are implemented. Bootstrap remaining: actual
source-product depth acceptance. Union-only cycles (2b) and own-parameter recursion (2c) are deferred
language extensions with no current bootstrap witness.

## M6: library and shell

**Status.** Reviewed acceptance of matching host/target `string.byte_at` and
`string.from_codepoint` interfaces. Target phase/native ownership tests, six mutations,
the full 456-case e2e gate and 3,640 matched cost calls pass hard ceilings.
The [API report](https://github.com/kablorp/blorp/blob/1e07c4dce85e51cd7ad911142e9bc96a5e0d91c7/benchmarks/results/blorp_2_string_integer_apis_2026-10-16.md)
retains all 105 allocation misses of the +5% target (maximum +5.62%); normal
instructions stay within +5%. Implementation, cost and documentation reviews are
complete.
Source Char and ASCII classification migration is complete in `abd0aa1a0`:
all 39 compiler modules reconcile to fresh pre-DCE facts, with 3,109 component
checks and 461 e2e fixtures passing. The [migration report](https://github.com/kablorp/blorp/blob/1e07c4dce85e51cd7ad911142e9bc96a5e0d91c7/benchmarks/results/blorp_2_source_byte_lazy_screen_2026-10-17.md)
preserves the failed historical cost screen and the separately reviewed fixed-A/D
acceptance. Slicing, remaining library and shell/path work still leave M6 open.

The standalone [target current-directory Result slice](https://github.com/kablorp/blorp/blob/1e07c4dce85e51cd7ad911142e9bc96a5e0d91c7/benchmarks/results/blorp_2_target_current_directory_2026-10-17.md)
is implemented and validated: ordinary owning Result, phase/native tests, six
effective/restored mutations and all 483 logical cost cases meet their gates.
The [cost report](https://github.com/kablorp/blorp/blob/1e07c4dce85e51cd7ad911142e9bc96a5e0d91c7/benchmarks/results/blorp_2_target_current_directory_2026-10-17.md)
records host proxy allocation/instruction ceilings passing under the explicit
host-only bootstrap leak exception; both host strict memory observations remain
failed. No pilot/native memory exception applies. Compiler loader migration and
all broader M6 shell/library integration retain the dependency order above;
this accepted bounded witness establishes no self-compilation or M6 completion.

[Target file reading](https://github.com/kablorp/blorp/blob/1e07c4dce85e51cd7ad911142e9bc96a5e0d91c7/benchmarks/results/blorp_2_target_file_read_2026-10-17.md) is implemented and validated with phase/native,
mutation, full-suite and matched-cost gates; [evidence](https://github.com/kablorp/blorp/blob/1e07c4dce85e51cd7ad911142e9bc96a5e0d91c7/benchmarks/results/blorp_2_target_file_read_2026-10-17.md)
retains failed host strict checks. Destination e2e passed; loader migration remains pending.

The bounded [target file-writing slice](https://github.com/kablorp/blorp/blob/1e07c4dce85e51cd7ad911142e9bc96a5e0d91c7/benchmarks/results/blorp_2_target_write_file_2026-10-18.md) implements
ordinary `Result[Void, String]` with two borrowed Strings. Its phase/native, full
functional and matched FEATURE cost gates pass; [evidence](https://github.com/kablorp/blorp/blob/1e07c4dce85e51cd7ad911142e9bc96a5e0d91c7/benchmarks/results/blorp_2_target_write_file_2026-10-18.md)
retains the failed supporting-host strict checks. Main/loader migration remains
a separate gate. This does not complete M6.

The ordinary [String integer-appending wrapper](README.md#counted-string-operations)
is implemented over accepted formatting and concat. Its fixtures preserve signed
extrema, UTF-8/NUL bytes and aliases; self-compilation remains a separate gate.

The [target API reference](standard_library/README.md) documents the implemented
Option/Result helpers, including four callback helpers.
Lambdas/captures and explicit compiler-source operation imports are implemented
in the combined candidate; source-frontier and resource acceptance remain pending.
This library increment does not close those consumers. The prelude stays unchanged.
The superseded five-helper proposal is recoverable from Git.

Loader/shell integration uses fallible CWD and explicit stderr. Source review
and [cost acceptance](#cost-and-evidence-rules) remain separate from library
acceptance; historical R0 failures stay recorded.

**Goal.** The real compiler source loads and checks against the real temporary
library, with no remaining required parity row missing. Use the reduced resolved
dependency inventory, including retained callbacks, not the historical parity counts.

**Scope.** Existing Int/Float/String/List representation and machine operations;
remaining first-order numeric comparisons/classification; ordinary Option/Result
helpers; byte-exact String operations; and the shell/path surface below. Implemented
`string.byte_at -> Option[Int]` and `string.from_codepoint -> Option[String]`
avoid target Char/Bytes. Strings contain valid UTF-8; byte observation retains
byte coordinates, and scalar encoding validates before narrowing.
[`string.slice`](README.md#counted-string-operations) checks half-open byte
bounds and scalar boundaries; Some[String] carries ordinary owning payloads.

Write ordinary helpers in Blorp where the reduced subset and measured cost allow.
Do not reconstruct raw substring bytes through scalar encoding. `starts_with`
can compare counted bytes without per-position substring allocation. Remove
Unicode case mapping or search from the prerequisite set only after the parser's
actual ASCII-classification calls disappear. Large String concatenation/join
uses the ordinary [List[String].join helper](standard_library/README.md), whose
copying and stack costs are explicit. No native join primitive, generic builder
or M6 completion follows from that helper alone.

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
as documented in the [target API reference](standard_library/README.md). No
host trait enters target code.

- **Current directory:** owned, nonempty absolute path on success; useful Err
  otherwise. Grow storage as required by the OS; no fixed buffer or empty failure
  sentinel. Query once before loader identities. Failure uses the real compiler
  SourceId and an empty source inventory, not a fabricated module/file row.
  Validate native encoding before String publication; invalid UTF-8 returns Err.
- **Read:** target adapter/native contract and integrated loader use implemented;
  full compiler acceptance pending.
  Preserve valid UTF-8 contents exactly, including CRLF, BOM and NUL.
  Target encoding help omits the host read_bytes suggestion because that API
  is unavailable; both reject malformed UTF-8 before String publication.
  Malformed UTF-8 returns Err before publishing contents as a String. The native
  file-admission tests pin its diagnostic and priority. Preserve malformed-input
  coverage here.
  Reject NUL in a path before opening. Missing/unreadable input, incomplete reads
  and close failure return Err; clean up every opened handle. This increment
  needs stable source files, not arbitrary streams or concurrent snapshots.
- **Write:** implemented and validated; the
  [acceptance report](https://github.com/kablorp/blorp/blob/1e07c4dce85e51cd7ad911142e9bc96a5e0d91c7/benchmarks/results/blorp_2_target_write_file_2026-10-18.md)
  retains the contracts and evidence.
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
  The [target stderr implementation](https://github.com/kablorp/blorp/blob/1e07c4dce85e51cd7ad911142e9bc96a5e0d91c7/benchmarks/results/blorp_2_print_error_2026-10-18.md) is validated;
  the integrated compiler shell uses this target API; whole-compiler acceptance
  remains pending.
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
operations. The host `get_current_directory` API is implemented and validated.
Target wiring and source shell/path integration are implemented in the combined
candidate; current composition, host provenance and fixpoint acceptance remain separate.
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

**Historical pre-stored-callable checkpoint.** Pure callback types, named
references, forwarding, pure lambdas and immutable data captures were implemented.
Mutable/callable captures, callable storage/returns and runtime-selected callbacks
were unsupported at that checkpoint. The owner stopped the remaining
callback-removal migration on 2026-10-19. The
[language reference](README.md#grammar-for-this-increment) owns the current
callable contract, including stored values and immutable callable captures; the
[stored-callable acceptance report](https://github.com/kablorp/blorp/blob/1e07c4dce85e51cd7ad911142e9bc96a5e0d91c7/benchmarks/results/blorp2_stored_callables_2026-10-21.md)
records validation and measured cost limits. The
[target API reference](standard_library/README.md) records callback helpers.
The source-removal work below is retained history.

**Historical bootstrap decision.** Migrate the current 53 pure lambda literals, 64
higher-order calls and one function-typed helper parameter to first-order source
under the bounded source plan. Retire this dependency only after sorting,
translation/source-growth pilots and the complete resolved inventory pass.
No stored/returned closure was found in the reviewed current source. Broader
language function values remain future work; existing parser/rejection behavior
is preserved.

The abandoned callback-removal estimates grant no implementation allowance.
Any future source slice follows the [fixed-baseline cost policy](#cost-and-evidence-rules);
retain historical R0 failures and cumulative trends without automatic baseline
changes after failure.

The bounded [three-site type-argument translation](https://github.com/kablorp/blorp/blob/1e07c4dce85e51cd7ad911142e9bc96a5e0d91c7/benchmarks/results/blorp_2_first_order_type_arguments_2026-10-18.md)
is implemented and validated: [3,920 matched calls](https://github.com/kablorp/blorp/blob/1e07c4dce85e51cd7ad911142e9bc96a5e0d91c7/benchmarks/results/blorp_2_first_order_type_arguments_2026-10-18.md)
pass the +3% per-input and original-checkpoint-proxy limits. Historical R0
compliance remains UNVERIFIED; eight callbacks and the broader M7 dependency remain.

The historical stable-layout-ordering and six-site constant-fill proposals
belong to the stopped callback-removal campaign. They are retained in Git, not
active bootstrap prerequisites or grants for further implementation.

**Retained design sketch.** Lambdas at known callees, including managed captures.
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

**Required language exit proof.** Fixtures for a capturing and a non-capturing lambda at a library
combinator and at a user generic; ownership of borrowed managed captures
verified; frontier reaches emit.

**Historical pre-stored-callable acceptance status.** Pure callback types, named
references, callable parameter forwarding, direct-call specialization, lambdas
and immutable capture specialization were implemented in the combined candidate;
integrated correctness, resource and self-compilation acceptance were still
separate obligations. For current behavior and the later acceptance evidence,
use [README.md](README.md#grammar-for-this-increment) and the
[stored-callable report](https://github.com/kablorp/blorp/blob/1e07c4dce85e51cd7ad911142e9bc96a5e0d91c7/benchmarks/results/blorp2_stored_callables_2026-10-21.md).
Historical resource failures retain their original verdicts.

## M8: the fixpoint gate

**Goal.** The definition of done. **Scope.** `scripts/blorp2-fixpoint` exits 0:
B == C, A == B on every fixture, e2e under B, all at `-O0`. Measure the
self-compile cost row (allocations and instructions per phase) under
always-fresh `append`; if quadratic, unique-root reuse is the first post-fixpoint
optimization candidate for M9 to assess before implementation.
**Decision (harness).** The e2e harness has no closure values: tests
are dispatched by name. It does not add a lambda prerequisite to bootstrap.
The `BLORP2_COMPILER` harness is expected to
be rewritten once blorp_2 is mature. The unit-test migration is a separate plan.

**Exit proof.** The fixpoint script exits 0.

**Status.** In progress. The compiler accepts all 43 of its own source modules,
emits C that links without warnings, and the resulting compiler emits
byte-identical C from the same source and library. The [self-compilation
report](https://github.com/kablorp/blorp/blob/1e07c4dce85e51cd7ad911142e9bc96a5e0d91c7/benchmarks/results/blorp_2_self_compiled_bootstrap_2026-10-20.md)
records the exact inputs and matched `-O0` execution cost. Host-backed component
validation passes 4,174 checks. All 556 maintained fixture files agree under A/B;
the self-built compiler passes all 559 e2e functional callbacks under the explicit
initial-bootstrap cost-debt policy. Whole-source `-O0` ASan/UBSan compilation reproduces the same C and balances
27,373,418 allocations/releases with no tracked leaks after replacing flat
declaration recursion with an ordinary source loop. The final native run also
passes from a fresh working directory. The verified three-platform seed is pinned and the default B2 build uses it.
Legacy TestSuite hosting remains separate. The remaining cost obligations above
are still pending; this checkpoint does
not mark the complete M8 resource gate green.

The [runtime accounting preparation](https://github.com/kablorp/blorp/blob/1e07c4dce85e51cd7ad911142e9bc96a5e0d91c7/benchmarks/results/blorp_2_pilot_memory_accounting_2026-10-18.md)
has passed its bounded runtime and matched host-proxy gates
([evidence](https://github.com/kablorp/blorp/blob/1e07c4dce85e51cd7ad911142e9bc96a5e0d91c7/benchmarks/results/blorp_2_pilot_memory_accounting_2026-10-18.md)).
Those historical pilot counts do not by themselves establish target-built strict
self-compilation; the current proof is recorded above. Matched mode 0/mode 1
target allocator overhead remains M8 work.

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
  retired instructions per frozen input. Remaining SOURCE migrations follow the
  fixed-baseline policy:
  root names accepted B and complete C before setup; each owned input and the
  original construction-checkpoint proxy must independently pass +3% allocations
  and normal min3 instructions. Historical R0 failures and cumulative trends
  remain recorded; no baseline rolls after failure. A required native-host
  transition is measured separately and both sources are rebuilt under one
  frozen measurement epoch. The historical layout sorter still records
  10,166 allocations against its 9,923 threshold (R0 9,634), despite a local
  12-allocation reduction. A later accepted slice does not relabel that failure.
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
[reviewed fixed-current contract](https://github.com/kablorp/blorp/blob/1e07c4dce85e51cd7ad911142e9bc96a5e0d91c7/benchmarks/results/blorp_2_carried_bindings_2026-10-18.md)
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

Allocation reuse beyond unique-owner String and List buffers (record and union
cell reuse is [O3](#o3-cell-reuse-for-records-and-union-nodes), pending its
measurement), retain elimination, List removal, Set/Dict
key semantics (storing a type does not make it a key), mutual tail calls,
tail-modulo-constructor, closure escape and closure values, and the unit-test
migration plan. When reuse is introduced, its enabled and always-fresh paths must
agree on observable values and safe destruction.

`utils/int_map.brp` is a stopgap Int-keyed map for compiler tables; once Blorp
has a dict implementation it is deleted and its users move to it.

Historical measurements also identify repeated generic-recursion reachability,
linear specialization-instance lookup inside repeated requests, module-path
comparisons and growing String construction as scaling candidates. Retain
complete instance keys and diagnostic order; any graph/index/builder change needs
its own current matched measurement and reviewed scope. Old timings and source
counts do not describe current main. Flat managed recursion and actual product
destruction margins remain explicit M3/M4/M8 obligations, not cleanup work.

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
[host temporary-projection repair](https://github.com/kablorp/blorp/blob/1e07c4dce85e51cd7ad911142e9bc96a5e0d91c7/benchmarks/results/compiler_nested_temporary_projection_2026-10-11.md);
passing pilot checks do not imply an incomplete broader host gate passed.
Old slice-specific thresholds and counts are historical evidence, not current
budgets.
