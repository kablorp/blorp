#ifndef BLORP_TEST_DICT_NATIVE_REINSERT_HEADER_H
#define BLORP_TEST_DICT_NATIVE_REINSERT_HEADER_H

static inline long dict_native_reinsert_preserves_order(void) {
    blorp_Dict* dict = blorp_dict_new();
    dict = blorp_dict_insert(dict, (void*)(intptr_t)100, (void*)(intptr_t)100);

    for (long key = 1; key < 16; key++) {
        dict = blorp_dict_insert(dict, (void*)(intptr_t)key, (void*)(intptr_t)key);
        dict = blorp_dict_remove(dict, (void*)(intptr_t)key);
    }

    blorp_Dict* snapshot = dict;
    blorp_retain(snapshot);
    dict = blorp_dict_insert(dict, (void*)(intptr_t)16, (void*)(intptr_t)16);

    long snapshot_slot = snapshot->order[0];
    long first_slot = dict->order[0];
    long second_slot = dict->order[1];
    long passed = snapshot->size == 1
        && snapshot->order_len == 16
        && snapshot->keys[snapshot_slot] == (void*)(intptr_t)100
        && dict->size == 2
        && dict->order_len == 2
        && dict->keys[first_slot] == (void*)(intptr_t)100
        && dict->keys[second_slot] == (void*)(intptr_t)16;

    blorp_release(dict);
    blorp_release(snapshot);
    return passed;
}

#endif
