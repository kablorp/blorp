# Step 4A: Meta-Session Issuer Preflight

**Status:** Issuer preflight and checked body/module/global-session projections complete.
This packet also records the focused benchmark and issuance contract. It does
**not** migrate solver metas to `MetaId` or change compiler semantics.

## Why a session key cannot be guessed

Packet 140 removed display-string identity from dimension factors, leaving
`SemanticMetaType(Int)` as the next identity boundary. Two independent solver
sessions can both issue slot zero. The current `Context` accepts either
integer as local to its own solver, so crossing contexts can resolve or bind
the wrong meta.

`fresh_meta(CONTEXT_EMPTY)` is pure. Calling it twice with the same value
cannot issue distinct sessions. A fix therefore has to receive an explicit
session identity when a fresh solver is constructed; a hidden global counter,
meta-count-derived epoch, source-name heuristic, or debug spelling would
weaken the compiler's value semantics or fail under reordered work.

The relevant production construction boundaries are:

| Boundary | Current constructor | Available logical owner | Missing distinction |
| --- | --- | --- | --- |
| Initial typecheck state | `typecheck_state_for_origin` uses `CONTEXT_EMPTY` | input/module origin | invocation and graph provenance |
| Prepared module state | `typecheck_session_for_prepared_module` calls `context_from_prepared_infer_facts` | `ModuleId` and prepared module scope | invocation/issuing `ModuleTable` provenance |
| Global initializer | `initializer_check_state` constructs a prepared-module session for each global | table-issued `GlobalId` | global owner and independent-check purpose at the constructor |
| Function body | `check_function_body_artifact` calls `fresh_body_infer_session` | table-issued `CallableId` | issuing definition table and check invocation/purpose |
| Body planning/recheck | `accepted_body_module_base` also calls `fresh_body_infer_session`; CTFE can check a body through the body worklist | same logical callable | planning versus normal/CTFE execution and repeated checks |

`reset_meta` and `context_for_fresh_infer_session` have no production callers;
tests and a benchmark use them. Both currently clear bindings without an
issuer argument. They must change or disappear when solver construction
requires a session key.

`ModuleId`, `CallableId`, and `GlobalId` wrap dense **table-local** indices.
Equal indices from separately issued tables are not proof of the same owner.
The session issuer must carry exact compilation/table provenance before
projecting these IDs into a compact solver key. Normal and CTFE checks of
one callable can also create separate solvers, so owner identity alone is
insufficient. This is why merely adding `session: CallableId` to every meta
would leave an aliasing hole.

## Original target contract

The shape is illustrative; the issuer representation must be selected at the
compilation root, where graph provenance and invocation identity are known:

```blorp
opaque type CompilationRunId = ...       -- issued at one explicit root
opaque type MetaSessionId = ...          -- run + owner + purpose/invocation
opaque type MetaId = ...                 -- session + dense solver slot

-- A fresh solver receives its identity. No same-input "mint" function.
func context_for_infer_session(
    facts: PreparedInferContextFacts,
    session: MetaSessionId,
) -> Context: ...
```

The issuer must be stable under source/reverse/shuffled body schedules,
distinguish independent contexts and CTFE rechecks, and reject IDs issued by
another compilation graph. The solver stores its session once and checks it
at `lookup_meta`, `bind_meta`, `occurs_meta`, unification, and zonking. A
`SemanticMetaType` and `DimMetaFactor` then carry nominal `MetaId`; dimension
results return `DimBindMeta(MetaId, SemanticType)`. No raw-`Int` compatibility
constructor or packed integer namespace should survive in production.

The first failing regression should construct two *explicitly different*
sessions, issue slot zero in both, bind one, and assert that the other remains
unresolved and cannot be bound through the wrong context. Passing the same
session to two value copies is intentionally **not** a distinct-session test.
Follow that with body-order and CTFE-recheck fixtures to verify deterministic
issuance and unchanged diagnostics.

## Fast feedback added now

Packet 140's equality benchmark did not enter `dim_solve_multiple_terms` on
its plain/multi-term workloads. The benchmark now accepts three expected-
result modes built outside the measured loop:

```bash
benchmarks/compiler_blorp_benchmark_runner \
    compiler-dim-canonical-factor-profile \
    blorp/benchmark/compiler/compiler_dim_canonical_factor_profile.brp \
    plain 8 4096 meta-bind

# Replace meta-bind with named-bind or stuck to screen those branches.
```

- `meta-bind` isolates a meta from a product remainder and requires
  `DimBindMeta(1, ...)`.
- `named-bind` isolates `#P` beside a non-exact division and requires
  `DimBindVar("#P", ...)`.
- `stuck` combines two unsolvable products and requires `DimStuck`.
  It requires width at least two so the first product is not itself a
  solvable dimension variable.

Mode dispatch happens once outside the repeated solver loop. The output
reports both `solved` and `matched`, so an unexpected `DimSolved` cannot make
a bind/stuck run pass. A one-time preflight also substitutes each proposed
binding into the original equation and requires `DimSolved`; it runs before
memory reset and timing, without retaining an extra product alias in the
measured loop. Each mode requires `matched == iterations` and zero retained
objects/bytes. One warm direct baseline at width eight and
4,096 iterations gives:

| Mode | Matched | Allocations/releases | Retired instructions | Sampled peak footprint |
| --- | ---: | ---: | ---: | ---: |
| `meta-bind` | 4,096 | 704,512 / 704,512 | 915,318,556 | 1,081,632 B |
| `named-bind` | 4,096 | 753,664 / 753,664 | 973,776,798 | 1,098,016 B |
| `stuck` | 4,096 | 593,920 / 593,920 | 790,028,161 | 1,081,632 B |

These are a *new baseline*, not an improvement claim. The formatted-source
worker key for this direct measurement is
`5df85f117d99119ef7031a389e2d39e27dc7dd1b327a39422eee0f95c6963056`.
Wall time is omitted because the short direct runs are noisy. This narrow
loop guards candidate-record construction, sorting, binding-value
reconstruction, and the stuck path during the future `MetaId` migration.

## Acceptance and next slice

This preflight is complete when all three new modes and the existing five
modes return their expected results, with zero retention; the benchmark
formats cleanly; and the exact issuer inventory above is reconciled with
normal, planning, initializer, and CTFE call paths. No broad production test
claim follows from a benchmark-only edit.

The next implementation slice should introduce the explicit compilation
issuer at the root and thread it to each fresh solver boundary, then migrate
`MetaId` and all solver/dimension consumers together. If provenance cannot
be represented without a process-global counter or a large per-meta payload,
measure a smaller issuer design before changing `SemanticMetaType`.

## Follow-up: rejected pure graph-token prototype

A follow-up prototype placed an opaque record on `IndexedGraph` and compared
its allocation address to distinguish two graph builds from identical input.
Its focused graph test passed, but review found that this is **not** a sound
issuer contract: the record was created by a pure same-input constructor, and
future `MetaId` correctness would depend on whether equal values happen to
share an allocation after copying or optimization. The existing
`IndexedGraph` allocation check is only a fast path with semantic fallback;
it does not authorize correctness-critical graph identity. The prototype was
removed without changing production code. The changed-owner gate also exposed
that a new production module would need explicit manifest ownership; this was
not a reason to retain the design.

`ModuleTable` and `DefinitionTable` already use exact allocation provenance
for their table-local IDs. That is precedent, not proof that a new
correctness-critical identity survives optimized copying. Table provenance
also cannot by itself distinguish two independent solver sessions for one
body, planning versus checking, or a CTFE recheck. Conversely, a new pure
graph-token constructor merely repeats the same-input mint problem. Before
migrating `SemanticMetaType`, the issuer implementation must settle the
**compiler host/typecheck entry boundary**. Two candidate strategies remain:

1. Pass an explicit compilation-run key through pure typecheck APIs, with
   issuance owned by an explicit host state; or
2. Use table allocation as one run-provenance component, **only if** an
   optimizer/runtime identity guarantee is established. An explicit issuer
   must still assign distinct invocation keys for repeated checks of the
   same owner and purpose; a static purpose enum is insufficient.

Both strategies need explicit, schedule-stable identity for every fresh
solver, assigned before body execution order can affect it. Neither permits
deriving session identity from source spelling, an unscoped integer meta slot,
or an allocation created *inside* a pure solver constructor. The first
implementation test must use two explicitly different sessions with slot
zero, while a separate test must demonstrate that passing one session through
a value copy preserves identity. Once the issuer contract is chosen, the
migration should be one coordinated change across
`SemanticMetaType`, dimension factors/results, `Context`'s sole solver writer,
all fresh-session constructors, and the normal/CTFE body paths. Smaller
traversal optimizations do not close this safety boundary.

## Follow-up: explicit run-capability first cut

The first production identity primitive is now `CompilationRunToken` in
`type_system/meta_identity.brp`. Its no-input constructor is deliberately
**impure** and allocates one opaque ARC-managed record. Copying the token
retains the same capability; a second constructor call yields a different
capability even with identical source inputs. The equality operation compares
the retained allocation, and the generated C calls `blorp_alloc` directly.
This avoids the rejected pure graph-token mint. It has not yet been threaded
through CLI/LSP/typecheck entry points.

A trial `MetaSessionIssuer` carrying `{run, next_session}` was also removed
after review. Two calls starting from a copied or reset issuer can both issue
ordinal zero for one run. The resulting IDs compare equal even if a caller
treats those checks as independent. Pure value-state counters are suitable
for **deterministically assigned work-item keys**, but cannot by themselves
guarantee fresh session identity after a value fork. The next implementation
must assign a typed key at the body/module/global planning boundary, before
schedule-dependent execution, and make independent rechecks explicitly
different. The trial's counter-based session ID and solver API were removed;
the later definition-bound body-session cut uses explicit keys instead.

Fast feedback for this boundary is:

```bash
bin/blorp test blorp/test/compiler/stage_06_typecheck/type_system/test_context.brp
bin/blorp test --leak-check blorp/test/compiler/stage_06_typecheck/type_system/test_context.brp
bin/blorp run --release --no-format \
  blorp/test/compiler/stage_06_typecheck/type_system/fixtures/meta_identity_release_probe.brp
scripts/compiler-check --changed
```

The focused suite passed 33/33; the token case's leak check reported three
allocations and three releases, with zero leaked bytes. The optimized release
probe returned success, covering distinct fresh calls and retained-value
copying. This is an identity/lifetime guard, **not** a whole-compiler resource
claim: no production compilation path calls the new token constructor yet.
Step 4A still needs module/global work-item/session-key assignment,
session-owned semantic-meta migration, normal/CTFE cross-session solver tests,
and the multi-metric guard.

## Follow-up: definition-bound body sessions

The next bounded cut introduces `MetaSessionId` as an opaque tuple of retained
run token, exact definition table, dense owner index, explicit owner kind, and
explicit invocation index (the table/kind fields were added in subsequent
cuts below). `meta_body_session` is a low-level representation mapper:
equal explicit keys map to equal sessions, while a different run, owner,
purpose, or invocation maps to a different session. Negative indices are
rejected. It is **not** a freshness generator; a caller that checks the same
body twice must plan distinct invocation indices rather than copy a pure
counter and assume uniqueness.

The checked body boundary binds run issuance to one exact accepted
`DefinitionTable`:

```blorp
run = new_definition_meta_run(accepted_typecheck_module_definition_table(module))
session = body_check_context_meta_session(
    context, run, NormalBodyMetaSession, planned_invocation,
)
```

`new_definition_meta_run` is impure and retains `{definition_table, token}` in
an opaque scope. A copy preserves both. A second call allocates a distinct
token, even for the same table. The body context derives its exact accepted
definition table through the `PreparedModuleScope` already retained by the
body plan. It rejects a run bound to another table before projecting the
`CallableId`'s dense definition index. This avoids both collision holes in an
earlier wrapper trial: structural table compatibility (which could accept
separately issued equal tables and scan every row) and a bare token passed
independently from the table (which could be reused across two valid
contexts with the same numeric definition index). No extra table field is
stored on every body plan.

The later pure binder described below supersedes the bare-token rejection:
the table is now part of `MetaSessionId` itself, so sharing one token across
two tables cannot make their same-numbered owners equal.

The boundary is covered by two independently accepted modules with identical
source. Each context accepts its own run, rejects the other's; their
same-numbered body sessions differ. A separately issued run for one table
also differs, while a copied scope maps to the same explicit key. The
low-level module's release probe checks that optimized C preserves token
copy and distinct-allocation identity. The low-level mapper remains available
to its test and checked wrapper; production solver consumers must use the
checked boundary, not assemble a session from an unvalidated integer.

Focused body-order and context suites pass 26/26 and 34/34, respectively,
both normally and under ASan/UBSan. Changed-owner checks pass for two sources
and seven suites; the optimized-release identity probe exits successfully.

A follow-up boundary guard now scans all Blorp production sources and permits
the raw `meta_body_session` mapper and impure token constructor only in their
representation module and the checked declaration owner. The declaration
boundary suite protects that allowlist and verifies that the only calls in
the declaration owner are inside its bound-run constructor and checked body
wrapper. A later solver call therefore cannot silently bypass exact-table
admission. A two-body plan regression projects session IDs
before and after reversing body order: each body keeps its own ID, and the two
bodies remain distinct. This confirms the explicit key is order-independent;
it does not yet mean production body execution consumes the session.

This is still a representation/authority cut. The typecheck CLI and LSP do
not issue `DefinitionMetaRun` yet, normal/CTFE work items do not assign
invocations, `Context` does not retain a session, and `SemanticMetaType(Int)`
does not carry session provenance. Next, thread a run from the host
through accepted module/global/body planning, assign stable typed work-item
keys before scheduling, and then migrate the solver's one meta writer and
all readers together. Keep the existing dimension and selected CTFE probes
as cost guards; do not infer a memory-ceiling benefit from this unexercised
representation alone.

The new native identity helper also needs its `type_system` include directory
in every generated-C build path. The Makefile, benchmark runner, standalone
typecheck-worker builder, and rebuilt-CLI test now declare that directory;
the benchmark and build-configuration contract tests check the paths. The
selected CTFE guard remains valid: checksum 2,538, 72 dependency body checks,
three reuses, zero errors, and 770,145 allocations / 770,142 releases with
three retained objects / 192 B. These match the immediately preceding
selected baseline exactly. One warm elapsed sample was 93,666 → 93,853 µs;
that difference is noise, not a latency claim. The selected worker size was
6,399,712 → 6,399,888 B (+176 B, under 0.003%). Retired instructions and
peak footprint were not resampled for this cut; because production has not
begun issuing sessions, these numbers guard incidental overhead only.

## Follow-up: rejected heap `MetaId` representation

A nominal `MetaId` prototype paired the retained `MetaSessionId` and dense
slot in an opaque record. It passed focused identity tests, ASan/UBSan, and
an optimized-release probe: equal session/slot keys compared equal; a foreign
session could not project its slot. The generated C nevertheless called
`blorp_alloc` in `MetaIdRep_make`. A first standalone 4,096-key issue/read
probe measured 4,096 allocations and 4,096 releases for the record versus
zero for a scalar. That scalar branch did less work, so elapsed times from
that pair are **not** a fair latency comparison.

The retained probe now models embedding inside a meta-type union. At 4,096
nodes, a raw-index variant and a flat `{session, slot}` variant each allocate
4,096 objects; the heap `MetaId` nested inside the variant allocates 8,192.
All three modes release every object and retain zero bytes. This isolates the
record's deterministic **extra** allocation per meta before additional ARC
traffic through solver bindings and dimension factors. It is enough to reject
the record as the default performance-sensitive representation. The flat
variant is an allocation-neutral *candidate*, not a production design or an
instruction/peak-memory claim; it still needs integration, lifetime proof,
and multi-metric measurement.

A `private struct MetaIdRep {session: MetaSessionId, slot: Int}` was tried
first. Blorp rejects it because structs cannot contain a retained opaque
record field. Encoding the session as an unretained pointer-sized scalar
would make identity depend on address reuse after the run is freed; a packed
integer or hidden global issuer would violate the stated contract. Neither
was retained. The production `MetaId` prototype and its tests were removed.
The local record and flat-payload candidates remain only in the retained
`compiler_meta_identity_profile.brp` benchmark, so a future representation
can be screened with the same narrow allocation loop:

```bash
benchmarks/compiler_blorp_benchmark_runner \
    compiler-meta-identity-profile \
    blorp/benchmark/compiler/compiler_meta_identity_profile.brp \
    plain -- 4096 heap

# Replace heap with raw-meta or flat-meta for the union-payload comparison.
```

The production ingress map explains why this cannot be repaired by minting
inside an existing pure constructor: `pipeline.brp`'s frontend typecheck
entry, `frontend_graph_typecheck.brp`, `bridge.brp`'s graph typecheck entry,
`typecheck_state_for_origin`, and body checking are all pure. The next
coherent migration must bring an impure run capability in from each CLI/LSP
host entry, carry explicit module/global/body work-item keys through those
pure APIs, and make solver construction require a validated session. The
flat-payload candidate would keep `(session, slot)` together in each meta
variant rather than add a nested heap `MetaId`; use a nominal scalar slot or
checked constructor if necessary to prevent arbitrary indices. It must be
screened in actual `SemanticMetaType`, dimension factors/results, solver
bindings, and body/CTFE handoffs before acceptance. Do not introduce an
unvalidated raw-`Int` compatibility path while changing these boundaries.

## Follow-up: checked prepared-module sessions

`PreparedModuleScope` is the earliest table-backed module owner in the current
typecheck path. `prepared_module_scope_meta_session(scope, run, invocation)`
derives the scope's retained `DefinitionTable` and requires its exact
provenance to match the table bound to `DefinitionMetaRun`. It validates the
scope's `ModuleId` against the run's module table before projecting the dense
module index. A separate graph with identical source and same-numbered module
IDs is rejected; a copied scope and run produce the same key. Distinct modules,
runs, and explicit recheck invocations produce distinct keys.

`MetaSessionId` now includes a private owner-domain kind. A module's table
index and a body's definition index may both be 7, but cannot compare equal
under the same run and invocation. This is a scalar enum field in the existing
opaque session record, not another per-meta heap box. The raw
`meta_module_session` mapper is guarded alongside the raw body mapper: only
the checked declaration owner may project a table-local index into it.

The new indexed-graph fixture failed first because the checked projection was
absent, then passed with 23/23 tests. The focused context suite passed 35/35,
body order passed 26/26, and all three suites passed under ASan/UBSan. The
production-source boundary guard passed 62/62, the optimized-release identity
probe exited successfully, and the changed-owner gate passed two sources/eight
suites. A single selected CTFE smoke kept checksum 846, 24 dependency body
checks, one reuse, zero errors, 256,715 allocations / 256,714 releases, and
one retained object/64 B. These are exactly one third of the preceding
three-iteration selected guard's counts; no latency claim follows from the
single elapsed sample. These checks establish issuance semantics only:
production module inference still constructs its solver without the session,
and global initializer work has no checked session projection yet. The next
cut should give global initializer work an exact table-backed owner and then
thread the explicit run through the host/typecheck entry before replacing raw
solver meta indices. Do not infer compilation resource improvements from
unused issuer APIs.

## Follow-up: plan-owned global initializer sessions

The global-header completion plan previously exposed four aligned lists of
pending/annotated headers and dependencies but did not retain the
`DefinitionTable` that issued each header's `GlobalId`. Accepting a caller's
bare `GlobalId` at a session boundary would allow an equal numeric ID from a
separate graph to be interpreted under the run's table. The opaque plan now
retains its table once and exposes an ordered header projection: pending
dependency order followed by annotated stable order. No per-global issuer
record or parallel session list is allocated.

`global_header_completion_plan_meta_session_at(plan, run, plan_index,
invocation)` validates the plan's exact table provenance, obtains the header
from that plan position, confirms its ID names a global row in the run table,
and maps the dense definition index to the distinct global-initializer
session domain. A foreign but source-identical plan/run pair is rejected;
two plan positions, two runs, and explicit recheck invocations differ. Invalid
positions and negative invocation indices fail closed. The low-level
`meta_global_session` mapper is covered by the same production-source guard
as the body and module mappers.

The current completion loop already uses this pending-then-annotated order
and an index for its aligned dependency lists. When solver execution starts
consuming the session, the plan position must travel with that header and its
dependencies as one work item; independently re-enumerating a reordered
header list would associate a valid session with the wrong initializer.

The declaration fixture failed before the checked API existed, then passed
160/160, including a mixed pending/annotated forward-dependency plan whose
positions remain stable under reversed session queries. The changed-owner
gate passed three sources, ten suites, and one leak check. The selected
focused suites passed 272/272 normally and under ASan/UBSan; the boundary
guard passed 62/62, and the optimized-release identity probe exited zero.

One selected CTFE iteration retained the prior module-cut counts exactly:
checksum 846, 24 dependency body checks, one reuse, zero errors, 256,715
allocations / 256,714 releases, and one retained object/64 B. A direct warm
cached-worker pair measured 680,524,718 → 680,349,635 retired instructions
(-0.026%), 14,860,576 → 14,893,344 B sampled peak footprint (+0.22%), and
6,399,888 → 6,399,968 B worker size (+80 B). These are near-parity screens,
not a wall-time or memory-ceiling improvement claim from one pair. This
pair used cached workers `29145e3ddf39b63b0d71d5419a985fd4e6d170270013fb518baf997018b8bf58`
and `ffcdfe42877dbc2c259ab52aeb343487ef6959cde6cfc26eb8e65a9b3203e2a1`.
This proves an exact plan-owned key, not production solver ownership. Global
initializer execution still constructs a
raw-index solver; `DefinitionMetaRun` is not yet threaded from the host. The
next coherent cut should assign invocation keys for normal/CTFE rechecks at
their scheduling boundary and carry a run through the graph/typecheck entry
without creating a pure same-input issuer or a raw-index compatibility path.

## Follow-up: pure binding of a host run to a prepared table

Graph construction and typechecking remain pure, while
`new_compilation_run_token()` must be impure to distinguish separate host
invocations. The host can now issue that token before graph preparation and
bind it afterward with `definition_meta_run_for_table(table, token)`, which is
pure. The opaque `MetaSessionId` retains the exact `DefinitionTable` alongside
the run token, owner-domain kind, table-local index, and explicit invocation.
Equality checks table provenance as well as the remaining key fields. Thus
the same host token may safely be bound to two independently prepared,
source-identical tables without aliasing their same-numbered owners. Binding
it twice to the *same* table produces the same explicit key. The impure
`new_definition_meta_run(table)` remains a convenience for focused callers;
it delegates to the pure binder with a freshly issued token.

```blorp
token = new_compilation_run_token()  -- impure host boundary
-- Pure graph preparation creates the accepted table here.
run = definition_meta_run_for_table(accepted_table, token)
session = body_check_context_meta_session(body_context, run, NormalBodyMetaSession, 0)
```

This adds one retained table reference per session, not per semantic meta.
The same-token/two-table body fixture failed before the binder existed and
now checks both non-aliasing and rejection of crossed run/context pairs. The
optimized-release identity probe checks the same provenance distinction at
the low-level mapper. Production compilation still does **not** thread the
host token into typecheck or pass these sessions to the solver; this change
only makes that threading sound at the pure/impure boundary.

The retained identity probe (4,096 keys, one run/table constructed outside
the measured loop) reports 4,096 allocations/releases and zero retained
objects for both raw-index and flat session-owned union payloads; the
heap-record candidate still reports 8,192 allocations/releases. These
counts support the flat representation's allocation neutrality in this
isolated case, not a whole-compiler latency or memory claim.

A single selected CTFE iteration also kept the previous checksum 846, 24
dependency body checks, one reuse, zero errors, 256,715 allocations /
256,714 releases, and one retained object/64 B. This is an allocation and
retention parity check only; one elapsed sample is not a latency comparison.

Review identified a layering prerequisite for the actual `SemanticMetaType`
migration: `meta_identity` currently imports `definition_index` to retain the
table, but `definition_index` reaches `semantic_type` through builtins/env.
Making `semantic_type` import a `MetaId` from `meta_identity` would close a
module cycle. Before that migration, extract a lower-level table provenance
and session-identity boundary (or equivalent phase-neutral table storage)
that semantic types can import without reaching back into `definition_index`.
Preserve exact table provenance and retention; a bare numeric or unretained
pointer substitute would reopen the aliasing/lifetime hole. Measure the
extraction separately before replacing solver-local indices.

## Follow-up: phase-neutral definition-table storage

The frozen `DefinitionTable` representation, its row/kind types, and its
pointer-equality provenance check now live in `graph/definition_table_storage`
below both the graph index and semantic type system. `meta_identity` imports
that small storage module rather than `definition_index`, so a future
`semantic_type → meta_identity` edge will not itself create the prior cycle.
The table still is the same opaque, ARC-retained allocation: no pointer-derived
integer, duplicate identity token, or per-row/session side table was added.

`definition_index` remains the sole production construction boundary. It
re-exports the existing `DefinitionTable`, `DefinitionRow`, and
`DefinitionKind` type names as aliases, while its five table-construction
sites use storage constructors for initial/frozen tables, row append, and
module-table rebase. Only four internal test/owner imports of enum variants
move to the defining module, because aliases do not re-export constructors.
A declaration-boundary guard rejects use of those storage constructors by
other production modules and rejects a new semantic-type dependency in the
storage module. A failing-first guard detected the original
`meta_identity → definition_index` edge; the definition-index suite then
passed 11/11 with the extracted storage.

The changed-owner gate passed for six production sources, 18 focused suites,
the declaration-boundary check, and the serial leak check. The focused
definition-index, index-identity, index-reservation, and body-order suites
passed 11/11, 13/13, 9/9, and 27/27 under ASan/UBSan. The optimized-release
session identity probe exited zero. One selected CTFE iteration matched its
prior checksum 846, 256,715 allocations / 256,714 releases, and one retained
object/64 B exactly. This is an allocation/retention parity screen, not a
multi-sample latency claim.

One direct cached-worker pair measured 683,075,278 → 662,095,168 retired
instructions (-3.07%) and 14,876,960 → 14,926,112 B peak footprint
(+0.33%); worker size was 6,399,968 → 6,400,576 B (+608 B). The pair uses
pre-extraction worker `7c53b6086b7cb1a8ae8db7a07241fe3b5c4d2da89c6e3676580f4cd3ce31026b`
and extracted worker `a6447af467593f330422e41f2eb4acbfce7a3de6bb49a82e9c3015f707dd88e6`.
These one-pair values screen for a large regression, not a stable speedup.

The next cut can place a flat session-owned `MetaId` below `semantic_type`,
then migrate solver and dimension/body handoffs together. Explicit normal and
CTFE invocation keys and host token threading are still required. The alias
and constructor split is compiler-internal; no source-language behavior is
intended to change.

## Follow-up: distinguish selective CTFE from eager fallback

The selective CTFE dependency worklist may check a body, then abandon its
attempt and invoke eager dependency preparation. The eager path can construct
a fresh solver for the same table-issued callable. A single undifferentiated
`CtfeBodyMetaSession` purpose with invocation zero would give both solvers the
same identity. The checked issuer now uses distinct
`CtfeSelectiveBodyMetaSession` and `CtfeEagerBodyMetaSession` purposes;
`NormalBodyMetaSession` remains separate. The raw mapper converts each into a
distinct private session kind, and repeated checks within one purpose still
require an explicit distinct invocation number.

```blorp
selective = body_check_context_meta_session(context, run, CtfeSelectiveBodyMetaSession, 0)
eager = body_check_context_meta_session(context, run, CtfeEagerBodyMetaSession, 0)
-- Same callable/table/run, but independent fresh solver attempts.
```

A failing-first test established that both CTFE purposes were missing. The
low-level context fixture checks selective/eager and eager recheck separation;
the accepted-body fixture checks the exact-table owner boundary, and the
optimized-release probe checks the distinction under C optimization. Focused
context and body-order suites pass 36/36 and 28/28. This does not yet cause
production CTFE to construct a session-aware solver. The host run must be
threaded through the worklist and eager fallback together, with the
invocation number assigned by the schedule rather than inferred from source
names or the order in which bodies happen to finish.

Independent ASan/UBSan runs passed 36/36 context and 28/28 body-order tests;
the optimized-release identity probe exited zero and the boundary guard
passed 64/64. One selected CTFE iteration kept checksum 846, zero errors,
24 dependency body checks, one reuse, 256,715 allocations / 256,714 releases,
and one retained object/64 B—identical to the preceding resource screen.
The selected benchmark worker stayed 6,400,576 B. No latency conclusion
follows from that one sample; production solver execution does not consume
the new purposes yet.

There is a second concrete repeated-check path inside eager preparation:
`prepare_ctfe_dependency_program` can attempt artifact-backed construction,
receive no program, and then run bound-module construction for the same
dependency. Those two eager solver attempts need distinct planned invocation
numbers (for example artifact attempt 0, bound fallback 1) even though their
purpose is the same. Add a regression at that scheduling handoff when the
session is first consumed; do not assume a single eager attempt per body.

The pre-table bootstrap boundary now rejects an unscoped typecheck state whose
solver still contains inference metas when entering a prepared module scope.
Those retained metas cannot be assigned the prepared graph's session after the fact.
The focused state test failed before this guard and passed 22/22 afterward;
ordinary empty-solver scope entry remains covered by the existing reserved
scope tests. This is a local guard, not proof against a meta that escaped into
another value before a solver reset; the full migration must make construction
session-aware at the indexed-graph handoff.
The changed-owner gate passed seven production sources, 22 focused suites,
the declaration-boundary check, and the serial leak check after this guard.
One selected CTFE run retained checksum 846, 24 dependency body checks, one
reuse, 256,715 allocations / 256,714 releases, and one retained object/64 B,
matching the prior allocation and retention screen. The single elapsed sample
is not latency evidence.

## Follow-up: cheap same-allocation session comparison

The eventual solver will compare many metas against one retained session.
`meta_session_ids_equal` previously unpacked both session records and checked
run/table provenance and all key fields even when both arguments were copies
of the *same* allocation. It now checks that allocation first. This is safe
only while both operands are ARC-retained, which the `MetaSessionId` arguments
guarantee. Separately reconstructed equal keys still take the full comparison;
the existing same-key and foreign-key tests, plus an explicit copied-session
assertion, cover both paths. Generated C has a pointer-equality branch before
the record retains and field comparisons.

In the retained 200,000-key flat-union probe, two additional alternating
old/new pairs measured 285.2–285.5 million → 263.2–263.4 million retired
instructions (about 7.7% lower). Both versions allocated/released 200,000
objects, retained zero, and had sampled peak footprint in the 1.61–1.66 MB
range; the new worker was 96 B smaller. The raw-index control remained near
251 million instructions. This is a focused *candidate comparison-cost*
improvement, not a whole-compiler gain: production `SemanticMetaType` still
uses raw indices and the solver does not yet call this equality path.
The focused context and indexed-graph suites passed 36/36 and 23/23, the
context suite passed 36/36 under ASan/UBSan, and the changed-owner gate passed.
One selected CTFE iteration kept checksum 846, 24 body checks, one reuse,
256,715 allocations / 256,714 releases, and one retained object/64 B exactly;
its single elapsed value is not a latency comparison.

## Step 4A completion path (no more issuer-only slices)

The remaining change is coordinated. A session-aware `SemanticMetaType`
cannot be installed alone: the solver, dimension factors/results, all fresh
solver constructors, and the normal/CTFE scheduling paths must agree on one
identity. Keep the next work on this path rather than adding another unused
issuer API or a raw-index compatibility variant.

A one-off local representation probe ruled out a tempting shortcut: nesting a
transparent `(MetaSessionId, Int)` tuple in the candidate meta union made
4,096 keys allocate/release 8,192 objects, versus 4,096 for the direct flat
`(session, slot)` variant. The tuple candidate was removed after the probe and
is not a retained benchmark mode; the permanent benchmark still compares raw,
flat, and heap-record representations. There is no production representation
change. The coordinated migration
should use the direct flat variant payload, not an alias that hides an
aggregate allocation.

1. Establish one pure run-aware typecheck worker and impure compiler-host
   wrappers that issue one `CompilationRunToken` per independent invocation.
   Audit every graph-executing ingress: `typecheck_graph`,
   `typecheck_frontend_graph_ids`, `typecheck_graph_with_metrics`, streaming
   and traced graph preparation, and the source-artifact/`handle_typecheck_source`
   path; the LSP service must use a run-aware execution path too. Propagate the
   necessary impurity through `typecheck_frontend_graph_direct` and its pure
   frontend/pipeline callers, or move their execution behind an impure wrapper.
   Bind the run immediately after a successful `indexed_graph_build`, using
   that graph's definition index/table, *before* binding, header completion,
   global evaluation, CTFE, or body work may issue metas. Reject or explicitly
   reconcile any later table-provenance change. The pre-table state constructor
   currently bootstraps builtins with an empty solver; it must not issue metas
   before this bind. Do not retain the run in emitted/Core products.
2. Require an explicit checked session at every fresh solver constructor:
   initial/prepared module work, plan-owned global initializer work, body
   planning, ordinary body checking, selective CTFE, eager artifact work, and
   eager bound fallback. Do not let `CONTEXT_EMPTY`, `reset_meta`, or copied
   prepared facts silently create a second solver under a reused key. Assign
   invocation numbers at the scheduling handoff, not when work finishes.
3. Change the `SemanticMetaType` payload and typed dimension factors/results
   together to a flat session-plus-slot identity. Have the opaque solver
   retain its session once and reject a foreign session at lookup, bind,
   occurs, unification, and zonking. Avoid a nested heap `MetaId` record; the
   retained flat-payload probe is allocation-neutral while that record doubled
   per-key allocation calls.
4. Permanently test the old cross-session slot-zero alias, normal/reverse body
   order, selective-to-eager fallback, artifact-to-bound eager fallback,
   dimension bind/stuck and opaque-factor distinctions, reset/recheck, and
   exact diagnostic order. Then run the focused solver/dimension probes,
   changed-owner gate, sanitizers, and a small number of selected CTFE
   resource pairs. Accept 4A only when no unresolved meta reaches accepted
   body/CTFE/Core products and no material allocation, instruction, memory,
   or worker-size regression remains.
