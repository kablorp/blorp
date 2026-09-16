# Compiler Speed Roadmap

Goal: compile `blorp/src/main.brp` to C in about 10 seconds on the reference
machine, without lowering the maintainability bar. This document turns the
2026-09-16 self-compile profile into tasks that are cheap and mostly
mechanical to execute, in parallel where file ownership allows.

Measured starting point after the first round (issues 147-151), -O2, frozen
input, from `benchmarks/results/self_compile_baseline_O2_2026-09-16_r2.json`:
267.2G retired instructions, 272.6M allocations, 2.82GB peak RSS, about
23-25s wall on a quiet machine. Phase shares before the round were late Core
39%, typed frontend 19%, early Core 18%, backend 12%, discovery 7%,
lowering 7%, runtime projection 3%.

## How To Work A Task

Every task below follows the same contract. Read this once; each task only
states what differs.

**Measurement.** Use `benchmarks/self_compile_measure` exactly as described in
[the protocol](../benchmarks/README.md#self-compile-measurement-protocol).
Baselines are the newest `self_compile_*_baseline_*.json` files (r3 as of this writing); the input revision is in the
JSON. Run both `--program self` and `--program small` with
`--require-identical` unless the task says the C may change. Primary metrics
are retired instructions and per-phase allocations; wall time is confirmation
only. Iterate at `-O0`; the coordinator confirms at `-O2`.

**Fast loop.** `make && scripts/compiler-build-status` (about 45s), the
task's focused suite (seconds), then one harness run (about 40s at -O0).
Never argue from a run made while another gate or build is active on the
machine; the harness lock serializes only harness runs and locked gates.

**Gates before handoff.** Focused suites named in the task,
`benchmarks/self_compile_measure lock -- scripts/compiler-check --changed --base main`,
`bin/blorp format --check --diff <changed files>`, `git diff --check`. The
coordinator runs the default `scripts/test` gate and the ownership gates
(`compiler-core-sanitize`, `leak`) after merge. Never run multi-process gates
concurrently (macOS `syspolicyd` stalls).

**Debugging.** `bin/blorp compile --dump-core-after=<stage> --dump-core-file=<path>`
gives a Core snapshot before and after a pass; diff two snapshots to localize
a semantic change. `--check-invariants` runs the full invariant set. For
"which function got slower", build a calls or exact profile of the compiler
compiling the frozen input:

```bash
boot=$(scripts/blorp-compiler-bootstrap --print-path)
input=$(benchmarks/self_compile_measure freeze --rev <input_rev>)
$boot compile --profile-mode exact --profile-module blorp/src/compiler/stage_09_core/perceus \
  --std-dir standard_library/src --no-format -o /tmp/prof.c blorp/src/main.brp
cc -O0 -fwrapv -pipe -w -DBLORP_COMPILER_RUNTIME_SOURCES=1 \
  -Iblorp/src/compiler/stage_01_generated_inputs -Iblorp/src/compiler/stage_04_modules \
  -Iblorp/src/compiler/stage_06_typecheck/graph -Iblorp/src/compiler/stage_06_typecheck/type_system \
  -Iblorp/src -Iblorp/src/lib -Iblorp/src/lsp/server -Iblorp/src/test \
  /tmp/prof.c blorp/build/_build/blorp-cli/runtime_sources.c \
  blorp/src/lsp/server/native_runtime.c -lm -lpthread -o /tmp/blorp-prof
/tmp/blorp-prof compile --no-format --no-embed-runtime \
  --std-dir $input/standard_library/src -o /tmp/x.c $input/blorp/src/main.brp 2> /tmp/prof.txt
```

Omit `--profile-module` for the whole compiler (about 5 minutes). The report
has `=== Function Profile ===` rows (self time, calls) and `FLAME:` rows.

**Quality bar.** One change per commit, named after the cut. A protecting test
first. Grouped arm functions rather than one giant match when adding locals
to an 89-arm match (issue 147 overflowed the default 8MB stack at -O0 before
splitting). Delete the code a change replaces; no parallel authorities, no
caches without a lifetime, no heuristics keyed on names.

**Reporting.** Branch and final commit, per-cut summary, harness tables for
self and small verbatim, suite counts, compiler-check result, anything
rejected with numbers, open questions. Workers stop with
`QUESTION FOR COORDINATOR:` when a task's Decision clause triggers.

## Parallelism Map

Tasks in different rows own disjoint files and can run at the same time.
Tasks in the same row are sequential.

| Row | Tasks | Files owned |
| --- | --- | --- |
| 1 | P1 then P2 | `stage_09_core/pipeline.brp`, `pipeline_stage.brp`, `early_pipeline.brp`, `early_stages.brp`, `stage_manifest.brp`, `compiler/pipeline.brp` (late-core section), `lib/compile_plan_execute.brp` |
| 2 | C3 (C1 and C2 landed) | `stage_09_core/prepare.brp`, `closure.brp`, then `resource_management.brp`, `fairness.brp`, `tuple_sroa.brp` |
| 3 | C4 | `stage_09_core/dce.brp` (entry point only), `early_pipeline.brp` (one call; coordinate with P1) |
| 4 | O2 then O3 (O1 landed) | `stage_09_core/perceus.brp` |
| 5 | F1 then F2 | `stage_06_typecheck/decl.brp` body loop, `bridge.brp`, typecheck metrics |
| 6 | B1 then B2 | `stage_10_backend/emit.brp`, `cancellation_plan.brp` |
| 7 | D1 | `stage_02_lex/*`, `lib/source.brp`, `stage_03_parse/language_parser.brp` |
| 8 | R1 | `stage_09_core/perceus.brp` drop placement probe (read-only until scoped), runtime tests |

Two tasks that both touch `perceus.brp` (O-row and R1) must not run at once.
C4 touches `early_pipeline.brp`; land it before P1 or rebase onto P1.

---

## Track P: Pipeline Structure And Per-Pass Measurement

### P1. Make the pass pipeline a list and time every pass

**Context.** Late Core is a 14-variant `CorePipelineStage` enum whose
`run_core_pipeline_stage` re-lists the pass chain for every variant, and
`execute_late_core_stages` re-runs the whole prefix from the pre-DCE program
for each requested dump or stop stage. Early Core is a separate mechanism of
nested `match finish_stage(...)` chains. Neither exposes per-pass timing or
allocation deltas; the only measurement is the seven coarse phase rows, so
answering "which pass regressed" required a five-minute instrumented build
throughout the first round. There are about 40 whole-program passes.

**Code today** (`blorp/src/compiler/stage_09_core/pipeline.brp`):

```blorp
pure func run_core_pipeline_stage(stage: CorePipelineStage, program: CoreProgram) -> CoreProgram:
	match stage:
		PostPerceusTailStage:
			run_post_perceus_tail(run_perceus_stage(run_projected_dce_stage(program)))
		PreClosureTailStage:
			run_pre_closure_tail(
				run_reuse_stage(run_perceus_stage(run_projected_dce_stage(program))),
			)
		...
```

**Change.** One ordered list of named passes owned by `stage_09_core/pipeline.brp`
and one runner:

```blorp
record CorePass {
	name: String,                      -- "perceus", "reuse", "closure", ...
	run: pure (CoreProgram) -> CoreProgram,
	invariant: pure (CoreProgram) -> Option[String]   -- fast checks that run in production
}

pure func late_core_passes() -> List[CorePass]:
	[
		{ name = "adapt_function_refs", run = CoreClosure.adapt_function_refs_program, invariant = no_invariant },
		{ name = "tensor_specialize", run = CoreTensorSpecialize.specialize_program, invariant = no_invariant },
		{ name = "specialize", run = CoreSpecialize.specialize_program, invariant = no_invariant },
		{ name = "resolve_callables", run = CoreResolve.resolve_callable_id_calls, invariant = no_invariant },
		...
		{ name = "perceus", run = CorePerceus.insert_drops_program, invariant = perceus_invariant },
		...
	]

record CorePassObservation {
	name: String,
	elapsed_microseconds: Int,
	allocations_before: Int,
	allocations_after: Int
}

func run_core_passes(
	passes: List[CorePass],
	program: CoreProgram,
	control: CorePassControl,        -- stop_after, dump_after, check_invariants, record_timings
) -> CorePassRun
```

The runner walks the list once, records elapsed time and allocation counters
per pass (reuse the runtime's lightweight allocation counter exposed by
`record_compile_memory_checkpoint`), renders a snapshot only for a pass that
is in `dump_after`, stops after `stop_after`, and runs the fast production
invariant after each pass. `--time-phases` gains one row per pass under the
phase row (indented, so existing consumers of the seven phase rows keep
working); the harness already parses arbitrary labelled rows.

**Strategy.**
1. Write the runner and the observation record with a test that runs three
   trivial passes and asserts order, stop-after, dump-after, and timing rows.
2. Move the early pipeline onto it first (it has the simpler contract:
   lower, debug, desugar+ssa, mono, synth, match, trait_resolve, resolve,
   std_inline, tailrec, fusion set, tuple_sroa). Keep `CoreEarlyPipelineStage`
   as the public dump/stop name enum by mapping names to list entries.
3. Move the late pipeline. Delete `run_core_pipeline_stage`'s chain
   duplication and `execute_late_core_stages`' prefix replay; keep
   `CorePipelineStage` names as aliases for pass names.
4. Keep the production invariants that run today after resolve, std_inline,
   tailrec, and fusion as `invariant` entries so behavior is unchanged; P2
   decides their fate with numbers.
5. Print per-pass rows under `--time-phases` and expose them through the
   memory-checkpoint labels (`pass_<name>_complete`) so the harness reports
   per-pass allocations without changes.

**Fast loop.** `bin/blorp test --timeout 180 blorp/test/compiler/stage_09_core/test_core_pipeline.brp`
and `blorp/test/compiler/pipeline/test_cli_late_core.brp`; then
`bin/blorp compile --time-phases --dump-core-after=perceus --stop-after=reuse`
on a small file to confirm dump and stop still work.

**Debugging.** Compare `--dump-core-after=<stage>` snapshots before and after
the refactor for every stage name; they must be byte-identical.

**Acceptance.** Generated C identical on self and small; every dump/stop
stage name still accepted with identical snapshots; `--time-phases` shows one
row per pass; the harness reports per-pass allocations; instructions not up
(expect a small win from deleting the prefix replay and JSON rendering only
under dump). Suites: Core pipeline, CLI late-core, `scripts/test cli`.

### P2. Gate production invariant walks

**Context.** `finish_stage` in `early_pipeline.brp` runs
`check_resolve_invariants` four times and `check_std_inline_invariants` three
times on every compile even without `--check-invariants`, about 0.3s at -O2
and a full read walk of the program each time.

**Change.** After P1, each pass's `invariant` entry is either the fast
identity check (`check_definition_id_uniqueness`, milliseconds) or nothing;
the full walks move under `--check-invariants`. If a walk protects a real
production failure mode, replace it with an O(1) fact recorded by the pass
that established it (for example the resolve pass returning a
`CoreResolvedProgram` opaque type that later passes require, so "unresolved
survived" is a type error rather than a walk).

**Acceptance.** Identical C; `--check-invariants` still runs all walks; early
Core instructions down by the measured walk cost; Core suites green.

---

## Track C: Core Allocation

Every pass that rebuilds a node it did not change allocates for nothing.
Issue 147 made the shared traversal reuse unchanged nodes; these tasks apply
the same rule to the passes that bypass it. The mechanical pattern is:

```blorp
-- before
BinaryExpr(op, left, right, typ, loc):
	BinaryExpr(op, rewrite(left), rewrite(right), typ, loc)

-- after
BinaryExpr(op, left, right, typ, loc):
	mapped_left: CoreExpr = rewrite(left)
	mapped_right: CoreExpr = rewrite(right)
	if same_core_expr(mapped_left, left) and same_core_expr(mapped_right, right):
		expr
	else:
		BinaryExpr(op, mapped_left, mapped_right, typ, loc)
```

`same_core_expr`/`same_core_type` are the foreign declarations in
`traverse.brp` bound to `blorp_same_object`; move them to a small shared
module (`stage_09_core/node_identity.brp`) in the first task that needs them
outside `traverse.brp`. Lists use the prefix-copy-on-first-change helper
already in `traverse.brp` (`map_context_exprs`); export it.

### C1. `prepare_expr` reuse (landed 2026-09-16, `4741dce9`)

**Context.** `stage_09_core/prepare.brp` `prepare_expr` has 89 arms, 2 of
which return the input; it also deep-copies payloads through 37 `clone_core_*`
calls; `prepare_program` runs twice per compile. Late Core still allocates
about 116M objects per self-compile after 147.

**Strategy.** Apply the pattern arm by arm, grouped into arm functions
(`prepare_leaf_expr`, `prepare_operator_expr`, ...) behind a binding-free
dispatcher. Replace `clone_core_*` calls with sharing where the callee does
not mutate. Add a `test_core_prepare.brp` case asserting an already-prepared
program comes back with identical top-level function bodies (pointer
identity through `same_core_expr` on the body).

**Acceptance.** Identical C; late_core allocations down at least 10% from the
r2 baseline; small program not up; prepare and Perceus suites green.

### C2. Closure conversion reuse (landed 2026-09-16, `4741dce9`)

**Context.** `stage_09_core/closure.brp` `convert_non_spine_expr` (about
1,100 lines, 89 arms) threads `ClosureState` and rebuilds every node; both
`adapt_function_refs_program` and `convert_program` run it.

**Strategy.** Same pattern. `ClosureState` results stay as they are; only the
returned node is reused when no child and no state-derived field changed.
Add a test that converts a closure-free function and asserts body identity.

**Acceptance.** As C1, measured on the two closure passes.

### C3. Resource, fairness, and tuple SROA reuse

**Context.** `resource_management.brp` `rewrite_resource_expr_with_cleanups`
(89 arms), `fairness.brp` `insert_cooperative_checkpoints_expr` (89 arms, 10
identity arms), `tuple_sroa.brp` `rewrite_tuple_sroa_expr_from` (65 arms).
Fairness and resource touch only loops and resource scopes; tuple SROA only
tuple-bearing code. Each currently reallocates the whole program.

**Strategy.** Same pattern, three separate commits. For fairness and
resource, most arms become "map children, reuse if unchanged" and can route
through `map_core_expr_children` directly, deleting the hand-rolled arms
where the pass has no special handling.

**Acceptance.** Identical C; each pass's allocation delta (visible per pass
after P1, otherwise as late_core and runtime_projection deltas) at least
50% down for that pass; suites for the three passes green.

### C4. Prune unreachable declarations before early Core

**Context.** DCE runs after specialization in late Core. A two-function
program lowers 2,054 functions (the whole embedded standard library) and
keeps 20; the self-compile carries about 19.3k declarations through roughly
15 early passes and keeps 16.5k. Monomorphization already instantiates only
demanded generics, so the dead weight is non-generic standard-library
functions, and every early pass walks them. This is the largest lever for
small programs (the test suite compiles thousands of them) and worth about
15% of early-Core work on the self-compile.

**Code today.** `stage_09_core/dce.brp` `prune_program` keys reachability on
function `def_id`, function names, constructor names, global names, and type
names, all of which exist immediately after lowering (`core_module_member_name`
mangles names uniquely; `def_id` is assigned at lowering).

**Change.** Run `prune_program` once immediately after the lower stage
(before debug/desugar) in addition to the existing late run. Nothing else
changes; the late run still removes what specialization made dead.

**Strategy.**
1. Probe first: add the early call behind a temporary flag, compile the
   frozen input and the small program, and diff the generated C against the
   baseline. If identical, proceed. If not, the diff shows which root DCE
   missed at that stage (likely a trait implementation or a name-resolved
   call that is only exact after `resolve`); extend `collect_roots` for that
   category and re-probe. Do not weaken `fail_closed`.
2. Land the early call under P1's pass list as `prune_early` (or as one line
   in `run_early_core_pipeline` if P1 has not landed; coordinate).
3. Add a test with an unused standard-library-style helper asserting the
   post-lower declaration count drops and the late DCE result is unchanged.

**Fast loop.** `bin/blorp compile --dump-core-after=lower --dump-core-file=/tmp/a.txt`
before and after, counting `"kind":"function"` entries; then the harness.

**Acceptance.** Identical C on self and small; small program early_core and
core_lowering-adjacent allocations down by an order of magnitude;
self-compile early_core instructions down at least 10%; `scripts/test`
runtime and compiler gates green (they compile thousands of small programs).

**Decision.** If the C differs and the missing root is a category DCE cannot
see before `resolve`, ask before moving the early prune later than desugar.

---

## Track O: Perceus

### O1. `contract_for_call` (landed 2026-09-16, `8660e6b1`)

**Context.** After 148, `contract_for_call` is about 21% of Perceus self time
(2.66M calls, ~0.8 µs each). It resolves an ownership contract per call site
from name, def_id, arity, and return type through several dictionaries.

**Strategy.** Attribute per-call work with an exact profile limited to the
Perceus module, then precompute the contract per callable identity once per
`insert_drops_program` (the env already owns `user_call_contracts_by_callable_id`)
so the per-call path is one exact-ID lookup.

**Acceptance.** Identical C; Perceus self time for that function down at
least 50%; late_core instructions down; Perceus, leak, and sanitizer suites
green.

### O2. Remaining speculative summaries

**Context.** Two sites still summarize before knowing whether the result is
read (`perceus.brp`):

```blorp
private pure func summarize_repeated_body_uses(...):
	body_uses = summarize_linear_ownership_uses(env, name, body)
	if body_uses.consumed_refs > 0:
		ownership_uses_from_legacy_count(count_uses(name, whole_expr))   -- second full walk
	else:
		seq_ownership_uses(prefix_uses, ...)

private pure func rewrite_non_match_direct_mutable_assignment_with_uses(...):
	match rhs:
		IfExpr(cond, then_expr, else_expr, ...):
			cond_uses = summarize_linear_ownership_uses(env, target.name, cond)
			then_uses = summarize_linear_ownership_uses(env, target.name, then_expr)
			else_uses = summarize_linear_ownership_uses(env, target.name, else_expr)
			if not skip_old_release and cond_uses.consumed_refs == 0 and then_uses... :
```

**Change.** In the first, fold the count the legacy path needs into the
summary walk (extend `OwnershipUseSummary` only if the count is not already
derivable from `required_refs + consumed_refs`; prove equivalence with a
test on a body that consumes and borrows the same name). In the second, test
`skip_old_release` first and summarize the three parts only inside that
branch, duplicating the fallback call into an `else` (the worker on 148
declined this because the nine-argument fallback would be written twice;
factor the fallback into a local helper instead).

**Acceptance.** Identical C; `summarize_linear_ownership_uses` and
`count_uses` call counts down on the self-compile; Perceus suites green.

### O3. Drop insertion walk

**Context.** `insert_drops_expr_inner_result` is the largest self-time item
in Perceus (2.8s instrumented, 650k calls, ~4.3 µs each). It is the pass's
main rewrite; `managed_let_reuses_source` already tracks when a let can be
returned unchanged.

**Strategy.** Measurement-first: count, per node kind, how many nodes the
walk rebuilds versus returns unchanged (temporary counters). Extend the
existing `reuses_source` discipline to the node kinds that dominate rebuilds
without an ownership change, using `same_core_expr` on children. Do not touch
the ordering of `DupExpr`/`DropExpr` insertion.

**Acceptance.** Identical C; late_core allocations down at least 5%; leak and
sanitizer gates green.

---

## Track F: Typed Frontend

### F1. Per-body cost attribution

**Context.** The typed frontend is about 4.3s and 45M allocations and no
first-round task touched it. Its cost is diffuse in the function profile
(inference 3.6%, semantic types 1.7%, definition index 1.2%, module view
1.1%, environment 0.9%). The one structural fact is that every body of every
module, including all 2,315 standard-library functions, is checked on every
compile in `check_complete_body_table_in_order`.

**Change.** Add opt-in per-body metrics to the existing typecheck metrics:
for each checked body, elapsed microseconds, allocations, node count, and
whether the body belongs to a dependency module. Print them under an
environment variable (`BLORP_TYPECHECK_BODY_METRICS=1`) as one row per body,
sorted by cost, plus totals for project modules versus dependency modules.

**Strategy.** The body loop in `decl.brp`
(`materialize_complete_from_validated_seed`, `check_complete_body_table_in_order`)
already threads a `checked_bodies` count; extend the run record with the
per-body rows and route them to the existing metrics printer in `bridge.brp`.

**Acceptance.** Identical C; the report answers two questions for the
self-compile and the small program: what share of frontend time is
dependency-module bodies, and what the ten most expensive bodies cost. Those
numbers decide F2's scope.

### F2. Demand-driven body checking for dependency modules

**Context.** If F1 shows dependency-module bodies dominate the small
program's frontend (expected: the two-function program spends most of its
113ms typed_frontend on standard-library bodies), then bodies of dependency
modules that the program never reaches do not need checking to compile it.
Headers are accepted first, so reachability is computable from accepted call
targets. CTFE already has a demand-driven body path (`CtfeCheckedBodyGroups`),
which is the precedent.

**Change.** Add a `ReachableBodyOrder` alongside `SourceBodyOrder`: compute
the set of callables reachable from the root module's bodies through accepted
call targets and implementation methods, check exactly those bodies in source
order, and mark the rest as unchecked-in-this-compile in the outcome table.
`check` (the diagnostic command), lint, and LSP keep `SourceBodyOrder` so
users still see every diagnostic in their own project; the policy is chosen by
the pipeline request, not inside the typechecker.

**Strategy.**
1. F1 numbers first.
2. Reachability over accepted headers: seeds are the root module's callables
   and globals; edges are resolved call targets in checked bodies (this is a
   worklist: check a body, add its targets). Trait method targets add every
   implementation of the trait for the receiver types seen.
3. `CompleteBodyOutcomeTable` gains an explicit "unchecked by policy" row
   kind so Core lowering can skip those declarations (they are pruned anyway
   by C4).
4. Tests: a dependency module with a body that has a type error is accepted
   under `ReachableBodyOrder` when unreachable and rejected when reachable;
   `check` still rejects it.

**Fast loop.** Small program harness (`--program small`); the discovery and
typed_frontend rows.

**Acceptance.** Identical C on self and small (the self-compile reaches most
of its dependencies, so its win is smaller); small program typed_frontend
allocations and instructions down by more than half; `scripts/test`
compiler-blorp, runtime, cli, and lsp gates green; `check` output on a
project with a broken dependency body unchanged.

**Decision.** Ask before changing what `blorp check` reports.

---

## Track B: Backend Emission

### B1. Emit nested blocks at depth

**Context.** After 151 `indent_statements` no longer allocates per line, but
every nesting level still re-copies the entire nested body to add two
spaces, so a body copies once per enclosing brace (O(depth × size)). 76
call sites.

**Change.** Thread an indentation depth through `FunctionBodyC` construction
so statements are emitted with their final indentation and `indent_statements`
disappears. Mechanically: `emit_*` functions that produce statement text take
`indent: String` (the current prefix) and write `indent + "..."` at each
statement start; nested emitters receive `indent + "  "`.

**Strategy.** Start at `emit_function_body` and push the prefix down one
construct family at a time (if/else, while, for loops, match, blocks),
measuring after each; each step is byte-identical by construction because
the prefix is exactly what `indent_statements` would have added.

**Acceptance.** Identical C; backend_emission allocations down at least 15%
from r2 and `string.split` calls from the emitter gone; emitter suite and
codegen audit green.

### B2. Cancellation forced re-analysis

**Context.** `analyze_current_behavior_expr` visits about 1.03 nodes per
node; the 3% excess is a deliberate fail-closed second pass over
`forced_match_scrutinees` in 17 plans, one function contributing 85%.

**Change.** Cache the first analysis result for the forced scrutinee subtree
inside the plan builder (lifetime: one function's plan) so the second pass
reads it rather than re-walking. No protection decision changes.

**Acceptance.** Identical C; visit count equals node count within 0.1%;
cancellation suite green. Small; do only when someone is already in the file.

---

## Track D: Source Discovery

### D1. Token and span construction

**Context.** After 150, discovery is 1.26s and 24.9M allocations at -O2 for
416 files and 1.8M tokens; per-character scanning is gone. The remaining
cost is `SourceSpan` (a heap record with eight fields, one per token plus
one per trivia) and `Token` construction, then the parser's `current_token`
(13.5M calls) re-reading tokens by index.

**Change.** Make `SourceSpan` a `struct` (stack, copied by value, no ARC)
with the path and module name moved to the enclosing `SourceFile` (spans
index a file, they do not need to carry its path), and store `line`/`column`
as `Int` fields already present. Trivia keep their spans by value. The parser
reads `tokens.get(index)` into a local once per production instead of calling
`current_token(state)` repeatedly.

**Strategy.**
1. Measure with `--program small` and `self`: discovery allocations and
   instructions before.
2. Convert `SourceSpan` to a struct; fix the constructor sites in
   `lib/source.brp` and the lexer; every consumer that read `span.path`
   switches to the file's path (there are few; diagnostics carry the file).
3. Then reduce `current_token` calls in the hottest parser productions
   (`parse_expression`, `parse_primary`, statement dispatch) by binding the
   current token once.

**Acceptance.** Identical C; every lexer, parser, formatter, purify, lint,
and LSP fixture unchanged (`scripts/test compiler-tools lsp`); discovery
allocations down at least 40% and instructions down at least 20%.

---

## Track R: Value-Semantics Costs In The Compiler's Own Code

### R1. Record update keeps the old record alive

**Context.** Issue 149 found that `{ state | field = ... }` inside a loop
keeps the previous `state` alive until block end, so collections held by the
record have two owners and every append copies. The fix there was to keep
six locals instead of a record, which is the wrong direction for
maintainability if the pattern is common. The compiler's own passes use
record-threaded state everywhere (`LexerState`, `PerceusEnv`, closure and
SSA states, DCE facts).

**Change.** Determine whether this is a Perceus drop-placement limitation
(the old binding's drop is placed at scope end instead of after its last
use when the record is rebuilt) or a COW reuse gap (`RecordCowUpdateExpr`
exists for unique records but is not selected in this shape). Write the
minimal probe:

```blorp
record State { items: List[Int], count: Int }

func fill(n: Int) -> State:
	var state: State = { items = [], count = 0 }
	var i: Int = 0
	while i < n:
		state = { state | items = state.items.append(i), count = state.count + 1 }
		i += 1
	state
```

Measure allocations with `BLORP_ALLOCATOR_STATS=1` for n = 1k, 10k, 100k; a
quadratic curve confirms the copy. Then read the generated C for `fill` and
the post-Perceus Core (`--dump-core-after=perceus`) to see where `state`'s
old value is released.

**Strategy.** If the drop can move to just before the update (the old record
is dead once its fields are read into the update), that is a Perceus
last-use cut with a large payoff across the compiler and user programs; scope
it as a separate task with the probe as its fixture and the DCE case as its
compiler-level test (revert the six-locals workaround afterwards). If it is
a COW reuse selection gap, scope that instead.

**Acceptance for the probe task.** A written finding with the probe's
allocation curve, the relevant Core and C excerpts, and the scoped follow-up
task. No compiler change in this task.

---

## Deferred

- **ID propagation instead of strings in Core.** Real (32M `Option[Int]`
  equality calls and 10M string-list membership scans before this round),
  but a representation change across every pass; sequence after Track C so
  the two 89-arm rewrites do not collide. Pilot on `CoreVar` identity in
  Perceus and cancellation first.
- **Parallel passes.** The runtime scales to 8 threads on pure CPU work, but
  the one experiment doubled CPU time even single-threaded; understand the
  cross-thread reference-counting cost before retrying.
- **Incremental compilation.** Per-module reuse of accepted frontend facts
  keyed by content hash is the next step after the from-scratch compile is
  near 10s; F2's reachable-body table is its first ingredient.
