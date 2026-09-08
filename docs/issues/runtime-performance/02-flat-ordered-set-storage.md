# Replace Node-Based `Set` Storage With An Ordered Flat Hash Index

## Issue Summary

Replace the current separately chained, per-element-allocated `Set[T]`
representation with flat storage while preserving Blorp's existing value
semantics, insertion-order iteration, average O(1) membership/insertion/removal,
custom `Hashable` and `Equatable` dispatch, and ARC/COW behavior.

The target representation is an **ordered flat hash index**:

- an open-addressed control array stores empty/deleted/H2 fingerprint state;
- a parallel array maps each occupied hash slot to an insertion-order position;
- a dense insertion-order key array stores keys, with explicit live/deleted
  metadata for holes; and
- COW copies duplicate a small number of arrays rather than allocating and
  rehashing one linked node per element.

This is deliberately not `Dict[T, Void]`. Reusing `Dict` as the public runtime
representation would retain an unused value array and would couple Set's ABI,
ownership, and iteration behavior to map-only concerns. The implementation may
share neutral hash-control helpers with `Dict`, but `Set` remains a distinct
runtime type.

The public source API does not change:

```blorp
pure func set[T]() -> Set[T]
pure func add[T](self: Set[T], elem: T) -> Set[T]
pure func remove[T](self: Set[T], elem: T) -> Set[T]
pure func contains[T](self: Set[T], elem: T) -> Bool
```

## Why This Matters

The current runtime stores every set member in an independently allocated
node:

```c
typedef struct blorp_SetEntry {
    void *key;
    struct blorp_SetEntry *next;
    struct blorp_SetEntry *prev_order;
    struct blorp_SetEntry *next_order;
} blorp_SetEntry;

typedef struct {
    blorp_Object header;
    long size;
    long capacity;
    long mask;
    blorp_SetEntry **buckets;
    blorp_SetEntry *first;
    blorp_SetEntry *last;
    unsigned long (*hash_fn)(void *);
    bool (*eq_fn)(void *, void *);
    void (*key_release)(void *);
} blorp_Set;
```

On a 64-bit target, each live member therefore carries 32 explicit bytes of
node storage before allocator metadata and fragmentation. The bucket array
adds another `8 * capacity` bytes. At the current 37.5%-75% occupancy range,
the explicit table scaffolding is approximately 43-53 bytes per live member,
excluding the `blorp_Set` header, allocator overhead, and the key object itself.

The layout has costs beyond retained bytes:

1. Building an N-member set performs N small native allocations.
2. Destroying it performs N independent native frees.
3. Membership follows bucket-chain pointers with weak cache locality.
4. Iteration follows a second linked structure through `next_order`.
5. Resizing rehashes keys while traversing scattered nodes.
6. A COW copy allocates N new nodes, hashes all N keys again, reconstructs both
   link structures, and retains every managed key.
7. The node allocation and pointer manipulation is reproduced in synthesized
   Core, increasing implementation surface and generated-C complexity.

The COW path is the strongest reason to do this work. The current
`blorp_set_copy` cannot bulk-copy the table: it must allocate and rebuild every
entry. Flat storage changes a shared-set update from N native node allocations
plus N hash calls to a bounded number of backing-array allocations, bulk
copies, and only the ARC retains that managed keys genuinely require.

For non-owning immediate key layouts, such as the ordinary machine-sized
integer and Boolean representations, a COW copy should contain no per-key ARC
work at all. Do not infer this from the source-level label "primitive": wide
integers such as `Int128` and `UInt128` currently use boxed layouts and require
the same retain/release care as other managed keys.

## External Design Context

The design is informed by several production families:

- [Abseil Swiss tables](https://abseil.io/about/design/swisstables) and
  [Rust hashbrown](https://github.com/rust-lang/hashbrown) use open addressing,
  one-byte control metadata, H2 fingerprints, and group-friendly probing. They
  are the appropriate model for hash-index locality, but their ordinary Set
  variants do not promise insertion order.
- [Swift OrderedSet](https://github.com/apple/swift-collections/blob/main/Sources/OrderedCollections/OrderedSet/OrderedSet.swift)
  and [Rust IndexSet](https://github.com/indexmap-rs/indexmap) store ordered
  elements separately from a hash table containing element indices. This is
  the closest production model for Blorp's ordered iteration and COW semantics.
- [.NET HashSet](https://github.com/dotnet/runtime/blob/main/src/libraries/System.Private.CoreLib/src/System/Collections/Generic/HashSet.cs)
  replaces per-element allocations with bucket and entry arrays while retaining
  index-based chaining. It demonstrates the value of flattening allocations,
  but open addressing is a better match for Blorp's existing Dict machinery.
- [CPython set](https://github.com/python/cpython/blob/main/Objects/setobject.c)
  combines nearby linear probes with dispersed probes and explicitly rebuilds
  to purge deletion markers. Its deletion behavior reinforces that tombstone
  accounting must be part of the representation, not an afterthought.

Do not import any implementation wholesale. Blorp has different constraints:
keys are erased into `void *`, `Int(0)` is represented by a null pointer, keys
may be ARC-managed, collection values are COW, and insertion order is already
observable in tests.

## Goals

- Eliminate `blorp_SetEntry` and all per-member Set node allocations.
- Preserve existing source behavior and insertion order.
- Preserve average O(1) membership, insertion, and removal.
- Preserve direct, zero-materialization `for element in set` iteration.
- Preserve COW snapshot behavior when a set is shared or reassigned during
  iteration.
- Make Set copies use bulk array copies rather than rehashing every member.
- Retain and release every managed key exactly once per owning set.
- Preserve immediate, float, String, enum, and user-defined key dispatch.
- Handle tombstones and order holes with explicit, testable invariants.
- Avoid allocating backing arrays for a freshly constructed empty Set. A Set
  emptied through reuse may retain already-initialized capacity.
- Reduce memory and native allocation traffic for representative nontrivial
  sets without regressing common operations materially.

## Non-Goals

- Do not change the public Set API or equality semantics.
- Do not implement `Set` as `Dict[T, Void]`.
- Do not remove insertion-order behavior.
- Do not change Dict's storage algorithm as part of this issue.
- Do not add HAMTs, tree sets, bitsets, sorted sets, or a generic collection
  framework.
- Do not add SIMD probing in the first implementation. Keep metadata suitable
  for group probing, but establish correctness and scalar performance first.
- Do not change the hash algorithm or random seeding policy.
- Do not introduce 32-bit table indices in the first implementation. Use
  `long`, matching existing container sizes, and treat compact indices as a
  separately measured follow-up.
- Do not optimize duplicate insertion on a shared Set by moving lookup ahead of
  COW in this issue. Preserve the existing evaluation/ownership shape first.
- Do not combine this work with Set API additions such as public
  `with_capacity`.

## Existing Behavior Is The Contract

Although `standard_library/src/set.brp` currently describes Set only as an
immutable hash set, runtime tests already pin insertion-order iteration. Treat
that behavior as authoritative and document it in the same change.

The required ordering rules are:

```text
add new A, add new B, add new C  => iterate A, B, C
add existing B                  => order remains A, B, C
remove B                        => iterate A, C
add B again                     => iterate A, C, B
rehash or COW                   => order does not change
```

Set equality remains mathematical Set equality and must ignore insertion
order.

The synthesized collection operations currently derive deterministic result
order from their ordered input walks. Pin these rules rather than merely
preserving whichever order a hash-table scan happens to produce:

```text
combine(left, right)       left order, then previously absent right members
intersect(left, right)     surviving members in left order
difference(left, right)    surviving members in left order
symmetric_difference       left-only order, then right-only order
filter(set, predicate)     surviving members in input order
map(set, mapper)           first mapped occurrence in input order
fold(set, initial, folder) callback visits members in input order
```

These rules follow the current synthesized walkers. They are especially
important because the runtime hash seed is randomized, so table-slot iteration
would otherwise make observable output vary between processes.

The following COW example must continue to iterate the original snapshot:

```blorp
var values: Set[Int] = set().add(1).add(2).add(3)
var total: Int = 0

for value in values:
	total += value
	values = values.add(value + 100)

-- The loop saw the original 1, 2, 3 snapshot.
total == 6 and values.length() == 6
```

## Current Implementation Map

Read these files before editing. Locate declarations by name rather than by
line number because the compiler is actively changing.

| Responsibility | Current location |
| --- | --- |
| Public Set API and representation comments | `standard_library/src/set.brp` |
| Public Set guide | `docs/GUIDE.md`, `Sets` section |
| Runtime Set and Dict layouts | `blorp/src/lib/runtime/native/runtime.c` |
| Generated-C runtime declarations | `blorp/src/lib/runtime/native/runtime_decl.c` |
| Set construction, copy, COW, resize, reserve, and destruction | `blorp/src/lib/runtime/native/runtime.c`, `blorp_set_*` |
| Hash seed, primitive hash/equality, H2 encoding | `blorp/src/lib/runtime/native/runtime.c`, current Dict support immediately before Set |
| Synthesized Set/Dict Core operations | `blorp/src/compiler/stage_09_core/synth_hash_collections.brp` |
| Intrinsic ownership contracts | `blorp/src/compiler/stage_09_core/ownership.brp` |
| Reuse recognition | `blorp/src/compiler/stage_09_core/reuse.brp` |
| Intrinsic registry and C spelling | `blorp/src/compiler/stage_10_backend/intrinsic_renderer.brp` |
| Direct Set `for` emission | `blorp/src/compiler/stage_10_backend/emit.brp`, `emit_for_set` |
| Prepared Set iteration C fragments | `blorp/src/compiler/stage_10_backend/prepared_backend_renderer.brp` |
| Core Set synthesis tests | `blorp/test/compiler/stage_09_core/test_core_synth_hash_collections.brp` |
| Ownership tests | `blorp/test/compiler/stage_09_core/test_core_ownership.brp` |
| Intrinsic rendering tests | `blorp/test/compiler/stage_10_backend/test_codegen_intrinsic_renderer.brp` |
| Prepared backend rendering tests | `blorp/test/compiler/stage_10_backend/test_codegen_prepared_backend_renderer.brp` |
| Complete C emission tests | `blorp/test/compiler/stage_10_backend/test_core_emit.brp` |
| Runtime Set tests | `standard_library/test/set/` |
| Managed-key leak baseline | `blorp/test/runtime/memory/leak_check_baselines/set_string_storage.brp` |
| Existing throughput benchmark | `benchmarks/blorp/set_ops.brp` |
| Compiler workload using Set heavily | `blorp/benchmark/compiler/compiler_module_visibility_profile_fixture.brp` |

Search for all old representation dependencies before starting:

```bash
rg --no-ignore -n \
  -e 'blorp_SetEntry|set_entry_|set_first|set_last' \
  -e 'set_bucket|set_set_bucket|set_resize|blorp_set_resize_to' \
  -e 'set_alloc|blorp_set_alloc|blorp_set_add|blorp_set_remove' \
  blorp standard_library
```

Classify every result before editing. Some names are node-specific and must
disappear; the allocation and direct add/remove names require the explicit
decisions below. After the migration, no node-specific occurrence should
survive except an intentionally historical statement in this issue or a test
explicitly asserting that the old shape is absent.

## Required Runtime Representation

Use this logical representation. Field ordering may be adjusted for C padding,
but the states and invariants must remain explicit.

```c
#define BLORP_SET_CTRL_EMPTY   UINT8_C(0xFF)
#define BLORP_SET_CTRL_DELETED UINT8_C(0x80)

#define BLORP_SET_INITIAL_TABLE_CAPACITY 8L
#define BLORP_SET_INITIAL_ORDER_CAPACITY 4L
#define BLORP_SET_LOAD_NUMERATOR 7L
#define BLORP_SET_LOAD_DENOMINATOR 10L

typedef struct {
    blorp_Object header;

    long size;              // live keys
    long order_len;         // initialized order positions, including holes
    long order_capacity;
    long table_capacity;    // zero only when no backing table is allocated
    long tombstones;

    uint8_t *ctrl;          // [table_capacity]
    long *slot_to_order;    // [table_capacity], meaningful only when occupied
    void **order_keys;      // [order_capacity]
    uint8_t *order_live;    // [order_capacity], exactly 0 or 1

    unsigned long (*hash_fn)(void *);
    bool (*eq_fn)(void *, void *);
    void (*key_release)(void *);
} blorp_Set;
```

`mask` and `grow_at` may either remain cached fields or be calculated from
`table_capacity`; follow measured local precedent. Do not encode tombstone
count, order length, or live-order state implicitly in unrelated fields.

The initial capacities above are named design parameters, not ABI. They keep
the first flat allocation proportionate for small sets. If measurement shows a
different value is clearly superior across the required size matrix, change
the named constants and retain the evidence with the implementation.

### Why Keys Live In Order Storage

A simpler Dict-like Set would use:

```text
keys[table_capacity]
ctrl[table_capacity]
order[table_capacity]
order_index[table_capacity]
```

That is easy to derive from Dict, but it spends approximately 25 bytes per hash
slot with 64-bit indices. Instead, the proposed table stores only metadata and
an order index:

```text
ctrl[table_capacity]
slot_to_order[table_capacity]
order_keys[order_capacity]
order_live[order_capacity]
```

At 70% table occupancy with order storage close to live size, this is roughly
22 bytes of explicit backing storage per live member with 64-bit indices. The
power-of-two boundary matters: at N=100,000, a 262,144-slot table plus a
131,072-position order allocation is about 35.4 requested bytes per live key,
versus roughly 53 requested bytes for the current nodes and bucket array--about
a 33% reduction before allocator metadata. With order holes and geometric
spare capacity, transient bytes can be higher still. The likely practical gain
is larger than requested-byte arithmetic suggests because N independent node
allocations disappear, but the issue must not promise a fixed 35%-50% range.

These values are design estimates, not acceptance evidence. The implementation
must measure actual native allocation counts, retained bytes/RSS, and elapsed
time.

## Representation Invariants

Add a debug-only invariant checker or extend an existing runtime invariant
facility so these facts can be asserted in focused tests:

1. `0 <= size <= order_len <= order_capacity`.
2. `table_capacity == 0` means all four backing pointers are null,
   `size == 0`, `order_len == 0`, and `tombstones == 0`.
3. A nonzero table capacity is a power of two and has at least one empty slot.
4. Every control byte is empty, deleted, or an occupied 7-bit H2 fingerprint.
5. Each occupied table slot maps to an order position in
   `[0, order_len)` whose `order_live` byte is 1.
6. Every empty or deleted table slot has `slot_to_order[slot] == -1`. Initialize
   the complete mapping array rather than leaving inactive entries undefined.
7. Every live order position is referenced by exactly one occupied table slot.
8. Every order position outside `[0, order_len)` is initialized as not live;
   its key storage is either null or otherwise never read.
9. `size` equals both the number of occupied table slots and the number of live
   order positions.
10. `tombstones` equals the number of deleted control bytes.
11. Empty or deleted table slots do not own keys.
12. A dead order position does not own a key. Set `order_keys[position]` to
    null after releasing it as a defensive aid, but never use nullness to
    determine liveness because `Int(0)` is represented by null.
13. The order positions reached from occupied slots contain keys whose hashes
    and H2 bytes agree with the table slot.
14. Hash/equality/release function pointers survive COW, reserve, rebuild,
    reuse, and resize unchanged.

Run this checker after construction, insertion, removal, COW copy, rebuild,
reserve, and reuse when a named build guard such as
`BLORP_RUNTIME_DEBUG_INVARIANTS` is enabled. Sanitizer test builds should enable
that guard. Ordinary release builds must compile the calls away; an accidental
full-table invariant scan or key rehash in production would invalidate the
performance results.

## Required Algorithms

The examples below are pseudocode. Use the repository's checked allocation and
overflow helpers and exact C naming conventions.

### H2 Encoding And Probing

Use the same logical encoding as Dict:

```text
0xFF       empty; an unsuccessful lookup may stop
0x80       deleted; lookup continues and insertion may reuse the slot
0x00-0x7F occupied; value is the H2 fingerprint
```

The current Dict code describes group-of-16 probing but its production lookup
still advances one control byte at a time. The first Set implementation should
use scalar linear probing as well. This isolates the storage migration from a
SIMD algorithm change and still gains locality and fingerprint filtering.

```c
typedef struct {
    long found_slot;
    long insertion_slot;
} blorp_SetProbe;

static blorp_SetProbe blorp_set_probe(
    blorp_Set *set,
    void *key,
    unsigned long hash
) {
    if (set->table_capacity == 0) {
        return (blorp_SetProbe){-1, -1};
    }

    uint8_t h2 = blorp_hash_h2(hash);
    long slot = (long)(hash & (unsigned long)(set->table_capacity - 1));
    long first_deleted = -1;

    for (long probes = 0; probes <= set->table_capacity; probes++) {
        uint8_t metadata = set->ctrl[slot];

        if (metadata == h2) {
            long order_position = set->slot_to_order[slot];
            void *stored = set->order_keys[order_position];
            if (set->eq_fn(stored, key)) {
                return (blorp_SetProbe){slot, -1};
            }
        } else if (metadata == BLORP_SET_CTRL_EMPTY) {
            long insertion = first_deleted >= 0 ? first_deleted : slot;
            return (blorp_SetProbe){-1, insertion};
        } else if (
            metadata == BLORP_SET_CTRL_DELETED && first_deleted < 0
        ) {
            first_deleted = slot;
        }

        slot = (slot + 1) & (set->table_capacity - 1);
    }

    return (blorp_SetProbe){-1, first_deleted};
}
```

Every query path must treat `table_capacity == 0` as an immediate miss without
reading `ctrl` or `slot_to_order`. This includes public `contains` and
`remove`, plus internal probes used by equality, subset/superset, algebra, and
duplicate detection. An insertion must allocate its initial backing arrays
*before* calling this probe; the `{-1, -1}` empty result is not an insertion
slot. Keep those two contracts explicit rather than relying on callers to
avoid empty Sets accidentally.

Production Set equality for custom key types is synthesized in Core so it can
use the exact monomorphic equality implementation rather than only a runtime
function pointer. Preserve that capability: port the existing synthesized
probe structure to the new control/index/order intrinsics. The C pseudocode
defines semantics and supports runtime-only helpers; it does not authorize
routing every operation through an indirect runtime comparator.

`blorp_hash_h2` is a proposed shared name, not a function that exists today.
The current implementation calls the equivalent helper `blorp_dict_h2`.
Extract/rename it as a neutral hash-table helper and update Dict's call sites,
or deliberately retain the current spelling for both collections. Do not add
two subtly different H2 encoders.

### Empty Allocation

`blorp_set_new*` must allocate only the Set header. Backing storage is created
on the first insertion or an explicit internal reserve:

```c
set->size = 0;
set->order_len = 0;
set->order_capacity = 0;
set->table_capacity = 0;
set->tombstones = 0;
set->ctrl = NULL;
set->slot_to_order = NULL;
set->order_keys = NULL;
set->order_live = NULL;
```

Do not point empty mutable sets at a shared writable singleton allocation.

### Insertion

Preserve the current high-level ownership order:

1. Evaluate and erase the input key exactly once.
2. Obtain a unique Set through `set_cow`.
3. Hash the key once and save the full hash.
4. If the table is empty, allocate initial backing before probing. Otherwise,
   probe immediately. If the key is already present, return without preparing
   capacity; a duplicate add must not trigger an avoidable O(N) compaction.
5. For an absent key, determine whether the selected slot is empty or deleted
   and whether the order array can append. Inserting into an empty slot raises
   `size + tombstones` pressure by one; reusing a tombstone does not.
6. Prepare capacity only when required. If `order_len == order_capacity`,
   compact when holes justify it and otherwise grow geometrically. Grow or
   tombstone-rebuild the table only when the applicable pressure threshold
   requires it.
7. If preparation rebuilt either array, re-probe using the saved full hash.
   Never use a slot or order position computed before a rebuild.
8. Commit the insertion through one atomic helper. It retains the key for Set
   ownership exactly once if the layout is managed, appends it at `order_len`,
   marks it live, maps the table slot to that position, writes H2 metadata,
   updates `size`/`order_len`, and decrements `tombstones` only when the chosen
   slot was deleted.

The table must never be allowed to contain no empty slot. Capacity preparation
must guarantee room before the commit. Keep duplicate lookup ahead of
preparation for an already allocated table; otherwise duplicate-heavy workloads
can inherit rebuild cost despite making no semantic change.

### Removal

Removal must remain average O(1) and must not shift all later order positions:

```c
static void blorp_set_remove_occupied_slot(blorp_Set *set, long slot) {
    long position = set->slot_to_order[slot];
    void *key = set->order_keys[position];

    if (set->key_release && key) {
        set->key_release(key);
    }

    set->order_keys[position] = NULL;
    set->order_live[position] = 0;
    set->ctrl[slot] = BLORP_SET_CTRL_DELETED;
    set->slot_to_order[slot] = -1;
    set->size--;
    set->tombstones++;
}
```

Use `order_live`, not `key != NULL`, because `Set[Int]` must store zero.

Do not automatically shrink on every remove. Rebuild when named tombstone or
order-hole pressure thresholds are crossed, or defer cleanup to the next
mutation if lookup degradation remains bounded and tested. Required behavior:

- a delete-heavy workload cannot leave an indefinitely probe-degraded table;
- a churn workload cannot grow `order_len` without bound while `size` remains
  small; and
- cleanup is amortized rather than performed after every deletion.

A reasonable initial policy is to rebuild when either tombstones exceed one
quarter of table capacity or order holes exceed live order positions. Give
these fractions names and validate them with the benchmark matrix. They are
policy inputs, not hidden literals.

### Rebuild And Compaction

One internal operation should own rehashing and order compaction. It must:

1. choose checked power-of-two table and order capacities;
2. allocate fresh arrays before releasing old arrays;
3. walk old order positions from oldest to newest;
4. copy only live keys into consecutive new order positions;
5. recompute hashes and rebuild table metadata/index mappings;
6. preserve key ownership without retain/release churn when moving storage
   within one unique Set;
7. publish all new fields only when construction has completed; and
8. free the old arrays exactly once.

An order compaction should choose a checked geometric `order_capacity` near the
live size instead of preserving arbitrarily large hole-driven capacity. A
tombstone-only table rebuild should normally retain `table_capacity`; shrinking
it at the same time can create shrink/grow oscillation around the load
threshold. Any different policy requires churn measurements that demonstrate
bounded memory and no oscillation.

Rebuild preserves insertion order. It is ownership-neutral for keys: moving a
pointer from old backing storage to new backing storage within the same Set is
not acquisition of a second owner.

### COW Copy

Copy must not call the rebuild path and must not hash keys. The process hash
seed and hash/equality functions are unchanged, so the table layout is valid in
the copy.

```c
static blorp_Set *blorp_set_copy(const blorp_Set *source) {
    blorp_Set *copy = blorp_set_alloc_header_like(source);

    if (source->table_capacity == 0) {
        return copy;
    }

    blorp_set_alloc_backing_like(copy, source);

    memcpy(copy->ctrl, source->ctrl, source->table_capacity);
    memcpy(
        copy->slot_to_order,
        source->slot_to_order,
        source->table_capacity * sizeof(long)
    );
    memcpy(
        copy->order_keys,
        source->order_keys,
        source->order_len * sizeof(void *)
    );
    memcpy(
        copy->order_live,
        source->order_live,
        source->order_len
    );

    if (copy->key_release) {
        for (long position = 0; position < copy->order_len; position++) {
            if (copy->order_live[position] && copy->order_keys[position]) {
                blorp_retain(copy->order_keys[position]);
            }
        }
    }

    return copy;
}
```

The empty-copy branch is required: do not call `memcpy`, even with a zero byte
count, using null source or destination pointers. The allocated header must
already carry the source's hash/equality/release functions and the canonical
zero/null backing state before this return.

`blorp_set_alloc_header_like` must copy `size`, `order_len`, both capacities,
the tombstone count, and all hash/equality/release functions while initially
leaving backing pointers null. The backing allocation must initialize the full
control/mapping arrays and initialize unused order liveness/key positions as
dead/null. The pseudocode then copies only the initialized `order_len` prefix
of keys and liveness. Do not copy indeterminate pointer/index bytes and later
expose them to diagnostics, sanitizers, or a mistaken inactive-slot read.

The null check before retaining is valid because managed Blorp objects are
never represented by null. Liveness must still come from `order_live`.

### Destruction

Destroy by scanning order storage once:

```c
for (long position = 0; position < set->order_len; position++) {
    if (!set->order_live[position]) continue;
    void *key = set->order_keys[position];
    if (set->key_release && key) set->key_release(key);
}

free(set->ctrl);
free(set->slot_to_order);
free(set->order_keys);
free(set->order_live);
```

There must be no per-member native `free`.

### Iteration

Generated C should use an integer order position and skip holes:

```c
for (long position = 0; position < set->order_len; position++) {
    if (!set->order_live[position]) continue;
    void *raw_key = set->order_keys[position];
    /* existing borrowed unboxing and loop body */
}
```

Keep the existing retain/cleanup ownership around the iterable. The loop must
borrow keys from that retained Set; it must not retain/release each key merely
to iterate.

### Reserve And Reuse

`blorp_set_reserve_for_len` and `blorp_set_reuse_alloc` are used by synthesized
set algebra and must be migrated rather than removed.

- Define the second argument of `set_reuse_alloc` and
  `set_reserve_for_len` consistently as an **expected live member count**, not
  raw table capacity. Reuse currently passes `0`; update renderers, callers,
  contracts, tests, and comments to use this one unit.
- Reserve must size the hash table for the expected live member count at the
  named load factor and ensure enough order capacity.
- Reserve on an existing Set preserves keys and order.
- Reuse of a unique Set releases every old managed key once, clears metadata,
  resets counters, and retains adequate allocated capacity when sensible.
- Reuse of a shared Set consumes the caller's owner and returns fresh empty
  storage without mutating aliases.
- All constructor-specific hash/equality/release functions survive both paths.

The current shared `blorp_hash_capacity_at_least` has a minimum of 16, while
the proposed initial Set table capacity is 8. Resolve that deliberately: add a
Set-specific/parameterized checked helper, or retain 16 and adjust the named
constant after measuring tiny Sets. Do not silently call the existing helper
and claim an 8-slot first allocation.

Capacity conversion must safely compute the equivalent of
`ceil(expected_len * 10 / 7)`, round to a supported power of two, and reserve at
least one truly empty slot. Avoid overflowing in the multiplication; use a
checked quotient/remainder formulation or the repository's checked size
helpers. Normalize a negative internal request to zero (or make it
unrepresentable before this boundary), and reject/terminate through the
existing infrastructure-allocation path when the requested size cannot be
represented. Low-level backing helpers may accept raw table/order capacities,
but their names must say so and those units must not leak into Core intrinsics.

## Compiler And Intrinsic Migration

The current synthesized Set implementation directly manipulates buckets and
linked nodes. Replace that vocabulary completely.

### Remove Old Intrinsics And Helpers

Remove the runtime declarations, intrinsic variants, parsers, renderers,
ownership contracts, and tests for:

```text
set_bucket
set_first
set_last
set_entry_key
set_entry_next
set_entry_prev_order
set_entry_next_order
set_set_bucket
set_set_first
set_set_last
set_entry_set_next
set_entry_set_prev_order
set_entry_set_next_order
set_alloc_entry
set_free_entry
set_resize
blorp_set_alloc_entry
blorp_set_free_entry
blorp_set_resize_to
blorp_SetEntry
```

`set_resize`/`blorp_set_resize_to` expose raw table capacity and the old
rehash shape. Replace them with the checked internal rebuild/reserve operation;
do not retain them as aliases.

The compiler also registers `set_alloc`, although the current tree has no
ordinary synthesized call site for that intrinsic. Confirm with `rg`, then
remove its intrinsic variant, renderer, ownership contract, and dead tests.
Construction remains represented by `SetAllocExpr` and its typed runtime
constructors. Replace the internal runtime `blorp_set_alloc(long capacity)`
with a clearly named lazy header/expected-length helper rather than preserving
an ambiguous raw-capacity API.

`blorp_set_add` and `blorp_set_remove` remain reachable names in
`builtin_registry.brp`, `specialize_collection.brp`, ownership classification,
and backend tests. Port them to the flat representation and make them delegate
the same probe/preparation/atomic mutation helpers as the synthesized path.
Add direct runtime-call tests. Do not leave a second independent flat-Set
algorithm. Removing these entry points is acceptable only if the same change
proves them unreachable, removes all registrations and specializations, and
updates the existing tests coherently.

### Add Flat Set Intrinsics

Use the surrounding Dict intrinsic names and arity conventions. The required
logical operations are:

```text
set_capacity             Set -> Int
set_mask                 Set -> Int
set_ctrl_get              Set, slot -> Int
set_slot_order_get        Set, slot -> Int
set_order_len             Set -> Int
set_order_key_get         Set, position -> Ptr aliasing Set
set_order_live_get        Set, position -> Bool

set_cow                   Set -> Set
set_reuse_alloc           Set, expected_live_count -> Set
set_prepare_insert        Set, expected_live_count -> Void
set_commit_insert         Set, slot, hash_metadata, key -> Void
set_remove_occupied       Set, slot -> Void
set_reserve_for_len       Set, expected_live_count -> Void
```

Treat these names as logical operations; exact names may follow local naming
precedent. The important design decision is that synthesized Core performs
monomorphic hash/equality probing but commits representation changes through
narrow atomic helpers. Do not expose six independent setters that permit
temporarily invalid table/order state and inflate generated C. Do not introduce
a generic stringly typed mutation helper or move custom-key equality out of
synthesized Core.

Every new intrinsic needs:

- one registry entry;
- one exact ownership contract;
- one C renderer;
- parser/arity coverage;
- focused renderer tests; and
- inclusion in any intrinsic count or exhaustiveness test.

Read operations returning a raw stored key must be `ReturnAliasOfArg(0)`, not
owned. COW remains `[CowConsumeArg] -> ReturnOwned`.
`set_commit_insert` must have one authoritative key-acquisition contract (for
example, a `RetainArg` key while the Set is borrowed), and
`set_remove_occupied` must release the Set-owned key internally exactly once.
Key storage must retain or transfer ownership exactly once in a way visible to
the ownership model. Do not hide an additional retain in C while also asking
Perceus to transfer a separately retained owner.

### Port Synthesized Set Operations

Port all Set operations in `synth_hash_collections.brp`, not only `add`,
`remove`, and `contains`:

- `contains` and internal membership probes;
- `add` and insertion helpers;
- `remove`;
- `to_list`;
- `combine` / union;
- `intersect`;
- `difference` and symmetric difference dependencies;
- `map`;
- `filter`;
- `fold`;
- subset/superset/equality helpers; and
- any builder/reuse path.

Iteration over existing entries must scan `0..<set_order_len`, guard on
`set_order_live_get`, then read `set_order_key_get`. Do not scan table slots:
that would expose hash order rather than insertion order.

The immediate-key paths must retain direct immediate hash/equality operations.
String, float, and custom-key paths must retain the correct dispatched
hash/equality behavior. Do not replace an immediate comparison with a function
pointer call merely because the runtime layout is now common.

### Port Direct `for` Emission

Replace the prepared backend operations that name a `blorp_SetEntry *` with
order-position operations. Suggested concepts are:

```text
BackendSetIterSourceBinding
BackendSetIterRetain
BackendSetIterLoopOpen(position, set)
BackendSetIterLive(set, position)
BackendSetIterKey(set, position)
BackendSetIterRelease
```

Expected loop shape:

```c
for (long __set_position_0 = 0;
     __set_position_0 < __set_iter_0->order_len;
     __set_position_0++) {
    if (!__set_iter_0->order_live[__set_position_0]) continue;
    void *__set_key_0 = __set_iter_0->order_keys[__set_position_0];
    /* borrowed unbox + body */
}
```

Preserve the existing iterable cleanup-plan push/pop and retain/release order.
This is especially important for early return, cancellation, and reassignment
inside the body.

## TDD And Migration Sequence

Each step should be observed failing for the intended reason before its
production implementation is added. Keep the compiler buildable at commit
boundaries where practical.

### 1. Pin Missing Semantic Cases

Extend `standard_library/test/set/test_set_iteration.brp` with exact list/order
checks for:

1. remove from the middle preserves the relative order of survivors;
2. remove and re-add appends at the end;
3. duplicate add does not change order;
4. order survives enough insertions to force multiple table rebuilds;
5. order survives COW, with the alias unchanged;
6. churn with repeated remove/re-add does not duplicate entries; and
7. `Int(0)` remains iterable after other holes are created.

Use `to_list()` where exact order is the assertion. Do not infer order only
from sums.

Add or extend tests for:

- constant-hash user keys that force a long probe sequence;
- String keys deleted from the middle and later re-added;
- Float `+0.0`/`-0.0`, infinities, repeated NaN insertion,
  contains/remove NaN, and distinct NaN payloads, first characterizing the
  current result and then pinning it without redefining Float equality here;
- equivalent but separately allocated managed candidate keys, proving a
  duplicate keeps the originally stored key and cleans up only the candidate;
- boxed `Int128` and `UInt128` across COW, removal, rebuild, and destruction;
- empty, singleton, load-threshold, just-after-growth, and delete-heavy sizes;
- null-tolerant internal paths currently supported by `set_cow(NULL)`,
  `set_reuse_alloc(NULL, 0)`, and `blorp_set_remove(NULL, key)`;
- equality of same-member sets constructed in different orders; and
- all algebra and callback operations preserving the explicit ordering
  contract above: left order followed by novel right members for `combine`,
  left/source survivor order for intersection/difference/filter, left-only
  then right-only order for symmetric difference, and first mapped occurrence
  order when `map` produces collisions.

### 2. Add Representation-Shape Compiler Tests

Update `test_core_synth_hash_collections.brp` so Set synthesis requires the new
control/index/order intrinsics and rejects all node intrinsics.

Representative assertion shape:

```blorp
match synthesized_body(add_function):
	Some(body):
		contains_intrinsic(body, "set_cow")
			and contains_intrinsic(body, "set_ctrl_get")
			and contains_intrinsic(body, "set_slot_order_get")
			and contains_intrinsic(body, "set_order_key_get")
			and not contains_intrinsic(body, "set_alloc_entry")
			and not contains_intrinsic(body, "set_entry_set_next")
	None:
		False
```

Add corresponding shape checks for `contains`, `remove`, `to_list`, one set
algebra operation, and one callback operation.

### 3. Add Intrinsic And Ownership Tests

Before changing synthesis, add the new intrinsic renderer and ownership tests:

- exact arity and exact emitted C spelling;
- aliasing return contract for `set_order_key_get`;
- primitive return contracts for metadata/index reads;
- borrowed/transfer/retain contracts for writes;
- `CowConsumeArg -> ReturnOwned` for `set_cow`; and
- removal of old entry-pointer contracts.

Do not only adjust a global expected-intrinsic count. Test the semantics of the
new operations.

Add focused backend/runtime coverage for the retained direct
`blorp_set_add`/`blorp_set_remove` route so it cannot drift from synthesized
operations. If the implementation instead removes that route under the proof
allowed above, replace those tests with assertions that no registry,
specialization, ownership, or emitted-C reference remains.

### 4. Replace Runtime Storage

Implement allocation, copy, rebuild, reserve, reuse, remove, and destruction
against the new arrays in both `runtime.c` and `runtime_decl.c`. Those two type
definitions must remain byte-for-byte layout compatible.

At this point, compile the focused runtime probes with sanitizers even if full
Core synthesis is not yet migrated. A temporary C-only test may be used during
development but should not become a second permanent Set implementation.

### 5. Port Synthesis And Direct Iteration

Port all synthesized operations, then update prepared backend iteration and its
tests. Remove old entry helpers only after all generated C has stopped
referencing them.

### 6. Add Ownership And Stress Coverage

Extend the managed-key leak baseline or add a focused Set storage baseline
covering:

```blorp
var original: Set[String] = set()

for i in 0..200:
	original = original.add("key-${i}")

alias = original
changed = original.remove("key-100").add("replacement")

-- Read both branches, iterate both, then let both be destroyed.
```

Add a churn case that repeatedly crosses tombstone/order-compaction thresholds.
It must run under leak checking, ASan, and UBSan.

### 7. Remove The Old Representation Completely

Run the representation search from the implementation map. Delete all old
node declarations, helpers, intrinsics, renderer variants, ownership contracts,
and tests. Update stale comments that describe Set as separately chained.

## Bootstrap Transition Plan

This section is mandatory. The pinned bootstrap compiler contains the old Set
synthesis and backend. When it compiles the compiler source, the generated
compiler C contains `blorp_SetEntry`, `buckets`, `first`, and `next_order`
accesses even if the working-tree compiler sources describe the new flat
layout. Compiling that C against only the new `runtime_decl.c` will fail; making
it compile through accidental field compatibility would be worse.

Do not commit a permanent dual-representation runtime and do not keep a
compiler-version bridge. Use a controlled two-generation bootstrap:

1. Record the exact pre-change revision and pinned bootstrap binary hash.
2. Materialize the pre-change `runtime.c`, `runtime_decl.c`, and `minicoro.h`
   in a temporary directory outside the repository.
3. Use the pinned bootstrap to compile the changed compiler sources to a
   generation-1 C file. This C uses the old Set ABI internally because the
   pinned compiler emitted it.
4. Compile generation 1 against the temporary **old** runtime declaration and
   runtime object, but link the build-generated `runtime_sources.c` containing
   the **new** runtime source/declaration text. Generation 1 therefore runs on
   the old ABI while carrying the new runtime text and new compiler/backend
   logic for programs it emits.
5. Use generation 1 to compile the same changed compiler sources to
   generation-2 C. This output must use only the new flat Set ABI.
6. Compile generation 2 against the working-tree new runtime declaration and
   runtime object.
7. Use generation 2 to produce generation-3 C. Compile it normally and compare
   generation-2/generation-3 behavior, focused generated Set C shapes, test
   results, and deterministic outputs expected by existing self-host checks.
8. Run all acceptance gates with the homogeneous generation-2-or-later
   compiler.
9. Only a fully tested homogeneous compiler is eligible for a dev release and
   later bootstrap pin. The mixed generation-1 executable is a local transition
   tool and must never be published or pinned.

Use `mktemp -d` for the transition directory and an explicit cleanup trap. Use
`git show <recorded-revision>:<exact-path>` to materialize the three old runtime
files; never switch or overwrite the working tree. Base the host-C command on
the current `compile-prepared-blorp-cli` recipe so include directories, compile
flags, embedded runtime source, and LSP native source stay aligned.

Before relying on this plan, perform a small proof with one harmless temporary
Set field rename or generated-C marker: confirm that generation 1 contains the
old emitted shape while generation 2 contains the new emitted shape. Remove
the proof change before implementation. This validates the generation boundary
without beginning the full migration on an unproven bootstrap procedure.

If the build has acquired an official generation-transition tool by the time
this issue is implemented, use that tool instead, provided it enforces the same
old-internal/new-embedded separation and refuses to publish the mixed binary.

## Benchmark And Measurement Plan

### Required Benchmark Fixture

Extend `benchmarks/blorp/set_ops.brp` for end-to-end continuity, and add a
focused size-matrix fixture under:

```text
benchmarks/blorp/profiles/set_storage_profile.brp
```

The focused fixture must independently measure:

- build by repeated unique insertion;
- duplicate insertion;
- contains hit;
- contains miss;
- remove existing;
- remove missing;
- insertion-order iteration;
- delete/re-add churn;
- union, intersection, and difference;
- one shared COW update; and
- repeated unique updates after a Set has become unique again.

Treat the additional `slot_to_order -> order_keys` load on an H2 candidate as
the central performance risk of the proposed layout. Include controlled cases
for:

- contains hit/miss immediately before and immediately after table growth;
- a late-probe hit;
- multiple unequal keys sharing an H2 fingerprint; and
- a constant-hash key type.

The benchmark-only instrumentation must report probes and equality calls so a
good elapsed-time sample cannot hide a worsening probe policy.

Cover at least these live sizes:

```text
0, 1, 4, 8, 16, 64, 1,024, 100,000
```

Zero is required only where the operation is semantically applicable: empty
build, contains miss, remove missing, iteration, algebra, and COW. A hit,
remove-existing, or duplicate-insert sample needs at least one pre-populated
member. For those operations, start at N=1 and state the pre-operation live
size explicitly in the result label; do not manufacture a misleading N=0 hit
case merely to fill the matrix.

Use deterministic Int workloads for low-noise table cost, then include bounded
String and constant-hash custom-key cases. Feed every timed result through
`instrumentation.black_box_int` (or the matching typed black-box helper) and
also contribute it to a printed checksum, following existing Blorp benchmark
conventions, so the C compiler cannot remove the work.

Setup, key construction, result validation, printing, and destruction should
be outside the measured window whenever the operation permits it. The build
and destruction cases necessarily need their own carefully named windows.
Calibrate repetitions to a minimum stable timing window. A single COW update
is too short: prebuild independent shared aliases, then time a batch of exactly
one update per alias without including alias construction.

Collect benchmark-only counters for table/order capacities, `order_len`, live
size, holes, tombstones, probe steps, hash calls, equality calls, rebuilds,
compactions, requested allocation bytes, and allocator usable bytes where the
platform exposes them. Measure String/custom-hash churn explicitly because the
layout does not store full hashes and every growth/compaction recomputes them.
Also construct a shared Set at the maximum permitted hole/tombstone pressure
and measure its COW copy; exact metadata copying can otherwise copy substantial
dead capacity. If that result is poor, revisit policy or representation rather
than silently making ordinary COW rehash user keys.

### Required Allocation Evidence

Blorp's ordinary managed-object `MemStats` does not currently count the raw
`malloc` calls used for Set entries and backing arrays. Do not claim allocation
reductions from those counters alone.

Collect native allocation evidence by one of these explicit methods:

- a benchmark-only runtime build with malloc/calloc/free counters;
- platform allocator instrumentation against retained benchmark binaries; or
- another reviewed mechanism that counts both old Set nodes and new backing
  arrays without changing release-build behavior.

Record, for build and one shared COW update at N=1,024 and N=100,000:

- native allocation calls;
- native free calls;
- peak or retained bytes attributable to Set scaffolding;
- managed retains/releases for String keys, if available; and
- elapsed time as a secondary measure.

The old build should show O(N) entry allocations. The new build and COW copy
must show no per-member native allocation loop.

### Compiler-Level Check

Set is used in module visibility, DCE, match lowering, Core resolution, type
policy, and backend layout collection. Use the repository wrapper, which pins
the compiler/workspace inputs and build behavior:

```bash
benchmarks/compiler_module_visibility_profile
benchmarks/compiler_module_visibility_profile 1000 128 all 1 dense mixed
```

Set `BLORP_COMPILER_BENCHMARK_COMPILER` and
`BLORP_COMPILER_BENCHMARK_WORKSPACE_ROOT` to the matching baseline/candidate
pair as documented in `benchmarks/README.md`; do not compare a fixture built
from one source graph with another compiler graph.

Also time a representative full source-to-C compile of `blorp/src/main.brp`
with C compilation excluded. Record emitted C bytes and lines. Report host-C
compile time separately as diagnostic evidence because changing synthesized
Core may change emitted-C shape, but do not include it in the compiler
regression gate for this issue. Pin the exact command and options in the result
artifact rather than relying on an interactive shell history.

The compiler measurement is a guardrail, not the primary acceptance signal:
Set appears in a limited number of compiler modules, so a large whole-compiler
speedup is not required.

### Comparison Discipline

- Build baseline and candidate with the same pinned bootstrap and host C flags.
- Use a clean control worktree at the pre-change revision.
- Warm both binaries before measurement.
- Alternate baseline/candidate order.
- Use 10-30 measured pairs in alternating even-numbered blocks, plus a warmup,
  for publication-quality elapsed-time claims.
- Report paired percentage deltas and a deterministic 95% bootstrap interval
  with at least 10,000 resamples, following the repository benchmark protocol.
- Retain raw samples, compiler versions, host details, input/checksum output,
  and exact commands under `benchmarks/results/`.
- Treat results with mismatched checksums or semantic output as invalid.
- Do not quote a speedup from a single run.

## Fast-Feedback Loop

The inner loop should take seconds to a few minutes and should be run after
each coherent edit.

### Runtime Layout / C Helper Edit

```bash
make
bin/blorp test standard_library/test/set/test_set_ir.brp
bin/blorp test standard_library/test/set/test_set_iteration.brp
bin/blorp test standard_library/test/set/test_set_user_key.brp
```

Inspect the first generated C artifact that exercises `add`, `remove`, and
iteration. Confirm that it uses control/index/order arrays and contains no
`blorp_SetEntry`, `blorp_set_alloc_entry`, or linked-order traversal.

### Core Synthesis / Intrinsic Edit

```bash
scripts/compiler-check --changed
bin/blorp test \
  blorp/test/compiler/stage_09_core/test_core_synth_hash_collections.brp
bin/blorp test \
  blorp/test/compiler/stage_09_core/test_core_ownership.brp
bin/blorp test \
  blorp/test/compiler/stage_10_backend/test_codegen_intrinsic_renderer.brp
bin/blorp test \
  blorp/test/compiler/stage_10_backend/test_codegen_prepared_backend_renderer.brp
```

If `scripts/compiler-check --changed` selects a broader set, let it do so; do
not replace manifest-owned coverage with only hand-picked files.

### Ownership / Tombstone Edit

```bash
bin/blorp test --leak-check --suite --timeout 30 \
  blorp/test/runtime/memory/leak_check_baselines/set_string_storage.brp
bin/blorp test --sanitize --timeout 30 \
  standard_library/test/set/test_set_storage_stress.brp
scripts/test compiler-core-sanitize
```

`test_set_storage_stress.brp` is the new focused churn, H2/constant-collision,
wide-integer, and managed-key fixture required by this issue. Keep the direct
sanitizer invocation: the compiler Core sanitizer gate alone does not execute
this runtime storage workload.

### Quick Performance Check

```bash
bin/blorp run --release benchmarks/blorp/profiles/set_storage_profile.brp
bash benchmarks/bench.sh set_ops
```

Use this only to catch catastrophic regressions during development. Run the
paired comparison protocol before making final performance claims.

### Pre-Handoff Gate

```bash
make
scripts/compiler-check --changed
scripts/test compiler-blorp
scripts/test compiler-tools
scripts/test std-check
scripts/test runtime
scripts/test leak
scripts/test doctest
scripts/test cli
scripts/test lsp
scripts/test package
blorp/test/compiler/pipeline/codegen_audit/run_codegen_audit.sh bin/blorp
```

Run the compiler sanitizer gate as well when the final generated Set operations
or ownership contracts differ from the last sanitizer run.

## Pitfalls And Gotchas

### `Int(0)` Is A Null Pointer

Primitive integer keys are erased through `void *`; zero is null. Never use
`order_keys[position] == NULL` as an empty/deleted test. `order_live` is the
only order-storage liveness authority.

### Managed Null Checks Are Different From Slot Liveness

It remains correct to guard `blorp_retain`/release with `key != NULL` after
`order_live` has established a live managed slot. Do not reverse those roles.

### Tombstones Must Not Terminate Lookup

An empty slot terminates an unsuccessful probe. A deleted slot does not. Using
empty metadata for removal will make keys later in the probe run unreachable.

### First Deleted Slot Must Be Remembered

Insertion should reuse the first deleted slot encountered but must continue
probing until it finds either the key or an actually empty slot. Inserting
immediately into the first tombstone can create duplicates.

### Rebuild Invalidates Table Slots And Order Positions

Never retain a table slot or order position across reserve, growth, compaction,
reuse, or COW replacement. Re-probe or calculate the position only after the
last operation that can rebuild storage.

### COW Copy Must Preserve Exact Metadata

Within one process, the hash seed and hash/equality functions are unchanged.
Bulk-copy table metadata and mappings; do not rehash during COW. Rehashing adds
work and can invoke user equality/hash paths unnecessarily.

### Rebuild Is Not A Second Owner

Moving live key pointers between arrays owned by one unique Set is
ownership-neutral. Retaining every key during rebuild and releasing it from the
old arrays is both slower and easier to get wrong.

### Copy Is A Second Owner

COW copy is different: both source and destination remain valid. Every managed
key must be retained exactly once for the new Set.

### Duplicate Add Owns Nothing New

When insertion finds an equivalent existing key, the Set does not acquire the
candidate key and must preserve the original stored key object and insertion
position. Preserve the current ownership cleanup for boxed/custom candidate
temporaries; an equal but separately allocated managed candidate must be
released without releasing or replacing the stored owner.

### Custom Hash And Equality Stay Monomorphic Where They Are Today

The compiler synthesizes direct immediate/custom calls for Set operations.
Changing storage does not justify routing them all through function pointers.
Preserve exact type layout, boxing, and unboxing behavior.

### Float Semantics Must Not Drift

The current runtime canonicalizes signed zero for hashing and compares with C
floating equality. Preserve existing `0.0`, `-0.0`, infinity, and NaN behavior;
do not silently redefine it during the storage migration. Characterize
repeated insertion, contains, and removal for one NaN and for distinct NaN
payloads before changing storage because intuition about mathematical Sets is
not an adequate substitute for the current equality contract.

### Null-Tolerant Internal Paths Are Observable To Generated Code

Current runtime helpers tolerate null Set pointers in paths including
`set_cow(NULL)`, `set_reuse_alloc(NULL, ...)`, and `blorp_set_remove(NULL, key)`.
Preserve and test those results unless the compiler proves and removes the
states in an earlier, separately reviewed change. The new lazy-empty state
must not turn a formerly valid null path into a probe through null backing.

### Fresh Empty And Reused Empty Are Different States

A fresh constructor must allocate only the Set header. A unique Set cleared by
reuse may retain its initialized arrays for the next builder. Both have
`size == 0`, but only the fresh state is required to have zero capacity and
null backing pointers. All queries must work for both representations.

### Holey COW Copies Trade Hashing For Dead-Byte Copies

Exact COW copying avoids hash/equality calls, but a Set near the allowed hole
and tombstone thresholds can copy much more storage than it has live members.
Measure this boundary explicitly. Do not compact a shared source in place, and
do not switch to rehashing COW ad hoc; if the tradeoff is poor, adjust the
named compaction thresholds or revise the design with evidence.

### Iteration Uses Order Storage, Not Table Storage

Scanning open-addressed table slots is tempting and fast, but it exposes hash
order and makes output depend on the randomized process seed. All public
iteration, `to_list`, callbacks, and ordered set-algebra builders must use order
storage.

### Holes Can Grow Without Bound

O(1) ordered removal requires holes. A workload that repeatedly removes and
adds while keeping a small live Set can otherwise grow `order_len` forever.
Compaction thresholds and churn tests are mandatory.

### Tiny Sets Need Measurement

Four independently allocated arrays can make tiny sets allocator-heavy even
when retained bytes are lower. The initial capacities are intentionally small,
and empty sets are lazy, but measure sizes 1, 4, and 8 explicitly. If tiny Set
results are poor, a single combined backing allocation is a reasonable
follow-up. Do not add an inline/dual representation without separate evidence;
it complicates every intrinsic and can push the Set header out of the runtime's
small-object pool.

### Runtime And Runtime Declarations Must Match

`runtime.c` and `runtime_decl.c` duplicate the ABI-visible structure. A field
order or type mismatch can compile and then corrupt generated programs. Update
and review them together.

### Sanitizers Will Not Replace Leak Checks

ASan catches invalid accesses and double frees. It does not prove that ARC keys
were released or that a COW branch retained its members. Run both sanitizer and
Blorp leak gates.

### Do Not Leave Transitional Compatibility Helpers

Blorp is pre-0.1 and the Set representation is internal. Once synthesis and
generated C have migrated, remove the node ABI completely. Do not retain an
unused linked representation or a bridge selected by compiler version.

## Acceptance Criteria

### Representation

- [ ] `blorp_SetEntry` no longer exists in production runtime declarations or
      generated C.
- [ ] A live Set member is stored in flat order storage and indexed by a flat
      open-addressed table.
- [ ] No Set operation performs one native allocation or free per member.
- [ ] A freshly constructed empty Set allocates no backing arrays; an empty Set
      produced by reuse may retain initialized capacity.
- [ ] Control state, table-to-order mapping, order liveness, and tombstone count
      are explicit and covered by invariants.
- [ ] Runtime and generated-C Set structure declarations match exactly.

### Semantics

- [ ] `add`, `remove`, `contains`, `length`, `to_list`, all set algebra,
      `map`, `filter`, `fold`, subset/superset, and equality retain their public
      results.
- [ ] Iteration is insertion ordered.
- [ ] Duplicate insertion leaves order unchanged.
- [ ] Removal preserves survivor order.
- [ ] Remove then re-add appends the member.
- [ ] Equality ignores insertion order.
- [ ] Rebuild, reserve, COW, and reuse preserve required order.
- [ ] `combine` keeps left order then appends previously absent right members;
      intersection, difference, and filter preserve left/source order;
      symmetric difference emits left-only then right-only members; and map
      keeps the first input occurrence of each mapped value.
- [ ] Immediate zero, String, Float, enum, and user-defined keys work.
- [ ] Existing signed-zero, infinity, and NaN insertion/lookup/removal behavior
      is characterized and unchanged.
- [ ] Null-tolerant COW, reuse, and remove helper paths retain their current
      results without touching null backing arrays.
- [ ] Constant-hash collisions, load-boundary growth, tombstone reuse, and
      delete/re-add churn are covered.

### Ownership And Safety

- [ ] Shared aliases are unchanged after mutation of a COW result.
- [ ] Unique updates remain valid across rebuild and reuse.
- [ ] Non-owning immediate-layout COW copies perform no per-key retains.
- [ ] Boxed `Int128` and `UInt128` COW, removal, rebuild, and destruction retain
      or release every live key exactly as their managed layout requires.
- [ ] Managed-key COW copies retain each live key exactly once.
- [ ] Duplicate insertion of an equivalent managed candidate preserves the
      original stored object and disposes of only the candidate ownership.
- [ ] Rebuild/compaction performs no retain/release churn for moved keys.
- [ ] Removal and destruction release each managed key exactly once.
- [ ] Iteration borrows keys and does not add per-element ARC traffic.
- [ ] Leak checks, ASan, and UBSan pass for String and custom managed keys.
- [ ] No stale slot/order index survives an operation that can rebuild arrays.

### Compiler Integration

- [ ] All node-specific Set intrinsics, variants, renderers, ownership contracts,
      runtime helpers, and tests are removed.
- [ ] `set_resize`/`blorp_set_resize_to` and the unused `set_alloc` compiler
      intrinsic are removed; expected-live-count capacity units are consistent
      across reserve/reuse callers, renderers, contracts, and tests.
- [ ] Retained direct `blorp_set_add`/`blorp_set_remove` paths delegate shared
      flat helpers and have direct tests, or are proven unreachable and removed
      with all registry/specialization/ownership references.
- [ ] Every replacement intrinsic has exact arity, rendering, and ownership
      coverage.
- [ ] All synthesized Set operations use the flat representation.
- [ ] Direct `for` emission scans ordered storage and skips holes.
- [ ] Generated C contains no linked Set traversal.
- [ ] The codegen audit reports no new warning, unsequenced operation, or
      incompatible pointer conversion.

### Documentation

- [ ] `standard_library/src/set.brp` no longer says Set uses separate chaining.
- [ ] `standard_library/src/set.brp` explicitly documents insertion order,
      removal order, and remove/re-add behavior.
- [ ] `docs/GUIDE.md` documents the same observable ordering contract.
- [ ] Benchmark documentation includes the new focused Set profile and exact
      reproduction commands.

### Performance Evidence

- [ ] Build, contains hit/miss, remove, iteration, churn, set algebra, and COW
      are measured across every semantically applicable size in the required
      matrix; hit/existing/duplicate cases start at N=1.
- [ ] Just-before/after-growth, late-probe, H2-collision, constant-hash, and
      maximally holey COW cases report capacities, holes/tombstones, probes,
      hash/equality calls, rebuilds, and compactions.
- [ ] Native allocation evidence counts raw Set node/backing allocations rather
      than relying only on managed `MemStats`.
- [ ] Building an N-member Set and copying it for COW have no O(N) native
      allocation count.
- [ ] The primary scenarios are Int build, duplicate add, contains hit/miss,
      remove existing/missing, ordered iteration, shared COW update, and a
      steady-state unique update at N=64, N=1,024, and N=100,000.
- [ ] No primary scenario regresses by more than 10% in paired median, using
      10-30 alternating pairs and a deterministic 95% bootstrap interval. If
      the interval crosses the 10% bound, gather enough samples to resolve it
      or treat it as an acceptance failure; do not waive an inconclusive or
      adverse result in the implementation change.
- [ ] Small sizes 0, 1, 4, and 8 are reported explicitly; no silent tiny-Set
      regression is hidden in a large-set aggregate.
- [ ] The representative compiler profile has identical output and no greater
      than 5% paired median regression. A whole-compiler speedup is not required.
- [ ] Full compiler source-to-C time and emitted-C bytes/lines are reported;
      host-C time is recorded separately and excluded from that 5% gate.
- [ ] At N=1,024 and N=100,000, measured Set scaffolding bytes are at least 25%
      lower than the node-based baseline. This is intentionally below the
      design estimate so allocator/platform variance does not create a brittle
      gate.
- [ ] Memory is also reported immediately before/after growth and at maximum
      permitted order-hole pressure; these characterization points have no
      separate percentage gate but must remain bounded by the named policies.
- [ ] Raw samples, checksums, commands, revisions, toolchain, and host details
      are retained under `benchmarks/results/`.

### Gates

- [ ] `make` passes.
- [ ] `scripts/compiler-check --changed` passes.
- [ ] `scripts/test compiler-blorp` passes.
- [ ] `scripts/test compiler-tools` passes.
- [ ] `scripts/test std-check` passes.
- [ ] `scripts/test runtime` passes.
- [ ] `scripts/test leak` passes.
- [ ] `scripts/test doctest` passes.
- [ ] `scripts/test cli` passes.
- [ ] `scripts/test lsp` passes.
- [ ] `scripts/test package` passes.
- [ ] The relevant compiler sanitizer gate passes.
- [ ] The generated-C codegen audit passes.
- [ ] The documented two-generation bootstrap succeeds, generation 2 contains
      only the flat Set ABI, and the mixed generation-1 tool is neither committed
      nor published.
- [ ] `git diff --check` passes and no generated compilation artifact remains in
      the repository.

## Expected Outcome

After completion, Blorp Set values retain their current simple source model and
deterministic iteration while using cache-friendly, bulk-copyable storage.
Large Set construction and destruction no longer stress the native allocator,
membership avoids linked pointer chasing, iteration becomes sequential, and a
shared COW update no longer allocates and rehashes one node per member.

The implementation should also leave a clean foundation for two independent
future experiments:

1. group/SIMD control-byte probing shared with Dict; and
2. compact table indices after an explicit maximum-capacity policy is chosen.

Neither follow-up is required to close this issue.
