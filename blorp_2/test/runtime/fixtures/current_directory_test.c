#include <assert.h>
#include <errno.h>
#include <inttypes.h>
#include <limits.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

enum { MAX_ALLOCATIONS = 32, LONG_PATH_LENGTH = 5000, REAL_PATH_CAPACITY = 4096 };
struct Allocation { void *pointer; int live; };
static struct Allocation allocations[MAX_ALLOCATIONS];
static size_t allocation_count, live_count, staging_frees, growth_count, query_count;
static void *staging;
static const char *script_path;
static int script_errno, grow_then_fail, clobber_errno, bad_spare_byte, real_query;

static size_t allocation_slot(void *pointer) {
    for (size_t cursor = allocation_count; cursor > 0; cursor--) {
        if (allocations[cursor - 1].live && allocations[cursor - 1].pointer == pointer)
            return cursor - 1;
    }
    abort();
}

static void *observed_malloc(size_t bytes) {
    void *pointer = malloc(bytes);
    assert(pointer && allocation_count < MAX_ALLOCATIONS);
    allocations[allocation_count++] = (struct Allocation){pointer, 1};
    live_count++;
    return pointer;
}

static void *observed_realloc(void *pointer, size_t bytes) {
    const size_t slot = allocation_slot(pointer);
    void *grown = realloc(pointer, bytes);
    assert(grown);
    allocations[slot].pointer = grown;
    staging = grown;
    growth_count++;
    return grown;
}

static void observed_free(void *pointer) {
    if (!pointer) return;
    const size_t slot = allocation_slot(pointer);
    const int was_staging = pointer == staging;
    allocations[slot].live = 0;
    live_count--;
    if (was_staging) { staging = NULL; staging_frees++; }
    free(pointer);
    if (was_staging && clobber_errno) errno = EINTR;
}

static char *observed_getcwd(char *buffer, size_t capacity) {
    staging = buffer;
    query_count++;
    if (real_query) return getcwd(buffer, capacity);
    if (grow_then_fail && query_count == 1) { errno = ERANGE; return NULL; }
    if (script_errno) { errno = script_errno; return NULL; }
    const size_t length = strlen(script_path);
    if (capacity <= length) { errno = ERANGE; return NULL; }
    memcpy(buffer, script_path, length + 1);
    if (bad_spare_byte) { assert(capacity > length + 1); buffer[length + 1] = (char)0xff; }
    return buffer;
}

/* Aliases apply only to the unmodified production fragments, after headers. */
#define malloc observed_malloc
#define realloc observed_realloc
#define free observed_free
#define getcwd observed_getcwd
#include "current_directory_runtime.c"
#undef getcwd
#undef free
#undef realloc
#undef malloc

static struct blorp_string *query(uint8_t expected_status, const char *expected) {
    struct blorp_string *payload = NULL;
    const size_t before_allocations = allocation_count, before_frees = staging_frees;
    const uint8_t status = blorp_get_current_directory(&payload);
    assert(status == expected_status && payload);
    assert(atomic_load(&payload->references) == 1);
    assert(payload->length == (int64_t)strlen(expected));
    assert(memcmp(payload->bytes, expected, strlen(expected) + 1) == 0);
    assert(blorp_utf8_is_valid(payload->bytes, (size_t)payload->length));
    assert(allocation_count == before_allocations + 2); /* staging + fresh String */
    assert(staging == NULL && staging_frees == before_frees + 1);
    return payload;
}

static void release_result(uint8_t success, struct blorp_string *payload) {
    struct blorp_u_0 result;
    if (success) {
        result = (struct blorp_u_0){.tag = blorp_v_0_0, .payload.blorp_up_0 = {.blorp_uf_0 = payload}};
    } else {
        result = (struct blorp_u_0){.tag = blorp_v_0_1, .payload.blorp_up_1 = {.blorp_uf_0 = payload}};
    }
    blorp_union_drop_0(result);
}

static void check_error(int error) {
    char expected[sizeof("get_current_directory: failed; errno=") + sizeof(int) * CHAR_BIT];
    const int length = snprintf(expected, sizeof expected, "get_current_directory: failed; errno=%d", error);
    assert(length > 0 && (size_t)length < sizeof expected);
    release_result(0, query(0, expected));
}

int main(int argc, char **argv) {
    assert(argc == 2);
    const char *name = argv[1];
    script_path = "/valid";
    if (strcmp(name, "real") == 0) {
        char expected[REAL_PATH_CAPACITY];
        assert(getcwd(expected, sizeof expected)); /* ordinary short CWD only */
        real_query = 1;
        release_result(1, query(1, expected));
    } else if (strcmp(name, "growth") == 0) {
        char path[LONG_PATH_LENGTH + 1];
        memset(path, 'a', LONG_PATH_LENGTH);
        path[0] = '/'; path[LONG_PATH_LENGTH] = '\0'; script_path = path;
        release_result(1, query(1, path));
        assert(growth_count > 0 && query_count == growth_count + 1);
    } else if (strcmp(name, "growth_error") == 0) {
        grow_then_fail = 1; script_errno = EACCES;
        check_error(EACCES);
        assert(growth_count == 1 && query_count == 2);
    } else if (strcmp(name, "eintr") == 0) {
        script_errno = EINTR;
        check_error(EINTR);
        assert(query_count == 1 && growth_count == 0);
    } else if (strcmp(name, "saved_errno") == 0) {
        script_errno = EACCES; clobber_errno = 1;
        check_error(EACCES);
    } else if (strcmp(name, "utf8") == 0) {
        script_path = "/";
        release_result(1, query(1, script_path));
        script_path = "/ é🙂 \t";
        release_result(1, query(1, script_path));
    } else if (strcmp(name, "after_terminator") == 0) {
        bad_spare_byte = 1;
        release_result(1, query(1, script_path));
    } else if (strcmp(name, "malformed") == 0) {
        const char *paths[] = {"/\xc0\x80", "/\xed\xa0\x80", "/\xe2\x82", "/x\xff", "/\xf4\x90\x80\x80", "/\x80"};
        for (size_t index = 0; index < sizeof paths / sizeof *paths; index++) {
            script_path = paths[index];
            release_result(0, query(0, "get_current_directory: invalid UTF-8; use a working directory with a UTF-8 path"));
        }
    } else if (strcmp(name, "empty") == 0 || strcmp(name, "relative") == 0) {
        script_path = strcmp(name, "empty") == 0 ? "" : "relative";
        release_result(0, query(0, "get_current_directory: native path must be nonempty and absolute"));
    } else if (strcmp(name, "fresh") == 0) {
        struct blorp_string *first = query(1, script_path);
        struct blorp_string *second = query(1, script_path);
        assert(first != second && live_count == 2);
        release_result(1, first); release_result(1, second);
    } else if (strcmp(name, "owned_ok") == 0) {
        struct blorp_string *payload = query(1, script_path);
        const size_t slot = allocation_slot(payload);
        release_result(1, payload);
        assert(!allocations[slot].live);
    } else if (strcmp(name, "owned_error") == 0) {
        script_errno = EACCES;
        check_error(EACCES);
    } else {
        abort();
    }
    assert(allocation_count > 0 && live_count == 0 && staging == NULL);
    return 0;
}
