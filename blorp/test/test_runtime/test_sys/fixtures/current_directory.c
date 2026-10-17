#define _GNU_SOURCE
#include <assert.h>
#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

enum QueryMode { REAL_DIRECTORY, SCRIPTED_DIRECTORY, QUERY_ERROR, GROW_THEN_ERROR };
static enum QueryMode query_mode;
static const char* pathname;
static int query_errno;
static int observing;
static int clobber_errno;
static int invalid_spare_byte;
static void* staging;
static int staging_frees;
static int query_count;
static int growth_count;
static long raw_malloc_before_query;
static long raw_realloc_before_query;
static size_t previous_capacity;
static void* payload;
static int payload_frees;

static char* observed_getcwd(char* buffer, size_t capacity) {
    if (!observing) return getcwd(buffer, capacity);
    if (!staging) previous_capacity = 0;
    else assert(staging == buffer);
    staging = buffer;
    assert(capacity > previous_capacity);
    previous_capacity = capacity;
    query_count++;
    if (query_mode == REAL_DIRECTORY) return getcwd(buffer, capacity);
    if (query_mode == QUERY_ERROR) {
        errno = query_errno;
        return NULL;
    }
    size_t length = strlen(pathname);
    if (capacity <= length) {
        errno = ERANGE;
        return NULL;
    }
    if (query_mode == GROW_THEN_ERROR) {
        errno = query_errno;
        return NULL;
    }
    memcpy(buffer, pathname, length + 1);
    if (invalid_spare_byte) {
        assert(capacity > length + 1);
        buffer[length + 1] = (char)0xff;
    }
    return buffer;
}

static void* observed_realloc(void* before, size_t capacity) {
    int tracked = observing && before == staging;
    void* after = realloc(before, capacity);
    if (tracked && after) {
        staging = after;
        growth_count++;
    }
    return after;
}

static void observed_free(void* object) {
    int releasing_staging = object && observing && object == staging;
    if (releasing_staging) {
        staging = NULL;
        staging_frees++;
    }
    if (object && object == payload) {
        payload = NULL;
        payload_frees++;
    }
    free(object);
    if (releasing_staging && clobber_errno) errno = EINTR;
}

#define MINICORO_IMPL
#include "minicoro.h"
#define getcwd observed_getcwd
#define realloc observed_realloc
#define free observed_free
#include "runtime.c"
#undef getcwd
#undef realloc
#undef free

static const char INVALID_UTF8_ERROR[] =
    "get_current_directory: invalid UTF-8; use a working directory with a UTF-8 path";
static const char INVALID_SHAPE_ERROR[] =
    "get_current_directory: native path must be nonempty and absolute";

static void reset_counts(void) {
    blorp_reset_mem_stats();
    blorp_MemStats stats = blorp_get_mem_stats();
    assert(stats.memory_stats_active && stats.oracle_stats_active);
}

static blorp_Result* query(enum QueryMode mode, const char* path, int error_code) {
    query_mode = mode;
    pathname = path;
    query_errno = error_code;
    staging = NULL;
    staging_frees = query_count = growth_count = 0;
    raw_malloc_before_query = blorp_read_memory_counter(BLORP_MEMORY_COUNTER_RAW_MALLOC_EVENTS);
    raw_realloc_before_query = blorp_read_memory_counter(BLORP_MEMORY_COUNTER_RAW_REALLOC_EVENTS);
    observing = 1;
    blorp_Result* result = blorp_get_current_directory();
    observing = 0;
    assert(query_count > 0 && staging_frees == 1 && staging == NULL);
    return result;
}

static void assert_text(const blorp_String* value, const char* expected) {
    size_t length = strlen(expected);
    assert(value && value->len == (long)length);
    assert(memcmp(value->data, expected, length) == 0);
    assert(value->data[length] == '\0');
}

static void assert_ok(blorp_Result* result, const char* expected) {
    assert(result && result->tag == BLORP_TAG_OK && result->release_mask == 1UL);
    assert_text(result->data.Ok.field0, expected);
}

static void assert_error(blorp_Result* result, const char* expected) {
    assert(result && result->tag == BLORP_TAG_ERR && result->release_mask == 1UL);
    assert_text(result->data.Err.field0, expected);
}

static void assert_errno_error(blorp_Result* result, int error_code) {
    enum { ERROR_CAPACITY = sizeof("get_current_directory: failed; errno=") + sizeof(int) * CHAR_BIT };
    char expected[ERROR_CAPACITY];
    int length = snprintf(expected, sizeof expected,
        "get_current_directory: failed; errno=%d", error_code);
    assert(length > 0 && length < ERROR_CAPACITY);
    assert_error(result, expected);
}

static void drop_payload_once(blorp_Result* result) {
    payload = result->tag == BLORP_TAG_OK ? result->data.Ok.field0 : result->data.Err.field0;
    payload_frees = 0;
    blorp_release(result);
    assert(payload_frees == 1 && payload == NULL);
}

static void assert_clean(long allocations) {
    blorp_MemStats stats = blorp_get_mem_stats();
    assert(stats.total_allocations == allocations);
    assert(stats.total_releases == allocations && stats.current_objects == 0);
}

static void finish(blorp_Result* result, long allocations, long earlier_releases) {
    blorp_MemStats stats = blorp_get_mem_stats();
    assert(stats.total_allocations == allocations);
    assert(stats.total_releases == earlier_releases && stats.current_objects == 2);
    assert(stats.raw_buffer_malloc_events - raw_malloc_before_query == 1);
    assert(stats.raw_buffer_realloc_events - raw_realloc_before_query == growth_count);
    drop_payload_once(result);
    assert_clean(allocations);
}

int main(int argc, char** argv) {
    enum { CASE_ARGUMENT = 1, ARGUMENT_COUNT = 2, LEGACY_CAPACITY = 4096,
        LONG_PATH_LENGTH = LEGACY_CAPACITY + 257 };
    assert(argc == ARGUMENT_COUNT);
    const char* name = argv[CASE_ARGUMENT];
    char long_path[LONG_PATH_LENGTH + 1];
    memset(long_path, 'a', LONG_PATH_LENGTH);
    long_path[0] = '/';
    long_path[LONG_PATH_LENGTH] = '\0';
    reset_counts();
    if (strcmp(name, "real") == 0) {
        char expected[LEGACY_CAPACITY];
        assert(getcwd(expected, sizeof expected));
        blorp_Result* result = query(REAL_DIRECTORY, NULL, 0);
        assert_ok(result, expected);
        assert(expected[0] == '/');
        finish(result, 2, 0);
    } else if (strcmp(name, "growth") == 0) {
        blorp_Result* result = query(SCRIPTED_DIRECTORY, long_path, 0);
        assert(query_count > 1 && growth_count == query_count - 1);
        assert(previous_capacity > LONG_PATH_LENGTH);
        assert_ok(result, long_path);
        finish(result, 2, 0);
    } else if (strcmp(name, "growth_error") == 0) {
        blorp_Result* result = query(GROW_THEN_ERROR, long_path, EACCES);
        assert(query_count > 1 && growth_count == query_count - 1);
        assert_errno_error(result, EACCES);
        finish(result, 3, 1);
    } else if (strcmp(name, "eintr") == 0) {
        blorp_Result* result = query(QUERY_ERROR, NULL, EINTR);
        assert(query_count == 1);
        assert_errno_error(result, EINTR);
        finish(result, 3, 1);
    } else if (strcmp(name, "saved_errno") == 0) {
        clobber_errno = 1;
        blorp_Result* result = query(QUERY_ERROR, NULL, EACCES);
        assert_errno_error(result, EACCES);
        finish(result, 3, 1);
    } else if (strcmp(name, "utf8") == 0) {
        const char* paths[] = { "/", "/\xc3\xa9/\xf0\x9f\x98\x80/\n " };
        for (size_t index = 0; index < sizeof paths / sizeof paths[0]; index++) {
            reset_counts();
            blorp_Result* result = query(SCRIPTED_DIRECTORY, paths[index], 0);
            assert_ok(result, paths[index]);
            finish(result, 2, 0);
        }
    } else if (strcmp(name, "after_terminator") == 0) {
        invalid_spare_byte = 1;
        blorp_Result* result = query(SCRIPTED_DIRECTORY, "/path", 0);
        assert_ok(result, "/path");
        finish(result, 2, 0);
    } else if (strcmp(name, "malformed") == 0) {
        const char* paths[] = { "/\xc0\x80", "/\xed\xa0\x80", "/\xe2\x82", "/valid\xff" };
        for (size_t index = 0; index < sizeof paths / sizeof paths[0]; index++) {
            reset_counts();
            blorp_Result* result = query(SCRIPTED_DIRECTORY, paths[index], 0);
            assert_error(result, INVALID_UTF8_ERROR);
            finish(result, 2, 0);
        }
    } else if (strcmp(name, "empty") == 0 || strcmp(name, "relative") == 0) {
        const char* path = strcmp(name, "empty") == 0 ? "" : "relative/path";
        blorp_Result* result = query(SCRIPTED_DIRECTORY, path, 0);
        assert_error(result, INVALID_SHAPE_ERROR);
        finish(result, 2, 0);
    } else if (strcmp(name, "fresh") == 0) {
        blorp_Result* first = query(SCRIPTED_DIRECTORY, "/kept", 0);
        blorp_Result* second = query(SCRIPTED_DIRECTORY, "/kept", 0);
        assert_ok(first, "/kept");
        assert_ok(second, "/kept");
        assert(first->data.Ok.field0 != second->data.Ok.field0);
        drop_payload_once(first);
        assert_ok(second, "/kept");
        drop_payload_once(second);
        assert_clean(4);
    } else if (strcmp(name, "owned_ok") == 0) {
        blorp_Result* result = query(SCRIPTED_DIRECTORY, "/owned", 0);
        assert_ok(result, "/owned");
        finish(result, 2, 0);
    } else if (strcmp(name, "owned_error") == 0) {
        blorp_Result* result = query(QUERY_ERROR, NULL, ENOENT);
        assert_errno_error(result, ENOENT);
        finish(result, 3, 1);
    } else {
        assert(0 && "unknown current-directory case");
    }
    return 0;
}
