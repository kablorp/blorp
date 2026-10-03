# Struct Payload Findings (Archived)

No step remains open here. The [Record Simplification
Roadmap](FIXED_LAYOUT_ROADMAP.md) supersedes expanding the separate
`struct` value path. This file remains as a short landing point for older
links; the [Memory Model](MEMORY_MODEL.md) describes current behavior until
the semantic migration lands.

The current compiler emits valid `struct` values inline when their fields
and destination permit it. Erased union, tuple, dictionary, closure-call, and
some list placements instead use a transport box. A static box-site count is
not a dynamic allocation count.

The evidence that changed the direction:

- Converting `SourceSpan` to a struct cut discovery allocations by 5.5%
  but raised typed-frontend allocations by 2.0%; 662 of 903 candidate C box
  sites were spans entering union payloads. Inline storage at the origin did
  not guarantee cheaper storage at the sink.
- The managed source-union typed-payload pilot cut emitted C by 2.10% but
  changed retired instructions by only -0.04% (noise) and raised total
  allocations by 0.33%. A broader accessor pilot improved median
  instructions by just 0.1052%, below its 2% bar. See the
  [S2 outcome](../benchmarks/results/STRUCT_PAYLOAD_S2A_OUTCOME.md) and
  [follow-up probe](../benchmarks/results/struct_payload_managed_union_s2b_probe_2026-09-23.md).
- Typed dictionary storage for struct keys/values had no measured dynamic
  reach. Do not build it solely to preserve a source representation being
  retired. If an ABI-only value later makes it material, open a new issue
  with dynamic counts.

Stored tuple layout is independent and belongs to the
[value-tuple plan](VALUE_TUPLES_AND_STATE_HANDOFF.md). Landed typed
source-union payload storage and closure environments remain in the code;
this change in strategy does not undo them. Full prior design and stop
conditions are in Git history and `benchmarks/results/`.
