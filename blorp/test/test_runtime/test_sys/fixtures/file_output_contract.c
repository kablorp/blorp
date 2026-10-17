#define _GNU_SOURCE
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

enum WriteFault { NO_FAILURE, SHORT_WRITE, CLOSE_FAILURE, WRITE_CLOSE_FAILURE, FDOPEN_FAILURE, OPEN_FAILURE };
enum { INPUT_PATH, INPUT_CONTENT, OUTPUT_RESULT, ERROR_TEXT, PRIVATE_PATH, WATCH_COUNT };
static enum WriteFault write_fault;
static int observing_write, write_descriptor, close_attempts;
static int transfer_attempts, strerror_calls;
static int write_code = EIO, close_code = ENOSPC;
static FILE* write_stream;
static void* watched[WATCH_COUNT];
static int frees[WATCH_COUNT];
static const void* write_path_bytes;
static void* observed_memcpy(void*, const void*, size_t);

static char* observed_strerror(int code) {
    if (observing_write && write_fault == OPEN_FAILURE) {
        static char invalid_text[] = "\xff";
        strerror_calls++;
        return invalid_text;
    }
    return strerror(code);
}

static FILE* observed_fdopen(int descriptor, const char* mode) {
    if (observing_write) {
        write_descriptor = descriptor;
        if (write_fault == FDOPEN_FAILURE) {
            errno = EMFILE;
            return NULL;
        }
    }
    FILE* stream = fdopen(descriptor, mode);
    if (observing_write) write_stream = stream;
    return stream;
}

static size_t observed_fwrite(const void* data, size_t width, size_t count, FILE* stream) {
    if (observing_write && stream == write_stream) {
        transfer_attempts++;
        assert(transfer_attempts == 1);
    }
    if (observing_write && stream == write_stream &&
        (write_fault == SHORT_WRITE || write_fault == WRITE_CLOSE_FAILURE)) {
        size_t written = fwrite(data, width, count ? count - 1 : 0, stream);
        errno = write_code;
        return written;
    }
    return fwrite(data, width, count, stream);
}

static int observed_fclose(FILE* stream) {
    if (observing_write) assert(write_stream != NULL && stream == write_stream);
    int observed = observing_write && stream == write_stream;
    if (observed) {
        close_attempts++;
        write_stream = NULL;
    }
    int result = fclose(stream);
    if (observed && (write_fault == CLOSE_FAILURE || write_fault == WRITE_CLOSE_FAILURE)) {
        errno = close_code;
        return EOF;
    }
    return result;
}

static int observed_close(int descriptor) {
    if (observing_write && descriptor == write_descriptor) close_attempts++;
    return close(descriptor);
}

static void observed_free(void* object) {
    for (int index = 0; index < WATCH_COUNT; index++) {
        if (object && object == watched[index]) {
            if (index == INPUT_PATH) write_path_bytes = NULL;
            watched[index] = NULL; /* Clear before libc can reuse the address. */
            frees[index]++;
        }
    }
    free(object);
}

#define MINICORO_IMPL
#include "minicoro.h"
#define fdopen observed_fdopen
#define fwrite observed_fwrite
#define fclose observed_fclose
#define close observed_close
#define free observed_free
#define strerror observed_strerror
#define memcpy observed_memcpy
#include "runtime.c"
#undef fdopen
#undef fwrite
#undef fclose
#undef close
#undef free
#undef strerror
#undef memcpy

static void* observed_memcpy(void* destination, const void* source, size_t count) {
    if (observing_write && source == write_path_bytes) {
        assert(frees[INPUT_PATH] == 0 && frees[PRIVATE_PATH] == 0);
        assert(watched[PRIVATE_PATH] == NULL);
        watched[PRIVATE_PATH] = destination;
    }
    return memcpy(destination, source, count);
}

static const char LONG_TEXT[] = "prefix-\xc3\xa9\0\r\nsuffix";
static const unsigned char LONG_BYTES[] = {
    'p', 'r', 'e', 'f', 'i', 'x', '-', 195, 169, 0, 13, 10, 's', 'u', 'f', 'f', 'i', 'x'
};
static const char SHORT_TEXT[] = "\xc3\xa9\0\r\n";
static const unsigned char SHORT_BYTES[] = {195, 169, 0, 13, 10};
static const char MIXED_TEXT[] = "\xc3\xa9\0\r\nx\n";
static const unsigned char MIXED_BYTES[] = {195, 169, 0, 13, 10, 'x', 10, 10};
static const unsigned char EMPTY_LINE[] = {10};
static const unsigned char UNICODE_LINE[] = {195, 169, 10};
static const unsigned char INTERNAL_LINE[] = {'a', 10, 'b', 10, 10};

static void assert_string(const blorp_String* value, const void* bytes, size_t count) {
    assert(value && value->len == (long)count);
    assert(!count || memcmp(value->data, bytes, count) == 0);
}

static void assert_file_error(const blorp_String* message, const char* prefix, int code) {
    enum { ERROR_CAPACITY = sizeof("write_file: short write; errno=") + sizeof(int) * CHAR_BIT };
    char expected[ERROR_CAPACITY];
    int length = snprintf(expected, sizeof(expected), "%s%d", prefix, code);
    assert(length > 0 && length < ERROR_CAPACITY);
    assert_string(message, expected, (size_t)length);
    assert(blorp_utf8_is_valid((const unsigned char*)message->data, message->len));
}

static void assert_stream(FILE* stream, const unsigned char* expected, size_t count) {
    unsigned char bytes[sizeof(LONG_BYTES) + 1];
    assert(fseek(stream, 0, SEEK_SET) == 0);
    size_t length = fread(bytes, 1, sizeof(bytes), stream);
    assert(!ferror(stream) && length == count && feof(stream));
    assert(!count || memcmp(bytes, expected, count) == 0);
    assert(fclose(stream) == 0);
}

static void assert_balanced(long allocations, long releases, long live) {
    blorp_MemStats after = blorp_get_mem_stats();
    assert(after.total_allocations - allocations == after.total_releases - releases);
    assert(after.current_objects == live);
}

static void write_case(const char* file, const char* text, size_t length,
                       const unsigned char* expected, size_t count, enum WriteFault fault) {
    blorp_MemStats before = blorp_get_mem_stats();
    long allocations = before.total_allocations;
    long releases = before.total_releases;
    long live = before.current_objects;
    memset(watched, 0, sizeof(watched));
    memset(frees, 0, sizeof(frees));
    blorp_String* path = blorp_string_create_len(file, (long)strlen(file));
    blorp_String* content = blorp_string_create_len(text, (long)length);
    watched[INPUT_PATH] = path;
    write_path_bytes = path->data;
    watched[INPUT_CONTENT] = content;
    write_descriptor = -1;
    write_stream = NULL;
    close_attempts = transfer_attempts = strerror_calls = 0;
    write_fault = fault;
    observing_write = 1;
    blorp_Result* result = blorp_write_file(path, content);
    observing_write = 0;
    /* Check the actual descriptor before any oracle can open/reuse its number. */
    if (fault == OPEN_FAILURE) {
        assert(write_descriptor == -1 && close_attempts == 0);
        assert(strerror_calls == 0);
    } else {
        assert(write_descriptor >= 0);
        errno = 0;
        assert(fcntl(write_descriptor, F_GETFD) == -1 && errno == EBADF);
        assert(close_attempts == 1);
    }
    assert(transfer_attempts == (fault != OPEN_FAILURE && fault != FDOPEN_FAILURE && count > 0));
    assert(frees[PRIVATE_PATH] == 1);
    assert(frees[INPUT_PATH] == 0 && frees[INPUT_CONTENT] == 0);
    assert_string(path, file, strlen(file));
    assert_string(content, expected, count);
    assert(result);
    watched[OUTPUT_RESULT] = result;
    if (fault == NO_FAILURE) {
        assert(result->tag == BLORP_TAG_OK && result->release_mask == 0);
        assert(result->data.Ok.field0 == NULL);
    } else {
        assert(result->tag == BLORP_TAG_ERR && result->release_mask == 1UL);
        blorp_String* error = result->data.Err.field0;
        watched[ERROR_TEXT] = error;
        if (fault == OPEN_FAILURE || fault == FDOPEN_FAILURE) {
            assert_file_error(error, "write_file: open failed; errno=", fault == OPEN_FAILURE ? ENOENT : EMFILE);
        } else if (fault == CLOSE_FAILURE) {
            assert_file_error(error, "write_file: close failed; errno=", close_code);
        } else {
            assert_file_error(error, "write_file: short write; errno=", write_code);
        }
    }
    blorp_release(result);
    assert(frees[OUTPUT_RESULT] == 1 && frees[ERROR_TEXT] == (fault != NO_FAILURE));
    assert(frees[INPUT_PATH] == 0 && frees[INPUT_CONTENT] == 0);
    assert_string(path, file, strlen(file));
    assert_string(content, expected, count);
    blorp_release(path);
    blorp_release(content);
    assert(frees[INPUT_PATH] == 1 && frees[INPUT_CONTENT] == 1);
    assert_balanced(allocations, releases, live);
    if (fault == NO_FAILURE) {
        FILE* input = fopen(file, "rb");
        assert(input);
        assert_stream(input, expected, count);
    }
}

static void stderr_case(const char* text, size_t length,
                        const unsigned char* expected, size_t count) {
    blorp_MemStats before = blorp_get_mem_stats();
    long allocations = before.total_allocations;
    long releases = before.total_releases;
    long live = before.current_objects;
    blorp_String* message = blorp_string_create_len(text, (long)length);
    watched[INPUT_CONTENT] = message;
    frees[INPUT_CONTENT] = 0;
    FILE* output = tmpfile();
    FILE* error = tmpfile();
    assert(output && error);
    assert(fflush(stdout) == 0 && fflush(stderr) == 0);
    int saved_output = dup(STDOUT_FILENO);
    int saved_error = dup(STDERR_FILENO);
    assert(saved_output >= 0 && saved_error >= 0);
    int output_capture = dup2(fileno(output), STDOUT_FILENO);
    int error_capture = dup2(fileno(error), STDERR_FILENO);
    blorp_print_error(message);
    int output_flush = fflush(stdout);
    int error_flush = fflush(stderr);
    int output_restore = dup2(saved_output, STDOUT_FILENO);
    int error_restore = dup2(saved_error, STDERR_FILENO);
    int output_close = close(saved_output);
    int error_close = close(saved_error);
    /* Both original descriptors are restored before any payload/error assertion. */
    assert(output_capture == STDOUT_FILENO && error_capture == STDERR_FILENO);
    assert(output_flush == 0 && error_flush == 0);
    assert(output_restore == STDOUT_FILENO && error_restore == STDERR_FILENO);
    assert(output_close == 0 && error_close == 0);
    assert(frees[INPUT_CONTENT] == 0);
    assert_string(message, text, length);
    blorp_release(message);
    assert(frees[INPUT_CONTENT] == 1);
    assert_balanced(allocations, releases, live);
    assert_stream(output, NULL, 0);
    assert_stream(error, expected, count);
}

int main(int argc, char** argv) {
    enum { CASE_ARGUMENT = 1, PATH_ARGUMENT = 2, ARGUMENT_COUNT = 3 };
    assert(argc == ARGUMENT_COUNT);
    const char* name = argv[CASE_ARGUMENT];
    const char* path = argv[PATH_ARGUMENT];
    blorp_reset_mem_stats(); /* Enable once; each case compares scalar deltas. */
    blorp_MemStats enabled = blorp_get_mem_stats();
    assert(enabled.memory_stats_active && enabled.oracle_stats_active);
    if (strcmp(name, "counted_write") == 0) {
        write_case(path, LONG_TEXT, sizeof(LONG_TEXT) - 1,
                   LONG_BYTES, sizeof(LONG_BYTES), NO_FAILURE);
        write_case(path, SHORT_TEXT, sizeof(SHORT_TEXT) - 1,
                   SHORT_BYTES, sizeof(SHORT_BYTES), NO_FAILURE);
        write_case(path, "", sizeof("") - 1, NULL, 0, NO_FAILURE);
    } else if (strcmp(name, "write_open_errno_ascii") == 0) {
        if (unlink(path) != 0) assert(errno == ENOENT);
        size_t capacity = strlen(path) + sizeof("/child");
        char* missing = malloc(capacity);
        assert(missing);
        int length = snprintf(missing, capacity, "%s/child", path);
        assert(length > 0 && (size_t)length < capacity);
        write_case(missing, SHORT_TEXT, sizeof(SHORT_TEXT) - 1,
                   SHORT_BYTES, sizeof(SHORT_BYTES), OPEN_FAILURE);
        free(missing);
    } else if (strcmp(name, "stderr_empty") == 0) {
        stderr_case("", sizeof("") - 1, EMPTY_LINE, sizeof(EMPTY_LINE));
    } else if (strcmp(name, "stderr_unicode") == 0) {
        stderr_case("\xc3\xa9", sizeof("\xc3\xa9") - 1, UNICODE_LINE, sizeof(UNICODE_LINE));
    } else if (strcmp(name, "stderr_internal_lf") == 0) {
        stderr_case("a\nb\n", sizeof("a\nb\n") - 1, INTERNAL_LINE, sizeof(INTERNAL_LINE));
    } else if (strcmp(name, "stderr_counted") == 0) {
        stderr_case(MIXED_TEXT, sizeof(MIXED_TEXT) - 1, MIXED_BYTES, sizeof(MIXED_BYTES));
    } else {
        enum WriteFault fault;
        if (strcmp(name, "short_write") == 0) fault = SHORT_WRITE;
        else if (strcmp(name, "close_failure") == 0) fault = CLOSE_FAILURE;
        else if (strcmp(name, "write_close_failure") == 0) fault = WRITE_CLOSE_FAILURE;
        else if (strcmp(name, "fdopen_failure") == 0) fault = FDOPEN_FAILURE;
        else if (strcmp(name, "write_short_eintr") == 0) {
            fault = SHORT_WRITE;
            write_code = EINTR;
        } else if (strcmp(name, "write_close_eintr") == 0) {
            fault = CLOSE_FAILURE;
            close_code = EINTR;
        } else abort();
        write_case(path, SHORT_TEXT, sizeof(SHORT_TEXT) - 1,
                   SHORT_BYTES, sizeof(SHORT_BYTES), fault);
    }
    return 0;
}
