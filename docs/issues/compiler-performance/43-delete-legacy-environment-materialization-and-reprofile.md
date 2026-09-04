# Audit Residual Environment Materialization, Delete Proven Legacy Scaffolding, And Reprofile

**Status:** Implemented and profiled

**Source audited:** `origin/main` at `3d8ec393` (`Remove dormant Env UFCS
compatibility path`).

**Dependencies:** Issues 33, 34, and 36-41 are complete. Issue 42's cleanup is
complete, while its candidate-selection rewrite was deliberately deferred
after the prototype increased Phase 01-06 retired instructions. That deferred
optimization is not a blocker for this issue. Issue 35 was rejected after its
production-path audit and is not an implementation dependency.

**Parallel work:** None. This is the final audit, deletion, and proof step for
the Stage 06 environment-reuse roadmap. It edits the same Stage 06 preparation,
observation, test, and architecture surfaces.

## Objective

Audit the current Stage 06 production path after the accepted-declaration
cutovers, delete only materialization and migration machinery proven obsolete,
make the remaining `Env` and session ownership explicit, and measure the final
Phase 01-06 architecture.

This is no longer a blanket instruction to delete every function whose name
contains `install`, `prepare`, or `environment`. Recent work has already moved
accepted graph-owned declaration payloads out of `Env`. Some remaining walks
project module-visible spelling or session facts, and the prepared canonical
module environment is the reuse product introduced by Issues 33-34. Classify
those paths before changing them.

## Implementation result

The audit retained the prepared module/session split and removed only proven
residue. Production changes delete constant-zero migration metrics, the
synthetic graph-to-`Env` publication model, four unreachable adapters, one
unused definition-replay local, and obsolete observation scans. The one active
production optimization checks accepted alias authority before doing
provisional payload work. Accepted aliases therefore skip parameter-name
mapping, resolved-target conversion, containment projection, and `Env` payload
construction while still recording the known name and opaque nominal home.

The final production and benchmark diff is net-negative. Permanent structural
tests prohibit the removed counters, model, helpers, and the old accepted-alias
ordering. Real observations remain for authority/category size, visibility,
module-view projection, canonical base construction, fresh body sessions, and
errors.

### Controlled Phase 01-06 result

The control was `3d8ec393b04dcab12dd50a6f754ff220f0de7b37`; the
candidate was the Issue 43 working tree on that parent. Both used bootstrap
`dev-aaa4b347bc5e`, `-O0`, and:

```bash
blorp/build/_build/blorp-cli/blorp check --no-format blorp/src/main.brp
```

The control and candidate executable SHA-256 values were respectively
`2bd9fad669a9a7797e099e32eacc42295749063986d22c330bb050c6b004e5d8` and
`6ae3827c96ed8bad1005ae035a67cd925d11fadb253620e87468d648efb9df86`.
After one warmup per executable, three uncontended alternating pairs produced:

```text
control:   16.76s / 295,631,209,625 instructions / 839,615,448 B peak footprint
candidate: 16.42s / 291,776,747,305 instructions / 832,996,288 B peak footprint
control:   16.70s / 295,665,614,952 instructions / 839,238,592 B peak footprint
candidate: 17.65s / 291,872,206,622 instructions / 833,668,032 B peak footprint
control:   20.06s / 295,863,786,936 instructions / 840,418,264 B peak footprint
candidate: 17.81s / 291,827,262,058 instructions / 832,586,688 B peak footprint
```

Median retired instructions fell 1.298%, from 295,665,614,952 to
291,827,262,058. Median peak footprint fell 0.788%, from 839,615,448 to
832,996,288 bytes. Median wall time moved from 16.76 to 17.65 seconds, but the
paired direction was mixed and the slowest run was the control; this is host
noise rather than a repeatable latency regression. Retired instructions are
the acceptance signal.

LLVM instrumentation made the alias mechanism exact. The accepted-path alias
installation specialization ran 24,177 times in both binaries. General
resolved-shape conversion ran 69,777 times in the control and 45,540 times in
the candidate: exactly 24,177 conversions were removed. The new accepted-only
session-fact projection also ran exactly 24,177 times. The authority-absent
provisional branch remains compiled and covered by focused tests.

The measured checkpoint still implemented its Boolean authority check through
payload-returning alias queries. Final review narrowed that check further to
scalar binding-kind and index-bounds membership, so the merged candidate does
not localize or retrieve an alias payload merely to prove presence. Per the
closeout instruction, this strictly narrower follow-up was covered by focused
and structural tests without starting another profiling round; the executable
hash and LLVM counts above identify the measured pre-review checkpoint exactly.

One comparable 1 ms macOS sample was collected for each executable. After the
cleanup, remaining top-of-stack cost is dominated by general ARC/list/dict
work (`blorp_release`, `blorp_retain`, list capacity copies, and dictionary
copies), not a residual graph-to-`Env` publication family. That evidence does
not by itself authorize Issue 44; any lexical-environment optimization still
needs a named production hotspot and its own fail-fast measurement.

The dense frontend harness (`dense 1 64 16 16 0`) retained identical category
counts and 65 canonical bases. Removing synthetic installation observation
reduced its measured allocations from 2,005,124 to 1,340,151 (-33.16%) and
releases from 2,005,122 to 1,340,150. This is chiefly deletion of benchmark
modeling work and must not be extrapolated to ordinary compiler latency.

## Current Source Reality After Issues 37-42

The implementation entering this issue has these accepted authorities:

| Accepted declaration family | Semantic authority | Visibility authority |
| --- | --- | --- |
| aliases | accepted alias graph/authority | module type view and type identity |
| records and fields | accepted record graph/authority | module type view and type identity |
| unions and constructors | accepted union graph/authority | module type view and type identity |
| globals | `AcceptedGlobalTable` | accepted global module authority |
| source and foreign callables | `AcceptedCallableTable` | accepted callable module authority |
| source overloads and source-function UFCS | `AcceptedCallableTable` | ordered accepted callable indices |
| traits, trait methods, implementations, and implementation methods | `AcceptedTraitImplementationTable` | accepted trait/implementation module authority |

Resource, debug-only, purity, generic, dimension, loop-producer, and foreign
facts are properties of the appropriate accepted type, global, callable, or
trait/implementation record. They are not separate declaration families and
must not acquire parallel catalogs in this issue.

The following are intentional and must not be mistaken for legacy duplication:

- `PreparedCanonicalModuleEnvironment` and
  `PreparedModuleDeclarationEnv` retain the reusable module base constructed
  once per accepted module.
- `PreparedInferSessionEnv` creates a fresh inference session from that base;
  ordinary bodies must not rebuild the module environment.
- compiler builtin types, functions, traits, trait-function associations, and
  implementations remain in `Env`;
- rejected or not-yet-accepted provisional header checking may use `Env`;
- nested lexical functions and variables remain in `Env` scopes;
- local type parameters, refinements, containment snapshots, definition-ID
  minting, and other check-local facts remain session-owned; and
- Issue 42's existing accepted-callable candidate-list query remains. It is an
  active authority reader, not a compatibility fallback.

The local/imported type-header routines require special care. When an accepted
record, union, or alias authority is present, these routines no longer publish
the accepted payload into `Env`; they may still record known-type or type-home
spelling facts needed by inference. Builtin headers still have a real `Env`
payload. Delete or rename these routines only after listing each retained side
effect and its production reader.

## Precondition: Produce The Final Ownership Ledger

Before deleting production code, complete this inventory from current source:

| Category | Accepted owner | Visibility owner | Allowed session/builtin residue | Production readers | Suspected obsolete readers/writers |
| --- | --- | --- | --- | --- | --- |

Cover:

- aliases, builtin types, records, fields, unions, and constructors;
- globals and completed initializer values;
- source functions, foreign functions, overloads, and UFCS candidates;
- traits, trait methods, implementations, and implementation methods;
- nominal type homes and imported spelling aliases;
- known-type/resource classification and containment facts;
- purity, resource-argument, debug-only, generic, dimension, and loop-producer
  callable metadata;
- compiler builtins; and
- provisional, recovery, CTFE, and ordinary-body paths.

For accepted graph-owned declarations, the ledger must show one semantic
authority and no required accepted-payload reader or writer in `Env`. A row may
legitimately retain a builtin, provisional, lexical, or session reader. Record
that exception precisely instead of forcing it into another catalog.

Use production call sites, not names, comments, or tests, as the authority
proof. A helper used only by tests is not a production requirement.

### Completed ownership ledger

| Category | Accepted owner | Visibility owner | Allowed residue in `Env` or session state | Production readers | Deleted residue |
| --- | --- | --- | --- | --- | --- |
| aliases | `AcceptedAliasTable` / per-module alias authority | module type view plus exact `TypeId` | provisional aliases; known names; opaque nominal homes | type resolution, containment/resource queries, imported spelling projection | accepted-branch target conversion and containment projection; constant-zero metrics |
| builtin types | type headers plus compiler builtin definitions | prelude/module visibility | builtin type payload, resource cleanup, known names, nominal homes | inference, resource cleanup, builtin validation | none; this is intentional `Env` data |
| records and fields | `AcceptedRecordTable` / record authority | module type view plus exact `TypeId` | provisional records; known names and nominal homes | field lookup, record construction/update, containment/resource queries | unused table extractor and local field adapter; constant-zero metrics |
| unions and constructors | `AcceptedUnionTable` / union authority | module type and constructor locators | provisional unions; known names and nominal homes | pattern checking, constructor lookup, containment/resource queries | unused local variant adapter; constant-zero metrics |
| globals and completed values | `AcceptedGlobalTable` | accepted global module authority | lexical variables only | initializer dependency planning and ordinary/CTFE global lookup | graph-global install telemetry and scan telemetry |
| source/foreign callables, overloads, UFCS | `AcceptedCallableTable` | ordered callable indices in module views | compiler builtins and lexical/provisional functions | exact call resolution, overload selection, UFCS selection | callable/overload install telemetry, exact-scan telemetry, synthetic copy model |
| traits, methods, implementations | `AcceptedTraitImplementationTable` | compact trait/implementation module authority | compiler builtin and provisional trait facts | method lookup, obligations, coherence, implementation selection | unused exact implementation adapter and constant-zero install/copy/scan metrics |
| nominal homes and imported spelling | exact type identity plus module view | module view | `TypecheckState` known-name/resource sets and type-home map | inference name resolution and owner/import localization | no accepted payload; retained projection is session-specific |
| callable metadata | owning callable or implementation record | callable/trait authority indices | lexical/provisional function metadata | purity, resource-argument, debug-only, generic, dimension, foreign, and loop-producer checks | no parallel metadata catalog |
| canonical module preparation | `PreparedCanonicalModuleEnvironment` with `PreparedModuleDeclarationEnv` and `InferModuleFacts` | bound module view | immutable builtin/provisional/session seed facts | initializer and ordinary-body session construction | synthetic publication counters and representation model |
| fresh inference sessions | `PreparedInferSessionEnv` derived from the canonical base | inherited module view | metas, diagnostics, refinements, lexical scopes and body-local definitions | expression/body inference | literal-zero body-rebuild/body-start counters; structural checks now prove the boundary |
| CTFE artifact checking | demand-built `PreparedAcceptedBodyModule` from retained graph facts | dependency-only module view | fresh CTFE session and definition-ID replay | CTFE dependency body checks | no graph-owned CTFE environment (Issue 35 remains rejected) |
| recovery/provisional checking | accepted headers where available, otherwise the existing provisional path | recoverable graph/module view | provisional declaration payloads and diagnostics | recovery and pre-acceptance checks | no fallback was removed where accepted authority is absent |

The audit also removed four production-unreachable adapters:
`accepted_record_graph_table`, `local_record_header_fields`,
`local_union_header_variants`, and `accepted_implementation_find_exact`.
Their absence, along with the obsolete publication model and constant-zero
fields, is now guarded by the declaration-catalog structural test.

## Mechanical Work

### 1. Separate real regression proof from migration telemetry

The authorities entering the audit exposed fields such as:

```text
legacy_alias_graph_symbol_installs
legacy_record_graph_symbol_installs
legacy_union_graph_symbol_installs
legacy_graph_global_installs
legacy_graph_callable_env_installs
legacy_graph_overload_installs
legacy_graph_trait_env_installs
legacy_graph_implementation_env_installs
```

These were assigned literal zero values. A constant-zero production
field cannot detect a future publication regression. Delete migration-only
fields that have no non-test reader and replace their tests with structural
assertions against the actual forbidden field, helper, and call-site names.
Keep counters that are computed from real work and prove catalog/view scaling.

The entering `FrontendDeclarationPreparationObservation` required the same
audit. Several fields used names such as `*_installations`, `scope_symbol_insertions`,
`environment_publications`, and `total_graph_declaration_installations` even
when the measured operation is now authority construction, module-view
projection, or session-fact registration. For each field:

1. identify the exact operation counted;
2. rename it if the operation remains useful;
3. delete it if it only models the superseded architecture; and
4. update the benchmark output and assertions in the same change.

Do not preserve misleading counters merely to keep historical benchmark column
names stable.

### 2. Audit the remaining type-header projection walks

Start at:

```text
prepared_module_environment_base_state
typecheck_register_import_modules_from
typecheck_register_import_module_types
typecheck_install_local_*_headers
typecheck_install_imported_*_headers
```

For every call, write down whether it performs one of:

- accepted payload publication into `Env` — forbidden and removable;
- compiler builtin installation — retained;
- provisional/recovery installation — retained;
- module-visible spelling/type-home projection — retained unless an existing
  authority already supplies the exact answer without a new scan; or
- no observable production work — removable.

The authority-present record path illustrates the required distinction:

```blorp
match module_view_accepted_record_authority(state.module_view):
	Some(authority):
		-- No accepted RecordSymbol is added to Env here. The remaining work
		-- records only the module/session spelling facts still read later.
		finalize_installed_type(...)
	None:
		-- Provisional pre-acceptance path used before authority exists.
		env_add_accepted_record(...)
```

If the accepted branch only projects session facts, prefer an accurate name
such as `project_imported_record_session_facts` over `install_*`. This issue may
make such a mechanical rename. If deleting the projection would require a new
authority, cache, invalidation rule, or broad inference rewrite, record that as
a follow-up rather than expanding this issue.

### 3. Audit broad records and helpers for production reachability

Inspect every field in:

- `Scope` and `Env`;
- `TypecheckState` and `InferModuleFacts`;
- `PreparedCanonicalModuleEnvironment` and accepted-body session seeds;
- `TypecheckGraphFacts`; and
- the accepted authority/view records.

Classify each field as accepted authority, module visibility, reusable module
fact, builtin/provisional declaration, lexical/session state,
diagnostic/recovery state, or deletion. Delete fields and helpers that are
always empty, always literal, derivable without repeated work, or referenced
only by tests.

Do not remove a field merely because its record is broad. In particular, do
not remove the prepared module environment or merge fresh inference state back
into it.

### 4. Delete verified compatibility surfaces in dependency order

For each ledger row with proven obsolete code, delete in this order so compiler
errors reveal missed consumers:

1. dead production callers;
2. category-specific graph-to-`Env` writers;
3. readers and adapters used only by those writers;
4. graph-only fields or indexes with no remaining production reader;
5. fallback and dual-read branches;
6. migration-only answer comparisons and constant-zero telemetry;
7. tests that only construct a state production cannot construct; and
8. stale imports, wrappers, names, comments, counters, and documentation.

Use `rg` after each family. Do not leave deprecated aliases or compatibility
wrappers; Blorp is pre-0.1.

## Required End State

`Env` is session-owned, not an accepted graph declaration catalog. Its
remaining contents must be attributable to one of:

- compiler builtins;
- provisional or recoverable header checking before accepted authority exists;
- lexical variables, parameters, or local functions;
- nested scope order and shadowing;
- local type parameters and bounds;
- flow-sensitive refinements and containment snapshots; or
- another explicitly named module/session fact that genuinely varies per
  check.

Accepted declaration payloads, accepted visibility, and graph identity must
remain in their category authorities and module views. Exact definition/source
navigation identity remains in `DefinitionIndex`.

## Permanent Structural And Scaling Proof

Prefer tests that fail when forbidden production code is reintroduced. Do not
add production fields whose only possible value is zero.

Structural checks must establish the absence of:

- accepted record/union/alias/global/callable/trait/implementation publication
  into `Env`;
- standalone `Env` overload or UFCS collections;
- accepted exact-callable recovery from `Env`;
- old/new dual reads and fallback lookup; and
- ordinary-body reconstruction of the prepared module base.

Retain or improve real observations proving:

```text
each accepted table construction == once per accepted graph
canonical prepared module bases == accepted module count
```

Ordinary-body reconstruction and accepted exact-query scanning are absence
properties, so this implementation proves them structurally. It does not keep
production counters whose only possible value is zero.

Also prove that authority construction scales with accepted declarations,
module views with actual visibility edges, and lexical insertion with
body-local declarations—not body count times a module's visible graph closure.

## TDD And Fast Feedback

1. Extend the Stage 06 declaration-boundary structural test with the precise
   stale fields/helpers found by the ledger. Demonstrate that it fails before
   each deletion.
2. Delete one coherent family of obsolete code at a time.
3. Run its focused authority, `Env`, inference, and production-shaped bridge
   suites.
4. Run the frontend declaration-catalog profile fixture whenever observation
   fields change.
5. Run `scripts/compiler-check --changed` after every coherent slice.
6. Run the full Stage 06 manifest only after focused checks are green.

Keep the implementation deletion-heavy. Do not add a cache, invalidation
scheme, generic declaration bag, another graph pass, or an Issue 42 candidate
selector.

## Controlled Phase 01-06 Reprofile

Only Phase 01-06 matters. Use the production `check --no-format` path for
`blorp/src/main.brp`; do not compile through Core or the backend merely to make
the profile longer.

Before production edits, record the exact current-main control commit, current
bootstrap compiler, command, build mode, and executable hash. Build isolated
control and candidate worktrees. After one warmup per executable, collect
three alternating, uncontended pairs using the same procedure used for Issues
40-42.

Record:

- LLVM retired instructions as the primary acceptance signal;
- unsampled wall time and peak memory as supporting signals;
- one external macOS 1 ms sample for the candidate and a comparable control;
- exact LLVM function-entry counts for the affected preparation/projection
  functions; and
- allocations, releases, retained objects, and bytes from the existing
  frontend declaration-catalog profile harness.

Compare Issue 43 to its immediate parent to detect a regression. Separately
summarize the roadmap's recorded before/after results only where the bootstrap,
command, and stop point are comparable; do not add percentages from unrelated
measurements or imply that inclusive sample percentages are predicted speedup.

The preferred result is fewer retired instructions. A deletion-only result
inside measurement noise may be retained for clear architectural value, but a
repeatable instruction, latency, or peak-memory regression is not acceptable.
Do not add an unrelated optimization to improve the number.

## Documentation

Update `docs/ARCHITECTURE.md` and the environment-reuse roadmap with:

- the final category-authority and module-view boundaries;
- the distinction between canonical prepared module facts and fresh sessions;
- the actual CTFE dependency lifetime, without introducing the graph-owned
  CTFE environment rejected by Issue 35;
- the builtin/provisional/lexical/session responsibility that remains in
  `Env`;
- deleted migration surfaces and renamed observations; and
- the measured final result and next Stage 06 bottlenecks.

Remove transitional wording that claims accepted payloads are still installed
into `Env`. Archive or update superseded performance claims only when their
premises no longer match source; preserve useful historical measurements as
historical evidence.

## Acceptance Criteria

- The ownership ledger is complete and distinguishes accepted declarations
  from builtin, provisional, lexical, and session facts.
- Every verified obsolete builder, field, adapter, fallback, test-only helper,
  and constant-zero migration counter is deleted.
- No accepted graph-owned declaration payload is stored in `Env`.
- The remaining type-header walks have accurate names/comments and perform
  only documented builtin, provisional, spelling, or session-fact work.
- `PreparedCanonicalModuleEnvironment` remains the reusable per-module base;
  ordinary bodies do not reconstruct it.
- Issue 42's deferred candidate-selection rewrite is not included.
- Permanent structural and real-work scaling assertions pass.
- Exact compiler results and diagnostic ordering remain unchanged.
- The production-source diff is net-negative; test and documentation changes
  are reported separately.
- Focused, Stage 06, compiler-owned, and proportionate leak/sanitizer checks
  pass.
- The controlled Phase 01-06 report records immediate-parent instructions,
  wall time, peak memory, allocations, and remaining bottlenecks with no
  material regression.
- No generated artifacts remain in the repository.

## Verification

At minimum, run:

```bash
scripts/compiler-check --changed
scripts/compiler-check --stage typecheck
scripts/test compiler-blorp
git diff --check
```

Run the focused declaration-authority, `Env`, inference, typecheck-bridge,
frontend profile, recovery, CTFE, debug-only, resource, foreign, and prepared
module fixtures selected by the changed manifest. Run leak or sanitizer gates
when ownership-bearing fields or managed adapters change. Run `make quality`
only if the deletion reaches C-facing code. Use the repository's current
premerge gate if it is proportionate at the final revision.
