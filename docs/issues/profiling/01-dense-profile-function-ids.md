# Replace Name Registration With Dense Profile Function IDs

**Status:** Ready for implementation

**Roadmap dependency:** None

**Unblocks:** Issues 2, 3, and 4

## Issue Summary

Delete the fixed-size, string-keyed function registry and assign each
instrumented emitted function a dense artifact-local numeric identity. Emit one
metadata row per selected function and pass only the numeric ID through hot
entry/exit probes.

This issue removes `BLORP_PROFILE_MAX_FUNCS` completely. It must not replace
1,024 with a larger arbitrary number, an environment-controlled ceiling, or a
dynamically growing string hash table.

## Current Behavior And Root Cause

`blorp/src/lib/runtime/native/runtime.c` currently declares:

```c
#define BLORP_PROFILE_MAX_FUNCS 1024
#define BLORP_PROFILE_TLS_CACHE 128

static blorp_ProfileEntry profile_entries[BLORP_PROFILE_MAX_FUNCS];
static BLORP_THREAD_LOCAL blorp_ProfileCacheEntry
    profile_cache[BLORP_PROFILE_TLS_CACHE];
```

`blorp_profile_start(const char *name)` hashes the string address into the
small cache. A miss acquires `profile_mutex`, then `blorp_profile_get_locked`
linearly compares the requested name with every registered name. Registration
returns `NULL` when the fixed table is full. The caller quietly skips the
frame, so the final report looks valid while omitting functions.

The backend emits the same string at both sites:

```c
blorp_profile_start("compiler_src_stage_05_types_env__scope_add_symbol");
/* body */
blorp_profile_end("compiler_src_stage_05_types_env__scope_add_symbol");
```

This design also makes display spelling an identity. Two distinct emitted
functions with the same display string merge into one entry.

The fixed table appears to have been an early allocation-avoidance
simplification: the implementation comment describes a linear search as good
enough for a small number of functions. Whole-compiler profiles are no longer
small.

## Goals

- Remove the 1,024-function ceiling and all other fixed function-count limits.
- Make hot function lookup O(1) array indexing.
- Remove string comparison, hashing, registration, and registry locking from
  entry/exit probes.
- Preserve a readable logical name for reports.
- Preserve compact emitted C symbols for native-profile joins.
- Keep two functions distinct even when their source/display names match.
- Emit deterministic IDs and metadata for a deterministic input artifact.
- Detect corrupt or out-of-range IDs explicitly.
- Reduce profile-only generated C by storing each metadata string once.
- Leave non-profiled C byte-identical to the current non-profiled route.

## Non-Goals

- Do not add sampling, call-count mode, selection flags, or a new top-level CLI.
- Do not add self time or change window semantics.
- Do not move counters to per-worker shards yet.
- Do not make IDs stable across compiler revisions or separate artifacts.
- Do not serialize `ModuleId` or other compiler-session IDs as durable profile
  identity without their descriptive metadata.
- Do not add a compatibility registry beside the dense route.
- Do not keep name-based fallback lookup for generated probes.

## Required Reading And Current Owners

| Responsibility | Location |
| --- | --- |
| Profile runtime and report | `blorp/src/lib/runtime/native/runtime.c` |
| Runtime declarations visible to generated C | `blorp/src/lib/runtime/native/runtime_decl.c` |
| Profile setup/start/end emission | `blorp/src/compiler/stage_10_backend/emit.brp` |
| C symbol projection and reverse display names | `blorp/src/compiler/stage_10_backend/c_symbol_projection.brp` |
| Backend profile tests | `blorp/test/compiler/stage_10_backend/test_core_emit.brp` |
| CLI generated-C and lifecycle tests | `blorp/test/cli/test_cli.sh` |
| Compact-symbol design constraints | `docs/C_SYMBOL_HASHING_ROADMAP.md` |

Read functions by name rather than assuming the line numbers in this issue
remain stable.

## Proposed Compiler Representation

Introduce a backend-owned profile plan after final C symbol projection and
before declaration rendering:

```blorp
struct ProfileFunctionId { value: Int }

struct ProfileFunctionMetadata {
    id: ProfileFunctionId,
    logical_name: String,
    c_symbol: String,
    module_path: String,
    definition_id: Int,
}

struct ProfileEmissionPlan {
    functions: List[ProfileFunctionMetadata],
}
```

Use the narrowest identity types already available in the backend. The sketch
does not require converting an existing `DefinitionId` or `ModuleId` to `Int`
if a stronger type is available. Generated helpers without a source definition
must use an explicit origin variant or documented sentinel-free optional field,
not a fabricated definition number.

IDs are dense indexes into `functions`:

```text
0 <= id < functions.length()
```

Choose IDs by the final deterministic emitted-function order. Do not iterate a
dictionary to assign them. The ID is meaningful only together with the emitted
artifact's metadata and build identity.

The plan includes only functions for which the emitter actually emits a body
and can place balanced probes. Unsupported, foreign-only, declaration-only, and
eliminated functions must not consume holes unless a later consumer requires
them in the symbol map. If the symbol-map issue needs a broader inventory, keep
the broader symbol inventory and selected profile-ID inventory as explicitly
different products.

## Proposed Generated C ABI

The exact spelling may follow runtime conventions, but the shape should be:

```c
typedef size_t blorp_ProfileFunctionId;

typedef struct {
    const char *logical_name;
    const char *c_symbol;
    const char *module_path;
    long definition_id;
    unsigned int metadata_flags;
} blorp_ProfileFunctionMetadata;

static const blorp_ProfileFunctionMetadata blorp_profile_functions[] = {
    {"scope_add_symbol", "brp_3i9", "compiler/stage_05_types/env", 418, 0},
    /* ... */
};

blorp_profile_enable(
    blorp_profile_functions,
    sizeof(blorp_profile_functions) / sizeof(blorp_profile_functions[0]));
```

Functions then contain numeric probes:

```c
blorp_profile_start_id(137);
/* body */
blorp_profile_end_id(137);
```

Use `size_t` or another representation whose maximum follows the artifact and
address space rather than a profiler policy constant. The generated metadata
array itself proves the valid count. If a narrower ABI is chosen for C size,
the emitter must reject an unrepresentable artifact with a named diagnostic;
that would be a representation bound, not silent truncation.

The runtime allocates exactly `function_count` counter entries during enable.
Allocation failure may use the runtime's accepted infrastructure-OOM behavior,
or may disable profiling after a clear diagnostic and nonzero profiler failure
status. It may not silently produce a partial profile.

Preserve the current ordering of global initialization and profile enablement in
this issue. Moving enablement before `__blorp_init_globals()` would change
whether global initialization is measured and belongs in a separately reviewed
semantics change.

## Runtime Changes

Delete:

- `BLORP_PROFILE_MAX_FUNCS`;
- `BLORP_PROFILE_TLS_CACHE`;
- `profile_count` as a registration cursor;
- `profile_mutex` when it has no remaining owner;
- `blorp_ProfileCacheEntry` and `profile_cache`;
- `blorp_profile_get_locked`;
- `blorp_profile_lookup_cached`; and
- all name matching on the normal entry/exit path.

Retain the current atomic counters initially so the issue does not combine ID
correctness with sharding. Entry validates `id < profile_function_count`, takes
the entry address directly, and pushes the ID or entry pointer. Normal exit
expects the top frame to carry the same ID. If tolerant unwind behavior is
still required, compare numeric IDs in the slow mismatch path and report that
the path was used.

Add explicit diagnostic counters:

```text
invalid_start_ids
invalid_end_ids
unmatched_ends
metadata_initialization_failures
functions_described
functions_observed
stack_overflows
```

Issue 3 replaces the fixed profile stack with dynamic fiber-owned storage. Until
then, Issue 1 must detect `profile_stack_depth >= BLORP_PROFILE_MAX_STACK`,
increment `stack_overflows`, and include it in a parseable transitional report.
Removing the function limit while continuing to hide a separate frame loss
would violate the roadmap's completeness contract.

An invalid generated ID indicates compiler/runtime ABI corruption. Focused
native tests should be able to call the ABI incorrectly and confirm the runtime
fails visibly without out-of-bounds access.

## Implementation Steps

1. Add a failing backend fixture that emits more than 1,024 callable bodies and
   proves the profile plan contains all of them.
2. Add focused native runtime coverage for metadata initialization and numeric
   start/end lookup.
3. Define the profile ID and metadata types in the backend.
4. Build the deterministic plan from the final projected program.
5. Thread the plan or per-function ID into only the top-level function renderer.
   Do not thread metadata through expression rendering.
6. Emit one metadata table and change generated probes to numeric IDs.
7. Update the runtime declaration ABI and runtime storage.
8. Delete the string registry and cache in the same production cutover.
9. Add explicit overflow accounting to the retained fixed stack.
10. Update current emitter, codegen-audit, and CLI expectations from string probes
   to numeric probes plus metadata rows.
11. Inspect a compiler-sized profiled C artifact and count metadata rows, start
    probes, end probes, and distinct IDs.
12. Measure small and whole-compiler profiler overhead against the immediate
    parent.

## Tests

### Backend tests

Cover:

- zero selected functions;
- one function with ID zero;
- more than 1,024 functions;
- deterministic IDs across repeated emission;
- stable IDs when unrelated dictionary insertion order changes;
- distinct functions sharing one logical display name;
- escaped quotes, tabs, newlines, and non-ASCII bytes in metadata;
- declaration-only and unsupported functions do not produce callable probes;
- entry and every normal return path use the same ID; and
- non-profiled emission contains no table or probes.

Avoid a fixture with 1,025 hand-written declarations. Construct the bounded
Core program using existing test helpers, but assert exact counts and selected
IDs rather than a vague substring.

### Native runtime tests

Cover:

- an ID at the first and last valid index;
- an out-of-range start and end;
- repeated and recursive calls to one ID;
- two metadata rows with the same logical name;
- an allocation/initialization failure seam if the runtime provides one; and
- report diagnostics and cleanup after enable with a large metadata count.

Use sanitizers for the invalid-ID cases.

### Integration tests

Compile and run a generated profile with at least 4,096 called functions. Parse
the structured or transitional text output and prove:

```text
functions_described == 4096 or greater
functions_observed == expected called functions
invalid_start_ids == 0
invalid_end_ids == 0
unmatched_ends == 0
```

The fixture should give each function a deterministic observable contribution
so dead-code elimination cannot make the asserted inventory accidental.

## Fast Feedback Loop

```bash
# Focused emission ownership
bin/blorp test blorp/test/compiler/stage_10_backend/test_core_emit.brp

# Generated-C and lifecycle behavior
blorp/test/cli/test_cli.sh --smoke --timeout 30

# Backend/static quality after the ABI stabilizes
make quality
```

During iteration, emit one tiny profiled C file and verify with `rg` that it has
one metadata spelling per function and numeric probes. Then run the >1,024
fixture. Do not self-compile the compiler after every renderer edit.

Before review:

```bash
make
scripts/test compiler-blorp runtime cli
scripts/test leak
make quality
```

Run the shared alternating measurement protocol only after these pass.

## Performance Evidence

Record separately:

- unprofiled optimized wall time;
- current-parent exact-profile wall time;
- candidate exact-profile wall time;
- calls completed;
- registry/cache misses and mutex acquisitions in the parent, measured with a
  temporary test-owned counter;
- invalid/lost diagnostics in the candidate; and
- profiled generated-C bytes and lines.

The structural result must be zero runtime string lookups and zero registration
mutex acquisitions. The candidate must not regress the small-profile median,
and must materially improve a compiler-sized exact profile whose function
inventory exceeds the old cap. If wall time is noisy, retired instructions and
the eliminated lookup/lock counts are the primary evidence.

## Acceptance Criteria

- [ ] `BLORP_PROFILE_MAX_FUNCS` and the fixed `profile_entries` array are gone.
- [ ] No replacement policy cap limits the number of described functions.
- [ ] Generated probes carry numeric IDs and perform direct indexed lookup.
- [ ] The name cache, registry mutex, linear string search, and name-keyed
      fallback are removed from production.
- [ ] Every profile metadata row has unique artifact-local identity plus
      readable logical and C-symbol metadata.
- [ ] The >1,024 integration fixture reports every called function.
- [ ] Duplicate display names remain distinct.
- [ ] Corrupt IDs and initialization failure are explicit diagnostics.
- [ ] The retained fixed stack reports every overflow until Issue 3 removes the
      limit.
- [ ] Non-profiled generated C is byte-identical to the parent for the same
      input and flags.
- [ ] Profiled C stores each metadata string once and does not grow two repeated
      name literals per function.
- [ ] Focused, CLI, runtime, leak, and quality owners pass.
- [ ] Before/after profiler overhead and artifact-size evidence is retained in
      the change report.

## Pitfalls And Review Questions

- Did a dictionary accidentally become the ID-order authority?
- Are eliminated or unsupported declarations assigned IDs that never appear?
- Does an entrypoint probe run before the metadata table is initialized?
- Did the change silently alter whether global initialization is measured?
- Can a `definition_id` from one module collide with another because the module
  owner was dropped from metadata?
- Are names escaped exactly once as C data, rather than reconstructed from
  compact symbols at runtime?
- Did a compatibility string route survive and leave two profiler systems?
- Does the report sort a snapshot without mutating the ID-indexed counter
  array?
- Is allocation proportional to described functions, rather than to an
  arbitrary maximum?

This issue is complete only when the old registry is deleted, not when a dense
table exists beside it.
