#include <assert.h>
#include <inttypes.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Observe allocation occurrences independently, including when malloc reuses
 * an address. After release, assertions read the observation, never the root. */
enum { MAX_ALLOCATION_OCCURRENCES = 128 };
struct Allocation { void *pointer; int live; };
static struct Allocation allocations[MAX_ALLOCATION_OCCURRENCES];
static size_t allocation_count, live_count, free_count;

static void *observed_malloc(size_t bytes) {
    void *pointer = malloc(bytes);
    assert(pointer && allocation_count < MAX_ALLOCATION_OCCURRENCES);
    allocations[allocation_count++] = (struct Allocation){pointer, 1};
    live_count++;
    return pointer;
}

static void observed_free(void *pointer) {
    assert(pointer);
    for (size_t cursor = allocation_count; cursor > 0; cursor--) {
        struct Allocation *allocation = &allocations[cursor - 1];
        if (allocation->live && allocation->pointer == pointer) {
            allocation->live = 0;
            live_count--;
            free_count++;
            free(pointer);
            return;
        }
    }
    abort();
}

#define malloc observed_malloc
#define free observed_free
#include "string_concat_runtime.c"
#undef free
#undef malloc

static void assert_bytes(const struct blorp_string *text, const char *bytes, int64_t length) {
    assert(text->length == length);
    assert(memcmp(text->bytes, bytes, (size_t)length) == 0);
    assert(text->bytes[length] == '\0');
    assert(atomic_load(&text->references) == 1);
    assert(blorp_utf8_is_valid(text->bytes, (size_t)length));
}

static void concat_case(const char *left_bytes, int64_t left_length,
                        const char *right_bytes, int64_t right_length,
                        const char *expected, int64_t expected_length) {
    struct blorp_string *left = blorp_string_from_bytes(left_bytes, left_length);
    struct blorp_string *right = blorp_string_from_bytes(right_bytes, right_length);
    const size_t result_occurrence = allocation_count;
    struct blorp_string *result = blorp_string_concat(left, right);
    assert(allocation_count == result_occurrence + 1 && live_count == 3);
    assert_bytes(left, left_bytes, left_length);
    assert_bytes(right, right_bytes, right_length);
    assert_bytes(result, expected, expected_length);
    blorp_string_release(left);
    blorp_string_release(right);
    assert(!allocations[0].live && !allocations[1].live);
    assert(allocations[result_occurrence].live && live_count == 1);
    assert_bytes(result, expected, expected_length);
    blorp_string_release(result);
    assert(!allocations[result_occurrence].live);
}

static void concat_alias(void) {
    const char bytes[] = {'a', '\0', (char)0xc3, (char)0xa9};
    const char expected[] = {'a', '\0', (char)0xc3, (char)0xa9,
                             'a', '\0', (char)0xc3, (char)0xa9};
    struct blorp_string *source = blorp_string_from_bytes(bytes, sizeof bytes);
    struct blorp_string *result = blorp_string_concat(source, source);
    assert(allocation_count == 2 && live_count == 2);
    assert_bytes(source, bytes, sizeof bytes);
    assert_bytes(result, expected, sizeof expected);
    blorp_string_release(result);
    assert(!allocations[1].live && allocations[0].live);
    assert_bytes(source, bytes, sizeof bytes);
    blorp_string_release(source);
}

int main(int argc, char **argv) {
    assert(argc == 2);
    const char *name = argv[1];
    if (strcmp(name, "concat_empty") == 0) concat_case("", 0, "", 0, "", 0);
    else if (strcmp(name, "concat_left_empty") == 0) concat_case("", 0, "right", 5, "right", 5);
    else if (strcmp(name, "concat_right_empty") == 0) concat_case("left", 4, "", 0, "left", 4);
    else if (strcmp(name, "concat_ascii") == 0) concat_case("left", 4, "right", 5, "leftright", 9);
    else if (strcmp(name, "concat_utf8") == 0) concat_case("\xc3\xa9", 2, "\xf0\x9f\x98\x80", 4, "\xc3\xa9\xf0\x9f\x98\x80", 6);
    else if (strcmp(name, "concat_nul") == 0) concat_case("a\0b", 3, "\0z", 2, "a\0b\0z", 5);
    else if (strcmp(name, "concat_normalization") == 0) concat_case("\xc3\xa9", 2, "e\xcc\x81", 3, "\xc3\xa9" "e\xcc\x81", 5);
    else if (strcmp(name, "concat_alias") == 0) concat_alias();
    else abort();
    assert(live_count == 0 && allocation_count == free_count);
    return 0;
}
