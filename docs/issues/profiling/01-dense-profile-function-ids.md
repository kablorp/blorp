# Replace Name Registration With Dense Profile Function IDs

**Status:** Implemented

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
- Store each metadata string once rather than repeating an identity string at
  both probes, and measure the total profile-only generated-C size separately.
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
    logical_name: String,
    c_symbol: String,
    module_path: Option[String],
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

The metadata list position is the ID. IDs are dense indexes into `functions`:

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

## Implementation Result

Implemented on 2026-09-09 from parent `f3fbb5542641ff42fe50acd7683cdf4ffa70f656`.
The final backend builds one private profile plan from projected declaration
order. Only body-bearing user functions and the program entrypoint receive
dense IDs, matching the pre-change instrumentation boundary. Builtins, foreign
declarations, bodyless declarations, and closure bodies remain outside exact
profiling. Metadata list position is the sole ID authority; the plan does not
store a redundant ID field.

Generated artifacts now contain one immutable metadata table and numeric
`blorp_profile_start_id` / `blorp_profile_end_id` probes. The runtime allocates
exactly one counter entry per metadata row and indexes it directly. The old
fixed registry, TLS name cache, linear string comparison, registration mutex,
and string-keyed fallback were deleted. Reports retain both logical names and
compact C symbols so duplicate logical labels remain distinct.

The implementation also corrected an existing balancing defect: direct
returns inside lowered tail-recursive bodies previously received a start probe
without an end probe. The function emission context now carries only the
optional numeric function ID into that narrow return renderer. Closure and
global contexts carry `None`, so this does not expand profiling eligibility or
introduce managed-string traffic in non-profile emission.

The transitional diagnostics row reports:

```text
functions_described functions_observed calls_completed
invalid_start_ids invalid_end_ids unmatched_ends out_of_order_ends
metadata_initialization_failures stack_overflows
```

Each active frame retains its start epoch. This preserves the existing rule
that frames crossing a window boundary are discarded without falsely reporting
their later ends as unmatched. Starts that race a window boundary carry a
reserved suppressed epoch, so they cannot become measured frames if a new
window opens before the frame is pushed. The callable-header benchmark marker
ignores suppressed frames and continues to inspect the current measured
frame's logical metadata name; normal entry/exit performs no string lookup.

### Controlled Evidence

Raw logs are retained locally under ignored
`logs/profiling-issue-01/final-sentinel-measurement/`. The final production patch
SHA-256 relative to `f3fbb554` is
`53db1781ef91bf09f1c5d3a58b3988c1c647aa808e26213e09cc3da74830c10a`.
The compiler bootstrap was `dev-174983f4e9a9`
(`0.0.1-dev.174983f4e9a9`, Apple arm64 SHA-256
`4577f9e001903d91f7c7f7977856c7548dc279c1c174d6e3ed64dcaf2eb06da7`).
The host compiler was Apple Clang 21.0.0. All measured native and compiler
binaries used `-O2 -fwrapv -pipe -w`.

| Identity | SHA-256 |
| --- | --- |
| Parent build compiler from `f3fbb554` | `4f48e00801aa38cd47108f4c66e249903786a70ed99da124b6337bb1d22080c5` |
| Final candidate build compiler | `289cb9afd8a964de9291ba4c45bea64c25557d3dafb0f01da53cb4f8a9ccb229` |
| Parent optimized plain compiler | `6e02086fb3b3652999aecec18f7ebdbd81fdbc90617b38c0095d222d6b54f439` |
| Parent optimized profiled compiler | `cd7b94d9dc3ffdffe3567130b982bddeaea5d0eede044c478024bd06993a3a23` |
| Candidate optimized plain compiler | `dd59905781d4f28bd8e0f97d91fb093d1de40bef0e31b8699bb2f072c6146597` |
| Candidate optimized profiled compiler | `7344900c80e2109730cd305fe0b2df3b79b63cd54cd8651bd8e296a1ff66efcf` |

The final generated-C artifact sizes were:

| Profile-only C overhead | Parent | Candidate | Delta |
| --- | ---: | ---: | ---: |
| Bytes | 3,454,074 | 3,885,391 | +12.49% |
| Lines | 36,224 | 48,320 | +33.39% |

The candidate stores each descriptive string once, but its metadata rows also
carry the C symbol, optional module path, definition ID, and flags. That richer
identity inventory outweighed removal of the second probe-name literal, so the
aggregate profile-only C artifact grew. Non-profile artifacts contain neither
the table nor probes and remained byte-identical across the parent and
candidate compilers for the measured source and flags.

The parent cache-miss and registry-mutex acquisition counts requested by the
measurement plan were not captured: the retained parent executable exposes no
such counters, and no temporary instrumented parent artifact was retained.
The candidate source and generated C prove structurally that the registry,
cache, string lookup, and registry mutex are absent, but modeled or inferred
parent counts are not substituted for measured facts. That evidence item
therefore remains incomplete.

Each workload used one warmup followed by seven serial alternating runs.
`/usr/bin/time -l` supplied wall, RSS, retired-instruction, and cycle
measurements. Medians below include median absolute deviation and range.

The native control called one non-inlined empty leaf 1,000,000 times. Plain and
profiled variants used the same optimized runtime for their side. Internal
elapsed samples in milliseconds were:

```text
parent plain:      0.799 0.672 0.690 0.674 0.672 0.672 0.675
candidate plain:   0.798 0.672 0.672 0.673 0.684 0.672 0.672
parent exact:     40.955 39.225 38.848 38.779 38.713 39.044 39.176
candidate exact:  38.366 38.293 38.446 38.618 38.874 38.561 38.853
```

| Native metric | Parent exact median, MAD (range) | Candidate exact median, MAD (range) | Exact delta |
| --- | ---: | ---: | ---: |
| Internal elapsed ms | 39.044, 0.196 (38.713-40.955) | 38.561, 0.195 (38.293-38.874) | -1.24% |
| Retired instructions | 624,844,742, 57,123 (624,781,736-624,957,901) | 581,952,486, 32,903 (581,897,615-582,031,882) | -6.86% |
| Cycles | 177,217,253, 119,921 (176,804,959-177,950,902) | 176,592,511, 236,924 (176,341,655-176,866,574) | -0.35% |
| Peak RSS bytes | 1,753,088 | 1,818,624 | +3.74% |

The plain native medians were 0.674 ms for the parent and 0.672 ms for the
candidate. Exact overhead was 5,693% for the parent and 5,638% for the
candidate because clock reads and shared
atomics dominate a single-function leaf; Issue 4 owns local aggregation. The
dense route nevertheless retired 6.86% fewer instructions and did not regress
elapsed time.

The optimized compiler workload was exactly:

```bash
<compiler> compile --std-dir standard_library/src --no-format \
  --no-embed-runtime --time-phases -o <temporary-output> blorp/src/main.brp
```

Every one of the 28 measured invocations emitted byte-identical C with SHA-256
`944ad986818d2dd542ed3194c58e8e0e51012bdb6d0e8cfaea0930cc4a682899`.
Raw process-wall samples in seconds were:

```text
parent plain:      27.61 27.58 27.54 27.44 27.20 27.38 27.55
candidate plain:   27.22 27.15 27.55 27.22 27.41 27.28 27.38
parent exact:     480.73 480.63 481.38 482.12 482.27 483.91 482.35
candidate exact:   61.08  61.12  61.07  61.16  60.92  61.20  61.22
```

| Compiler metric | Parent exact median, MAD (range) | Candidate exact median, MAD (range) | Exact delta |
| --- | ---: | ---: | ---: |
| Process wall s | 482.12, 0.74 (480.63-483.91) | 61.12, 0.05 (60.92-61.22) | -87.32% |
| Phase total ms | 470,017.866, 771.145 (468,436.144-471,790.476) | 54,544.224, 61.435 (54,335.125-54,656.156) | -88.40% |
| Retired instructions | 8,637,514,249,007, 97,792,591 (8,637,416,456,416-8,638,089,423,242) | 911,654,493,391, 46,304,719 (911,492,070,018-911,774,814,776) | -89.45% |
| Cycles | 1,951,157,701,739, 2,501,411,028 (1,946,717,200,301-1,958,021,725,201) | 247,464,160,104, 257,556,985 (246,814,300,911-247,823,774,555) | -87.32% |
| Peak RSS bytes | 2,764,488,704, 49,152 (2,764,374,016-2,765,504,512) | 2,763,145,216, 131,072 (2,762,260,480-2,763,620,352) | -0.05% |

Plain compiler medians were 27.54 s parent and 27.28 s candidate (-0.94%),
with retired instructions differing by -0.01% and peak RSS by +0.01%.
Exact-profile process overhead relative to each plain binary fell from 1,651%
to 124%; phase-total overhead fell from 1,726% to 114%.

The final candidate described 12,084 functions, observed 7,247, and completed
962,939,075 balanced calls in every run. All invalid-ID, unmatched-end,
out-of-order-end, metadata-failure, and stack-overflow counters were zero. The
parent emitted over 12,000 string probes but its runtime could register only
1,024 entries. The exact comparison therefore favors the candidate despite it
recording substantially more functions; the native leaf is the
equivalent-logical-work control.

The concurrent Blorp profile-window fixture also passed with crossing functions
excluded and every loss/corruption counter zero. The generated 4,096-leaf
integration fixture described 4,167 functions, observed 4,164, and completed
4,164 calls with no loss. Its non-profile output remains byte-identical between
explicitly disabled and default emission.

### Remaining Limits

- Exact timing is still wall-inclusive and uses shared atomic counters; Issues
  3 and 4 own fiber-correct timing, self time, and local aggregation.
- `BLORP_PROFILE_MAX_STACK` remains intentionally until Issue 3, but every
  overflow is now explicit.
- The legacy one-frame `FLAME:` rows remain until Issue 4 replaces the output
  schema; they are not claimed as real stacks.
- Runtime counter storage uses one raw `calloc` plus one report snapshot
  allocation. These are visible in RSS/native allocation tools but are outside
  Blorp object-allocation counters.
- Closure-body profiling remains unchanged and out of scope.

## Acceptance Criteria

- [x] `BLORP_PROFILE_MAX_FUNCS` and the fixed `profile_entries` array are gone.
- [x] No replacement policy cap limits the number of described functions.
- [x] Generated probes carry numeric IDs and perform direct indexed lookup.
- [x] The name cache, registry mutex, linear string search, and name-keyed
      fallback are removed from production.
- [x] Every profile metadata row has unique artifact-local identity plus
      readable logical and C-symbol metadata.
- [x] The >1,024 integration fixture reports every called function.
- [x] Duplicate display names remain distinct.
- [x] Corrupt IDs and initialization failure are explicit diagnostics.
- [x] The retained fixed stack reports every overflow until Issue 3 removes the
      limit.
- [x] Non-profiled generated C is byte-identical to the parent for the same
      input and flags.
- [x] Profiled C stores each metadata string once and does not grow two repeated
      name literals per function.
- [x] Focused, CLI, runtime, leak, and quality owners pass.
- [x] Before/after profiler overhead and artifact-size evidence is retained in
      the change report.
- [ ] Exact parent cache-miss and registry-mutex acquisition counts were
      captured; the retained parent artifact did not expose them.

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
