/* Native probe of system.current_directory, built with the unmodified
 * production fragments. Each case is one argument; a case that passes returns 0
 * and prints nothing.
 *
 * getcwd in the included runtime text is renamed to a scripted wrapper (D6),
 * so a case can provoke what the real directory never gives on demand: each
 * errno, a path the OS cannot name, bytes that are not UTF-8, and a path longer
 * than any String. The wrapper answers ERANGE until the buffer is large enough
 * for the scripted path, as the real call does. Nothing in the production text
 * changes. */
#define _POSIX_C_SOURCE 200809L
#define _XOPEN_SOURCE 700
#define _DEFAULT_SOURCE
#ifdef __APPLE__
#define _DARWIN_C_SOURCE
#endif
#include <assert.h>
#ifdef NDEBUG
#error the cases keep their work inside assert, so NDEBUG would skip it
#endif
/* Every header the runtime text includes comes first, so the renaming macro
 * below rewrites only the runtime's call and never a header's declaration. */
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
/* The memory runtime's optional headers, under its own conditions. */
#if defined(__APPLE__) && defined(__has_include)
#if __has_include(<execinfo.h>) && __has_include(<mach-o/dyld.h>)
#include <execinfo.h>
#include <mach-o/dyld.h>
#endif
#elif defined(__linux__) && defined(__has_include)
#if __has_include(<execinfo.h>) && __has_include(<link.h>) && __has_include(<sys/auxv.h>)
#include <execinfo.h>
#include <link.h>
#include <sys/auxv.h>
#endif
#endif

/* What the wrapper does: fail with `failure` when it is not 0, and otherwise
 * answer ERANGE until the buffer holds `path`, then copy it. */
static int failure;
static const char *path;
static int calls;

static char *scripted_getcwd(char *buffer, size_t capacity) {
    calls++;
    if (failure != 0) {
        errno = failure;
        return NULL;
    }
    const size_t length = strlen(path);
    if (capacity <= length) {
        errno = ERANGE;
        return NULL;
    }
    memcpy(buffer, path, length + 1);
    return buffer;
}

#define getcwd scripted_getcwd
#include "fs_current_directory_runtime.c"
#undef getcwd

/* A call that must fail with `code`: the error out-parameter holds it and no String
 * is published. */
static int expect_code(int64_t code) {
    struct blorp_string *directory = NULL;
    int64_t error = 0;
    assert(blorp_system_current_directory(&directory, &error) == BLORP_FS_FAILED);
    assert(directory == NULL);
    return error == code ? 0 : 1;
}

static int case_failure(int number, int64_t code) {
    failure = number;
    return expect_code(code);
}

static int case_success(const char *scripted, size_t expected_calls) {
    path = scripted;
    struct blorp_string *directory = NULL;
    int64_t error = 0;
    assert(blorp_system_current_directory(&directory, &error) == BLORP_FS_SUCCEEDED);
    assert(directory != NULL && error == 0);
    const int same = directory->length == (int64_t)strlen(scripted)
        && memcmp(directory->bytes, scripted, strlen(scripted) + 1) == 0;
    blorp_string_release(directory);
    return same && (size_t)calls == expected_calls ? 0 : 1;
}

static int case_unreachable(const char *scripted) {
    path = scripted;
    return expect_code(15);
}

/* The path is longer than the limit, so the buffer grows to it and the next ERANGE
 * is the capacity case, which is OtherOs(EOVERFLOW). */
static int case_capacity_limit(void) {
    enum { LIMIT = 1024 };
    char long_path[LIMIT + 1];
    memset(long_path, 'a', LIMIT);
    long_path[0] = '/';
    long_path[LIMIT] = '\0';
    path = long_path;
    struct blorp_string *directory = NULL;
    int64_t error = 0;
    assert(blorp_system_current_directory_within(&directory, &error, LIMIT) == BLORP_FS_FAILED);
    assert(directory == NULL);
    return error == -(int64_t)EOVERFLOW ? 0 : 1;
}

int main(int argc, char **argv) {
    blorp_memory_start();
    assert(argc >= 2);
    const char *name = argv[1];
    /* One allocation outside the cases, so that the strict accounting always
     * has something to balance. */
    blorp_string_release(blorp_string_from_bytes(name, (int64_t)strlen(name)));
    int status = 2;
    if (strcmp(name, "not_found") == 0) status = case_failure(ENOENT, 1);
    if (strcmp(name, "permission_denied") == 0) status = case_failure(EACCES, 2);
    /* EIO and EINTR are 5 and 4 on every supported platform. */
    if (strcmp(name, "other_errno") == 0) status = case_failure(EIO, -5);
    /* NoSpace is a named kind that CurrentDirectoryError lacks, so its number arrives. */
    if (strcmp(name, "other_errno") == 0) status += case_failure(ENOSPC, -(int64_t)ENOSPC);
    if (strcmp(name, "interrupted_is_not_retried") == 0) {
        /* Not retrying is deliberate: it matches the old fragment, and POSIX lists no
         * EINTR for getcwd. */
        status = case_failure(EINTR, -4) + (calls == 1 ? 0 : 1);
    }
    if (strcmp(name, "short_path") == 0) status = case_success("/short", 1);
    if (strcmp(name, "grows_past_initial") == 0) {
        char long_path[600];
        memset(long_path, 'a', sizeof long_path - 1);
        long_path[0] = '/';
        long_path[sizeof long_path - 1] = '\0';
        status = case_success(long_path, 3);
    }
    if (strcmp(name, "relative") == 0) status = case_unreachable("relative/path");
    if (strcmp(name, "empty") == 0) status = case_unreachable("");
    if (strcmp(name, "invalid_utf8") == 0) {
        path = "/\xc0\x80";
        status = expect_code(13);
    }
    if (strcmp(name, "capacity_limit") == 0) status = case_capacity_limit();
    return blorp_memory_finish(status);
}
