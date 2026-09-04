# Stage 06 Environment Reuse Roadmap

**Status:** Proposed execution outline

## Objective

Make Stage 06 construct graph-owned declarations once, derive explicit
visibility views once per module and environment kind, and create only fresh
lexical/session state for individual checks.

The detailed design, tests, and acceptance criteria live in the linked issue
documents. This file defines only sequencing, parallel work, shared invariants,
and the intended end state.

## Intended End State

```text
accepted module graph
        |
        v
one accepted declaration catalog
        |
        +-------------------------+
        |                         |
        v                         v
canonical module views      CTFE dependency views
        |                         |
        +------------+------------+
                     |
                     v
       fresh lexical/body sessions
```

- The catalog owns accepted declarations and nominal identity.
- Module views own visibility, qualification, aliases, precedence, and stable
  candidate order.
- A prepared module environment owns reusable module-level facts only.
- A typecheck session owns lexical scopes, context, inference state, errors,
  diagnostics, refinements, and other per-check state.
- `Env` ultimately contains lexical state, not copied module-graph
  declarations.

## Shared Invariants

Every issue must preserve:

1. exact accepted-graph, module, environment-kind, and policy provenance;
2. fresh session-local inference and diagnostic state;
3. ordered visibility of completed globals during initializer checking;
4. distinct canonical and CTFE dependency visibility;
5. separation between catalog identity and module source-name visibility;
6. existing lexical shadowing, candidate ordering, and exact diagnostics;
7. no old/new fallback or dual authority after a family is migrated; and
8. no clear Phase 01-06 latency regression.

Reusable products belong to the shared `TypecheckGraphFacts` used by both
`AcceptedTypecheckGraph` and `RecoverableTypecheckGraph`. Partial global
completion must retain only successfully completed global facts, preserve the
existing failed-module exclusion, and still allow unaffected modules through
`recoverable_graph_typecheck_module`.

`DefinitionIndex` remains the source-definition and navigation-ID authority.
The declaration catalog owns accepted semantic declarations, while module
views own their source visibility. Catalog cutovers reuse established nominal
definition IDs rather than replacing or duplicating the index.

Use the existing frontend declaration-catalog fixture, deterministic logical
counters, and controlled Phase 01-06 self-check profile. Timing is supporting
evidence; counters are the fast, CI-stable proof that reconstruction was
removed.

## Dependency Outline

```text
Independent precursor
  32 owner-directed DefinitionIndex lookup

Track A: reusable environment lifetime
  33 reuse initializer bases for ordinary bodies
   |
  34 separate prepared module environments from sessions
   |
  35 rejected: no repeated CTFE dependency-environment build

Track B: declaration authority
  36 decouple declaration-catalog construction
   |
   +------------------+
                      v
       37 retain catalog and cut over types
          ^
          |
         34

Continuation after 37
  38 globals
   |
  39 exact callable identity
   |
  40 source callable candidates and overloads
   |
  41 traits and implementations
   |
  42 UFCS and remaining callable metadata
   |
  43 delete legacy materialization and reprofile
   |
  44 optimize lexical environments only if still measured
```

## Parallelization

### Safe first wave

These issues are semantically independent and have reasonably isolated primary
files, so they may be developed in separate worktrees at the same time:

- [32: Use owner-directed DefinitionIndex lookups](32-use-owner-directed-definition-index-lookups.md)
- [33: Reuse initializer module environments for ordinary body checking](33-reuse-initializer-module-environments-for-body-checking.md)
- [36: Decouple accepted declaration catalog construction](36-decouple-accepted-declaration-catalog-construction.md)

Issue 32 changes exact type-definition lookup. Issue 33 changes lifetime and
reuse of an existing canonical environment. Issue 36 changes how the isolated
catalog builder receives its inputs, without yet installing the catalog into
production graph facts.

Integrate 32 and 36 before or after 33 as convenient. Each worker must rebase or
merge current main before final verification because imports and Stage 06 test
manifests may still overlap.

### Second wave

After Issue 33, Issue 34 is required before further reusable-environment work.
After Issue 36, catalog tests and query inventories can continue independently,
but Issue 37 must wait for Issue 34 because it retains the catalog alongside
the narrowed prepared-module product.

Issue 35 was audited after Issues 34 and 36 integrated and was rejected. CTFE
dependency preparation already deduplicates modules and retains each resulting
typed dependency in `PreparedTypecheckContext`; a graph-owned environment would
add eager construction and lifetime without removing demonstrated duplicate
work. Issue 37 therefore proceeds directly after Issues 34 and 36. It must
preserve CTFE dependency-only visibility while applying catalog authority, but
must not introduce the rejected prepared-environment product.

Issue 37's first broad cutover attempt was abandoned before merge after a
controlled self-check showed about 45% more retired instructions. The retry is
therefore serial even if Issue 35 work exists elsewhere. It uses vertical
category checkpoints: canonicalization plus aliases, records, then
unions/constructors/fields. Every checkpoint adds its category authority,
cuts over its readers, and deletes its legacy indexes and `Env` publication in
the same increment. Each must reduce focused allocations and instructions,
lower whole-compiler median retired instructions versus its parent, and avoid
a clear wall-time regression. Identity-only views and category-specific tables
are mandatory; payload-bearing views, generic managed-entry caches, and merged
scaffolding without an immediate deletion are prohibited.

All three Issue 37 checkpoints are implemented. Aliases, records, and
unions/constructors/fields each retain one graph-owned category table and
identity/scalar module views. Their accepted payload publication and legacy
projection/index paths are removed; provisional header checking continues to
use `Env`. Every checkpoint passed its focused allocation/instruction gate and
lowered whole-compiler median retired instructions versus its parent.

Issue 38 is implemented. Accepted globals now live once in a category-specific
table with compact module views. Initializer sessions expose annotated headers
plus only exact completed inferred dependencies; ordinary and CTFE body views
expose successful completions only. Graph-global `Env` publication and legacy
module-variable lookup have been removed.

Issue 39 is implemented by deletion after its prerequisite removed every
production exact-metadata reader. Resolved calls retain the chosen candidate's
bound parameters and debug-only status, and `Env` no longer builds an exact
callable-ID index. Source-name candidate storage remains for Issue 40.

Issue 40 is implemented. Accepted source and foreign callables now live once
in an immutable category table, while module views retain compact ordered
indices for visible names, qualification, and source-function UFCS. Prepared
`Env` values no longer contain graph callables, and the unused standalone
overload channel is deleted. The Phase 01-06 self-check retired 27.7% fewer
instructions than the Issue 39 baseline with no latency regression.

Issue 41 is implemented. Accepted source traits and implementations now live
once in an immutable semantic table; prepared module views retain compact
visibility and relevant-trait candidate indices. Imported trait and
implementation reconstruction is removed from module preparation, and
prepared `Env` values retain only compiler-builtin trait facts. Coherence
relationships are computed once in the table rather than once per module
view. Three isolated Phase 01-06 self-check samples retired a median 8.3%
fewer instructions than the Issue 40 parent with 7.7% lower median wall time.

Issue 42's fail-fast prototypes did not reduce Phase 01-06 retired
instructions, so the accepted change stops short of the candidate-selection
cutover. It deletes the dormant standalone `Env` UFCS channel and keeps real
lexical, provisional, and builtin functions in the session scope path. The
existing accepted-callable candidate-list path remains until a simpler design
can demonstrate an instruction reduction.

### Later declaration families

Issues 38-42 should be integrated serially. Their semantic inventories and
tests can be prepared in parallel, but the implementations all remove fields,
writers, and readers from the same `Env`, module-view, and declaration-query
surfaces. Parallel implementation would create avoidable conflicts and a risk
of temporary dual authority.

Issue 43 is strictly last. Issue 44 is conditional and starts only if the final
profile still identifies lexical environment work as material.

## Issues

### Reusable environment lifetime

- [33 — Reuse initializer module environments for ordinary body checking](33-reuse-initializer-module-environments-for-body-checking.md)
- [34 — Separate reusable module environments from typecheck sessions](34-separate-reusable-module-environments-from-typecheck-sessions.md)
- [35 — Reuse CTFE artifact dependency environments (rejected after audit)](35-reuse-ctfe-artifact-module-environments.md)

### Declaration authority

- [36 — Decouple accepted declaration catalog construction](36-decouple-accepted-declaration-catalog-construction.md)
- [37 — Retain the declaration catalog and cut over types](37-retain-declaration-catalog-and-cut-over-types.md)
- [38 — Cut over graph globals](38-cut-over-graph-globals.md)
- [39 — Cut over exact callable identity](39-cut-over-exact-callable-identity.md)
- [40 — Cut over source callable candidates and overloads](40-cut-over-callable-candidates-and-overloads.md)
- [41 — Cut over traits and implementations](41-cut-over-traits-and-implementations.md)
- [42 — Cut over UFCS and remaining callable metadata](42-cut-over-ufcs-and-callable-metadata.md)

### Completion and optional follow-up

- [43 — Delete legacy environment materialization and reprofile](43-delete-legacy-environment-materialization-and-reprofile.md)
- [44 — Optimize lexical environments only if still measured](44-optimize-lexical-environments-if-measured.md)

## Merge Discipline

Each issue must:

1. begin with a failing logical-counter or behavior assertion;
2. remove one reconstruction or authority path;
3. delete its superseded reads and writes in the same merge;
4. preserve exact results and diagnostics;
5. use focused Stage 06 checks during iteration;
6. run `scripts/compiler-check --changed` before merge; and
7. record latency evidence at Issues 33, 37, 42, and 43.

Issue 37 additionally records a current-main baseline and enforces a cumulative
performance ratchet after every category cutover. A production checkpoint that
does not measurably beat its immediate parent is redesigned or combined with
the next deletion rather than merged independently.

Do not batch adjacent issues into one change merely because they share files.
The point of the sequence is to preserve clean rollback and measurement points.

## Completion Criteria

The roadmap is complete when:

- one accepted declaration catalog is built per accepted graph;
- each module has one canonical view and at most one distinct CTFE dependency
  view when required;
- module-environment construction is independent of body count;
- accepted declaration storage no longer grows with the sum of module
  visibility closures;
- every check receives fresh session-local state;
- `Env` has a documented lexical-only responsibility;
- no legacy graph publication or fallback lookup remains;
- accepted and recoverable graph paths share the same reusable products,
  failed modules remain excluded, and unaffected modules still typecheck from
  partial successfully completed global facts; and
- a controlled Phase 01-06 profile shows no material latency regression and
  records the actual improvement without extrapolation.

## Superseded Planning Documents

- `22-cut-over-values-traits-and-implementations.md` is an inventory source for
  Issues 38-42, not an executable issue.
- `23-delete-legacy-declaration-materialization-and-reprofile.md` is superseded
  by Issue 43.
