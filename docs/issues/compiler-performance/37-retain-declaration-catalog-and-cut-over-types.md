# Retain The Declaration Catalog And Cut Over Types

**Status:** Implemented in three measured checkpoints (37a aliases, 37b records, 37c unions/constructors/fields)

**Dependencies:** Issues 34 and 36 (complete)

**Parallel work:** None. Issue 35 was rejected after its production-path audit
and introduces no graph-facts product or integration conflict. Keep this retry
isolated until each type-family slice has passed its correctness and latency
gate.

## First Attempt Retrospective (Not Merged)

The first implementation attempt was abandoned in the uncommitted worktree
`/private/tmp/blorp-issue37`. The branch
`codex/issue-37-catalog-type-authority` itself still points at the clean control
commit; the abandoned source is not durable branch history and must not become
an integration dependency for this retry.

The attempt did prove several useful semantic requirements, but it failed as
an implementation for two related reasons: it changed too many authority paths
before measuring them, and its replacement lookup representation was less
specialized than the three indexes it removed.

### What went wrong

1. **The cutover was attempted as one large replacement.** At final review the
   working tree covered 39 changed or untracked paths, with 2,534 inserted and
   4,006 deleted lines, before the production self-check latency was treated as
   a merge gate. That made it difficult to attribute regressions or revert one
   declaration category.
2. **A generic managed entry became the hot-path lookup value.** Alias, record,
   union, constructor, field, and containment reads converged on an
   `AcceptedTypeFamilyEntry` union. Recursive resource-capability scans and
   alias-head resolution then paid generic dictionary lookup, `Option` and
   union matching, and managed retain/release traffic even when they needed
   only one category-specific fact.
3. **Canonical payloads exposed an owner-spelling requirement late.** Callable
   headers and other Stage 06 inputs still refer to owner-local type spellings.
   The attempted fix projected complete canonical entries—including alias
   targets, fields, and variants—back into every owner module view. This made
   the views payload-bearing rather than identity-only and recreated the
   duplication Issue 37 is meant to remove.
4. **Compensating caches amplified ownership cost.** Adding dictionaries whose
   values were complete managed catalog records increased copying and ARC/COW
   work. A transparent-alias cache made the controlled self-check worse rather
   than better. More caches were not a sound way to recover the lost category
   specialization.
5. **The required TDD boundary was incomplete.** Existing catalog tests stayed
   green, but the attempt did not first land the issue's complete wrong-kind,
   unrelated-module candidate-count, and production-reader structural proofs.
   Correctness discoveries therefore arrived after the broad reader cutover.

### Evidence for abandoning it

On commit `77437463`, the clean control self-check
`blorp check --no-format blorp/src/main.brp` took 31.95 seconds and retired
526,318,890,009 instructions. The last stable first-attempt implementation took
46.66 seconds and retired approximately 763.8 billion instructions: roughly
46% more wall time and 45% more instructions. A further alias-cache experiment
retired more than one trillion instructions. Focused catalog tests passed, so
this was a representation and query-cost failure rather than justification for
weakening the semantic requirements.

## Retry Strategy And Stop Conditions

The retry must proceed by declaration category and preserve a clean rollback
point after every slice. It must not transplant the abandoned implementation
wholesale.

1. Record a clean current-main Phase 01-06 baseline before production edits.
2. Add the exact typed query tests and structural counters first. Include
   wrong-kind IDs and an unrelated module whose addition leaves exact-query
   candidate visits unchanged.
3. Establish the low-level identity dependency boundary without changing
   production lookup authority or latency.
4. Implement vertical slices that add an authority, cut over all readers for
   that category, and delete its old indexes and `Env` installation in the same
   increment. Do not merge catalog scaffolding that merely adds work.
5. First canonicalize accepted header inputs and cut over aliases together, so
   the canonicalization prerequisite immediately pays for itself by removing
   owner-local alias payload projections and legacy alias publication.
6. Design catalog storage around category-specific tables. An alias index may
   address only alias storage, a record index only record storage, and so on.
   No category index may address a heterogeneous managed-entry arena. Typed
   queries return only the requested category payload. A module view may retain
   ordered established IDs and scalar source-spelling bindings; it may not
   retain complete alias targets, fields, variants, or generic catalog entries.
7. Cut over and delete one old authority at a time: aliases, then records, then
   unions/constructors/fields. Run that category's focused tests and the
   controlled self-check immediately after each cutover.
8. Apply a performance ratchet: each production increment must reduce its
   focused workload's allocations and retired instructions, reduce whole-
   compiler median retired instructions, and avoid a clear wall-time
   regression versus its immediate parent. If the whole-compiler improvement
   is too small to measure, redesign the slice or combine it with the next
   deletion rather than merging a performance-neutral production step.
9. Do not add a compensating cache unless a sample identifies the precise
   repeated computation and the cache stores only compact identity/scalar
   facts. A cache containing a generic catalog entry, field lists, variant
   lists, or alias targets in a module view is a design failure.
10. Complete the recovery-path proof, legacy deletion sweep, and architecture
   documentation only after all category gates pass.

### One catalog lineage across global completion

Global initializer checking already needs accepted type-family facts, so the
type tables cannot first appear after completed globals exist. The production
sequence is instead:

```text
accepted type and implementation headers
        |
        v
prepare one graph-owned type-family authority and module views
        |
        +--> use that exact authority for global initializer sessions
        |
        v
attach successfully completed globals
        |
        v
finalize one AcceptedDeclarationCatalog that reuses the same authority
        |
        v
retain that catalog lineage in shared TypecheckGraphFacts
```

Preparation performs the only type-family table and canonical-view builds.
Finalization attaches the successful completed-global subset without scanning,
copying, or rebuilding those products. Accepted and recoverable wrappers retain
the same final lineage. During incremental implementation, a migrated category
uses this authority for both initializer and body checking while categories not
yet migrated continue to use their existing authority. There is never an
old/new fallback pair within one migrated category.

### Reproducible latency gate

For the baseline and every category checkpoint:

1. Create isolated control and candidate worktrees at the checkpoint's common
   parent and candidate revisions.
2. Run `make -B build-blorp-cli` once in each worktree.
3. Run one unmeasured warmup in each worktree:
   `blorp/build/_build/blorp-cli/blorp check --no-format blorp/src/main.brp`.
4. Run three alternating control/candidate pairs using
   `/usr/bin/time -lp blorp/build/_build/blorp-cli/blorp check --no-format blorp/src/main.brp`.
   No other compiler, Clang, test, or benchmark process may run concurrently.
5. Record every wall time and retired-instruction count plus their medians.

The candidate median retired-instruction count must be lower than its immediate
parent, and the focused scalable fixture must perform fewer allocations and
retire fewer instructions. Also stop for a clear wall-time regression—for
example, all three candidate runs exceeding their paired controls by more than
5%. Use a 1 ms `sample` profile to diagnose a failed gate, not to waive it. If
final catalog assembly cannot show an independent win, fold it into the last
category cutover.

The implementation should remain separable into reviewable commits even if it
is ultimately squash-merged. Each commit must compile and either add proof or
replace one existing authority; no commit may leave old and new production
readers as fallback peers.

## 37a Alias Checkpoint Evidence

The alias checkpoint replaces the accepted alias projection and
`TypeAliasIndex` with one graph-owned, category-specific alias table. Module
views retain established `TypeId` bindings and scalar lookup metadata, while
canonical payload dictionaries contain public aliases only. Local and
selective source spellings address the shared table; accepted body environments
no longer receive alias declarations. The provisional `Env` path remains only
for pre-acceptance checking.

The focused dense declaration-graph fixture reduced allocations from
2,454,325 to 2,447,605. On the accepted-graph phase fixture (one iteration, 16
modules, 32 shapes per module, 64 probes per module, import fan-out 4), control
retired 464,854,296,967 instructions in 25.11 seconds; 37a retired
396,063,438,972 instructions in 21.21 seconds. Both runs produced the same
2,297 primary outputs, 33 secondary outputs, and checksum.

Three alternating whole-compiler self-check pairs produced:

```text
control:   30.28s / 529,632,666,401 instructions
candidate: 30.15s / 526,886,390,819 instructions
control:   30.44s / 529,562,214,280 instructions
candidate: 30.15s / 527,105,387,335 instructions
control:   30.36s / 529,485,477,151 instructions
candidate: 30.10s / 527,205,180,531 instructions
```

Median wall time fell from 30.36 to 30.15 seconds, and median retired
instructions fell from 529,562,214,280 to 527,105,387,335. A rejected
intermediate implementation installed canonical-name self-redirects in module
views and retired about 577.2 billion instructions. Matching the prior
projection's rule that canonical names never redirect to themselves removed
roughly 505,000 redundant alias-resolution recursion steps and restored the
ratchet.

## 37b Record Checkpoint Evidence

The record checkpoint replaces `RecordTypeProjection` and `RecordTypeIndex`
with one graph-owned, category-specific record table. Canonical field payloads
are stored once. Prepared canonical module facts retain compact source-name and
field-shape indexes; ordinary body sessions reuse those facts, while CTFE
constructs its intentionally different dependency-only view without retaining
a second canonical copy. Accepted record headers no longer publish record
payloads or containment facts into `Env`; the provisional pre-acceptance path
is unchanged.

Resource-capability lookup initially queried the record authority before every
remaining `Env` category. That ordering passed correctness but failed the
instruction ratchet. The accepted path now asks `Env` for builtin, union, or
provisional facts first and consults the record authority only when `Env` has
no category-owned answer. This is category dispatch rather than an old/new
record fallback: accepted record values exist only in the record authority.

On the accepted-graph phase fixture (one iteration, 16 modules, 32 shapes per
module, 64 probes per module, import fan-out 4), the final matched clean runs
retired 499,571,627,287 instructions in 27.29 seconds on 37a and
357,460,529,933 instructions in 19.11 seconds on 37b. Both runs produced 2,297
primary outputs, 33 secondary outputs, and checksum
`-877448313171944452`. A repeated 37b run retired 357,511,165,421 instructions
in 19.21 seconds.

Memory measurement is a separate explicit harness mode: append `memory` after
the fan-out argument. `reset_mem_stats()` enables per-allocation metadata, so
enabling it during a latency run measures the tracking machinery rather than
the ordinary compiler path. In memory mode, the same phase window reduced
allocations from 4,230,098 to 4,030,750 and retained objects from 954,576 to
848,690. The body-preparation-only catalog benchmark intentionally excludes
authority construction and therefore is not the allocation gate for this
category cutover.

Three alternating whole-compiler self-check pairs produced:

```text
control:   30.53s / 530,505,424,348 instructions
candidate: 30.05s / 524,129,773,740 instructions
control:   30.58s / 531,476,071,839 instructions
candidate: 30.16s / 523,885,122,755 instructions
control:   30.60s / 530,863,797,327 instructions
candidate: 30.10s / 524,439,473,128 instructions
```

Median wall time fell from 30.58 to 30.10 seconds. Median retired
instructions fell from 530,863,797,327 to 524,129,773,740. Two rejected
representations retained another graph-level copy of canonical module views:
a managed dictionary raised the focused result to roughly 429.0 billion
instructions, and aligned retained lists raised it to roughly 425.2 billion.
Keeping the sole canonical view in the already-retained prepared module facts
avoids that duplication and keeps ordinary body construction flat.

After the final lookup-origin correction, a production self-check retired
524,209,774,389 instructions in 30.56 seconds, inside the measured candidate
instruction band above. The correction explicitly distinguishes an owner-local source-name
binding from canonical fallback without adding payload copies: local recursive
field types are localized only for the former, while canonical and
canonical-only lookups retain canonical field spellings.

## 37c Union, Constructor, And Field Checkpoint Evidence

The final checkpoint replaces `UnionTypeProjection` and `UnionTypeIndex` with
one graph-owned, category-specific accepted-union table. Canonical union and
variant payloads are stored once. Module views retain only compact union and
constructor locators plus scalar source-name and parent-alias bindings.
Accepted union installation records spelling provenance without publishing
union payloads, constructors, or containment facts into `Env`; provisional
header checking retains the existing `Env` path.

The first complete candidate exposed two accidental payload-materialization
costs: scalar union queries localized every variant field, and a constructor
query localized every variant instead of only the selected constructor. Both
paths now use raw scalar table facts or a single variant locator. A temporary
LLVM function profile then measured 3,946,667 full union lookups, chiefly from
recursive resource-capability component scans. Those scans now honor the
existing `resource_type_scan_is_proven_unnecessary` fact before opening record,
union, or opaque-alias payloads. This is a negative-proof shortcut, not a new
cache: it returns an empty component list only when accepted containment facts
prove that no relevant function or resource capability can occur.

On the accepted-graph phase fixture (one iteration, 16 modules, 32 shapes per
module, 64 probes per module, import fan-out 4), seven alternating bare-binary
runs produced median retired-instruction counts of 8,500,317,773 for 37b and
8,492,287,706 for 37c. Median wall time was 0.58 seconds for 37b and 0.57
seconds for 37c. Both candidates produced 2,297 primary outputs, 33 secondary
outputs, and checksum `-877448313171944452`.

In explicit memory mode, allocations fell from 4,033,060 to 4,024,782,
retained objects fell from 848,690 to 844,814, and allocated bytes fell from
63,823,968 to 63,551,744.

Three alternating whole-compiler self-check pairs produced:

```text
control:   32.19s / 527,391,641,801 instructions
candidate: 27.44s / 463,044,975,565 instructions
control:   31.73s / 527,498,633,760 instructions
candidate: 27.49s / 462,899,089,240 instructions
control:   31.96s / 527,367,563,858 instructions
candidate: 27.88s / 463,035,402,249 instructions
```

Median wall time fell from 31.96 to 27.49 seconds, and median retired
instructions fell from 527,391,641,801 to 463,035,402,249. Median peak RSS was
slightly lower, from 1,101,742,080 to 1,095,696,384
bytes. The candidate compiler SHA-256 was
`3add0002bd2a10b6f523133bf3b8cea23ba820cef4f0d0696a7fe9af6e4faf76`.

## Objective

Build one accepted declaration catalog as a production Stage 06 graph product,
retain compact module visibility projections, and make the catalog/module view
the sole accepted-semantic authority for aliases, types, constructors, and
fields.

This issue must replace work immediately. It is not acceptable to retain a
catalog while continuing to publish the same type declarations into every
module `Env`.

## Context

Issue 36 provides a builder that consumes pre-assembly graph products. Issue 34
provides a narrow reusable module product that can refer to graph-level
authority without retaining an entire prior typecheck session.

The current module-view/type projections and definition identities should be
reused. Do not create a second index keyed by display strings.

## Required Change

1. Prepare the catalog's type-family authority once after accepted headers and
   before global completion; finalize the same catalog lineage by attaching
   successful completed globals before graph facts are published. Do not
   rebuild its type tables or module views during finalization.
2. Retain it in shared `TypecheckGraphFacts`, used by both accepted and
   recoverable graph wrappers.
3. Build one compact canonical module view per accepted module. A view contains
   only identities/projections required for visibility, qualification, aliases,
   and deterministic ambiguity handling.
4. Add category-specific exact and visible-name queries for:
   - aliases;
   - type declarations;
   - constructors; and
   - fields.
5. Route all production accepted-semantic readers for those categories through
   catalog/view queries.
6. Delete their imported and local graph-symbol writes to `Env`, along with any
   category indexes that no longer have lexical consumers.
7. Apply the same catalog authority to canonical preparation and the existing
   CTFE artifact preparation path while preserving dependency-only CTFE
   visibility. Do not create or assume a retained CTFE prepared environment;
   Issue 35 rejected that product after proving no repeated production build.

Exact lookup must validate nominal kind and owner. Visible-name lookup must use
the current module view and preserve ambiguity behavior. Do not expose a
generic untyped declaration query.

`DefinitionIndex` remains authoritative for source-definition identity and
navigation IDs, including Issue 32's owner-directed type-occurrence lookup.
Catalog entries and views must carry and reuse those established IDs; they must
not create a second identity namespace or reroute navigation through copied
semantic records.

For recoverable completion, build the catalog and views in shared facts from
accepted headers plus only the successfully completed global subset. Preserve
`global_completion_failures` and the existing failed-module exclusion before a
prepared module can be used. Add a fixture proving an unaffected module still
typechecks without seeing a failed or partial global as completed.

## Non-Goals

- Do not migrate globals, callables, overloads, traits, implementations, or
  UFCS.
- Do not redesign type identity or import semantics.
- Do not retain parallel `Env` reads as a fallback.
- Do not optimize lexical scopes.
- Do not change error wording or winner selection.
- Do not replace `DefinitionIndex` as source/navigation identity authority.

## TDD And Structural Proof

First add assertions requiring:

```text
accepted_declaration_catalog_builds == 1
catalog_type_entries == accepted_type_family_declarations
canonical_module_views_built == accepted_module_count
legacy_type_family_graph_symbol_installs == 0
```

Cover local, selective, aliased, qualified, and ambiguous type names;
same-spelling declarations owned by different modules; constructors and fields;
rejected declarations; and wrong-kind IDs. Add an unrelated module to the graph
and prove an exact query visits no additional candidates.

## Acceptance Criteria

- One catalog is built and retained per accepted graph.
- One canonical visibility view is built per accepted module.
- Type-family declarations are stored once in the catalog, not copied into
  module `Env` values.
- All type-family production reads use typed catalog/view queries.
- Legacy type-family writes, reads, indexes, and adapters are deleted.
- Exact results, ambiguity behavior, and diagnostics are unchanged.
- Accepted and recoverable graphs share catalog/views; recovery excludes failed
  modules and keeps unaffected modules usable.
- Increasing body count does not increase catalog or view construction.
- Focused Stage 06 tests and `scripts/compiler-check --changed` pass.
- `docs/ARCHITECTURE.md` describes the new type-family authority boundary in
  this same merge.

## Verification

Run catalog, type occurrence, import visibility, constructor/field, prepared
module, CTFE visibility, and frontend benchmark fixtures. Inspect logical
construction and query counters. Build once before merge and run the affected
Stage 06 manifest/tests. Run the reproducible latency gate above after the
combined canonicalization-plus-alias slice, then after the record and
union/constructor/field cutovers. Record the raw paired results and medians in
this issue before merge; Issue 35 produced no integration boundary to measure.
