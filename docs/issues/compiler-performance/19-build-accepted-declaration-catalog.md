# Build A Checked Accepted Declaration Catalog

**Status:** Implemented and measured

## Context And Dependencies

This issue extracts Slice 1 from
[`13-freeze-frontend-declaration-catalog.md`](13-freeze-frontend-declaration-catalog.md).
It introduces the eventual graph-owned catalog as a checked product but does not
retain or use it in production compilation.

Issue 15 demonstrated material repeated installation. Issue 16 landed the
shared mixed-symbol batch primitive. Issue 17 was rejected after measurement
and Issue 18 was deferred, so the catalog deliberately depends only on the
opaque `AcceptedTypecheckGraph`, not on temporary batching adapters.

## Implemented Scope

The catalog is implemented in
`compiler/src/stage_06_typecheck/headers/declaration_catalog.brp`. Construction
accepts one opaque `AcceptedTypecheckGraph`; independently pairable graph
products are not part of the API. The catalog is not retained by normal
compilation in this issue.

Each category owns an ordered entry list and a separate exact index. Runtime
definition IDs are always qualified by module identity. Structural type and
global IDs use module-plus-name indexes followed by exact nominal equality.
The entry lists preserve the accepted order within each category; the initial
prototype's redundant all-category "source order" list was removed because it
was category order, not source order, and duplicated one allocation per entry.

Entries retain resolved semantic facts needed by Issues 21 and 22: complete
resolved type parameters, shapes and containment; constructor variants;
callable parameters, signatures, categories and dimension constraints; global
and callable dependency identities; trait parameters, supertraits and method
categories; and implementation parameters, receiver classification, method
category and method signature. Parsed declarations are not copied.

The accepted graph already guarantees component provenance, owner validity,
and header-graph completeness. Catalog construction therefore treats those as
input invariants. It still fails closed for errors introduced by its own
projection: duplicate exact-index keys, module-qualified runtime-ID category
reuse, missing declaration-skeleton visibility, and an unprojectable
implementation-method signature.

## Problem Statement

Accepted declarations currently exist across several products:

- type header and topology graphs;
- callable header graph;
- completed global header graph;
- implementation header graph;
- importable module graph;
- module surfaces and views; and
- materialized `Env` fields.

The final architecture needs one identity-keyed source of accepted declaration
facts. Building that source directly in production before its invariants are
proven risks duplicate identities, stale provenance, category confusion, and
increased peak memory.

## Goal

Create and validate an immutable `AcceptedDeclarationCatalog` from accepted
graph products. Exercise it only in focused tests and benchmarks. Build and
discard it outside production typechecking so this merge point cannot increase
normal peak memory.

## Ownership And Lifetime

The eventual owner is one `AcceptedTypecheckGraph`. For this issue:

- catalog construction receives one opaque accepted graph;
- the catalog owns indexes and compact declaration facts;
- catalog entries carry nominal IDs; canonical source spans remain available
  through the IDs rather than being copied into every entry;
- no AST, typed expression, body context, or `Env` stores a copy;
- tests release the catalog and prove no retained allocations remain.

## Required Type Shape

Add a production module under
`compiler/src/stage_06_typecheck/headers/declaration_catalog.brp` and update the
compiler ownership manifest.

Use an opaque product with private representation. It must support distinct
category indexes for:

```text
TypeId
ConstructorId
CallableId
GlobalId
TraitId
implementation identity
implementation method identity or owner-plus-slot identity
```

Do not use aliases if they are not nominally distinct. Do not key authoritative
lookups by source string, display module name, C symbol, or legacy `def_id`
alone.

Each entry contains only facts needed after header acceptance:

- nominal identity and category;
- owner module/type/trait identity;
- semantic signature or type facts;
- visibility;
- canonical source span through the nominal identity;
- containment/resource policy;
- deterministic order through its category entry list; and
- explicit callable/method category where later lookup semantics require it.

Do not copy complete parsed declarations unless a later consumer demonstrably
needs them.

## Builder Contract

The builder is:

```blorp
pure func accepted_declaration_catalog_build(
	graph: AcceptedTypecheckGraph,
) -> Result[AcceptedDeclarationCatalog, List[DeclarationCatalogError]]
```

Build each index with local accumulators and publish once. Preserve accepted
order in each category list separately from exact identity lookup.

## Fail-Closed Validation

The opaque accepted graph constructor already rejects missing owners, owner
mismatches, incompatible provenance, and incomplete headers. Revalidating those
conditions in this builder would add repeated graph scans and unreachable test
states. The catalog rejects and tests the new invariants it introduces:

- duplicate nominal identity;
- same module-qualified runtime identity in different categories;
- missing type or constructor visibility projection;
- missing implementation-method signature;
- accepted graph entry absent from the catalog; and
- catalog entry absent from accepted graph products.

Return typed errors. Do not silently choose a winner.

## TDD Sequence

1. Add one entry per category and assert exact identity lookup.
2. Assert category-specific APIs cannot cross-cast identities.
3. Assert deterministic accepted order within every category projection.
4. Test fail-closed catalog-local index and projection errors where the state is
   constructible; do not add test-only constructors for invalid opaque accepted
   graphs.
5. Build from a focused real accepted graph and compare every graph entry with
   its catalog projection.
6. Compile the same graph with perturbed module discovery order and assert
   artifact/catalog projection identity where stable identities require it.
7. Release the result under leak checking.

## Benchmark

Create a focused catalog-construction mode using Issue 15's fixture controls.
Measure:

```text
unique entries by category
index entries by category
ordered entries by category
builder visits
duplicate checks
elapsed microseconds
allocations/releases
retained objects after release
allocator bytes
checksum
```

Expected construction work is `O(unique declarations)`. Doubling unique
declarations with fixed declaration shape must not produce a deterministic
work exponent above 1.10.

Compare catalog retained bytes with the accepted graph products it projects.
Record bytes per entry and identify duplicated fields before Issue 20 retains
the catalog in production.

### Results

The focused harness is
`benchmarks/compiler_declaration_catalog_profile`. Accepted graph construction
is setup and excluded from the measured window. The measured loop builds and
discards catalogs; a separate unmeasured build records retained catalog size.

Configuration: four shapes per module, one probe per module, import fanout two,
20 catalog builds per row.

| Modules | Entries | Visits | Time (us) | Allocations | Retained objects | Retained bytes |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 2 | 57 | 1,140 | 24,584 | 25,960 | 132 | 12,408 |
| 4 | 105 | 2,100 | 41,893 | 47,880 | 218 | 20,312 |
| 8 | 201 | 4,020 | 72,099 | 91,560 | 390 | 36,120 |
| 16 | 393 | 7,860 | 138,165 | 178,760 | 734 | 67,864 |
| 32 | 777 | 15,540 | 270,771 | 353,000 | 1,422 | 131,352 |

Visits and allocations are exactly linear in accepted entries. From 393 to
777 entries, elapsed time grows by 1.96x for 1.98x the input, an empirical
exponent of approximately 0.99. Every build-and-discard row reports equal
allocations/releases, zero retained objects, and zero retained bytes. The
largest retained catalog is approximately 169 bytes per entry; Issue 20 must
include this additive cost in its production replay memory gate.

The catalog benchmark resets allocation accounting after accepted-graph setup
and reports balanced build/discard allocations with zero retained objects. The
shared mixed accepted-graph fixture itself has a pre-existing per-test leak
baseline (`test_compiler_typecheck_phase_profile` reports three objects under
direct `--leak-check`), so the catalog suite is not mapped to that fixture-level
leak check. Fixing that fixture lifetime is separate from catalog ownership and
must not be represented as a catalog leak.

## Non-Goals

- Do not modify `TypecheckState`, `Env`, or body lookup.
- Do not retain the catalog in accepted graph facts.
- Do not add module visibility projections yet.
- Do not preserve compatibility bridges based on names.
- Do not serialize or cache the catalog on disk.
- Do not delete existing header graphs.

## Verification

```bash
./blorp test --timeout 180 compiler/tests/test_compiler_declaration_catalog.brp
./blorp test --timeout 180 compiler/tests/test_compiler_declaration_identity_index.brp
./blorp test --timeout 180 compiler/tests/test_compiler_callable_headers.brp
./blorp test --timeout 180 compiler/tests/test_compiler_type_header_graph.brp
scripts/compiler-check --stage typecheck
scripts/test compiler-blorp-sanitize
```

Use actual suite names present after implementation and map the new production
module exactly once in the ownership manifest.

## Acceptance Criteria

- One opaque, category-safe catalog projects every accepted declaration exactly
  once.
- Builder and validation are deterministic and fail closed.
- Construction scales linearly in unique declarations.
- Focused graph projections match existing accepted products.
- Normal compilation does not build or retain the catalog.
- No leak remains after catalog release.
- Retained bytes per entry are recorded for Issue 20's memory gate.

## Merge Point

This is independently mergeable because the checked representation is usable
in tests and benchmarks but cannot affect normal compilation behavior or peak
memory.
