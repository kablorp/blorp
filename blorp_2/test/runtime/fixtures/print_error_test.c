#include <assert.h>
#include <errno.h>
#include <stdint.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static size_t allocations, destructions, writes, newlines, expected_length;
static int short_write, interrupted, fail_newline;
static size_t retains, releases;

static void *test_allocate(size_t size) {
    void *value = malloc(size);
    assert(value != NULL);
    allocations += 1;
    return value;
}

static void test_free(void *value) {
    if (value != NULL) destructions += 1;
    free(value);
}

static size_t test_write(const void *bytes, size_t size, size_t count, FILE *stream) {
    writes += 1;
    assert(writes == 1);
    assert(stream == stderr);
    assert(size == 1);
    assert(count == expected_length);
    if (interrupted) {
        errno = EINTR;
        return 0;
    }
    if (short_write) return fwrite(bytes, size, count - 1, stream);
    return fwrite(bytes, size, count, stream);
}

static int test_putc(int byte, FILE *stream) {
    newlines += 1;
    assert(newlines == 1);
    assert(writes == 1);
    assert(stream == stderr);
    assert(byte == '\n');
    if (fail_newline) {
        errno = EIO;
        return EOF;
    }
    return fputc(byte, stream);
}

/* Production fragments, with delegates installed only after libc headers. */
#define malloc test_allocate
#define free test_free
#include "string_runtime.c"
#undef free
#undef malloc

static void test_retain(struct blorp_string *value) {
    retains += 1;
    blorp_string_retain(value);
}

static void test_release(struct blorp_string *value) {
    releases += 1;
    blorp_string_release(value);
}

#define malloc test_allocate
#define free test_free
#define fwrite test_write
#define fputc test_putc
#define blorp_string_retain test_retain
#define blorp_string_release test_release
#include "print_error_runtime.c"
#undef blorp_string_release
#undef blorp_string_retain
#undef fputc
#undef fwrite
#undef free
#undef malloc

static void check_call(const char *bytes, size_t length) {
    struct blorp_string *value = blorp_string_from_bytes(bytes, (int64_t)length);
    assert(allocations == 1 && destructions == 0);
    (void)test_retain;
    (void)test_release;
    expected_length = length;
    assert(blorp_string_print_error(value) == (uint8_t)0);
    assert(writes == 1);
    assert(retains == 0 && releases == 0);
    assert(newlines == (size_t)(!short_write && !interrupted));
    assert(allocations == 1 && destructions == 0);
    assert(atomic_load(&value->references) == 1);
    assert(value->length == (int64_t)length);
    assert(memcmp(value->bytes, bytes, length) == 0);
    blorp_string_release(value);
    assert(destructions == 1);
}

int main(int argc, char **argv) {
    assert(argc == 2);
    if (strcmp(argv[1], "bytes") == 0) {
        const char bytes[] = {'l','i','n','e','1','\n','\0',
            (char)0xc3,(char)0xa9,(char)0xf0,(char)0x9f,(char)0x98,(char)0x80};
        check_call(bytes, sizeof(bytes));
    } else if (strcmp(argv[1], "empty") == 0) {
        check_call("", 0);
    } else if (strcmp(argv[1], "short") == 0) {
        short_write = 1;
        check_call("abc", 3);
    } else if (strcmp(argv[1], "eintr") == 0) {
        interrupted = 1;
        check_call("abc", 3);
    } else if (strcmp(argv[1], "newline_error") == 0) {
        fail_newline = 1;
        check_call("abc", 3);
    } else {
        assert(0 && "unknown test case");
    }
    return 0;
}
