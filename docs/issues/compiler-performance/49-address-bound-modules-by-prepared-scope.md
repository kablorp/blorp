# Address Bound Modules By Prepared Scope

**Status:** Rejected after focused and production measurement

**Dependencies:** Issues 46 and 47 are complete. Issue 48 was measured and
rejected, so this experiment started from its unchanged immediate baseline.

**Blocks:** Issue 50 must start from the unchanged identity-lookup baseline and
reprofile import/module visibility. It must not assume that this issue retained
a compatible-scope selector or scope-carrying header carrier.

**Parallel work:** None in bound-module graph construction, Stage 06 header
builders, or prepared-scope compatibility.

## Objective

Remove repeated durable-identity lookup when a Stage 06 caller already owns the
exact prepared scope or bound module. Add one narrow compatible-scope read of
`BoundModuleGraph`, then migrate only production call sites that can supply
that provenance without reconstructing it.

Do not replace source-facing canonical-path lookup. Do not add a public generic
module ID. Do not convert an identity-only caller by first performing another
identity-to-slot lookup; that only moves the work.

## Required Reading

Read `AGENTS.md`, Issues 45-48, and:

- `graph/indexed_graph.brp`;
- `modules/bound_module_graph.brp`;
- `headers/type_header_graph.brp`;
- `headers/type_parameter_headers.brp`;
- `headers/callable_headers.brp`;
- `headers/trait_headers.brp`;
- `headers/implementation_headers.brp`;
- `headers/type_header_dependencies.brp`;
- `headers/global_header_completion.brp`;
- the matching graph/header tests and compiler profile fixtures.

## Current Behavior And Signal

`BoundModuleGraph` already retains the target separately, dependencies in
graph order, and the issuing `IndexedGraph`. It also retains a canonical-path
dictionary for source/durable lookup. Current identity lookup performs all of:

```blorp
key = module_identity_display_name(identity)
module = modules_by_canonical_path.get(key)
module_identities_equal(bound_module_identity(module), identity)
```

The historical broad exact profile observed approximately 210,000
`bound_module_graph_find` calls. A fresh phase profile below found 45,074 calls
in the accepted phase. Instrumented function time is not wall time, but the
count justified the bounded call-site audit and experiment.

Current call sites include type, type-parameter, callable, trait,
implementation, global-completion, accepted-body, and CTFE paths. Many begin
from durable declaration IDs and do not inherently own a prepared scope. They
are not automatically suitable for direct indexing.

## Mandatory Call-Site Classification

Before editing, record exact counts and classify every call:

| Class | Example | Required treatment |
| --- | --- | --- |
| caller already has `PreparedModuleScope` | accepted body/module helper | direct compatible-scope candidate |
| caller already has `BoundModule` | module-local builder loop | pass/reuse the bound module; do not find it again |
| declarations can be grouped under an existing module loop | header construction | measure one category-specific restructuring |
| caller has only durable `TypeId`/`CallableId`/`GlobalId` | exact nominal lookup | retain descriptive lookup unless ownership is resolved once outside the hot loop |
| canonical source import/path request | module binding and diagnostics | retain path dictionary |
| graphless/direct/provisional path | no graph provenance | retain descriptive identity |

The initial candidate slice had to remove at least 25% of production
`bound_module_graph_find` calls. If the scope-owning classes are smaller, stop
and document the ceiling before adding the API.

## Completed Call-Site Audit

Most callers own only a durable declaration identity and correctly retain
identity lookup. The discarded candidate changed only the two paths where an
exact prepared scope was already present, plus the highest-count type-header
installation subpath whose existing carrier could preserve that provenance.

| Production area | Available provenance | Experimental treatment |
| --- | --- | --- |
| bound graph module projection | `PreparedModule` | retain identity lookup |
| implementation headers | `ImplId` | retain identity lookup |
| global header completion | `GlobalId` | retain identity lookup |
| type-header dependencies | `TypeId` | retain identity lookup |
| trait headers | `TraitId` | retain identity lookup |
| type-header owner APIs and skeletons | `ModuleIdentity` or `TypeId` | retain identity lookup |
| type-header table construction | owner scope exists, but lookup is part of a wider table build | retain; no category restructuring |
| type-parameter headers | `TypeId` | retain identity lookup |
| callable headers | `CallableId` or `GlobalId` | retain identity lookup |
| ordinary global/body adapters | `GlobalId` or other durable identity | retain identity lookup |
| record/union/alias installation | exact graph-owned module scope can be carried through the existing installation variant | experimental scope-carrying variants |
| CTFE artifact ownership | exact `PreparedModuleScope` | experimental compatible-scope selector, while retaining dependency-only admission |

The fresh exact profile used
`compiler_typecheck_phase_profile <phase> 1 8 32 64 4`. It reported:

| Phase | `bound_module_graph_find` calls | Share of instrumented phase |
| --- | ---: | ---: |
| parameters | 546 | 19.8% |
| headers | 1,092 | 1.9% |
| topology | 27 | 2.3% |
| callables | 1,068 | 1.2% |
| implementations | 36 | 1.7% |
| accepted | 45,074 | 0.7% |
| bodies | unavailable | no exact function count exposed |

Within the accepted phase,
`type_header_graph_owner_provides_prelude_type` accounted for 44,345 calls.
That made repeated prelude-ownership lookup inside type-header installation the
only category with a plausible retained slice above the 25% call-count gate.

## Measured Result

The experiment was semantically correct and substantially reduced synthetic
graph work, but it did not clear either compiler-wide acceptance threshold.
The implementation and tests were therefore restored. No new production API,
scope carrier, or test-only accessor remains.

### Compared artifacts

Both variants started from commit `b1849296`. The candidate source patch
SHA-256 was
`4f2ade6bb94e16d9448d7d7932ed958a072801fe407c9499d42da342fbcccddf`.
That hash was captured immediately before cleanup; the rejected source patch
itself was intentionally not retained. It identifies the measured input but is
not a reproducible substitute for a retained commit. The raw logs and replay
workers below are the retained measurement evidence.
The baseline and candidate compiler binary SHA-256 values were respectively
`967cbe2512a4335845735633c2c1a17bccd5d81798e9185ee799fcbed646b848`
and
`0368200e89fd1ab5a8c16b8b60575b3bd8bb234baec7fafac517802a0de51f7a`.

The production replay reused the 11,401,074-byte Issue 48 capture with SHA-256
`7e97872920905caa554e408a558c4cbb6f188f06a95493658fd6c0314ce97ab2`.
The baseline and candidate replay workers had SHA-256 values
`df360f1c38e5998b1843a7a0f04133bd3c145cdce29bcefb5c46ad727dde0f19`
and
`be54373405989b17d712a38040f6d7f2a2ab64ac9861dd5b0a98a2ea2efc4171`.
Raw logs and deterministic summaries remain locally under `logs/issue49/`,
which is ignored. The final matrix summary is
`logs/issue49/matrix-scope-final/full-summary.tsv`; replay summaries are under
`logs/issue49/replay/`; whole-compiler samples are under
`logs/issue49/whole-compiler/`.

### Experimental implementation

The discarded candidate added a compatible-scope lookup that used the existing
private prepared-scope slot, checked list bounds, and validated the selected
module's exact scope/identity. It did not construct a target-plus-dependencies
list. CTFE artifact ownership used that selector while preserving the existing
dependency-only graph admission.

For type headers, identity-backed installation variants remained in use for
callable, trait, implementation, global, and body adapters. Only existing
record, union, and alias installation variants carried their already known
`PreparedModuleScope`. Prelude ownership then read that scope directly while
preserving source order, diagnostics, identity allocation, and publication
behavior. Empty categories skipped setup.

Focused behavior tests covered target, first, middle, and final selection;
compatible separately allocated graphs; incompatible source; same path with a
different origin; and sparse/reordered module selection. Before rejection,
the bound-module graph suite passed 16/16 and the type-header graph suite
passed 58/58.

### Synthetic scaling

The final paired matrix used the existing declaration-catalog production-path
harness. It covered chain, star, layered, and dense graphs; module counts
`1`, `8`, `32`, and `128`; and declarations per module `1`, `16`, and `64`,
with requested import-fanout control `4` and body count `0`. Effective
adjacency remained topology-derived rather than fixed: chain, star, layered,
and dense rows intentionally produced different direct-edge counts. All 96
logs were valid. Every baseline/candidate pair had identical semantic fields,
error counts, and checksums. No row increased allocations.

| Topology | Mean allocation delta | Allocation-delta range | Mean elapsed delta |
| --- | ---: | ---: | ---: |
| chain | -3.062% | -11.487% to -0.022% | -4.344% |
| dense | -2.569% | -9.452% to -0.022% | +0.522% |
| layered | -2.994% | -11.373% to -0.022% | -0.164% |
| star | -0.585% | -1.740% to -0.022% | -2.415% |

The largest rows showed the mechanism's synthetic ceiling:

| Topology, 128 modules x 64 declarations | Baseline allocations | Candidate allocations | Delta | Baseline/candidate microseconds |
| --- | ---: | ---: | ---: | ---: |
| chain | 21,850,166 | 19,340,214 | -11.487% | 3,767,550 / 3,510,253 |
| dense | 26,553,386 | 24,043,434 | -9.452% | 4,168,890 / 4,053,291 |
| layered | 22,070,290 | 19,560,338 | -11.373% | 3,619,525 / 3,360,049 |
| star | 2,411,156 | 2,372,116 | -1.619% | 204,653 / 208,964 |

At one module and one declaration, every topology changed from 23,055 to
23,050 allocations (`-0.0217%`), showing negligible small-workload impact.
Elapsed values are secondary and were not used alone for acceptance.

### Exact production function evidence

On the accepted-phase profile, exact
`bound_module_graph_find` invocations fell from 45,074 to 21,842: 23,232
retired calls, or `-51.54%`. Identity-based
`type_header_graph_owner_provides_prelude_type` fell from 44,345 to 21,113.
The lower-level prepared-scope prelude predicate was called 44,345 times in
the candidate, but that total includes both migrated direct calls and the
21,113 retained identity-helper calls delegating to it. The exact migrated
count is therefore the 23,232-call reduction in the identity helper, not the
lower-level total. The semantic checksum remained `9213486634049527307`.

This clears the issue's exact call-retirement gate. It does not establish a
compiler-wide speedup because the production compiler still performs much more
work outside these lookups.

### Production replay

After one warmup per worker, three alternating target-only replay pairs used
allocator statistics, a 120-second timeout, a 4 GiB memory limit, and no
inventory. All six measured runs were verified, had clean timeout/memory
status, exposed allocator data, and emitted no stderr. Request and bridge hashes
matched. Every run produced the same 1,755,080-byte response with SHA-256
`999854562dbf34d2ee4d3d499f0fdcb28c30c529a8d674645a7cc5e4c45eedc5`.

| Metric | Baseline median (range) | Candidate median (range) | Delta |
| --- | ---: | ---: | ---: |
| elapsed seconds | 9.410 (9.397-9.609) | 9.633 (9.447-9.792) | +2.37% nominal, pairwise noisy |
| peak RSS bytes | 563,757,056 (563,609,600-563,937,280) | 563,773,440 (563,675,136-563,970,048) | +0.003% |
| allocations | 73,534,868 | 73,462,898 | -71,970 (-0.0979%) |
| releases | 67,297,798 | 67,225,828 | -71,970 (-0.1070%) |
| current objects | 6,247,571 | 6,247,571 | 0 |
| retained bytes | 529,104,848 | 529,104,848 | 0 |
| graph prepare microseconds | 2,542,006 | 2,564,596 | +0.89% |
| target typecheck microseconds | 13,514 | 13,339 | -1.30% |

The allocation reduction is real but below the required `0.25%` alternate
production gate. The `+2.37%` replay median elapsed change also exceeds the
predeclared `+1.0%` regression cap and is a failed gate. Pairwise elapsed
results were mixed, but timing noise does not waive that median threshold.

### Whole-compiler gate and decision

The final gate ran one warmup and three alternating pairs of
`bin/blorp check --no-format blorp/src/main.brp` under `/usr/bin/time -lp`.
Every stdout SHA-256 was
`c1758b804e292be62860bce968c8cee14b4b6a8fec681ff19c5318e5195c0963`.

| Metric | Baseline samples | Candidate samples | Median delta |
| --- | --- | --- | ---: |
| elapsed seconds | 17.87, 17.79, 17.74 | 18.36, 17.71, 17.64 | -0.45% |
| retired instructions | 316,450,204,172; 316,130,985,164; 316,245,181,235 | 316,364,323,610; 316,264,727,189; 316,215,083,479 | +0.0062% |
| cycles | 71,486,271,022; 71,202,624,177; 71,239,938,181 | 72,069,332,441; 71,107,371,338; 70,896,105,134 | -0.186% |
| peak RSS bytes | 879,738,880; 879,771,648; 880,066,560 | 881,770,496; 880,066,560; 879,443,968 | +0.034% |

The whole-compiler instruction threshold required at least `-0.10%`; the
observed median was flat/slightly worse. The alternate replay-allocation
threshold required at least `-0.25%`; the observed change was `-0.0979%`.
Neither gate passed, so the candidate is rejected exactly as required by this
issue. Generated-C inspection was not used as acceptance evidence because no
implementation is retained.

Issue 50 should proceed independently from the unchanged identity lookup and
must first reprofile its own import/visibility share. The synthetic result is
useful evidence that prepared scopes can remove high-multiplicity graph work,
but a future attempt needs a production consumer large enough to clear a
predeclared compiler-wide gate.

## Discarded Experimental Design

The following design and test plan describe the candidate that was measured
and removed. They are retained as historical context, not as current compiler
behavior or an available API.

## Proposed Private Boundary

The bound graph can select without a new list:

- compatible slot `0` selects `target`;
- compatible slot `N > 0` selects `modules[N - 1]`.

The boundary accepts a `PreparedModuleScope`, obtains a slot only through the
existing graph compatibility primitive, performs bounds checks, and validates
the selected module scope before returning it. It never returns the integer.

Blorp module visibility may require the function to be importable by sibling
Stage 06 modules. If so, expose only the semantic function
`bound_module_graph_find_compatible_scope`; keep its representation and slot
private. Do not weaken `Scope`, `IndexedGraph`, or `PreparedModuleScope`
privacy.

## Implementation Plan

### 1. Pin current behavior

Write failing tests for target/first/middle/final selection, unrelated graphs
with equal integer positions, structurally compatible graphs, same canonical
path with different origin, missing dependencies, and source-order stability.
Pin exact existing diagnostics for bad ownership.

### 2. Implement the zero-allocation scope read

Use the existing target/dependency fields. Do not construct
`[target].concat(modules)` on each query and do not add another retained list.
Generated C must show integer branching/list addressing and no managed wrapper.

### 3. Migrate direct scope-owning calls

Change only calls that already possess the correct scope. Preserve the old
identity/path lookup API for durable boundaries. Remove any redundant identity
projection made solely to call `bound_module_graph_find`.

### 4. Migrate one module-grouped header category

Choose the category with the highest exact call count. Keep declaration and
identity claiming order unchanged. Iterate the existing graph/module order and
pass the already selected `BoundModule` into the leaf helper. Do not batch
semantic work across modules or reorder declarations by owner as a shortcut.

Measure this category before migrating another. A second category requires a
fresh checkpoint and must improve the same accepted baseline.

### 5. Remove temporary paths

No final caller should convert `ModuleIdentity -> scope -> slot` solely to use
the new function. Remove benchmark strategy switches and test-only accessors.
Keep canonical-path lookup where path resolution is the actual operation.

## Non-Goals

- No change to `ModuleIdentity`, nominal declaration IDs, source import paths,
  `IndexedGraph`, `BoundModuleGraph`, or prepared scope representation.
- No process-global interner, path hash identity, or cross-graph integer.
- No declaration reordering, cross-module batching, or diagnostic changes.
- No migration of all header categories in one patch.
- No removal of `modules_by_canonical_path`; it remains authoritative for
  canonical path requests.
- No LSP/artifact numeric identities.

## TDD Plan

Required tests:

1. target slot selects target, not dependency zero;
2. first/middle/final dependency selection;
3. incompatible same-position graph fails closed;
4. equivalent-graph behavior matches current compatibility semantics;
5. same path/different origin fails closed;
6. missing selection and incompatible scopes return `None` without fallback;
7. local and imported visibility is unchanged;
8. declaration/header source order is unchanged;
9. identity claim and diagnostic order is unchanged;
10. accepted and recoverable successful-subset behavior is unchanged; and
11. direct/provisional paths continue through descriptive lookup; and
12. CTFE artifact ownership/visibility remains exact if any CTFE call site is
    migrated.

An out-of-range scope cannot be constructed through the public opaque API.
Prove the retained bounds branch through generated C and an existing private
structural-test precedent if one exists; do not expose a raw-scope constructor
for this test.

For the migrated category, compare the complete public graph/header projection
against the baseline, including private/public partitions, IDs, spans,
diagnostics, and deterministic checksum.

## Measurement Plan

First use exact production function instrumentation to count every old find by
caller/category. Then use a production-path fixture with:

```text
modules:            1, 8, 32, 128
declarations/module: 1, 16, 64
topology:           chain, star, layered/diamond, dense
owner position:     target, first, middle, final
```

Record semantic checksum, old finds, path-key constructions, durable identity
comparisons, compatibility checks, direct scope reads, declarations visited,
allocations, releases, retained objects/bytes, retired instructions, cycles,
elapsed, and RSS.

Build baseline and candidate from the same post-Issue-48 tree. Run paired,
alternating rows with at least three measured pairs for each focused sentinel
and at least three production self-check pairs. Every response must be
byte-identical. Do not infer timing from function-entry instrumentation.

## Fast Feedback

1. Run the bound-module graph suite after each boundary edit.
2. Run one selected header-category suite after each call-site migration.
3. Execute untimed 8-module chain and dense rows.
4. Inspect generated C for one compatibility check, one target/list branch, and
   no constructed combined module list.
5. Measure exact old-find reduction before migrating another category.
6. Stop if less than 25% of production finds are removable without broader
   identity/data-model changes.
7. Only then run changed/typecheck gates and request a clean timing slot.
8. Finish with code-reviewer, test-runner, and code-optimizer.

## Acceptance Criteria

- The retained slice removes at least 25% of exact production
  `bound_module_graph_find` invocations.
- Scope-aware lookup visits exactly one target/list position and performs no
  canonical-path key construction.
- The 128-module final-position focused lookup reduces median retired
  instructions by at least 25% with no allocation increase.
- The migrated production header/category window reduces allocations or
  retired instructions by at least 1%.
- Whole-compiler median retired instructions improve by at least 0.10%, or the
  relevant production typecheck checkpoint reduces allocations/releases by at
  least 0.25% while whole-compiler instructions remain within 0.05%.
- Median elapsed must not regress by more than 1.0%, and median peak RSS must
  not regress by more than 0.5%, across the production pairs.
- All semantic outputs, diagnostics, IDs, ordering, and replay bytes match.
- Generated C contains no per-query managed module value or intermediate
  target-plus-dependencies list.
- Durable path lookup remains only at legitimate path/identity boundaries.
- Temporary instrumentation and alternate implementations are removed; all
  three reviews approve.

If the call-site audit or production gate fails, do not keep an unconsumed
scope API. Remove the candidate, restore the baseline, and retain only the
documented evidence.
