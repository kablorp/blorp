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

enum { MAX_ALLOCATIONS = 32, EXPECTED_ERROR_CAPACITY = sizeof("write_file: close failed; errno=") + sizeof(int) * CHAR_BIT };
enum Failure { NO_FAILURE, OPEN_EACCES, SHORT_EIO, SHORT_EINTR, SHORT_ZERO,
    CLOSE_ENOSPC, CLOSE_EINTR, WRITE_AND_CLOSE };
struct Allocation { uintptr_t address; int live; };
static struct Allocation allocations[MAX_ALLOCATIONS];
static size_t allocation_count, live_count, free_count, path_frees;
static size_t open_count, stream_count, write_count, close_count;
static void *native_path;
static const void *contents_bytes;
static size_t contents_length;
static FILE *active_stream;
static enum Failure failure;
static int poison_cleanup;
static char output_path[] = "/tmp/blorp2_write_file_XXXXXX";

static size_t allocation_slot(const void *pointer) {
    for (size_t cursor = allocation_count; cursor > 0; cursor--) {
        if (allocations[cursor - 1].live && allocations[cursor - 1].address == (uintptr_t)pointer)
            return cursor - 1;
    }
    abort();
}

static void *observed_malloc(size_t bytes) {
    assert(bytes != 0 && allocation_count < MAX_ALLOCATIONS);
    void *pointer = malloc(bytes);
    assert(pointer);
    allocations[allocation_count++] = (struct Allocation){(uintptr_t)pointer, 1};
    live_count++;
    return pointer;
}

static void observed_free(void *pointer) {
    if (!pointer) return;
    allocations[allocation_slot(pointer)].live = 0;
    if (pointer == native_path) { native_path = NULL; path_frees++; }
    live_count--;
    free_count++;
    free(pointer);
    if (poison_cleanup) errno = EDOM;
}

static FILE *observed_fopen(const char *path, const char *mode) {
    assert(native_path == NULL && active_stream == NULL);
    (void)allocation_slot(path);
    native_path = (void *)path;
    assert(strcmp(mode, "wb") == 0);
    open_count++;
    if (failure == OPEN_EACCES) { errno = EACCES; return NULL; }
    active_stream = fopen(path, mode);
    if (active_stream) stream_count++;
    return active_stream;
}

static size_t observed_fwrite(const void *bytes, size_t width, size_t count, FILE *stream) {
    assert(stream == active_stream && stream != NULL && native_path == NULL);
    assert(bytes == contents_bytes && width == 1 && count == contents_length && count > 0);
    write_count++;
    if (failure == SHORT_EIO || failure == SHORT_EINTR || failure == SHORT_ZERO || failure == WRITE_AND_CLOSE) {
        assert(fwrite(bytes, width, count - 1, stream) == count - 1);
        errno = failure == SHORT_EINTR ? EINTR : failure == SHORT_ZERO ? 0 : EIO;
        return count - 1;
    }
    return fwrite(bytes, width, count, stream);
}

static int observed_fclose(FILE *stream) {
    assert(active_stream != NULL && stream == active_stream);
    const int descriptor = fileno(stream);
    active_stream = NULL;
    assert(fclose(stream) == 0);
    /* Prove actual descriptor disposal before another oracle can open it.
     * Scripted EINTR tests one attempt, not all platforms' EINTR disposal. */
    assert(fcntl(descriptor, F_GETFD) == -1 && errno == EBADF);
    close_count++;
    if (failure == CLOSE_ENOSPC || failure == WRITE_AND_CLOSE) { errno = ENOSPC; return -1; }
    if (failure == CLOSE_EINTR) { errno = EINTR; return -1; }
    if (poison_cleanup) errno = EBUSY;
    return 0;
}

/* Only unchanged production fragments see allocator and stdio aliases. */
#define malloc observed_malloc
#define free observed_free
#include "string_runtime.c"

static const struct blorp_string *borrowed_path, *borrowed_contents;

static void observed_string_retain(struct blorp_string *value) {
    assert(value != borrowed_path && value != borrowed_contents);
    blorp_string_retain(value);
}

static void observed_string_release(struct blorp_string *value) {
    assert(value != borrowed_path && value != borrowed_contents);
    blorp_string_release(value);
}

#define blorp_string_retain observed_string_retain
#define blorp_string_release observed_string_release
#define fopen observed_fopen
#define fwrite observed_fwrite
#define fclose observed_fclose
#include "write_file_runtime.c"
#undef fclose
#undef fwrite
#undef fopen
#undef blorp_string_release
#undef blorp_string_retain
#undef free
#undef malloc

static void assert_bytes(const struct blorp_string *text, const char *bytes, size_t length) {
    (void)allocation_slot(text);
    assert(atomic_load(&text->references) == 1 && text->length == (int64_t)length);
    assert(memcmp(text->bytes, bytes, length) == 0 && text->bytes[length] == '\0');
}

static struct blorp_string *invoke(struct blorp_string *path, struct blorp_string *contents,
    uint8_t expected_status, const char *expected_error) {
    const size_t allocations_before = allocation_count, frees_before = free_count;
    const size_t opens_before = open_count, writes_before = write_count, closes_before = close_count;
    const size_t streams_before = stream_count;
    const size_t path_frees_before = path_frees;
    const int nul_path = memchr(path->bytes, '\0', (size_t)path->length) != NULL;
    /* A non-NULL sentinel is a live borrowed input, so leaving it unchanged
     * fails the success oracle without inventing an invalid pointer. */
    struct blorp_string *error = path;
    borrowed_path = path;
    borrowed_contents = contents;
    contents_bytes = contents->bytes;
    contents_length = (size_t)contents->length;
    const uint8_t status = blorp_write_file(path, contents, &error);
    assert(status == expected_status && native_path == NULL && active_stream == NULL);
    assert(atomic_load(&path->references) == 1 && atomic_load(&contents->references) == 1);
    const size_t attempted_open = nul_path ? 0 : 1;
    const size_t acquired_stream = stream_count - streams_before;
    assert(open_count == opens_before + attempted_open);
    assert(path_frees == path_frees_before + attempted_open);
    assert(acquired_stream <= 1 && close_count == closes_before + acquired_stream);
    assert(write_count == writes_before + (acquired_stream != 0 && contents_length != 0 ? 1 : 0));
    assert(allocation_count == allocations_before + attempted_open + (expected_error ? 1 : 0));
    assert(free_count == frees_before + attempted_open);
    if (expected_error) {
        assert(error && error != path && error != contents);
        assert_bytes(error, expected_error, strlen(expected_error));
        assert(blorp_utf8_is_valid(error->bytes, (size_t)error->length));
    } else assert(error == NULL);
    contents_bytes = NULL;
    borrowed_path = borrowed_contents = NULL;
    return error;
}

static void drop_result(struct blorp_string *error) {
    const size_t before = free_count;
    const size_t expected_frees = error ? 1 : 0;
    const size_t child_slot = error ? allocation_slot(error) : 0;
    struct blorp_u_0 result;
    if (error) result = (struct blorp_u_0){.tag = blorp_v_0_1, .payload.blorp_up_1 = {.blorp_uf_0 = error}};
    else result = (struct blorp_u_0){.tag = blorp_v_0_0, .payload.blorp_up_0 = {.blorp_uf_0 = (uint8_t)0}};
    blorp_union_drop_0(result);
    assert(free_count == before + expected_frees);
    if (expected_frees) assert(!allocations[child_slot].live);
}

static void stored_bytes(const char *expected, size_t length) {
    FILE *stream = fopen(output_path, "rb");
    assert(stream);
    for (size_t index = 0; index < length; index++) assert(fgetc(stream) == (unsigned char)expected[index]);
    assert(fgetc(stream) == EOF && !ferror(stream) && fclose(stream) == 0);
}

static void success_bytes(const char *bytes, size_t length) {
    struct blorp_string *path = blorp_string_from_bytes(output_path, (int64_t)strlen(output_path));
    struct blorp_string *contents = blorp_string_from_bytes(bytes, (int64_t)length);
    drop_result(invoke(path, contents, BLORP_SYSTEM_SUCCEEDED, NULL));
    assert_bytes(path, output_path, strlen(output_path));
    assert_bytes(contents, bytes, length);
    stored_bytes(bytes, length);
    blorp_string_release(path);
    blorp_string_release(contents);
}

static void error_text(const char *path_bytes, size_t path_length, const char *expected) {
    struct blorp_string *path = blorp_string_from_bytes(path_bytes, (int64_t)path_length);
    struct blorp_string *contents = blorp_string_from_bytes("abc", 3);
    drop_result(invoke(path, contents, BLORP_SYSTEM_FAILED, expected));
    assert_bytes(path, path_bytes, path_length);
    assert_bytes(contents, "abc", 3);
    blorp_string_release(path);
    blorp_string_release(contents);
}

static void error_number(const char *prefix, int code) {
    char expected[EXPECTED_ERROR_CAPACITY];
    const int length = snprintf(expected, sizeof expected, "write_file: %s; errno=%d", prefix, code);
    assert(length > 0 && (size_t)length < sizeof expected);
    error_text(output_path, strlen(output_path), expected);
}

int main(int argc, char **argv) {
    assert(argc == 2);
    const int descriptor = mkstemp(output_path);
    assert(descriptor >= 0 && close(descriptor) == 0);
    FILE *seed = fopen(output_path, "wb");
    assert(seed && fwrite("longer seed", 1, 11, seed) == 11 && fclose(seed) == 0);
    poison_cleanup = 1;
    if (strcmp(argv[1], "empty") == 0) {
        success_bytes("", 0);
        assert(unlink(output_path) == 0);
        success_bytes("", 0);
    } else if (strcmp(argv[1], "utf8") == 0) success_bytes("\xc3\xa9\xf0\x9f\x98\x80", 6);
    else if (strcmp(argv[1], "nul") == 0) success_bytes("a\0tail", 6);
    else if (strcmp(argv[1], "crlf_bom") == 0) success_bytes("\xef\xbb\xbf" "a\r\nb", 7);
    else if (strcmp(argv[1], "nul_path") == 0) {
        char path_with_nul[sizeof output_path + 4];
        memcpy(path_with_nul, output_path, sizeof output_path);
        memcpy(path_with_nul + sizeof output_path, "tail", 4);
        error_text(path_with_nul, sizeof path_with_nul, "write_file: path contains embedded NUL; use a path without NUL");
        stored_bytes("longer seed", 11);
        assert(open_count == 0);
    } else if (strcmp(argv[1], "missing_parent") == 0) {
        assert(unlink(output_path) == 0);
        char missing_path[sizeof output_path + sizeof "/child"];
        assert(snprintf(missing_path, sizeof missing_path, "%s/child", output_path) > 0);
        assert(fopen(missing_path, "wb") == NULL);
        const int saved_errno = errno;
        char expected[EXPECTED_ERROR_CAPACITY];
        assert(snprintf(expected, sizeof expected, "write_file: open failed; errno=%d", saved_errno) > 0);
        error_text(missing_path, strlen(missing_path), expected);
    } else if (strcmp(argv[1], "same_input") == 0) {
        struct blorp_string *both = blorp_string_from_bytes(output_path, (int64_t)strlen(output_path));
        drop_result(invoke(both, both, BLORP_SYSTEM_SUCCEEDED, NULL));
        assert_bytes(both, output_path, strlen(output_path));
        stored_bytes(output_path, strlen(output_path));
        blorp_string_release(both);
    } else if (strcmp(argv[1], "fresh") == 0) {
        struct blorp_string *path = blorp_string_from_bytes(output_path, (int64_t)strlen(output_path));
        struct blorp_string *contents = blorp_string_from_bytes("abc", 3);
        failure = OPEN_EACCES;
        char expected[EXPECTED_ERROR_CAPACITY];
        assert(snprintf(expected, sizeof expected, "write_file: open failed; errno=%d", EACCES) > 0);
        struct blorp_string *first = invoke(path, contents, BLORP_SYSTEM_FAILED, expected);
        struct blorp_string *second = invoke(path, contents, BLORP_SYSTEM_FAILED, expected);
        assert(first != second);
        drop_result(first);
        assert_bytes(second, expected, strlen(expected));
        drop_result(second);
        blorp_string_release(path);
        blorp_string_release(contents);
    } else if (strcmp(argv[1], "ok_drop") == 0) {
        struct blorp_string *unrelated = blorp_string_from_bytes("live", 4);
        drop_result(NULL);
        assert_bytes(unrelated, "live", 4);
        blorp_string_release(unrelated);
    }
    else if (strcmp(argv[1], "err_drop") == 0) drop_result(blorp_string_from_bytes("error", 5));
    else if (strcmp(argv[1], "open_eacces") == 0) { failure = OPEN_EACCES; error_number("open failed", EACCES); }
    else if (strcmp(argv[1], "short_eio") == 0) { failure = SHORT_EIO; error_number("short write", EIO); }
    else if (strcmp(argv[1], "short_eintr") == 0) { failure = SHORT_EINTR; error_number("short write", EINTR); }
    else if (strcmp(argv[1], "short_zero") == 0) { failure = SHORT_ZERO; error_number("short write", 0); }
    else if (strcmp(argv[1], "close_enospc") == 0) { failure = CLOSE_ENOSPC; error_number("close failed", ENOSPC); }
    else if (strcmp(argv[1], "close_eintr") == 0) { failure = CLOSE_EINTR; error_number("close failed", EINTR); }
    else if (strcmp(argv[1], "write_close") == 0) { failure = WRITE_AND_CLOSE; error_number("short write", EIO); }
    else abort();
    assert(active_stream == NULL && native_path == NULL && live_count == 0);
    assert(allocation_count == free_count);
    if (strcmp(argv[1], "missing_parent") != 0) assert(unlink(output_path) == 0);
    return 0;
}
