# Replace Node-Based `Set` Storage With An Ordered Flat Index

**Status:** Proposed representation change; not admitted without the
measurement and bootstrap proof below.

**Current state:** `Set[T]` uses a separately allocated node per element,
bucket chains, and insertion-order links in `blorp/src/lib/runtime/native/runtime.c`.
Compiler synthesis and direct `for` emission know that shape. Existing runtime
tests make insertion-order iteration part of the effective contract.

**Next action:** Write failing order, COW, and collision characterization tests;
then prove the two-generation bootstrap transition with one harmless temporary
Set layout marker before changing the production representation. Establish
the native-allocation baseline at small and large sizes.

**Read first:** `standard_library/src/set.brp`, `runtime.c`,
`runtime_decl.c`, `stage_09_core/synth_hash_collections.brp`,
`stage_10_backend/emit.brp`, `standard_library/test/set/`, and
`benchmarks/blorp/set_ops.brp`.

## Contract

The public `set`, `add`, `remove`, `contains`, algebra, and iteration APIs do
not change. Membership and equality remain hash/trait based, average O(1),
and independent of insertion order. Iteration order is observable:

```text
add A, B, C; add B       => A, B, C
remove B; add B again    => A, C, B
combine(left, right)     => left order, then new right members
intersect/difference     => survivors in left order
symmetric_difference     => left-only, then right-only
filter/fold              => input order; map keeps first mapped occurrence
```

Rehash, reserve, reuse, and COW may not change that order. An iterator over a
shared snapshot keeps the old sequence even when the source variable is
rebound to an updated Set. Randomized hash seeds must not leak table-slot
order into user-visible iteration.

Use an ordered flat hash index, **not** `Dict[T, Void]`: an open-addressed
control array (empty/deleted/H2 fingerprint), a slot-to-order index, dense
insertion-order key storage, and explicit live/deleted metadata for order
holes. Keep live size, order length/capacity, table capacity, tombstone count,
and hash/equality/release callbacks explicit. Empty new Sets allocate no
backing arrays; an empty reused Set may retain capacity. The exact initial
capacity/load policy is a named, measured implementation decision, not a
language ABI.

For every state, prove `size` equals occupied slots and live order positions;
each occupied slot maps to one live position; dead positions and tombstones
own no key; an empty/deleted slot has no valid order index; capacity is safe
for probing; and callback pointers survive COW/rebuild. Add a debug-only
invariant checker used by sanitizer fixtures, not release-time full scans.
Never infer liveness from a null key pointer: immediate `Int(0)` can be null.

## Ownership And Integration

- Shared updates copy backing storage and retain each **live managed** key
  exactly once; immediate keys have no per-key retain. Unique updates may
  reuse storage. Rebuild/compaction move keys without retain/release churn.
- Duplicate insertion preserves the original stored key and disposes of the
  candidate correctly. Removal/destruction release each live managed key
  exactly once. Iteration borrows keys.
- Preserve signed-zero, infinity, NaN, boxed `Int128`/`UInt128`, String,
  custom `Hashable`/`Equatable`, and constant-hash collision behavior as
  characterized by current tests.
- Migrate runtime declaration, synthesis, ownership contracts, reuse,
  intrinsic rendering, direct `for` emission, and prepared backend rendering
  atomically. Remove node-specific `blorp_SetEntry`, bucket/order-link
  accesses, and unused old intrinsics; do not leave a permanent dual ABI.
- Read generated C. It must scan order storage, skip holes, match the runtime
  struct declaration, and produce no new codegen-audit warning.

## Bootstrap Transition Gate

The pinned compiler still emits C using the old Set layout. Merely changing
`runtime_decl.c` makes the first self-host generation fail or accidentally use
a mixed ABI. Use a temporary directory outside the repository and record the
old revision and bootstrap hash:

1. Supply the pinned bootstrap with the **old** runtime declaration/object
   while it compiles changed compiler sources to generation 1. Embed the
   **new** runtime source text for programs generation 1 will produce.
2. Use generation 1 to emit generation-2 compiler C; it must contain only the
   flat Set shape. Build generation 2 against the new runtime.
3. Use generation 2 to emit generation 3; compare behavior and deterministic
   generated outputs. Run acceptance gates with homogeneous generation 2 or
   later. Never publish or pin mixed generation 1.

Before the migration, prove this sequence with a temporary field rename or
marker that distinguishes old generation-1 C from new generation-2 C. Remove
the marker. Follow the current build recipe for native flags and embedded
runtime text; do not overwrite the active worktree or maintain a compiler-
version compatibility switch. If an official transition tool exists by then,
it must enforce the same separation.

## Fast Feedback And Measurement

Start with the smallest focused Set runtime and generated-C fixture after each
coherent edit. Use `standard_library/test/set/`, the Set synthesis and emitter
suites under `blorp/test/compiler/`, the managed-key leak baseline, and
sanitizer builds before the broad runtime/compiler gates. Test duplicate,
remove/re-add, collision, tombstone reuse, growth, COW, unique reuse, and
iteration order with the invariant checker enabled.

Extend `benchmarks/blorp/set_ops.brp` and add a focused size matrix for build,
duplicate add, contains hit/miss, remove hit/miss, iteration, churn, algebra,
one shared COW update, and repeated unique updates. Include sizes 0, 1, 4,
8, 16, 64, 1,024, and 100,000 where semantically applicable; use Int,
String, and constant-hash custom keys. Construct keys and aliases outside
the timed operation. Report probes, hash/equality calls, holes, tombstones,
rebuilds, and a checksum so a latency win cannot hide a worse probe policy.

The ordinary managed-object counters miss native Set node/backing-array
`malloc` calls. Use a reviewed native allocator counter or platform profiler
for build and shared COW at 1,024 and 100,000 keys. The old build should show
O(N) node allocations; the new build/COW must not allocate per member.
Measure requested and retained bytes, native alloc/free calls, managed key
retains/releases, and elapsed time. Compare a matched compiler module-
visibility workload and full source-to-C self-compilation as guardrails;
exclude host C compilation from the compiler latency claim. Warm and
alternate clean baseline/candidate binaries, require equal outputs, and
retain raw paired results and provenance in `benchmarks/results/`.

## Acceptance And Stop Conditions

Accept only if public results and order match, all ownership/leak/sanitizer
and codegen gates pass, the two-generation build is proven, and actual native
allocation calls fall materially without an important hit/miss or small-Set
regression. Check the extra slot-to-order-to-key load, late-probe hits, H2
collisions, and COW at high tombstone pressure explicitly. Reject a candidate
that merely reduces requested bytes while raising peak memory, hash work,
or representative latency enough to erase the benefit. If the flat layout
does not win across realistic workloads, retain the current Set and record
the negative result rather than leaving a complex compatibility layer.
