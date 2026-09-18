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

## Where the boundary stands (2026-09-17, main `77796856c`)

What crosses each boundary today, from reading the code:

- **Discovery to typecheck.** A module graph keyed by an integer `ModuleId`
  (`stage_04_modules/module_table.brp`); each `FrontendModule` holds the
  finalized parsed program (an immutable tree; the parser has no
  dictionaries) and a `ModuleSurface` whose exports and private names are
  lists of `String`-named symbols. Right shape, wrong keys.
- **Inside typecheck.** `TypecheckState` (`stage_06_typecheck/state.brp:207`)
  has 13 fields and is threaded through 328 parameters in `decl.brp` and
  the header install; every body returns `{state, typed}`. Correction from
  the T4 audit (2026-09-17): the per-module/per-body split already exists
  at the body boundary. `InferModuleFacts` (`state.brp:2113`) holds the
  seven per-module facts and `InferSession` the per-body accumulators, and
  all of `infer.brp` runs on them. What is still threaded by value is the
  header-install phase, and it re-runs a module's whole header install once
  per importer edge (24,435 installs for about 300 modules;
  `record_installed_type_home` costs 5.8 µs per call over 109,000 calls,
  the signature of a dictionary copy per insert). Ids already exist in
  `graph/` (`SourceNameId`, `DefinitionId`, `FieldId`, `ConstructorId`,
  `TraitId`) but 126 dictionaries are still keyed by `String`, against 138
  by `Int`.
- **Typecheck to everything after.** `TypedProgram` per module: a list of
  typed declarations plus two per-module lists (type definitions, type
  references). A tree, not tables. Mono, DCE, and Perceus each rebuild
  their own callable indexes from the declaration list; core lowering keys
  53 dictionaries by name (`lower.brp` alone has 19 `Dict[String, String]`).

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
checkable unit today is one body, after that pass has run.

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

Same as the codegen roadmap: one task per Sonnet worker in its own worktree
cut from `origin/main`; commit per cut with standalone titles; never rebase,
merge, or push; the coordinator squash-merges each task as one commit.
Stop with `QUESTION FOR COORDINATOR:` when a change would alter a published
type that another running task also edits, when identity breaks and you
believe it benign, or after three hours without a measured result. Never
end a turn waiting on a build or gate; poll in a foreground loop.

Two rules learned the hard way on 2026-09-17: never use `git stash` in
these worktrees (the stash list is shared across every worktree of the
repo and pops race between sessions; snapshot with `git diff > file` or a
commit), and compare instruction counts only against a baseline built with
the same C toolchain (an Xcode update moved identical C by 3.8%; the r6
baselines are the current toolchain).

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
| 2 | T4 typecheck as a per-module facts record plus per-body builder | `stage_06_typecheck/state.brp`, `decl.brp`, `bridge.brp` | yes: independently checkable bodies | after the attribution checkpoint |
| 3 | T5 publish the definition table out of typecheck | `graph/definition_index.brp`, `decl.brp`, then mono, DCE, Perceus index builders | yes: symbol table | after T3, T4 |
| 3 | T6 key lowering's tables by definition and type id | `stage_08_core_lower/lower.brp`, `list_layout.brp` | no | after T5 |
| 2 | T7 parser nodes without per-node ownership traffic | `stage_03_parse` | yes: per-keystroke work | T1, T2, T4 |
| 2 | T7b parser cursor as a scalar (builder conversion) | `stage_03_parse/language_parser.brp` | yes | after T7 |
| 4 | T8 cacheable header completion (design) | `stage_06_typecheck/decl.brp`, `headers/` | essential | after T4 |

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

### T4. Typecheck as a per-module facts record plus per-body builder

**Context.** `TypecheckState` (`state.brp:207`) threads facts and
accumulators together through 328 parameters and returns a new state per
body (`TypecheckFunctionBodyResult { state, typed }`). Any update to a
shared dictionary field copies it (`blorp_dict_copy` in the profile).

**Numbers.** Dictionary copies are 17% of the typecheck subtree, about
3.6% of the compile; header completion is another 5.9%. Ceiling for this
task: 5 to 8% of the compile, plus the header pass becoming cacheable.

**Status (2026-09-17).** Landed as the header-install builder (`6ccd89809`); see the results table. The per-body split already existed (`InferModuleFacts`/`InferSession`). Two generated-C lessons from it: `result_aliases_var` treats a bare `acc` return bound from `state` as aliasing (return a record update instead), and `from_opaque` of a borrowed argument retains, so an opaque-wrapped dictionary updated through a helper copies unless the update is done at an assignment site from a local owner.

**Change.** Split as the closure conversion did: `ModuleFacts` (module
view, module scope, known-type index, type homes, private impls, admission,
flag) built once per module and passed by borrow; a per-body builder that
owns `errors`, `diagnostics`, and the inference context as locals and
returns typed declarations plus diagnostics. Keep the order in which
diagnostics are produced (they are part of the identity oracle through
`--typed-summary` and the diagnostic fixtures). Do the read/write audit
first (which fields are written where) and put the table in the first
commit message; the attribution checkpoint's per-body metrics
(`BLORP_TYPECHECK_BODY_METRICS=1`) are the before numbers.

**Acceptance.** Identical C; `typed_frontend_complete` allocations down
(target: at least 15%); `blorp_dict_copy` samples down; typecheck suites,
diagnostic fixtures, and compiler-check green. This is also the step that
makes a body checkable on its own, so record in the report what a body
needs from `ModuleFacts` and nothing else.

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
from-scratch compile T4 makes it cheaper; for an editor it must become
cacheable per module, keyed by a hash of the module's declarations.

**Deliverable.** A design note, not code: what the per-module header
product is, what it depends on (imports' surfaces), how it is keyed and
invalidated, and what T4's `ModuleFacts` needs to look like so that a
cached header product can be loaded in place of recomputation. Written
after T4 lands, by whoever did T4.

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
| F4 type-home table by definition id (T4, in flight) | typecheck header install | `DefinitionId -> TypeHomeEntry` | `TypeHomeIndex`, the per-importer reinstall | 3 to 5% | in progress |
| F8 cacheable per-module header product (T8, design) | typecheck | per-`ModuleId` completed headers keyed by content hash | the whole-program `global_header_completion` rebuild for the editor case | 0% cold, per-edit latency otherwise | design 1 day |

Vetted total for F1 to F7: 5 to 7% of the compile, plus F4's 3 to 5%,
about 1.5 to 2 s of the 17 s stage-2 self-compile. The architectural gain is
larger than the instruction gain: F1, F2, F4, and F8 are the tables a
language server queries and invalidates, and F2 and F5 delete four callable
index rebuilds and two 20-signature threaded dictionaries.

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
| T4 typecheck facts | closed, no code | | | `InferModuleFacts`/`InferSession` already exist; the dictionary copies are gate 1 of record reuse (a helper returning its parameter unchanged on one path), now the typecheck state reuse task |
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
| lexer token as inline struct with interned texts | in flight, branch `perf/lexer-token-struct` | | census: 1,746,333 tokens, 601,674 with payload, 1,289 with trivia; 84,531 distinct interned texts (7:1); with the compatibility view that rebuilds `TokenKind` per parser read, discovery allocations +137% | the parser now converts to tag matching with text reads through the table only where an arm needs them; target discovery -15% |
| r7 / s3 baselines | recorded | `fdb932b93` | bootstrap -O2 176.3G; stage-2 172.3G; small stage-2 -3.7% vs s2 | generated C changed on main through the C emitter's split layout, so r6 identity is stale; use r7 and s3 |
| T3 prep: `Token` as a scalar `struct` with an interned-text side table, `TokenKind` kept as a compatibility view (`token_kind_of`) so the ~100+ existing match sites needed no body changes | parked (tests/formatting only), branch `perf/lexer-token-struct` | `6846913d6` (WIP source), `ccd9a5cdd0d0` (merge), test/format follow-up uncommitted at hand-off | `source_discovery_complete` +137.39% (self: 14,536,422 to 34,508,446; small: 341,353 to 776,573); instructions +5.99%; identical C (128,438,702 bytes both sides); every phase after `typed_frontend_complete` +0.00% | census over the frozen self-compile input (1,961 files): 1,746,333 tokens, 601,674 (34.4%) carry a payload, only 1,289 tokens (0.07%) carry any trivia (4,315 trivia items). Interning itself works: 601,674 payload tokens intern down to 84,531 distinct texts, a ~7.1x dedup ratio, with a round-trip test (`intern_text` on a string literal followed by three identifiers) proving no off-by-one. The regression is not interning, and not `InlineStructListStorage` (a standalone `List` of 200 ten-`Int`-field structs, built by append and read by `for` and by index, passes clean): it is the compatibility view. `token_kind_of` rebuilds a fresh heap-boxed `TokenKind` union (with an interned-text lookup) on every call, and the parser reads the same token index through `current_token`/`current_token_kind` several times at many decision points (peek-then-consume), so every payload-carrying token pays a fresh allocation per read instead of the zero-cost field read the old record gave it — exactly the risk the brief flagged for this strategy, just larger than expected. Two real compiler bugs were found and fixed along the way and are not part of this regression: a pinned-bootstrap effect (the bootstrap predated a Perceus fix, so the branch's own literal-match arms were miscompiled by it regardless of source content) and the underlying fix itself, `09f3d900c` (Perceus's `protect_repeated_consumes` had no `LiteralMatchExpr` arm, double-releasing a var consumed inside a literal-match arm in a loop). Next: delete the compatibility view. Convert the ~100+ match sites in `language_parser.brp` to match on the scalar `TokenTag` directly and read payload text through the interned-text table only at the sites that actually need it, instead of reconstructing the whole union per read |
