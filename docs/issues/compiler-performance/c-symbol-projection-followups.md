# Finish Internal C-Symbol Projection Safely

**Status:** Proposed; existing callable projection is in production.

**Current state:** Final Core-to-C projection gives artifact-local user and
closure bodies deterministic short C symbols and `static` linkage. Semantic
identities, diagnostics, dumps, and profile labels retain original names.
Types, constructors, globals, fields, and locals are intentionally unchanged.
The retained measurement is
[`compiler_c_symbol_projection_2026-08-23.md`](../../../benchmarks/results/compiler_c_symbol_projection_2026-08-23.md).

**Next action:** Replace the remaining string-only callable callback boundaries
with exact structured callable identity. Make a failing focused test for a
missing or ambiguous callback target, then remove the transitional unique-name
lookup. This is an identity cleanup, not a new hashing policy.

**Read first:** `blorp/src/compiler/stage_10_backend/c_symbol_projection.brp`,
`blorp/src/compiler/stage_10_backend/emit.brp`,
`blorp/test/compiler/stage_10_backend/test_c_symbol_projection.brp`, and the
final-Core variants for list-to-string and custom collection callbacks.
[Architecture](../../ARCHITECTURE.md#backend)
owns the current emission contract.

**Fast loop:** Run the focused projection tests and compare final Core plus
generated C for direct calls, closures, tasks, and both string-only callback
forms. Then run the codegen audit and relevant runtime/sanitizer gates.

**Decision:** Accept only if every final callable reference has an exact
inventoried target, collision and stale-identity failures remain explicit, and
generated C differs only in the intended internal-callable projection. Reject
name-shape inference, fallback-to-unprojected emission, or opaque profile and
diagnostic labels.

## Later Admission Gate

Do not hash aggregate types merely because their C spellings are long. First
classify complete C ABI exposure from declared ABI types, foreign function
parameters and returns, runtime bridges, and their transitive aliases, fields,
union payloads, variants, tags, constructors, and generated helpers. Verify the
classification with foreign headers that inspect nested records, unions, and
enums. Only then consider an atomic internal-type projection and measure its
incremental generated-C size, host-C cost, compiler latency, and memory.

Globals require a separate exact-reference inventory and benefit measurement.
Fields and locals remain out of scope unless a later census demonstrates a
material cost and supplies scope-aware identity. Keep semantic names available
throughout the compiler; do not make hashed spelling a package compatibility
contract.
