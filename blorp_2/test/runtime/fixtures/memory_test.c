#include <assert.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

enum { MAX_BACKING_OCCURRENCES = 4 };
/* Diagnostics start reads BLORP_LEAK_CHECK and BLORP_ALLOCATION_SITES; normal mode reads neither. */
enum { ENVIRONMENT_VARIABLES_READ_AT_START = 2 };
static uintptr_t allocated[MAX_BACKING_OCCURRENCES], released[MAX_BACKING_OCCURRENCES];
static size_t allocation_count, release_count, resize_count, environment_queries;
static int fail_allocation, fail_resize;

static void *observed_malloc(size_t bytes) {
    if (fail_allocation) return NULL;
    void *pointer = malloc(bytes);
    assert(pointer && allocation_count < MAX_BACKING_OCCURRENCES);
    allocated[allocation_count++] = (uintptr_t)pointer;
    return pointer;
}

static void *observed_realloc(void *pointer, size_t bytes) {
    resize_count++;
    return fail_resize ? NULL : realloc(pointer, bytes);
}

static void observed_free(void *pointer) {
    assert(pointer && release_count < MAX_BACKING_OCCURRENCES);
    released[release_count++] = (uintptr_t)pointer;
    free(pointer);
}

char *observed_getenv(const char *name) {
    environment_queries++;
    return getenv(name);
}

#define malloc observed_malloc
#define realloc observed_realloc
#define free observed_free
#define getenv observed_getenv
#include "memory_runtime.c"
/* Mode0 aliases expand at each call, so observation aliases stay active. */

int main(int argc, char **argv) {
    blorp_memory_start();
    assert(argc == 2 && environment_queries == (size_t)BLORP_MEMORY_DIAGNOSTICS * ENVIRONMENT_VARIABLES_READ_AT_START);
    const char *name = argv[1];
    if (strcmp(name, "effects") == 0) {
        puts("effect");
    } else if (strcmp(name, "normal") == 0) {
        size_t evaluations = 0;
        void *pointer = blorp_memory_allocate(17 + evaluations++);
        assert(evaluations == 1 && (uintptr_t)pointer == allocated[0]);
        pointer = blorp_memory_resize(pointer, 32 + evaluations++);
        assert(pointer && evaluations == 2);
        blorp_memory_release(pointer);
        assert(allocation_count == 1 && release_count == 1 && resize_count == 1);
        assert(blorp_memory_finish((int)evaluations++) == 2);
        assert(evaluations == 3 && environment_queries == 0);
    } else if (strcmp(name, "finish_once") == 0) {
        int evaluations = 0;
        const int result = blorp_memory_finish(17 + evaluations++);
        assert(evaluations == 1);
        return result;
    } else if (strcmp(name, "partial_argv") == 0) {
        char invalid[] = {(char)0xff, '\0'};
        char *arguments[] = {"program", "valid", invalid};
        assert(blorp_list_from_argv(3, arguments) == NULL);
        assert(allocation_count == 3 && release_count == 3);
        assert(released[0] == allocated[1] && released[1] == allocated[2]);
        assert(released[2] == allocated[0]);
    } else if (strcmp(name, "null") == 0) {
        blorp_memory_release(NULL);
        assert(allocation_count == 0 && release_count == 0);
    } else if (strcmp(name, "null_resize") == 0) {
        void *pointer = blorp_memory_resize(NULL, 17);
        assert(pointer);
        blorp_memory_release(pointer);
    } else if (strcmp(name, "failed_allocate") == 0) {
        fail_allocation = 1;
        assert(blorp_memory_allocate(17) == NULL);
        assert(allocation_count == 0 && release_count == 0);
#if BLORP_MEMORY_DIAGNOSTICS
    } else if (strcmp(name, "arithmetic") == 0) {
        assert(blorp_memory_add(SIZE_MAX, 0) == SIZE_MAX);
        assert(blorp_memory_subtract(SIZE_MAX, SIZE_MAX) == 0);
    } else if (strcmp(name, "size_overflow") == 0) {
        (void)blorp_memory_allocate(SIZE_MAX);
    } else if (strcmp(name, "add_overflow") == 0) {
        blorp_memory_counts.allocations = SIZE_MAX;
        (void)blorp_memory_allocate(17);
    } else if (strcmp(name, "subtract_underflow") == 0) {
        void *pointer = blorp_memory_allocate(17);
        blorp_memory_counts.live = 0;
        blorp_memory_release(pointer);
    } else if (strcmp(name, "zero_resize") == 0) {
        (void)blorp_memory_resize(NULL, 0);
#endif
    } else {
        unsigned char *pointer = blorp_memory_allocate(17);
        assert(pointer && (uintptr_t)pointer % _Alignof(max_align_t) == 0);
        memset(pointer, 42, 17);
        if (strcmp(name, "resize") == 0) {
            pointer = blorp_memory_resize(pointer, 32);
            assert(pointer && allocation_count == 1 && resize_count == 1);
            for (size_t index = 0; index < 17; index++) assert(pointer[index] == 42);
            memset(pointer + 17, 7, 15);
#if BLORP_MEMORY_DIAGNOSTICS
            assert(blorp_memory_counts.bytes == 32);
#endif
        } else if (strcmp(name, "failed_resize") == 0) {
            fail_resize = 1;
            assert(blorp_memory_resize(pointer, 32) == NULL);
            assert(allocation_count == 1 && resize_count == 1 && release_count == 0);
            for (size_t index = 0; index < 17; index++) assert(pointer[index] == 42);
#if BLORP_MEMORY_DIAGNOSTICS
            assert(blorp_memory_counts.allocations == 1 && blorp_memory_counts.releases == 0);
            assert(blorp_memory_counts.live == 1 && blorp_memory_counts.bytes == 17);
#endif
        } else {
            assert(strcmp(name, "leak") == 0 || strcmp(name, "release") == 0
                   || strcmp(name, "alignment") == 0
                   || strcmp(name, "double_release") == 0);
        }
        if (strcmp(name, "leak") == 0) return blorp_memory_finish(0);
        blorp_memory_release(pointer);
        assert(release_count == 1);
        if (strcmp(name, "resize") != 0) assert(released[0] == allocated[0]);
        if (strcmp(name, "double_release") == 0) blorp_memory_release(pointer);
    }
    return blorp_memory_finish(0);
}
