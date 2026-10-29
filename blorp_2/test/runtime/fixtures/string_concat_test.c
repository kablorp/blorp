#include <assert.h>
#include <inttypes.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>

/* Observe allocation occurrences independently, including when malloc reuses
 * an address. After release, assertions read the observation, never the root. */
enum { MAX_ALLOCATION_OCCURRENCES = 128 };
struct Allocation { void *pointer; size_t bytes; int live; };
static struct Allocation allocations[MAX_ALLOCATION_OCCURRENCES];
static size_t allocation_count, live_count, free_count;
static size_t resize_count, resized_bytes;

static void *observed_malloc(size_t bytes) {
    void *pointer = malloc(bytes);
    assert(pointer && allocation_count < MAX_ALLOCATION_OCCURRENCES);
    allocations[allocation_count++] = (struct Allocation){pointer, bytes, 1};
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

/* Allocate before freeing so every resize relocates. Observations refer to
 * occurrences; neither tests nor this wrapper inspect a retired allocation. */
static void *observed_realloc(void *pointer, size_t bytes) {
    for (size_t cursor = allocation_count; cursor > 0; cursor--) {
        const struct Allocation allocation = allocations[cursor - 1];
        if (allocation.live && allocation.pointer == pointer) {
            void *result = observed_malloc(bytes);
            const size_t copied = allocation.bytes < bytes ? allocation.bytes : bytes;
            memcpy(result, pointer, copied);
            resized_bytes += copied;
            resize_count++;
            observed_free(pointer);
            return result;
        }
    }
    abort();
}

#define malloc observed_malloc
#define realloc observed_realloc
#define free observed_free
#include "string_concat_runtime.c"
#undef free
#undef malloc
#undef realloc

static void assert_bytes(const struct blorp_string *text, const char *bytes, int64_t length) {
    assert(text->length == length);
    assert(text->capacity >= (size_t)length);
    assert(text->capacity <= blorp_string_maximum_capacity());
    assert(memcmp(text->bytes, bytes, (size_t)length) == 0);
    assert(text->bytes[length] == '\0');
    assert(atomic_load(&text->references) == 1);
    assert(blorp_utf8_is_valid(text->bytes, (size_t)length));
}

/* Every String owns at least BLORP_STRING_MINIMUM_CAPACITY bytes. */
static size_t expected_capacity(int64_t length) {
    return (size_t)length < BLORP_STRING_MINIMUM_CAPACITY ? BLORP_STRING_MINIMUM_CAPACITY : (size_t)length;
}

static void concat_case(const char *left_bytes, int64_t left_length,
                        const char *right_bytes, int64_t right_length,
                        const char *expected, int64_t expected_length) {
    struct blorp_string *left = blorp_string_from_bytes(left_bytes, left_length);
    struct blorp_string *right = blorp_string_from_bytes(right_bytes, right_length);
    const size_t result_occurrence = allocation_count;
    struct blorp_string *result = blorp_string_concat(left, right);
    assert(left->capacity == expected_capacity(left_length));
    assert(right->capacity == expected_capacity(right_length));
    assert(result->capacity == expected_capacity(expected_length));
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

static void take_left_bytes(const char *prefix, int64_t prefix_length,
                            const char *suffix, int64_t suffix_length,
                            const char *expected, int64_t length) {
    struct blorp_string *left = blorp_string_from_bytes(prefix, prefix_length);
    struct blorp_string *right = blorp_string_from_bytes(suffix, suffix_length);
    const size_t calls = allocation_count, resizes = resize_count;
    const int grows = (size_t)length > left->capacity;
    struct blorp_string *result = blorp_string_concat_take_left(left, right);
    assert(resize_count == resizes + grows);
    assert(allocation_count == calls + grows);
    assert_bytes(result, expected, length);
    assert_bytes(right, suffix, suffix_length);
    blorp_string_release(right);
    blorp_string_release(result);
}

static void take_left_spare_capacity(void) {
    struct blorp_string *value = blorp_string_from_bytes("abc", 3);
    struct blorp_string *suffix = blorp_string_from_bytes("z", 1);
    value = blorp_string_concat_take_left(value, suffix);
    assert(value->capacity > (size_t)value->length);
    const size_t calls = allocation_count, resizes = resize_count;
    const size_t current_occurrence = allocation_count - 1;
    value = blorp_string_concat_take_left(value, suffix);
    assert(allocation_count == calls && resize_count == resizes);
    assert(allocations[current_occurrence].live);
    assert_bytes(value, "abczz", 5);
    blorp_string_release(suffix);
    blorp_string_release(value);
}

static void take_left_shared(int same_root) {
    struct blorp_string *source = blorp_string_from_bytes("ab", 2);
    struct blorp_string *right = same_root ? source : blorp_string_from_bytes("z", 1);
    blorp_string_retain(source);
    const size_t calls = allocation_count, resizes = resize_count;
    struct blorp_string *result = blorp_string_concat_take_left(source, right);
    assert(allocation_count == calls + 1 && resize_count == resizes);
    assert_bytes(source, "ab", 2); /* The transferred reference was released. */
    assert_bytes(result, same_root ? "abab" : "abz", same_root ? 4 : 3);
    if (!same_root) blorp_string_release(right);
    blorp_string_release(source);
    assert_bytes(result, same_root ? "abab" : "abz", same_root ? 4 : 3);
    blorp_string_release(result);
}

static void take_left_geometric_growth(void) {
    /* From the 32-byte minimum, doubling to 4096 bytes resizes 7 times. */
    enum { APPENDS = 4096, MAX_RESIZES = 7 };
    struct blorp_string *value = blorp_string_from_bytes("", 0);
    struct blorp_string *suffix = blorp_string_from_bytes("x", 1);
    for (int64_t index = 0; index < APPENDS; index++) {
        const size_t old_capacity = value->capacity, calls = allocation_count;
        value = blorp_string_concat_take_left(value, suffix);
        assert(value->length == index + 1);
        assert(value->bytes[index] == 'x' && value->bytes[index + 1] == '\0');
        if ((size_t)index < old_capacity) assert(allocation_count == calls);
        else assert(value->capacity == 2 * old_capacity);
    }
    assert(resize_count == MAX_RESIZES);
    /* Forced relocation copies each old allocation, including fixed metadata.
     * The geometric series of prefixes stays below twice the final length. */
    assert(resized_bytes < 2 * APPENDS + MAX_RESIZES *
           (sizeof(struct blorp_string) + 1 + sizeof(max_align_t)));
    for (int64_t index = 0; index < APPENDS; index++) assert(value->bytes[index] == 'x');
    assert(blorp_utf8_is_valid(value->bytes, (size_t)value->length));
    blorp_string_release(suffix);
    blorp_string_release(value);
}

static void overflow_is_rejected(void) {
    for (int scenario = 0; scenario < 3; scenario++) {
        const pid_t child = fork();
        assert(child >= 0);
        if (child == 0) {
            if (scenario == 0) (void)blorp_string_from_bytes("", -1);
            struct blorp_string left = {0}, right = {0};
            atomic_init(&left.references, 1);
            left.length = INT64_MAX;
            right.length = 1;
            if (scenario == 1) (void)blorp_string_concat(&left, &right);
            else (void)blorp_string_concat_take_left(&left, &right);
            _Exit(EXIT_FAILURE);
        }
        int status;
        assert(waitpid(child, &status, 0) == child);
        assert(WIFSIGNALED(status) && WTERMSIG(status) == SIGABRT);
    }
}

static void append_int_borrowed(const char *prefix, int64_t prefix_length,
                                int64_t number, const char *expected, int64_t length) {
    struct blorp_string *source = blorp_string_from_bytes(prefix, prefix_length);
    const size_t calls = allocation_count, resizes = resize_count;
    struct blorp_string *result = blorp_string_append_int(source, number);
    assert(allocation_count == calls + 1 && resize_count == resizes);
    assert_bytes(source, prefix, prefix_length);
    assert_bytes(result, expected, length);
    blorp_string_release(source);
    assert_bytes(result, expected, length);
    blorp_string_release(result);
}

static void append_int_limits(void) {
    const int64_t values[] = {0, -7, INT64_MIN, INT64_MAX};
    const char *expected[] = {"0", "-7", "-9223372036854775808", "9223372036854775807"};
    const int64_t lengths[] = {1, 2, 20, 19};
    for (size_t index = 0; index < sizeof values / sizeof values[0]; index++) {
        append_int_borrowed("", 0, values[index], expected[index], lengths[index]);
        struct blorp_string *value = blorp_string_from_bytes("", 0);
        const size_t calls = allocation_count, resizes = resize_count;
        value = blorp_string_append_int_take_left(value, values[index]);
        assert(allocation_count == calls && resize_count == resizes);
        assert_bytes(value, expected[index], lengths[index]);
        blorp_string_release(value);
    }
}

static void append_int_shared(void) {
    struct blorp_string *source = blorp_string_from_bytes("prefix=", 7);
    blorp_string_retain(source);
    const size_t calls = allocation_count, resizes = resize_count;
    struct blorp_string *result = blorp_string_append_int_take_left(source, -42);
    assert(allocation_count == calls + 1 && resize_count == resizes);
    assert_bytes(source, "prefix=", 7);
    assert_bytes(result, "prefix=-42", 10);
    blorp_string_release(source);
    assert_bytes(result, "prefix=-42", 10);
    blorp_string_release(result);
}

static void append_int_utf8_nul(void) {
    append_int_borrowed("\xc3\xa9\0", 3, -42, "\xc3\xa9\0-42", 6);
    struct blorp_string *value = blorp_string_from_bytes("\xc3\xa9\0", 3);
    const size_t calls = allocation_count, resizes = resize_count;
    value = blorp_string_append_int_take_left(value, -42);
    assert(allocation_count == calls && resize_count == resizes);
    assert_bytes(value, "\xc3\xa9\0-42", 6);
    blorp_string_release(value);
}

static void append_int_spare_capacity(void) {
    struct blorp_string *value = blorp_string_from_bytes("abc", 3);
    struct blorp_string *suffix = blorp_string_from_bytes("z", 1);
    value = blorp_string_concat_take_left(value, suffix);
    blorp_string_release(suffix);
    assert(value->capacity > (size_t)value->length);
    const size_t calls = allocation_count, resizes = resize_count;
    value = blorp_string_append_int_take_left(value, 7);
    assert(allocation_count == calls && resize_count == resizes);
    assert_bytes(value, "abcz7", 5);
    blorp_string_release(value);
}

static void append_int_geometric_growth(void) {
    /* From the 32-byte minimum, doubling to 4096 bytes resizes 7 times. */
    enum { APPENDS = 4096, MAX_RESIZES = 7 };
    struct blorp_string *value = blorp_string_from_bytes("", 0);
    const size_t calls = allocation_count;
    for (int64_t index = 0; index < APPENDS; index++) {
        value = blorp_string_append_int_take_left(value, 7);
        assert(value->length == index + 1 && value->bytes[index + 1] == '\0');
    }
    assert(resize_count == MAX_RESIZES && allocation_count == calls + MAX_RESIZES);
    assert(resized_bytes < 2 * APPENDS + MAX_RESIZES *
           (sizeof(struct blorp_string) + 1 + sizeof(max_align_t)));
    for (int64_t index = 0; index < APPENDS; index++) assert(value->bytes[index] == '7');
    blorp_string_release(value);
}

static void append_int_overflow_is_rejected(void) {
    for (int scenario = 0; scenario < 4; scenario++) {
        const pid_t child = fork();
        assert(child >= 0);
        if (child == 0) {
            struct blorp_string prefix = {0};
            atomic_init(&prefix.references, 1);
            prefix.length = scenario < 2 ? INT64_MAX : -1;
            if (scenario % 2 == 0) (void)blorp_string_append_int(&prefix, 7);
            else (void)blorp_string_append_int_take_left(&prefix, 7);
            _Exit(EXIT_FAILURE);
        }
        int status;
        assert(waitpid(child, &status, 0) == child);
        assert(WIFSIGNALED(status) && WTERMSIG(status) == SIGABRT);
    }
}

int main(int argc, char **argv) {
    blorp_memory_start();
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
    else if (strcmp(name, "take_empty") == 0) take_left_bytes("", 0, "", 0, "", 0);
    else if (strcmp(name, "take_left_empty") == 0) take_left_bytes("", 0, "right", 5, "right", 5);
    else if (strcmp(name, "take_right_empty") == 0) take_left_bytes("left", 4, "", 0, "left", 4);
    else if (strcmp(name, "take_utf8_nul") == 0) take_left_bytes("\xc3\xa9\0", 3, "\xf0\x9f\x98\x80", 4, "\xc3\xa9\0\xf0\x9f\x98\x80", 7);
    else if (strcmp(name, "take_grows_past_minimum") == 0) take_left_bytes("0123456789012345678901234567890", 31, "abc", 3, "0123456789012345678901234567890abc", 34);
    else if (strcmp(name, "take_spare_capacity") == 0) take_left_spare_capacity();
    else if (strcmp(name, "take_shared") == 0) take_left_shared(0);
    else if (strcmp(name, "take_shared_alias") == 0) take_left_shared(1);
    else if (strcmp(name, "take_geometric_growth") == 0) take_left_geometric_growth();
    else if (strcmp(name, "overflow") == 0) overflow_is_rejected();
    else if (strcmp(name, "append_int_borrowed") == 0) append_int_borrowed("prefix=", 7, 42, "prefix=42", 9);
    else if (strcmp(name, "append_int_limits") == 0) append_int_limits();
    else if (strcmp(name, "append_int_utf8_nul") == 0) append_int_utf8_nul();
    else if (strcmp(name, "append_int_shared") == 0) append_int_shared();
    else if (strcmp(name, "append_int_spare") == 0) append_int_spare_capacity();
    else if (strcmp(name, "append_int_growth") == 0) append_int_geometric_growth();
    else if (strcmp(name, "append_int_overflow") == 0) append_int_overflow_is_rejected();
    else abort();
    assert(live_count == 0 && allocation_count == free_count);
    return blorp_memory_finish(0);
}
