# Module environment preparation repeatedly rebuilds state

Status: open.

## Cost and hypothesis

Base construction and final-authority indexes in `prepared_module_environments`
still need independent attribution. Earlier bounded cuts changed the split;
remeasure current main before choosing the next helper. Prior measurements:
[helper allocation ranking](../../benchmarks/results/typecheck_body_helper_allocations_O2_2026-09-22.md),
[import scope transitions](../../benchmarks/results/typecheck_import_scope_transitions_2026-09-25.md),
[qualified implementation projection](../../benchmarks/results/typecheck_qualified_implementation_projection_2026-09-26.md).

**Goal.** `global_prepare` (all of it `prepared_module_environments` in
`stage_06_typecheck/decl.brp`, called once per compile from
`complete_planned_global_headers`) was 5,201,772 allocations, 78.3% of
`global_header_completion`, when first measured. It prepares one canonical
environment per module and its result is carried to body checking in
`TypecheckGraphFacts.prepared_environments`. It rebuilds the same per-module
setup once per module, once per trait header, once per callable header and once
per implementation header through a `bases` list it updates by
`bases.set(index, {...})`. Move the setup that is the same for every module in
front of the loops, build the per-module state once, and stop copying the base
record per header. Target: the `global_prepare` row down 40% from its first
measurement (about 2.1M allocations), the `typed_frontend_complete` harness row
down 1.5% or more beyond the landed cuts; identical C.

**Where.** All inside `prepared_module_environments`, as seven loops
(`record_typecheck_phase` rows already mark each: `prepare_products`,
`prepare_bases`, `prepare_traits`, `prepare_trait_authority`,
`prepare_callables`, `prepare_impls`, `prepare_environments`):

- Setup derived before the loops (`callable_headers`, `type_headers`,
  `bound_graph`, `definition_table`, the `modules` list, the base positions by
  module id, an empty `header_products` table) is already hoisted.
- Products loop: `module_header_product_table_ensure` per module and per
  visible import per module. A module imported by forty modules is ensured forty
  times; check the hit path for allocation.
- Bases loop: `prepared_module_environment_base_state` per module builds a fresh
  `TypecheckState`, scans known type names, calls three
  `prepare_*_type_authority` helpers that each thread and return the state,
  registers the module view facts and every visible import, installs the local
  header section, and appends a `PreparedModuleCallableBase` holding the whole
  state plus `local_type_names_from_decls`.
- Trait, callable and implementation loops: per header, each doing
  `bases.set(index, { base | state = ... })`; whether a record update on a shared
  list element copies depends on the reuse gates, and
  `prepare_accepted_callable_header` returns state per callable header, which
  is written back through `bases.set`. The accepted graph already visits
  callables one module at a time; `active_rows` groups and sorts completed
  module rows without yet owning the module's state across those headers.
- Environments loop: per base, install the callable and trait authorities,
  build `prepared_canonical_module_environment`, append the `issues`.

**Cuts, in order.**

1. Re-attribute with the seven phase rows on the current main (the landed cuts
   moved the split) and retain the numbers in `benchmarks/results/`.
2. Cut the loop that dominates:
   - If `prepare_callables` dominates: use the accepted graph's existing module
     grouping to process one module's callables while owning its base locally,
     writing back once rather than returning the record per header. If another
     header family lacks that grouping, probe one pass into a `List[List[Int]]`
     indexed by base position, then process each module locally. Same shape
     for trait and implementation loops if their rows are large.
   - If `prepare_bases` dominates: split `prepared_module_environment_base_state`
     so the parts that depend only on graph-wide inputs (`type_headers`, the
     accepted alias, record, union and global tables) are built once before the
     loop as a `PreparedModuleSetup` record and borrowed; check whether
     `prepare_type_alias_authority`, `prepare_record_type_authority` and
     `prepare_union_type_authority` rebuild anything from the whole table per
     module rather than selecting the module's slice.
   - If `prepare_products` dominates: make the hit path of
     `module_header_product_table_ensure` allocation-free and ensure each import
     module once by collecting the distinct import module ids first.
3. Stop threading the state through `bases.set`: update a local written back
   once per module, not once per header. Check with `--dump-core-after=perceus`
   on a small program that the update is in place.

**Acceptance.** The `global_prepare` row is the metric. The `module_bodies` row
must not rise: the environments this function builds are read by every body
through `typecheck_session_for_prepared_module`, so cheaper to build but more
expensive to read is not a win. Identical C; small program not regressed;
instructions within 0.3%. Retain the before/after row and attribution split in
`benchmarks/results/`; use a short headline in the squash commit.

**Tests.** `test_typecheck_decl.brp` (global ordering and cycle diagnostics),
`test_global_header_dependency_profile_benchmark.brp`,
`test_typecheck_body_metrics.py` (the `global_*` rows and counts),
`test_accepted_record_authority.brp`, `test_accepted_union_authority.brp`,
`test_accepted_alias_authority.brp`, and the `should_fail` fixtures that mention
globals, imports, traits or cycles. Add one test where a global initializer
references a callable from an imported module and one where a module declares a
trait, an implementation and a callable so all four per-header loops touch the
same base, asserting the same diagnostics before and after.

**Traps.** The order of diagnostics inside one module follows the order the loops
append errors to the base state (trait errors, then callable errors after
`callable_error_start`, then implementation errors); regrouping the loops per
module must keep that order or the `should_fail` fixtures move.
`callable_error_start` is read after the preliminary trait authority loop and
`callable_errors` is sliced from it; if the state is no longer threaded through
`bases`, compute both from the local. The global pass sees the initial global
table on purpose; keep it an input of the per-module part, never of anything
shared with body checking. `allow_debug_only_calls` is constant per compile and
belongs in the shared setup; `prepared_module_environment_accepts_request`
compares it per environment, so keep it on the module facts too. Do not move
CTFE work: `ctfe_globals` runs after completion and reads the completed table.
Keep `active_rows.sort_by(source_name_id)` stable within each completed module
so equal-name overloads retain accepted header order.

## Fast loop and measurement

Use [Worker Checklist](../WORKER_CHECKLIST.md) for setup and serial execution,
and the [self-compile protocol](../../benchmarks/README.md#self-compile-measurement-protocol)
for matching source/binary provenance, frozen self input and checksum-pinned
small input, FRESH `-O2` builds, and parent/candidate samples. The source
refactor must produce byte-identical C on both programs (`--require-identical`).
The harness acceptance row is authoritative; instrumented allocation totals
are attribution only.

For the narrow loop, compile the frozen `blorp/src/main.brp` with its matching
`--std-dir`, `--stop-after=lower --no-format`, `BLORP_TYPECHECK_BODY_METRICS=1`
and `BLORP_MEMORY_STATS=1`. Watch `BLORP_TYPECHECK_PHASE` (`global_prepare`,
its seven `prepare_*` subrows, `module_bodies`) and subtract
`typed_frontend_start` allocations from `typed_frontend_complete`.
`--stop-after=lower` is the earliest supported Core stop. Per-helper exact
profiling is described in [Developer Guide](../DEVELOPMENT.md#function-profiling-and-flame-graphs);
require `PROFILE_DIAGNOSTICS` with `calls_completed > 0` before trusting rows.

Acceptance also requires retired instructions no more than +0.3%, no
small-program regression and unchanged diagnostic text/order. A neutral cut
is reported and dropped. Run the named tests above plus `test_infer.brp` and
`type_system/test_env.brp`, relevant `*_profile_benchmark.brp` suites,
`scripts/compiler-check --changed`, and serial `compiler-blorp`,
`compiler-tools` and `lsp` gates.

## Stop rules learned from rejected cuts

- Attribute before cutting: dictionary probes do not allocate, and
  `TypedExprInfo`/`ValueSlot` boxes accounted for at most 2.9% of the typed
  frontend. A new body-loop issue must name its helper's calls, allocations
  and allocations per call from the ranking or fresh attribution.
- `Dict[String, ...]` to dense ids was allocation-neutral and +0.476%
  instructions on the small program. Cleaner keys alone are not a speed claim.
- Returning an unchanged parameter on one path defeats in-place update at
  callers. Use a record update or assignment-site local; inspect Core reuse.
- Structs inside `Option`, union payloads or lists of records are boxed.
  Reading a whole inline struct list element copies it; read the needed field.
- Shared dictionaries inside threaded state records copy on updates. Build
  immutable facts once, borrow them, own accumulators locally.
- Allocation rows and quiet retired-instruction samples are evidence; one
  apparent 50% improvement was machine noise.

Broader state/module-view ownership changes belong to the
[Identity roadmap](../IDENTITY_ROADMAP.md), "Frontend facts".
