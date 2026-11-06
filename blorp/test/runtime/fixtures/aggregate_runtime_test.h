#ifndef BLORP_AGGREGATE_RUNTIME_TEST_H
#define BLORP_AGGREGATE_RUNTIME_TEST_H

#include <assert.h>
#include <inttypes.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Each named case runs in a fresh process and allocates at most eight objects.
 * This fixed capacity is test-local, not a runtime facility. */
enum { RECORD_TEST_ALLOCATION_CAPACITY = 16 };

struct allocation_observation {
    uintptr_t address;
    size_t destruction_count;
};

static struct allocation_observation observations[RECORD_TEST_ALLOCATION_CAPACITY];
static size_t allocation_count;
static size_t destruction_count;

static void *runtime_test_allocate(size_t bytes) {
    assert(allocation_count < RECORD_TEST_ALLOCATION_CAPACITY);
    void *result = malloc(bytes);
    assert(result != NULL);
    observations[allocation_count].address = (uintptr_t)result;
    observations[allocation_count].destruction_count = 0;
    allocation_count += 1;
    return result;
}

/* IDs are allocation occurrences. A later malloc may reuse an old address;
 * selecting only a live occurrence keeps those IDs distinct. */
static size_t runtime_test_allocation_id(const void *value) {
    const uintptr_t address = (uintptr_t)value;
    for (size_t index = 0; index < allocation_count; index += 1) {
        if (observations[index].address == address &&
            observations[index].destruction_count == 0) {
            return index;
        }
    }
    assert(0 && "object must identify a live test allocation");
    abort();
}

static void runtime_test_deallocate(void *value) {
    if (value == NULL) return;
    const size_t id = runtime_test_allocation_id(value);
    observations[id].destruction_count += 1;
    destruction_count += 1;
    free(value);
}

/* Both includes must be written by the Blorp TestSuite from the same pure
 * production emission functions used by normal compilation. No generated
 * language function or language main is included or called here. */
#define malloc runtime_test_allocate
#define free runtime_test_deallocate
#include "string_runtime.c"
#include "record_runtime.c"
#undef free
#undef malloc

static void assert_frees(size_t id, size_t expected) {
    assert(id < allocation_count);
    assert(observations[id].destruction_count == expected);
}

static void assert_text(const struct blorp_string *value,
                        const char *expected, int64_t length) {
    assert(value->length == length);
    assert(blorp_string_length(value) == length);
    assert(memcmp(value->bytes, expected, (size_t)length) == 0);
    assert(value->bytes[length] == '\0');
}

#endif
