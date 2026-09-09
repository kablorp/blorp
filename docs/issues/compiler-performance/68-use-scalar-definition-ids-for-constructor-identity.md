# Use Scalar Definition IDs For Constructor Identity

**Status:** Implemented and validated

**Roadmap:** [Normalized Compilation Database Roadmap](NORMALIZED_COMPILATION_DATABASE_ROADMAP.md)

**Dependencies:** [Issue 61B: Establish the canonical graph definition table](61-establish-canonical-graph-definition-table.md)

## Objective

Make graph-backed `ConstructorId` a scalar, category-checked foreign key into
the accepted graph's canonical `DefinitionTable` instead of a managed record
that repeats module, name, owner, and source-span data already stored there.

This is the first category cut in Horizon 2. It does not migrate callables,
globals, traits, implementations, fields, type IDs, or Core IDs.

## Current Representation And Cost

`declaration_skeleton.brp` currently constructs two managed records for every
graph constructor:

```blorp
private record StructuralDeclarationIdRep {
	module_id: ModuleId,
	name: String,
	owner: Option[String],
	span: SourceSpan
}

private record RuntimeDeclarationIdRep {
	structural: StructuralDeclarationIdRep,
	definition_id: Int
}

opaque type ConstructorId = RuntimeDeclarationIdRep
```

The canonical `DefinitionRow` already owns the same module, category, name,
owner name, and span. Before implementation, Stage 06 contains 22
`ConstructorId` references in two production modules. Constructor module and
span accessors have no caller outside `declaration_skeleton.brp`.

## Required Representation

```blorp
opaque type ConstructorId = Int
```

Construction must:

1. resolve the existing runtime definition integer through `DefinitionIndex`;
2. admit the integer through that exact `DefinitionIndex` query, whose
   `ConstructorDefinition` key is checked against the canonical row category;
3. construct `ConstructorId` only from that admitted scalar result; and
4. emit the existing missing-definition error if lookup or admission fails.

No constructor ID may be minted from a raw integer, name, span, or `TypeId`.
No fallback may retain the old structural record.

## Provenance Contract

`DefinitionId` and `ConstructorId` are table-scoped scalar foreign keys. Equal integers
from independently constructed tables are not globally equal identities.
Stage 06 creates and compares constructor IDs only inside one
`DeclarationSkeletonGraph`, which retains the bound graph and issuing table.
The graph-local equality helpers are private so callers cannot compare opaque
constructor IDs without the owning graph/table context.

Before leaving that domain, existing boundaries project constructor identity
into destination-owned forms:

- accepted union/type facts store the runtime definition integer under the
  accepted graph's module domain;
- CTFE uses `CtfeResolvedConstructorId`, with explicit module-table
  provenance; and
- Core consumes resolved constructor payloads rather than comparing unrelated
  Stage 06 constructor IDs.

If implementation finds a cross-table comparison, stop and represent its
provenance explicitly. Do not add a table pointer to every ID.

## Mechanical Changes

### `headers/declaration_skeleton.brp`

1. Use the existing exact source-definition query with a
   `ConstructorDefinition` key. Do not add a parallel constructor index query;
   an experimental duplicate added one allocation/release per lookup.
2. Change only `ConstructorId` to use `Int` as its opaque payload. A nested
   opaque `DefinitionId` payload was measured and rejected because it added one
   allocation and release per constructor lookup in the maintained benchmark.
3. Construct it only after category-checked table admission.
4. Compare constructor IDs by scalar definition value.
5. Derive constructor names and duplicate spans from the authoritative parsed
   source already retained by `ConstructorDeclarationSkeleton`.
6. Remove unused constructor module/span accessors.
7. Keep `RuntimeDeclarationIdRep` for callable, trait, and implementation IDs.

`type_header_graph.brp` should need no representation change. Its exact query
continues returning `ConstructorId`, and parent/name/span checks remain intact.

## Tests First

The declaration boundary check must fail before production edits and assert:

- `ConstructorId` is backed by scalar `Int`;
- it is not backed by `RuntimeDeclarationIdRep`; and
- no constructor accessor reaches a retained `.structural` payload.

Existing public tests must stay exact for same names across modules/parents,
duplicates within one parent, diagnostic ordering/spans, wrong parent/span,
missing lookup, exact returned identity, and wrong-category admission. Add
behavior coverage only if the audit finds a gap; do not expose table internals.

## Fast Feedback

```bash
python3 blorp/test/compiler/stage_06_typecheck/support/test_declaration_boundary.py
bin/blorp test --timeout 180 blorp/test/compiler/stage_06_typecheck/test_definition_index.brp
bin/blorp test --timeout 180 blorp/test/compiler/stage_06_typecheck/test_declaration_skeleton_graph.brp
bin/blorp test --timeout 180 blorp/test/compiler/pipeline/test_type_header_graph.brp
```

Before merge:

```bash
scripts/compiler-check --changed
scripts/compiler-check --stage typecheck
```

## Implementation Result

`ConstructorId` is now an opaque `Int`. Constructor skeleton construction uses
the existing exact `definition_index_find_source_definition_id` query with a
`ConstructorDefinition` key. Since Issue 61B, that query reads the ID-only
module/name bucket and validates the complete canonical row, including category,
owner, name, module, and span, before returning the runtime integer.

The declaration skeleton's parsed variant remains the local source authority
for its name and span. Duplicate diagnostics therefore retain their exact text,
order, and source location without materializing a `DefinitionRow` or retaining
another identity record. The unused constructor module/span accessors were
deleted. No other identity category changed.

Two prototypes were rejected during measurement:

- `ConstructorId = DefinitionId` added one allocation and release per repeated
  constructor lookup because nested opaque values did not lower allocation-free
  in this context; and
- a parallel constructor-specific definition-index query duplicated the
  canonical lookup path and produced the same regression.

Neither prototype remains. The accepted implementation uses one existing query
and one scalar category ID.

## Focused Measurement

Baseline and candidate used the same bootstrap and source tree except for the
constructor identity change. Three alternating pairs ran both the declaration
skeleton construction window and its downstream type-header consumer:

```bash
bin/blorp run --release \
  blorp/benchmark/compiler/compiler_typecheck_phase_profile.brp -- \
  skeleton 20 8 32 64 4 memory

bin/blorp run --release \
  blorp/benchmark/compiler/compiler_typecheck_phase_profile.brp -- \
  headers 20 8 32 64 4 memory
```

All six pairs produced identical primary outputs, semantic checksums, 33 exact
constructor lookup requests, candidate counts, and lookup checksums.

| Window | Metric | Baseline median | Candidate median | Delta |
| --- | --- | ---: | ---: | ---: |
| Skeleton | elapsed | 14,679 us | 14,511 us | -1.14% |
| Skeleton | allocations | 201,241 | 199,261 | -1,980 (-0.98%) |
| Skeleton | releases | 197,253 | 195,339 | -1,914 (-0.97%) |
| Skeleton | retained objects | 3,988 | 3,922 | -66 (-1.65%) |
| Skeleton | live bytes | 285,808 | 282,640 | -3,168 (-1.11%) |
| Headers | elapsed | 46,254 us | 46,258 us | +0.01% |
| Headers | allocations | 533,901 | 534,561 | +660 (+0.12%) |
| Headers | releases | 529,488 | 530,148 | +660 (+0.12%) |
| Headers | retained objects | 4,413 | 4,413 | 0 |
| Headers | live bytes | 350,512 | 350,512 | 0 |

The skeleton window removes three allocations and two retained records per
constructor. Passing the scalar through the repeated downstream lookup adds one
transient allocation/release per lookup. A production-shaped build constructs
and consumes each graph once, so the combined deterministic result is two fewer
allocations and two fewer retained objects per constructor. Combined focused
median elapsed was 60,933 us baseline and 60,769 us candidate (-0.27%).

Raw focused output is retained in the ignored
`logs/issue68-constructor-id/final/` directory.

## Production Replay

The baseline and candidate workers were built serially with the same pinned
bootstrap. One warmup per worker preceded three alternating target-only replay
pairs using allocator statistics, no inventory, a 120-second timeout, and a
2-GiB sampled-RSS ceiling.

| Metric | Baseline median | Candidate median | Delta |
| --- | ---: | ---: | ---: |
| elapsed | 6.596947 s | 6.589933 s | -0.11% |
| peak RSS | 503,431,168 | 502,972,416 | -458,752 (-0.09%) |
| allocations | 46,379,260 | 46,372,454 | -6,806 (-0.015%) |
| releases | 41,181,611 | 41,181,611 | 0 |
| current objects | 5,208,138 | 5,201,332 | -6,806 (-0.13%) |
| live bytes | 470,896,448 | 470,569,760 | -326,688 (-0.07%) |

The exact 6,806-object reduction is two retained records for each of the 3,403
production constructors. Elapsed and RSS changes are below-noise; the accepted
benefit is deterministic allocation and graph-lifetime memory reduction.

Every run was verified, exited zero, stayed within timeout/memory bounds, and
reported allocator data. Request and replay SHA-256 were both
`5eabbc7bafad8b070b8d9d2ff13c71bb5b5f4760cb0989c2827c00b0a5843c6b`.
All responses were byte-identical at 1,755,080 bytes with SHA-256
`f11d97d6f1cf5ac91ae76d1461ded8ba5a8884f1217504621bf3707d75363851`.
Worker SHA-256 values were
`70bcf228f988af55b4a4a5a5c7aa36c70992960bc1c0c8f06143896780dc6ca9`
for baseline and
`1cdba0b188cd6d430fa64877d0137c11078a84020f635c72b42a3048f839cc9d`
for candidate. Raw replay JSON is ignored under
`logs/issue68-constructor-id/replay/`.

## Generated C

Generated C from the maintained phase benchmark shows constructor skeleton IDs
stored and extracted as `long`, and `ConstructorDeclarationSkeletonInfo_make`
accepts a `long id`. `RuntimeDeclarationIdRep` remains generated only for the
unmigrated callable, trait, and implementation categories. There is no retained
constructor structural payload.

## Acceptance Criteria

1. Construction and wrong-category admission fail closed.
2. Lookup, duplicate behavior, diagnostic order, and spans are unchanged.
3. Generated C contains scalar constructor IDs and no hidden structural payload.
4. Focused constructor workloads reduce deterministic allocations and retained
   objects without material elapsed regression. **Met.**
5. Production output is identical with lower allocations/retained memory and no
   material RSS or elapsed regression. **Met.**
6. No test-only API, alternate representation, fallback, or table pointer
   remains.
7. `CallableId` and all other categories remain unchanged.

If deterministic allocation evidence is neutral or negative, restore the
production representation and retain only the documented rejection.

## Non-Goals

- migrating any identity category other than `ConstructorId`;
- changing definition/module table ownership or identity allocation;
- changing type-header lookup, visibility, diagnostics, or CTFE behavior;
- changing direct-program insertion or adding caching; or
- implementing later relationship edge tables.
