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
  has 13 fields and is threaded through 328 parameters; every body returns
  `{state, typed}`. Seven of its fields are per-module facts (module view,
  module scope, known-type index, type homes, private impls, admission, a
  flag); the rest are accumulators. Ids already exist in `graph/`
  (`SourceNameId`, `DefinitionId`, `FieldId`, `ConstructorId`, `TraitId`)
  but 126 dictionaries are still keyed by `String`, against 138 by `Int`.
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
layouts, and core types by type name.

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

## Results

Filled in as tasks land, one row per task, with the pass row, the
whole-compile instruction delta, and the string-lookup sample counts.
