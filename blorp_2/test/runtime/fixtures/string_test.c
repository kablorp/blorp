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
    if (value == NULL) return;
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

static void test_edge_duplicate_outputs(void) {
    struct blorp_string *source = blorp_int_to_string(INT64_C(17));
    struct blorp_string *first = source;
    struct blorp_string *second = source;
    blorp_string_retain(first);
    blorp_string_retain(second);
    blorp_string_release(source);
    assert(allocation_count == 1 && destruction_count == 0);
    assert(atomic_load(&first->references) == 2);
    assert(strcmp(first->bytes, "17") == 0);
    blorp_string_release(first);
    assert(destruction_count == 0);
    assert(atomic_load(&second->references) == 1);
    assert(strcmp(second->bytes, "17") == 0);
    blorp_string_release(second);
    assert(destruction_count == 1);
}

static void test_edge_swap_outputs(void) {
    struct blorp_string *left = blorp_int_to_string(INT64_C(1));
    struct blorp_string *right = blorp_int_to_string(INT64_C(777));
    struct blorp_string *next_left = right;
    struct blorp_string *next_right = left;
    blorp_string_retain(next_left);
    blorp_string_retain(next_right);
    blorp_string_release(left);
    blorp_string_release(right);
    assert(allocation_count == 2 && destruction_count == 0);
    assert(strcmp(next_left->bytes, "777") == 0);
    assert(strcmp(next_right->bytes, "1") == 0);
    assert(atomic_load(&next_left->references) == 1);
    assert(atomic_load(&next_right->references) == 1);
    blorp_string_release(next_left);
    assert(destruction_count == 1);
    assert(strcmp(next_right->bytes, "1") == 0);
    blorp_string_release(next_right);
    assert(destruction_count == 2);
}

static void test_edge_old_alias(void) {
    struct blorp_string *original = blorp_int_to_string(INT64_C(1));
    struct blorp_string *old_alias = original;
    blorp_string_retain(old_alias);
    struct blorp_string *replacement = blorp_int_to_string(INT64_C(777));
    struct blorp_string *next = replacement;
    blorp_string_retain(next);
    blorp_string_release(replacement);
    blorp_string_release(original);
    assert(allocation_count == 2 && destruction_count == 0);
    assert(strcmp(old_alias->bytes, "1") == 0);
    assert(strcmp(next->bytes, "777") == 0);
    blorp_string_release(old_alias);
    assert(destruction_count == 1);
    assert(strcmp(next->bytes, "777") == 0);
    blorp_string_release(next);
    assert(destruction_count == 2);
}

static void assert_bytes(const struct blorp_string *value, const char *expected, int64_t length) {
    assert(value->length == length);
    assert(blorp_string_length(value) == length);
    assert(memcmp(value->bytes, expected, (size_t)length) == 0);
    assert(value->bytes[length] == '\0');
}

static void test_bytes_empty(void) {
    struct blorp_string *value = blorp_string_from_bytes("", 0);
    assert_bytes(value, "", 0);
    blorp_string_release(value);
}

static void test_bytes_ascii(void) {
    const char expected[] = {'h', 'e', 'l', 'l', 'o'};
    struct blorp_string *value = blorp_string_from_bytes(expected, (int64_t)sizeof expected);
    assert_bytes(value, expected, (int64_t)sizeof expected);
    blorp_string_release(value);
}

static void test_bytes_embedded_nul(void) {
    const char expected[] = {'a', '\0', '9'};
    struct blorp_string *value = blorp_string_from_bytes(expected, (int64_t)sizeof expected);
    assert_bytes(value, expected, (int64_t)sizeof expected);
    blorp_string_release(value);
}

static void test_bytes_escapes(void) {
    const char expected[] = {'\n', '\r', '\t', '\0', '\\', '"', '\'', '{', '}', '?', '?', '/'};
    struct blorp_string *value = blorp_string_from_bytes(expected, (int64_t)sizeof expected);
    assert_bytes(value, expected, (int64_t)sizeof expected);
    blorp_string_release(value);
}

static void test_bytes_utf8_accent(void) {
    /* U+00E9 is one scalar encoded as two bytes. */
    const char expected[] = {(char)0xC3, (char)0xA9};
    struct blorp_string *value = blorp_string_from_bytes(expected, (int64_t)sizeof expected);
    assert_bytes(value, expected, (int64_t)sizeof expected);
    blorp_string_release(value);
}

static void test_bytes_utf8_emoji(void) {
    /* U+1F600 is one scalar encoded as four bytes. */
    const char expected[] = {(char)0xF0, (char)0x9F, (char)0x98, (char)0x80};
    struct blorp_string *value = blorp_string_from_bytes(expected, (int64_t)sizeof expected);
    assert_bytes(value, expected, (int64_t)sizeof expected);
    blorp_string_release(value);
}

static void test_bytes_utf8_mixed_nul(void) {
    const char expected[] = {
        'a', (char)0xC3, (char)0xA9, '\0', (char)0xF0, (char)0x9F, (char)0x98, (char)0x80, '9'
    };
    struct blorp_string *value = blorp_string_from_bytes(expected, (int64_t)sizeof expected);
    assert_bytes(value, expected, (int64_t)sizeof expected);
    blorp_string_release(value);
}

static void test_bytes_independent_roots(void) {
    const char expected[] = {'s', 'a', 'm', 'e'};
    struct blorp_string *first = blorp_string_from_bytes(expected, (int64_t)sizeof expected);
    struct blorp_string *second = blorp_string_from_bytes(expected, (int64_t)sizeof expected);
    assert(first != second);
    assert(allocation_count == 2);
    assert(destruction_count == 0);
    assert_bytes(first, expected, (int64_t)sizeof expected);
    blorp_string_release(first);
    assert(destruction_count == 1);
    assert(atomic_load(&second->references) == 1);
    assert_bytes(second, expected, (int64_t)sizeof expected);
    blorp_string_release(second);
    assert(destruction_count == 2);
}

static void test_bytes_copy_input(void) {
    char input[] = {'a', '\0', '9'};
    const char expected[] = {'a', '\0', '9'};
    struct blorp_string *value = blorp_string_from_bytes(input, (int64_t)sizeof input);
    input[0] = 'z';
    input[1] = '!';
    input[2] = '0';
    assert_bytes(value, expected, (int64_t)sizeof expected);
    blorp_string_release(value);
}

static void test_bytes_initial_reference(void) {
    struct blorp_string *value = blorp_string_from_bytes("7", 1);
    assert(atomic_load(&value->references) == 1);
    assert(allocation_count == 1);
    assert(destruction_count == 0);
    blorp_string_release(value);
}

static void test_bytes_nonfinal_release(void) {
    const char expected[] = {'a', '\0', '9'};
    struct blorp_string *value = blorp_string_from_bytes(expected, (int64_t)sizeof expected);
    blorp_string_retain(value);
    assert(atomic_load(&value->references) == 2);
    blorp_string_release(value);
    assert(atomic_load(&value->references) == 1);
    assert(allocation_count == 1);
    assert(destruction_count == 0);
    assert_bytes(value, expected, (int64_t)sizeof expected);
    blorp_string_release(value);
}

static void test_bytes_final_release(void) {
    struct blorp_string *value = blorp_string_from_bytes("7", 1);
    assert(allocation_count == 1);
    assert(destruction_count == 0);
    blorp_string_release(value);
    /* No access to value after its final release. */
    assert(destruction_count == 1);
}

static void test_bytes_balanced_lifetimes(void) {
    struct blorp_string *first = blorp_string_from_bytes("", 0);
    struct blorp_string *second = blorp_string_from_bytes("other", 5);
    blorp_string_retain(first);
    blorp_string_retain(second);
    blorp_string_retain(second);
    assert(allocation_count == 2);
    blorp_string_release(second);
    blorp_string_release(first);
    blorp_string_release(second);
    assert(destruction_count == 0);
    blorp_string_release(first);
    assert(destruction_count == 1);
    blorp_string_release(second);
    assert(destruction_count == 2);
}

static void test_print_borrow(void) {
    struct blorp_string *value = blorp_string_from_bytes("kept", 4);
    blorp_string_retain(value);
    assert(blorp_string_print(value) == (uint8_t)0);
    assert(atomic_load(&value->references) == 2);
    assert(allocation_count == 1);
    assert(destruction_count == 0);
    blorp_string_release(value);
    assert(blorp_string_print(value) == (uint8_t)0);
    assert(atomic_load(&value->references) == 1);
    assert_bytes(value, "kept", 4);
    blorp_string_release(value);
}

static void test_print_bytes(void) {
    const char bytes[] = { (char)0xc3, (char)0xa9, (char)0xf0, (char)0x9f,
                           (char)0x98, (char)0x80, '\0', '1', '2', '3' };
    struct blorp_string *value = blorp_string_from_bytes(bytes, (int64_t)sizeof bytes);
    assert(blorp_string_print(value) == (uint8_t)0);
    assert_bytes(value, bytes, (int64_t)sizeof bytes);
    blorp_string_release(value);
}

static void test_print_empty(void) {
    struct blorp_string *value = blorp_string_from_bytes("", 0);
    assert(blorp_string_print(value) == (uint8_t)0);
    assert(atomic_load(&value->references) == 1);
    blorp_string_release(value);
}

static void assert_parse(const char *bytes, int64_t length, uint8_t success, int64_t expected) {
    const size_t allocations_before = allocation_count;
    const size_t frees_before = destruction_count;
    struct blorp_string *value = blorp_string_from_bytes(bytes, length);
    blorp_string_retain(value);
    int64_t result = INT64_C(17);
    assert(blorp_string_parse_int(value, &result) == success);
    assert(result == (success ? expected : INT64_C(17)));
    assert_bytes(value, bytes, length);
    assert(atomic_load(&value->references) == 2);
    assert(allocation_count == allocations_before + 1);
    assert(destruction_count == frees_before);
    blorp_string_release(value);
    blorp_string_release(value);
    assert(destruction_count == frees_before + 1);
}

static void test_parse_bounds(void) {
    assert_parse("9223372036854775807", 19, 1, INT64_MAX);
    assert_parse("-9223372036854775808", 20, 1, INT64_MIN);
}

static void test_parse_overflow(void) {
    assert_parse("9223372036854775808", 19, 0, 0);
    assert_parse("-9223372036854775809", 20, 0, 0);
    assert_parse("9999999999999999999999999999999999999999", 40, 0, 0);
}

static void test_parse_signs(void) {
    assert_parse("+00042", 6, 1, INT64_C(42));
    assert_parse("-00042", 6, 1, INT64_C(-42));
    assert_parse("-0", 2, 1, INT64_C(0));
    assert_parse("+0", 2, 1, INT64_C(0));
    assert_parse("+", 1, 0, 0);
    assert_parse("-", 1, 0, 0);
    assert_parse("--1", 3, 0, 0);
    assert_parse("", 0, 0, 0);
}

static void test_parse_counted_bytes(void) {
    const char nul[] = {'4', '2', '\0', '1', '2', '3'};
    const char unicode[] = {(char)0xc3, (char)0xa9};
    assert_parse(nul, (int64_t)sizeof nul, 0, 0);
    assert_parse(unicode, (int64_t)sizeof unicode, 0, 0);
    assert_parse("42suffix", 8, 0, 0);
}

static void test_parse_whitespace(void) {
    assert_parse(" 42", 3, 0, 0);
    assert_parse("42 ", 3, 0, 0);
    assert_parse("42\n", 3, 0, 0);
    assert_parse("\t42", 3, 0, 0);
}

static void assert_equality(const char *left_bytes, int64_t left_length,
                            const char *right_bytes, int64_t right_length,
                            uint8_t expected) {
    const size_t allocations_before = allocation_count;
    const size_t destructions_before = destruction_count;
    struct blorp_string *left = blorp_string_from_bytes(left_bytes, left_length);
    struct blorp_string *right = blorp_string_from_bytes(right_bytes, right_length);
    blorp_string_retain(left);
    blorp_string_retain(right);
    assert(blorp_string_equals(left, right) == expected);
    assert(blorp_string_equals(right, left) == expected);
    assert_bytes(left, left_bytes, left_length);
    assert_bytes(right, right_bytes, right_length);
    assert(atomic_load(&left->references) == 2);
    assert(atomic_load(&right->references) == 2);
    assert(allocation_count == allocations_before + 2);
    assert(destruction_count == destructions_before);
    blorp_string_release(left);
    blorp_string_release(left);
    blorp_string_release(right);
    blorp_string_release(right);
    assert(destruction_count == destructions_before + 2);
}

static void test_equals_nul(void) {
    static const char first[] = {'a', '\0', '1', '2', '3'};
    static const char second[] = {'a', '\0', '1', '2', '4'};
    assert_equality(first, sizeof first, first, sizeof first, 1);
    assert_equality(first, sizeof first, second, sizeof second, 0);
}

static void test_equals_bytes(void) {
    static const char first[] = {(char)0xc3, (char)0xa9, 'x'};
    static const char second[] = {(char)0xc3, (char)0xaa, 'x'};
    assert_equality(first, sizeof first, first, sizeof first, 1);
    assert_equality(first, sizeof first, second, sizeof second, 0);
}

static void assert_byte_at(const char *bytes, int64_t length, int64_t index,
                           uint8_t status, int64_t expected) {
    struct blorp_string *value = blorp_string_from_bytes(bytes, length);
    const size_t allocations_before = allocation_count;
    const size_t destructions_before = destruction_count;
    const int64_t unchanged = -71;
    int64_t result = unchanged;
    assert(blorp_string_byte_at(value, index, &result) == status);
    assert(result == (status ? expected : unchanged));
    assert(atomic_load(&value->references) == 1);
    assert(allocation_count == allocations_before);
    assert(destruction_count == destructions_before);
    assert_bytes(value, bytes, length);
    blorp_string_release(value);
    assert(destruction_count == destructions_before + 1);
}

static void test_byte_at_bounds(void) {
    assert_byte_at("", 0, 0, 0, 0);
    assert_byte_at("a", 1, -1, 0, 0);
    assert_byte_at("a", 1, 1, 0, 0);
    assert_byte_at("a", 1, INT64_MIN, 0, 0);
    assert_byte_at("a", 1, INT64_MAX, 0, 0);
    assert_byte_at("a", 1, INT64_C(4294967296), 0, 0);
}

static void test_byte_at_values(void) {
    const char bytes[] = {(char)0xc3, (char)0xa9, '\0', 'z'};
    assert_byte_at(bytes, sizeof bytes, 0, 1, 195);
    assert_byte_at(bytes, sizeof bytes, 1, 1, 169);
    assert_byte_at(bytes, sizeof bytes, 2, 1, 0);
    assert_byte_at(bytes, sizeof bytes, 3, 1, 122);
}

static void test_from_codepoint_boundaries(void) {
    const struct {
        int64_t scalar;
        unsigned char bytes[4];
        int64_t length;
    } cases[] = {
        {0, {0}, 1}, {0x7f, {0x7f}, 1},
        {0x80, {0xc2, 0x80}, 2}, {0x7ff, {0xdf, 0xbf}, 2},
        {0x800, {0xe0, 0xa0, 0x80}, 3}, {0xd7ff, {0xed, 0x9f, 0xbf}, 3},
        {0xe000, {0xee, 0x80, 0x80}, 3}, {0xfdd0, {0xef, 0xb7, 0x90}, 3},
        {0xfffe, {0xef, 0xbf, 0xbe}, 3}, {0xffff, {0xef, 0xbf, 0xbf}, 3},
        {0x10000, {0xf0, 0x90, 0x80, 0x80}, 4},
        {0x1f600, {0xf0, 0x9f, 0x98, 0x80}, 4},
        {0x10fffe, {0xf4, 0x8f, 0xbf, 0xbe}, 4},
        {0x10ffff, {0xf4, 0x8f, 0xbf, 0xbf}, 4}
    };
    for (size_t index = 0; index < sizeof cases / sizeof cases[0]; index++) {
        const size_t allocations_before = allocation_count;
        const size_t destructions_before = destruction_count;
        struct blorp_string *result = NULL;
        assert(blorp_string_from_codepoint(cases[index].scalar, &result) == 1);
        assert(result != NULL);
        assert_bytes(result, (const char *)cases[index].bytes, cases[index].length);
        assert(atomic_load(&result->references) == 1);
        assert(allocation_count == allocations_before + 1);
        assert(destruction_count == destructions_before);
        blorp_string_release(result);
        assert(destruction_count == destructions_before + 1);
    }
}

static void test_from_codepoint_invalid(void) {
    const int64_t cases[] = {INT64_MIN, -1, 0xd800, 0xdfff, 0x110000, INT64_C(4294967361), INT64_MAX};
    struct blorp_string *sentinel = blorp_string_from_bytes("kept", 4);
    const size_t allocations_before = allocation_count;
    const size_t destructions_before = destruction_count;
    for (size_t index = 0; index < sizeof cases / sizeof cases[0]; index++) {
        struct blorp_string *result = sentinel;
        assert(blorp_string_from_codepoint(cases[index], &result) == 0);
        assert(result == sentinel);
        assert(allocation_count == allocations_before);
        assert(destruction_count == destructions_before);
    }
    assert_bytes(sentinel, "kept", 4);
    blorp_string_release(sentinel);
}

int main(int argc, char **argv) {
    assert(argc == 2);
    if (strcmp(argv[1], "byte_at_bounds") == 0) {
        test_byte_at_bounds();
    } else if (strcmp(argv[1], "byte_at_values") == 0) {
        test_byte_at_values();
    } else if (strcmp(argv[1], "from_codepoint_boundaries") == 0) {
        test_from_codepoint_boundaries();
    } else if (strcmp(argv[1], "from_codepoint_invalid") == 0) {
        test_from_codepoint_invalid();
    } else if (strcmp(argv[1], "equals_empty") == 0) {
        assert_equality("", 0, "", 0, 1);
    } else if (strcmp(argv[1], "equals_same") == 0) {
        assert_equality("same", 4, "same", 4, 1);
    } else if (strcmp(argv[1], "equals_lengths") == 0) {
        assert_equality("same", 4, "same prefix", 11, 0);
    } else if (strcmp(argv[1], "equals_nul") == 0) {
        test_equals_nul();
    } else if (strcmp(argv[1], "equals_bytes") == 0) {
        test_equals_bytes();
    } else if (strcmp(argv[1], "parse_bounds") == 0) {
        test_parse_bounds();
    } else if (strcmp(argv[1], "parse_overflow") == 0) {
        test_parse_overflow();
    } else if (strcmp(argv[1], "parse_signs") == 0) {
        test_parse_signs();
    } else if (strcmp(argv[1], "parse_counted_bytes") == 0) {
        test_parse_counted_bytes();
    } else if (strcmp(argv[1], "parse_whitespace") == 0) {
        test_parse_whitespace();
    } else if (strcmp(argv[1], "print_borrow") == 0) {
        test_print_borrow();
    } else if (strcmp(argv[1], "print_bytes") == 0) {
        test_print_bytes();
    } else if (strcmp(argv[1], "print_empty") == 0) {
        test_print_empty();
    } else if (strcmp(argv[1], "zero") == 0) {
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
    } else if (strcmp(argv[1], "edge_duplicate_outputs") == 0) {
        test_edge_duplicate_outputs();
    } else if (strcmp(argv[1], "edge_swap_outputs") == 0) {
        test_edge_swap_outputs();
    } else if (strcmp(argv[1], "edge_old_alias") == 0) {
        test_edge_old_alias();
    } else if (strcmp(argv[1], "bytes_empty") == 0) {
        test_bytes_empty();
    } else if (strcmp(argv[1], "bytes_ascii") == 0) {
        test_bytes_ascii();
    } else if (strcmp(argv[1], "bytes_embedded_nul") == 0) {
        test_bytes_embedded_nul();
    } else if (strcmp(argv[1], "bytes_escapes") == 0) {
        test_bytes_escapes();
    } else if (strcmp(argv[1], "bytes_utf8_accent") == 0) {
        test_bytes_utf8_accent();
    } else if (strcmp(argv[1], "bytes_utf8_emoji") == 0) {
        test_bytes_utf8_emoji();
    } else if (strcmp(argv[1], "bytes_utf8_mixed_nul") == 0) {
        test_bytes_utf8_mixed_nul();
    } else if (strcmp(argv[1], "bytes_independent_roots") == 0) {
        test_bytes_independent_roots();
    } else if (strcmp(argv[1], "bytes_copy_input") == 0) {
        test_bytes_copy_input();
    } else if (strcmp(argv[1], "bytes_initial_reference") == 0) {
        test_bytes_initial_reference();
    } else if (strcmp(argv[1], "bytes_nonfinal_release") == 0) {
        test_bytes_nonfinal_release();
    } else if (strcmp(argv[1], "bytes_final_release") == 0) {
        test_bytes_final_release();
    } else if (strcmp(argv[1], "bytes_balanced_lifetimes") == 0) {
        test_bytes_balanced_lifetimes();
    } else {
        fprintf(stderr, "unknown String runtime test: %s\n", argv[1]);
        return EXIT_FAILURE;
    }
    assert(allocation_count == destruction_count);
    return EXIT_SUCCESS;
}
