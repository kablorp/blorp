# Typecheck Optimization Issues

Open work for reducing the time and allocations of the typed frontend on the
compiler's own self-compile. One issue is live: the remaining module
environment preparation cost. The earlier issues are finished or retired (the
dense authority tables, the scope-lookup rewrite, the per-node typed-fact
flattening and the per-body identifier resolution table were measured and
rejected or retired; the per-helper allocation attribution landed with its
ranking in `benchmarks/results/typecheck_body_helper_allocations_O2_2026-09-22.md`
and `.tsv`). Read [`WORKER_CHECKLIST.md`](WORKER_CHECKLIST.md) first; its rules
(no `git stash`, no parallel test binaries, foreground gates, one squash commit
per task) apply here.

Function and record names are the anchors; grep for them, line numbers drift.

## Rules learned from the rejected cuts

- **Attribute before cutting.** Two cuts named a structure from reading the code
  and were wrong about where the allocations are: dictionary probes do not
  allocate, and the per-node info boxes (`TypedExprInfo`, `ValueSlot`) are at
  most 2.9% of the typed frontend. Every cut names a helper and an allocation
  count from the ranking above or from a fresh attribution. The one accepted
  line of work started from phase rows and found that a step nobody had named
  (`prepared_module_environments`) is more than three quarters of global header
  completion.
- `Dict[String, ...]` where an `Int` id exists is a cleanliness issue, not an
  allocation lever. A dense-table conversion was allocation-neutral and still
  cost +0.476% instructions on the small program; the small-program row is a
  gate, not a courtesy.
- A helper that returns its parameter unchanged on one path defeats in-place
  update everywhere it is called (the reuse gate assumes aliasing). Return a
  record update, or update at the assignment site from a local.
- A struct inside an `Option`, a union payload or a `List` of records is boxed;
  converting a record to a struct there saves nothing. Reading a whole struct
  out of an inline `List[struct]` copies it; read the field.
- Threading a state record through helpers and returning it copies any shared
  dictionary inside it on every update. Build facts once, borrow them, own
  accumulators as locals.
- Allocation rows and retired instructions are the only evidence; a "50% win"
  once was machine noise.

## Fast loop, acceptance and correctness

Fast loop (about 6 s per run; the metrics inflate allocation totals, so use them
for attribution and the harness rows for acceptance):

```bash
base=$(git rev-parse origin/main)
input=$(benchmarks/self_compile_measure freeze --rev "$base")
export BLORP_CLI_C_OPTIMIZATION=-O2
make && scripts/compiler-build-status   # must say FRESH

BLORP_TYPECHECK_BODY_METRICS=1 BLORP_MEMORY_STATS=1 \
  bin/blorp compile --stop-after=lower --no-format \
  --std-dir "$input/standard_library/src" "$input/blorp/src/main.brp" \
  2>&1 >/dev/null | grep -E '^BLORP_(TYPECHECK_PHASE|TYPECHECK_BODY_TOTAL|COMPILER_MEMORY_CHECKPOINT)'
```

`--stop-after=lower` is the earliest stop (it accepts Core stage names only).
The lines to watch are the `BLORP_TYPECHECK_PHASE` rows (`global_prepare`,
`global_annotated`, `module_bodies`, ...) and the `typed_frontend_complete`
checkpoint (`total_allocations` minus the `typed_frontend_start` value).
Allocation counts are deterministic; run once while iterating. The same run
prints one `BLORP_TYPECHECK_BODY` row per body sorted by time. For per-helper
allocations, the exact profiler (`--profile --profile-mode exact
--profile-module <module>`) reports `Self allocs` and `Avg allocs`; build the
profiled compiler with the two-step recipe in `benchmarks/README.md` and check
`PROFILE_DIAGNOSTICS` shows `calls_completed > 0` before trusting a row.

Acceptance:

```bash
# On the untouched parent, using the same -O2 build as the fast loop.
export BLORP_CLI_C_OPTIMIZATION=-O2
benchmarks/self_compile_measure --stage2 --label parent --input-rev "$base" \
  --samples 3 --output /tmp/typecheck-parent.json
shasum -a 256 benchmarks/self_compile/small.brp \
  > /tmp/typecheck-parent-small.sha256
benchmarks/self_compile_measure --stage2 --program small --label parent-small \
  --input-rev "$base" --samples 3 --output /tmp/typecheck-parent-small.json

# After editing, rebuild with BLORP_CLI_C_OPTIMIZATION=-O2 and require FRESH.
export BLORP_CLI_C_OPTIMIZATION=-O2
make && scripts/compiler-build-status
benchmarks/self_compile_measure --stage2 --label candidate --input-rev "$base" \
  --samples 3 --baseline /tmp/typecheck-parent.json \
  --output /tmp/typecheck-candidate.json --require-identical
shasum -a 256 -c /tmp/typecheck-parent-small.sha256 && \
  benchmarks/self_compile_measure --stage2 --program small --label candidate-small \
  --input-rev "$base" --samples 3 --baseline /tmp/typecheck-parent-small.json \
  --output /tmp/typecheck-candidate-small.json --require-identical
```

`--stage2` builds matching normal and diagnostic compilers from each checkout.
Keep the frozen input revision and `-O2` toolchain the same for parent and
candidate, and check the recorded provenance before trusting the comparison.
The checksum check also requires the checkout-local small program to match;
`--input-rev` does not freeze it.
Typecheck source is compiled into `bin/blorp` by the bootstrap, so these
measurements observe your change directly. `--require-identical` is a real
identity check (exit 3 means the typed program changed: a bug, not a result). A
cut lands when the issue's named allocation row drops by at least the issue's
target, retired instructions do not rise beyond 0.3%, and the small program does
not regress. A neutral result is reported and dropped, not argued.

Correctness:

```bash
bin/blorp test --timeout 300 blorp/test/compiler/stage_06_typecheck/test_infer.brp \
  blorp/test/compiler/stage_06_typecheck/test_typecheck_decl.brp \
  blorp/test/compiler/stage_06_typecheck/type_system/test_env.brp
scripts/compiler-check --changed --plan            # read-only: what will run
scripts/compiler-check --changed
scripts/test --serial compiler-blorp compiler-tools lsp
```

The diagnostic fixtures (`fixtures/typecheck/should_fail` and
`infer_fixtures/infer/should_fail`) are part of the identity oracle: diagnostic
text and order must not change. The `*_profile_benchmark.brp` suites under
`stage_06_typecheck/` are existing perf regression tests; run the ones that name
the structure you touch.

## Issue: build module environment preparation once

**Status.** Six bounded preparation cuts have landed: sharing the immutable
builtin environment, owning callable rows locally during header preparation,
precomputing stable trait-implementation lookup facts, batching graph-selective
type facts while their two indexes are locally owned, removing redundant session
scope transitions around imported header sections (-108,340 typed-frontend
allocations, -0.35%; see
[`typecheck_import_scope_transitions_2026-09-25.md`](../benchmarks/results/typecheck_import_scope_transitions_2026-09-25.md)),
and publishing qualified implementation candidates once in the accepted table
(-297,390 allocations, -0.97%, -0.58% retired instructions; see
[`typecheck_qualified_implementation_projection_2026-09-26.md`](../benchmarks/results/typecheck_qualified_implementation_projection_2026-09-26.md)).
All were byte-identical C with `module_bodies` unchanged. The original goal is
not met: base construction and the remaining final-authority indexes still need
independent attribution and cuts.

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
  `prepare_accepted_module_callable` returns a new base per callable header
  (13,000 or more callables).
- Environments loop: per base, install the callable and trait authorities,
  build `prepared_canonical_module_environment`, append the `issues`.

**Cuts, in order.**

1. Re-attribute with the seven phase rows on the current main (the landed cuts
   moved the split) and put the numbers in the commit body.
2. Cut the loop that dominates:
   - If `prepare_callables` dominates: group the callable headers by owner module
     first (one pass over `callable_header_graph_callables` into a
     `List[List[Int]]` indexed by base position), then process each module's
     callables in one call that owns the base as a local and appends without
     returning the record per header. Same shape for the trait and
     implementation loops if their rows are large.
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
instructions within 0.3%. Land as one squash commit with the row before and after
and the attribution split in the body.

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

## Not here

New body-loop issues are written one per helper from the attribution ranking,
each with the helper's calls, allocations and allocations per call as the opening
line. The broader typecheck state and module-view ownership cuts are in
[`IDENTITY_ROADMAP.md`](IDENTITY_ROADMAP.md), "Frontend facts".
