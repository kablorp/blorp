#include <assert.h>
#include <inttypes.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static size_t allocation_count;
static size_t destruction_count;

static void *runtime_test_allocate(size_t bytes) {
    void *result = malloc(bytes);
    assert(result != NULL);
    allocation_count += 1;
    return result;
}

static void runtime_test_deallocate(void *value) {
    assert(value != NULL);
    destruction_count += 1;
    free(value);
}

/* Use the exact fragment supplied by string_runtime(), with real allocation
 * and destruction. The aliases affect only this include, never libc headers. */
#define malloc runtime_test_allocate
#define free runtime_test_deallocate
#include "string_runtime.c"
#undef free
#undef malloc

static void assert_decimal(int64_t number, const char *expected, int64_t length) {
    struct blorp_string *value = blorp_int_to_string(number);
    assert(value->length == length);
    assert(blorp_string_length(value) == length);
    assert(strcmp(value->bytes, expected) == 0);
    assert(strlen(value->bytes) == (size_t)length);
    blorp_string_release(value);
}

static void test_initial_reference(void) {
    struct blorp_string *value = blorp_int_to_string(INT64_C(7));
    assert(allocation_count == 1);
    assert(destruction_count == 0);
    assert(atomic_load(&value->references) == 1);
    blorp_string_release(value);
}

static void test_retain(void) {
    struct blorp_string *value = blorp_int_to_string(INT64_C(7));
    blorp_string_retain(value);
    assert(atomic_load(&value->references) == 2);
    assert(allocation_count == 1);
    assert(destruction_count == 0);
    blorp_string_release(value);
    blorp_string_release(value);
}

static void test_nonfinal_release(void) {
    struct blorp_string *value = blorp_int_to_string(INT64_C(-7));
    blorp_string_retain(value);
    blorp_string_release(value);
    assert(atomic_load(&value->references) == 1);
    assert(destruction_count == 0);
    assert(blorp_string_length(value) == 2);
    assert(strcmp(value->bytes, "-7") == 0);
    blorp_string_release(value);
}

static void test_final_release(void) {
    struct blorp_string *value = blorp_int_to_string(INT64_C(7));
    assert(allocation_count == 1);
    assert(destruction_count == 0);
    blorp_string_release(value);
    /* No access to value after its final release. */
    assert(destruction_count == 1);
}

static void test_independent_objects(void) {
    struct blorp_string *first = blorp_int_to_string(INT64_C(7));
    struct blorp_string *second = blorp_int_to_string(INT64_C(-42));
    assert(first != second);
    blorp_string_retain(first);
    assert(atomic_load(&first->references) == 2);
    assert(atomic_load(&second->references) == 1);
    blorp_string_release(first);
    assert(destruction_count == 0);
    blorp_string_release(first);
    assert(destruction_count == 1);
    assert(atomic_load(&second->references) == 1);
    assert(blorp_string_length(second) == 3);
    assert(strcmp(second->bytes, "-42") == 0);
    blorp_string_release(second);
    assert(allocation_count == 2);
    assert(destruction_count == 2);
}

int main(int argc, char **argv) {
    assert(argc == 2);
    if (strcmp(argv[1], "zero") == 0) {
        assert_decimal(INT64_C(0), "0", 1);
    } else if (strcmp(argv[1], "negative") == 0) {
        assert_decimal(INT64_C(-7), "-7", 2);
    } else if (strcmp(argv[1], "minimum") == 0) {
        assert_decimal(INT64_MIN, "-9223372036854775808", 20);
    } else if (strcmp(argv[1], "maximum") == 0) {
        assert_decimal(INT64_MAX, "9223372036854775807", 19);
    } else if (strcmp(argv[1], "initial_reference") == 0) {
        test_initial_reference();
    } else if (strcmp(argv[1], "retain") == 0) {
        test_retain();
    } else if (strcmp(argv[1], "nonfinal_release") == 0) {
        test_nonfinal_release();
    } else if (strcmp(argv[1], "final_release") == 0) {
        test_final_release();
    } else if (strcmp(argv[1], "independent_objects") == 0) {
        test_independent_objects();
    } else {
        fprintf(stderr, "unknown String runtime test: %s\n", argv[1]);
        return EXIT_FAILURE;
    }
    return EXIT_SUCCESS;
}
