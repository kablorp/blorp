#define _GNU_SOURCE
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int observing_read;
static FILE* read_stream;
static int read_descriptor;
static int read_opens;
static int read_closes;
static void* staging_object;
static int staging_frees;
enum ReadFault { READ_NORMAL, SEEK_END_ERROR, TELL_ERROR, SEEK_START_ERROR, READ_IO_ERROR, READ_EOF, READ_CLOSE_ERROR };
enum { ERROR_PATH, ERROR_RESULT, ERROR_PAYLOAD, PRIVATE_PATH, ERROR_OBJECTS };
enum { EOF_EXTRA_BYTE = 1 };
enum { NO_CLOSE_ERROR = 0 };
static enum ReadFault read_fault;
static int error_case_active, primary_code, cleanup_code;
static int seek_calls, tell_calls, transfer_calls, actual_eof;
static void* error_objects[ERROR_OBJECTS];
static int error_frees[ERROR_OBJECTS];
static const void* read_path_bytes;
static void* observed_memcpy(void*, const void*, size_t);

static int observed_fseek(FILE* stream, long offset, int whence) {
    int result = fseek(stream, offset, whence);
    if (error_case_active && stream == read_stream) {
        seek_calls++;
        if ((read_fault == SEEK_END_ERROR && whence == SEEK_END) ||
            (read_fault == SEEK_START_ERROR && whence == SEEK_SET)) {
            assert(seek_calls == (read_fault == SEEK_END_ERROR ? 1 : 2));
            errno = primary_code;
            return -1;
        }
    }
    return result;
}

static long observed_ftell(FILE* stream) {
    long length = ftell(stream);
    if (error_case_active && stream == read_stream) {
        tell_calls++;
        if (read_fault == TELL_ERROR) {
            assert(tell_calls == 1);
            errno = primary_code;
            return -1;
        }
        if (read_fault == READ_EOF) {
            assert(length >= 0 && length < LONG_MAX);
            return length + EOF_EXTRA_BYTE;
        }
    }
    return length;
}

static int observed_ferror(FILE* stream) {
    int result = ferror(stream);
    if (error_case_active && stream == read_stream) {
        if (read_fault == READ_IO_ERROR) {
            errno = EINVAL;
            return 1;
        }
    }
    return result;
}

static FILE* observed_fdopen(int descriptor, const char* mode) {
    FILE* stream = fdopen(descriptor, mode);
    if (observing_read) {
        read_stream = stream;
        read_descriptor = descriptor;
        read_opens++;
    }
    return stream;
}

static int observed_fclose(FILE* stream) {
    if (observing_read) assert(read_stream != NULL && stream == read_stream);
    int observed = observing_read && stream == read_stream;
    if (observed) {
        read_closes++;
        read_stream = NULL;
    }
    int result = fclose(stream);
    if (observed && error_case_active && cleanup_code) {
        errno = cleanup_code;
        return EOF;
    }
    return result;
}

static void observed_free(void* object) {
    int staging_released = object && object == staging_object;
    if (object && object == staging_object) {
        staging_frees++;
        staging_object = NULL; /* Track this allocation, not later address reuse. */
    }
    for (int index = 0; index < ERROR_OBJECTS; index++) {
        if (object && object == error_objects[index]) {
            if (index == ERROR_PATH) read_path_bytes = NULL;
            error_objects[index] = NULL;
            error_frees[index]++;
        }
    }
    free(object);
    if (error_case_active && staging_released) errno = E2BIG;
}

static size_t observed_fread(void*, size_t, size_t, FILE*);
#define MINICORO_IMPL
#include "minicoro.h"
#define fdopen observed_fdopen
#define fclose observed_fclose
#define fread observed_fread
#define fseek observed_fseek
#define ftell observed_ftell
#define ferror observed_ferror
#define free observed_free
#define memcpy observed_memcpy
#include "runtime.c"
#undef fdopen
#undef fclose
#undef fread
#undef fseek
#undef ftell
#undef ferror
#undef free
#undef memcpy

static void* observed_memcpy(void* destination, const void* source, size_t count) {
    if (error_case_active && source == read_path_bytes) {
        assert(error_frees[ERROR_PATH] == 0 && error_frees[PRIVATE_PATH] == 0);
        assert(error_objects[PRIVATE_PATH] == NULL);
        error_objects[PRIVATE_PATH] = destination;
    }
    return memcpy(destination, source, count);
}

static size_t observed_fread(void* bytes, size_t width, size_t count, FILE* stream) {
    if (observing_read && stream == read_stream) {
        staging_object = (char*)bytes - offsetof(blorp_String, data);
        if (error_case_active) {
            transfer_calls++;
            assert(transfer_calls == 1);
            if (read_fault == READ_IO_ERROR) {
                assert(count > 0);
                size_t length = fread(bytes, width, count - 1, stream);
                errno = primary_code;
                return length;
            }
            size_t length = fread(bytes, width, count, stream);
            actual_eof = feof(stream) && !ferror(stream);
            if (read_fault == READ_EOF) errno = primary_code;
            return length;
        }
    }
    return fread(bytes, width, count, stream);
}

static const char INVALID_UTF8_ERROR[] =
    "read_file: invalid UTF-8; save the file as UTF-8, "
    "or use read_bytes for binary data";
static blorp_MemStats before_read;

static blorp_Result* read_case(const char* path, const unsigned char* bytes, size_t count) {
    FILE* output = fopen(path, "wb");
    assert(output && fwrite(bytes, 1, count, output) == count);
    assert(fclose(output) == 0);
    blorp_String* name = blorp_string_create(path);
    read_stream = NULL;
    read_descriptor = -1;
    read_opens = read_closes = staging_frees = 0;
    staging_object = NULL;
    blorp_reset_mem_stats();
    before_read = blorp_get_mem_stats();
    assert(before_read.memory_stats_active && before_read.oracle_stats_active);
    observing_read = 1;
    blorp_Result* result = blorp_read_file(name);
    observing_read = 0;
    blorp_release(name);
    return result;
}

static void assert_rejection(blorp_Result* result) {
    assert(result && result->tag == BLORP_TAG_ERR);
    /* Result ABI bit zero owns its sole managed payload. */
    assert(result->release_mask == 1UL);
    const blorp_String* message = result->data.Err.field0;
    assert(message && message->len == (long)sizeof(INVALID_UTF8_ERROR) - 1);
    assert(memcmp(message->data, INVALID_UTF8_ERROR, sizeof(INVALID_UTF8_ERROR) - 1) == 0);
}

static void assert_clean(void) {
    blorp_MemStats after = blorp_get_mem_stats();
    assert(after.current_objects == 0);
    assert(after.total_allocations == after.total_releases);
}

static void assert_rejected(const char* path, const unsigned char* bytes, size_t count) {
    blorp_Result* result = read_case(path, bytes, count);
    assert_rejection(result);
    blorp_release(result);
    assert_clean();
}

#define REJECT(text) assert_rejected(path, (const unsigned char*)(text), sizeof(text) - 1)

static void assert_valid(const char* path, const unsigned char* bytes, size_t count) {
    blorp_Result* result = read_case(path, bytes, count);
    assert(result && result->tag == BLORP_TAG_OK && result->release_mask == 1UL);
    blorp_String* contents = result->data.Ok.field0;
    assert(contents && contents->len == (long)count);
    assert(memcmp(contents->data, bytes, count) == 0);
    blorp_MemStats after = blorp_get_mem_stats();
    /* Existing success budget: one String, one Result and one raw path copy. */
    enum { READ_MANAGED_ALLOCATIONS = 2, READ_PATH_ALLOCATIONS = 1 };
    assert(after.total_allocations == READ_MANAGED_ALLOCATIONS);
    assert(after.backing_libc_malloc_events - before_read.backing_libc_malloc_events == READ_MANAGED_ALLOCATIONS);
    assert(after.raw_buffer_malloc_events - before_read.raw_buffer_malloc_events == READ_PATH_ALLOCATIONS);
    assert(after.raw_buffer_calloc_events == before_read.raw_buffer_calloc_events);
    assert(after.raw_buffer_realloc_events == before_read.raw_buffer_realloc_events);
    assert(after.raw_buffer_aligned_events == before_read.raw_buffer_aligned_events);
    if (!count) staging_object = contents; /* An empty read never calls fread. */
    blorp_release(result);
    assert(staging_frees == 1);
    assert_clean();
}

static void read_error_case(const char* path, enum ReadFault fault,
                            int code, int cleanup, const char* prefix) {
    static const unsigned char bytes[] = {'x', 0, 255};
    FILE* output = fopen(path, "wb");
    assert(output && fwrite(bytes, 1, sizeof(bytes), output) == sizeof(bytes));
    assert(fclose(output) == 0);
    blorp_MemStats before = blorp_get_mem_stats();
    long allocations = before.total_allocations;
    long releases = before.total_releases;
    long live = before.current_objects;
    memset(error_objects, 0, sizeof(error_objects));
    memset(error_frees, 0, sizeof(error_frees));
    blorp_String* file = blorp_string_create_len(path, (long)strlen(path));
    error_objects[ERROR_PATH] = file;
    read_path_bytes = file->data;
    read_fault = fault;
    primary_code = code;
    cleanup_code = cleanup;
    read_stream = NULL;
    read_descriptor = -1;
    read_opens = read_closes = staging_frees = 0;
    seek_calls = tell_calls = transfer_calls = actual_eof = 0;
    staging_object = NULL;
    observing_read = 1;
    error_case_active = 1;
    blorp_Result* result = blorp_read_file(file);
    error_case_active = 0;
    observing_read = 0;
    errno = 0;
    assert(read_descriptor >= 0 && fcntl(read_descriptor, F_GETFD) == -1 && errno == EBADF);
    assert(read_opens == 1 && read_closes == 1);
    assert(error_frees[PRIVATE_PATH] == 1);
    assert(seek_calls == (fault == SEEK_END_ERROR || fault == TELL_ERROR ? 1 : 2));
    assert(tell_calls == (fault == SEEK_END_ERROR ? 0 : 1));
    int has_staging = fault == READ_IO_ERROR || fault == READ_EOF || fault == READ_CLOSE_ERROR;
    assert(transfer_calls == has_staging && staging_frees == has_staging);
    if (fault == READ_EOF) assert(actual_eof);
    assert(error_frees[ERROR_PATH] == 0 && file->len == (long)strlen(path));
    assert(memcmp(file->data, path, (size_t)file->len) == 0);
    assert(result && result->tag == BLORP_TAG_ERR && result->release_mask == 1UL);
    blorp_String* message = result->data.Err.field0;
    enum { ERROR_CAPACITY = sizeof("read_file: seek start failed; errno=") + sizeof(int) * CHAR_BIT };
    char expected[ERROR_CAPACITY];
    int length = fault == READ_EOF ? snprintf(expected, sizeof(expected), "%s", prefix)
                                  : snprintf(expected, sizeof(expected), "%s%d", prefix, code);
    assert(length > 0 && length < ERROR_CAPACITY && message && message->len == length);
    assert(memcmp(message->data, expected, (size_t)length) == 0);
    error_objects[ERROR_RESULT] = result;
    error_objects[ERROR_PAYLOAD] = message;
    blorp_release(result);
    assert(error_frees[ERROR_RESULT] == 1 && error_frees[ERROR_PAYLOAD] == 1);
    assert(error_frees[ERROR_PATH] == 0);
    assert(file->len == (long)strlen(path));
    assert(memcmp(file->data, path, (size_t)file->len) == 0);
    blorp_release(file);
    assert(error_frees[ERROR_PATH] == 1);
    blorp_MemStats after = blorp_get_mem_stats();
    assert(after.total_allocations - allocations == after.total_releases - releases);
    assert(after.current_objects == live);
    assert(unlink(path) == 0);
}

int main(int argc, char** argv) {
    enum { CASE_ARGUMENT = 1, PATH_ARGUMENT = 2, ARGUMENT_COUNT = 3 };
    assert(argc == ARGUMENT_COUNT);
    const char* name = argv[CASE_ARGUMENT];
    const char* path = argv[PATH_ARGUMENT];
    blorp_reset_mem_stats(); /* New cases compare scalar deltas; legacy boundaries stay below. */
    if (strcmp(name, "read_seek_end_errno") == 0) {
        read_error_case(path, SEEK_END_ERROR, EINTR, ENOSPC, "read_file: seek end failed; errno=");
        return 0;
    } else if (strcmp(name, "read_tell_errno") == 0) {
        read_error_case(path, TELL_ERROR, EIO, NO_CLOSE_ERROR, "read_file: tell failed; errno=");
        return 0;
    } else if (strcmp(name, "read_seek_start_errno") == 0) {
        read_error_case(path, SEEK_START_ERROR, ESPIPE, NO_CLOSE_ERROR, "read_file: seek start failed; errno=");
        return 0;
    } else if (strcmp(name, "read_io_errno") == 0) {
        read_error_case(path, READ_IO_ERROR, EIO, NO_CLOSE_ERROR, "read_file: read failed; errno=");
        read_error_case(path, READ_IO_ERROR, EINTR, NO_CLOSE_ERROR, "read_file: read failed; errno=");
        return 0;
    } else if (strcmp(name, "read_io_cleanup_errno") == 0) {
        read_error_case(path, READ_IO_ERROR, EIO, ENOSPC, "read_file: read failed; errno=");
        return 0;
    } else if (strcmp(name, "read_eof_short") == 0) {
        read_error_case(path, READ_EOF, EIO, NO_CLOSE_ERROR, "read_file: short read");
        read_error_case(path, READ_EOF, EIO, ENOSPC, "read_file: short read");
        return 0;
    } else if (strcmp(name, "read_close_errno") == 0) {
        read_error_case(path, READ_CLOSE_ERROR, ENOSPC, ENOSPC, "read_file: close failed; errno=");
        read_error_case(path, READ_CLOSE_ERROR, EINTR, EINTR, "read_file: close failed; errno=");
        return 0;
    }
    if (strcmp(name, "open_errno") == 0) {
        blorp_String* file = blorp_string_create(path);
        blorp_reset_mem_stats();
        blorp_Result* result = blorp_read_file(file);
        assert(result && result->tag == BLORP_TAG_ERR);
        /* Decimal int text cannot require more digits than its bit width. */
        enum { ERROR_CAPACITY = sizeof("read_file: open failed; errno=") + sizeof(int) * CHAR_BIT };
        char expected[ERROR_CAPACITY];
        int length = snprintf(expected, sizeof(expected), "read_file: open failed; errno=%d", ENOENT);
        assert(length > 0 && length < ERROR_CAPACITY);
        const blorp_String* message = result->data.Err.field0;
        assert(message && message->len == length);
        assert(memcmp(message->data, expected, (size_t)length) == 0);
        blorp_release(result);
        blorp_release(file);
        assert_clean();
        return 0;
    }
    if (strcmp(name, "documentation") == 0) {
        REJECT("---\n\xff\n---\nfunc main() -> Int:\n    0\n");
    } else if (strcmp(name, "forbidden") == 0) {
        const unsigned char leads[] = {0x80, 0xbf, 0xc0, 0xc1};
        for (size_t index = 0; index < sizeof(leads); index++) {
            assert_rejected(path, leads + index, sizeof(leads[index]));
        }
        for (unsigned int lead = 0xf5; lead <= 0xff; lead++) {
            const unsigned char byte = (unsigned char)lead;
            assert_rejected(path, &byte, sizeof(byte));
        }
    } else if (strcmp(name, "overlong") == 0) {
        REJECT("\xc0\x80");
        REJECT("\xe0\x80\x80");
        REJECT("\xf0\x80\x80\x80");
    } else if (strcmp(name, "surrogate") == 0) {
        REJECT("\xed\xa0\x80");
        REJECT("\xed\xbf\xbf");
    } else if (strcmp(name, "above_max") == 0) {
        REJECT("\xf4\x90\x80\x80");
        REJECT("\xf5\x80\x80\x80");
    } else if (strcmp(name, "truncated") == 0) {
        REJECT("\xc2");
        REJECT("\xe2");
        REJECT("\xe2\x82");
        REJECT("\xe0");
        REJECT("\xe0\xa0");
        REJECT("\xed");
        REJECT("\xed\x9f");
        REJECT("\xef");
        REJECT("\xef\xbf");
        REJECT("\xf0");
        REJECT("\xf0\x9f");
        REJECT("\xf0\x9f\x98");
        REJECT("\xf1");
        REJECT("\xf1\x80");
        REJECT("\xf1\x80\x80");
        REJECT("\xf4");
        REJECT("\xf4\x8f");
        REJECT("\xf4\x8f\xbf");
    } else if (strcmp(name, "continuation") == 0) {
        REJECT("\xc2\x7f");
        REJECT("\xe2\x28\xa1");
        REJECT("\xe2\x82\x41");
        REJECT("\xf0\x90\xff\x80");
        REJECT("\xf0\x90\x80\x41");
    } else if (strcmp(name, "after_nul") == 0) {
        REJECT("a\0\xff");
    } else if (strcmp(name, "empty") == 0) {
        assert_valid(path, (const unsigned char*)"", 0);
    } else if (strcmp(name, "contents") == 0) {
        static const unsigned char bytes[] =
            "\xef\xbb\xbf""a\r\n\0\xc3\xa9\xe6\x97\xa5\xf0\x9f\x98\x80"
            "e\xcc\x81\xc2\x80\xdf\xbf\xe0\xa0\x80\xed\x9f\xbf"
            "\xee\x80\x80\xef\xb7\x90\xef\xbf\xbf\xf0\x90\x80\x80\xf4\x8f\xbf\xbf";
        assert_valid(path, bytes, sizeof(bytes) - 1);
    } else if (strcmp(name, "staging_free") == 0) {
        blorp_Result* result = read_case(path, (const unsigned char*)"\xff", 1);
        assert_rejection(result);
        assert(staging_frees == 1);
        blorp_release(result);
        assert_clean();
    } else if (strcmp(name, "closed") == 0) {
        blorp_Result* result = read_case(path, (const unsigned char*)"\xff", 1);
        assert_rejection(result);
        assert(read_opens == 1 && read_closes == 1);
        errno = 0;
        assert(fcntl(read_descriptor, F_GETFD) == -1 && errno == EBADF);
        blorp_release(result);
        assert_clean();
    } else {
        assert(!"unknown file-admission case");
    }
    assert(unlink(path) == 0);
    return 0;
}
