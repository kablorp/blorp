#define _POSIX_C_SOURCE 200809L
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <limits.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

enum { MAX_ALLOCATIONS = 64, EXPECTED_ERROR_CAPACITY = sizeof("read_file: seek start failed; errno=") + sizeof(int) * CHAR_BIT };
enum Failure { NO_FAILURE, OPEN_FAILURE, SEEK_END_FAILURE, TELL_FAILURE,
    TELL_OVERFLOW, SEEK_START_FAILURE, READ_EIO, READ_EINTR, SHORT_READ,
    CLOSE_ENOSPC, CLOSE_EINTR, READ_AND_CLOSE, INVALID_AND_CLOSE };
struct Allocation { void *pointer; int live; };
static struct Allocation allocations[MAX_ALLOCATIONS];
static size_t allocation_count, live_count, allocation_total, free_total;
static size_t path_frees, staging_frees, output_frees;
static size_t open_count, close_count, read_count, error_count;
static void *native_path, *staging, *output_root;
static const void *borrowed_bytes;
static FILE *active_stream;
static enum Failure failure;
static int poison_free, poison_error, poison_close;
static char input_path[] = "/tmp/blorp2_read_file_XXXXXX";

static size_t allocation_slot(void *pointer) {
    for (size_t cursor = allocation_count; cursor > 0; cursor--) {
        if (allocations[cursor - 1].live && allocations[cursor - 1].pointer == pointer)
            return cursor - 1;
    }
    abort();
}

static void *observed_malloc(size_t bytes) {
    assert(bytes != 0 && allocation_count < MAX_ALLOCATIONS);
    if (failure == OPEN_FAILURE && open_count != 0)
        assert(native_path == NULL && path_frees == open_count);
    void *pointer = malloc(bytes);
    assert(pointer);
    allocations[allocation_count++] = (struct Allocation){pointer, 1};
    live_count++;
    allocation_total++;
    return pointer;
}

static void observed_free(void *pointer) {
    if (!pointer) return;
    const size_t slot = allocation_slot(pointer);
    if (pointer == native_path) { native_path = NULL; path_frees++; }
    if (pointer == staging) { staging = NULL; staging_frees++; }
    if (pointer == output_root) { output_root = NULL; output_frees++; }
    allocations[slot].live = 0;
    live_count--;
    free_total++;
    free(pointer);
    if (poison_free) errno = EDOM;
}

static void *observed_memcpy(void *destination, const void *source, size_t length) {
    if (source == borrowed_bytes) {
        assert(native_path == NULL);
        (void)allocation_slot(destination);
        native_path = destination;
    }
    return memcpy(destination, source, length);
}

static FILE *observed_fopen(const char *path, const char *mode) {
    assert(path == native_path && active_stream == NULL);
    assert(strcmp(mode, "rb") == 0);
    open_count++;
    active_stream = fopen(path, mode);
    if (failure == OPEN_FAILURE) { assert(active_stream == NULL && errno == ENOENT); }
    else assert(active_stream);
    return active_stream;
}

static int observed_fseek(FILE *stream, long offset, int origin) {
    assert(stream == active_stream && offset == 0);
    if ((origin == SEEK_END && failure == SEEK_END_FAILURE) ||
        (origin == SEEK_SET && failure == SEEK_START_FAILURE)) {
        errno = EIO;
        return -1;
    }
    return fseek(stream, offset, origin);
}

static long observed_ftell(FILE *stream) {
    assert(stream == active_stream);
    if (failure == TELL_FAILURE || failure == TELL_OVERFLOW) {
        errno = failure == TELL_OVERFLOW ? EOVERFLOW : EIO;
        return -1;
    }
    return ftell(stream);
}

static size_t observed_fread(void *destination, size_t width, size_t count, FILE *stream) {
    assert(stream == active_stream && width == 1 && count > 0 && staging == NULL);
    (void)allocation_slot(destination);
    staging = destination;
    read_count++;
    if (failure == READ_EIO || failure == READ_EINTR || failure == SHORT_READ || failure == READ_AND_CLOSE) {
        const size_t received = fread(destination, width, count - 1, stream);
        assert(received == count - 1);
        errno = failure == READ_EINTR ? EINTR : EIO;
        return received;
    }
    return fread(destination, width, count, stream);
}

static int observed_ferror(FILE *stream) {
    assert(stream == active_stream);
    const int actual = ferror(stream);
    error_count++;
    const int selected = failure == SHORT_READ ? 0 : actual || failure == READ_EIO || failure == READ_EINTR || failure == READ_AND_CLOSE;
    if (poison_error) errno = EILSEQ;
    return selected;
}

static int observed_fclose(FILE *stream) {
    assert(active_stream != NULL && stream == active_stream);
    const int descriptor = fileno(stream);
    active_stream = NULL;
    const int actual = fclose(stream);
    assert(actual == 0);
    /* Check the actual descriptor before counters or another oracle can open. */
    assert(fcntl(descriptor, F_GETFD) == -1 && errno == EBADF);
    close_count++;
    if (failure == CLOSE_ENOSPC || failure == READ_AND_CLOSE || failure == INVALID_AND_CLOSE) {
        errno = ENOSPC;
        return -1;
    }
    if (failure == CLOSE_EINTR) { errno = EINTR; return -1; }
    if (poison_close) errno = EBUSY;
    return actual;
}

/* Only the unchanged production runtime and aggregate fragments see aliases. */
#define malloc observed_malloc
#define free observed_free
#define memcpy observed_memcpy
#define fopen observed_fopen
#define fseek observed_fseek
#define ftell observed_ftell
#define fread observed_fread
#define ferror observed_ferror
#define fclose observed_fclose
#include "file_read_runtime.c"
#undef fclose
#undef ferror
#undef fread
#undef ftell
#undef fseek
#undef fopen
#undef memcpy
#undef free
#undef malloc

static void write_input(const char *bytes, size_t length) {
    FILE *stream = fopen(input_path, "wb");
    assert(stream);
    assert(fwrite(bytes, 1, length, stream) == length);
    assert(fclose(stream) == 0);
}

static struct blorp_string *query(const char *path_bytes, size_t path_length,
    uint8_t expected_status, const char *expected, size_t expected_length) {
    struct blorp_string *path = blorp_string_from_bytes(path_bytes, (int64_t)path_length);
    borrowed_bytes = path->bytes;
    const size_t previous_path_frees = path_frees, previous_staging_frees = staging_frees;
    const size_t previous_opens = open_count, previous_closes = close_count, previous_reads = read_count;
    struct blorp_string *payload = NULL;
    const uint8_t status = blorp_read_file(path, &payload);
    assert(status == expected_status && payload && payload != path);
    assert(atomic_load(&path->references) == 1 && atomic_load(&payload->references) == 1);
    assert(path->length == (int64_t)path_length && memcmp(path->bytes, path_bytes, path_length) == 0);
    assert(payload->length == (int64_t)expected_length);
    assert(memcmp(payload->bytes, expected, expected_length) == 0 && payload->bytes[expected_length] == '\0');
    assert(blorp_utf8_is_valid(payload->bytes, expected_length));
    assert(native_path == NULL && staging == NULL && active_stream == NULL);
    const int forbidden_path = memchr(path_bytes, '\0', path_length) != NULL;
    assert(open_count == previous_opens + (forbidden_path ? 0 : 1));
    assert(close_count == previous_closes + (forbidden_path || failure == OPEN_FAILURE ? 0 : 1));
    assert(path_frees == previous_path_frees + (forbidden_path ? 0 : 1));
    assert(staging_frees == previous_staging_frees + read_count - previous_reads);
    assert(read_count - previous_reads <= 1);
    borrowed_bytes = NULL;
    blorp_string_release(path);
    return payload;
}

static void release_result(uint8_t success, struct blorp_string *payload) {
    assert(output_root == NULL);
    output_root = payload;
    const size_t previous_frees = output_frees;
    struct blorp_u_0 result;
    if (success) {
        result = (struct blorp_u_0){.tag = blorp_v_0_0, .payload.blorp_up_0 = {.blorp_uf_0 = payload}};
    } else {
        result = (struct blorp_u_0){.tag = blorp_v_0_1, .payload.blorp_up_1 = {.blorp_uf_0 = payload}};
    }
    blorp_union_drop_0(result);
    assert(output_frees == previous_frees + 1 && output_root == NULL);
}

static void success_bytes(const char *bytes, size_t length) {
    write_input(bytes, length);
    release_result(1, query(input_path, strlen(input_path), 1, bytes, length));
}

static void error_text(const char *text) {
    release_result(0, query(input_path, strlen(input_path), 0, text, strlen(text)));
}

static void error_number(const char *operation, int code) {
    char expected[EXPECTED_ERROR_CAPACITY];
    const int length = snprintf(expected, sizeof expected, "read_file: %s failed; errno=%d", operation, code);
    assert(length > 0 && (size_t)length < sizeof expected);
    error_text(expected);
}

static void malformed_utf8(void) {
    const unsigned char values[][4] = {
        {0x80, 0, 0, 0}, {0xc0, 0x80, 0, 0}, {0xc1, 0xbf, 0, 0},
        {0xf5, 0x80, 0x80, 0x80}, {0xff, 0, 0, 0}, {0xc2, 0, 0, 0},
        {0xe0, 0x9f, 0xbf, 0}, {0xed, 0xa0, 0x80, 0}, {0xed, 0xbf, 0xbf, 0},
        {0xf0, 0x8f, 0xbf, 0xbf}, {0xf4, 0x90, 0x80, 0x80}, {0xe2, 0x82, 0, 0},
        {0xc2, 0x41, 0, 0}, {0xf0, 0x9f, 0x98, 0}
    };
    const size_t lengths[] = {1, 2, 2, 4, 1, 1, 3, 3, 3, 4, 4, 2, 2, 3};
    for (size_t index = 0; index < sizeof lengths / sizeof lengths[0]; index++) {
        write_input((const char *)values[index], lengths[index]);
        error_text("read_file: invalid UTF-8; save the file as UTF-8");
        /* Keep the bounded allocation ledger local to each completed call. */
        assert(live_count == 0);
        allocation_count = 0;
    }
}

int main(int argc, char **argv) {
    assert(argc == 2);
    const int descriptor = mkstemp(input_path);
    assert(descriptor >= 0 && close(descriptor) == 0);
    write_input("abcdef", 6);
    if (strcmp(argv[1], "empty") == 0) success_bytes("", 0);
    else if (strcmp(argv[1], "utf8") == 0) success_bytes("\xc3\xa9\xf0\x9f\x98\x80", 6);
    else if (strcmp(argv[1], "nul") == 0) success_bytes("a\0b", 3);
    else if (strcmp(argv[1], "crlf_bom") == 0) success_bytes("\xef\xbb\xbf" "a\r\nb", 7);
    else if (strcmp(argv[1], "malformed") == 0) malformed_utf8();
    else if (strcmp(argv[1], "nul_path") == 0) {
        const char *text = "read_file: path contains embedded NUL; use a path without NUL";
        release_result(0, query("input\0suffix", 12, 0, text, strlen(text)));
    } else if (strcmp(argv[1], "fresh") == 0) {
        write_input("", 0);
        struct blorp_string *first = query(input_path, strlen(input_path), 1, "", 0);
        struct blorp_string *second = query(input_path, strlen(input_path), 1, "", 0);
        assert(first != second);
        release_result(1, first);
        release_result(1, second);
    } else {
        poison_free = poison_error = poison_close = 1;
        if (strcmp(argv[1], "open") == 0) { failure = OPEN_FAILURE; assert(unlink(input_path) == 0); error_number("open", ENOENT); }
        else if (strcmp(argv[1], "seek_end") == 0) { failure = SEEK_END_FAILURE; error_number("seek end", EIO); }
        else if (strcmp(argv[1], "tell") == 0) { failure = TELL_FAILURE; error_number("tell", EIO); }
        else if (strcmp(argv[1], "tell_overflow") == 0) { failure = TELL_OVERFLOW; error_number("tell", EOVERFLOW); }
        else if (strcmp(argv[1], "seek_start") == 0) { failure = SEEK_START_FAILURE; error_number("seek start", EIO); }
        else if (strcmp(argv[1], "read_eio") == 0) { failure = READ_EIO; error_number("read", EIO); }
        else if (strcmp(argv[1], "read_eintr") == 0) { failure = READ_EINTR; error_number("read", EINTR); }
        else if (strcmp(argv[1], "short") == 0) { failure = SHORT_READ; error_text("read_file: short read"); }
        else if (strcmp(argv[1], "close") == 0) { failure = CLOSE_ENOSPC; error_number("close", ENOSPC); }
        else if (strcmp(argv[1], "close_eintr") == 0) { failure = CLOSE_EINTR; error_number("close", EINTR); }
        else if (strcmp(argv[1], "read_close") == 0) { failure = READ_AND_CLOSE; error_number("read", EIO); }
        else if (strcmp(argv[1], "invalid_close") == 0) {
            write_input("\xff", 1);
            failure = INVALID_AND_CLOSE;
            error_number("close", ENOSPC);
        } else abort();
    }
    assert(active_stream == NULL && live_count == 0);
    assert(allocation_total > 0 && allocation_total == free_total);
    assert(error_count == (failure == READ_EIO || failure == READ_EINTR || failure == SHORT_READ || failure == READ_AND_CLOSE ? 1u : 0u));
    if (failure != OPEN_FAILURE) assert(unlink(input_path) == 0);
    return 0;
}
