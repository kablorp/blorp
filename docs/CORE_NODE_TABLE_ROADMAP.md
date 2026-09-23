# Core Node Table Roadmap

Goal: stop rebuilding the Core tree once per pass. Every Core expression gets
an integer identity minted by lowering, facts about nodes live in id-keyed
tables published once on the pass state, and only a pass that genuinely
rewrites a node allocates a new one. This is the immutable-builder rule of
[`FRONTEND_FACTS_ROADMAP.md`](FRONTEND_FACTS_ROADMAP.md) applied to the Core
program itself. It is the endpoint that the late-Core pass fusions and
[`CORE_ID_MIGRATION.md`](CORE_ID_MIGRATION.md) are already walking toward.

Each step below lands on its own, is gated by a measurement taken before it
starts, and states its oracle. Read [`WORKER_CHECKLIST.md`](WORKER_CHECKLIST.md)
first; its rules (no `git stash`, foreground gates, one squash commit per task,
no parallel test binaries) apply throughout. There is no measurement lock any
more; run gates directly.

Anchors are against main at `dab2f490` (2026-09-23). Line numbers drift; grep
for the name.

Companion roadmaps that run in parallel with this one:
[`TYPE_INTERNING_ROADMAP.md`](TYPE_INTERNING_ROADMAP.md) (types and names as
ids) and [`STRUCT_PAYLOAD_ROADMAP.md`](STRUCT_PAYLOAD_ROADMAP.md) (struct
values inline in union payloads). The "Parallelism" section at the end says
which files each roadmap owns and where they meet.

## What is true today

**The IR.** All Core types and their JSON codec live in one file,
`stage_09_core/ir.brp` (15,120 lines). `CoreProgram` is `{ decls:
List[CoreDecl], foreign_includes }`; `CoreExpr` is a union of 89 constructors
(`ir.brp:1204-1295`). Every non-binding arm ends in `(..., CoreType,
CoreSourceLoc)`. There is no statement type: `LetExpr(binder, is_mutable,
typ, rhs, body)` nests the rest of the block as its last child, and
`SeqExpr(first, rest)` does the same. About 60 payload records
(`CoreListHandoff`, `CoreForList`, `CoreClosureCreate`, ...) hide further
children.

**Identity.** No expression carries an id. The only identity carriers are
`CoreVar { name, id, def_id }` (binder identity, `ir.brp:672`) and
`CoreFunction.def_id` / `CoreGlobal.def_id`. Node identity is pointer
identity, reached through a foreign builtin redeclared privately in ten files
because the pinned bootstrap cannot project a new builtin name:

```
private pure func same_core_expr(left: CoreExpr, right: CoreExpr) -> Bool = "blorp_same_object"
```

**Source locations are a value, not a handle.** `CoreSourceLoc` is
`KnownSourceLoc(String, Int, Int, Int, Int) | SyntheticSourceLoc`
(`ir.brp:663`). It costs two allocations per node: 748,990 calls and
1,497,980 allocations in lowering, 7.87% of the lowering row
(`benchmarks/results/core_lowering_allocation_attribution_2026-09-22.md`).
Compacting it was marked GO there and never started; the stated blocker is
breadth (ten construction sites, the codec, its round-trip test, diagnostics).

**The traversal already preserves identity.** `traverse.brp` (7,472 lines,
32 public functions) rebuilds a node only when a child changed:

```
mapped_left = mapper(state, left)
mapped_right = mapper(mapped_left.state, right)
rebuilt: CoreExpr = if (same_core_expr(mapped_left.value, left)
                        and same_core_expr(mapped_right.value, right)):
	expr
else:
	BinaryExpr(op, mapped_left.value, mapped_right.value, typ, loc)
```

That one change (`60a66556`, 2026-09-16) bought total allocations -8.21% and
late Core -9.89%. `same_core_expr` has 284 call sites in `traverse.brp`
alone. But the central traversal is not the only walk: 52 files under
`stage_09_core/` contain their own `match expr:` (314 sites), and `emit.brp`
has 20 more.

**Passes.** 17 early-Core passes (`early_pipeline.brp`) and 19 late-Core
passes (`pipeline.brp:415`), of which two fused pairs landed this week
(`d1fd548a`, `e1463193`) so the normal late path runs 17 walks. Only one pass
is facts-only (`ownership_contracts`); every other pass returns a rebuilt
`CoreProgram`. `CorePassState` (`pass_runner.brp`) is the only cross-pass
channel and carries exactly one published table:

```
record CorePassState {
	program: CoreProgram,
	next_def_id: Int,
	ownership_contract_facts: OwnershipContractFacts
}
```

Facts recomputed by more than one pass today: free variables (25 private
`free_vars_*` helpers in `closure.brp`), use counts and ownership summaries
(`perceus/uses.brp`; `summarize_linear_ownership_uses` is 4.8M calls and
28.6% of the Perceus row, of which 14.1% repeat a pair already summarized in
the same rebuild), declaration indexes (`closure.brp` `functions_by_id`,
`resolve.brp` three `*_targets_by_id`, `dce.brp` id sets, Perceus
`build_env`), and expression types (one `CoreType` inline per node).

**Two table attempts were measured and parked.** `core/program-facts`
(indexes of declaration objects: no faster, stale after body rewrites) and
`perf/definition-table` (+11% instructions when built inside the per-module
lowering loop; the recorded fix is to build once after lowering). The rule
they left in `CORE_ID_MIGRATION.md`: a table holds ids and indices, and
consumers read bodies from the program. A fold-instead-of-list traversal was
also rejected (`d8de15a9`: allocations -0.08%, instructions +0.6%).

**The emitter reads the nesting.** `emit.brp:13603` emits a `LetExpr` by
emitting the rhs and concatenating the body's statements; tail position is
the innermost let body; temporaries are numbered left to right; the C name of
a local is `c_local_name(variable.name)` with `id` not consulted. The
`--dump-core-after` path renders through `core_program_to_json`, and
`test_core_json.brp` (6,151 lines) pins the encoding, not structural equality.

**Where the allocations are** (fixed input `0c2e1043`, main at `dab2f490`,
about 186M total): typed frontend 36.9M, core lowering 18.0M, mono 16.6M,
ownership contracts 5.5M, Perceus 41.8M, backend 15.8M, the other Core passes
about 45M between them.

## What this roadmap is not

It is not a rewrite of Core into a flat arena in one step. That would touch
89 constructors, 314 private match sites, the codec, and the emitter's
nesting assumptions at once, with byte-identical C as the only oracle. Each
step here changes one representation fact and measures it. If the measured
result is negative the step is parked with its numbers, as `program-facts`
was.

## Measurement

Every step reports, before and after, on the frozen input
(`--input-rev 0c2e104331a224226088519bb0509c00b9ac0b70`):

- `benchmarks/self_compile_measure --samples 3`, comparing the phase rows the
  step names. Allocation rows are deterministic; instruction rows need three
  samples and the same C toolchain.
- The identity oracle is byte-identical C (`--require-identical`). Steps N1
  and N2 change nothing the emitter prints, so they keep byte identity. A
  step that changes C identifiers uses normalized C
  (`benchmarks/normalize_generated_c_symbols`) plus the runtime, leak and
  sanitizer gates.
- A stage-2 compiler (`benchmarks/build_stage2_compiler`) for any step whose
  gain is in instructions rather than allocations, because `bin/blorp` is
  linked by the pinned bootstrap.
- Gates: the owning suites (`test_core_traverse.brp`, `test_core_json.brp`,
  the pass's own), `scripts/compiler-check --changed --base origin/main`,
  `scripts/test --serial compiler-blorp compiler-tools`, `scripts/test leak`,
  `scripts/test compiler-core-sanitize`, `make hygiene-check`.

Rules learned this month that bind every step:

- Instrumentation must be allocation-neutral with the flag off, and the
  flag-off total must equal the parent commit's row. Two attribution tools
  inflated their own rows (one 3.8x) before this was enforced.
- Dictionary probes do not allocate. Replacing a `Dict[String, ...]` by an
  id-keyed list is an instruction change; do not claim an allocation target
  for it.
- Small pooled allocations are cheap; per-call overhead is not
  (`small_list_allocation_not_the_cost_2026-09-22`). Removing a child list
  is only a win if the replacement walk is not more calls.
- A closure-callback visitor on a per-node path cost +6% instructions
  (`closure_callback_fold_regression_2026-09-22`). Per-node code stays a
  direct `match`.

## Steps

| step | what lands | expected effect | oracle | parallel with |
| --- | --- | --- | --- | --- |
| N1 | `CoreSourceLoc` becomes an `Int` handle into a per-program location table | lowering -1.5M allocations (-8%); every later rebuild copies one Int instead of a five-field union | byte-identical C; diagnostics fixtures unchanged | everything; owns `CoreSourceLoc` |
| N2 | the handle becomes a node id: passes mint fresh rows for synthetic nodes | 0 allocations; enables N3 and N4 | byte-identical C; new invariant under `--check-invariants` | everything |
| N3 | Perceus ownership summaries memoized in a table keyed by node id | Perceus -6M to -11M (-15% to -25% of the row); instructions -3% to -5% | byte-identical C; leak gate | N1/N2 done; not with Perceus liveness work |
| N4 | program facts built once after lowering and published on `CorePassState`: callable table, free-variable table, use counts; per-pass builders deleted | instructions -2% to -4%; allocations -3M to -5M across dce, closure, resolve, Perceus env | byte-identical C | N3 |
| N5 | expression types become type ids from the interning table | node size -1 pointer; mono substitution becomes a table remap; mono -5M to -8M | byte-identical C | after `TYPE_INTERNING_ROADMAP` I3 |
| N6 | let chains as blocks: `BlockExpr(List[CoreStmt], CoreExpr)` | Perceus `LetExpr` row (8.8%) and every let-heavy rebuild shrink; emitter simpler | normalized C, runtime and leak gates | last; owns emit's statement path |

Steps N1 to N4 keep byte-identical C. N5 depends on the type table. N6 is
the only step that changes the emitter's structure and is deliberately last.

### N1: source locations as a handle

**Context.** Two allocations per node for a value that is read only by
diagnostics, `--dump-core-after`, and the backend's line directives.
`SourceLocation` in the frontend already made this move: `blorp/src/lib/
source.brp:48` is `opaque type SourceLocation = Int`, with the comment "keep
it pointer-sized so those payloads remain inline: a struct here is boxed by
the backend".

**Change.** Add a location table to `CoreProgram` and make `CoreSourceLoc` an
opaque `Int`:

```
--- Rows are appended by lowering and by passes that mint synthetic nodes;
--- a row is never mutated. Row 0 is the synthetic location.
struct CoreSourceLocRow {
	file: Int,          -- index into CoreProgram.source_files
	start_line: Int,
	start_column: Int,
	end_line: Int,
	end_column: Int
}

record CoreProgram {
	decls: List[CoreDecl],
	foreign_includes: List[String],
	source_files: List[String],
	source_locs: List[CoreSourceLocRow]
}

opaque type CoreSourceLoc = Int

pure func core_source_loc_row(program: CoreProgram, loc: CoreSourceLoc) -> CoreSourceLocRow
pure func core_source_loc_is_synthetic(loc: CoreSourceLoc) -> Bool = loc == 0
```

`List[CoreSourceLocRow]` is inline storage (`InlineStructListStorage`), so a
row costs no allocation of its own. Lowering owns the append: a local `var`
accumulator in the lowering context, published once on the program, exactly
as `LexResult.texts` is built. Passes that construct a node today write
`SyntheticSourceLoc` or copy the source node's `loc`; both keep working:
synthetic is row 0, and copying an `Int` is free.

The ten `KnownSourceLoc(` construction sites, the codec (`ir.brp:2977`
region; encode the row's fields so the JSON is unchanged), the decoder (build
the table while decoding), and the diagnostic renderers change in the same
commit. `test_core_json.brp` round-trips must keep passing byte for byte on
the encoded string, which they will if the encoder prints the resolved row.

**Expected ROI.** `core_lowering_complete` -1.5M allocations (about -8% of
the row). Every downstream node rebuild stops retaining and releasing a loc
object: a small instruction gain across all Core passes (estimate -0.5% to
-1%). Peak RSS down by 748,990 five-field unions.

**Risks.** Diagnostics that print a loc must resolve through the program;
any helper that had only a `CoreSourceLoc` in hand now needs the table or
the resolved row passed in. Grep every `core_source_loc_` consumer before
starting and count them in the report. The backend receives the program, so
line directives are unaffected.

**Oracle.** Byte-identical C; the 860 typecheck diagnostic fixtures and the
Core dump JSON unchanged; `test_core_json.brp` green.

### N2: the handle is the node id

**Context.** After N1 every lowered node carries a row index that is unique
to it, because lowering appends one row per node. Passes that copy a loc from
the node they rewrite produce two nodes with the same index, which is fine
for locations but not for identity.

**Change.** Rename the field's role without changing its type: a node's
`loc` is its `node: CoreNodeId` (`opaque type CoreNodeId = Int`), and the
location is one column of the node row. Add the allocator to the pass state
so a pass that mints a node gets a fresh row that copies the source node's
location:

```
record CorePassState {
	program: CoreProgram,
	next_def_id: Int,
	ownership_contract_facts: OwnershipContractFacts
}

--- Mint a node id whose location is that of `origin`.
pure func core_mint_node(program: CoreProgram, origin: CoreNodeId) -> (CoreProgram, CoreNodeId)
```

Convert the passes that construct nodes to mint through it, one pass per
commit if the count is large (grep `SyntheticSourceLoc` and copied `loc`
arguments; the survey counted ten `KnownSourceLoc(` sites but many more
`loc` pass-throughs). Add a checked invariant, report-only first like the
binder-identity contract: two nodes in one function must not share a node
id. Flip it to fatal when the count reaches zero on the self-compile.

**Expected ROI.** None directly. This step exists so N3 and N4 can key
tables by node. Report the invariant's violation count before and after.

**Risks.** A pass that rebuilds a node through the identity-preserving
mapper must keep the old id when it returns a new allocation with the same
meaning (the mapper copies `loc` today; that becomes copying the id, which is
correct). Only genuinely new nodes mint. Judging "new" versus "rewritten" is
per site; the report lists the decisions.

**Oracle.** Byte-identical C; invariant count reported.

### N3: Perceus summaries by node id

**Context.** `summarize_linear_ownership_uses` is 28.6% of the Perceus row
and returns a fresh `OwnershipUseSummary` record per visit (11M records) plus
a frame stack (4.3M pushes); 14% of its calls repeat a `(name, expr)` pair
already summarized inside the same `rebuild_managed_let`. Every prior
go/no-go on Perceus at the 5% threshold came back negative because the cost
is diffuse, 2 allocations per visit at the floor.

**Change.** A table `Dict[CoreNodeId, OwnershipUseSummary]` (or a
`List[Option[...]]` indexed by node id once ids are dense) built once per
function body before drop insertion, in one bottom-up walk; the per-visit
call becomes a lookup. `rebuild_managed_let`'s repeated summaries hit the
table. The summary for a node is invalidated only when the node is replaced,
which under N2 means a new id, so no invalidation logic is needed within a
function.

```
-- before: recomputed at each managed let
summary: OwnershipUseSummary = summarize_linear_ownership_uses(env, name, body)

-- after: one table per function body
summaries: OwnershipSummaryTable = build_ownership_summaries(env, body)
summary: OwnershipUseSummary = ownership_summary(summaries, name, body.node)
```

Note the key includes the variable being summarized as well as the node;
use `(node, variable.id)`.

**Expected ROI.** Perceus row -6M to -11M (-15% to -25%), instructions -3%
to -5% on the self-compile, because the repeated walks disappear and the
per-visit record allocation happens once per node instead of once per
(let, node) pair. Go/no-go gate: at least -5M on the Perceus row or the
step is parked with numbers.

**Risks.** Summaries depend on the environment at the let, not only on the
node; confirm which fields of `PerceusEnv` the summary reads and key on them
or prove they are constant within a body. The leak gate is the safety net.

**Oracle.** Byte-identical C; `scripts/test leak`; `test_core_perceus.brp`.

### N4: program facts published once

**Context.** Four late passes rebuild a callable index from `decls`;
`closure.brp` recomputes free variables with 25 helpers; `dce.brp` collects
reads and invalidations that Perceus later needs again. The parked attempts
failed because they indexed declaration *objects* (stale after rewrites) or
were built inside the lowering loop.

**Change.** A `CoreProgramFacts` record on `CorePassState`, built once by a
facts pass right after lowering and kept current by the two operations that
change the declaration set (mono and consume-specialize mint; dce prunes),
which append or tombstone rows by `def_id`. Rows hold ids only:

```
record CoreCallableRow { def_id: Int, name: String, arity: Int, decl_index: Int }
record CoreProgramFacts {
	callables: List[CoreCallableRow],        -- indexed by def_id
	free_vars_by_function: List[List[Int]],  -- binder ids, by def_id
	...
}
```

Consumers read bodies from `program.decls` through `decl_index`. Delete each
per-pass builder as its consumer converts, one pass per commit, with the
pass's allocation row as the measure. Start with the cheapest to verify:
`resolve.brp`'s three `*_targets_by_id` dictionaries.

**Expected ROI.** Instructions -2% to -4%; allocations -3M to -5M summed over
`pass_dce`, `pass_closure`, `pass_resolve_callables` and the Perceus env
build. Go/no-go per consumer: the pass's row must go down or the builder
stays.

**Risks.** Exactly the ones that parked the earlier attempts: staleness and
build placement. The mitigation is structural (ids only; built after
lowering; maintained by the two minting passes) and the invariant walk under
`--check-invariants` should assert the table matches `decls` after every
pass.

**Oracle.** Byte-identical C.

### N5: expression types as type ids

**Context.** Every node carries a `CoreType` union inline; mono substitution
rebuilds those trees per instantiation; `core_type_equal` (37 sites) and
`core_mono_type_equal` (139 sites) compare structurally without a pointer
short-circuit.

**Change.** Depends on `TYPE_INTERNING_ROADMAP.md` I3 (a `CoreTypeTable`
with hash-consed rows). The `CoreType` field on each expression becomes a
`CoreTypeId`; type substitution in mono becomes a remap over the table; the
two equality functions become integer compares. The codec renders the
resolved type so the dump JSON is unchanged.

**Expected ROI.** Mono -5M to -8M; every node rebuild stops copying a type
pointer; instructions -2% to -3%.

**Risks.** This is the widest mechanical change in the roadmap (every arm,
every private match that reads `typ`). Do it after N1 established the
pattern of a scalar column per node, and only once I3 has landed and its
table is stable.

**Oracle.** Byte-identical C.

### N6: blocks instead of let nesting

**Context.** A function body of n lets is n nested `LetExpr` nodes; every
pass that touches one let rebuilds the chain above it. Perceus's `LetExpr`
arm alone is 8.8% of its row. The emitter derives statement order and tail
position from the nesting.

**Change.** `BlockExpr(List[CoreStmt], CoreExpr)` where `CoreStmt` is
`LetStmt | AssignStmt | ExprStmt`; lowering emits blocks; `LetExpr` and
`SeqExpr` are removed from late Core by a checked invariant. The emitter's
statement path iterates the list. This changes emitted C layout (statement
order is the same, temporaries may renumber), so the oracle is normalized C
plus the behavioural gates.

**Expected ROI.** Perceus and every let-heavy pass rebuild a list slice
instead of a chain: estimate late Core -5% to -10% allocations and a
comparable instruction gain. Estimate is soft; measure a prototype on the
small program first.

**Risks.** Largest blast radius in the roadmap: the emitter's `LetExpr`
arms, every pass that pattern-matches `LetExpr`, and the ownership passes'
notion of scope. Only start after N1 to N4 have landed and the pass list has
stopped moving.

**Oracle.** Normalized C; runtime, leak, sanitizer, codegen-audit gates.

## Parallelism

| roadmap | owns | touches lightly |
| --- | --- | --- |
| this one | `ir.brp` (`CoreSourceLoc`, `CoreProgram`, node ids), `traverse.brp`, `pass_runner.brp`, `perceus/uses.brp` (N3), `closure.brp`/`resolve.brp`/`dce.brp` builders (N4), emit's statement path (N6) | `lower.brp` (loc minting only) |
| `TYPE_INTERNING_ROADMAP` | `semantic_type.brp`, `context.brp`, type lowering in `lower.brp`, `mono*.brp`, `trait_resolve.brp` keys, `list_layout.brp` | `ir.brp` (`CoreType` equality, then the type table field) |
| `STRUCT_PAYLOAD_ROADMAP` | `lower_union_payload_storage` in `lower.brp`, union emission in `emit.brp`, `match_projection.brp` accessors, `specialize_layout.brp`, codegen fixtures | `ir.brp` (only after N1: `CoreVar` as a struct needs a name id from interning) |

Meeting points: N1 gives `STRUCT_PAYLOAD_ROADMAP` its example of a
record-to-handle conversion and owns `CoreSourceLoc`, so that roadmap does
not convert it. N5 waits for I3. Nothing in N1 to N4 conflicts with either
companion; run them concurrently, each in its own worktree, and merge main
before every gate run.

## Not in this roadmap

Perceus as a single liveness pass (a separate design once N3 and the
Perceus cleanup issues settle), parallel late passes (blocked on task-fiber
cost), and the emitted-C shape (`PER_NODE_CODEGEN_ROADMAP.md`).
