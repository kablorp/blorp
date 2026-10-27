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

static size_t live_id(void *address) {
    for (size_t index = 0; index < allocations; index++)
        if (observations[index].live && observations[index].address == address) return index;
    abort();
}
static void *observed_allocate(size_t bytes) {
    assert(allocations < OBSERVATION_CAPACITY);
    void *address = blorp_memory_allocate(bytes);
    assert(address != NULL);
    observations[allocations++] = (struct observation){address, bytes, 1};
    return address;
}
static void observed_release(void *address) {
    if (!address) return;
    observations[live_id(address)].live = 0;
    releases++;
    blorp_memory_release(address);
}
static void *observed_resize(void *address, size_t bytes) {
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
    else if (strcmp(argv[1], "bounds") == 0) bounds();
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
    return blorp_memory_finish(0);
}
