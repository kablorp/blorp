# Cut Over Traits And Implementations To The Declaration Catalog

**Status:** Implemented

**Dependencies:** Issue 40

**Parallel work:** UFCS inventory and tests may be prepared for Issue 42, but
UFCS implementation depends on the final trait/implementation query surface.

## Objective

Make the catalog and module views the sole authority for accepted traits,
trait methods, implementations, implementation methods, privacy, inheritance,
and coherence lookup. Remove those graph-owned records and indexes from `Env`.

## Required Inventory

Classify every consumer of:

- trait identity and visible trait names;
- supertrait edges and inherited method availability;
- trait method owner and slot identity;
- implementation identity and trait/type candidate indexes;
- public versus module-private implementations;
- implementation conflict and coherence checks;
- default versus explicit methods;
- implementation method exact callable identity; and
- generic bounds that consult trait facts.

Do not infer method or implementation identity from synthesized names.

## Required Design

- Catalog entries own full traits, method slots, implementations, methods, and
  nominal relationships.
- Module views own visible trait and implementation IDs, including privacy and
  deterministic order.
- Exact queries validate kind and owner.
- Relational queries use explicit trait/type/method IDs.
- Coherence checks preserve the current deterministic diagnostic winner when
  several conflicts are present.
- Private implementations remain visible only in the owning module under the
  existing rules.

After every subfamily migrates, delete its old `Env` readers and writers in the
same change. Split this issue before implementation if one review cannot cover
traits and implementations coherently, but keep the dependency order and do
not leave a migrated family dual-owned.

## Non-Goals

- Do not redesign traits, inheritance, coherence, or privacy semantics.
- Do not migrate UFCS candidate construction; Issue 42 owns it.
- Do not synthesize string keys as a shortcut for nominal relationships.
- Do not move local type-parameter bounds out of session state.
- Do not retain old/new comparison fallbacks.

## TDD And Structural Proof

Cover:

- trait lookup by exact ID and visible name;
- trait inheritance and inherited method availability;
- method owner and slot identity;
- default and explicit implementation methods;
- implementation selection and exact conflict diagnostics;
- private implementation isolation;
- generic trait bounds;
- wrong-category and wrong-owner IDs;
- rejected traits/implementations never entering views; and
- stable answers when unrelated modules are added.

Require zero legacy trait, implementation, and method graph installs. Candidate
visits must scale with relevant trait/type relations, not all graph entries.

## Acceptance Criteria

- All accepted trait and implementation facts are catalog-owned.
- Module views contain compact visible IDs and privacy projections.
- `Env` no longer stores graph traits, implementations, or their methods.
- Inheritance, generic bounds, privacy, coherence, and exact diagnostics are
  unchanged.
- No synthesized-name identity or compatibility adapter is introduced.
- Focused tests and `scripts/compiler-check --changed` pass without a clear
  latency regression.
- Recoverable graph behavior and failed-module exclusion remain unchanged.
- `docs/ARCHITECTURE.md` describes catalog/view-owned traits and implementations
  in this same merge.

## Verification

Run trait, inheritance, implementation, privacy, generic-bound, method, and
coherence fixtures plus the dense frontend benchmark. Inspect exact conflict
diagnostics and method-slot identities. Build once before merge and run the
affected Stage 06 tests.

## Implementation Result

Accepted source traits and implementations now have one graph-owned semantic
table. Each prepared module view retains only deterministic table indices for
its local declarations and public direct imports, plus a relevant-trait
candidate index. Trait inheritance, method ownership, implementation
selection, generic bounds, and private implementation isolation read that
authority. Prepared `Env` values retain compiler builtins and session-local
facts, but no accepted source trait, implementation, or method publication.

The cutover also removes imported trait/implementation reconstruction from
module preparation. A logical-counter regression requires one semantic table
entry and conversion per accepted header, compact module-view indices, zero
legacy graph installs or full-record view copies, and zero exact-query graph
scans. Coherence overlap relationships are computed once in the table; module
views only test precomputed conflicting indices that are actually visible.

In three isolated compiler self-check samples through Stage 06, the final
implementation retired a median 290,397,281,209 instructions versus
316,649,911,090 for its Issue 40 parent, an 8.3% reduction. Median wall time was
16.55 seconds versus 17.94 seconds, a 7.7% reduction; retired instructions are
the primary evidence because unrelated host activity makes wall time noisier.
