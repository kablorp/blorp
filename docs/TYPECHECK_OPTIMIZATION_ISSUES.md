# Typecheck Optimization Issues

Issues for reducing the time and allocations of the typed frontend on the
compiler's own self-compile. The first execution wave ran five issues (T-A
to T-E); one landed, two were measured and rejected, two were blocked. Their
results are recorded verbatim below, and the live work is now two issues: a
mandatory per-helper attribution pass, and the second cut of T-D. Each issue
names the exact functions and records to change, the order of cuts, the fast
loop, the acceptance numbers, and the traps that cost earlier attempts a
cycle. Read [`WORKER_CHECKLIST.md`](WORKER_CHECKLIST.md) first; the rules
there (no `git stash`, no parallel test binaries, foreground gates, one
squash commit per task) apply to every issue below.

All anchors are against main at `de865651` (2026-09-21). Line numbers drift;
the function and record names do not, so grep for the name if a line is off.

## First wave results

Recorded as reported by the workers. Numbers are `-O2`, frozen self-compile
input, allocation rows from `benchmarks/self_compile_measure` unless the
entry says otherwise.

- **T-A rejected.** Dense authority tables: 0% allocation change,
  small-program instructions +0.476%. `SourceNameId` buckets: +18
  allocations. Both reverted. Dictionary probes do not allocate, so T-A was
  never an allocation lever.
- **T-B blocked** and retired as written.
- **T-C rejected.** Correct unboxing of the value slot saved 550,709
  typed-frontend allocations, 1.406%, against an 8% target; the full split's
  ceiling was 2.889%. Reverted. The per-node info records are not the mass.
- **T-D cut 1 accepted.** `global_header_completion` splits as
  `global_plan` 6,701, `global_prepare` 5,201,772, `global_pending` 0,
  `global_annotated` 1,421,126 allocations. Preparation
  (`prepared_module_environments` in `stage_06_typecheck/decl.brp`) is 78.3%
  of global completion. Identical C. Measurement in
  `benchmarks/results/self_compile_typecheck_global_attribution_O2_2026-09-21.json`
  once that worktree (`/Users/keithphilpott/.codex/worktrees/typecheck-t-d`)
  is landed.
- **T-E blocked** and retired as written.

What the wave taught, and what the live issues are built on:

- Two of the three measured issues named a structure from reading the code
  and were wrong about where the allocations are. Neither dictionary probes
  nor per-node info boxes are the mass. No further cut is written from code
  reading alone; every cut names a helper and an allocation count from the
  attribution issue below.
- The one accepted result came from attribution first: T-D cut 1 spent its
  budget on phase rows and found that a step nobody had named
  (`prepared_module_environments`) is more than three quarters of a phase
  that was assumed to be inference.
- `global_pending` is zero on the self-compile: no unannotated global in
  the compiler or the standard library reaches the pending loop, so the
  "pending inference dominates" branch of the old T-D cut 2 is dead.

## Shared context

### Where the phase stands

Frozen self-compile input `10acd6104`, compiler built at `-O2`, one run with
`BLORP_TYPECHECK_BODY_METRICS=1` (the metrics inflate allocation totals; use
them for attribution, and the harness rows below for acceptance). The four
`global_*` rows are children of `global_header_completion`, added by T-D
cut 1 and measured in that worktree; do not add a parent and its children
together.

| typecheck phase row | wall | allocations |
| --- | ---: | ---: |
| `indexed_graph` | 251 ms | 0.10M |
| `bound_modules` | 190 ms | 1.83M |
| `callable_headers` | 66 ms | 1.17M |
| `global_header_completion` | 834 ms | 6.62M |
| &nbsp;&nbsp;`global_plan` | | 6,701 |
| &nbsp;&nbsp;`global_prepare` | | 5,201,772 |
| &nbsp;&nbsp;`global_pending` | | 0 |
| &nbsp;&nbsp;`global_annotated` | | 1,421,126 |
| `graph_completion` (contains `global_header_completion`) | 848 ms | 6.76M |
| `module_bodies` (13,314 bodies) | 1,847 ms | 27.66M |

Harness rows without metrics (`benchmarks/self_compile_measure`, same input):
`source_discovery_complete` 8.47M allocations, `typed_frontend_complete`
about 34M, so the typed frontend itself is about 25.6M allocations and
3.1 s wall at `-O2`. Inside the body loop the earlier sample split was:
generated code 30%, reference counting 27%, cancellation cleanup frames
18.5%, allocation 7.5%, string and dict lookups 5%. The zonk skip for bodies
with no metas (`a92f30bda`) already landed; per-node zonk reuse was measured
negative and is not an option here. T-C established that the per-node
`TypedExprInfo` and `ValueSlot` boxes are at most 2.889% of the typed
frontend; the remaining body-loop mass is in the helpers, which is what the
attribution issue ranks.

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

Once T-D cut 1 is landed the same run prints the `global_plan`,
`global_prepare`, `global_pending` and `global_annotated` rows with their
`globals_total`, `globals_annotated`, `globals_pending`, `pending_project`
and `pending_dependency` counts (format in `benchmarks/README.md`, "Global
completion also reports ..."). Until then, build the T-D worktree to see
them.

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
cut lands when the issue's named allocation row drops by at least the
issue's target, retired instructions do not rise beyond 0.3%, and the small
program does not regress. A neutral result is reported and dropped, not
argued; T-A and T-C are the precedent, and both reports were useful.

### Correctness loop

```bash
bin/blorp test --timeout 300 blorp/test/compiler/stage_06_typecheck/test_infer.brp \
  blorp/test/compiler/stage_06_typecheck/test_typecheck_decl.brp \
  blorp/test/compiler/stage_06_typecheck/type_system/test_env.brp
scripts/compiler-check --changed --plan            # read-only: what will run
scripts/compiler-check --changed
scripts/test --serial compiler-blorp compiler-tools lsp
```

The diagnostic fixtures (`fixtures/typecheck/should_fail`, 589 files, and
`infer_fixtures/infer/should_fail`, 271 files) are part of the identity
oracle: diagnostic text and order must not change. The
`*_profile_benchmark.brp` suites under `stage_06_typecheck/` are existing
perf regression tests; run the ones that name the structure you touch.

### Traps seen this month

- Naming the structure before measuring it. T-A (dictionaries) and T-C
  (per-node boxes) each cost a cycle proving a hypothesis wrong that a
  per-helper allocation count would have ruled out in an hour. Dictionary
  probes do not allocate. A boxed record on every node is visible but
  small when the helpers around it allocate lists and closures.
- A helper that returns its parameter unchanged on one path defeats
  in-place update everywhere it is called (the reuse gate assumes aliasing).
  Return a record update, or update at the assignment site from a local.
- `Dict[String, ...]` where an `Int` id exists is a cleanliness issue, not
  an allocation lever (T-A). Do not write an allocation cut around one.
- A struct inside an `Option`, a union payload, or a `List` of records is
  boxed; converting a record to a struct there saves nothing.
- Reading a whole struct out of an inline `List[struct]` copies it; read the
  field.
- Threading a state record through helpers and returning it copies any
  shared dictionary inside it on every update. Build facts once, borrow
  them, own accumulators as locals.
- Wall-clock claims. A "50% win" this month was machine noise. Allocation
  rows and retired instructions only.
- Instruction regressions on the small program. T-A's dense tables were
  allocation-neutral and still cost +0.476% instructions there; the small
  program row is a gate, not a courtesy.

---

## Issue T-F: Profile body checking per helper (mandatory, runs first)

**Goal.** Produce the ranked list of the top twenty allocating helpers in
`stage_06_typecheck/infer.brp` and `stage_06_typecheck/type_system/` on the
self-compile body loop, with calls, allocations and allocations per call for
each, as a retained benchmark and a results file. Every later typecheck cut
must name a helper and an allocation count from this list. No compiler
change is accepted from this issue other than the counters it needs; the
deliverable is the table.

**Model.** `benchmarks/compiler_dce_facts_builder_allocations` and
`benchmarks/blorp/profiles/dce_facts_builder_allocations.brp` (commit
`94d34bdc`, "Fuse DCE fact updates"). The pair is: a focused Blorp program
under `benchmarks/blorp/profiles/` that builds a deterministic input,
calls `reset_mem_stats()`, runs the function under study once, reads
`get_mem_stats()` (`standard_library/src/memory.brp:21-48`, a `MemStats`
struct whose read allocates nothing), checks output identity, and prints one
value per line; and a bash wrapper under `benchmarks/` that builds at
`-O2` unless `*_SKIP_BUILD=1`, runs the program with `BLORP_TRACK_STATS=1`,
validates every line as an integer, fails on any identity change, caps
`allocations` at an expected value (`*_MEASURE_ONLY=1` to report without the
cap), and prints one `..._ALLOCATIONS schema=1 ... allocations=... ` summary
line. The README entry from that commit (`benchmarks/README.md`, "retains a
focused 512-identity Core expression") is the shape of the documentation.

**Where the numbers come from.** The function profiler
(`bin/blorp compile --profile --profile-mode exact --profile-module <m>`,
flags in `blorp/src/lib/cli_args.brp`; `blorp_ProfileEntry` in `runtime.c`
~37983-37987) records `total_ns`, `self_ns` and `call_count` per function
and nothing about allocations; its "Function Profile" table (`runtime.c`
~39217, columns Inclusive, Self, Self %, Calls, Avg self) is time only. The
managed-allocation counter is process-global (`get_mem_stats`,
`typecheck_body_metrics_allocations`). So today the repo can give you calls
per helper, or allocations for one window, but not allocations per helper.
This issue adds that.

**Cuts, in order.**

1. Self allocations per profiled function. Add `self_allocations` to
   `blorp_ProfileEntry` next to `self_ns`, attributed the same way exact
   timing attributes self time: read the allocation counter at frame enter
   and exit, subtract the callees' inclusive counts, add the remainder to the
   frame's function. Only in `BLORP_PROFILE_MODE_EXACT`; the `calls` mode
   stays as it is. Print it as two more columns (`Self allocs`,
   `Avg allocs`) at the end of the "Function Profile" table and leave the
   existing columns in place and in order (`benchmarks/compiler_typecheck_profile`
   and its README recipes read the call counts from it). Build the profiled
   compiler with the two-step recipe (bootstrap `compile --no-embed-runtime`,
   then `cc` with `-DBLORP_PROFILE_EXACT_TIMING=1` for both the runtime
   object and the generated C); the Makefile's prebuilt runtime object does
   not define it and an exact probe then reports `functions_observed=0`.
   Check `PROFILE_DIAGNOSTICS` shows `calls_completed > 0` before trusting a
   row.
2. The retained probe. `benchmarks/blorp/profiles/typecheck_body_helper_allocations.brp`
   imports `typecheck_graph` (the entry `benchmarks/compiler_typecheck_profile`
   already drives in-process through
   `blorp/benchmark/compiler/compiler_typecheck_profile.brp`) and checks a
   fixed corpus: the frozen self-compile input is too large for a gate, so
   the program builds a deterministic synthetic module set the way the
   existing profile does, sized so one run is under ten seconds at `-O2`,
   and prints body count, diagnostic count, a hash of the typed JSON, then
   the `MemStats` fields. `benchmarks/compiler_typecheck_body_helper_allocations`
   wraps it exactly as the DCE wrapper does: identity lines must match,
   `allocations` is capped, `BLORP_TYPECHECK_HELPERS_MEASURE_ONLY=1` lifts
   the cap. This gives the gate. It does not give the ranking; the ranking
   comes from cut 3 on the real input.
3. The ranking. Run the profiled compiler from cut 1 on the frozen
   self-compile input with `--stop-after=lower`, restrict to
   `--profile-module` covering `stage_06_typecheck/infer` and
   `stage_06_typecheck/type_system/*`, and write
   `benchmarks/results/typecheck_body_helper_allocations_O2_<date>.md`
   with the top twenty rows by `self_allocations`: helper, file, calls,
   allocations, allocations per call, share of `module_bodies` allocations.
   Add a second table with the top twenty by allocations per call whose
   call count is above 1,000 (the expensive-but-rare helpers hide in the
   first table). Keep the raw profile output next to it as `.tsv`. State
   the compiler commit, the input revision and the toolchain line from
   `bin/blorp --version` at the top of the file.
4. Land cuts 1 and 2 as one squash commit with the two tables in the
   results file; the wrapper joins the `compiler-tools` gate the way the
   DCE wrapper did. The results file is the artifact every later issue
   cites.

**Acceptance.** Cut 1 is identical C (`--require-identical` on the harness
with the profiler off) and zero allocation change in the unprofiled build.
Cut 2's wrapper passes with the cap set to the measured value. Cut 3's
results file exists and its top-twenty rows account for a stated share of
`module_bodies` allocations; if that share is under 50%, widen to the top
forty and say so. Nothing in this issue needs a self-compile allocation win.

**Tests.** `blorp/test/compiler/stage_06_typecheck/support/test_typecheck_body_metrics.py`
(row format), whatever parses the "Function Profile" table or the
`PROFILE_DIAGNOSTICS` line (grep both under `blorp/test/` and
`benchmarks/`), and the new wrapper itself.

**Traps.** Self attribution across task fibers: the exact profiler already
handles frames across yields for time (`scheduled-active`); allocations must
follow the same frame stack, or a helper that yields inherits another
fiber's allocations. Global initializers folded by CTFE do not allocate at
runtime; a helper called only from a folded initializer shows zero and that
is correct. The metrics build (`BLORP_TYPECHECK_BODY_METRICS=1`) inflates
totals; run the ranking with it off and use `--profile` only. Do not rank
by `self_ns`; time rows on this machine moved by 50% between runs this
month.

---

## Issue T-D cut 2: Build module environment preparation once

**Goal.** `global_prepare` is 5,201,772 allocations, 78.3% of
`global_header_completion`, and all of it is `prepared_module_environments`
(`stage_06_typecheck/decl.brp:7551`), called once per compile from
`complete_planned_global_headers` (`decl.brp:8263`). It prepares one
canonical environment per module and its result is carried to body checking
in `TypecheckGraphFacts.prepared_environments` (`decl.brp:8498-8505`), so
the function is not run twice; it is one function that rebuilds the same
per-module setup once per module, once per trait header, once per callable
header and once per implementation header, through a `bases` list it
updates by `bases.set(index, {...})`. Move the setup that is the same for
every module in front of the loops, build the per-module state once, and
stop copying the base record per header. Target: the `global_prepare` row
down 40% or more (about 2.1M allocations), the `typed_frontend_complete`
harness row down 1.5% or more; identical C.

**Where.** `decl.brp`, all inside `prepared_module_environments`
(7551-7920):

- Setup derived before the loops (7559-7585): `callable_headers`,
  `type_headers`, `bound_graph`, `definition_table`, the `modules` list
  (target concatenated with every bound module), `base_positions_by_module_id`
  and an empty `header_products` table. These are already hoisted; nothing
  to do here except pass them down.
- Loop 1 (7590-7604): `module_header_product_table_ensure` per module and
  per visible import per module. A module imported by forty modules is
  ensured forty times; the hit path must be checked for allocation
  (the returned table, the `bound_module_visible_import_modules` list).
- Loop 2 (7605-7631): `prepared_module_environment_base_state`
  (7437-7515) per module. Inside it, per module: a fresh
  `TypecheckState`, `typecheck_prescan_known_type_names`, three
  `prepare_*_type_authority` calls that each thread and return the state,
  `accepted_global_authority_for_module`, `register_module_view_type_facts`,
  `module_header_product_table_section` for the local section,
  `typecheck_register_import_modules_from` over every visible import, and
  `typecheck_install_module_header_section`. Then `bases.append` of a
  `PreparedModuleCallableBase` that holds the whole state plus
  `local_type_names_from_decls` over the module's declarations.
- Loops 3 to 6 (7632-7860): per trait header, per base (preliminary trait
  authority), per callable header, per implementation header, each doing
  `bases.set(index, { base | state = ... })`. Every `set` of a record with
  a `TypecheckState` inside it is a record update on a shared list
  element; whether it copies depends on the reuse gates (see the traps in
  the shared context), and `prepare_accepted_module_callable` returns a
  new base per callable header (13,000 or more callables).
- Loop 7 (7860-7920): per base, install the callable and trait
  authorities, `prepared_canonical_module_environment` (7516), and the
  `issues` append.

**Cuts, in order.**

1. Attribute inside `global_prepare` before touching it. Add temporary
   `typecheck_phase_mark` / `record_typecheck_phase` rows around each of
   the seven loops named above: `prepare_products`, `prepare_bases`,
   `prepare_traits`, `prepare_trait_authority`, `prepare_callables`,
   `prepare_impls`, `prepare_environments`. One fast-loop run in the T-D
   worktree (or on main once it lands); put the seven numbers in the commit
   body. If T-F has landed, cross-check against its ranking for
   `prepare_accepted_module_callable`, `typecheck_register_import_modules_from`
   and the three `prepare_*_type_authority` helpers. Keep the rows if they
   cost nothing with metrics off (a disabled mark is one probe call).
2. Cut the loop that dominates:
   - If `prepare_callables` dominates: `prepare_accepted_module_callable`
     is called once per callable header and returns a whole
     `PreparedModuleCallableBase`, which `bases.set` then stores. Group the
     callable headers by owner module first (one pass over
     `callable_header_graph_callables` into a `List[List[Int]]` indexed by
     base position), then process each module's callables in one call that
     owns the base as a local and appends to `callables` without returning
     the record per header. Same shape for the trait and implementation
     loops if their rows are large.
   - If `prepare_bases` dominates: the per-module setup in
     `prepared_module_environment_base_state` is the "shared pre-loop
     setup" this cut is named for. Split it: the parts that depend only on
     graph-wide inputs (`type_headers`, the accepted alias, record, union
     and global tables) are built once before the loop as a
     `PreparedModuleSetup` record and borrowed; the per-module part
     (prescan, binding diagnostics, the module's own authorities, import
     registration) reads from it. In particular check whether
     `prepare_type_alias_authority`, `prepare_record_type_authority` and
     `prepare_union_type_authority` rebuild anything from the whole table
     per module rather than selecting the module's slice.
   - If `prepare_products` dominates: make the hit path of
     `module_header_product_table_ensure` allocation-free and ensure each
     import module once by collecting the distinct import module ids first.
3. Stop threading the state through `bases.set`. Whatever loop you cut,
   the base list update `bases = bases.set(index, { base | state = ... })`
   should become an update of a local that is written back once per
   module, not once per header. Check with `--dump-core-after=perceus` on
   a small program that the update is in place (the reuse gate notes in
   the shared traps).
4. Measure the `global_prepare` row with the fast loop after each cut, then
   run the acceptance harness. Land as one squash commit with the row before
   and after and the cut-1 split in the body.

**Acceptance.** The `global_prepare` row is the metric: down 40% or more.
`typed_frontend_complete` down 1.5% or more on the harness. The
`module_bodies` row must not rise: the environments this function builds
are read by every body through `typecheck_session_for_prepared_module`
(7920), so a cut that leaves the environments cheaper to build but more
expensive to read is not a win. Identical C; small program not regressed;
instructions within 0.3%.

**Tests.** `test_typecheck_decl.brp` (global ordering and cycle
diagnostics), `test_global_header_dependency_profile_benchmark.brp`,
`test_typecheck_body_metrics.py` (the `global_*` rows and their counts),
`test_accepted_record_authority.brp`, `test_accepted_union_authority.brp`,
`test_accepted_alias_authority.brp`, and `fixtures/typecheck/should_fail`
cases that mention globals, imports, traits or cycles. Add one test where a
global initializer references a callable from an imported module and one
where a module declares a trait, an implementation and a callable so all
four per-header loops touch the same base, asserting the same diagnostics
before and after.

**Traps.** The order of diagnostics inside one module follows the order
the loops append errors to the base state (trait errors, then callable
errors after `callable_error_start`, then implementation errors); regrouping
the loops per module must keep that order or the should_fail fixtures move.
`callable_error_start` is read after the preliminary trait authority loop
and `callable_errors` is sliced from it; if the state is no longer threaded
through `bases`, compute both from the local. The global pass sees the
*initial* global table (`initial_global_table` at 8263) on purpose; keep it
an input of the per-module part, never of anything shared with body
checking. `allow_debug_only_calls` is constant per compile and belongs in
the shared setup; `prepared_module_environment_accepts_request` (8918)
compares it per environment, so keep it on `module_facts` too. Do not move
CTFE work: `ctfe_globals` runs after completion and reads the completed
table.

---

## Retired issues

Kept as one paragraph each so the next wave does not rewrite them.

- **T-A, dense authority tables.** Rejected on measurement. The
  `Int -> Int` dictionaries in `accepted_global_authority.brp` and
  `accepted_callable_authority.brp` and the `String`-keyed
  `FuncCallableNameBuckets` in `graph/definition_index.brp` are probe cost,
  not allocation cost. Converting them is a cleanliness change to be done
  when a file is open for another reason, not a perf task.
- **T-B, scope lookup keyed by name id.** Blocked; retired as written. The
  `Scope.symbols_by_name: Dict[String, List[Int]]` shape in
  `type_system/env.brp` stands. Given T-A's result the allocation claim in
  T-B (fewer key copies) is unproven; if T-F ranks `scope_lookup`,
  `env_lookup` or `env_symbols_named` in its top twenty, rewrite the issue
  from that row.
- **T-C, flatten the per-node typed facts.** Rejected on measurement:
  1.406% for the value-slot unboxing, 2.889% ceiling for the full split.
  Reverted so the `TypedExprInfo` / `ValueSlot` shape in `infer.brp` is
  unchanged. Not worth a second pass unless the node count itself falls.
- **T-D cut 1, attribute global header completion.** Accepted; see the
  results above. Cut 2 is rewritten above around the row it found.
- **T-E, resolve each identifier once per body.** Blocked on T-B; retired
  as written. The design deliverable (a per-body resolution table read by
  inference and lowering) remains a good idea for the flat typed AST work,
  where it needs its own oracle.

---

## Order and parallelism

T-F runs first and alone; it is the input to every later cut. T-D cut 2
may start in parallel because its row is already attributed by T-D cut 1
and its target is a different phase from the body loop that T-F ranks, but
its own attribution step (the seven loop rows inside `global_prepare`)
must be in the commit body before a loop is rewritten. After T-F lands,
new body-loop issues are written one per helper from its table, each with
the helper's calls, allocations and allocations per call as the opening
line. Each issue is one squash commit on main with the measurement record
folded into the commit body; record the accepted harness JSON under
`benchmarks/results/self_compile_<issue>_O2_<date>.json`.
