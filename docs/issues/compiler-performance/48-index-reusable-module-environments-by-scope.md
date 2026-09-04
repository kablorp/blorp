# Index Reusable Module Environments By Prepared Scope

**Status:** Rejected after focused and production measurement

**Dependencies:** Issues 34, 46, and 47 are complete. Issue 34 created
`PreparedCanonicalModuleEnvironment`; Issue 46 retained the private validated
module slot in `PreparedModuleScope`; Issue 47 proved that the slot can address
one graph-owned dense product without changing durable module identity.

**Blocks:** Issue 49 should use the result of this issue as its immediate
baseline, whether this candidate is retained or rejected.

**Parallel work:** None in `decl.brp`, accepted/recoverable graph construction,
prepared environments, or prepared-scope compatibility.

## Objective

Replace retained accepted/recoverable graph linear scans of reusable module
environments with one validated `PreparedModuleScope` slot lookup. Reuse the
existing target-first environment list and Issue 46 scope index. Do not add
another module table, identity interner, dictionary, or public numeric module
ID.

This issue is a lookup cutover, not a representation program. It must remove
measured scan/equality work immediately and must remain bounded to reusable
canonical environments.

## Required Reading

Before editing, read:

- `AGENTS.md`;
- Issues 34, 35, 45, 46, and 47;
- `blorp/src/compiler/stage_06_typecheck/decl.brp`;
- `blorp/src/compiler/stage_06_typecheck/graph/indexed_graph.brp`;
- `blorp/src/compiler/stage_06_typecheck/modules/bound_module_graph.brp`;
- the prepared-environment, accepted-graph, recoverable-graph, CTFE, and
  typecheck-profile tests; and
- the ownership manifest entries for every changed production module.

## Current Behavior

`prepared_module_environments` constructs canonical environments in the same
target-first order as the bound graph:

```blorp
modules = [
	bound_module_graph_target(bound_graph),
].concat(bound_module_graph_modules(bound_graph))
```

The graph completion boundary rejects a result whose environment count does
not equal the expected graph module count before it constructs either an
accepted or recoverable graph. The builder visits every module once and appends
at most one environment per visit, so equal final length proves every visit
succeeded and positions remain aligned. Both retained graph forms therefore
have one environment for every slot in graph order. Recoverability records
global-completion failures; it does not permit a missing canonical environment.

Current lookup ignores the accepted dense invariant and scans by durable
identity:

```blorp
private pure func prepared_module_environment_find(
	facts: TypecheckGraphFacts,
	module_identity: ModuleIdentity,
) -> Option[PreparedCanonicalModuleEnvironment]:
	facts.prepared_environments.find(func(environment):
		module_identities_equal(bound_module_identity(environment.bound_module), module_identity)
	)
```

The scan is used by ordinary accepted body preparation and diagnostic/profile
observers. `complete_one_global_header` performs a separate environment scan
from a `GlobalId`; it does not already possess a trusted request scope and is
not an automatic cutover target.

## Invariants

Preserve exactly:

1. target-first module and environment order;
2. accepted versus recoverable global-completion behavior;
3. missing-environment and preparation-failure diagnostics;
4. wrong-graph, wrong-origin, and same-path/different-identity rejection;
5. debug-only call policy validation;
6. definition, callable, and type-variable allocation order;
7. local/import visibility and prepared declaration environment contents;
8. CTFE dependency-only behavior;
9. durable `ModuleIdentity` in nominal IDs, diagnostics, artifacts, and LSP
   projection; and
10. byte-identical typecheck and CLI responses.

A numeric slot is meaningful only after the existing compatibility check. A
list length check, canonical path, or matching integer alone is not provenance.

## Required Pre-Edit Audit

Inventory every call to `prepared_module_environment_find` and every direct
scan of `PreparedCanonicalModuleEnvironment`. Classify each call as:

| Class | Required action |
| --- | --- |
| accepted graph plus exact request scope | candidate for dense lookup |
| accepted graph plus existing `BoundModule` | use its prepared scope, then validate the requested durable identity if one is supplied |
| recoverable graph after the exact environment-count gate | candidate for the same dense lookup; retain its global-failure admission check |
| identity-only initializer/dependency lookup | retain initially; do not manufacture a scope or add a second index |
| benchmark/observer-only | migrate only after the production path is exact, and report it separately |

Record exact production call counts for the accepted and recoverable classes.
If accepted production performs too few lookups to measure, stop before adding
an enduring API.

## Completed Dependency Audit

`prepared_module_environments` visits the target followed by every bound
dependency and appends at most one canonical environment per visit.
`finish_typecheck_graph_completion` requires the final list length to equal
`1 + dependency count` before constructing either retained graph variant.
Those two facts prove that accepted and recoverable graphs retain one dense,
target-first environment per `PreparedModuleScope` slot. Recoverable status
records global-completion failures; it does not permit a missing environment.

The complete lookup inventory before the candidate was:

| Call site | Available key | Candidate action |
| --- | --- | --- |
| `graph_facts_typecheck_module` through `accepted_graph_typecheck_module` | exact request scope plus durable identity | indexed lookup |
| `graph_facts_typecheck_module` through `recoverable_graph_typecheck_module` | exact request scope plus durable identity, after failure admission | same indexed lookup |
| `observe_accepted_body_module_preparation` canonical row | graph-owned `BoundModule` | indexed lookup through its scope |
| initializer preparation observation | graph-owned `BoundModule` | indexed lookup through its scope |
| `complete_one_global_header` | `GlobalId` module identity only | retain identity scan |
| CTFE artifact preparation | dependency scope, but a distinct preparation path | unchanged; it does not read a reusable canonical environment |

The discarded candidate added a narrow `ImportableModuleGraph` target-scope
accessor, called `prepared_module_scope_compatible_index` once, performed one
checked `prepared_environments.get`, and then validated both the
caller-supplied durable identity and the request-scope identity against the
selected bound module. Debug-policy admission and `ImportableModuleGraph`
scope admission remained after selection exactly as before. Recoverable
failure admission remained before the shared selector.

Focused behavior covers target, first, middle, and final slots; a structurally
equivalent separately allocated graph; a supplied identity/scope mismatch; an
unrelated graph with the same numeric slot; and debug-policy mismatch. Existing
recoverable tests continue to prove that a failed target is rejected while a
later dependency remains usable. A source-boundary test rejects any return of
the scope-owning identity scan while allowing the explicitly identity-only
global-completion scan. These candidate tests and the temporary benchmark were
discarded after the production gate failed; no production or test API remains.

## Measurement Result

The dense selector is a strong isolated optimization but is not sufficiently
represented in current production compilation. The production candidate is
therefore rejected under this issue's predeclared gate. The repository remains
on the original identity scan.

### Compared artifacts

Both temporary source trees started at `05685b61` and used the same bootstrap
compiler, fixture, runner, checksum, allocator schema, and matrix. The measured
workers differed in the production selector; candidate tests and documentation
were outside the measured inputs. The temporary runner
SHA-256 was
`2ac1a5143b067319fb0a9670303488d340533833af30427158810063f7405608`;
the shared fixture SHA-256 was
`4556e198406c9966ed3aff6fb3219dbf11cdce2b475bfe40478d1bf3b7cfc2d5`.

| Artifact | Baseline SHA-256 | Candidate SHA-256 |
| --- | --- | --- |
| focused generated C | `4d851d49eb7a6a796d81db9255737586934f3f89c036463f35e01a5422e5ff3c` | `e36f1e84a62610620fa8f3cc92eda8f83781c3827298c69d2e71d1ea870b0fa5` |
| focused runner | `ae9c88aa0255f2f3eaf2dbb156c294f1839dff0a9512f8b4f2a4deec60ab43cf` | `2c15a0d2784add757af4265fda151a081845d949ed41f0baca441b6fbaea3dcf` |
| replay worker | `e22984e7c6eced8a4020d0b47ac52ce795bf2e13ed9a71f5445fb790f649165c` | `0ba0942d16a1738926dbc4496944938f8b6a37a7ca1549dcfe67a6e3d63c8ea6` |

The production capture was 11,401,074 bytes with SHA-256
`7e97872920905caa554e408a558c4cbb6f188f06a95493658fd6c0314ce97ab2`.
Raw output and deterministic summaries are retained locally under
`logs/issue48/{matrix,function-profile,replay,whole-compiler}/`; that directory
is ignored.

### Semantic and modeled evidence

The full 120-configuration paired matrix covered `1`, `8`, `32`, and `128`
dependency modules; `1`, `16`, and `64` lookups; target, first, middle, final,
and missing positions; and accepted and recoverable graphs. All 240 rows had
`workload_valid=True`; every paired error count, success count, and semantic
checksum was identical. Recoverable rows retained one deliberate global-cycle
error. The modeled baseline scan candidates ranged from one through
`modules + 1`; the candidate modeled one validated indexed read for every
admitted selector attempt. These modeled values are workload facts, not exact
production counts.

At 128 modules and 64 lookups, allocator results show the expected positional
scaling:

| Graph | Position | Baseline allocations | Candidate allocations | Delta |
| --- | --- | ---: | ---: | ---: |
| accepted | target | 1,216 | 1,152 | -5.26% |
| accepted | first | 1,280 | 1,152 | -10.00% |
| accepted | middle | 5,376 | 1,152 | -78.57% |
| accepted | final | 9,408 | 1,152 | -87.76% |
| accepted | missing | 8,384 | 128 | -98.47% |
| recoverable | target, rejected before selection | 256 | 256 | 0.00% |
| recoverable | first | 1,408 | 1,280 | -9.09% |
| recoverable | middle | 5,504 | 1,280 | -76.74% |
| recoverable | final | 9,536 | 1,280 | -86.58% |
| recoverable | missing | 8,512 | 256 | -96.99% |

At one dependency module, the 64-lookup final rows still reduced allocations
by 10.00% accepted and 9.09% recoverable; no matrix row increased allocator
work. Successful rows include body-session preparation after selection, while
missing rows more narrowly isolate selection. The full per-row table is
`logs/issue48/matrix/full-summary.tsv`.

### Focused cost and exact function evidence

The required 128-module final-position sentinel used 16,384 lookups so that
the measured selector outweighed fixture construction. After one scout, three
alternating pairs produced:

| Graph | Metric | Baseline median (range) | Candidate median (range) | Delta |
| --- | --- | ---: | ---: | ---: |
| accepted | allocations/releases | 2,408,448 | 294,912 | -87.76% |
| accepted | window microseconds | 229,299 (193,680-265,322) | 21,568 (21,543-21,698) | -90.59% |
| accepted | retired instructions | 5,754,537,355 (5,752,389,169-5,756,650,579) | 2,134,373,749 (2,133,938,300-2,136,263,040) | -62.91% |
| accepted | peak RSS bytes | 34,799,616 (34,652,160-34,897,920) | 34,701,312 (34,701,312-34,750,464) | -0.28% |
| recoverable | allocations/releases | 2,441,216 | 327,680 | -86.58% |
| recoverable | window microseconds | 198,574 (198,013-199,084) | 23,330 (23,141-24,049) | -88.25% |
| recoverable | retired instructions | 4,641,727,424 (4,639,237,463-4,643,861,323) | 1,026,933,736 (1,026,165,181-1,027,198,806) | -77.88% |
| recoverable | peak RSS bytes | 23,953,408 (23,920,640-23,953,408) | 23,871,488 (23,805,952-23,887,872) | -0.34% |

Exact function profiling at 128 modules and 64 final lookups reported 8,384
total baseline module-identity equality calls for the accepted row: 8,256
modeled scan candidates plus 128 compatibility/request comparisons. The
candidate reported 192 total calls. Recoverable selection reported
64 calls each to the old scan and request-admission helpers and 8,448 identity
equality calls; the candidate reported 64 dense-selector calls, 64 compatibility
checks, and 256 identity equality calls. Generated C showed one
`blorp_list_get` on the non-empty candidate path and no environment scan loop.
The checked list read was inlined and was therefore not separately named by the
function profiler.

### Production replay and decision

Three target-only allocator-instrumented replay pairs followed one warmup per
worker. All six measured runs were verified, exited zero, stayed below timeout
and memory limits, and produced the same 1,755,080-byte response with SHA-256
`999854562dbf34d2ee4d3d499f0fdcb28c30c529a8d674645a7cc5e4c45eedc5`.
Request and sliced replay-request hashes were identical across variants.

| Metric | Baseline median (range) | Candidate median (range) | Delta |
| --- | ---: | ---: | ---: |
| elapsed seconds | 10.274 (9.420-10.408) | 10.343 (9.478-10.782) | +0.669% |
| peak RSS bytes | 564,314,112 (564,019,200-564,805,632) | 564,035,584 (563,609,600-564,658,176) | -0.049% |
| allocations | 73,534,868 | 73,534,867 | -1 allocation (-0.000001%) |
| releases | 67,297,798 | 67,297,797 | -1 release (-0.000001%) |
| current objects | 6,247,571 | 6,247,571 | 0 |
| retained bytes | 529,104,848 | 529,104,848 | 0 |
| graph-prepare checkpoint microseconds | 2,752,126 (2,519,427-2,783,964) | 2,752,403 (2,634,578-2,763,171) | +0.010% |
| target typecheck checkpoint microseconds | 13,979 (13,178-14,229) | 13,686 (13,017-13,836) | -2.096% |

The separate whole-compiler check used one warmup and three alternating pairs;
all stdout was byte-identical. Median retired instructions changed from
316,458,456,808 to 316,454,548,381 (`-0.0012%`), far below the required
`-0.10%`. Median peak RSS changed by `+0.022%`. Wall time was noisy and worse
(`19.05` to `20.70` seconds, `+8.66%`), explicitly failing the `+1.0%` cap and
providing no acceptance evidence.

The focused mechanism clears its 25% gate, but the production allocation and
instruction thresholds both fail. The current compiler principally requests
the target environment, where the linear scan ends immediately. Keeping the
candidate would add a new internal accessor and compatibility work without a
measurable compiler-level return. Issue 49 should proceed from the unchanged
linear baseline and must not assume this dense selector exists. A future
cutover is justified only if another accepted consumer measurably performs
middle/final/missing scope-owning lookups in production.

## Implementation Plan

### 1. Establish failing public-behavior tests

Add tests before production changes. Tests must exercise accepted target,
first/middle/final dependency, wrong graph with the same numeric position,
equivalent graph allocation where currently accepted, same path with a
different origin, stale/mismatched durable identity, and debug-policy mismatch.

Add a recoverable graph with a global-completion failure in one module and a
successful later module. It must prove that the failed module remains rejected,
the later module selects its own aligned environment, and no slot shift occurs.
Also pin the existing graph-completion rejection for genuinely incomplete
canonical environment preparation.

### 2. Add the smallest private accepted lookup

Use the graph's existing owner scope and
`prepared_module_scope_compatible_index` to obtain a checked slot. Read the
existing environment list once. Validate that the selected environment's bound
scope and durable identity match the request before returning it.

Do not expose the integer, list, environment representation, or a general
graph-index API. Do not add a fallback that probes both dense and linear paths
in final production code.

### 3. Cut over accepted body preparation first

Keep the public accepted-module function signature unchanged. It still accepts
both `ModuleIdentity` and `PreparedModuleScope`; the scope selects the candidate
slot and the descriptive identity remains an exact admission check.

After that path is exact, use the same dense selector for recoverable graph
requests while preserving `global_completion_failures` admission before the
lookup. If a shared helper makes accepted and recoverable behavior ambiguous,
keep separate wrappers rather than encoding graph state in a boolean.

### 4. Migrate scope-owning observers and helpers

After the production accepted path is green, migrate only helpers that already
hold a `BoundModule` or `PreparedModuleScope`. Keep initializer identity-only
lookups unchanged unless a separate exact profile proves they dominate and a
correct scope is already available.

### 5. Delete scope-owning linear paths

No accepted or recoverable call that owns a compatible scope may retain a
linear scan or identity-comparison loop. A genuinely identity-only initializer
path should have a name that states why it remains. Remove temporary alternate
implementations and benchmark-only production surface before final review.

## Non-Goals

- Do not change `TypecheckGraphFacts`, `PreparedCanonicalModuleEnvironment`,
  `PreparedModuleScope`, `IndexedGraph`, `BoundModule`, or `ModuleIdentity`
  representation unless measurement proves the issue cannot be completed
  without it and the scope is re-approved.
- Do not add a process-global or cross-graph module interner.
- Do not change the graph-completion count gate or permit an incomplete
  environment list in either retained graph form.
- Do not migrate `complete_one_global_header` merely because it also scans the
  list.
- Do not change CTFE preparation, accepted authorities, declaration
  publication, identity allocation, or diagnostics.
- Do not retain a public/test-only slot accessor.

## TDD Plan

Required exact tests:

1. empty dependency list and target slot;
2. singleton dependency;
3. first, middle, and final accepted dependency lookup;
4. repeated source names across modules select the exact owner;
5. same canonical path with incompatible origin fails closed;
6. unrelated graph with the same integer slot fails closed;
7. structurally equivalent graph behavior matches the current compatibility
   contract;
8. supplied identity and scope disagreement fails closed;
9. debug-only policy disagreement fails closed;
10. recoverable global-failure rejection and later-module selection use the
    correct aligned environments;
11. accepted and recoverable diagnostics remain byte-for-byte equal; and
12. CTFE artifact behavior and dependency visibility are unchanged.

Use public accepted/recoverable graph APIs for semantic tests. Private list
lengths and numeric slots are structural evidence from generated C and focused
instrumentation, not public test assertions.

## Measurement Plan

Keep four evidence classes separate:

1. semantic dimensions and checksums;
2. modeled workload facts derived from module count and lookup positions;
3. exact production function counts; and
4. allocator, retired-instruction, RSS, and elapsed measurements.

Use matched baseline/candidate trees from the same source and bootstrap
compiler. Alternate each pair. The comparison patch may select linear versus
dense lookup temporarily, but it must execute the production helpers and be
removed before commit.

Matrix:

```text
modules:             1, 8, 32, 128
lookups per module:  1, 16, 64
lookup position:     target, first, middle, final, missing
graph result:        accepted, recoverable global-completion failure
```

Record exact scan candidates, identity comparisons, compatibility checks, list
reads, successful/missing results, semantic checksum, errors/diagnostics,
elapsed, allocations, releases, current objects/bytes, retired instructions,
cycles, and RSS where available.

Run one warmup and at least three alternating measured pairs for the 128-module
sentinel. Run production typecheck replay only after the focused scope-indexed
path wins. Production replay requires byte-identical response bytes and hashes,
identical request/bridge identities, allocator statistics, clean timeout/memory
status, and at least three alternating pairs.

## Fast Feedback

1. Add the wrong-provenance test and confirm it fails against an unchecked-index
   prototype; separately pin recoverable global-failure admission.
2. Run only the prepared-environment accepted/recoverable graph suites.
3. Run source check and formatter on `decl.brp`.
4. Run untimed 1-, 8-, and 128-module lookup scouts.
5. Inspect generated C: each scope-owning lookup must contain one compatibility
   check and one list read, with no environment scan loop or new managed module
   ID allocation.
6. Run `scripts/compiler-check --changed` only after focused behavior and the
   sentinel measurement are green.
7. Request a clean timing slot before the full matrix or replay.
8. Run code-reviewer, test-runner, and code-optimizer before commit.

Stop immediately if the retained list is not provably slot-aligned, if existing
behavior depends on scanning, or if recoverable failure admission cannot remain
isolated.

## Acceptance Criteria

- Scope-owning accepted and recoverable lookup candidates visited change from
  position-dependent `1..M` to exactly one checked slot read.
- The 128-module final-position focused sentinel reduces median retired
  instructions by at least 25% and does not increase allocations.
- No enduring table, dictionary, owner record, or per-lookup managed value is
  added.
- Production accepted/recoverable scope-path exact counts show zero environment
  scans and the removal of their identity-comparison loops.
- The production typecheck checkpoint must either reduce allocations/releases
  by at least 0.10% or reduce median retired instructions by at least 0.10%.
- Whole-compiler median retired instructions must not regress by more than
  0.05%, median elapsed must not regress by more than 1.0%, and median peak RSS
  must not regress by more than 0.5%.
- Every semantic checksum, diagnostic, ID frontier, and response is identical.
- Recoverable failed-module admission and wrong-provenance tests fail closed
  exactly; a later module cannot select the failed module's slot.
- Generated C proves one indexed read and no linear accepted scan.
- Temporary comparison surfaces are removed and all required reviews approve.

If the production threshold is not met, restore the baseline and document the
measurement. Do not retain it merely because indexed lookup is cleaner.
