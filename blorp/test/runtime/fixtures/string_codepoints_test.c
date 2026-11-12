#include <assert.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* The exact fragments string_runtime() and STRING_SLICE_RUNTIME supply, after
 * MEMORY_RUNTIME, built with memory diagnostics so every release recounts. */
#include "string_codepoints_runtime.c"

/* "h", U+00E9, "llo ", U+1F600: 11 bytes, 7 code points. */
static const char mixed[] = "h\xc3\xa9llo \xf0\x9f\x98\x80";
enum { MIXED_BYTES = 11, MIXED_CODE_POINTS = 7 };

static struct blorp_string *text(const char *bytes, int64_t length) {
    return blorp_string_from_bytes(bytes, length);
}

/* The bytes, both counts and the trailing NUL of a live String. */
static void assert_text(const struct blorp_string *value, const char *bytes, int64_t length,
                        int64_t code_points) {
    assert(value->length == length);
    assert(value->code_points == code_points);
    assert(memcmp(value->bytes, bytes, (size_t)length) == 0);
    assert(value->bytes[length] == '\0');
}

static void assert_lengths(const char *bytes, int64_t length, int64_t code_points) {
    struct blorp_string *value = text(bytes, length);
    assert(blorp_string_byte_length(value) == length);
    assert(blorp_string_codepoint_length(value) == code_points);
    blorp_string_release(value);
}

static void lengths(void) {
    assert_lengths("", 0, 0);
    assert_lengths("abc", 3, 3);
    assert_lengths(mixed, MIXED_BYTES, MIXED_CODE_POINTS);
    /* U+20AC, NUL and U+00E9: NUL is one ASCII code point. */
    assert_lengths("\xe2\x82\xac\0\xc3\xa9", 6, 3);
}

static void assert_codepoint_at(const struct blorp_string *value, int64_t index, uint8_t found,
                                int64_t expected) {
    const int64_t unchanged = -71;
    int64_t result = unchanged;
    assert(blorp_string_codepoint_at(value, index, &result) == found);
    assert(result == (found ? expected : unchanged));
}

static void codepoint_at(void) {
    struct blorp_string *ascii = text("abc", 3);
    assert_codepoint_at(ascii, 0, 1, 'a');
    assert_codepoint_at(ascii, 2, 1, 'c');
    assert_codepoint_at(ascii, 3, 0, 0);
    assert_codepoint_at(ascii, -1, 0, 0);
    assert_codepoint_at(ascii, INT64_MIN, 0, 0);
    assert_codepoint_at(ascii, INT64_MAX, 0, 0);
    blorp_string_release(ascii);

    /* One scalar of each UTF-8 width: 1, 2, 3 and 4 bytes. */
    struct blorp_string *widths = text("a\xc3\xa9\xe2\x82\xac\xf0\x9f\x98\x80", 10);
    assert_codepoint_at(widths, 0, 1, 0x61);
    assert_codepoint_at(widths, 1, 1, 0xe9);
    assert_codepoint_at(widths, 2, 1, 0x20ac);
    assert_codepoint_at(widths, 3, 1, 0x1f600);
    assert_codepoint_at(widths, 4, 0, 0);
    blorp_string_release(widths);

    /* The largest scalar and NUL. */
    struct blorp_string *edges = text("\xf4\x8f\xbf\xbf\0", 5);
    assert_codepoint_at(edges, 0, 1, 0x10ffff);
    assert_codepoint_at(edges, 1, 1, 0);
    blorp_string_release(edges);

    struct blorp_string *empty = text("", 0);
    assert_codepoint_at(empty, 0, 0, 0);
    blorp_string_release(empty);
}

/* The slice is a fresh unique String with both counts; the source is unchanged. */
static void assert_codepoint_slice(const struct blorp_string *source, int64_t start, int64_t end,
                                   const char *bytes, int64_t length, int64_t code_points) {
    struct blorp_string *result = blorp_string_codepoint_slice(source, start, end);
    assert(result != source);
    assert(atomic_load(&result->references) == 1);
    assert(atomic_load(&source->references) == 1);
    assert_text(result, bytes, length, code_points);
    blorp_string_release(result);
}

static void codepoint_slice(void) {
    struct blorp_string *ascii = text("hello", 5);
    assert_codepoint_slice(ascii, 1, 3, "el", 2, 2);
    assert_codepoint_slice(ascii, -5, 2, "he", 2, 2);
    assert_codepoint_slice(ascii, 3, 100, "lo", 2, 2);
    assert_codepoint_slice(ascii, INT64_MIN, INT64_MAX, "hello", 5, 5);
    assert_codepoint_slice(ascii, 4, 2, "", 0, 0);
    assert_codepoint_slice(ascii, 5, 5, "", 0, 0);
    assert_codepoint_slice(ascii, 9, 12, "", 0, 0);
    assert_text(ascii, "hello", 5, 5);
    blorp_string_release(ascii);

    struct blorp_string *source = text(mixed, MIXED_BYTES);
    assert_codepoint_slice(source, 0, 2, "h\xc3\xa9", 3, 2);
    assert_codepoint_slice(source, 1, 2, "\xc3\xa9", 2, 1);
    assert_codepoint_slice(source, 2, 6, "llo ", 4, 4);
    assert_codepoint_slice(source, 6, 7, "\xf0\x9f\x98\x80", 4, 1);
    assert_codepoint_slice(source, -3, 100, mixed, MIXED_BYTES, MIXED_CODE_POINTS);
    assert_codepoint_slice(source, 4, 2, "", 0, 0);
    assert_codepoint_slice(source, 7, 7, "", 0, 0);
    assert_codepoint_slice(source, INT64_MAX, INT64_MIN, "", 0, 0);
    assert_text(source, mixed, MIXED_BYTES, MIXED_CODE_POINTS);
    blorp_string_release(source);

    struct blorp_string *empty = text("", 0);
    assert_codepoint_slice(empty, 0, 0, "", 0, 0);
    assert_codepoint_slice(empty, -1, 1, "", 0, 0);
    blorp_string_release(empty);
}

static void assert_byte_slice(const struct blorp_string *source, int64_t start, int64_t end,
                              uint8_t found, const char *bytes, int64_t length,
                              int64_t code_points) {
    struct blorp_string *result = NULL;
    assert(blorp_string_byte_slice(source, start, end, &result) == found);
    if (!found) {
        assert(result == NULL);
        return;
    }
    assert_text(result, bytes, length, code_points);
    blorp_string_release(result);
}

static void byte_slice(void) {
    struct blorp_string *ascii = text("abc", 3);
    assert_byte_slice(ascii, 0, 2, 1, "ab", 2, 2);
    assert_byte_slice(ascii, 1, 4, 0, NULL, 0, 0);
    blorp_string_release(ascii);

    struct blorp_string *source = text(mixed, MIXED_BYTES);
    assert_byte_slice(source, 1, 3, 1, "\xc3\xa9", 2, 1);
    assert_byte_slice(source, 0, 7, 1, "h\xc3\xa9llo ", 7, 6);
    /* Offset 2 is inside U+00E9 and offset 9 inside U+1F600. */
    assert_byte_slice(source, 0, 2, 0, NULL, 0, 0);
    assert_byte_slice(source, 2, 4, 0, NULL, 0, 0);
    assert_byte_slice(source, 7, 9, 0, NULL, 0, 0);
    assert_byte_slice(source, 7, 11, 1, "\xf0\x9f\x98\x80", 4, 1);
    assert_text(source, mixed, MIXED_BYTES, MIXED_CODE_POINTS);
    blorp_string_release(source);

    struct blorp_string *empty = text("", 0);
    assert_byte_slice(empty, 0, 0, 1, "", 0, 0);
    blorp_string_release(empty);
}

/* The per-byte definition of the count: every byte but a continuation starts a scalar.
 * It repeats the byte tests rather than using the runtime's, so the two stay independent. */
static int64_t counted_per_byte(const char *bytes, size_t length) {
    int64_t count = 0;
    for (size_t position = 0; position < length; position++) {
        if (((unsigned char)bytes[position] & 0xc0) != 0x80) count++;
    }
    return count;
}

static void assert_counted(const char *bytes, size_t length, int64_t code_points) {
    assert(counted_per_byte(bytes, length) == code_points);
    struct blorp_string *value = text(bytes, (int64_t)length);
    assert(value->code_points == code_points);
    blorp_string_release(value);
}

/* The eight-byte step and its tail: lengths around each word boundary, and a
 * scalar of every width starting at every offset in a word, so its
 * continuations meet both ends of a word. */
static void word_count(void) {
    static const size_t lengths[] = {0, 1, 7, 8, 9, 15, 16, 17};
    char buffer[128];
    for (size_t index = 0; index < sizeof lengths / sizeof lengths[0]; index++) {
        memset(buffer, 'a', sizeof buffer);
        assert_counted(buffer, lengths[index], (int64_t)lengths[index]);
    }
    static const char *const scalars[] = {"a", "\xc3\xa9", "\xe2\x82\xac", "\xf0\x9f\x98\x80"};
    for (size_t kind = 0; kind < sizeof scalars / sizeof scalars[0]; kind++) {
        const size_t width = strlen(scalars[kind]);
        for (size_t prefix = 0; prefix <= 2 * BLORP_UTF8_WORD_BYTES + 1; prefix++) {
            for (size_t repeats = 0; repeats <= 5; repeats++) {
                size_t length = 0;
                memset(buffer, 'a', prefix);
                length = prefix;
                for (size_t repeat = 0; repeat < repeats; repeat++) {
                    memcpy(buffer + length, scalars[kind], width);
                    length += width;
                }
                assert_counted(buffer, length, (int64_t)(prefix + repeats));
            }
        }
    }
    /* Three four-byte scalars: each word holds a lead byte and continuations. */
    assert_counted("\xf0\x9f\x98\x80\xf0\x9f\x98\x80\xf0\x9f\x98\x80", 12, 3);
    /* Invalid input is counted by the same definition: a word of nothing but
     * continuations, with lengths 8, 16 and 17 (a tail), then 0xff and 0xc0
     * (both have bit 7 set) mixed among continuations. */
    static const size_t continuation_lengths[] = {8, 16, 17};
    for (size_t index = 0; index < sizeof continuation_lengths / sizeof continuation_lengths[0];
         index++) {
        memset(buffer, 0x80, sizeof buffer);
        assert_counted(buffer, continuation_lengths[index], 0);
    }
    static const char mixed_invalid[] = "\xff\x80\xc0\x80\xbf\xff\x80\xc0\x80\x80\xc0\xff\xbf\xbf\x80\xc0\x80";
    for (size_t length = 0; length < sizeof mixed_invalid; length++) {
        assert_counted(mixed_invalid, length, counted_per_byte(mixed_invalid, length));
    }
}

/* S9: a String whose count disagrees with its bytes aborts at its release
 * with the named fault, as a writer that forgot its count would. */
static void wrong_count_faults(void) {
    struct blorp_string *value = text(mixed, MIXED_BYTES);
    value->code_points = MIXED_BYTES;
    blorp_string_release(value);
}

int main(int argc, char **argv) {
    blorp_memory_start();
    assert(argc == 2);
    const char *name = argv[1];
    if (strcmp(name, "lengths") == 0) lengths();
    else if (strcmp(name, "codepoint_at") == 0) codepoint_at();
    else if (strcmp(name, "codepoint_slice") == 0) codepoint_slice();
    else if (strcmp(name, "byte_slice") == 0) byte_slice();
    else if (strcmp(name, "word_count") == 0) word_count();
    else if (strcmp(name, "wrong_count_faults") == 0) wrong_count_faults();
    else {
        fprintf(stderr, "unknown String code point test: %s\n", name);
        return EXIT_FAILURE;
    }
    return blorp_memory_finish(0);
}
