# Typecheck Optimization Issues

Five self-contained issues for reducing the time and allocations of the typed
frontend on the compiler's own self-compile. Each issue names the exact
functions and records to change, the order of cuts, the fast loop, the
acceptance numbers, and the traps that cost earlier attempts a cycle. Read
[`WORKER_CHECKLIST.md`](WORKER_CHECKLIST.md) first; the rules there (no
`git stash`, no parallel test binaries, foreground gates, one squash commit
per task) apply to every issue below.

All anchors are against main at `cf9a7350` (2026-09-21). Line numbers drift;
the function and record names do not, so grep for the name if a line is off.

## Shared context

### Where the phase stands

Frozen self-compile input `10acd6104`, compiler built at `-O2`, one run with
`BLORP_TYPECHECK_BODY_METRICS=1` (the metrics inflate allocation totals; use
them for attribution, and the harness rows below for acceptance):

| typecheck phase row | wall | allocations |
| --- | ---: | ---: |
| `indexed_graph` | 251 ms | 0.10M |
| `bound_modules` | 190 ms | 1.83M |
| `callable_headers` | 66 ms | 1.17M |
| `global_header_completion` | 834 ms | 6.62M |
| `graph_completion` (contains the row above) | 848 ms | 6.76M |
| `module_bodies` (13,314 bodies) | 1,847 ms | 27.66M |

Harness rows without metrics (`benchmarks/self_compile_measure`, same input):
`source_discovery_complete` 8.47M allocations, `typed_frontend_complete`
about 34M, so the typed frontend itself is about 25.6M allocations and
3.1 s wall at `-O2`. Inside the body loop the earlier sample split was:
generated code 30%, reference counting 27%, cancellation cleanup frames
18.5%, allocation 7.5%, string and dict lookups 5%. The zonk skip for bodies
with no metas (`a92f30bda`) already landed; per-node zonk reuse was measured
negative and is not an option here.

### Fast loop (about 6 s per run)

```bash
base=$(git rev-parse origin/main)
input=$(benchmarks/self_compile_measure freeze --rev "$base")
BLORP_CLI_C_OPTIMIZATION=-O2 make && scripts/compiler-build-status   # must say FRESH

BLORP_TYPECHECK_BODY_METRICS=1 BLORP_COMPILER_MEMORY_PROFILE=1 \
  bin/blorp compile --stop-after=lower --no-format \
  --std-dir "$input/standard_library/src" "$input/blorp/src/main.brp" \
  2>&1 >/dev/null | grep -E '^BLORP_(TYPECHECK_PHASE|TYPECHECK_BODY_TOTAL|COMPILER_MEMORY_CHECKPOINT)'
```

`--stop-after` only accepts Core stage names (`stage_09_core/stage_manifest.brp`),
so `lower` is the earliest stop; it still runs lowering but skips every later
pass and emission. The lines to watch are the `BLORP_TYPECHECK_PHASE` rows
named above and the `typed_frontend_complete` checkpoint
(`total_allocations` minus the `typed_frontend_start` value). Allocation
counts are deterministic; run once while iterating. Wall time is noise until
the harness runs below.

Per-body attribution: the same run prints one `BLORP_TYPECHECK_BODY` row per
body sorted by time (`runtime.c` ~2075-2148 for the format). `head -40` of
those rows tells you whether a change moved the expensive bodies.

### Acceptance (the numbers that decide)

```bash
benchmarks/self_compile_measure --label <issue>-parent --input-rev "$base" \
  --samples 3 --output /tmp/<issue>-parent.json            # on the untouched tree, first
benchmarks/self_compile_measure --label <issue> --input-rev "$base" --samples 3 \
  --baseline /tmp/<issue>-parent.json --output /tmp/<issue>.json --require-identical
benchmarks/self_compile_measure --program small --label <issue>-small --input-rev "$base" \
  --samples 3 --baseline /tmp/<issue>-parent-small.json --output /tmp/<issue>-small.json --require-identical
```

Typecheck source is compiled into `bin/blorp` by the bootstrap, so unlike
emitter changes these measurements do observe your change directly, and
`--require-identical` is a real identity check (exit 3 means the typed
program changed and lowering produced different C: a bug, not a result). A
cut lands when the `typed_frontend_complete` allocation row drops by at
least the issue's target, retired instructions do not rise beyond 0.3%, and
the small program does not regress. A neutral result is reported and
dropped, not argued.

### Correctness loop

```bash
bin/blorp test --timeout 300 blorp/test/compiler/stage_06_typecheck/test_infer.brp \
  blorp/test/compiler/stage_06_typecheck/test_typecheck_decl.brp \
  blorp/test/compiler/stage_06_typecheck/type_system/test_env.brp
scripts/compiler-check --changed --plan            # read-only: what will run
benchmarks/self_compile_measure lock -- scripts/compiler-check --changed
benchmarks/self_compile_measure lock -- scripts/test --serial compiler-blorp compiler-tools lsp
```

The diagnostic fixtures (`fixtures/typecheck/should_fail`, 589 files, and
`infer_fixtures/infer/should_fail`, 271 files) are part of the identity
oracle: diagnostic text and order must not change. The
`*_profile_benchmark.brp` suites under `stage_06_typecheck/` are existing
perf regression tests; run the ones that name the structure you touch.

### Traps seen this month

- A helper that returns its parameter unchanged on one path defeats
  in-place update everywhere it is called (the reuse gate assumes aliasing).
  Return a record update, or update at the assignment site from a local.
- `Dict[String, ...]` where an `Int` id exists. Every issue below removes
  one; do not add another.
- A struct inside an `Option`, a union payload, or a `List` of records is
  boxed; converting a record to a struct there saves nothing.
- Reading a whole struct out of an inline `List[struct]` copies it; read the
  field.
- Threading a state record through helpers and returning it copies any
  shared dictionary inside it on every update. Build facts once, borrow
  them, own accumulators as locals.
- Wall-clock claims. A "50% win" this month was machine noise. Allocation
  rows and retired instructions only.

---

## Issue T-A: Dense slot tables in the accepted authorities

**Goal.** Replace the `Int -> Int` dictionaries that map a definition id to a
slot index with dense lists indexed by the id, and stop hashing a name more
than once per bare lookup. Target: `typed_frontend_complete` allocations
down 2% or more, string-hash and dict-probe instruction share down; C
identical.

**Why.** Definition ids are dense integers minted from a running counter
(`graph/definition_index.brp:950`, `definition_id(current_next_def_id)`),
and the definition table already exploits that: `definition_table_rep_row`
(`definition_index.brp:413-421`) is `rows.get(raw_id - first_graph_definition_id)`,
an array index. But the per-kind authorities consulted on every bare-name
resolution then throw that away. `accepted_global_find`
(`type_system/accepted_global_authority.brp:707-718`) does: one
`String -> Int` dict probe in the source-name table, one array index into
`visible_locators_by_source_name_id`, then `binding_at`
(`accepted_global_authority.brp:696-704`) does a second dict probe
`table.index_by_global_definition_id.get(definition_id)` before the final
`table.slots.get(index)`. `accepted_callable_find`
(`type_system/accepted_callable_authority.brp` ~562-579) has the same shape
and additionally compares candidates through
`definition_index_rep_find_func_callable_id`
(`definition_index.brp:984-1005`), a linear scan of a
`FuncCallableNameBuckets = Dict[String, List[DefinitionId]]` bucket
(`definition_index.brp:149`) calling `definition_table_rep_row` per candidate.

**Cuts, in order.**

1. `index_by_global_definition_id: Dict[Int, Int]` (find its declaration in
   `accepted_global_authority.brp`; it is populated where slots are appended)
   becomes `slot_by_definition_offset: List[Int]` indexed by
   `raw_id - first_graph_definition_id`, with `-1` for "no slot". Build it in
   the same builder that appends slots; read it in `binding_at`. Do the same
   for the callable authority's equivalent index and for
   `accepted_trait_implementation_authority.brp` if it has one (it calls
   `definition_id_runtime_value` at line 270; check what it indexes).
2. `FuncCallableNameBuckets` keyed by `String` becomes keyed by
   `SourceNameId` (an `Int`): change the type at `definition_index.brp:149`,
   the insert in `definition_index_add_func_callable_id` (~1044-1059), and the
   lookup in `definition_index_rep_find_func_callable_id` (984-1005). The
   callers already have or can obtain a `SourceNameId` via
   `source_name_table_find_id` (`graph/source_name_table.brp:437-442`); do the
   String lookup once at the entry of the find, never inside the loop.
3. Measure after each cut. If cut 2 is flat, keep it anyway only if it
   deletes code; otherwise revert it and say so.

**Tests.** `test_definition_index.brp`, `test_accepted_record_authority.brp`,
`test_accepted_union_authority.brp`, `test_accepted_alias_authority.brp`,
plus the authority tests for globals and callables (grep `accepted_global`
and `accepted_callable` under `blorp/test/compiler/stage_06_typecheck/`). Add
one test per converted table asserting that a definition id outside the
table's range returns `None`, not an out-of-bounds panic.

**Traps.** `first_graph_definition_id` differs between the in-progress
`DefinitionIndexRep` and the finished `DefinitionTable`; read it from the
table you are indexing. Ids from `definition_index_add_func_callable_id` may
be minted after the table's rows were appended; check `next_def_id` handling
at `definition_index.brp:1044-1059` and the source-definition adder near
line 1281 before assuming the dense range is closed.

---

## Issue T-B: Scope lookup keyed by name id, not name text

**Goal.** Every identifier occurrence in a body currently walks the scope
chain hashing its `String` once per scope. Key scopes by an `Int` name id so
the chain walk hashes an integer, and hash the string at most once per
occurrence. Target: string hash and equality samples in the body loop
(about 5% of it) mostly gone; `typed_frontend_complete` allocations down
1% or more from fewer key copies; C identical.

**Where.** `type_system/env.brp`:

- `Scope` record (277-280): `symbols: List[Symbol]`,
  `symbols_by_name: Dict[String, List[Int]]`. The `Int`s are indices into
  `symbols`, most recent first (`scope_add_symbol`, 495-505, prepends).
- `scope_lookup` (562-571) probes `symbols_by_name` and takes index 0.
- `env_lookup` (718-729) walks `env.scopes` outer to inner calling
  `scope_lookup` per scope, `O(depth)` string hashes.
- `env_symbols_named` (~704) walks every scope and collects all matches; it
  is the fallback `lookup_bare_value` takes when the direct hit is filtered
  by visibility.

`infer.brp`: `lookup_bare_value` (7218-7305) is the single choke point for
identifier resolution: `env_lookup` first, then `env_symbols_named`, then the
accepted callable and global authorities (Issue T-A), then constructors. Its
callers are `infer_name_expr` (7395), `bare_callee_is_constructor` (9268), and
`infer_special_builtin_call_expr` (17057). Binders enter the scope through
`env_add_var_with_details` from: `add_lambda_param_bindings` (13501),
`add_tuple_destruct_bindings` (13775), `add_match_binding` (17550),
`add_tuple_for_bindings` (19273), `infer_for_expr` (19413),
`infer_implicit_assign_binding` (19661), `infer_var_decl_expr` (19932),
`question_bind_result` (20085), `add_concurrent_result_binding` (20731),
`infer_with_error_mapper` (21101), `infer_with_body` (21311),
`infer_concurrent_for_body` (21597), `infer_select_arm_body` (21776),
`if_refined_then_context` (18738).

**Cuts, in order.**

1. Introduce the key. The program-wide `SourceNameTable`
   (`graph/source_name_table.brp:30-39`, `spellings: List[String]`,
   `id_by_spelling: Dict[String, Int]`) already exists in the typecheck
   session. Add an `Env`-level accessor that turns a `String` into its
   `SourceNameId` through `source_name_table_find_id`, inserting on a miss
   if the table permits it (it is built during the graph phase; if it is
   frozen by body-checking time, add a per-session local-name table with
   the same shape for names that only occur as locals). Do this once at the
   top of `lookup_bare_value` and once in `env_add_symbol`.
2. Change `Scope.symbols_by_name` to `Dict[Int, List[Int]]` keyed by the
   name id; `scope_add_symbol` and `scope_lookup` take the id. `Symbol` keeps
   its `name: String` for diagnostics. All external callers go through
   `env_lookup`, `env_lookup_with_scope_depth` (746-762),
   `env_symbols_named`, `env_lookup_in_current_scope` and the
   `env_add_*` wrappers (776, 804, 826, 1003, 1389, 1491, 1556, 1620); each
   gains an id parameter or resolves the id at its entry. Do not leave a
   String-keyed twin alive "for compatibility".
3. Remove the fallback scan. `env_symbols_named` exists because
   `env_lookup` returns the first hit even when visibility filtering will
   reject it. Make the walk take the visibility predicate
   (`symbol_is_lexical_or_current_module`, see `lookup_bare_value`) so it
   returns the first *visible* hit and the all-matches scan is only reached
   for genuine ambiguity. Count how often the fallback still fires with a
   temporary counter under `BLORP_TYPECHECK_BODY_METRICS` before and after
   and put both numbers in the commit body; then delete the counter.
4. Measure after each cut.

**Tests.** `type_system/test_env.brp` (2,117 lines; shadowing, scope depth,
visibility cases live here), `test_infer.brp`, and
`test_env_symbols_named_profile_benchmark.brp`, which is the existing
regression test for cut 3. Add cases for: a local shadowing an imported
callable, a match binding shadowing a lambda parameter, and a name that
exists only in an outer module scope.

**Traps.** Diagnostics print `Symbol.name`, not the key; keep the text on
the symbol. `env_symbols_named` returns matches in scope order and callers
may depend on that order for ambiguity messages; preserve it. Do not put the
name id on `ParsedIdentifier` in this issue (that is a parser change with
its own identity oracle); resolve the id at the `Env` boundary.

---

## Issue T-C: Flatten the per-node typed facts

**Goal.** Every `TypedExpr` node carries a `TypedExprInfo` record and, in
the common case, a boxed `KeptValueSlot`, so a body of N nodes costs at
least 2N allocations before any inference happens; the phase averages about
2,100 allocations per body over 13,314 bodies. Remove the boxes that carry
no information in the common case. Target: `typed_frontend_complete`
allocations down 8% or more; C identical.

**Where.** `infer.brp`:

- `TypedExprInfo` (536-544): `source_type: Option[SemanticType]`,
  `origin: ExprTypeOrigin`, `value_slot: ValueSlot`, `proofs: ValueProofs`,
  `resolved_call: Option[ResolvedCallInfo]`,
  `resolved_definition_id: Option[Int]`, `resource_dependencies: List[String]`.
- `ValueSlot` (`type_system/type_widening.brp:65-67`):
  `KeptValueSlot(SemanticType)` or `WidenedValueSlot(SemanticType, SemanticType, TypeWideningReason)`.
  `KeptValueSlot` is constructed 18 times in infer.brp; it is the common
  case and it boxes one pointer.
- `ExprTypeOrigin` (473-476): `InferredOrigin` (no payload, free),
  `ExplicitAnnotationOrigin(SemanticType)`, `SynthesizedOrigin(String)`.
- `ResolvedCallInfo` (506-518): 12 fields including three lists; built by
  seven `resolved_call_from_*` helpers (1510, 1577, 1645, 1682, 1704, 1723, 1747).
- The near-universal constructor is `typed_expr_info_from_slot` (1373-1387),
  called from 17 sites (1395, 6849, 7339, 7408, 7432, 7461, 7517, 7581, 8883,
  8895, 8917, 8938, 10457, 10775, 13740, 16405) and wrapped by
  `inferred_info` (1391-1400).
- Readers: the accessors at `infer.brp:1779-2012` (`typed_expr_info`,
  `typed_expr_value_type`, `typed_expr_resolved_call`, `typed_expr_widening`,
  ...); `typed_ast_json.brp` reads the fields directly (61 sites, e.g.
  784-791 and the `resolved_call_to_json` family 415-655); `stage_07_ctfe`
  reads `typed_expr_resolved_call` and `typed_expr_value_type` (`ir.brp:388,
  961, 986, 1050`, `body_dependencies.brp:61`); `stage_08_core_lower/lower.brp`
  reads `typed_expr_value_type` at 21 sites (1893, 2101, 2164, 2296, 2659 and
  others); `graph/typed_expr_children.brp` and the LSP read no info fields.
- The zonk rebuilds info per node in `zonk_typed_expr_info` (2968-2978) for
  the 0.7% of bodies that still have metas.

**Cuts, in order.**

1. Measure the shape first. Add a temporary counter under
   `BLORP_TYPECHECK_BODY_METRICS` that counts `TypedExprInfo` constructions
   and how many have `value_slot` kept, `origin` inferred, `resolved_call`
   none, `proofs` empty, `resource_dependencies` empty. Put the five ratios
   in the commit body; they justify cut 2 and 3. Remove the counter after.
2. Unbox the value slot. Replace `value_slot: ValueSlot` with
   `slot_type: SemanticType` and `widening: Option[TypeWidening]` where
   `TypeWidening` holds the widened-from type and the reason. `KeptValueSlot`
   becomes "widening is `None`", so the common node allocates no slot box.
   Update `typed_expr_info_from_slot`, the accessors, `zonk_value_slot`, and
   `value_slot_to_json`; `typed_ast_json` must produce the same JSON as
   before (the `test_typed_ast_json.brp` suite is the oracle).
3. Share the empties. If cut 1 shows `proofs` and `resource_dependencies`
   are empty on nearly every node, make the constructors reuse one
   program-lifetime empty value instead of building a fresh empty list or
   record per node (check whether `[]` already shares; if it does, this cut
   is a no-op and you say so).
4. Only if cuts 2 and 3 leave the target unmet: split `TypedExprInfo` into
   the always-present part (`slot_type`, `origin`, `widening`,
   `resolved_definition_id`) stored inline on the node, and a
   `Option[TypedExprExtras]` holding `source_type`, `proofs`,
   `resolved_call`, `resource_dependencies`, allocated only when one of them
   is non-default. This touches every `TypedExpr` variant (60 or more at
   `infer.brp:679`) and every construction site; do it with the central
   builder and let the exhaustiveness errors find the rest.

**Tests.** `test_infer.brp`, `test_typed_ast_json.brp` (JSON must be
byte-identical for every fixture), `test_typecheck_bridge.brp`, plus the
CTFE and lowering suites that read the accessors
(`blorp/test/compiler/stage_07_ctfe`, `stage_08_core_lower`).

**Traps.** `WidenedValueSlot` carries two types; keep both. `zonk` must
still resolve metas inside `slot_type` and inside the widening. Do not
move to node-index side tables in this issue; that is the flat typed AST
and needs its own oracle.

---

## Issue T-D: Global header completion is a fifth of the phase

**Goal.** `global_header_completion` costs 834 ms and 6.6M allocations,
more than a fifth of the typed frontend, for what should be a dependency
sort over globals and inference of the unannotated ones. Attribute it, then
cut the largest component. Target: the `global_header_completion` phase row
down 30% or more in allocations; C identical.

**Where.** `decl.brp`: `complete_typecheck_graph` (8839-8853) runs once per
compile from `bridge.brp:978-989` and calls
`complete_typecheck_graph_for_meta_run` (8723-8836), which times
`accepted_aliases`, `accepted_records`, `accepted_unions`, `accepted_globals`,
then `complete_global_header_graph` (8416-8449, the 834 ms row), then
`accepted_graph`. `complete_global_header_graph` builds a
`GlobalHeaderCompletionPlan` via `global_header_completion_plan_build`
(`headers/global_header_completion.brp:679-733`): it iterates every global
header in the program (`callable_header_graph_globals`), splits annotated
from pending, builds `global_dependency_adjacency` over the pending ones and
orders them with `pending_global_dependency_order`, then the completion
infers each pending global's type in that order. The body-metrics row
`complete_planned_global_headers` (a `decl.brp` function) is where the
inference happens.

**Cuts, in order.**

1. Attribute. Wrap the three sub-steps (plan build, annotated installs,
   pending inference) in `typecheck_phase_mark` / `record_typecheck_phase`
   rows (the pattern is in `complete_typecheck_graph_for_meta_run`) named
   `global_plan`, `global_annotated`, `global_pending`. Also print the
   counts: globals total, annotated, pending, and how many pending globals
   are in the compiler's own modules versus the standard library. Put the
   table in the commit body. This cut lands on its own; the rows are
   permanent.
2. Cut whichever row dominates:
   - If `global_pending` dominates: each pending global is inferred with a
     fresh inference session; check whether the session setup
     (`InferSession` construction, environment install for the global's
     module) is rebuilt per global and hoist it per module. The
     per-module header product from `6ccd89809`
     (`headers/type_header_install.brp:563-580`,
     `module_header_product_table_ensure` 787-816) is the model: build once
     per module, read per global.
   - If `global_plan` dominates: `global_dependency_adjacency` is likely
     computing dependencies by scanning each global's initializer for names
     and resolving them by string; key it by definition id (Issue T-A gives
     you the dense index) and build the adjacency as a `List[List[Int]]`.
   - If `global_annotated` dominates: annotated globals need no inference;
     find what is being rebuilt for them and stop.
3. Measure with the fast loop after each cut; the phase row is the metric.

**Tests.** `test_typecheck_decl.brp` (global ordering and cycle diagnostics
live here), `test_global_header_dependency_profile_benchmark.brp` (existing
regression test for the plan), `fixtures/typecheck/should_fail` cases that
mention globals or cycles.

**Traps.** The order in which pending globals are inferred determines which
diagnostic is reported first for a cycle; keep
`pending_global_dependency_order` stable. Globals can depend on CTFE
results (`ctfe_globals` runs after); do not move CTFE work.

---

## Issue T-E: Resolve each identifier once per body (design, then cut 1)

**Goal.** Longer term, a use site should carry the definition id or local
slot it resolved to, so inference and every later stage read an id instead
of re-walking scopes by name. Today `TypedNameExpr(ParsedIdentifier, TypedExprInfo)`
keeps only `ParsedIdentifier.text` and `resolved_definition_id: Option[Int]`
(set for callables and globals, `None` for locals); the scope index used to
resolve a local is discarded. This issue delivers the design and the first
cut, and depends on T-B.

**Deliverable 1, design note (`docs/`, under 120 lines).** What a per-body
resolution table looks like: one row per identifier occurrence in source
order (occurrence index minted by the parser or by a pre-pass over the
parsed body), row = `Local(slot)` or `Definition(DefinitionId)` or
`Constructor(...)`, built by one walk that mirrors the binder call sites
listed in T-B; who consumes it (inference reads the row instead of calling
`lookup_bare_value`; lowering reads the id instead of the name; the
definition table published out of typecheck, the parked `perf/definition-table`
branch, becomes the consumer's index). Say what the parser must add
(an occurrence index on `ParsedIdentifier`, or a side counter in the
finalizer) and what the identity oracle is (typed JSON and diagnostics
unchanged).

**Deliverable 2, cut 1.** Give locals an id: when `env_add_var_with_details`
binds a local, mint a per-body slot number and store it on the `Symbol`;
when `infer_name_expr` resolves a `BareEnvSymbol`, put that slot into
`resolved_definition_id` (or a new `resolved_local_slot: Option[Int]` if the
two id spaces must not mix; prefer a single `ResolvedName` union with
`LocalSlot(Int)` and `Definition(Int)` arms and delete the bare
`Option[Int]`). Lowering's `lower.brp` currently reconstructs local identity
by name and uniq; find where (grep `uniq` in `lower.brp`) and read the slot
instead. Acceptance for cut 1 is identical C and no allocation regression;
the win arrives when lowering stops rebuilding its name maps, which is the
follow-up.

**Tests.** `test_infer.brp`, `test_typed_ast_json.brp` (a new field must be
serialized deterministically), lowering suites.

**Traps.** Shadowing: two locals with the same name in one body must get
different slots and the typed JSON must show which was resolved. Closures
capture locals by name today (`closure.brp` `free_vars_expr`); keep the name
until the capture path reads slots too.

---

## Order and parallelism

T-A and T-C touch different files and can run in parallel. T-B follows T-A
(it wants the name-id key). T-D is independent and can start at any time;
its cut 1 is attribution only and should land within a day. T-E starts
after T-B lands. Each issue is one squash commit on main with the
measurement record folded into the commit body; record the accepted
harness JSON under `benchmarks/results/self_compile_<issue>_O2_<date>.json`.
