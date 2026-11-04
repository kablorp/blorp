/* Native probe of the fs directory operations, built with the unmodified
 * production fragments and the List[String] layout a program that lists a
 * directory emits. Each case is one argument; a case that passes returns 0 and
 * prints nothing.
 *
 * The system calls in the included runtime text are renamed to recording
 * wrappers (D6). Each wrapper appends the call to one event log and either
 * passes it through or returns an injected failure, so a case can count calls
 * and descriptors, and provoke what no file system gives on demand: an
 * unknown d_type, an entry that vanishes, a name that is not UTF-8, a failed
 * readdir or fdopendir, EINTR, and a lost mkdir race. Nothing in the
 * production text changes. */
#define _POSIX_C_SOURCE 200809L
#define _XOPEN_SOURCE 700
#define _DEFAULT_SOURCE /* before any header, or glibc hides the DT_ codes */
#ifdef __APPLE__
#define _DARWIN_C_SOURCE
#endif
#include <assert.h>
#ifdef NDEBUG
#error the cases keep their work inside assert, so NDEBUG would skip it
#endif
/* Every header the runtime text includes comes first, so the renaming macros
 * below rewrite only the runtime's calls and never a header's declarations.
 * <dirent.h> is first of all, because the wrappers replace readdir. */
#include <dirent.h>
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

static int recording_open(const char *path, int flags, ...);
static int recording_close(int descriptor);
static DIR *recording_fdopendir(int descriptor);
static struct dirent *recording_readdir(DIR *directory);
static int recording_closedir(DIR *directory);
static int recording_fstatat(int directory, const char *name, struct stat *status, int flags);
static int recording_mkdir(const char *path, mode_t mode);
static int recording_stat(const char *path, struct stat *status);
static int recording_lstat(const char *path, struct stat *status);
static int recording_unlink(const char *path);
static int recording_rmdir(const char *path);
static int recording_rename(const char *source, const char *destination);
#define open recording_open
#define close recording_close
#define fdopendir recording_fdopendir
#define readdir recording_readdir
#define closedir recording_closedir
#define fstatat recording_fstatat
#define mkdir recording_mkdir
/* Function-like, so that `struct stat` is left alone. */
#define stat(path, status) recording_stat(path, status)
#define lstat recording_lstat
#define unlink recording_unlink
#define rmdir recording_rmdir
#define rename recording_rename
#include "fs_directory_runtime.c"
#undef open
#undef close
#undef fdopendir
#undef readdir
#undef closedir
#undef fstatat
#undef mkdir
#undef stat
#undef lstat
#undef unlink
#undef rmdir
#undef rename

/* The List[String] layout of the included runtime text. */
typedef struct blorp_l_0_s listing_t;

enum call {
    OPEN_CALL, CLOSE_CALL, FDOPENDIR_CALL, READDIR_CALL, CLOSEDIR_CALL, FSTATAT_CALL,
    MKDIR_CALL, STAT_CALL, LSTAT_CALL, UNLINK_CALL, RMDIR_CALL, RENAME_CALL,
    CALL_KINDS
};

enum { EVENT_CAPACITY = 1024, PATH_BYTES = 1024, ENTRY_NAME_BYTES = 256 };

/* One call as the runtime made it. `descriptor` is the descriptor a call
 * took or returned: open's result, close's argument, and the descriptor of
 * the stream that fdopendir made or closedir closed. `flags` are open's or
 * fstatat's flags. */
struct event {
    enum call call;
    int descriptor;
    int flags;
    long result;
    int error;
    char path[PATH_BYTES];
};

static struct event events[EVENT_CAPACITY];
static int event_count = 0;

/* Fails the calls of one kind: the first `skip` pass, and the next
 * `failures` fail with `error`. */
struct injection {
    int skip;
    int failures;
    int error;
};

static struct injection injections[CALL_KINDS];
/* readdir reports every entry's d_type as DT_UNKNOWN. */
static int unknown_types = 0;
/* readdir returns these regular-file entries, in this order, before the real
 * ones; the array ends with NULL. A case controls the order the sort sees, and
 * can give a name no file system here would create. */
static const char *const *crafted_names = NULL;
/* fstatat reports this name as gone. */
static const char *vanished_name = NULL;
/* mkdir makes the directory and then reports EEXIST, as when another
 * process makes it first. */
static int racing_mkdir = 0;
/* A readdir that returns an entry leaves errno at this value instead of the
 * one it found, which POSIX allows of a call that succeeds; only a NULL result
 * reports errno. 0 leaves errno alone. */
static int errno_after_entry = 0;
static struct dirent returned_entry;

static void copy_text(char *target, const char *text) {
    if (text == NULL) {
        target[0] = '\0';
        return;
    }
    const size_t length = strlen(text);
    assert(length < PATH_BYTES);
    memcpy(target, text, length + 1);
}

static void record(enum call call, int descriptor, int flags, const char *path, long result, int error) {
    assert(event_count < EVENT_CAPACITY);
    struct event *event = &events[event_count++];
    event->call = call;
    event->descriptor = descriptor;
    event->flags = flags;
    event->result = result;
    event->error = error;
    copy_text(event->path, path);
}

/* The errno to inject into this call, or 0 to pass it through. */
static int injected_error(enum call call) {
    struct injection *injection = &injections[call];
    if (injection->failures == 0) return 0;
    if (injection->skip > 0) {
        injection->skip--;
        return 0;
    }
    injection->failures--;
    return injection->error;
}

static void inject(enum call call, int skip, int failures, int error) {
    injections[call] = (struct injection){skip, failures, error};
}

/* A wrapper's errno: the injected one, the real call's on failure, or 0. */
static int outcome_error(int injected, int failed) {
    if (injected != 0) return injected;
    return failed ? errno : 0;
}

static int recording_open(const char *path, int flags, ...) {
    int mode = 0;
    if ((flags & O_CREAT) != 0) {
        va_list arguments;
        va_start(arguments, flags);
        mode = va_arg(arguments, int);
        va_end(arguments);
    }
    const int injected = injected_error(OPEN_CALL);
    const int result = injected != 0 ? -1 : open(path, flags, mode);
    const int error = outcome_error(injected, result < 0);
    record(OPEN_CALL, result, flags, path, result, error);
    if (result < 0) errno = error;
    return result;
}

static int recording_close(int descriptor) {
    const int result = close(descriptor);
    const int error = outcome_error(0, result < 0);
    record(CLOSE_CALL, descriptor, 0, NULL, result, error);
    if (result < 0) errno = error;
    return result;
}

/* An injected failure leaves the descriptor open, as fdopendir's does. */
static DIR *recording_fdopendir(int descriptor) {
    const int injected = injected_error(FDOPENDIR_CALL);
    DIR *result = injected != 0 ? NULL : fdopendir(descriptor);
    const int error = outcome_error(injected, result == NULL);
    record(FDOPENDIR_CALL, descriptor, 0, NULL, result == NULL ? -1 : 0, error);
    if (result == NULL) errno = error;
    return result;
}

/* The entry is copied field by field: a real entry may be shorter than
 * struct dirent, so copying the whole struct could read past it. */
static struct dirent *returned(const char *name, unsigned char type) {
    memset(&returned_entry, 0, sizeof returned_entry);
    const size_t length = strlen(name);
    assert(length < sizeof returned_entry.d_name);
    memcpy(returned_entry.d_name, name, length + 1);
    returned_entry.d_type = type;
    return &returned_entry;
}

/* An injected failure returns NULL with errno set and consumes no entry. */
static struct dirent *recording_readdir(DIR *directory) {
    const int injected = injected_error(READDIR_CALL);
    if (injected != 0) {
        record(READDIR_CALL, dirfd(directory), 0, NULL, -1, injected);
        errno = injected;
        return NULL;
    }
    const int before = errno;
    struct dirent *entry = NULL;
    int error = 0;
    if (crafted_names != NULL && *crafted_names != NULL) {
        entry = returned(*crafted_names, DT_REG);
        crafted_names++;
    } else {
        entry = readdir(directory);
        error = entry == NULL ? errno : 0;
        if (entry != NULL && unknown_types) entry = returned(entry->d_name, DT_UNKNOWN);
    }
    record(READDIR_CALL, dirfd(directory), 0, entry == NULL ? NULL : entry->d_name, entry == NULL ? -1 : 0, error);
    if (entry == NULL) {
        errno = error;
    } else {
        errno = errno_after_entry != 0 ? errno_after_entry : before;
    }
    return entry;
}

static int recording_closedir(DIR *directory) {
    const int descriptor = dirfd(directory);
    const int result = closedir(directory);
    const int error = outcome_error(0, result < 0);
    record(CLOSEDIR_CALL, descriptor, 0, NULL, result, error);
    if (result < 0) errno = error;
    return result;
}

static int recording_fstatat(int directory, const char *name, struct stat *status, int flags) {
    int injected = injected_error(FSTATAT_CALL);
    if (injected == 0 && vanished_name != NULL && strcmp(name, vanished_name) == 0) injected = ENOENT;
    const int result = injected != 0 ? -1 : fstatat(directory, name, status, flags);
    const int error = outcome_error(injected, result < 0);
    record(FSTATAT_CALL, directory, flags, name, result, error);
    if (result < 0) errno = error;
    return result;
}

static int recording_mkdir(const char *path, mode_t mode) {
    const int injected = injected_error(MKDIR_CALL);
    int result = injected != 0 ? -1 : mkdir(path, mode);
    int error = outcome_error(injected, result < 0);
    if (result == 0 && racing_mkdir) {
        result = -1;
        error = EEXIST;
    }
    record(MKDIR_CALL, -1, 0, path, result, error);
    if (result < 0) errno = error;
    return result;
}

static int recording_stat(const char *path, struct stat *status) {
    const int result = stat(path, status);
    const int error = outcome_error(0, result < 0);
    record(STAT_CALL, -1, 0, path, result, error);
    if (result < 0) errno = error;
    return result;
}

static int recording_lstat(const char *path, struct stat *status) {
    const int result = lstat(path, status);
    const int error = outcome_error(0, result < 0);
    record(LSTAT_CALL, -1, 0, path, result, error);
    if (result < 0) errno = error;
    return result;
}

static int recording_unlink(const char *path) {
    const int injected = injected_error(UNLINK_CALL);
    const int result = injected != 0 ? -1 : unlink(path);
    const int error = outcome_error(injected, result < 0);
    record(UNLINK_CALL, -1, 0, path, result, error);
    if (result < 0) errno = error;
    return result;
}

static int recording_rmdir(const char *path) {
    const int injected = injected_error(RMDIR_CALL);
    const int result = injected != 0 ? -1 : rmdir(path);
    const int error = outcome_error(injected, result < 0);
    record(RMDIR_CALL, -1, 0, path, result, error);
    if (result < 0) errno = error;
    return result;
}

static int recording_rename(const char *source, const char *destination) {
    const int injected = injected_error(RENAME_CALL);
    const int result = injected != 0 ? -1 : rename(source, destination);
    const int error = outcome_error(injected, result < 0);
    record(RENAME_CALL, -1, 0, source, result, error);
    if (result < 0) errno = error;
    return result;
}

/* Clears the log and every injection before the call a case observes. */
static void begin(void) {
    event_count = 0;
    memset(injections, 0, sizeof injections);
    unknown_types = 0;
    crafted_names = NULL;
    vanished_name = NULL;
    racing_mkdir = 0;
    errno_after_entry = 0;
}

static int count_events(enum call call) {
    int count = 0;
    for (int index = 0; index < event_count; index++) {
        if (events[index].call == call) count++;
    }
    return count;
}

/* The number the next open would return, outside the log. */
static int lowest_free_descriptor(void) {
    const int probe = open("/dev/null", O_RDONLY);
    assert(probe >= 0);
    assert(close(probe) == 0);
    return probe;
}

/* Every descriptor an open in the log returned is closed exactly once, by
 * close or by the closedir of its stream, before that number is returned
 * again, and nothing else is closed. */
static void expect_each_descriptor_closed_once(void) {
    int opens = 0;
    int closes = 0;
    for (int index = 0; index < event_count; index++) {
        const enum call call = events[index].call;
        if (call == CLOSE_CALL || call == CLOSEDIR_CALL) closes++;
        if (call != OPEN_CALL || events[index].result < 0) continue;
        opens++;
        const int descriptor = (int)events[index].result;
        int closed = 0;
        for (int later = index + 1; later < event_count; later++) {
            const enum call next = events[later].call;
            if (next == OPEN_CALL && events[later].result == descriptor) break;
            if ((next == CLOSE_CALL || next == CLOSEDIR_CALL) && events[later].descriptor == descriptor) closed++;
        }
        assert(closed == 1);
    }
    assert(closes == opens);
}

/* The checks every call ends with: each descriptor it opened closed once, and
 * none left open. */
static void expect_clean(int free_before) {
    expect_each_descriptor_closed_once();
    assert(lowest_free_descriptor() == free_before);
}

/* "<directory>/<name>" into a caller's PATH_BYTES buffer. */
static void join(char *joined, const char *directory, const char *name) {
    const int length = snprintf(joined, PATH_BYTES, "%s/%s", directory, name);
    assert(length > 0 && length < PATH_BYTES);
}

/* A fresh directory for one case under the suite's directory, which the other
 * fs probes share, so its name carries this probe's prefix. */
static void case_directory(char *path, const char *directory, const char *name) {
    const int length = snprintf(path, PATH_BYTES, "%s/directories-%s", directory, name);
    assert(length > 0 && length < PATH_BYTES);
    assert(mkdir(path, 0755) == 0);
}

static void make_file(const char *path) {
    FILE *stream = fopen(path, "wb");
    assert(stream != NULL);
    assert(fclose(stream) == 0);
}

static void make_file_in(const char *directory, const char *name) {
    char path[PATH_BYTES];
    join(path, directory, name);
    make_file(path);
}

static void make_directory_in(const char *directory, const char *name) {
    char path[PATH_BYTES];
    join(path, directory, name);
    assert(mkdir(path, 0755) == 0);
}

/* 1 for a directory, 0 for anything else or nothing. */
static int is_directory(const char *path) {
    struct stat status;
    return lstat(path, &status) == 0 && S_ISDIR(status.st_mode);
}

static int exists(const char *path) {
    struct stat status;
    return lstat(path, &status) == 0;
}

static struct blorp_string *bytes_of(const char *bytes, size_t length) {
    return blorp_string_from_bytes(bytes, (int64_t)length);
}

static struct blorp_string *string_of(const char *text) {
    return bytes_of(text, strlen(text));
}

/* A path with a NUL embedded after its first `length` bytes. */
static struct blorp_string *nul_path(const char *path) {
    char bytes[PATH_BYTES];
    const size_t length = strlen(path);
    assert(length + 7 < PATH_BYTES);
    memcpy(bytes, path, length);
    memcpy(bytes + length, "\0suffix", 7);
    return bytes_of(bytes, length + 7);
}

/* Each operation's code: 0 on success, the failure code otherwise. */
typedef uint8_t (*path_operation)(const struct blorp_string *, int64_t *);

static int64_t outcome(uint8_t succeeded, int64_t error) {
    assert(succeeded == BLORP_FS_SUCCEEDED ? error == 0 : error != 0);
    return error;
}

static int64_t on_string(path_operation operation, struct blorp_string *path) {
    int64_t error = 0;
    const uint8_t succeeded = operation(path, &error);
    blorp_string_release(path);
    return outcome(succeeded, error);
}

static int64_t on_path(path_operation operation, const char *path) {
    return on_string(operation, string_of(path));
}

static int64_t create_directory(const char *path) { return on_path(blorp_fs_create_directory, path); }
static int64_t create_directories(const char *path) { return on_path(blorp_fs_create_directories, path); }
static int64_t remove_file(const char *path) { return on_path(blorp_fs_remove_file, path); }
static int64_t remove_directory(const char *path) { return on_path(blorp_fs_remove_directory, path); }

static int64_t rename_strings(struct blorp_string *source, struct blorp_string *destination) {
    int64_t error = 0;
    const uint8_t succeeded = blorp_fs_rename(source, destination, &error);
    blorp_string_release(source);
    blorp_string_release(destination);
    return outcome(succeeded, error);
}

static int64_t rename_path(const char *source, const char *destination) {
    return rename_strings(string_of(source), string_of(destination));
}

/* Lists a path given as a String. On success `*entries` is the List, which
 * the caller drops; on failure it is untouched and NULL. */
static int64_t list_string(struct blorp_string *path, listing_t **entries) {
    int64_t error = 0;
    *entries = NULL;
    const uint8_t succeeded = blorp_fs_list_directory(path, entries, &error);
    blorp_string_release(path);
    assert(succeeded == BLORP_FS_SUCCEEDED ? *entries != NULL : *entries == NULL);
    return outcome(succeeded, error);
}

static int64_t list_failure(const char *path) {
    listing_t *entries = NULL;
    const int64_t error = list_string(string_of(path), &entries);
    assert(error != 0);
    return error;
}

/* An element is the entry's code byte, then its name. */
static void expect_entry(const listing_t *entries, int64_t index, int code, const char *name) {
    assert(index < entries->length);
    const struct blorp_string *entry = entries->values[index];
    assert(entry->length == (int64_t)strlen(name) + 1);
    assert((unsigned char)entry->bytes[0] == code);
    assert(memcmp(entry->bytes + 1, name, strlen(name)) == 0);
}

/* Lists `path`, which must succeed with exactly the expected elements. */
struct expected_entry {
    int code;
    const char *name;
};

static void expect_listing(const char *path, const struct expected_entry *expected, int64_t length) {
    listing_t *entries = NULL;
    assert(list_string(string_of(path), &entries) == 0);
    assert(entries->length == length);
    for (int64_t index = 0; index < length; index++) expect_entry(entries, index, expected[index].code, expected[index].name);
    blorp_list_drop_0_s(entries);
}

/* One descriptor, one stream, one closedir, and no bare close. */
static void expect_one_stream(void) {
    assert(count_events(OPEN_CALL) == 1);
    assert(count_events(FDOPENDIR_CALL) == 1);
    assert(count_events(CLOSEDIR_CALL) == 1);
    assert(count_events(CLOSE_CALL) == 0);
}

static int case_list_empty(const char *root) {
    char directory[PATH_BYTES];
    case_directory(directory, root, "list_empty");
    const int free_before = lowest_free_descriptor();
    begin();
    expect_listing(directory, NULL, 0);
    expect_one_stream();
    expect_clean(free_before);
    return 0;
}

/* readdir's NULL means the end only while errno is still 0, and a readdir
 * that returns an entry may leave errno set, so the listing clears it before
 * each call. */
static int case_list_errno_left_set(const char *root) {
    char directory[PATH_BYTES];
    case_directory(directory, root, "list_errno_left_set");
    make_file_in(directory, "file");
    const struct expected_entry expected[] = {{1, "file"}};
    const int free_before = lowest_free_descriptor();
    begin();
    errno_after_entry = EIO;
    expect_listing(directory, expected, 1);
    expect_one_stream();
    expect_clean(free_before);
    return 0;
}

/* More entries than the initial capacity of the collected names, each in
 * order: zero-padded names sort by their numbers. */
enum { MANY_ENTRIES = 3 * BLORP_FS_LIST_INITIAL_CAPACITY + 1 };

static int case_list_many(const char *root) {
    char directory[PATH_BYTES];
    case_directory(directory, root, "list_many");
    for (int index = MANY_ENTRIES - 1; index >= 0; index--) {
        char name[32];
        (void)snprintf(name, sizeof name, "entry-%03d", index);
        make_file_in(directory, name);
    }
    const int free_before = lowest_free_descriptor();
    begin();
    listing_t *entries = NULL;
    assert(list_string(string_of(directory), &entries) == 0);
    assert(entries->length == MANY_ENTRIES);
    for (int index = 0; index < MANY_ENTRIES; index++) {
        char name[32];
        (void)snprintf(name, sizeof name, "entry-%03d", index);
        expect_entry(entries, index, 1, name);
    }
    blorp_list_drop_0_s(entries);
    expect_one_stream();
    expect_clean(free_before);
    return 0;
}

/* Bytes, not letters: an upper-case letter sorts before '_' and lower case,
 * a prefix before what extends it, and a multi-byte character last. */
static int case_list_order(const char *root) {
    char directory[PATH_BYTES];
    case_directory(directory, root, "list_order");
    static const char *const created[] = {"\xc3\xa9", "ab", "a", "_", "B"};
    for (size_t index = 0; index < sizeof created / sizeof created[0]; index++) make_file_in(directory, created[index]);
    const struct expected_entry expected[] = {{1, "B"}, {1, "_"}, {1, "a"}, {1, "ab"}, {1, "\xc3\xa9"}};
    const int free_before = lowest_free_descriptor();
    begin();
    expect_listing(directory, expected, 5);
    expect_clean(free_before);

    /* The file system's own order is not controlled above, so the same names,
     * longer prefixes first, also come from readdir in a fixed order. A sort that
     * found equal prefixes equal would keep them in that order. */
    static const char *const scripted[] = {"\xc3\xa9", "abc", "ab", "a", "_", "B", NULL};
    const struct expected_entry sorted[] = {{1, "B"}, {1, "_"}, {1, "a"}, {1, "ab"}, {1, "abc"}, {1, "\xc3\xa9"}};
    char empty[PATH_BYTES];
    join(empty, directory, "empty");
    assert(mkdir(empty, 0755) == 0);
    begin();
    crafted_names = scripted;
    expect_listing(empty, sorted, 6);
    expect_clean(free_before);
    return 0;
}

/* A link is listed as a link and never followed, whatever it points at; a
 * FIFO is Other. */
static int case_list_kinds(const char *root) {
    char directory[PATH_BYTES], path[PATH_BYTES];
    case_directory(directory, root, "list_kinds");
    make_file_in(directory, "file");
    make_directory_in(directory, "folder");
    join(path, directory, "link_to_file");
    assert(symlink("file", path) == 0);
    join(path, directory, "link_to_folder");
    assert(symlink("folder", path) == 0);
    join(path, directory, "dangling");
    assert(symlink("nowhere", path) == 0);
    join(path, directory, "pipe");
    assert(mkfifo(path, 0644) == 0);
    const struct expected_entry expected[] = {
        {3, "dangling"}, {1, "file"}, {2, "folder"}, {3, "link_to_file"}, {3, "link_to_folder"}, {4, "pipe"},
    };
    const int free_before = lowest_free_descriptor();
    begin();
    expect_listing(directory, expected, 6);
    expect_clean(free_before);
    return 0;
}

/* A link to a directory, and a path ending in '/', list the directory. */
static int case_list_paths(const char *root) {
    char directory[PATH_BYTES], target[PATH_BYTES], link[PATH_BYTES], slashed[PATH_BYTES];
    case_directory(directory, root, "list_paths");
    join(target, directory, "target");
    assert(mkdir(target, 0755) == 0);
    make_file_in(target, "inside");
    join(link, directory, "link");
    assert(symlink("target", link) == 0);
    const struct expected_entry expected[] = {{1, "inside"}};
    const int free_before = lowest_free_descriptor();
    begin();
    expect_listing(link, expected, 1);
    expect_clean(free_before);
    join(slashed, target, "");
    begin();
    expect_listing(slashed, expected, 1);
    expect_clean(free_before);
    return 0;
}

/* Each failure that the path itself causes. A NUL makes no system call. */
static int case_list_failures(const char *root) {
    char directory[PATH_BYTES], file[PATH_BYTES], slashed[PATH_BYTES], loop[PATH_BYTES], missing[PATH_BYTES];
    case_directory(directory, root, "list_failures");
    join(file, directory, "file");
    make_file(file);
    join(slashed, file, "");
    join(loop, directory, "loop");
    assert(symlink("loop", loop) == 0);
    join(missing, directory, "missing");
    const int free_before = lowest_free_descriptor();
    static const struct { int which; int64_t code; } expected[] = {
        {0, 1}, {1, 4}, {2, 4}, {3, -(int64_t)ELOOP}, {4, 1},
    };
    const char *const paths[] = {missing, file, slashed, loop, ""};
    for (size_t index = 0; index < sizeof expected / sizeof expected[0]; index++) {
        begin();
        assert(list_failure(paths[expected[index].which]) == expected[index].code);
        assert(count_events(FDOPENDIR_CALL) == 0);
        expect_clean(free_before);
    }
    begin();
    listing_t *entries = NULL;
    assert(list_string(nul_path(directory), &entries) == 12);
    assert(event_count == 0);
    return 0;
}

/* With every d_type unknown, each entry is examined with fstatat on the
 * open directory, without following a link. */
static int case_list_unknown_types(const char *root) {
    char directory[PATH_BYTES], path[PATH_BYTES];
    case_directory(directory, root, "list_unknown_types");
    make_file_in(directory, "file");
    make_directory_in(directory, "folder");
    join(path, directory, "link");
    assert(symlink("folder", path) == 0);
    const struct expected_entry expected[] = {{1, "file"}, {2, "folder"}, {3, "link"}};
    const int free_before = lowest_free_descriptor();
    begin();
    unknown_types = 1;
    expect_listing(directory, expected, 3);
    assert(count_events(FSTATAT_CALL) == 3);
    int stream = -1;
    for (int index = 0; index < event_count; index++) {
        if (events[index].call == OPEN_CALL) stream = (int)events[index].result;
    }
    for (int index = 0; index < event_count; index++) {
        if (events[index].call != FSTATAT_CALL) continue;
        assert(events[index].flags == AT_SYMLINK_NOFOLLOW);
        assert(events[index].descriptor == stream);
    }
    expect_clean(free_before);
    return 0;
}

/* An entry that is gone by the time fstatat examines it is left out; any
 * other fstatat failure fails the listing and frees what was collected. */
static int case_list_vanished(const char *root) {
    char directory[PATH_BYTES];
    case_directory(directory, root, "list_vanished");
    make_file_in(directory, "first");
    make_file_in(directory, "gone");
    make_file_in(directory, "last");
    const struct expected_entry expected[] = {{1, "first"}, {1, "last"}};
    const int free_before = lowest_free_descriptor();
    begin();
    unknown_types = 1;
    vanished_name = "gone";
    expect_listing(directory, expected, 2);
    expect_clean(free_before);

    begin();
    unknown_types = 1;
    inject(FSTATAT_CALL, 1, 1, EACCES);
    assert(list_failure(directory) == 2);
    expect_one_stream();
    expect_clean(free_before);
    return 0;
}

/* A readdir that fails part way fails the whole listing with its errno, after
 * names were collected, which the strict leak check shows were freed. */
static int case_list_read_failure(const char *root) {
    char directory[PATH_BYTES];
    case_directory(directory, root, "list_read_failure");
    for (int index = 0; index < 4; index++) {
        char name[16];
        (void)snprintf(name, sizeof name, "file-%d", index);
        make_file_in(directory, name);
    }
    const int free_before = lowest_free_descriptor();
    begin();
    inject(READDIR_CALL, 4, 1, EIO);
    assert(list_failure(directory) == -(int64_t)EIO);
    assert(count_events(READDIR_CALL) == 5);
    expect_one_stream();
    expect_clean(free_before);
    return 0;
}

/* One name that is not UTF-8 fails the whole listing (D8), even with valid
 * names already collected. */
static int case_list_invalid_utf8(const char *root) {
    char directory[PATH_BYTES];
    case_directory(directory, root, "list_invalid_utf8");
    make_file_in(directory, "valid");
    const int free_before = lowest_free_descriptor();
    static const char *const names[] = {"collected", "bad-\xff\xfe", NULL};
    begin();
    crafted_names = names;
    assert(list_failure(directory) == 13);
    expect_one_stream();
    expect_clean(free_before);
    return 0;
}

/* fdopendir that fails leaves the descriptor open, so the listing closes it
 * itself, once, and never calls closedir. */
static int case_list_fdopendir_failure(const char *root) {
    char directory[PATH_BYTES];
    case_directory(directory, root, "list_fdopendir_failure");
    const int free_before = lowest_free_descriptor();
    begin();
    inject(FDOPENDIR_CALL, 0, 1, ENOMEM);
    assert(list_failure(directory) == -(int64_t)ENOMEM);
    assert(count_events(OPEN_CALL) == 1);
    assert(count_events(CLOSE_CALL) == 1);
    assert(count_events(CLOSEDIR_CALL) == 0);
    expect_clean(free_before);
    return 0;
}

/* EINTR from each call is retried once, and the call then succeeds. */
static int case_interrupted(const char *root) {
    char directory[PATH_BYTES], path[PATH_BYTES], other[PATH_BYTES];
    case_directory(directory, root, "interrupted");
    make_file_in(directory, "file");
    const struct expected_entry expected[] = {{1, "file"}};
    const int free_before = lowest_free_descriptor();

    begin();
    inject(OPEN_CALL, 0, 1, EINTR);
    expect_listing(directory, expected, 1);
    assert(count_events(OPEN_CALL) == 2);
    expect_clean(free_before);

    begin();
    inject(READDIR_CALL, 0, 1, EINTR);
    expect_listing(directory, expected, 1);
    int first_read = 0;
    while (events[first_read].call != READDIR_CALL) first_read++;
    assert(events[first_read].error == EINTR && events[first_read + 1].call == READDIR_CALL);
    expect_clean(free_before);

    begin();
    unknown_types = 1;
    inject(FSTATAT_CALL, 0, 1, EINTR);
    expect_listing(directory, expected, 1);
    assert(count_events(FSTATAT_CALL) == 2);
    expect_clean(free_before);

    join(path, directory, "made");
    begin();
    inject(MKDIR_CALL, 0, 1, EINTR);
    assert(create_directory(path) == 0);
    assert(count_events(MKDIR_CALL) == 2);
    assert(is_directory(path));

    join(other, directory, "renamed");
    begin();
    inject(RENAME_CALL, 0, 1, EINTR);
    assert(rename_path(path, other) == 0);
    assert(count_events(RENAME_CALL) == 2);
    assert(is_directory(other));

    begin();
    inject(RMDIR_CALL, 0, 1, EINTR);
    assert(remove_directory(other) == 0);
    assert(count_events(RMDIR_CALL) == 2);
    assert(!exists(other));

    join(path, directory, "file");
    begin();
    inject(UNLINK_CALL, 0, 1, EINTR);
    assert(remove_file(path) == 0);
    assert(count_events(UNLINK_CALL) == 2);
    assert(!exists(path));
    return 0;
}

/* One mkdir: an existing path is AlreadyExists whatever it names. */
static int case_create_kinds(const char *root) {
    char directory[PATH_BYTES], made[PATH_BYTES], file[PATH_BYTES], child[PATH_BYTES], missing[PATH_BYTES];
    char slashed[PATH_BYTES];
    case_directory(directory, root, "create_kinds");
    join(made, directory, "made");
    join(file, directory, "file");
    make_file(file);
    join(child, file, "child");
    join(missing, directory, "missing/child");
    join(slashed, directory, "slashed/");
    begin();
    assert(create_directory(made) == 0);
    assert(count_events(MKDIR_CALL) == 1);
    assert(is_directory(made));
    const mode_t mask = umask(0);
    (void)umask(mask);
    struct stat status;
    assert(lstat(made, &status) == 0);
    assert((status.st_mode & 07777) == (0777 & ~mask));
    assert(create_directory(made) == 3);
    assert(create_directory(file) == 3);
    assert(create_directory(child) == 4);
    assert(create_directory(missing) == 1);
    assert(create_directory("") == 1);
    assert(create_directory(slashed) == 0);
    join(slashed, directory, "slashed");
    assert(is_directory(slashed));
    begin();
    inject(MKDIR_CALL, 0, 1, EROFS);
    assert(create_directory(made) == 8);
    begin();
    inject(MKDIR_CALL, 0, 1, ENOSPC);
    assert(create_directory(made) == 9);
    begin();
    assert(on_string(blorp_fs_create_directory, nul_path(made)) == 12);
    assert(event_count == 0);
    return 0;
}

/* How many components `path` has, counted from its text: the walk makes one
 * mkdir for each. */
static int existing_components(const char *path) {
    int components = 0;
    for (size_t index = 0; path[index] != '\0'; index++) {
        if (path[index] != '/' && (index == 0 || path[index - 1] == '/')) components++;
    }
    assert(components > 0);
    return components;
}

/* The walk makes each missing component from the left, and passes those
 * that exist as directories, or as links to them. */
static int case_create_all(const char *root) {
    char directory[PATH_BYTES], path[PATH_BYTES], link[PATH_BYTES];
    case_directory(directory, root, "create_all");

    begin();
    assert(create_directories("") == 1);
    assert(event_count == 0);
    begin();
    assert(create_directories("/") == 0);
    assert(create_directories("//") == 0);
    assert(event_count == 0);

    const int existing = existing_components(directory);
    join(path, directory, "a/b/c");
    begin();
    assert(create_directories(path) == 0);
    assert(is_directory(path));
    assert(count_events(MKDIR_CALL) == existing + 3);
    assert(count_events(STAT_CALL) == existing);
    begin();
    assert(create_directories(path) == 0);
    assert(count_events(MKDIR_CALL) == existing + 3);
    assert(count_events(STAT_CALL) == existing + 3);

    /* Repeated and trailing slashes separate no further components. */
    join(path, directory, "slashes//inner///");
    begin();
    assert(create_directories(path) == 0);
    assert(count_events(MKDIR_CALL) == existing + 2);
    join(path, directory, "slashes//inner");
    assert(strcmp(events[event_count - 1].path, path) == 0);
    assert(is_directory(path));

    join(link, directory, "link");
    assert(symlink("a", link) == 0);
    join(path, directory, "link/through");
    begin();
    assert(create_directories(path) == 0);
    join(path, directory, "a/through");
    assert(is_directory(path));
    assert(!is_directory(link));
    begin();
    assert(on_string(blorp_fs_create_directories, nul_path(path)) == 12);
    assert(event_count == 0);
    return 0;
}

/* A component that exists and is not a directory: NotADirectory with more
 * components after it, AlreadyExists as the last, dangling links included.
 * The walk stops at the failure. */
static int case_create_all_conflicts(const char *root) {
    char directory[PATH_BYTES], file[PATH_BYTES], dangling[PATH_BYTES], path[PATH_BYTES];
    case_directory(directory, root, "create_all_conflicts");
    join(file, directory, "file");
    make_file(file);
    join(dangling, directory, "dangling");
    assert(symlink("nowhere", dangling) == 0);

    join(path, directory, "file/child/grandchild");
    begin();
    assert(create_directories(path) == 4);
    assert(events[event_count - 1].call == STAT_CALL);
    assert(strcmp(events[event_count - 1].path, file) == 0);
    begin();
    assert(create_directories(file) == 3);
    begin();
    assert(create_directories(dangling) == 3);
    join(path, directory, "dangling/child");
    begin();
    assert(create_directories(path) == 4);
    join(path, directory, "nowhere");
    assert(!exists(path));

    /* Any other mkdir failure stops the walk with its own code. */
    const int existing = existing_components(directory);
    join(path, directory, "stopped/here/never");
    begin();
    inject(MKDIR_CALL, existing, 1, EROFS);
    assert(create_directories(path) == 8);
    assert(count_events(MKDIR_CALL) == existing + 1);
    join(path, directory, "stopped");
    assert(!exists(path));
    return 0;
}

/* Another process making a component first is no failure. */
static int case_create_all_race(const char *root) {
    char directory[PATH_BYTES], path[PATH_BYTES];
    case_directory(directory, root, "create_all_race");
    join(path, directory, "raced/inner");
    begin();
    racing_mkdir = 1;
    assert(create_directories(path) == 0);
    assert(is_directory(path));
    assert(count_events(STAT_CALL) == count_events(MKDIR_CALL));
    return 0;
}

static int case_remove_file_kinds(const char *root) {
    char directory[PATH_BYTES], file[PATH_BYTES], link[PATH_BYTES], target[PATH_BYTES], folder[PATH_BYTES];
    char child[PATH_BYTES];
    case_directory(directory, root, "remove_file_kinds");
    join(file, directory, "file");
    make_file(file);
    join(target, directory, "target");
    make_file(target);
    join(link, directory, "link");
    assert(symlink("target", link) == 0);
    join(folder, directory, "folder");
    assert(mkdir(folder, 0755) == 0);
    join(child, target, "child");

    begin();
    assert(remove_file(file) == 0);
    assert(!exists(file));
    assert(count_events(LSTAT_CALL) == 0);
    begin();
    assert(remove_file(link) == 0);
    assert(!exists(link));
    assert(exists(target));
    assert(remove_file(file) == 1);
    assert(remove_file("") == 1);
    assert(remove_file(child) == 4);

    /* macOS refuses a directory with EPERM, and the lstat makes it IsADirectory. */
    begin();
    inject(UNLINK_CALL, 0, 1, EPERM);
    assert(remove_file(folder) == 5);
    assert(count_events(LSTAT_CALL) == 1);
    assert(is_directory(folder));
    begin();
    inject(UNLINK_CALL, 0, 1, EPERM);
    assert(remove_file(target) == 2);
    assert(count_events(LSTAT_CALL) == 1);
    assert(exists(target));
    /* Linux's EISDIR is IsADirectory through the shared map. */
    begin();
    inject(UNLINK_CALL, 0, 1, EISDIR);
    assert(remove_file(folder) == 5);
    begin();
    inject(UNLINK_CALL, 0, 1, EROFS);
    assert(remove_file(target) == 8);
    assert(count_events(LSTAT_CALL) == 0);
    begin();
    assert(on_string(blorp_fs_remove_file, nul_path(target)) == 12);
    assert(event_count == 0);
    return 0;
}

static int case_remove_directory_kinds(const char *root) {
    char directory[PATH_BYTES], empty[PATH_BYTES], full[PATH_BYTES], file[PATH_BYTES], link[PATH_BYTES];
    char slashed[PATH_BYTES], missing[PATH_BYTES];
    case_directory(directory, root, "remove_directory_kinds");
    join(empty, directory, "empty");
    assert(mkdir(empty, 0755) == 0);
    join(full, directory, "full");
    assert(mkdir(full, 0755) == 0);
    make_file_in(full, "inside");
    join(file, directory, "file");
    make_file(file);
    join(link, directory, "link");
    assert(symlink("full", link) == 0);
    join(slashed, directory, "slashed");
    assert(mkdir(slashed, 0755) == 0);
    join(slashed, directory, "slashed/");
    join(missing, directory, "missing");

    assert(remove_directory(empty) == 0);
    assert(!exists(empty));
    assert(remove_directory(slashed) == 0);
    assert(remove_directory(full) == 6);
    assert(remove_directory(file) == 4);
    assert(remove_directory(link) == 4);
    assert(remove_directory(missing) == 1);
    assert(remove_directory("") == 1);
    assert(remove_directory(".") == -(int64_t)EINVAL);
    /* POSIX also lets rmdir report a directory that is not empty as EEXIST. */
    begin();
    inject(RMDIR_CALL, 0, 1, EEXIST);
    assert(remove_directory(full) == 6);
    begin();
    inject(RMDIR_CALL, 0, 1, EROFS);
    assert(remove_directory(full) == 8);
    begin();
    assert(on_string(blorp_fs_remove_directory, nul_path(full)) == 12);
    assert(event_count == 0);
    assert(is_directory(full) && exists(file));
    return 0;
}

static void expect_contents(const char *path, const char *expected) {
    FILE *stream = fopen(path, "rb");
    assert(stream != NULL);
    char buffer[64];
    const size_t length = fread(buffer, 1, sizeof buffer, stream);
    assert(fclose(stream) == 0);
    assert(length == strlen(expected) && memcmp(buffer, expected, length) == 0);
}

static void write_file(const char *path, const char *text) {
    FILE *stream = fopen(path, "wb");
    assert(stream != NULL);
    assert(fwrite(text, 1, strlen(text), stream) == strlen(text));
    assert(fclose(stream) == 0);
}

static int case_rename_kinds(const char *root) {
    char directory[PATH_BYTES], first[PATH_BYTES], second[PATH_BYTES], folder[PATH_BYTES], empty[PATH_BYTES];
    char full[PATH_BYTES], inside[PATH_BYTES], missing[PATH_BYTES];
    case_directory(directory, root, "rename_kinds");
    join(first, directory, "first");
    write_file(first, "first");
    join(second, directory, "second");
    write_file(second, "second");
    join(folder, directory, "folder");
    assert(mkdir(folder, 0755) == 0);
    make_file_in(folder, "kept");
    join(empty, directory, "empty");
    assert(mkdir(empty, 0755) == 0);
    join(full, directory, "full");
    assert(mkdir(full, 0755) == 0);
    make_file_in(full, "inside");
    join(inside, folder, "into_itself");
    join(missing, directory, "missing");

    assert(rename_path(first, second) == 0);
    assert(!exists(first));
    expect_contents(second, "first");
    assert(rename_path(folder, empty) == 0);
    assert(!exists(folder));
    join(folder, empty, "kept");
    assert(exists(folder));
    assert(rename_path(empty, full) == 6);
    assert(rename_path(second, full) == 5);
    assert(rename_path(full, second) == 4);
    join(inside, full, "into_itself");
    assert(rename_path(full, inside) == -(int64_t)EINVAL);
    assert(rename_path(missing, first) == 1);
    begin();
    inject(RENAME_CALL, 0, 1, EEXIST);
    assert(rename_path(empty, full) == 6);
    begin();
    inject(RENAME_CALL, 0, 1, EXDEV);
    assert(rename_path(second, first) == 11);
    begin();
    assert(rename_strings(nul_path(second), string_of(first)) == 12);
    assert(rename_strings(string_of(second), nul_path(first)) == 12);
    assert(event_count == 0);
    expect_contents(second, "first");
    assert(is_directory(empty) && is_directory(full));
    return 0;
}

/* Each operation refused by permissions, and a real directory given to
 * remove_file. Root may do all of these, and on macOS the super-user's rules
 * for unlink differ, so the suite leaves this case out as root. */
static int case_permission_kinds(const char *root) {
    assert(geteuid() != 0);
    char directory[PATH_BYTES], unreadable[PATH_BYTES], locked[PATH_BYTES], path[PATH_BYTES], other[PATH_BYTES];
    case_directory(directory, root, "permission_kinds");
    join(unreadable, directory, "unreadable");
    assert(mkdir(unreadable, 0755) == 0);
    assert(chmod(unreadable, 0) == 0);
    join(locked, directory, "locked");
    assert(mkdir(locked, 0755) == 0);
    make_file_in(locked, "file");
    make_directory_in(locked, "folder");
    assert(chmod(locked, 0555) == 0);
    const int free_before = lowest_free_descriptor();

    begin();
    assert(list_failure(unreadable) == 2);
    assert(count_events(FDOPENDIR_CALL) == 0);
    expect_clean(free_before);
    join(path, locked, "new");
    assert(create_directory(path) == 2);
    join(path, locked, "new/inner");
    assert(create_directories(path) == 2);
    join(path, locked, "file");
    assert(remove_file(path) == 2);
    join(path, locked, "folder");
    assert(remove_directory(path) == 2);
    join(other, locked, "renamed");
    assert(rename_path(path, other) == 2);
    /* Linux checks the parent's write permission first, so this directory is in
     * a writable one: macOS then refuses it with EPERM and Linux with EISDIR. */
    join(path, directory, "folder");
    assert(mkdir(path, 0755) == 0);
    begin();
    assert(remove_file(path) == 5);
    assert(is_directory(path));

    assert(chmod(unreadable, 0755) == 0);
    assert(chmod(locked, 0755) == 0);
    return 0;
}

static int child_case(int argc, char **argv) {
    if (argc != 3) return 2;
    const char *name = argv[1];
    const char *directory = argv[2];
    /* One allocation outside the cases, so that the strict accounting always
     * has something to balance. */
    blorp_string_release(string_of(name));
    /* The runtime text's only close follows a failed fdopendir. Naming the
     * wrapper here keeps the probe building, under -Werror, when an oracle
     * removes that close, so the break shows as a failing case. */
    (void)recording_close;
    if (strcmp(name, "list_empty") == 0) return case_list_empty(directory);
    if (strcmp(name, "list_errno_left_set") == 0) return case_list_errno_left_set(directory);
    if (strcmp(name, "list_many") == 0) return case_list_many(directory);
    if (strcmp(name, "list_order") == 0) return case_list_order(directory);
    if (strcmp(name, "list_kinds") == 0) return case_list_kinds(directory);
    if (strcmp(name, "list_paths") == 0) return case_list_paths(directory);
    if (strcmp(name, "list_failures") == 0) return case_list_failures(directory);
    if (strcmp(name, "list_unknown_types") == 0) return case_list_unknown_types(directory);
    if (strcmp(name, "list_vanished") == 0) return case_list_vanished(directory);
    if (strcmp(name, "list_read_failure") == 0) return case_list_read_failure(directory);
    if (strcmp(name, "list_invalid_utf8") == 0) return case_list_invalid_utf8(directory);
    if (strcmp(name, "list_fdopendir_failure") == 0) return case_list_fdopendir_failure(directory);
    if (strcmp(name, "interrupted") == 0) return case_interrupted(directory);
    if (strcmp(name, "create_kinds") == 0) return case_create_kinds(directory);
    if (strcmp(name, "create_all") == 0) return case_create_all(directory);
    if (strcmp(name, "create_all_conflicts") == 0) return case_create_all_conflicts(directory);
    if (strcmp(name, "create_all_race") == 0) return case_create_all_race(directory);
    if (strcmp(name, "remove_file_kinds") == 0) return case_remove_file_kinds(directory);
    if (strcmp(name, "remove_directory_kinds") == 0) return case_remove_directory_kinds(directory);
    if (strcmp(name, "rename_kinds") == 0) return case_rename_kinds(directory);
    if (strcmp(name, "permission_kinds") == 0) return case_permission_kinds(directory);
    return 2;
}

int main(int argc, char **argv) {
    blorp_memory_start();
    return blorp_memory_finish(child_case(argc, argv));
}
