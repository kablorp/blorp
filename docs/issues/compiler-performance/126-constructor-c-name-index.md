# Index Constructor C-Name Lookup

**Status:** Proposed; phase-owned index design required

**Current state:** `operation_metadata.constructor_c_name` scans every Core
declaration and then the selected union's variants for each lookup. The
retained self-profile observed hundreds of calls.
**Next action:** Count lookup keys and misses, identify the nearest existing
operation-metadata/layout owner, and build one string-pair constructor index per
program.
**Read first:** `blorp/src/compiler/stage_09_core/operation_metadata.brp`,
`blorp/src/compiler/stage_09_core/specialize_layout.brp`, and
`blorp/test/compiler/stage_09_core/test_core_specialize_layout.brp`.
**Fast loop:** Run the Core pipeline suite plus a proposed constructor metadata
lookup profile.
**Decision:** Key by both union and constructor source strings; operation specs
do not carry nominal IDs. Do not use constructor spelling alone or introduce a
second program-wide authority.

## Objective

Replace repeated declaration/variant scans with one index build and expected
constant-time lookups.

## Proposed Shape

Prefer extending an existing phase-owned layout/metadata product with the
existing dictionary key types:

```blorp
-- union source name -> constructor source name -> C name
Dict[String, Dict[String, String]]
```

Admit only a missing `(union_name, constructor_name)` pair. This preserves the
first matching pair while allowing a later same-name union declaration to fill
a constructor absent from an earlier declaration. Never use dictionary
iteration for output. Thread the index through the pass rather than rebuilding
it per expression.

## Invariants And Tests

- Same constructor spelling in two unions must not collide.
- Preserve selected union, variant order, exact C spelling, and missing lookup.
- Across duplicate same-name union declarations, the first matching
  constructor wins, but a later declaration may supply a constructor absent
  from earlier declarations.
- Cover empty programs, early/late unions, early/late variants, duplicate
  spellings across unions, and malformed duplicate identities.
- Preserve operation metadata, Core, generated C, and diagnostics.
- Do not combine this with the harder `match_projection.find_enum_variant`
  index until both phases have a single clear owner.

## Feedback Loop

The proposed profile should vary declarations, unions, variants, lookup count,
hit position, and misses, including zero-lookup and single-lookup controls.
Record index-build rows, declaration/variant visits, lookup probes,
allocations/releases, retained objects, retired instructions, elapsed time, and
exact metadata/C-name checksum.

```bash
bin/blorp test --timeout 180 blorp/test/compiler/stage_09_core/test_core_pipeline.brp
bin/blorp test --timeout 180 blorp/test/compiler/stage_09_core/test_core_specialize_layout.brp
bin/blorp test --timeout 180 blorp/test/compiler/stage_09_core/test_core_backend_projection.brp
bin/blorp test --timeout 180 blorp/test/compiler/stage_10_backend/test_core_emit.brp
scripts/compiler-check --changed
scripts/test compiler-blorp
```

## Acceptance And Rejection

Accept when repeated declaration scans fall to zero after one build, a
many-lookup fixture improves instructions or allocations by at least 10%, and
zero-lookup and single-lookup controls remain within 2% for allocations,
instructions, elapsed time, and retained state. Require metadata/Core/C
identity. Reject if the index is rebuilt per lookup, uses constructor-only
keys, duplicates an existing authority, or shifts equivalent work into index
construction without a measured production benefit.
