# Core Identity Migration

Goal: after lowering, a variable is identified by an integer, not by its
spelling. Strings leave Core except for diagnostics, dumps and the C
identifier, which read the spelling from one table. Each step below lands on
its own, is gated by a measurement taken before it starts, and states its
oracle. Read [`WORKER_CHECKLIST.md`](WORKER_CHECKLIST.md) first; its rules
(no `git stash`, no parallel test binaries, foreground gates, one squash
commit per task) apply throughout.

Anchors are against main at `f7fb1cd6` (2026-09-22). Line numbers drift;
grep for the name.

## What is true today

`CoreVar` (`stage_09_core/ir.brp:668`) is `{ name: String, uniq: Int,
def_id: Option[Int] }`. Lowering mints every local and parameter through one
helper, `core_var` at `stage_08_core_lower/lower.brp:630`, with `uniq = 0`
and `def_id = None` (73 call sites); `def_id` is set only for globals,
callables and constructors. The SSA desugar pass later uses `uniq` as an
assignment version, so after it identity is the pair name plus `uniq` for
reassigned locals and the bare name for everything else. Because that pair
is not unique per binder, every pass that mints a synthetic variable bakes a
counter or a source offset into the name string to keep it distinct (about
thirty passes with a private `core_var(name)` helper: `perceus.brp:14216
synthetic_binding_var`, `8706 mutable_assignment_temp_var`, `tuple_sroa.brp:227`,
`tailrec.brp:829`, `ssa.brp:1215`, `std_inline.brp:471`, `match_projection.brp:1226`,
`record_update.brp:519`, the `synth_*` files), and the C identifier is
derived from the name alone (`stage_10_backend/emit.brp` `c_var_name`, via
`c_naming.brp:154 c_local_name`).

Consequences that this migration removes:

- Perceus resolves ownership by name. `count_uses` (`perceus.brp:5032`),
  `summarize_linear_ownership_uses` and its non-binding variant
  (`4887`, `4286`), `rewrite_mutable_assignments` (`11337`) and
  `protect_repeated_consumes` (`13467`) match `variable.name == name`.
  `BorrowedOwnerCatalog` (`811-816`) keys candidates by name and sets
  `has_unresolved_identity` whenever any parameter has `def_id = None`,
  which is every ordinary parameter, so `borrow_expr_aliases_param`
  (`4025`) takes the name-only scan on nearly every region.
- Closure capture is by name. `FreeVar` (`closure.brp:242`) and
  `CoreClosureCapture` (`ir.brp:1145`) carry `{ name, typ }`;
  `free_vars_expr` (`1797`) checks a `List[String]` of bound names; the
  name-only comparison `same_var_name` (`2710`) is required there because
  callers run shadow checks before descending.
- DCE's value index (`dce.brp:237-244`) is keyed by `(def_id, uniq)`, so a
  local with `def_id = None` is never deduplicated.

Already landed (2026-09-21): one public equality `core_var_equal`
(`ir.brp:685`, name plus `uniq`; `def_id` never overrules it) replacing eight
private copies; one definition-id allocator on `CorePassState.next_def_id`
replacing two whole-program rescans, which also fixed a real bug: the late
pipeline seeded the frontier at zero and reseeded from surviving
declarations after DCE, recycling ids of deleted declarations. That change
altered closure symbol names in the emitted C; identity was proven with
`benchmarks/normalize_generated_c_symbols`, which is the oracle for any step
that changes id allocation.

## Lessons that shape every step

- Attribute before cutting. Three typecheck cuts and one Core cut were
  reverted this week because their targets were estimates. The wins came
  from measured mechanisms: a closure built per traversal visit, a
  whole-program rescan, a duplicated environment build. Each step below
  names the profile it needs before it starts.
- Indexes of declaration objects do not pay. The program-facts attempt
  (branch `core/program-facts`, parked) showed a single linear walk over
  about sixteen thousand declarations is already cheap, and an index that
  holds bodies goes stale after passes that rewrite bodies without changing
  the declaration count. If a table is needed, it holds ids and indices and
  consumers read bodies from the program.
- Dictionary probes do not allocate. Replacing a `Dict[String, ...]` with an
  id-keyed list is an instruction and correctness change; do not claim an
  allocation target for it.
- The identity oracle is byte-identical C, except where a step changes id
  allocation or C identifiers; then it is normalized C, and the runtime,
  leak and sanitizer gates carry the rest.
- Ownership of files: while `perf/lowering-type-sharing` is open, do not
  edit `lower.brp`; while `core/central-traversal-*` is open, do not edit
  `traverse.brp`, `ssa.brp`, `std_inline.brp` or `tuple_sroa.brp`.

## Measurement

```bash
base=$(git rev-parse origin/main)
input=$(benchmarks/self_compile_measure freeze --rev "$base")
BLORP_CLI_C_OPTIMIZATION=-O2 make && scripts/compiler-build-status
benchmarks/self_compile_measure --label <step>-parent --input-rev "$base" --samples 1 --output /tmp/<step>-parent.json
benchmarks/self_compile_measure --label <step> --input-rev "$base" --samples 3 \
  --baseline /tmp/<step>-parent.json --output /tmp/<step>.json --require-identical
```

Rows that matter: `pass_perceus_complete`, `pass_closure_complete`,
`core_lowering_complete`, total allocations, retired instructions. Core is
compiled into `bin/blorp`, so the bootstrap-built harness observes every
step directly. Per-helper allocation profiles follow the model of
`benchmarks/compiler_dce_facts_builder_allocations` and
`benchmarks/profiles/dce_facts_builder_allocations.brp` (commit `94d34bdc`):
a profile program that runs the production entry point on the frozen
self-compile and reports calls, allocations and allocations per call per
helper, using the runtime's allocation counter from `standard_library/src/memory.brp`.

Gates for every code step, each under `benchmarks/self_compile_measure lock --`:
the owning suites (`test_core_perceus.brp`, `test_core_closure.brp`,
`test_core_dce.brp`, `test_core_lower.brp`, `test_core_json.brp`, plus the
pass's own), `scripts/compiler-check --changed`, `scripts/test --serial
compiler-blorp compiler-tools`, `scripts/test leak`, `scripts/test
compiler-core-sanitize`. The `BLORP_GATE_RESULT` line is the verdict.

## Steps

| # | Step | Gate to start | Oracle | Expected effect |
| --- | --- | --- | --- | --- |
| 0 | Perceus per-helper allocation profile | none | n/a | the table that sizes 3 and 5 |
| 1 | Lowering mints a unique `uniq` per binder | `perf/lowering-type-sharing` landed | identical C | complete identity at Core entry; instructions flat |
| 2 | Contract before Perceus | 1 landed | identical C | any pass that mints without identity fails loudly |
| 3 | Perceus keys by identity | 0 and 2 landed; 0 names the helpers | identical C | whatever 0 measured; correctness under shadowing |
| 4 | Closure captures carry identity | 2 landed | identical C | string compares gone; latent shadowing bugs closed |
| 5 | Synthetic binders from the shared allocator, no name baking | 2 landed; 0 counts the strings | identical C until 6 | the synthetic-name strings 0 counted |
| 6 | C identifiers from identity; spellings in one table | 5 landed | normalized C plus runtime, leak, sanitizer gates | strings out of Core |

Steps 3 and 4 can run in parallel after 2. Step 5 can run alongside 3 if it
avoids `perceus.brp`.

### Step 0: Perceus per-helper allocation profile

Build `benchmarks/compiler_perceus_allocations` and
`benchmarks/profiles/perceus_allocations.brp` on the DCE model. Run
`insert_drops_program` (`perceus.brp:26165`) on the frozen self-compile's
late Core (dump it with `--dump-core-after=dict_literal_ownership`, the pass
before Perceus, and load it through the Core JSON decoder in `ir.brp`, or
drive the pipeline to that point in the profile program; say which). Report
calls, allocations and allocations per call for at least: `build_env`
(`1479`) and `infer_user_call_contracts` (`21236`); `build_borrowed_owner_catalog`
(`22156`) and the number of regions it is built for; `count_uses` and its
`count_uses_in_*` helpers (`2308-2495`); the two `summarize_linear_ownership_uses`
variants and `summarize_linear_call` (`2730`) with the frame stack they push;
`rewrite_mutable_assignments` and `mutable_assignment_temp_var`; `protect_repeated_consumes`;
`stabilize_nested_assignment_rhs` (`10239`); `schedule_contract_linear` (`19506`);
`normalize_borrowed_boundaries` (`24625`); `synthetic_binding_var` and every
other `CoreVar` constructor in the file (`5435`, `8703`, `14216`, `14929`,
`14937`); and the `OwnershipUseSummary` records built per node (`2000-2005`).
Also count the fallbacks the existing `perceus_work_*` counters expose
(`250-300`, consumed by `work_profile.brp`), split by cause: missing
identity, unsupported shape, missing ownership summary.

Deliverable: `benchmarks/results/perceus_allocation_attribution_<date>.md`
with the table and the exact commands, plus the profile program, as one
commit with no production change. Then write, at the top of that file, the
go/no-go for step 3 and step 5: which helpers exceed 5% of the Perceus row
and whether identity or name strings are among them.

### Step 1: lowering mints a unique `uniq` per binder

Where: `core_var` (`lower.brp:630`) and the 73 sites that call it;
`core_lower_params` / `core_lower_param` (`4806-4829`) for parameters;
the binder sites for `let`, match bindings, loop binders, lambda parameters
and the record-update temp at `2017-2021` (which sets `uniq` to a source
offset today). `CoreLowerContext` (`473`) gains a `next_uniq: Int` counter,
minted per binder from 1 upward, and a scope stack keyed by the source name
id (the typed AST's `ParsedIdentifier` carries only text; resolve the id at
the lowering boundary through the same source-name table typecheck uses, or
a per-function `Dict[String, List[Int]]` if that table is not reachable; say
which and why) so a use resolves to the innermost binder's `uniq`. Shadowing
therefore yields different pairs. The SSA desugar (`ssa.brp:1215
fresh_version`) keeps minting fresh versions, seeded above the lowering
counter, so a version never collides with a binder id. Globals and callables
keep `uniq = 0` and their `def_id`.

Oracle: byte-identical C on both programs. Every pass compares by
`core_var_equal` (name plus `uniq`) today, and today every local has
`uniq = 0` except SSA versions, so this is the one step where a mistake
shows as a diff immediately: a use bound to the wrong binder changes the
pair and downstream passes change their answer. Tests: extend
`test_core_lower.brp` with shadowing in nested scopes, a match binding
shadowing a parameter, a lambda parameter shadowing a `let`, and a loop
binder reused after the loop, asserting the `uniq` values on binders and
uses. `test_core_json.brp` must still round-trip.

Expected effect: none on allocations (an Int field per var already exists).
Instructions flat. The value is the invariant step 2 asserts.

### Step 2: contract before Perceus

A debug-only check in `pass_runner.brp`, gated by `--check-invariants`
(the existing `control.check_invariants`), run before the Perceus pass:
every binder in a function has a distinct pair, every `VarExpr` names a
binder in scope or a global or callable with a `def_id`, and no two binders
in a function share a `uniq` unless one is an SSA version of the other. It
fails with the function name, the binder kind and the location. The
`--check-invariants` self-compile is the acceptance run (the string-operator
desugar failure that blocked that run was fixed in `30998844`). Also add the
same check after each pass that mints binders, so the pass that forgets the
allocator is named, not Perceus.

Oracle: identical C (no production change). Expected effect: none;
correctness.

### Step 3: Perceus keys by identity

Only the helpers step 0 named. Candidates: `count_uses` and the
`summarize_linear_ownership_uses` family take a `CoreVar` and compare with
`core_var_equal`; `rewrite_mutable_assignments` and
`protect_repeated_consumes` stop dropping to `target.name`;
`BorrowedOwnerCatalog.candidate_ids_by_name` becomes a list indexed by
`uniq` within the region (or a `Dict[Int, List[Int]]` if the range is
sparse; measure); `has_unresolved_identity` and the alias fallback that
exists only for it are deleted, and the fallbacks for unsupported shapes
stay, now counted separately by the `perceus_work_*` counters. Do not
convert `PerceusEnv`'s global and constructor lookups here; they are keyed
by declaration names, not variables, and they are built once.

Oracle: byte-identical C on both programs. If a helper's rewrite changes
the C, the old name-based answer and the new identity-based answer differ on
a shadowed name, which is a bug in the old code; report the function and the
shape and keep the change only with a test that pins the new behaviour and a
runtime gate that exercises it. Expected effect: the allocation share step 0
measured for the converted helpers, plus the fallback counters at zero for
the identity cause.

### Step 4: closure captures carry identity

`FreeVar` and `CoreClosureCapture` carry a `CoreVar`; `free_vars_expr`'s
bound list is a `List[CoreVar]` compared with `core_var_equal`;
`same_var_name` and the shadow-check-before-descend discipline go away
because a shadowed name is now a different pair. `CoreClosureAbi.moved_captures`
(`ir.brp:1156`) follows. JSON codec and `test_core_json.brp` updated;
`test_core_closure.brp` gains a capture-under-shadowing case.

Oracle: byte-identical C. Expected effect: string compares gone in closure
conversion; allocation flat.

### Step 5: synthetic binders from the shared allocator

Every pass with a private `core_var(name)` helper mints `uniq` from the
allocator on `CorePassState` (extend it with `next_uniq` next to
`next_def_id`, threaded the same way; passes that mint take and return it)
and stops baking counters and source offsets into the name. Names become
plain prefixes (`__assign`, `__elem`, `__view`). Until step 6, the C
identifier still comes from the name, so the emitter must append `uniq`
when a name is not unique within a function; do that in `c_var_name` as a
transitional rule and remove it in step 6.

Oracle: byte-identical C is not available (identifiers change spelling);
use normalized C plus the runtime, leak and sanitizer gates. Expected
effect: the name-string allocations step 0 counted (one to three per
synthetic binder).

### Step 6: C identifiers from identity; spellings in one table

`c_var_name` derives the C identifier from `uniq` (with the source name kept
as a suffix for readability of the emitted C, from the table); diagnostics,
`--dump-core-after` and the Core JSON read the spelling through one accessor
on a per-program name table (id to `String`), the only place a variable's
spelling lives after lowering. `CoreVar.name` is deleted last, after the
accessor has replaced every read; the exhaustiveness errors and the 39 files
with their own `match expr:` will find the rest.

Oracle: normalized C plus the full gates; the diagnostic fixtures under
`blorp/test/compiler` must print the same text. Expected effect: strings out
of Core; the remaining `Dict[String` in `perceus.brp`, `closure.brp` and
`dce.brp` that key on variables are gone.

## What this roadmap does not include

The definition table for callables and types (the parked
`perf/definition-table` and `core/program-facts` branches). Both measured
as a cost, for the reason in the lessons above. If a later profile shows a
pass paying for name-keyed declaration lookups, the table is columns of ids
and indices only, built once after lowering and rebuilt after the passes
that mint declarations, and the consumer reads bodies from the program.
