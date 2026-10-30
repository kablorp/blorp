#include <assert.h>
#include <signal.h>
#include <stdint.h>
#include <stddef.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include "list_memory.c"

/* Allocation occurrences and resize work are independent observations, even
 * when the production allocator could have returned the same address. */
enum { OBSERVATION_CAPACITY = 256 };
struct observation { void *address; size_t bytes; int live; };
static struct observation observations[OBSERVATION_CAPACITY];
static size_t allocations, releases, resizes, moved_bytes;
/* Synthetic overflow inputs must be rejected before any backing operation. */
static int forbid_storage_operations;

static size_t live_id(void *address) {
    for (size_t index = 0; index < allocations; index++)
        if (observations[index].live && observations[index].address == address) return index;
    abort();
}
static void *observed_allocate(size_t bytes) {
    if (forbid_storage_operations) _Exit(1);
    assert(allocations < OBSERVATION_CAPACITY);
    void *address = blorp_memory_allocate(bytes);
    assert(address != NULL);
    observations[allocations++] = (struct observation){address, bytes, 1};
    return address;
}
static void observed_release(void *address) {
    if (forbid_storage_operations) _Exit(1);
    if (!address) return;
    observations[live_id(address)].live = 0;
    releases++;
    blorp_memory_release(address);
}
static void *observed_resize(void *address, size_t bytes) {
    if (forbid_storage_operations) _Exit(1);
    const size_t previous = observations[live_id(address)].bytes;
    /* Force relocation while the old allocation remains live. */
    void *result = observed_allocate(bytes);
    memcpy(result, address, previous < bytes ? previous : bytes);
    moved_bytes += previous;
    resizes++;
    observed_release(address);
    return result;
}
#undef blorp_memory_allocate
#undef blorp_memory_resize
#undef blorp_memory_release
#define blorp_memory_allocate observed_allocate
#define blorp_memory_resize observed_resize
#define blorp_memory_release observed_release
#include "list_values.c"
#undef blorp_memory_allocate
#undef blorp_memory_resize
#undef blorp_memory_release

static void boundaries(void) {
    const size_t counts[] = {0, 1, 3, 4, 5, 8, 9};
    for (size_t example = 0; example < sizeof counts / sizeof *counts; example++) {
        const size_t count = counts[example];
        struct blorp_l_0_i *root = blorp_list_repeat_0_i(7, (int64_t)count);
        assert(root->capacity == count && root->length == (int64_t)count);
        const size_t before = resizes;
        root = blorp_list_append_take_left_0_i(root, 11);
        const size_t expected = count < 4 ? 4 : count * 2;
        assert(root->capacity == expected && root->length == (int64_t)count + 1);
        assert(resizes == before + 1 && root->values[count] == 11);
        for (size_t index = 0; index < count; index++) assert(root->values[index] == 7);
        blorp_list_drop_0_i(root);
    }
    struct blorp_l_0_i *root = blorp_list_repeat_0_i(0, 0);
    const size_t before = resizes;
    const size_t before_bytes = moved_bytes;
    for (int64_t index = 0; index < 65; index++) {
        const size_t old_capacity = root->capacity;
        const size_t old_resizes = resizes;
        root = blorp_list_append_take_left_0_i(root, index);
        assert(resizes == old_resizes + ((size_t)index == old_capacity));
        for (int64_t slot = 0; slot <= index; slot++) assert(root->values[slot] == slot);
    }
    assert(root->capacity == 128 && resizes == before + 6);
    assert(moved_bytes - before_bytes == 6 * sizeof *root + (4 + 8 + 16 + 32 + 64) * sizeof *root->values);
    blorp_list_drop_0_i(root);
    struct blorp_l_0_i *zero = blorp_list_repeat_0_i(0, 0);
    struct blorp_l_0_i *copy = blorp_list_set_0_i(zero, -1, 4);
    struct blorp_l_0_i *joined = blorp_list_concat_0_i(zero, zero);
    assert(copy->capacity == 0 && copy->length == 0);
    assert(joined->capacity == 0 && joined->length == 0);
    blorp_list_drop_0_i(copy);
    blorp_list_drop_0_i(joined);
    blorp_list_drop_0_i(zero);
    char first[] = "first", second[] = "second";
    char *arguments[] = {first, second};
    struct blorp_l_0_s *empty = blorp_list_from_argv(0, arguments);
    assert(empty->capacity == 0 && empty->length == 0);
    blorp_list_drop_0_s(empty);
    struct blorp_l_0_s *argv = blorp_list_from_argv(2, arguments);
    assert(argv->capacity == 2 && argv->length == 2);
    struct blorp_l_0_s *tail = blorp_list_suffix_0_s(argv, 2);
    assert(tail->capacity == 0 && tail->length == 0);
    blorp_list_drop_0_s(tail);
    blorp_list_drop_0_s(argv);
}
static void strings(void) {
    struct blorp_string *child = blorp_int_to_string(42);
    struct blorp_l_0_s *root = blorp_list_repeat_0_s(child, 4);
    assert(atomic_load(&child->references) == 5);
    root = blorp_list_append_take_left_0_s(root, child);
    assert(root->capacity == 8 && atomic_load(&child->references) == 6);
    const size_t before = allocations;
    root = blorp_list_append_take_left_0_s(root, child);
    assert(allocations == before && atomic_load(&child->references) == 7);
    /* Spare slots are deliberately invalid: destruction must stop at length. */
    root->values[6] = NULL; root->values[7] = NULL;
    blorp_list_drop_0_s(root);
    assert(atomic_load(&child->references) == 1);
    blorp_string_release(child);
}
static void shared(void) {
    struct blorp_string *child = blorp_int_to_string(7);
    struct blorp_l_0_s *old = blorp_list_repeat_0_s(child, 1);
    struct blorp_l_0_s *borrowed = blorp_list_append_0_s(old, child);
    assert(borrowed != old && old->length == 1 && borrowed->length == 2);
    assert(atomic_load(&child->references) == 4);
    blorp_list_drop_0_s(borrowed);
    blorp_list_dup_0_s(old);
    struct blorp_l_0_s *updated = blorp_list_append_take_left_0_s(old, child);
    assert(updated != old && old->length == 1 && old->capacity == 1);
    assert(updated->length == 2 && updated->values[0] == child && updated->values[1] == child);
    assert(atomic_load(&old->references) == 1 && atomic_load(&child->references) == 4);
    blorp_list_drop_0_s(old);
    assert(atomic_load(&child->references) == 3);
    blorp_list_drop_0_s(updated);
    assert(atomic_load(&child->references) == 1);
    blorp_string_release(child);
}
static void nested(void) {
    struct blorp_string *text = blorp_int_to_string(1);
    struct blorp_l_0_s *child = blorp_list_repeat_0_s(text, 1);
    struct blorp_l_1_s *root = blorp_list_repeat_1_s(child, 1);
    root = blorp_list_append_take_left_1_s(root, child);
    assert(atomic_load(&child->references) == 3 && atomic_load(&text->references) == 2);
    blorp_list_drop_1_s(root);
    assert(atomic_load(&child->references) == 1);
    blorp_list_drop_0_s(child);
    blorp_string_release(text);
}
static void inline_slots(void) {
    blorp_r_1 value = {.blorp_rf_1_0 = 9};
    struct blorp_l_0_r1 *root = blorp_list_repeat_0_r1(value, 4);
    root = blorp_list_append_take_left_0_r1(root, value);
    assert(root->capacity == 8 && root->length == 5);
    for (int64_t index = 0; index < 5; index++) assert(root->values[index].blorp_rf_1_0 == 9);
    blorp_list_drop_0_r1(root);
}
static void managed(void) {
    struct blorp_string *text = blorp_int_to_string(9);
    blorp_r_0 entry = observed_allocate(sizeof *entry);
    atomic_init(&entry->references, 1);
    entry->blorp_rf_0_0 = text;
    blorp_string_retain(text);
    struct blorp_l_0_r0 *root = blorp_list_repeat_0_r0(entry, 4);
    root = blorp_list_append_take_left_0_r0(root, entry);
    assert(atomic_load(&entry->references) == 6 && atomic_load(&text->references) == 2);
    blorp_list_drop_0_r0(root);
    assert(atomic_load(&entry->references) == 1);
    blorp_record_drop_0(entry);
    struct blorp_u_0 choice = {.tag = blorp_v_0_0, .payload.blorp_up_0 = {.blorp_uf_0 = text}};
    struct blorp_l_0_u0 *choices = blorp_list_repeat_0_u0(choice, 4);
    choices = blorp_list_append_take_left_0_u0(choices, choice);
    assert(atomic_load(&text->references) == 6);
    blorp_list_drop_0_u0(choices);
    assert(atomic_load(&text->references) == 1);
    blorp_string_release(text);
}
static size_t callable_references, callable_retains, callable_drops;
static int64_t invoke(void *environment) { (void)environment; return 5; }
static void retain(void *environment) { assert(environment == &callable_references); callable_references++; callable_retains++; }
static void drop(void *environment) { assert(environment == &callable_references); assert(callable_references > 0); callable_references--; callable_drops++; }
static void callable(void) {
    const struct blorp_co_p0_r_i_e ops = {invoke, retain, drop};
    struct blorp_c_p0_r_i_e value = {&ops, &callable_references};
    struct blorp_l_0_cp0_r_i_e *root = blorp_list_repeat_0_cp0_r_i_e(value, 4);
    assert(callable_references == 4 && callable_retains == 4 && callable_drops == 0);
    const size_t before = resizes;
    root = blorp_list_append_take_left_0_cp0_r_i_e(root, value);
    assert(resizes == before + 1 && root->capacity == 8);
    assert(callable_references == 5 && callable_retains == 5 && callable_drops == 0);
    root = blorp_list_append_take_left_0_cp0_r_i_e(root, value);
    assert(resizes == before + 1 && root->length == 6);
    assert(callable_references == 6 && callable_retains == 6 && callable_drops == 0);
    assert(root->values[0].ops->invoke(root->values[0].environment) == 5);
    blorp_list_drop_0_cp0_r_i_e(root);
    assert(callable_references == 0 && callable_retains == 6 && callable_drops == 6);
    struct blorp_l_0_v *units = blorp_list_repeat_0_v(0, 4);
    units = blorp_list_append_take_left_0_v(units, 0);
    assert(units->capacity == 8 && units->length == 5);
    blorp_list_drop_0_v(units);
}
static void set_work(void) {
    const struct blorp_co_p0_r_i_e ops = {invoke, retain, drop};
    const struct blorp_c_p0_r_i_e value = {&ops, &callable_references};
    const int64_t counts[] = {1, 64};
    for (size_t sample = 0; sample < sizeof counts / sizeof *counts; sample++) {
        struct blorp_l_0_cp0_r_i_e *root = blorp_list_repeat_0_cp0_r_i_e(value, counts[sample]);
        struct blorp_l_0_cp0_r_i_e *alias = root;
        const size_t before_allocations = allocations, before_resizes = resizes;
        const size_t before_retains = callable_retains, before_drops = callable_drops;
        root = blorp_list_set_take_left_0_cp0_r_i_e(root, counts[sample] - 1, value);
        assert(root == alias && root->length == counts[sample] && root->capacity == (size_t)counts[sample]);
        assert(allocations == before_allocations && resizes == before_resizes);
        assert(callable_retains == before_retains + 1 && callable_drops == before_drops + 1);
        const int64_t invalid[] = {INT64_MIN, -1, counts[sample], INT64_MAX};
        for (size_t index = 0; index < sizeof invalid / sizeof *invalid; index++) {
            root = blorp_list_set_take_left_0_cp0_r_i_e(root, invalid[index], value);
            assert(root == alias && callable_retains == before_retains + 1 && callable_drops == before_drops + 1);
            assert(allocations == before_allocations && resizes == before_resizes);
        }
        for (int64_t index = 0; index < counts[sample]; index++)
            assert(root->values[index].ops == &ops && root->values[index].environment == &callable_references);
        blorp_list_drop_0_cp0_r_i_e(root);
        assert(callable_references == 0 && callable_retains == callable_drops);
    }
}
static void set_equal(void) {
    struct blorp_string *text = blorp_int_to_string(42);
    struct blorp_l_0_s *root = blorp_list_repeat_0_s(text, 1);
    blorp_string_release(text);
    assert(atomic_load(&root->values[0]->references) == 1);
    const size_t before = allocations, before_resizes = resizes;
    root = blorp_list_set_take_left_0_s(root, 0, root->values[0]);
    assert(allocations == before && resizes == before_resizes);
    assert(atomic_load(&root->values[0]->references) == 1);
    assert(root->values[0]->length == 2 && memcmp(root->values[0]->bytes, "42", 2) == 0);
    blorp_list_drop_0_s(root);

    struct blorp_string *old = blorp_int_to_string(1);
    const size_t old_id = live_id(old);
    struct blorp_string *replacement = blorp_int_to_string(2);
    root = blorp_list_repeat_0_s(old, 1);
    blorp_string_release(old);
    root = blorp_list_set_take_left_0_s(root, 0, replacement);
    assert(!observations[old_id].live && root->values[0] == replacement);
    assert(atomic_load(&replacement->references) == 2);
    blorp_string_release(replacement);
    blorp_list_drop_0_s(root);
}
static void update_families(void) {
    struct blorp_l_0_i *ints = blorp_list_repeat_0_i(7, 3);
    ints = blorp_list_set_take_left_0_i(ints, 1, 8);
    struct blorp_l_0_i *right_ints = blorp_list_repeat_0_i(9, 3);
    ints = blorp_list_concat_take_left_0_i(ints, right_ints);
    assert(ints->length == 6 && ints->capacity == 8);
    assert(ints->values[0] == 7 && ints->values[1] == 8 && ints->values[2] == 7);
    for (int64_t index = 3; index < 6; index++) assert(ints->values[index] == 9);
    blorp_list_drop_0_i(ints); blorp_list_drop_0_i(right_ints);

    blorp_r_1 point = {.blorp_rf_1_0 = 9}, other_point = {.blorp_rf_1_0 = 10};
    struct blorp_l_0_r1 *points = blorp_list_repeat_0_r1(point, 1);
    points = blorp_list_set_take_left_0_r1(points, 0, other_point);
    struct blorp_l_0_r1 *right_points = blorp_list_repeat_0_r1(point, 1);
    points = blorp_list_concat_take_left_0_r1(points, right_points);
    assert(points->length == 2 && points->values[0].blorp_rf_1_0 == 10 && points->values[1].blorp_rf_1_0 == 9);
    blorp_list_drop_0_r1(points); blorp_list_drop_0_r1(right_points);

    struct blorp_string *text = blorp_int_to_string(9);
    struct blorp_l_0_s *texts = blorp_list_repeat_0_s(text, 1);
    struct blorp_l_0_s *right_texts = blorp_list_repeat_0_s(text, 1);
    texts = blorp_list_concat_take_left_0_s(texts, right_texts);
    assert(texts->length == 2 && texts->values[0] == text && texts->values[1] == text);
    assert(atomic_load(&text->references) == 4);
    blorp_list_drop_0_s(texts); blorp_list_drop_0_s(right_texts);
    struct blorp_l_0_s *child = blorp_list_repeat_0_s(text, 1);
    struct blorp_l_1_s *nested = blorp_list_repeat_1_s(child, 1);
    nested = blorp_list_set_take_left_1_s(nested, 0, child);
    struct blorp_l_1_s *right_nested = blorp_list_repeat_1_s(child, 1);
    nested = blorp_list_concat_take_left_1_s(nested, right_nested);
    assert(nested->length == 2 && nested->values[0] == child && nested->values[1] == child);
    assert(atomic_load(&child->references) == 4 && atomic_load(&text->references) == 2);
    blorp_list_drop_1_s(nested); blorp_list_drop_1_s(right_nested); blorp_list_drop_0_s(child);

    blorp_r_0 entry = observed_allocate(sizeof *entry);
    atomic_init(&entry->references, 1); entry->blorp_rf_0_0 = text; blorp_string_retain(text);
    struct blorp_l_0_r0 *entries = blorp_list_repeat_0_r0(entry, 1);
    entries = blorp_list_set_take_left_0_r0(entries, 0, entry);
    struct blorp_l_0_r0 *right_entries = blorp_list_repeat_0_r0(entry, 1);
    entries = blorp_list_concat_take_left_0_r0(entries, right_entries);
    assert(entries->length == 2 && atomic_load(&entry->references) == 4);
    blorp_list_drop_0_r0(entries); blorp_list_drop_0_r0(right_entries); blorp_record_drop_0(entry);

    struct blorp_u_0 choice = {.tag = blorp_v_0_0, .payload.blorp_up_0 = {.blorp_uf_0 = text}};
    struct blorp_l_0_u0 *choices = blorp_list_repeat_0_u0(choice, 1);
    choices = blorp_list_set_take_left_0_u0(choices, 0, choice);
    struct blorp_l_0_u0 *right_choices = blorp_list_repeat_0_u0(choice, 1);
    choices = blorp_list_concat_take_left_0_u0(choices, right_choices);
    assert(choices->length == 2 && atomic_load(&text->references) == 4);
    blorp_list_drop_0_u0(choices); blorp_list_drop_0_u0(right_choices);
    assert(atomic_load(&text->references) == 1); blorp_string_release(text);

    struct blorp_l_0_v *units = blorp_list_repeat_0_v(0, 1);
    units = blorp_list_set_take_left_0_v(units, 0, 0);
    struct blorp_l_0_v *right_units = blorp_list_repeat_0_v(0, 1);
    units = blorp_list_concat_take_left_0_v(units, right_units);
    assert(units->length == 2 && units->values[0] == 0 && units->values[1] == 0);
    blorp_list_drop_0_v(units); blorp_list_drop_0_v(right_units);
}
static void concat_work(void) {
    const struct blorp_co_p0_r_i_e ops = {invoke, retain, drop};
    const struct blorp_c_p0_r_i_e value = {&ops, &callable_references};
    for (int grows = 0; grows < 2; grows++) {
        struct blorp_l_0_cp0_r_i_e *left = blorp_list_repeat_0_cp0_r_i_e(value, grows ? 3 : 4);
        if (!grows) left = blorp_list_append_take_left_0_cp0_r_i_e(left, value);
        struct blorp_l_0_cp0_r_i_e *right = blorp_list_repeat_0_cp0_r_i_e(value, 2);
        const int64_t first = left->length;
        const size_t before_allocations = allocations, before_resizes = resizes, before_bytes = moved_bytes;
        const size_t before_retains = callable_retains, before_drops = callable_drops;
        const uintptr_t old_address = (uintptr_t)left;
        const size_t previous_bytes = sizeof *left + left->capacity * sizeof *left->values;
        left = blorp_list_concat_take_left_0_cp0_r_i_e(left, right);
        assert(left->length == first + 2 && left->capacity == 8);
        assert(allocations == before_allocations + (size_t)grows && resizes == before_resizes + (size_t)grows);
        assert(moved_bytes == before_bytes + (grows ? previous_bytes : 0));
        assert(((uintptr_t)left != old_address) == grows);
        assert(callable_retains == before_retains + 2 && callable_drops == before_drops);
        assert(right->length == 2 && atomic_load(&right->references) == 1);
        for (int64_t index = 0; index < left->length; index++) assert(left->values[index].ops == &ops);
        blorp_list_drop_0_cp0_r_i_e(left); blorp_list_drop_0_cp0_r_i_e(right);
        assert(callable_references == 0 && callable_retains == callable_drops);
    }
}
static void updates_shared(void) {
    struct blorp_string *old = blorp_int_to_string(1), *replacement = blorp_int_to_string(2);
    struct blorp_l_0_s *root = blorp_list_repeat_0_s(old, 2);
    struct blorp_l_0_s *borrowed = blorp_list_set_0_s(root, 1, replacement);
    assert(root->values[1] == old && borrowed->values[1] == replacement);
    blorp_list_drop_0_s(borrowed);
    blorp_list_dup_0_s(root);
    struct blorp_l_0_s *updated = blorp_list_set_take_left_0_s(root, 1, replacement);
    assert(updated != root && root->length == 2 && root->values[0] == old && root->values[1] == old);
    assert(atomic_load(&root->references) == 1 && atomic_load(&old->references) == 4);
    assert(updated->values[0] == old && updated->values[1] == replacement && atomic_load(&replacement->references) == 2);
    blorp_list_drop_0_s(updated); blorp_list_drop_0_s(root);
    assert(atomic_load(&old->references) == 1 && atomic_load(&replacement->references) == 1);

    root = blorp_list_repeat_0_s(old, 2);
    borrowed = blorp_list_concat_0_s(root, root);
    assert(borrowed != root && borrowed->length == 4 && root->length == 2);
    blorp_list_drop_0_s(borrowed);
    blorp_list_dup_0_s(root);
    updated = blorp_list_concat_take_left_0_s(root, root);
    assert(updated != root && updated->length == 4 && root->length == 2);
    assert(atomic_load(&root->references) == 1 && atomic_load(&old->references) == 7);
    blorp_list_drop_0_s(updated); blorp_list_drop_0_s(root);
    assert(atomic_load(&old->references) == 1);

    root = blorp_list_repeat_0_s(old, 2); blorp_list_dup_0_s(root);
    updated = blorp_list_set_take_left_0_s(root, -1, replacement);
    assert(updated != root && updated->length == 2 && root->values[0] == old && root->values[1] == old);
    assert(updated->values[0] == old && updated->values[1] == old);
    assert(atomic_load(&root->references) == 1 && atomic_load(&old->references) == 5);
    assert(atomic_load(&replacement->references) == 1);
    blorp_list_drop_0_s(updated); blorp_list_drop_0_s(root);
    blorp_string_release(old); blorp_string_release(replacement);
}
static void updates_empty(void) {
    const struct blorp_co_p0_r_i_e ops = {invoke, retain, drop};
    const struct blorp_c_p0_r_i_e value = {&ops, &callable_references};
    struct blorp_l_0_cp0_r_i_e *empty = blorp_list_repeat_0_cp0_r_i_e(value, 0);
    struct blorp_l_0_cp0_r_i_e *right = blorp_list_repeat_0_cp0_r_i_e(value, 0);
    struct blorp_l_0_cp0_r_i_e *alias = empty;
    const size_t before = allocations, before_resizes = resizes;
    empty = blorp_list_set_take_left_0_cp0_r_i_e(empty, 0, value);
    empty = blorp_list_concat_take_left_0_cp0_r_i_e(empty, right);
    assert(empty == alias && empty->length == 0 && empty->capacity == 0);
    assert(allocations == before && resizes == before_resizes && callable_retains == 0 && callable_drops == 0);
    blorp_list_drop_0_cp0_r_i_e(right);
    right = blorp_list_repeat_0_cp0_r_i_e(value, 2);
    empty = blorp_list_concat_take_left_0_cp0_r_i_e(empty, right);
    assert(empty->length == 2 && empty->capacity == 4 && callable_retains == 4 && callable_drops == 0);
    blorp_list_drop_0_cp0_r_i_e(right);
    right = blorp_list_repeat_0_cp0_r_i_e(value, 0);
    alias = empty;
    const size_t before_empty_right = allocations, before_empty_resizes = resizes;
    const size_t before_retains = callable_retains, before_drops = callable_drops;
    empty = blorp_list_concat_take_left_0_cp0_r_i_e(empty, right);
    assert(empty == alias && allocations == before_empty_right && resizes == before_empty_resizes);
    assert(callable_retains == before_retains && callable_drops == before_drops);
    blorp_list_drop_0_cp0_r_i_e(empty); blorp_list_drop_0_cp0_r_i_e(right);
    assert(callable_references == 0 && callable_retains == callable_drops);

    struct blorp_l_0_i *shared_empty = blorp_list_repeat_0_i(0, 0);
    struct blorp_l_0_i *other_empty = blorp_list_repeat_0_i(0, 0);
    blorp_list_dup_0_i(shared_empty);
    struct blorp_l_0_i *copy = blorp_list_concat_take_left_0_i(shared_empty, other_empty);
    assert(copy != shared_empty && copy->length == 0 && copy->capacity == 0);
    assert(atomic_load(&shared_empty->references) == 1 && atomic_load(&other_empty->references) == 1);
    blorp_list_drop_0_i(copy); blorp_list_drop_0_i(shared_empty); blorp_list_drop_0_i(other_empty);
}
/* `[]` names its layout's immortal root, spelled as the literal emits it;
 * each evaluation is one counted owner. Dup and drop never touch the root,
 * consumed updates copy it, and its untouched count proves no path wrote it. */
#define EMPTY_INTS ((struct blorp_l_0_i *)blorp_list_empty_acquire(&blorp_list_empty_0_i))
#define EMPTY_TEXTS ((struct blorp_l_0_s *)blorp_list_empty_acquire(&blorp_list_empty_0_s))
static void static_empty(void) {
    const size_t before = allocations, before_releases = releases, before_resizes = resizes;
    struct blorp_l_0_i *empty = EMPTY_INTS;
    for (int index = 0; index < 1000; index++) blorp_list_dup_0_i(empty);
    for (int index = 0; index < 1001; index++) blorp_list_drop_0_i(empty);
    assert(allocations == before && releases == before_releases);
    struct blorp_l_0_i *appended = blorp_list_append_take_left_0_i(EMPTY_INTS, 11);
    assert(appended != &blorp_list_empty_0_i && appended->length == 1 && appended->values[0] == 11);
    struct blorp_l_0_i *replaced = blorp_list_set_take_left_0_i(EMPTY_INTS, 0, 5);
    assert(replaced != &blorp_list_empty_0_i && replaced->length == 0);
    struct blorp_l_0_i *joined = blorp_list_concat_take_left_0_i(EMPTY_INTS, appended);
    assert(joined != &blorp_list_empty_0_i && joined != appended && joined->length == 1 && joined->values[0] == 11);
    assert(allocations == before + 3 && resizes == before_resizes);
    blorp_list_drop_0_i(appended); blorp_list_drop_0_i(replaced); blorp_list_drop_0_i(joined);

    struct blorp_string *text = blorp_int_to_string(3);
    struct blorp_l_0_s *texts = blorp_list_append_take_left_0_s(EMPTY_TEXTS, text);
    assert(texts != &blorp_list_empty_0_s && texts->values[0] == text && atomic_load(&text->references) == 2);
    struct blorp_l_0_s *joined_texts = blorp_list_concat_take_left_0_s(EMPTY_TEXTS, texts);
    assert(joined_texts->length == 1 && atomic_load(&text->references) == 3);
    blorp_list_drop_0_s(joined_texts); blorp_list_drop_0_s(texts);
    assert(atomic_load(&text->references) == 1);
    blorp_string_release(text);
    assert(allocations == before + 6 && releases == before_releases + 6);
    assert(blorp_list_empty_0_i.length == 0 && blorp_list_empty_0_i.capacity == 0);
    assert(blorp_list_empty_0_s.length == 0 && blorp_list_empty_0_s.capacity == 0);
    assert(atomic_load(&blorp_list_empty_0_i.references) == 0 && atomic_load(&blorp_list_empty_0_s.references) == 0);
    assert(atomic_load(&blorp_list_empty_owners) == 0);
}
/* An ownership bug on `[]` must still fail the strict exit check. */
static void static_empty_extra_drop(void) {
    struct blorp_l_0_i *empty = EMPTY_INTS;
    blorp_list_drop_0_i(empty); blorp_list_drop_0_i(empty);
}
static void static_empty_missing_drop(void) {
    struct blorp_l_0_i *empty = EMPTY_INTS;
    blorp_list_dup_0_i(empty); blorp_list_drop_0_i(empty);
}
/* Deliberately header-only roots establish overflow rejection before either
 * values[] access or allocation; they are never inspected or destroyed later. */
static void concat_overflow(int length_limit) {
    struct blorp_l_0_i left, right;
    atomic_init(&left.references, 1); atomic_init(&right.references, 1);
    const size_t maximum = (SIZE_MAX - sizeof left) / sizeof *left.values;
    left.length = length_limit ? INT64_MAX : (int64_t)maximum;
    left.capacity = (size_t)left.length; right.length = 1; right.capacity = 1;
    forbid_storage_operations = 1;
    (void)blorp_list_concat_take_left_0_i(&left, &right);
}
static void bounds(void) {
    assert(BLORP_LIST_DEFAULT_CAPACITY == 4);
    assert(blorp_list_capacity(0, 1, 1) == 1);
    assert(blorp_list_capacity(0, 2, 3) == 3);
    assert(blorp_list_capacity(3, 4, 5) == 4);
    assert(blorp_list_capacity(4, 5, 5) == 5);
    assert(blorp_list_capacity(4, 5, 9) == 8);
    assert(blorp_list_capacity(8, 9, 9) == 9);
    const size_t maximum = SIZE_MAX < (uintmax_t)INT64_MAX ? SIZE_MAX : (size_t)INT64_MAX;
    assert(blorp_list_capacity(maximum / 2 + 1, maximum, maximum) == maximum);
}
enum { EXPECTED_CAPACITY_ABORT = 73 };
static void capacity_aborted(int signal_number) {
    _Exit(signal_number == SIGABRT ? EXPECTED_CAPACITY_ABORT : 1);
}
int main(int argc, char **argv) {
    assert(argc == 2);
    blorp_memory_start();
    if (strcmp(argv[1], "boundaries") == 0) boundaries();
    else if (strcmp(argv[1], "strings") == 0) strings();
    else if (strcmp(argv[1], "shared") == 0) shared();
    else if (strcmp(argv[1], "nested") == 0) nested();
    else if (strcmp(argv[1], "inline") == 0) inline_slots();
    else if (strcmp(argv[1], "managed") == 0) managed();
    else if (strcmp(argv[1], "callable") == 0) callable();
    else if (strcmp(argv[1], "set-work") == 0) set_work();
    else if (strcmp(argv[1], "set-equal") == 0) set_equal();
    else if (strcmp(argv[1], "update-families") == 0) update_families();
    else if (strcmp(argv[1], "concat-work") == 0) concat_work();
    else if (strcmp(argv[1], "updates-shared") == 0) updates_shared();
    else if (strcmp(argv[1], "updates-empty") == 0) updates_empty();
    else if (strcmp(argv[1], "static-empty") == 0) static_empty();
    else if (strcmp(argv[1], "static-empty-extra-drop") == 0) static_empty_extra_drop();
    else if (strcmp(argv[1], "static-empty-missing-drop") == 0) static_empty_missing_drop();
    else if (strcmp(argv[1], "bounds") == 0) bounds();
    else if (strcmp(argv[1], "concat-length-overflow") == 0 || strcmp(argv[1], "concat-byte-overflow") == 0) {
        if (signal(SIGABRT, capacity_aborted) == SIG_ERR) return 1;
        concat_overflow(strcmp(argv[1], "concat-length-overflow") == 0);
        return 1;
    }
    else if (strcmp(argv[1], "required-overflow") == 0) {
        if (signal(SIGABRT, capacity_aborted) == SIG_ERR) return 1;
        (void)blorp_list_capacity(0, 2, 1);
        return 1;
    }
    else if (strcmp(argv[1], "current-overflow") == 0) {
        if (signal(SIGABRT, capacity_aborted) == SIG_ERR) return 1;
        (void)blorp_list_capacity(2, 1, 1);
        return 1;
    }
    else abort();
    assert(allocations == releases);
    return blorp_memory_finish(blorp_list_empty_finish(0));
}
