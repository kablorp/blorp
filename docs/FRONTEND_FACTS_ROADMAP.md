# Frontend Facts Roadmap

Goal: time-to-C, weighted toward the front of the pipeline (lexing, parsing,
module discovery, typechecking, core lowering), because those phases are
what an LSP and static analysis reuse and what every edit-compile iteration
pays. The means is one architectural rule applied stage by stage:

> **Each stage publishes immutable facts as tables and indexes keyed by
> ids.** A stage builds its facts inside one function with local `var`
> accumulators, publishes them once as fields of the record it hands to the
> next stage, and never updates them again. Later stages read them. A stage
> may add a table only as a new field on the facts it publishes, keyed by an
> existing id or one it mints. No stage may rebuild an index that an earlier
> stage already publishes. No hot path keys a table by `String` when an id
> exists.

Read first: `COMPILER_SPEED_ROADMAP.md` ("How To Work A Task", "Quality
bar", and the round-three principle and its lexer, closure, mono, and
Perceus results), `PER_NODE_CODEGEN_ROADMAP.md` (the measurement rules,
including the stage-2 rule, which does not apply here because these tasks
do not change generated C), and `benchmarks/README.md` ("Self-Compile
Measurement Protocol").

## Boundary snapshots

### Historical baseline (2026-09-17, main `77796856c`)

What crossed each boundary in that snapshot, from reading the code:

- **Discovery to typecheck.** A module graph keyed by an integer `ModuleId`
  (`stage_04_modules/module_table.brp`); each `FrontendModule` holds the
  finalized parsed program (an immutable tree; the parser has no
  dictionaries) and a `ModuleSurface` whose exports and private names are
  lists of `String`-named symbols. Right shape, wrong keys.
- **Typecheck to everything after.** `TypedProgram` per module: a list of
  typed declarations plus two per-module lists (type definitions, type
  references). A tree, not tables. Mono, DCE, and Perceus each rebuild
  their own callable indexes from the declaration list; core lowering keys
  53 dictionaries by name (`lower.brp` alone has 19 `Dict[String, String]`).

### Current typecheck census (2026-09-21, `c4fe22776f1f`)

- **Inside typecheck.** The current source census supersedes the stale
  13-field/328-parameter estimate. `TypecheckState`
  (`stage_06_typecheck/state.brp`, `record TypecheckState`) has 14 fields.
  Across Stage 06, 295 function signatures mention the type, 285 take it,
  152 return it directly, and 142 do both; 63 of the direct-return helpers
  have at least one unchanged-state terminal. The counts are a source-shape
  census, not runtime call counts. `decl.brp` owns 161 of the 295 signatures,
  `state.brp` 77, and `modules/module_binding.brp` 23. The per-module/per-body
  split already exists: `InferModuleFacts` holds nine immutable body facts,
  while `InferSession` holds five accumulators plus those facts, and recursive
  `infer.brp` uses `InferContext`/`InferSession` rather than the broad state.
  Only two `infer.brp` function signatures still mention `TypecheckState`, at
  the entry/exit conversion boundary. The header-install builder also landed:
  it hoists `type_homes` and `known_type_index` into local owners and publishes
  them once. Ids already exist in
  `graph/` (`SourceNameId`, `DefinitionId`, `FieldId`, `ConstructorId`,
  `TraitId`) but the historical string-key inventory has not been refreshed
  by this audit.

### Historical cost snapshot (2026-09-17 stage-2 compiler)

Cost evidence: on a whole-compile `sample` of the stage-2 compiler
(about 15,000 samples), `blorp_string_eq` 441, `blorp_dict_hash_string` 291,
`blorp_dict_copy` 275, `blorp_dict_get_nullable` 133, `_platform_memcmp` 129.
String equality and hashing together are about 5% of the compile; a
dictionary copy means a shared dictionary was updated, which is the
threaded-state shape. Phase times on the stage-2 compiler: source_discovery
0.95 s, typed_frontend 3.65 s, core_lowering 1.1 s of about 17 s.


## Attribution (2026-09-17, stage-2 compiler, two samples of ~16,000)

| phase | inclusive share of compile | what dominates |
| --- | ---: | --- |
| lex | 1.1% | its own scanning plus one heap object per token; ~77 MB/s |
| parse | 5.2% | allocation and refcount around AST nodes (`blorp_release_slow_finish` is 50% of the subtree); ~16 MB/s |
| modules | 0.4% | `module_table_canonical_path` and string equality |
| typecheck | 21.5% | `blorp_dict_cow`+`blorp_dict_copy` 17% of the subtree; string hash and equality 4.7% |
| CTFE | 1.2% | `ctfe_lookup_binding` by name |
| core lowering | 7.9% | type-name construction and lookup by string (`core_lower_type_with_prefixes`, `flatten__find_callable_rewrite`) |

The dictionaries being copied are `TypeHomeIndex = Dict[String, TypeHomeEntry]`
(`state.brp:219`, written by `typecheck_state_record_type_home` and
`record_installed_type_home` during header install) and
`Scope.symbols_by_name: Dict[String, List[Int]]` (`type_system/env.brp`,
written by `scope_add_symbol`/`env_add_symbol` on every binding inside a
body). Both sit inside a state record that is threaded by value, so every
insert into a shared dictionary copies it. A `DefinitionId` already exists
for every declaration before these tables are populated
(`graph/definition_index.brp:116`).

Typecheck's own phase rows (`BLORP_TYPECHECK_BODY_METRICS=1`, microseconds,
one instrumented run): `indexed_graph` 289k, `bound_modules` 177k,
`callable_headers` 78k, `graph_completion` 941k (of which
`global_header_completion` 927k), `module_bodies` 2,205k for 12,800 bodies
(11,987 in the compiler's own source, 813 in the standard library). The
header completion is a whole-program pass with no incremental path; a
language server would pay it on every edit. The smallest independently
checkable unit in that snapshot was one body, after that pass had run.

Parser: `current_token` is still 6.9% of the parser's self time; the rest
of its non-scanning cost is `ParsedExpr` node allocation and destruction.

## How to measure a facts change

None of these tasks changes generated C, so the oracle is byte identity
plus the pass rows. For each cut:

```bash
export BLORP_CLI_C_OPTIMIZATION=-O2
make && scripts/compiler-build-status        # must print FRESH
benchmarks/self_compile_measure --label <task>-<cut> \
  --input-rev 0c2e104331a224226088519bb0509c00b9ac0b70 --samples 3 \
  --baseline benchmarks/results/self_compile_baseline_O2_2026-09-17_r5.json \
  --output /tmp/<task>-<cut>.json --require-identical
benchmarks/self_compile_measure --program small --label <task>-<cut>-small \
  --input-rev 0c2e104331a224226088519bb0509c00b9ac0b70 --samples 3 \
  --baseline benchmarks/results/self_compile_small_baseline_O2_2026-09-17_r5.json \
  --output /tmp/<task>-<cut>-small.json --require-identical
```

Primary metrics: the allocation row of the phase you changed
(`source_discovery_complete`, `typed_frontend_complete`,
`core_lowering_complete`, or the pass row inside them), whole-compile
instructions retired, and the string-lookup category from a sample. Take
the sample with the compiler you built:

```bash
input=$(benchmarks/self_compile_measure freeze --rev 0c2e104331a224226088519bb0509c00b9ac0b70)
bin/blorp compile --no-format --no-embed-runtime --std-dir $input/standard_library/src \
  -o /tmp/x.c $input/blorp/src/main.brp & sample $! 30 1 -file /tmp/sample.txt; wait
grep -E 'blorp_string_eq|blorp_dict_hash_string|blorp_dict_copy|blorp_dict_get_nullable|memcmp' /tmp/sample.txt | head
```

Report the "Sort by top of stack" counts for those five symbols before and
after; a facts change that keys a hot table by id must move them.
`benchmarks/attribute_sample --pass <module path> --map <profiled C>` gives
the per-phase category split (see `benchmarks/README.md`).

The frontend-only loop: `--stop-after=lower` ends the compile after core
lowering, so a self-compile iteration takes about 5 s instead of 17 s and
the lowered-Core dump proves identity of every frontend product:

```bash
BLORP_COMPILER_MEMORY_PROFILE=1 BLORP_TYPECHECK_BODY_METRICS=1 \
bin/blorp compile --stop-after=lower --dump-core-after=lower --dump-core-file=/tmp/cand.core \
  --time-phases --no-format --std-dir $input/standard_library/src -o /dev/null $input/blorp/src/main.brp \
  2>/tmp/cand.txt
cmp /tmp/base.core /tmp/cand.core     # base.core from the same command on the base build
```

`cand.txt` carries the phase times, the typecheck metrics rows, and the
allocation checkpoint rows for the three frontend phases. Use this for
every intermediate step and the full harness only for the numbers you
report per cut.

The fast loop is a small program: compile it, dump the phase you touched
(`--dump-core-after=lower` for lowering; `--typed-summary` or the typed AST
JSON for typecheck), and diff against the base build. The medium loop is
the small program through the harness. The slow loop is the self-compile,
three samples.

Gates per cut, one at a time (never parallel background shells): the owning
suites, then `benchmarks/self_compile_measure lock -- scripts/compiler-check --changed --base main`.
Measurements take no lock; run them before waiting on a gate. Do not run the
full default `scripts/test`; the coordinator runs it once per merge.

If the machine's `cc` reports an unaccepted Xcode license, prepend the
session's Command Line Tools shim to PATH (the coordinator gives the path);
it is a `cc` wrapper and changes nothing about the build.

## Working agreement

Same as the codegen roadmap and the general setup/measure/land loop in
[`docs/WORKER_CHECKLIST.md`](WORKER_CHECKLIST.md): one task per Sonnet worker
in its own worktree cut from `origin/main`; commit per cut with standalone
titles; never rebase, merge, or push; the coordinator squash-merges each task
as one commit; never `git stash` in these worktrees; compare instruction
counts only against a baseline built with the same C toolchain (an Xcode
update once moved identical C by 3.8%; the r6 baselines are the current
toolchain).

Task-specific: stop with `QUESTION FOR COORDINATOR:` when a change would
alter a published type that another running task also edits, when identity
breaks and you believe it benign, or after three hours without a measured
result. Never end a turn waiting on a build or gate; poll in a foreground
loop.

What "maximal result for every data source change" means in practice:
when you convert one lookup, convert every lookup on that data source in
the same task, delete the old accessor, and grep for stragglers. A task
that leaves the old `String`-keyed path alive next to the new id-keyed one
has not finished; the point is that the old shape cannot come back.

## Tasks

| order | task | files | serves LSP | parallel with |
| --- | --- | --- | --- | --- |
| 1 | T1 module lookups by `ModuleId` | `stage_06_typecheck/frontend_graph_typecheck.brp`, `stage_04_modules` | yes: module table by id | T2 |
| 1 | T2 callable name facts built once per lowering | `stage_08_core_lower/flatten.brp` | no | T1 |
| 2 | T3 intern names at the lexer | lexer, parser, `graph/source_name_table.brp`, every `Dict[String, ...]` keyed by a source name | yes: name occurrences by id | after T1 |
| 2 | T4 measured TypecheckState ownership cuts | `stage_06_typecheck/state.brp`, `infer.brp`, `decl.brp`, `modules/module_binding.brp` | yes: independently checkable bodies and imports | T4a capability gate; T4b independent |
| 3 | T5 publish the definition table out of typecheck | `graph/definition_index.brp`, `decl.brp`, then mono, DCE, Perceus index builders | yes: symbol table | after T3, T4 |
| 3 | T6 key lowering's tables by definition and type id | `stage_08_core_lower/lower.brp`, `list_layout.brp` | no | after T5 |
| 2 | T7 parser nodes without per-node ownership traffic | `stage_03_parse` | yes: per-keystroke work | T1, T2, T4 |
| 2 | T7b parser cursor as a scalar (builder conversion) | `stage_03_parse/language_parser.brp` | yes | after T7 |
| 4 | T8 cacheable header completion (design) | `stage_06_typecheck/decl.brp`, `headers/` | essential | after T4b |

### T1. Module lookups by `ModuleId`

**Context.** `frontend_graph_typecheck.brp:42-158` builds and threads
`modules_by_identity: Dict[String, FrontendModule]`, keyed by the canonical
module path, even though the graph assigns every module a `ModuleId` and
exposes `frontend_graph_module_table`, `frontend_graph_module_ids`,
`module_table_id_at`. Every cross-module lookup hashes a path string.

**Change.** Replace the dictionary with a `List[FrontendModule]` (or the
existing `ModuleTable`) indexed by `ModuleId`, built once, and change the
callers that resolve a module by path to resolve the id once at the edge
(import resolution already yields `ResolvedFrontendModuleReference(ModuleId)`)
and pass ids inward. Delete the path-keyed builder. Grep for any other
`Dict[String, FrontendModule]` or path-keyed module lookup in stage_04 and
stage_06 and convert them in the same task (the census counted five sites).

**Where to look.** `stage_04_modules/frontend_graph.brp` (the opaque graph
and its accessors), `module_table.brp` (`ModuleId`, `module_table_*`),
`frontend_graph_typecheck.brp`, and `pipeline.brp:803` for the driver that
calls `typecheck_frontend_graph_ids`.

**Pitfalls.** Module identity has an origin (`ResolvedModuleIdentityRep`
carries `canonical_path` and `origin`); do not conflate two modules with the
same path from different origins: the id table already distinguishes them,
which is the point. Diagnostics print paths; keep the id-to-identity lookup
for rendering.

**Acceptance.** Identical C on both programs; `typed_frontend_complete`
allocations down; `blorp_dict_hash_string` and `blorp_string_eq` sample
counts down; no `Dict[String, FrontendModule]` remains; typecheck and
frontend-graph suites green; compiler-check green.

### T2. Callable name facts built once per lowering

**Context.** `stage_08_core_lower/flatten.brp:469` builds
`Dict[String, CallableNameFacts]` from the function list; it is called at
line 517 and the facts are refined again at 551 and 584. Find every place
the facts are built or rebuilt per pass or per module during one lowering
and count how many times the builder runs on the self-compile (temporary
counter, removed before commit).

**Change.** Build the facts once in the lowering driver, publish them as a
field of the lowering's facts record, and pass them by borrow to
`materialize_builtin_overload` and the other consumers. If the refinement
steps at 551 and 584 add information, fold them into the single builder so
the product is complete when published. Then key the table by the callable's
definition id if `CoreFunction` carries one (check `ir.brp`); if only the
name is available at this point, keep the name key but record that as T6
input.

**Where to look.** `flatten.brp` around 179 (the record), 440-600 (build,
refine, consume), `lower.brp` for the driver order, `core_lowering_input`
in `pipeline.brp:940`.

**Acceptance.** Identical C; `core_lowering_complete` allocations down;
the builder runs once per compile; lowering suites and compiler-check
green.

### T3. Intern names at the lexer

**Context.** The parser's `ParsedIdentifier` carries `String`; the
typechecker later interns into `SourceNameId` (`graph/source_name_table.brp`).
Every name comparison and every `Dict[String, ...]` keyed by a source name
before that point hashes and compares bytes.

**Change.** Move interning to lexing: the lexer publishes a name table
(id to text, built with a local dictionary during the scan, published
once) and identifier tokens carry the id. The parser stores the id in
`ParsedIdentifier` (keep the text reachable through the table for
diagnostics and the formatter). Convert every consumer that keys on the
name text to key on the id, and delete the later interning step or make it
a pass-through. The formatter is the strongest oracle: it must reproduce
every file byte for byte (`bin/blorp format --check blorp/src standard_library/src`).

**Pitfalls.** Names are per compilation, not per module, so the table must
be shared across all files in one compile and stable across the LSP's
incremental reparse of one file (append-only). Hygiene: the typechecker
distinguishes same-named locals by a uniq counter; do not collapse those.
Interpolated strings and docstrings are not names.

**Acceptance.** Identical C; `source_discovery_complete` allocations not
up; `typed_frontend_complete` allocations down; `blorp_string_eq` and
`blorp_dict_hash_string` sample counts down substantially (report before and
after); formatter check clean on the whole tree; lexer, parser, typecheck
suites green.

### T4. Measured TypecheckState ownership cuts (T4a and T4b)

**Verified state census (2026-09-21).** The former broad-split proposal is
stale: the body boundary is already split, and another managed facts record
would recreate the ownership failure seen in Core lowering. Blorp has no
source-level borrowed record field that can store `&Facts`. A facts value can
only stay outside the returned state as a function parameter, and that is safe
only if generated C proves that recursive calls do not add retain/release
traffic.

The current fields and owners are:

| field | semantic owner and lifetime | kind | constructed / updated | principal consumers | managed | broad callers need it? |
| --- | --- | --- | --- | --- | --- | --- |
| `context` | inference/meta solver accumulator | accumulator | `typecheck_state_for_origin`; freshened by `fresh_body_infer_session`; solver steps in `infer.brp` | inference and body finalization | yes, `record Context` | body callers only |
| `env` | provisional declarations and lexical scopes | accumulator | definition-index bootstrap; `env_add_*` and scope changes in `decl.brp`/`infer.brp` | declaration checks and name/type lookup | yes, `record Env` | declaration/body callers only |
| `errors` | legacy message projection | accumulator | empty at session construction; appended with diagnostics and recovered body errors | success tests and legacy result projection | yes, `List[String]` | error boundaries only |
| `diagnostics` | ordered, located diagnostic authority | accumulator | empty at session construction; `typecheck_state_add_diagnostic`, location and recovery merges | CLI/LSP diagnostic products | yes, list of records | error boundaries only |
| `module_view` | admitted module/header authorities | build-then fact | empty initially; import admission and accepted-authority publication | declaration lookup and every body through `InferModuleFacts` | yes, opaque record | module/body readers |
| `graph_import_admission` | one import block's unpublished module-view builder | ephemeral cursor | `typecheck_state_begin_graph_import_admission`; every graph import registration; finish returns `None` | only `state.brp` admission helpers | yes, optional opaque record | no |
| `module_scope` | exact module/definition provenance plus temporary selected scope | fact plus cursor | unscoped bootstrap; program/import scope enter/restore | definition claiming and graph-table access | yes, opaque union | scope-sensitive callers only |
| `allow_debug_only_calls` | module policy | immutable fact | origin/request construction; never changed during one body | body call validation | no, `Bool` | body readers only |
| `private_impls` | provisional private implementation catalog | accumulator, then fact | appended during declaration admission; cleared at accepted boundaries | conflict checks; preserved across body reconstruction | yes, list of records | header/declaration callers only |
| `known_type_index` | accepted/provisional known type names | build-then fact | header install local builder, then one publication | resource/type-name queries | yes, opaque dictionary | selected declaration/body readers |
| `scoped_trait_functions` | imported/local trait-method visibility | build-then fact | module preparation and trait registration | UFCS/trait lookup | yes, list of string pairs | selected declaration/body readers |
| `type_homes` | visible spelling to exact nominal home | build-then fact | header install local builder, then one publication | qualification and import checks | yes, opaque dictionary | selected declaration/body readers |
| `type_shape_memo` | per-body resource-capability memo | ephemeral cache | empty for each body; updated only around capability scans | resource checks in `infer.brp` | yes, record of lists | body callers only |
| `source_table` | source-span labeling authority | immutable module fact | `typecheck_state_scope_to_program` | diagnostic source labels | yes, optional opaque record | diagnostic readers only |

The signature census found 295 functions mentioning `TypecheckState`: 285
take it, 152 return it directly, and 142 do both. Of the direct-return
helpers, 63 contain at least one unchanged-state terminal (83 terminals in
total), while 37 contain broad record updates (53 updates). Static call sites
are led by `typecheck_state_add_error` (138), but that is mainly an error/cold
path. Hot recursive expression inference no longer threads `TypecheckState`;
it threads `InferContext` containing `InferSession`. The remaining broad-state
publication opportunity with a tight production loop is graph import
admission, not another whole body-state rewrite.

The static call graph reinforces that split. `typecheck_state_add_error` has
138 source call sites and `typecheck_unfinalized_type_error` 13, but both are
diagnostic paths. The leading non-error helpers are
`canonical_annotation_type` (19 read-only call sites),
`typecheck_state_apply_selective_name_registration` (12),
`typecheck_state_module_id` (10 read-only),
`typecheck_state_remember_top_level_name` (9), and
`typecheck_install_header_category` (8). The landed header installer already
hoists the repeatedly updated `type_homes` and `known_type_index` dictionaries
into local owners. By contrast, `typecheck_state_register_graph_module_alias`
still has six success/conflict arms that republish `graph_import_admission` in
the broad state, and selective-name/constructor registration has the same
shape. These are the T4b target. Runtime loop counts still require the proposed
deterministic counter; static call sites and native samples are not substitutes.

The retained reconstruction fixture confirms the existing split's mechanism:
at 10,000 iterations, constructing an intermediate `InferSession` and then a
`TypecheckState` performs 30,000 allocations/releases; direct fresh-body state
construction performs 20,000/20,000, with equal checksums and zero retained
objects. The earlier production replay likewise removed exactly 11,114
allocations and releases, one per body-state construction. It did not establish
that moving `InferModuleFacts` across the recursive-call boundary is free.

A current orientation run on `c4fe22776f1f` used a captured
`blorp/src/main.brp` request (SHA-256
`bc58761588c7233cf7957757738e711dcba411fe0bcddfecde0b38f5e0ac964a`).
An explicitly prebuilt, uninstrumented target-only worker returned 1,821,834
bytes with SHA-256
`743afc195dd7babfb8a34faf1180ea7f71a15ac7a8d40ad127d3424830af4b7d` in
9.189 s at 399,147,008 bytes peak RSS; the enclosing process retired
1,708,245,757 instructions. A separate allocator-attributed replay returned
the same bytes and hash. From `typecheck_start` to `typecheck_complete` it
recorded 54,747 allocations, 45,448 releases, +9,299 current objects, and
+486,496 allocator bytes in 17,998 µs. These are a single-run baseline, not
an improvement claim. The same checkout's `--stop-after=lower --time-phases`
orientation reported 6,907.412 ms for `typed_frontend`; use paired optimized
workers, not this `-O0` orientation, for acceptance.

#### T4a. Capability gate: keep immutable inference facts outside returned state

**Owner and dependency.** `blorp/src/compiler/stage_06_typecheck/state.brp`
(`InferSession`, `InferModuleFacts`),
`blorp/src/compiler/stage_06_typecheck/infer.brp` (`InferContext`, `infer_expr`
and facts readers), and `blorp/src/compiler/stage_06_typecheck/decl.brp` (the
three body-inference entry sites). This gate must run before any signature
migration. T4b is independent and may land first.

The experiment removes `facts` from the state returned by recursive inference
and passes one facts value separately. The following is explicitly
non-compilable design pseudocode: proposed function names do not exist yet,
but the record shapes and comment syntax match the current Blorp types.

```blorp
-- Current shape.
record InferSession {
    context: Context,
    env: Env,
    errors: List[String],
    diagnostics: List[TypecheckDiagnostic],
    type_shape_memo: TypeShapeMemo,
    facts: InferModuleFacts
}

result = infer_expr(context, body)

-- Probe shape. Do not migrate callers until its generated C passes.
record InferSession {
    context: Context,
    env: Env,
    errors: List[String],
    diagnostics: List[TypecheckDiagnostic],
    type_shape_memo: TypeShapeMemo
}

record InferContext {
    state: InferSession,
    expectation: InferExpectation,
    in_loop: Bool,
    in_debug: Bool,
    suppress_debug_only_reference: Bool
}

facts = infer_module_facts_from_typecheck_state(body_state)
context = infer_context_without_facts(body_state)
result = infer_expr_with_facts(facts, context, body)
```

The characterization test comes first: extend
`blorp/test/compiler/pipeline/test_infer_session_reconstruction_profile_benchmark.brp`
with a nested inference-shaped probe that returns only the accumulator, checks
the facts-dependent checksum, and exposes exact publication/allocation counts.
Inspect the generated C around the probe and recursive call before touching
`infer_expr`.

Fast loop:

```bash
bin/blorp test --timeout 180 \
  blorp/test/compiler/pipeline/test_infer_session_reconstruction_profile_benchmark.brp
benchmarks/compiler_infer_session_reconstruction_profile 10000
bin/blorp compile --no-format -o /tmp/infer-facts-probe.c \
  blorp/benchmark/compiler/compiler_infer_session_reconstruction_profile.brp
rg -n 'InferModuleFacts|retain|release|infer_facts' /tmp/infer-facts-probe.c
```

Retain the exact `blorp/src/main.brp` captured request and compare workers with
the required positional request path; response bytes and SHA-256 are the
identity oracle:

```bash
capture=/tmp/typecheck-state-main-request.json
candidate_worker=/tmp/candidate-worker/compiler_typecheck_worker
test -f "$capture"
test -x "$candidate_worker"
benchmarks/compiler_typecheck_replay "$capture" \
  --bridge "$candidate_worker" \
  --target-only --timeout 180 --memory-limit 4G --no-inventory --json
```

Run the same command with the baseline worker, alternate order, then run
`scripts/compiler-check --stage typecheck` and `scripts/test compiler-blorp`.

**Accept/reject.** Proceed only if the probe removes at least one managed
publication and its matching allocation/release per modeled recursive update,
adds no retain/release pair per recursive call in generated C, preserves zero
retained objects/bytes, and produces byte-identical replay responses. Reject
the design immediately if passing facts as a parameter retains them on every
call, if allocation/release counts are flat or higher, or if three alternating
self-compile pairs regress minimum retired instructions by more than 0.5%.
That rejection means the compiler needs an explicit borrow/codegen capability;
it is not permission to wrap the facts in another managed carrier.

**Likely risk.** The facts argument is managed and recursive helpers may borrow
it often enough that eliminating the nested field only trades record
publications for retains. The probe exists to reject that shape before the
large, mechanical `infer.brp` signature migration.

#### T4b. Own graph import admission locally and publish the module view once

**Owner and dependency.**
`blorp/src/compiler/stage_06_typecheck/modules/module_binding.brp`
(`register_program_imports`, `apply_import_decl_decision`,
`register_import_symbols`, and alias/constructor helpers) and
`blorp/src/compiler/stage_06_typecheck/state.brp` (the
`typecheck_state_*graph*admission` adapters). This cut has a representation/API
prerequisite in
`blorp/src/compiler/stage_06_typecheck/modules/module_view.brp`.

`GraphImportAdmissionRep` currently stores `initial_view`, occupancy rows, and
candidate-builder state. It does **not** store the active `ModuleTable`,
`DefinitionTable`, or `ModuleId`. `graph_import_admission_begin` validates a
caller-supplied table/id, and every alias/selective registration again accepts
caller-supplied current authority. Moving only the admission into a local would
therefore leave a stale-pair hazard.

The smallest prerequisite is to add the already-validated active
`DefinitionTable` directly to the private admission representation. Its module
table is the graph authority, while the current module id is derived from the
`GraphModuleNameScope` already retained by `initial_view` rather than stored as
a second independently supplied value. A new batch constructor accepts
`(view, active_definition_table)`, derives the issuer module id from the view,
validates table compatibility once, and stores the definition table only on
success. Batch alias/selective/constructor registration then removes the
`current_table`, `current_module_id`, and `active_definition_table` parameters
and reads that authority from the admission. Issuing target tables remain
explicit and are still checked against the stored active table. This makes a
stale active `(table, module id)` pairing unrepresentable after construction.

Write the prerequisite test first in `test_module_view.brp`: a definition
table from graph A cannot begin admission on a view from graph B; an admitted
value exposes no API that accepts replacement active authority; mismatched
issuing tables remain rejected; and finish preserves the original view owner.
Inspect generated C and the focused allocation fixture before proceeding,
because retaining a `DefinitionTable` inside the admission is a new managed
field and may itself erase the expected win. If it does, stop and require a
compiler borrow/codegen capability rather than passing a parallel raw table/id
pair.

Today every successful registration republishes the whole 14-field state:

```blorp
var current = state
current = typecheck_state_begin_graph_import_admission(current)
current = apply_import_decl_decision(current, import_decl, decision)
final_state = typecheck_state_finish_graph_import_admission(current)
```

After that prerequisite passes, the bounded cut keeps the admission as the
loop's single owner, threads only registration decisions and cold-path
diagnostics through helpers, then updates `module_view` once. This is design
pseudocode; the proposed helper names do not exist yet:

```blorp
var current = state
final_state = match typecheck_state_definition_table(current):
    None:
        current
    Some(active_definition_table):
        match graph_import_admission_begin_batch(
            current.module_view,
            active_definition_table,
        ):
            None:
                current
            Some(initial_admission):
                var admission = initial_admission

                for import_decl in imports:
                    decision = decide_import_decl(
                        index,
                        import_decl,
                        seen_module_paths,
                        is_stdlib,
                    )
                    admission_result = apply_graph_import_decl(
                        admission,
                        import_decl,
                        decision,
                    )
                    admission = admission_result.admission
                    current = append_import_diagnostics(
                        current,
                        admission_result.diagnostics,
                    )

                { current |
                    module_view = graph_import_admission_finish(admission)
                }
```

First change the existing structural test in
`blorp/test/compiler/stage_06_typecheck/support/test_declaration_boundary.py`
so it requires a module-binding-local admission owner and rejects per-import
successful `TypecheckState` publication. Preserve the exact conflict/reentry
cases in `blorp/test/compiler/stage_06_typecheck/test_typecheck_state.brp` and
the publish-once/invalid-candidate cases in
`blorp/test/compiler/stage_06_typecheck/test_module_view.brp`.

Fast loop and retained benchmark:

```bash
python3 \
  blorp/test/compiler/stage_06_typecheck/support/test_declaration_boundary.py
bin/blorp test --timeout 180 \
  blorp/test/compiler/stage_06_typecheck/test_typecheck_state.brp
bin/blorp test --timeout 180 \
  blorp/test/compiler/stage_06_typecheck/test_module_view.brp
bin/blorp test --timeout 180 \
  blorp/test/compiler/pipeline/test_module_binding_benchmark.brp
benchmarks/compiler_module_binding_profile 100 64 16
```

Use the same captured replay response as the identity oracle, then run
`scripts/compiler-check --stage typecheck` and `scripts/test compiler-blorp`.
Add a deterministic benchmark counter for successful admission mutations and
whole-state publications; do not infer either count from samples.

**Accept/reject.** Accept only if each nonempty graph import block has one
admission construction and one final `ModuleView` publication, successful
imports do not publish `TypecheckState`, diagnostics and accepted binding order
are byte-identical, allocations/releases fall by at least the eliminated
publication count, and retained objects/bytes do not rise. Stop if the opaque
admission still accepts replacement active authority after construction, if
the stored definition table adds a retain/release per registration, or if COW
merely moves into an admission helper. Reject on any replay identity difference
or a greater than 0.5% minimum-retired-instruction regression across three
alternating pairs.

**Likely risk.** The graph and standalone registration paths currently share
state-level adapters, and conflict diagnostics are interleaved with successful
admission updates. Keep diagnostics on the cold branch without changing their
order, and inspect generated C to ensure the local admission remains uniquely
owned rather than moving COW into `apply_graph_import_decl`.

**Current viability.** T4a is viable only as a probe until generated C proves
the function-parameter borrow shape. T4b is likewise blocked on its smallest
safe authority-coupling prerequisite and the generated-C/allocation result of
that prerequisite. The broad `TypecheckState -> ModuleFacts + BodyBuilder`
rewrite is closed: most of that boundary already exists, and the remaining
ownership work should land only as these measured cuts.

### T5. Publish the definition table out of typecheck

**Context.** `graph/definition_index.brp` assigns `DefinitionId`s inside
the typechecker; later stages do not receive the index. Mono
(`collect_generic_functions`), DCE (roots), and Perceus (`build_env`'s
callable index and `user_call_contracts`) each rebuild a callable index
from `CoreProgram.decls`.

**Change.** Make the definition table a published field of the typecheck
result: id to name id, module id, kind, declared type, span; plus a
resolution table (use site to definition id). Carry it through lowering
onto `CoreProgram` (or a sibling facts record on the pass state), then
replace each downstream index builder with a lookup or a one-time
projection. Delete the builders.

**Acceptance.** Identical C; `pass_mono_complete`, `pass_dce_complete`,
and `pass_perceus_complete` allocations down; no downstream pass walks
`decls` to build a callable index; suites and compiler-check green.

### T6. Key lowering's tables by definition and type id

**Context.** `lower.brp` has nineteen `Dict[String, String]` tables (name
renames and prefixes) and `list_layout.brp` keys type aliases, storage
layouts, and core types by type name. T2's census also found
`CoreLayoutTypeIndex` built twice per compile on the same declarations
(`ffi_boundary.brp:234` and `list_layout.brp:644`, back to back in
`graph_prepare.brp`), with `annotate_list_layouts` also called from
`stage_09_core/early_stages.brp`; share one build and pass it in.
`module_member_prefixes` (`graph_prepare.brp:379`) is built once and
threaded through 19 signatures; it only needs the id key.
`CoreLowerCallableNameRegistry` (`graph_prepare.brp:189`) is already
`Int`-keyed and built once per module: the target shape.

**Change.** With T5's table available, replace each with a list indexed by
definition id or an interned type id; delete the string builders. Where a
table maps names to sanitized C identifiers, compute the identifier once
per definition id in the published table instead.

**Acceptance.** Identical C; `core_lowering_complete` allocations down;
`blorp_string_eq` and `blorp_dict_hash_string` samples down; lowering
suites and compiler-check green.

### T7. Parser nodes without per-node ownership traffic

**Context.** Parsing is 79% of discovery and runs at 16 MB/s where lexing
runs at 77 MB/s; half of its cost is allocating, retaining, and destroying
`ParsedExpr` nodes and their lists, not scanning. `current_token` is still
re-read at 6.9% of the parser's self time.

**Change.** Measure first with a sample restricted to `stage_03_parse` and
a per-node-kind allocation count; then the cuts that the numbers pick
among: build child lists with a single local accumulator and one publish
per node; keep the current token in a struct local instead of re-reading;
return small scalar results as structs. The formatter is the oracle
(`bin/blorp format --check blorp/src standard_library/src`), plus the
parser suites and identical C.

**Acceptance.** Identical C; `source_discovery_complete` allocations down
at least 20%; parse throughput reported before and after; formatter clean.
Serves the LSP directly: parsing is the per-keystroke work.


### T7b. The parser's cursor as a scalar, not a state record (builder conversion)

**Context.** T7 read the generated C of `advance_parser`
(`language_parser.brp:745`, `{ state | index = state.index + 1 }`): the
callee retains its `state` parameter before the reuse check, so the update
is never unique and every token advance allocates a new four-field
`ParserState` plus three field retains. `ParserState` is threaded through
about 257 call sites of the recursive-descent grammar (6,885 lines).
T7's two cuts (token kind without owning the token, infix info as a stack
struct) landed at -1.3% instructions; this is the remaining, larger
allocation source in parsing.

**Change.** The parser becomes a builder in the lexer's shape: the token
list and source are passed by borrow; the cursor is an `Int` passed in and
returned in a small `struct` result together with what was parsed (a
struct field may be an Int or a fieldless enum; the parsed node itself is a
record and travels as the second field of a record result only where the
struct rule forbids it, so measure which result shapes stay on the stack);
diagnostics are a local `var` accumulator of the top-level parse function
(or passed by borrow and appended through a returned list only at the few
sites that emit them). Do it grammar family by grammar family (expressions,
patterns, types, declarations), each as a cut with the formatter as the
oracle.

**Fast loop and oracle.** `bin/blorp format --check blorp/src standard_library/src`
(400 files, byte-exact), the parser and lexer suites, the stop-after loop
with an identical lowered-Core dump, then the r6 harness with
`--require-identical`. Report `source_discovery_complete` allocations and
parse throughput before and after.

**Pitfalls.** Backtracking: any site that saves a `ParserState` and
restores it on failure becomes "save the Int cursor"; diagnostics emitted
during a failed speculative parse must still be discarded the way they are
today. Error recovery paths that return a partially advanced state must
return the cursor they reached. The `Step` records the grammar uses to
return (state, node) pairs are the natural place to become structs.

**Acceptance.** Identical C; `source_discovery_complete` allocations down
at least 20%; formatter clean; suites and compiler-check green.

### T8. Header completion that does not restart from scratch (design)

**Context.** `graph_completion` re-derives every module's accepted record,
union, alias, and global headers on every compile (927 ms here). For a
from-scratch compile the landed header-install builder makes it cheaper; for
an editor it must become cacheable per module, keyed by a hash of the module's
declarations.

**Deliverable.** A design note, not code: what the per-module header
product is, what it depends on (imports' surfaces), how it is keyed and
invalidated, and how `PreparedCanonicalModuleEnvironment` can load a cached
header product without reconstructing module facts. Write it after T4b proves
the final module-view publication boundary.

## Facts inventory and propagation map (audit of 2026-09-17)

A read-only audit of every `Dict[String, ...]` and hot name comparison from
stage_06 through stage_10 (373 sites; one 60 s sample of 29,727 frames on
the frozen input) collapsed the candidates into the facts below. Sample
shares: `blorp_string_eq` 2.5%, `blorp_dict_hash_string` 2.1%,
`blorp_dict_copy` 1.9%, `memcmp` 0.9%, `blorp_dict_get_nullable` 0.8%,
`blorp_string_concat` 0.3%: about 8.5% of the compile is string and
dictionary work in total, which bounds what propagation can remove.

| fact to publish | published by | shape | retires | vetted realistic gain | effort |
| --- | --- | --- | --- | ---: | ---: |
| F7 DCE keyed by the `def_id` already on `CoreVar` | none needed | consumer fix in `dce.brp:238-358, 330, 407, 451` | the `Dict[String, Dict[Int, Dict[Int, Bool]]]` read and invalidation indexes | 0.5 to 1% | 1 day |
| F2 definition and callable table (T5) | typecheck, threaded onto Core | `DefinitionId -> {name id, module id, kind, type, span, arity, purity}` plus use-site resolution | `dce.brp:1358-1489` five name indexes; `resolve.brp:219-499` nine tables; Perceus `build_env` callable index; `closure.brp` `functions_by_name`; the name half of `flatten.brp:762` `find_callable_rewrite` | 1.5 to 2% | 3 to 4 days |
| F3 sanitized C identifier table | backend, once per definition | `DefinitionId -> C identifier` (make, destroy, reuse, enum helper, local spellings) | every concat-on-call helper in `c_naming.brp:80-130` (64 call sites), `c_symbol_projection.brp:130-272` `by_original_c_spelling`; backend concatenation is 7.8% of the backend's 19.7% | 1 to 1.5% | 2 to 3 days |
| F1 interned source names (T3) | lexer | `SourceNameId -> String`, append-only | `Scope.symbols_by_name`; the four `accepted_*_authority.brp` name tables (about 53 sites); `declaration_skeleton.brp` `latest_skeleton_index_by_name`; `type_header_dependencies.brp` vertex index | 1.5 to 2.5% | 4 to 5 days |
| F6 module prefix by `ModuleId` (T6) | core lowering (already built once) | `ModuleId -> C prefix` | `module_member_prefixes` threaded through 19 signatures in `lower.brp` plus copies in `resolve.brp`, `mono_specialize.brp`, `mono_option.brp`, `parallel_tensor_pipeline.brp` | 0.5 to 1% | 1 to 2 days |
| F5 type name and layout table (T6) | core lowering, once | `TypeId -> {alias target, declared type, list layout}` | `CoreLayoutTypeIndex` (built twice); `mono_data.brp` `templates` and `transparent_aliases` (threaded through ~20 signatures); `record_update.brp` `record_decls` (~25 signatures); `emit_record_layout.brp` three tables; `flatten.brp` `type_rewrite_index` | 0.5 to 1% | 3 days |
| F4 type-home table by definition id (historical T4 proposal) | typecheck header install | `DefinitionId -> TypeHomeEntry` | `TypeHomeIndex`, the per-importer reinstall | historical ceiling 3 to 5% | superseded by the landed section builder and exact graph authorities |
| F8 cacheable per-module header product (T8, design) | typecheck | per-`ModuleId` completed headers keyed by content hash | the whole-program `global_header_completion` rebuild for the editor case | 0% cold, per-edit latency otherwise | design 1 day |

The 2026-09-17 audit estimated 5 to 7% for F1 to F7 before the landed work was
measured. Do not add F4's historical 3 to 5% ceiling to the remaining
opportunity: the section builder and graph authorities superseded that shape,
and the current T4 cuts have no speedup estimate before their capability
gates. The architectural value remains that F1, F2, the current graph
authorities, and F8 are tables a language server queries and invalidates; F2
and F5 also targeted repeated downstream index construction.

Not worth a task: `FIXED_BUILTIN_GROUP_BY_NAME`, `INTRINSICS_DICT` (small
static tables); `stage_07_ctfe/context.brp:688` (new information at CTFE);
`emit.brp` dump-path membership sets (behind CLI flags);
`module_binding.brp` path tables (tooling fallback only after T1);
`type_header_dependencies.brp` (tens of entries per module); trait and
match-lowering name tables (small, fold into F2/F5); Perceus name tables
(2.6% of its own subtree is string equality; its lever is ownership).

Order by gain over effort: F7, F2, F3, F1 (after T4 leaves the typecheck
files), then F6 and F5 together.

## Body-checking attribution (2026-09-17, exact and calls profiles plus a sample rooted at the body loop)

The two flat typecheck attempts targeted the wrong mass. Scoped to the
body loop itself (2,168 samples, 7 roots): generated code 30%, reference
counting 27%, cleanup frames 18.5%, allocation 7.5%, string and dict
lookups 5%, list ops 4.5%. Dictionary copies and string construction are
under 1% here; the whole-phase figures that suggested them belonged to
header install.

The mass is the post-inference zonk: `finalize_infer_result` runs once per
body (13,749) and unconditionally calls `zonk_typed_expr` on every node
(565,091 calls), reconstructing a `TypedExpr` and a `TypedExprInfo` (plus
`ResolvedCallInfo`, `ValueSlot`, `ExprTypeOrigin`) even when the node has
no unresolved meta, then destroying the pre-zonk tree
(`TypedExpr_destroy_fields` is 8.3% of the body loop). The type-level zonk
(`resolve_type_metas_if_changed`) is already diff-aware; the expression
level is not. Secondary: the id-indirection chain
(`source_name_id_table_index` 8.8M calls, `definition_id_runtime_value`
5.6M, `definition_table_rep_row` 2.3M; 258 ms self, shared with header
completion), scope-chain lookups by name (`scope_lookup` 4.4M,
`env_lookup` 1.2M, `lookup_bare_value` 0.4M), and the scope-table insert
(`scope_add_symbol` 200k calls, real but small).

Tasks, ranked: (1) zonk reuses unchanged nodes and skips bodies with no
metas (task `perf/zonk-reuse`, in flight); (2) resolve each identifier
occurrence once by definition id instead of re-walking the scope chain by
name; (3) key the id-indirection chain directly (a facts change shared
with header completion); (4) the scope insert, only alongside (2).

## Results

| task | outcome | commit | phase row | notes |
| --- | --- | --- | --- | --- |
| T1 module lookups by `ModuleId` | landed | `842912c16` | self-compile rows identical | the path-keyed source was only the fallback used by lint, check, purify, and the LSP; the self-compile driver already used ids |
| T2 callable name facts once per module | landed | `46930b911` | `core_lowering_complete` -0.13% | builder runs 359 times instead of 718; identical lowered Core; `CallableNameFacts` stays name-keyed by design (it aggregates overloads sharing a name) |
| F7 DCE reference indexes by `(def_id, uniq)` | landed | `441f568a9` | instructions -0.32%; `pass_perceus_complete` -0.5% | the consumer of those indexes is Perceus, not DCE's own pass; string-equality samples -56% |
| T7 parser: token kind without owning the token; infix classification as a stack struct | landed | `7619c0035` | instructions -1.3%; `source_discovery_complete` -0.4% | `advance_parser` still rebuilds a `ParserState` record per token: the T7b builder conversion below |
| T4 broad typecheck facts split | closed; replaced by T4a/T4b gates | | | `InferModuleFacts`/`InferSession` and the header-install builder already exist; do not add another managed facts carrier. Probe a function-parameter facts boundary first, and independently move graph import admission to a local owner with one module-view publication |
| F3 backend type naming facts and reserved-identifier index | landed | `aff15726a` | instructions -1.52% | the cost was a 54-entry `List[String].contains` per emitted local reference, not concatenation; naming facts flat but single-sourced |
| typecheck state reuse (type-home and known-type early-outs folded into the update) | landed | `e346793d1` | instructions -0.39%; ~23k fewer typecheck allocations | partial: consume-specialization never clones a helper whose parameter is a `Dict` or `List` (`consume_specialize.brp:448` accepts only records and unions), so container updates through helpers still copy; opened as a codegen task (consume-containers) |
| T7b parser as a builder with a scalar cursor | landed | `4996e97c9` | `source_discovery_complete` -10.3%; instructions -1.2% | `ParserState` deleted; the parser never backtracks, so no cursor-save machinery was needed; remaining discovery cost is one heap object per token in the lexer and the AST nodes |
| header install as a per-module builder (T4 as re-scoped) | landed | `6ccd89809` | `typed_frontend_complete` -1.5% | 24,435 per-edge installs became 718 per-module section builds; C and 1,354 diagnostic fixtures identical; the header install was 2.9% of the phase, body checking is 72%, so the next typecheck lever is `Scope.symbols_by_name` and the `env_add_*` tail-call chain |
| Perceus short-circuit ownership fix (other session) plus coverage | landed | `4cf07d54e` | Perceus allocations +8% (1.4M in the fix, 2.3M more in its worklist follow-up) | fixes a real leak for `flag and f(borrowed)`; the parser stopgap was reverted once the compiler fix covered it; the allocation cost of the extra operand scans is a follow-up for that session |
| consume-specialization for `Dict`/`List` helpers with tail-position propagation | parked, branch `perf/consume-containers` at `5e505dc11` | | instructions +2.2% net on stage-2; total allocations -0.5%; Perceus allocations -2.6% | mechanism is correct (a three-helper chain mutates a dict in place under the leak checker; a real trailing-drop bug was fixed; propagation discovery proven redundant and deleted; the pass's own cost is now within 2% of base). The regression is in the emitted clones: retargeting fires at hot sites whose argument arrives borrowed and is never unique at runtime (`push_short_circuit_scan` clone 643k calls at 2x per-call cost, `insert_drops_expr_inner` 5x, `type_home_index_record` 2x), so callers pay the clone's drop machinery without an in-place win. To revive: retarget only when the argument is provably owned by the caller (a local bound to an owned value, or the caller's own consumed parameter), and make the clone's pass-through path cost no more than the original |
| typecheck Env builder: scope update single-owner, 16 gate-1 early-outs removed in the body checker | parked, flat, branch `perf/typecheck-env-builder` at `ab7a6c672` | | identical C; instructions +0.02%; typed-frontend allocations -0.3%; time -0.7% on a quiet machine | the scope-table copies were not the mass of body checking (29.4M allocations); the per-binding update is O(1) in isolation but the phase did not move, so the next step is an allocation-site attribution of body checking, not more ownership plumbing |
| zonk skipped for bodies with no unresolved metas | landed | `a92f30bda` | `typed_frontend_complete` -8.5%; total allocations -1.6%; instructions -0.8% | 13,656 of 13,749 bodies have no metas at finalize; per-node reuse (cut 2) parked on `perf/zonk-reuse`: 57k allocations for twenty identity predicates; the 93 meta bodies thread the meta through nearly every node (the designed polymorphic case) |
| T5 definition table: publish, post-pass sync | parked, branch `perf/definition-table` | | publish-only measured +11% instructions; sync fixed to rebuild columns once | root causes: `push`/`set` rebuilt every column from the same base (fixed, 466 ms to 2 ms self), and the table built inside the per-module lowering loop makes `decls` non-unique so lowering copies it on append (`lower_core_modules` +23 s inclusive, allocation rows flat). Next: build the table once after lowering from the final `decls`; then DCE consumes. Seven passes mint named functions without registering (synth eta adapters, match, std_inline, tailrec, fusion, closure, consume_specialize); the post-pass sync covers them |
| Perceus literal-match balancing fix (found by the struct-token lexer) | landed | `09f3d900c`; bootstrap re-pinned `132647c3f` | C +0.01%, instructions +0.09% | `protect_repeated_consumes` had no `LiteralMatchExpr` arm: a var consumed inside a literal-match arm within a loop got no protective retain while the reassignment dropped it (double release); regression test under the leak checker and sanitizer |
| lexer token as inline struct with interned texts; parser reads token columns | landed | `2c171a5d8` | `source_discovery_complete` -4.8%; instructions -0.17% self, -0.06% small; identical C | census: 1,746,333 tokens, 601,674 with payload, 84,531 distinct texts (7:1). Three lessons: a compatibility view that rebuilds the union per read cost +137%; tuples returned per token by the lexer's helpers cost +37% until `lex` owned its accumulators; reading a ten-field struct out of an inline list copies it whole, and the parser reads each token ten times, so the parser stores tokens as columns. Found and fixed two Perceus bugs on the way. The 1.5M spans materialized per node are the next lever (cross-stage token indices) |
| r7 / s3 baselines | recorded | `fdb932b93` | bootstrap -O2 176.3G; stage-2 172.3G; small stage-2 -3.7% vs s2 | generated C changed on main through the C emitter's split layout, so r6 identity is stale; use r7 and s3 |
| T3 prep: `Token` as a scalar `struct` with an interned-text side table, `TokenKind` kept as a compatibility view (`token_kind_of`) so the ~100+ existing match sites needed no body changes | parked (tests/formatting only), branch `perf/lexer-token-struct` | `6846913d6` (WIP source), `ccd9a5cdd0d0` (merge), test/format follow-up uncommitted at hand-off | `source_discovery_complete` +137.39% (self: 14,536,422 to 34,508,446; small: 341,353 to 776,573); instructions +5.99%; identical C (128,438,702 bytes both sides); every phase after `typed_frontend_complete` +0.00% | census over the frozen self-compile input (1,961 files): 1,746,333 tokens, 601,674 (34.4%) carry a payload, only 1,289 tokens (0.07%) carry any trivia (4,315 trivia items). Interning itself works: 601,674 payload tokens intern down to 84,531 distinct texts, a ~7.1x dedup ratio, with a round-trip test (`intern_text` on a string literal followed by three identifiers) proving no off-by-one. The regression is not interning, and not `InlineStructListStorage` (a standalone `List` of 200 ten-`Int`-field structs, built by append and read by `for` and by index, passes clean): it is the compatibility view. `token_kind_of` rebuilds a fresh heap-boxed `TokenKind` union (with an interned-text lookup) on every call, and the parser reads the same token index through `current_token`/`current_token_kind` several times at many decision points (peek-then-consume), so every payload-carrying token pays a fresh allocation per read instead of the zero-cost field read the old record gave it — exactly the risk the brief flagged for this strategy, just larger than expected. Two real compiler bugs were found and fixed along the way and are not part of this regression: a pinned-bootstrap effect (the bootstrap predated a Perceus fix, so the branch's own literal-match arms were miscompiled by it regardless of source content) and the underlying fix itself, `09f3d900c` (Perceus's `protect_repeated_consumes` had no `LiteralMatchExpr` arm, double-releasing a var consumed inside a literal-match arm in a loop). Next: delete the compatibility view. Convert the ~100+ match sites in `language_parser.brp` to match on the scalar `TokenTag` directly and read payload text through the interned-text table only at the sites that actually need it, instead of reconstructing the whole union per read |
