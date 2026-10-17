#define _GNU_SOURCE
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
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
    if (observing_read && stream == read_stream) read_closes++;
    return fclose(stream);
}

static void observed_free(void* object) {
    if (object && object == staging_object) {
        staging_frees++;
        staging_object = NULL; /* Track this allocation, not later address reuse. */
    }
    free(object);
}

static size_t observed_fread(void*, size_t, size_t, FILE*);
#define MINICORO_IMPL
#include "minicoro.h"
#define fdopen observed_fdopen
#define fclose observed_fclose
#define fread observed_fread
#define free observed_free
#include "runtime.c"
#undef fdopen
#undef fclose
#undef fread
#undef free

static size_t observed_fread(void* bytes, size_t width, size_t count, FILE* stream) {
    if (observing_read && stream == read_stream) {
        staging_object = (char*)bytes - offsetof(blorp_String, data);
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

int main(int argc, char** argv) {
    enum { CASE_ARGUMENT = 1, PATH_ARGUMENT = 2, ARGUMENT_COUNT = 3 };
    assert(argc == ARGUMENT_COUNT);
    const char* name = argv[CASE_ARGUMENT];
    const char* path = argv[PATH_ARGUMENT];
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
