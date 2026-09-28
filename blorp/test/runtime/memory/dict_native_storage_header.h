#ifndef BLORP_TEST_DICT_NATIVE_STORAGE_HEADER_H
#define BLORP_TEST_DICT_NATIVE_STORAGE_HEADER_H

// Direct checks of the runtime Dict storage paths (blorp_dict_insert,
// blorp_dict_remove, the shared-copy path and rehash). Generated code mostly
// reaches Dict through synthesized Core, so these helpers drive the runtime
// entry points themselves. Each returns 1 on success and a distinct
// negative code naming the first failed check otherwise. The narrower
// order-hole compaction regression for a snapshot taken mid-churn lives in
// blorp/test/runtime/collections/dict_native_reinsert_header.h.

#define DICT_STORAGE_INT(v) ((void*)(intptr_t)(v))

// Walk the insertion order and compare it with expected int keys.
static inline long dict_storage_order_matches(blorp_Dict* dict, const long* expected, long count) {
    long seen = 0;
    for (long i = 0; i < dict->order_len; i++) {
        long slot = dict->order[i];
        if (slot < 0) continue;
        if (seen >= count) return 0;
        if (dict->keys[slot] != DICT_STORAGE_INT(expected[seen])) return 0;
        if (dict->order_index[slot] != i) return 0;
        seen++;
    }
    return seen == count && dict->size == count;
}

static inline long dict_storage_refcount(void* obj) {
#ifdef BLORP_SINGLE_THREADED
    return (long)((blorp_Object*)obj)->refcount;
#else
    return (long)atomic_load_explicit(&((blorp_Object*)obj)->refcount, memory_order_relaxed);
#endif
}

static inline long dict_storage_has_int(blorp_Dict* dict, long key, long value) {
    void* out = NULL;
    return blorp_dict_get_raw(dict, DICT_STORAGE_INT(key), &out) && out == DICT_STORAGE_INT(value);
}

static inline long dict_native_empty_dict(void) {
    blorp_Dict* dict = blorp_dict_new();
    void* out = NULL;
    long passed = dict->size == 0
        && dict->order_len == 0
        && dict->capacity >= 16
        && !blorp_dict_get_raw(dict, DICT_STORAGE_INT(7), &out);
    for (long slot = 0; slot < dict->capacity; slot++) {
        if (dict->meta[slot] != DICT_META_EMPTY) passed = 0;
    }
    // Removing from an empty dict stays empty; removing a missing key from an
    // empty shared dict changes nothing, so it returns the shared dict itself.
    dict = blorp_dict_remove(dict, DICT_STORAGE_INT(7));
    blorp_Dict* shared = dict;
    blorp_retain(shared);
    dict = blorp_dict_remove(dict, DICT_STORAGE_INT(7));
    if (dict != shared || dict->size != 0 || dict_storage_refcount(shared) != 2) passed = 0;
    blorp_List* entries = blorp_dict_entries(dict);
    if (entries->len != 0) passed = 0;
    blorp_release(entries);
    blorp_release(dict);
    blorp_release(shared);
    return passed ? 1 : -1;
}

// Growth through several capacities keeps every entry and insertion order.
static inline long dict_native_growth_preserves_entries_and_order(void) {
    enum { entry_count = 1500 };
    static long expected[entry_count];
    blorp_Dict* dict = blorp_dict_new();
    long capacities_seen = 1;
    long last_capacity = dict->capacity;
    for (long i = 0; i < entry_count; i++) {
        // Scatter keys so hash order and insertion order disagree.
        long key = (i * 7919) % 100003;
        expected[i] = key;
        dict = blorp_dict_insert(dict, DICT_STORAGE_INT(key), DICT_STORAGE_INT(key + 1));
        if (dict->capacity != last_capacity) {
            if (dict->capacity != last_capacity * 2) { blorp_release(dict); return -1; }
            last_capacity = dict->capacity;
            capacities_seen++;
        }
        if (dict->size >= dict->grow_at) { blorp_release(dict); return -2; }
    }
    long passed = 1;
    if (capacities_seen < 6) passed = -3;
    if (passed == 1 && !dict_storage_order_matches(dict, expected, entry_count)) passed = -4;
    for (long i = 0; passed == 1 && i < entry_count; i++) {
        if (!dict_storage_has_int(dict, expected[i], expected[i] + 1)) passed = -5;
    }
    blorp_release(dict);
    return passed;
}

// Removals leave tombstones and order holes; reinsertion and later growth
// compact them without losing entries or reordering survivors.
static inline long dict_native_tombstones_then_growth(void) {
    blorp_Dict* dict = blorp_dict_new();
    for (long key = 0; key < 10; key++) {
        dict = blorp_dict_insert(dict, DICT_STORAGE_INT(key), DICT_STORAGE_INT(key * 10));
    }
    for (long key = 0; key < 10; key += 2) {
        dict = blorp_dict_remove(dict, DICT_STORAGE_INT(key));
    }
    long capacity_before = dict->capacity;
    // Reinsert two removed keys: they move to the end of the order.
    dict = blorp_dict_insert(dict, DICT_STORAGE_INT(4), DICT_STORAGE_INT(44));
    dict = blorp_dict_insert(dict, DICT_STORAGE_INT(0), DICT_STORAGE_INT(1));
    // Churn remove/reinsert of one key to fill order[] with holes and force
    // a same-capacity compaction before any growth.
    for (long round = 0; round < 40; round++) {
        dict = blorp_dict_remove(dict, DICT_STORAGE_INT(100));
        dict = blorp_dict_insert(dict, DICT_STORAGE_INT(100), DICT_STORAGE_INT(round));
    }
    dict = blorp_dict_remove(dict, DICT_STORAGE_INT(100));
    long passed = 1;
    if (dict->capacity != capacity_before) passed = -1;
    long expected_small[] = {1, 3, 5, 7, 9, 4, 0};
    if (passed == 1 && !dict_storage_order_matches(dict, expected_small, 7)) passed = -2;
    // Grow well past the current capacity.
    for (long key = 1000; passed == 1 && key < 1100; key++) {
        dict = blorp_dict_insert(dict, DICT_STORAGE_INT(key), DICT_STORAGE_INT(key));
    }
    if (passed == 1 && dict->capacity <= capacity_before) passed = -3;
    if (passed == 1) {
        static long expected[107];
        for (long i = 0; i < 7; i++) expected[i] = expected_small[i];
        for (long i = 0; i < 100; i++) expected[7 + i] = 1000 + i;
        if (!dict_storage_order_matches(dict, expected, 107)) passed = -4;
        if (dict->order_len != 107) passed = -5;
    }
    if (passed == 1 && (!dict_storage_has_int(dict, 4, 44) || !dict_storage_has_int(dict, 0, 1)
        || !dict_storage_has_int(dict, 9, 90) || dict_storage_has_int(dict, 2, 20))) passed = -6;
    void* out = NULL;
    if (passed == 1 && blorp_dict_get_raw(dict, DICT_STORAGE_INT(100), &out)) passed = -7;
    blorp_release(dict);
    return passed;
}

// Inserting into a shared dict copies it; both sides stay independent, and a
// copy taken exactly at the growth threshold grows while the original keeps
// its capacity and contents.
static inline long dict_native_shared_copy_then_mutate_both(void) {
    long passed = 1;
    for (long fill = 1; passed == 1 && fill <= 40; fill++) {
        blorp_Dict* original = blorp_dict_new();
        for (long key = 0; key < fill; key++) {
            original = blorp_dict_insert(original, DICT_STORAGE_INT(key), DICT_STORAGE_INT(key));
        }
        // Leave a hole so the copy must also compact order[].
        original = blorp_dict_remove(original, DICT_STORAGE_INT(0));
        long original_capacity = original->capacity;
        long original_size = original->size;

        blorp_Dict* snapshot = original;
        blorp_retain(snapshot);
        blorp_Dict* copy = blorp_dict_insert(original, DICT_STORAGE_INT(500), DICT_STORAGE_INT(5));
        if (copy == snapshot) passed = -1;
        if (passed == 1 && (snapshot->capacity != original_capacity || snapshot->size != original_size)) passed = -2;
        if (passed == 1 && copy->size != original_size + 1) passed = -3;
        if (passed == 1 && copy->size >= copy->grow_at) passed = -4;

        // Mutate both sides after the split.
        copy = blorp_dict_insert(copy, DICT_STORAGE_INT(500), DICT_STORAGE_INT(55));
        snapshot = blorp_dict_insert(snapshot, DICT_STORAGE_INT(600), DICT_STORAGE_INT(6));

        long copy_expected[64];
        long snapshot_expected[64];
        long n = 0;
        for (long key = 1; key < fill; key++) { copy_expected[n] = key; snapshot_expected[n] = key; n++; }
        copy_expected[n] = 500;
        snapshot_expected[n] = 600;
        if (passed == 1 && !dict_storage_order_matches(copy, copy_expected, n + 1)) passed = -5;
        if (passed == 1 && !dict_storage_order_matches(snapshot, snapshot_expected, n + 1)) passed = -6;
        if (passed == 1 && !dict_storage_has_int(copy, 500, 55)) passed = -7;
        if (passed == 1 && fill > 1 && !dict_storage_has_int(snapshot, 1, 1)) passed = -8;
        if (passed == 1 && (dict_storage_has_int(copy, 600, 6) || dict_storage_has_int(snapshot, 500, 5))) passed = -9;

        // Updating an existing key of a shared dict copies without growing.
        blorp_Dict* again = copy;
        blorp_retain(again);
        blorp_Dict* updated = blorp_dict_insert(copy, DICT_STORAGE_INT(500), DICT_STORAGE_INT(50));
        if (passed == 1 && (updated == again || updated->capacity != again->capacity
            || !dict_storage_has_int(updated, 500, 50) || !dict_storage_has_int(again, 500, 55))) passed = -10;

        blorp_release(updated);
        blorp_release(again);
        blorp_release(snapshot);
        if (passed != 1) return passed - fill * 100;
    }
    return passed;
}

// A shared dict whose order[] is full of removal holes is compacted while it
// is copied for a new key; the original keeps its holes and capacity.
static inline long dict_native_shared_copy_with_full_order(void) {
    blorp_Dict* dict = blorp_dict_new();
    for (long key = 0; key < 5; key++) {
        dict = blorp_dict_insert(dict, DICT_STORAGE_INT(key), DICT_STORAGE_INT(key));
    }
    while (dict->order_len < dict->capacity) {
        dict = blorp_dict_remove(dict, DICT_STORAGE_INT(100));
        dict = blorp_dict_insert(dict, DICT_STORAGE_INT(100), DICT_STORAGE_INT(100));
    }
    dict = blorp_dict_remove(dict, DICT_STORAGE_INT(100));
    long capacity = dict->capacity;
    if (dict->order_len != capacity || dict->size != 5) { blorp_release(dict); return -1; }

    blorp_Dict* snapshot = dict;
    blorp_retain(snapshot);
    dict = blorp_dict_insert(dict, DICT_STORAGE_INT(200), DICT_STORAGE_INT(200));
    long passed = 1;
    long expected_copy[] = {0, 1, 2, 3, 4, 200};
    long expected_snapshot[] = {0, 1, 2, 3, 4};
    if (dict == snapshot || dict->capacity != capacity || dict->order_len != 6) passed = -2;
    if (passed == 1 && !dict_storage_order_matches(dict, expected_copy, 6)) passed = -3;
    if (passed == 1 && (snapshot->order_len != capacity || snapshot->capacity != capacity)) passed = -4;
    if (passed == 1 && !dict_storage_order_matches(snapshot, expected_snapshot, 5)) passed = -5;
    if (passed == 1 && (!dict_storage_has_int(dict, 200, 200) || dict_storage_has_int(snapshot, 200, 200))) passed = -6;
    blorp_release(dict);
    blorp_release(snapshot);
    return passed;
}

// resize_to asked for a capacity too small for the live entries raises it to
// one that fits: the rebuild terminates and keeps every entry in order.
static inline long dict_native_resize_below_live_count_keeps_entries(void) {
    enum { entry_count = 40 };
    long expected[entry_count];
    blorp_Dict* dict = blorp_dict_new();
    for (long i = 0; i < entry_count; i++) {
        expected[i] = (i * 37) % 1009;
        dict = blorp_dict_insert(dict, DICT_STORAGE_INT(expected[i]), DICT_STORAGE_INT(i));
    }
    long passed = 1;
    blorp_dict_resize_to(dict, 16);
    if (dict->capacity < 16 || dict->size >= dict->grow_at) passed = -1;
    if (passed == 1 && !dict_storage_order_matches(dict, expected, entry_count)) passed = -2;
    for (long i = 0; passed == 1 && i < entry_count; i++) {
        if (!dict_storage_has_int(dict, expected[i], i)) passed = -3;
    }
    // A capacity below the entry count itself is clamped the same way.
    blorp_dict_resize_to(dict, 1);
    if (passed == 1 && (dict->size >= dict->grow_at
        || !dict_storage_order_matches(dict, expected, entry_count))) passed = -4;
    blorp_release(dict);
    return passed;
}

// Heap keys and values through every storage path: growth, removal,
// shared copy at the growth threshold, reuse and resize. The leak gate
// checks that nothing survives the final release.
static inline long dict_native_heap_entries_release_cleanly(void) {
    blorp_Dict* dict = blorp_dict_new_string();
    blorp_dict_set_value_release(dict, blorp_elem_release_fn);
    char buffer[64];
    long passed = 1;
    for (long i = 0; i < 200; i++) {
        snprintf(buffer, sizeof(buffer), "key-%ld", i);
        blorp_String* key = blorp_string_create(buffer);
        snprintf(buffer, sizeof(buffer), "value-%ld", i);
        blorp_String* value = blorp_string_create(buffer);
        blorp_Dict* snapshot = NULL;
        long size_before_insert = dict->size;
        // Share at every growth threshold so the grow-while-copying path runs
        // with managed entries.
        if (dict->size + 1 >= dict->grow_at) {
            snapshot = dict;
            blorp_retain(snapshot);
        }
        dict = blorp_dict_insert(dict, key, value);
        if (snapshot) {
            if (snapshot->size != size_before_insert || dict->size != size_before_insert + 1) passed = -1;
            blorp_release(snapshot);
        }
        blorp_release(key);
        blorp_release(value);
        if (i % 3 == 0) {
            snprintf(buffer, sizeof(buffer), "key-%ld", i / 2);
            blorp_String* doomed = blorp_string_create(buffer);
            dict = blorp_dict_remove(dict, doomed);
            blorp_release(doomed);
        }
    }
    // Overwrite a value in a shared dict.
    blorp_Dict* shared = dict;
    blorp_retain(shared);
    blorp_String* key = blorp_string_create("key-199");
    blorp_String* value = blorp_string_create("replaced");
    dict = blorp_dict_insert(dict, key, value);
    void* out = NULL;
    if (!blorp_dict_get_raw(dict, key, &out) || !blorp_string_eq((blorp_String*)out, value)) passed = -2;
    blorp_release(key);
    blorp_release(value);
    blorp_release(shared);

    // Resize in place, then reuse the storage for a smaller and a larger table.
    long size_before = dict->size;
    blorp_dict_resize_to(dict, dict->capacity * 2);
    if (dict->size != size_before) passed = -3;
    blorp_Dict* copy = dict;
    blorp_retain(copy);
    dict = blorp_dict_reuse_alloc(dict, 16);
    if (dict == copy || dict->size != 0 || copy->size != size_before) passed = -4;
    blorp_release(copy);
    key = blorp_string_create("after-reuse");
    dict = blorp_dict_insert(dict, key, key);
    blorp_release(key);
    dict = blorp_dict_reuse_alloc(dict, 16);
    if (dict->size != 0 || dict->order_len != 0) passed = -5;
    for (long slot = 0; slot < dict->capacity; slot++) {
        if (dict->meta[slot] != DICT_META_EMPTY) passed = -6;
    }
    key = blorp_string_create("small");
    dict = blorp_dict_insert(dict, key, key);
    blorp_release(key);
    dict = blorp_dict_reuse_alloc(dict, 1024);
    if (dict->capacity < 1024 || dict->size != 0) passed = -7;
    key = blorp_string_create("large");
    dict = blorp_dict_insert(dict, key, key);
    if (!blorp_dict_get_raw(dict, key, &out) || out != (void*)key) passed = -8;
    blorp_release(key);
    blorp_release(dict);
    return passed;
}

// A mutation of a shared dict that changes nothing returns the shared dict
// itself, with no copy and no reference-count change: removing a missing key,
// and setting an existing key to the pointer-identical value. Value equality
// is never consulted, so an equal but distinct value still copies. Real
// mutations still copy and leave the other holder untouched.
static inline long dict_native_shared_noop_mutations_keep_object(void) {
    blorp_Dict* dict = blorp_dict_new_string();
    blorp_dict_set_value_release(dict, blorp_elem_release_fn);
    blorp_String* key = blorp_string_create("present");
    blorp_String* value = blorp_string_create("value");
    dict = blorp_dict_insert(dict, key, value);
    long passed = 1;

    blorp_Dict* holder = dict;
    blorp_retain(holder);
    blorp_String* missing = blorp_string_create("missing");
    dict = blorp_dict_remove(dict, missing);
    if (dict != holder || dict_storage_refcount(holder) != 2 || dict->size != 1) passed = -1;

    // Same key object and a distinct but equal key both find the entry.
    dict = blorp_dict_insert(dict, key, value);
    if (passed == 1 && (dict != holder || dict_storage_refcount(holder) != 2)) passed = -2;
    blorp_String* equal_key = blorp_string_create("present");
    dict = blorp_dict_insert(dict, equal_key, value);
    if (passed == 1 && (dict != holder || dict_storage_refcount(holder) != 2)) passed = -3;
    if (passed == 1 && dict_storage_refcount(value) != 2) passed = -4;

    // An equal but distinct value is a real update: it copies.
    blorp_String* equal_value = blorp_string_create("value");
    dict = blorp_dict_insert(dict, key, equal_value);
    void* out = NULL;
    if (passed == 1 && (dict == holder || dict_storage_refcount(holder) != 1)) passed = -5;
    if (passed == 1 && (!blorp_dict_get_raw(dict, key, &out) || out != (void*)equal_value)) passed = -6;
    if (passed == 1 && (!blorp_dict_get_raw(holder, key, &out) || out != (void*)value)) passed = -7;
    blorp_release(dict);

    // Removing a present key from the shared dict copies too.
    blorp_retain(holder);
    dict = blorp_dict_remove(holder, key);
    if (passed == 1 && (dict == holder || dict->size != 0 || holder->size != 1)) passed = -8;
    blorp_release(dict);

    // Unboxed scalars compare by their stored bits.
    blorp_Dict* ints = blorp_dict_new();
    ints = blorp_dict_insert(ints, DICT_STORAGE_INT(3), DICT_STORAGE_INT(30));
    blorp_Dict* int_holder = ints;
    blorp_retain(int_holder);
    ints = blorp_dict_insert(ints, DICT_STORAGE_INT(3), DICT_STORAGE_INT(30));
    ints = blorp_dict_remove(ints, DICT_STORAGE_INT(4));
    if (passed == 1 && (ints != int_holder || dict_storage_refcount(int_holder) != 2)) passed = -9;
    ints = blorp_dict_insert(ints, DICT_STORAGE_INT(3), DICT_STORAGE_INT(31));
    if (passed == 1 && (ints == int_holder || !dict_storage_has_int(ints, 3, 31)
        || !dict_storage_has_int(int_holder, 3, 30))) passed = -10;

    // A NULL dict is an empty dict on the probe-first paths too.
    blorp_Dict* from_null = blorp_dict_insert(NULL, DICT_STORAGE_INT(5), DICT_STORAGE_INT(50));
    if (passed == 1 && (!from_null || from_null->size != 1 || !dict_storage_has_int(from_null, 5, 50))) passed = -11;
    blorp_Dict* removed_from_null = blorp_dict_remove(NULL, DICT_STORAGE_INT(5));
    if (passed == 1 && (!removed_from_null || removed_from_null->size != 0)) passed = -12;

    blorp_release(removed_from_null);
    blorp_release(from_null);
    blorp_release(ints);
    blorp_release(int_holder);
    blorp_release(equal_value);
    blorp_release(equal_key);
    blorp_release(missing);
    blorp_release(key);
    blorp_release(value);
    blorp_release(holder);
    return passed;
}

#endif
