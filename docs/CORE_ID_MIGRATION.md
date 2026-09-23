# Core Identity Migration

Goal: after lowering, a variable is identified by an integer, not by its
spelling. Strings leave Core except for diagnostics, dumps and the C
identifier, which read the spelling from one table. Each step below lands on
its own, is gated by a measurement taken before it starts, and states its
oracle. Read [`WORKER_CHECKLIST.md`](WORKER_CHECKLIST.md) first; its rules
(no `git stash`, no parallel test binaries, foreground gates, one squash
commit per task) apply throughout.

Anchors are against main at `f7fb1cd6` (2026-09-22). Line numbers drift;
grep for the name. Perceus was split into per-phase modules under
`stage_09_core/perceus/` after that anchor (`53fd0c60`, `7dde2e17`), so
anchors below give the current file and symbol name instead of a
`perceus.brp` line number.

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
thirty passes with a private `core_var(name)` helper:
`synthetic_binding_var` (`perceus/results_and_loops.brp`),
`mutable_assignment_temp_var` (`perceus/mutable.brp`), `tuple_sroa.brp:227`,
`tailrec.brp:829`, `ssa.brp:1215`, `std_inline.brp:471`, `match_projection.brp:1226`,
`record_update.brp:519`, the `synth_*` files), and the C identifier is
derived from the name alone (`stage_10_backend/emit.brp` `c_var_name`, via
`c_naming.brp:154 c_local_name`).

Consequences that this migration removes:

- Perceus resolves ownership by name. `count_uses`
  (`stage_09_core/perceus/uses.brp`), `summarize_linear_ownership_uses` and
  its non-binding variant (`perceus/uses.brp`),
  `rewrite_mutable_assignments` (`perceus/mutable.brp`) and
  `protect_repeated_consumes` (`perceus/protect.brp`) match
  `variable.name == name`. `BorrowedOwnerCatalog` (`perceus/borrowed.brp`,
  `build_borrowed_owner_catalog`) keys candidates by name and sets
  `has_unresolved_identity` whenever any parameter has `def_id = None`,
  which is every ordinary parameter, so `borrow_expr_aliases_param`
  (`perceus/borrowed.brp`) takes the name-only scan on nearly every region.
- Closure capture is by name. `FreeVar` (`closure.brp:242`) and
  `CoreClosureCapture` (`ir.brp:1145`) carry `{ name, typ }`;
  `free_vars_expr` checks a `List[String]` of bound names; the name-only
  comparison `same_var_name` (`closure.brp:2069`) is required there because
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

Also landed since, and referenced by steps 3 and 5 below: `bde1af38` moved
the ownership-contract solve (`build_env`, `infer_user_call_contracts`) out
of Perceus into its own pass, `stage_09_core/ownership_contracts.brp`,
which publishes `OwnershipContractFacts` on `CorePassState` for Perceus to
read; `31e61487` removed the engine-metrics hooks that allocated a record
per visit in the ownership-use summary, on the release path, even with
metrics off.

## Landed (steps 0-2)

- **Step 0 — Perceus per-helper allocation profile**: `370f0abb`. Table and
  profile program in
  `benchmarks/results/perceus_allocation_attribution_2026-09-22.md`; sizes
  steps 3 and 5.
- **Step 1 — lowering mints a unique `uniq` per binder**: `54a4e6ef`.
  Byte-identical C; every binder has a distinct `(name, uniq)` pair inside
  its function.
- **Step 2 — binder-identity check before Perceus**: `908d8458`. This
  landed in **report-only mode**: `--check-invariants` prints an
  `identity: ...` line per violation (pass, function, binder kind) to
  stderr and the pipeline continues; it exits 0 even when violations are
  found (68,947 of them on the frozen self-compile today). Set
  `BLORP_IDENTITY_CONTRACT=strict` to make the contract fatal — it stops at
  the first violation and exits 1. The commit message is explicit that
  strict mode cannot pass cleanly on the real self-compile until steps 3-5
  land: match's arm desugaring and Perceus's borrow-argument handling each
  duplicate an existing binder's exact `(name, uniq)` into a second binder
  site instead of minting a fresh one. Do not read step 2 as an enforced
  invariant — it is a diagnostic until a later step flips
  `BLORP_IDENTITY_CONTRACT=strict` on by default.

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

Gates for every code step:
the owning suites (`test_core_perceus.brp`, `test_core_closure.brp`,
`test_core_dce.brp`, `test_core_lower.brp`, `test_core_json.brp`, plus the
pass's own), `scripts/compiler-check --changed`, `scripts/test --serial
compiler-blorp compiler-tools`, `scripts/test leak`, `scripts/test
compiler-core-sanitize`. The `BLORP_GATE_RESULT` line is the verdict.

## Steps

Steps 0-2 have landed; see "Landed (steps 0-2)" above. Steps 3-6 remain.

| # | Step | Gate to start | Oracle | Expected effect |
| --- | --- | --- | --- | --- |
| 3 | Perceus keys by identity | 0 and 2 landed; 0 names the helpers | identical C | whatever 0 measured; correctness under shadowing |
| 4 | Closure captures carry identity | 2 landed | identical C | string compares gone; latent shadowing bugs closed |
| 5 | Synthetic binders from the shared allocator, no name baking | 2 landed; 0 counts the strings | identical C until 6 | the synthetic-name strings 0 counted |
| 6 | C identifiers from identity; spellings in one table | 5 landed | normalized C plus runtime, leak, sanitizer gates | strings out of Core |

Their gates on step 0 and step 2 are already satisfied. Next unblocked:
3 and 4 in parallel (gated on 2, which has landed), 5 alongside if it
avoids `perceus/*.brp`, 6 after 5.

### Step 3: Perceus keys by identity

Only the helpers step 0 named. Candidates: `count_uses` and the
`summarize_linear_ownership_uses` family (`perceus/uses.brp`) take a
`CoreVar` and compare with `core_var_equal`; `rewrite_mutable_assignments`
(`perceus/mutable.brp`) and `protect_repeated_consumes`
(`perceus/protect.brp`) stop dropping to `target.name`;
`BorrowedOwnerCatalog.candidate_ids_by_name` (`perceus/borrowed.brp`)
becomes a list indexed by `uniq` within the region (or a
`Dict[Int, List[Int]]` if the range is sparse; measure);
`has_unresolved_identity` (`perceus/borrowed.brp`) and the alias fallback
that exists only for it are deleted, and the fallbacks for unsupported
shapes stay, now counted separately by the `perceus_work_*` counters
(`perceus/work_counters.brp`). Do not convert `PerceusEnv`'s global and
constructor lookups here; they are keyed by declaration names, not
variables, and they are built once.

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
of Core; the remaining `Dict[String` in `stage_09_core/perceus/*.brp`,
`closure.brp` and `dce.brp` that key on variables are gone.

## What this roadmap does not include

The definition table for callables and types (the parked
`perf/definition-table` and `core/program-facts` branches). Both measured
as a cost, for the reason in the lessons above. If a later profile shows a
pass paying for name-keyed declaration lookups, the table is columns of ids
and indices only, built once after lowering and rebuilt after the passes
that mint declarations, and the consumer reads bodies from the program.
