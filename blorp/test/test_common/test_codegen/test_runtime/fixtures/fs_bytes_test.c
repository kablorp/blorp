/* Native probe of the byte natives, built with the unmodified production
 * fragments and the List[UInt8] layout a program that uses them emits:
 * fs.read_bytes, fs.write_bytes, string.to_bytes and bytes.to_text. Each case
 * is one argument, after which comes a directory the case may write in; a case
 * that passes returns 0 and prints nothing. */
#define _POSIX_C_SOURCE 200809L
#define _XOPEN_SOURCE 700
#ifdef __APPLE__
#define _DARWIN_C_SOURCE /* before any header, or F_BARRIERFSYNC stays hidden */
#endif
#include <assert.h>
#ifdef NDEBUG
#error the cases keep their work inside assert, so NDEBUG would skip it
#endif
#include <stdio.h>
#include <string.h>

#include "fs_bytes_runtime.c"

typedef struct blorp_l_0_b *bytes_list;

/* A fresh List of `length` bytes, which the caller drops. */
static bytes_list bytes_of(const unsigned char *bytes, size_t length) {
    bytes_list result = blorp_memory_allocate(sizeof *result + length);
    assert(result != NULL);
    atomic_init(&result->references, 1);
    result->length = (int64_t)length;
    result->capacity = length;
    memcpy(result->values, bytes, length);
    return result;
}

static struct blorp_string *text_of(const char *bytes, size_t length) {
    return blorp_string_from_bytes(bytes, (int64_t)length);
}

static char *path_in(const char *directory, const char *name) {
    static char path[4096];
    int written = snprintf(path, sizeof path, "%s/%s", directory, name);
    assert(written > 0 && (size_t)written < sizeof path);
    return path;
}

/* Every byte value survives a write and a read, NUL and 0xFF included. */
static int round_trip(const char *directory) {
    static const unsigned char payload[] = {0x00, 0xff, 'H', 'i', 0x00, 0x80};
    const char *path = path_in(directory, "fs_bytes_round_trip.bin");
    struct blorp_string *name = text_of(path, strlen(path));
    bytes_list data = bytes_of(payload, sizeof payload);
    int64_t error = -1;
    assert(blorp_fs_write_bytes(name, data, &error) == BLORP_FS_SUCCEEDED);
    bytes_list read = NULL;
    assert(blorp_fs_read_bytes(name, &read, &error) == BLORP_FS_SUCCEEDED);
    assert(read->length == (int64_t)sizeof payload);
    assert(memcmp(read->values, payload, sizeof payload) == 0);
    blorp_list_drop_0_b(read);
    blorp_list_drop_0_b(data);
    blorp_string_release(name);
    return 0;
}

/* A missing file is NotFound, the read protocol's code 1, with nothing published. */
static int missing(const char *directory) {
    const char *path = path_in(directory, "fs_bytes_missing.bin");
    struct blorp_string *name = text_of(path, strlen(path));
    bytes_list read = NULL;
    int64_t error = 0;
    assert(blorp_fs_read_bytes(name, &read, &error) == BLORP_FS_FAILED);
    assert(error == BLORP_FS_NOT_FOUND && read == NULL);
    blorp_string_release(name);
    return 0;
}

static int to_bytes(void) {
    static const char text[] = "H\xc3\xa9\0";
    struct blorp_string *value = text_of(text, 4);
    bytes_list bytes = blorp_string_to_bytes(value);
    assert(bytes->length == 4 && memcmp(bytes->values, text, 4) == 0);
    blorp_list_drop_0_b(bytes);
    blorp_string_release(value);
    return 0;
}

/* Whether bytes.to_text accepts the bytes; an accepted text must equal them. */
static int to_text(const unsigned char *bytes, size_t length) {
    bytes_list data = bytes_of(bytes, length);
    struct blorp_string *text = NULL;
    const uint8_t accepted = blorp_bytes_to_text(data, &text);
    if (accepted) {
        assert(text->length == (int64_t)length && memcmp(text->bytes, bytes, length) == 0);
        blorp_string_release(text);
    } else {
        assert(text == NULL);
    }
    blorp_list_drop_0_b(data);
    return accepted;
}

static const unsigned char overlong[] = {0xc0, 0x80};
static const unsigned char surrogate[] = {0xed, 0xa0, 0x80};
static const unsigned char above_unicode[] = {0xf4, 0x90, 0x80, 0x80};
static const unsigned char continuation[] = {0x80};
static const unsigned char truncated[] = {0xe2, 0x82};
static const unsigned char grinning[] = {0xf0, 0x9f, 0x98, 0x80};

int main(int argc, char **argv) {
    assert(argc == 3);
    blorp_memory_start();
    const char *name = argv[1];
    int failed = 1;
    if (strcmp(name, "round_trip") == 0) {
        failed = round_trip(argv[2]);
    } else if (strcmp(name, "missing") == 0) {
        failed = missing(argv[2]);
    } else if (strcmp(name, "to_bytes") == 0) {
        failed = to_bytes();
    } else if (strcmp(name, "refuses_overlong") == 0) {
        failed = to_text(overlong, sizeof overlong);
    } else if (strcmp(name, "refuses_surrogate") == 0) {
        failed = to_text(surrogate, sizeof surrogate);
    } else if (strcmp(name, "refuses_above_unicode") == 0) {
        failed = to_text(above_unicode, sizeof above_unicode);
    } else if (strcmp(name, "refuses_lone_continuation") == 0) {
        failed = to_text(continuation, sizeof continuation);
    } else if (strcmp(name, "refuses_truncated") == 0) {
        failed = to_text(truncated, sizeof truncated);
    } else if (strcmp(name, "accepts_four_bytes") == 0) {
        failed = !to_text(grinning, sizeof grinning);
    }
    return blorp_memory_finish(failed);
}
