/* Native fs.write_text probe, built with the unmodified production fragments.
 * Each case is one argument; a case that passes returns 0 and prints nothing.
 *
 * The system calls in the included runtime text are renamed to recording
 * wrappers (D6). Each wrapper appends the call to one event log and either
 * passes it through or returns an injected failure, so a case can read the
 * order of the calls and provoke failures no file system gives on demand.
 * Nothing in the production text changes. */
#define _POSIX_C_SOURCE 200809L
#define _XOPEN_SOURCE 700
#ifdef __APPLE__
#define _DARWIN_C_SOURCE /* before any header, or F_BARRIERFSYNC stays hidden */
#endif
#include <assert.h>
#ifdef NDEBUG
#error the cases keep their work inside assert, so NDEBUG would skip it
#endif
/* Every header the runtime text includes comes first, so the renaming macros
 * below rewrite only the runtime's calls and never a header's declarations. */
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
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
static ssize_t recording_write(int descriptor, const void *bytes, size_t count);
static int recording_fsync(int descriptor);
static int recording_rename(const char *source, const char *destination);
static int recording_unlink(const char *path);
static int recording_fchown(int descriptor, uid_t owner, gid_t group);
static int recording_fchmod(int descriptor, mode_t mode);
static int recording_lstat(const char *path, struct stat *status);
static int recording_stat(const char *path, struct stat *status);
static int recording_fstat(int descriptor, struct stat *status);
static char *recording_realpath(const char *path, char *resolved);
#define open recording_open
#define close recording_close
#define write recording_write
#define fsync recording_fsync
#define rename recording_rename
#define unlink recording_unlink
#define fchown recording_fchown
#define fchmod recording_fchmod
#define lstat recording_lstat
/* Function-like, so struct stat keeps its name. */
#define stat(path, status) recording_stat(path, status)
#define fstat recording_fstat
#define realpath recording_realpath
/* Only macOS issues the barrier, so only there is fcntl called at all. */
#ifdef __APPLE__
static int recording_fcntl(int descriptor, int command, ...);
#define fcntl recording_fcntl
#endif
#include "fs_write_runtime.c"
#undef open
#undef close
#undef write
#undef fsync
#undef rename
#undef unlink
#undef fchown
#undef fchmod
#undef lstat
#undef stat
#undef fstat
#undef realpath
#ifdef __APPLE__
#undef fcntl
#endif

enum call {
    OPEN_CALL, CLOSE_CALL, WRITE_CALL, FSYNC_CALL, FCNTL_CALL, RENAME_CALL,
    UNLINK_CALL, FCHOWN_CALL, FCHMOD_CALL, LSTAT_CALL, STAT_CALL, FSTAT_CALL,
    REALPATH_CALL, CALL_KINDS
};

/* The call that orders the new file's contents before the rename (D5). */
#ifdef __APPLE__
#define FLUSH_CALL FCNTL_CALL
#else
#define FLUSH_CALL FSYNC_CALL
#endif

enum { EVENT_CAPACITY = 512, PATH_BYTES = 1024, DESCRIPTOR_LIMIT = 1024 };

/* One call as the runtime made it. `flags` are open's flags, or the flags the
 * descriptor was opened with, so a case can tell the new file's descriptor
 * (O_EXCL) from the directory's (O_DIRECTORY). `owner` and `group` are
 * fchown's arguments and 0 for every other call. */
struct event {
    enum call call;
    int descriptor;
    int flags;
    long result;
    int error;
    uid_t owner;
    gid_t group;
    char path[PATH_BYTES];
    char destination[PATH_BYTES];
};

static struct event events[EVENT_CAPACITY];
static int event_count = 0;
static int opened_flags[DESCRIPTOR_LIMIT];

/* Fails the calls of one kind whose flags include `required_flags`: the first
 * `skip` such calls pass, and the next `failures` fail with `error`. */
struct injection {
    int required_flags;
    int skip;
    int failures;
    int error;
};

enum { EVERY_CALL = INT_MAX };
static struct injection injections[CALL_KINDS];
/* How many writes still pass only half of their request through. */
static int short_writes = 0;

static void copy_text(char *target, const char *text) {
    if (text == NULL) {
        target[0] = '\0';
        return;
    }
    const size_t length = strlen(text);
    assert(length < PATH_BYTES);
    memcpy(target, text, length + 1);
}

static void record(enum call call, int descriptor, int flags, const char *path, const char *destination,
                   long result, int error) {
    assert(event_count < EVENT_CAPACITY);
    struct event *event = &events[event_count++];
    event->call = call;
    event->descriptor = descriptor;
    event->flags = flags;
    event->result = result;
    event->error = error;
    copy_text(event->path, path);
    copy_text(event->destination, destination);
    event->owner = 0;
    event->group = 0;
}

static int flags_of(int descriptor) {
    return descriptor >= 0 && descriptor < DESCRIPTOR_LIMIT ? opened_flags[descriptor] : 0;
}

/* The errno to inject into this call, or 0 to pass it through. */
static int injected_error(enum call call, int flags) {
    struct injection *injection = &injections[call];
    if (injection->failures == 0 || (flags & injection->required_flags) != injection->required_flags) return 0;
    if (injection->skip > 0) {
        injection->skip--;
        return 0;
    }
    if (injection->failures != EVERY_CALL) injection->failures--;
    return injection->error;
}

static void inject(enum call call, int required_flags, int skip, int failures, int error) {
    injections[call] = (struct injection){required_flags, skip, failures, error};
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
    const int injected = injected_error(OPEN_CALL, flags);
    const int result = injected != 0 ? -1 : open(path, flags, mode);
    const int error = outcome_error(injected, result < 0);
    if (result >= 0) {
        assert(result < DESCRIPTOR_LIMIT);
        opened_flags[result] = flags;
    }
    record(OPEN_CALL, result, flags, path, NULL, result, error);
    if (result < 0) errno = error;
    return result;
}

/* An injected failure still releases the descriptor, as Linux's close does. */
static int recording_close(int descriptor) {
    const int flags = flags_of(descriptor);
    const int injected = injected_error(CLOSE_CALL, flags);
    int result = close(descriptor);
    const int error = outcome_error(injected, result < 0);
    if (injected != 0) result = -1;
    record(CLOSE_CALL, descriptor, flags, NULL, NULL, result, error);
    if (result < 0) errno = error;
    return result;
}

static ssize_t recording_write(int descriptor, const void *bytes, size_t count) {
    const int flags = flags_of(descriptor);
    const int injected = injected_error(WRITE_CALL, flags);
    size_t request = count;
    if (injected == 0 && short_writes > 0 && count > 1) {
        short_writes--;
        request = count / 2;
    }
    const ssize_t result = injected != 0 ? -1 : write(descriptor, bytes, request);
    const int error = outcome_error(injected, result < 0);
    record(WRITE_CALL, descriptor, flags, NULL, NULL, (long)result, error);
    if (result < 0) errno = error;
    return result;
}

static int recording_fsync(int descriptor) {
    const int flags = flags_of(descriptor);
    const int injected = injected_error(FSYNC_CALL, flags);
    const int result = injected != 0 ? -1 : fsync(descriptor);
    const int error = outcome_error(injected, result < 0);
    record(FSYNC_CALL, descriptor, flags, NULL, NULL, result, error);
    if (result < 0) errno = error;
    return result;
}

#ifdef __APPLE__
/* The runtime issues only the barrier, which takes no argument. */
static int recording_fcntl(int descriptor, int command, ...) {
    assert(command == F_BARRIERFSYNC);
    const int flags = flags_of(descriptor);
    const int injected = injected_error(FCNTL_CALL, flags);
    const int result = injected != 0 ? -1 : fcntl(descriptor, F_BARRIERFSYNC);
    const int error = outcome_error(injected, result < 0);
    record(FCNTL_CALL, descriptor, flags, NULL, NULL, result, error);
    if (result < 0) errno = error;
    return result;
}
#endif

static int recording_rename(const char *source, const char *destination) {
    const int injected = injected_error(RENAME_CALL, 0);
    const int result = injected != 0 ? -1 : rename(source, destination);
    const int error = outcome_error(injected, result < 0);
    record(RENAME_CALL, -1, 0, source, destination, result, error);
    if (result < 0) errno = error;
    return result;
}

static int recording_unlink(const char *path) {
    const int injected = injected_error(UNLINK_CALL, 0);
    const int result = injected != 0 ? -1 : unlink(path);
    const int error = outcome_error(injected, result < 0);
    record(UNLINK_CALL, -1, 0, path, NULL, result, error);
    if (result < 0) errno = error;
    return result;
}

static int recording_fchown(int descriptor, uid_t owner, gid_t group) {
    const int flags = flags_of(descriptor);
    const int injected = injected_error(FCHOWN_CALL, flags);
    const int result = injected != 0 ? -1 : fchown(descriptor, owner, group);
    const int error = outcome_error(injected, result < 0);
    record(FCHOWN_CALL, descriptor, flags, NULL, NULL, result, error);
    events[event_count - 1].owner = owner;
    events[event_count - 1].group = group;
    if (result < 0) errno = error;
    return result;
}

static int recording_fchmod(int descriptor, mode_t mode) {
    const int flags = flags_of(descriptor);
    const int injected = injected_error(FCHMOD_CALL, flags);
    const int result = injected != 0 ? -1 : fchmod(descriptor, mode);
    const int error = outcome_error(injected, result < 0);
    record(FCHMOD_CALL, descriptor, flags, NULL, NULL, result, error);
    if (result < 0) errno = error;
    return result;
}

static int recording_lstat(const char *path, struct stat *status) {
    const int injected = injected_error(LSTAT_CALL, 0);
    const int result = injected != 0 ? -1 : lstat(path, status);
    const int error = outcome_error(injected, result < 0);
    record(LSTAT_CALL, -1, 0, path, NULL, result, error);
    if (result < 0) errno = error;
    return result;
}

/* A mode a successful stat reports instead of the real one, or 0 for the real
 * one: it stands in for a platform that resolves a slashed path to a file
 * without ENOTDIR, as macOS 15 does for a slashed link to a file. */
static mode_t stat_reported_mode;

static int recording_stat(const char *path, struct stat *status) {
    const int injected = injected_error(STAT_CALL, 0);
    const int result = injected != 0 ? -1 : stat(path, status);
    const int error = outcome_error(injected, result < 0);
    if (result == 0 && stat_reported_mode != 0) status->st_mode = stat_reported_mode;
    record(STAT_CALL, -1, 0, path, NULL, result, error);
    if (result < 0) errno = error;
    return result;
}

static int recording_fstat(int descriptor, struct stat *status) {
    const int flags = flags_of(descriptor);
    const int injected = injected_error(FSTAT_CALL, flags);
    const int result = injected != 0 ? -1 : fstat(descriptor, status);
    const int error = outcome_error(injected, result < 0);
    record(FSTAT_CALL, descriptor, flags, NULL, NULL, result, error);
    if (result < 0) errno = error;
    return result;
}

static char *recording_realpath(const char *path, char *resolved) {
    const int injected = injected_error(REALPATH_CALL, 0);
    char *answer = injected != 0 ? NULL : realpath(path, resolved);
    const int error = outcome_error(injected, answer == NULL);
    record(REALPATH_CALL, -1, 0, path, answer, answer != NULL ? 0 : -1, error);
    if (answer == NULL) errno = error;
    return answer;
}

/* Clears the log and every injection before the call a case observes. */
static void begin(void) {
    event_count = 0;
    memset(injections, 0, sizeof injections);
    short_writes = 0;
    stat_reported_mode = 0;
}

static int count_events(enum call call, int required_flags) {
    int count = 0;
    for (int index = 0; index < event_count; index++) {
        if (events[index].call == call && (events[index].flags & required_flags) == required_flags) count++;
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

/* Every descriptor an open in the log returned is closed exactly once before
 * that number is returned again, and nothing else is closed. A count alone
 * would miss a double close of a number that was reused. */
static void expect_each_descriptor_closed_once(void) {
    int opens = 0;
    int closes = 0;
    for (int index = 0; index < event_count; index++) {
        if (events[index].call == CLOSE_CALL) closes++;
        if (events[index].call != OPEN_CALL || events[index].result < 0) continue;
        opens++;
        const int descriptor = (int)events[index].result;
        int closed = 0;
        for (int later = index + 1; later < event_count; later++) {
            if (events[later].call == OPEN_CALL && events[later].result == descriptor) break;
            if (events[later].call == CLOSE_CALL && events[later].descriptor == descriptor) closed++;
        }
        assert(closed == 1);
    }
    assert(closes == opens);
}

static struct blorp_string *string_of(const char *text) {
    return blorp_string_from_bytes(text, (int64_t)strlen(text));
}

/* Writes `text` to a path given as raw bytes, so a NUL can be embedded in it.
 * Returns 0 on success and the failure code otherwise. */
static int64_t write_bytes_path(const char *bytes, size_t length, const char *text) {
    struct blorp_string *path = blorp_string_from_bytes(bytes, (int64_t)length);
    struct blorp_string *contents = string_of(text);
    int64_t error = 0;
    const uint8_t succeeded = blorp_fs_write_text(path, contents, &error);
    blorp_string_release(path);
    blorp_string_release(contents);
    assert(succeeded == BLORP_FS_SUCCEEDED ? error == 0 : error != 0);
    return error;
}

static int64_t write_text_to(const char *path, const char *text) {
    return write_bytes_path(path, strlen(path), text);
}

/* "<directory>/<name>" into a caller's PATH_BYTES buffer. */
static void join(char *joined, const char *directory, const char *name) {
    const int length = snprintf(joined, PATH_BYTES, "%s/%s", directory, name);
    assert(length > 0 && length < PATH_BYTES);
}

/* A fresh directory for one case under the suite's directory, by its real
 * path, so paths in the log can be compared with it. */
static void case_directory(char *path, const char *directory, const char *name) {
    char *real = realpath(directory, NULL);
    assert(real != NULL);
    join(path, real, name);
    free(real);
    assert(mkdir(path, 0755) == 0);
}

static void make_file(const char *path, const char *text, mode_t mode) {
    FILE *stream = fopen(path, "wb");
    assert(stream != NULL);
    assert(fwrite(text, 1, strlen(text), stream) == strlen(text));
    assert(fclose(stream) == 0);
    assert(chmod(path, mode) == 0);
}

static void expect_contents(const char *path, const char *expected) {
    FILE *stream = fopen(path, "rb");
    assert(stream != NULL);
    char buffer[4096];
    const size_t length = fread(buffer, 1, sizeof buffer, stream);
    assert(feof(stream));
    assert(fclose(stream) == 0);
    assert(length == strlen(expected));
    assert(memcmp(buffer, expected, length) == 0);
}

static mode_t mode_of(const char *path) {
    struct stat status;
    assert(lstat(path, &status) == 0);
    return status.st_mode & 07777;
}

static int count_temporaries(const char *directory) {
    DIR *listing = opendir(directory);
    assert(listing != NULL);
    int count = 0;
    const struct dirent *entry;
    while ((entry = readdir(listing)) != NULL) {
        if (strncmp(entry->d_name, ".blorp-tmp-", strlen(".blorp-tmp-")) == 0) count++;
    }
    assert(closedir(listing) == 0);
    return count;
}

static int count_entries(const char *directory) {
    DIR *listing = opendir(directory);
    assert(listing != NULL);
    int count = 0;
    const struct dirent *entry;
    while ((entry = readdir(listing)) != NULL) {
        if (strcmp(entry->d_name, ".") != 0 && strcmp(entry->d_name, "..") != 0) count++;
    }
    assert(closedir(listing) == 0);
    return count;
}

/* The checks every write ends with: each descriptor closed once, none left
 * open, and no temporary file left in the target's directory. */
static void expect_clean(int free_before, const char *directory) {
    expect_each_descriptor_closed_once();
    assert(lowest_free_descriptor() == free_before);
    assert(count_temporaries(directory) == 0);
}

/* A failure up to and including the rename: the code, the temporary file
 * removed, and the target as it was. Only a case that fails the rename itself
 * reaches it. */
static void expect_unchanged(int64_t error, int64_t expected, int renames, const char *target, const char *contents) {
    assert(error == expected);
    assert(count_events(RENAME_CALL, 0) == renames);
    assert(count_events(UNLINK_CALL, 0) == 1);
    expect_contents(target, contents);
}

struct step {
    enum call call;
    int required_flags;
};

/* From the new file's exclusive open on, the calls that change, publish or
 * flush it, in order; opens, stats and realpath are left out. */
static void expect_steps(const struct step *expected, int length) {
    int first = -1;
    for (int index = 0; index < event_count && first < 0; index++) {
        if (events[index].call == OPEN_CALL && (events[index].flags & O_EXCL) != 0 && events[index].result >= 0) first = index;
    }
    assert(first >= 0);
    int position = 0;
    for (int index = first + 1; index < event_count; index++) {
        const enum call call = events[index].call;
        if (call == OPEN_CALL || call == LSTAT_CALL || call == STAT_CALL || call == FSTAT_CALL
            || call == REALPATH_CALL) continue;
        assert(position < length);
        assert(call == expected[position].call);
        assert((events[index].flags & expected[position].required_flags) == expected[position].required_flags);
        position++;
    }
    assert(position == length);
}

/* The path the new file was created at. */
static const char *temporary_path(void) {
    for (int index = 0; index < event_count; index++) {
        if (events[index].call == OPEN_CALL && (events[index].flags & O_EXCL) != 0 && events[index].result >= 0) {
            return events[index].path;
        }
    }
    assert(0 && "no temporary file was created");
    return NULL;
}

static int starts_with(const char *text, const char *prefix) {
    return strncmp(text, prefix, strlen(prefix)) == 0;
}

/* Replacing a file: owner, then mode, then the bytes, the flush, one close,
 * the rename and the directory's flush. The mode survives. */
static int case_order_replace(const char *root) {
    char directory[PATH_BYTES], target[PATH_BYTES], prefix[PATH_BYTES];
    case_directory(directory, root, "order_replace");
    join(target, directory, "target.txt");
    make_file(target, "old", 0640);
    const int free_before = lowest_free_descriptor();
    begin();
    assert(write_text_to(target, "new contents") == 0);
    static const struct step steps[] = {
        {FCHOWN_CALL, O_EXCL}, {FCHMOD_CALL, O_EXCL}, {WRITE_CALL, O_EXCL}, {FLUSH_CALL, O_EXCL},
        {CLOSE_CALL, O_EXCL}, {RENAME_CALL, 0}, {FSYNC_CALL, O_DIRECTORY}, {CLOSE_CALL, O_DIRECTORY},
    };
    expect_steps(steps, (int)(sizeof steps / sizeof steps[0]));
    join(prefix, directory, ".blorp-tmp-");
    assert(starts_with(temporary_path(), prefix));
    expect_contents(target, "new contents");
    assert(mode_of(target) == 0640);
    expect_clean(free_before, directory);
    return 0;
}

/* A new file has no owner or mode to copy; the umask narrows 0666. */
static int case_order_new(const char *root) {
    char directory[PATH_BYTES], target[PATH_BYTES], private_target[PATH_BYTES];
    case_directory(directory, root, "order_new");
    join(target, directory, "fresh.txt");
    const mode_t previous = umask(022);
    const int free_before = lowest_free_descriptor();
    begin();
    assert(write_text_to(target, "fresh") == 0);
    static const struct step steps[] = {
        {WRITE_CALL, O_EXCL}, {FLUSH_CALL, O_EXCL}, {CLOSE_CALL, O_EXCL},
        {RENAME_CALL, 0}, {FSYNC_CALL, O_DIRECTORY}, {CLOSE_CALL, O_DIRECTORY},
    };
    expect_steps(steps, (int)(sizeof steps / sizeof steps[0]));
    expect_contents(target, "fresh");
    assert(mode_of(target) == 0644);
    expect_clean(free_before, directory);

    join(private_target, directory, "private.txt");
    (void)umask(077);
    begin();
    assert(write_text_to(private_target, "private") == 0);
    (void)umask(previous);
    assert(mode_of(private_target) == 0600);
    expect_clean(free_before, directory);
    return 0;
}

/* Empty text replaces a file with an empty one, and writes no bytes. */
static int case_empty_text(const char *root) {
    char directory[PATH_BYTES], target[PATH_BYTES];
    case_directory(directory, root, "empty_text");
    join(target, directory, "target.txt");
    make_file(target, "old", 0644);
    const int free_before = lowest_free_descriptor();
    begin();
    assert(write_text_to(target, "") == 0);
    assert(count_events(WRITE_CALL, 0) == 0);
    expect_contents(target, "");
    expect_clean(free_before, directory);
    return 0;
}

/* A write that takes half of its request is continued until every byte is in. */
static int case_short_write(const char *root) {
    char directory[PATH_BYTES], target[PATH_BYTES];
    case_directory(directory, root, "short_write");
    join(target, directory, "target.txt");
    char text[1001];
    for (int index = 0; index < 1000; index++) text[index] = (char)('a' + index % 26);
    text[1000] = '\0';
    const int free_before = lowest_free_descriptor();
    begin();
    short_writes = 1;
    assert(write_text_to(target, text) == 0);
    assert(count_events(WRITE_CALL, O_EXCL) == 2);
    expect_contents(target, text);
    expect_clean(free_before, directory);
    return 0;
}

/* EINTR from the write, the flush and the rename is each retried once. */
static int case_interrupted(const char *root) {
    char directory[PATH_BYTES], target[PATH_BYTES];
    case_directory(directory, root, "interrupted");
    join(target, directory, "target.txt");
    make_file(target, "old", 0644);
    const int free_before = lowest_free_descriptor();
    begin();
    inject(WRITE_CALL, O_EXCL, 0, 1, EINTR);
    inject(FLUSH_CALL, O_EXCL, 0, 1, EINTR);
    inject(RENAME_CALL, 0, 0, 1, EINTR);
    assert(write_text_to(target, "after the signal") == 0);
    assert(count_events(WRITE_CALL, O_EXCL) == 2);
    assert(count_events(FLUSH_CALL, O_EXCL) == 2);
    assert(count_events(RENAME_CALL, 0) == 2);
    expect_contents(target, "after the signal");
    expect_clean(free_before, directory);
    return 0;
}

/* A failed flush is final: called once, never followed by another flush, and
 * the target keeps its old contents. */
static int case_flush_failure(const char *root) {
    char directory[PATH_BYTES], target[PATH_BYTES];
    case_directory(directory, root, "flush_failure");
    join(target, directory, "target.txt");
    make_file(target, "old", 0644);
    const int free_before = lowest_free_descriptor();
    begin();
    inject(FLUSH_CALL, O_EXCL, 0, 1, EIO);
    const int64_t error = write_text_to(target, "never published");
    expect_unchanged(error, -(int64_t)EIO, 0, target, "old");
    assert(count_events(FLUSH_CALL, O_EXCL) == 1);
    assert(count_events(FSYNC_CALL, O_EXCL) + count_events(FCNTL_CALL, O_EXCL) == 1);
    expect_clean(free_before, directory);
    return 0;
}

/* On macOS a file system without the barrier gets exactly one fsync instead.
 * Elsewhere the flush is always one fsync. */
static int case_barrier_unsupported(const char *root) {
    char directory[PATH_BYTES], target[PATH_BYTES];
    case_directory(directory, root, "barrier_unsupported");
    join(target, directory, "target.txt");
    const int free_before = lowest_free_descriptor();
    begin();
#ifdef __APPLE__
    inject(FCNTL_CALL, O_EXCL, 0, 1, ENOTSUP);
#endif
    assert(write_text_to(target, "flushed") == 0);
    assert(count_events(FSYNC_CALL, O_EXCL) == 1);
#ifdef __APPLE__
    assert(count_events(FCNTL_CALL, O_EXCL) == 1);
#endif
    static const struct step steps[] = {
        {WRITE_CALL, O_EXCL},
#ifdef __APPLE__
        {FCNTL_CALL, O_EXCL},
#endif
        {FSYNC_CALL, O_EXCL}, {CLOSE_CALL, O_EXCL},
        {RENAME_CALL, 0}, {FSYNC_CALL, O_DIRECTORY}, {CLOSE_CALL, O_DIRECTORY},
    };
    expect_steps(steps, (int)(sizeof steps / sizeof steps[0]));
    expect_contents(target, "flushed");
    expect_clean(free_before, directory);
    return 0;
}

/* A failed close is a failed write, and the descriptor is not closed again. */
static int case_close_failure(const char *root) {
    char directory[PATH_BYTES], target[PATH_BYTES];
    case_directory(directory, root, "close_failure");
    join(target, directory, "target.txt");
    make_file(target, "old", 0644);
    const int free_before = lowest_free_descriptor();
    begin();
    inject(CLOSE_CALL, O_EXCL, 0, 1, EIO);
    const int64_t error = write_text_to(target, "never published");
    expect_unchanged(error, -(int64_t)EIO, 0, target, "old");
    expect_clean(free_before, directory);
    return 0;
}

static int case_rename_failure(const char *root) {
    char directory[PATH_BYTES], target[PATH_BYTES];
    case_directory(directory, root, "rename_failure");
    join(target, directory, "target.txt");
    make_file(target, "old", 0644);
    const int free_before = lowest_free_descriptor();
    begin();
    /* WriteError lacks CrossesDevices, so EXDEV arrives as the OS's own number. */
    inject(RENAME_CALL, 0, 0, 1, EXDEV);
    const int64_t error = write_text_to(target, "never published");
    expect_unchanged(error, -(int64_t)EXDEV, 1, target, "old");
    expect_clean(free_before, directory);
    return 0;
}

/* After the rename the target holds the new contents whatever the directory's
 * flush returns: EINVAL and ENOTSUP are success, and EIO is reported. */
static int case_directory_flush(const char *root) {
    char directory[PATH_BYTES], target[PATH_BYTES];
    case_directory(directory, root, "directory_flush");
    join(target, directory, "target.txt");
    const int free_before = lowest_free_descriptor();
    static const int unsupported[] = {EINVAL, ENOTSUP};
    for (size_t index = 0; index < sizeof unsupported / sizeof unsupported[0]; index++) {
        begin();
        inject(FSYNC_CALL, O_DIRECTORY, 0, 1, unsupported[index]);
        assert(write_text_to(target, "unsupported") == 0);
        assert(count_events(FSYNC_CALL, O_DIRECTORY) == 1);
        expect_contents(target, "unsupported");
        expect_clean(free_before, directory);
    }
    begin();
    inject(FSYNC_CALL, O_DIRECTORY, 0, 1, EIO);
    assert(write_text_to(target, "published") == -(int64_t)EIO);
    assert(count_events(FSYNC_CALL, O_DIRECTORY) == 1);
    assert(count_events(UNLINK_CALL, 0) == 0);
    expect_contents(target, "published");
    expect_clean(free_before, directory);
    return 0;
}

/* When every name is taken, the write gives up after the named bound with
 * OtherOs(EEXIST), never AlreadyExists, having tried a new name each time. */
static int case_temporary_names_exhausted(const char *root) {
    char directory[PATH_BYTES], target[PATH_BYTES];
    case_directory(directory, root, "temporary_names_exhausted");
    join(target, directory, "target.txt");
    make_file(target, "old", 0644);
    const int free_before = lowest_free_descriptor();
    begin();
    inject(OPEN_CALL, O_EXCL, 0, EVERY_CALL, EEXIST);
    assert(write_text_to(target, "never published") == -(int64_t)EEXIST);
    assert(count_events(OPEN_CALL, O_EXCL) == BLORP_FS_TEMPORARY_ATTEMPTS);
    for (int index = 0; index < event_count; index++) {
        if (events[index].call != OPEN_CALL || (events[index].flags & O_EXCL) == 0) continue;
        for (int later = index + 1; later < event_count; later++) {
            if (events[later].call == OPEN_CALL && (events[later].flags & O_EXCL) != 0) {
                assert(strcmp(events[index].path, events[later].path) != 0);
            }
        }
    }
    assert(count_events(RENAME_CALL, 0) == 0);
    expect_contents(target, "old");
    expect_clean(free_before, directory);
    return 0;
}

/* EPERM from fchown means another user owns the file: the group alone is then
 * copied, and EPERM from that is ignored too. Any other failure is the write's
 * failure. */
static int case_owner(const char *root) {
    char directory[PATH_BYTES], target[PATH_BYTES];
    case_directory(directory, root, "owner");
    join(target, directory, "target.txt");
    make_file(target, "old", 0660);
    struct stat original;
    assert(stat(target, &original) == 0);
    const int free_before = lowest_free_descriptor();
    begin();
    inject(FCHOWN_CALL, O_EXCL, 0, 1, EPERM);
    assert(write_text_to(target, "group kept") == 0);
    static const struct step group_only[] = {
        {FCHOWN_CALL, O_EXCL}, {FCHOWN_CALL, O_EXCL}, {FCHMOD_CALL, O_EXCL}, {WRITE_CALL, O_EXCL}, {FLUSH_CALL, O_EXCL},
        {CLOSE_CALL, O_EXCL}, {RENAME_CALL, 0}, {FSYNC_CALL, O_DIRECTORY}, {CLOSE_CALL, O_DIRECTORY},
    };
    expect_steps(group_only, (int)(sizeof group_only / sizeof group_only[0]));
    int chowns = 0;
    for (int index = 0; index < event_count; index++) {
        if (events[index].call != FCHOWN_CALL) continue;
        const uid_t owner = chowns == 0 ? original.st_uid : (uid_t)-1;
        assert(events[index].owner == owner && events[index].group == original.st_gid);
        chowns++;
    }
    expect_contents(target, "group kept");
    assert(mode_of(target) == 0660);
    expect_clean(free_before, directory);

    begin();
    inject(FCHOWN_CALL, O_EXCL, 0, 2, EPERM);
    assert(write_text_to(target, "owner and group refused") == 0);
    assert(count_events(FCHOWN_CALL, O_EXCL) == 2);
    assert(count_events(FCHMOD_CALL, O_EXCL) == 1);
    expect_contents(target, "owner and group refused");
    assert(mode_of(target) == 0660);
    expect_clean(free_before, directory);

    begin();
    inject(FCHOWN_CALL, O_EXCL, 0, 1, EACCES);
    const int64_t error = write_text_to(target, "never published");
    expect_unchanged(error, 2, 0, target, "owner and group refused");
    assert(count_events(FCHOWN_CALL, 0) == 1);
    assert(count_events(FCHMOD_CALL, 0) == 0);
    expect_clean(free_before, directory);
    return 0;
}

/* A probe that opens the file but cannot fstat it closes that descriptor once
 * and creates nothing. */
static int case_probe_failure(const char *root) {
    char directory[PATH_BYTES], target[PATH_BYTES];
    case_directory(directory, root, "probe_failure");
    join(target, directory, "target.txt");
    make_file(target, "old", 0644);
    const int free_before = lowest_free_descriptor();
    begin();
    inject(FSTAT_CALL, 0, 0, 1, EIO);
    assert(write_text_to(target, "never published") == -(int64_t)EIO);
    assert(count_events(OPEN_CALL, 0) == 1);
    assert(count_events(OPEN_CALL, O_EXCL) == 0);
    assert(count_events(FSTAT_CALL, 0) == 1);
    expect_contents(target, "old");
    assert(count_entries(directory) == 1);
    expect_clean(free_before, directory);
    return 0;
}

/* A real EFBIG: the file-size limit with SIGXFSZ ignored. The limit is
 * restored before any check, so the sanitizer's reports can still be written. */
static int case_file_too_large(const char *root) {
    enum { LIMIT_BYTES = 8192, TEXT_BYTES = 3 * LIMIT_BYTES };
    char directory[PATH_BYTES], target[PATH_BYTES];
    case_directory(directory, root, "file_too_large");
    join(target, directory, "target.txt");
    make_file(target, "small", 0644);
    char *text = malloc(TEXT_BYTES + 1);
    assert(text != NULL);
    memset(text, 'x', TEXT_BYTES);
    text[TEXT_BYTES] = '\0';
    struct rlimit saved;
    assert(getrlimit(RLIMIT_FSIZE, &saved) == 0);
    struct rlimit limited = saved;
    limited.rlim_cur = LIMIT_BYTES;
    struct sigaction ignore;
    struct sigaction previous;
    memset(&ignore, 0, sizeof ignore);
    ignore.sa_handler = SIG_IGN;
    sigemptyset(&ignore.sa_mask);
    assert(sigaction(SIGXFSZ, &ignore, &previous) == 0);
    const int free_before = lowest_free_descriptor();
    begin();
    assert(setrlimit(RLIMIT_FSIZE, &limited) == 0);
    const int64_t error = write_text_to(target, text);
    assert(setrlimit(RLIMIT_FSIZE, &saved) == 0);
    assert(sigaction(SIGXFSZ, &previous, NULL) == 0);
    free(text);
    expect_unchanged(error, 10, 0, target, "small");
    expect_clean(free_before, directory);
    return 0;
}

/* Failures found from the path alone, before any system call: the empty path
 * and an embedded NUL. */
static int case_path_kinds(const char *root) {
    char directory[PATH_BYTES];
    case_directory(directory, root, "path_kinds");
    const int free_before = lowest_free_descriptor();

    begin();
    assert(write_text_to("", "text") == 1);
    assert(event_count == 0);

    char bytes[PATH_BYTES];
    char target[PATH_BYTES];
    join(target, directory, "nul_target");
    const size_t prefix = strlen(target);
    memcpy(bytes, target, prefix);
    memcpy(bytes + prefix, "\0suffix", 7);
    begin();
    assert(write_bytes_path(bytes, prefix + 7, "text") == 12);
    assert(event_count == 0);
    assert(count_entries(directory) == 0);
    expect_clean(free_before, directory);
    return 0;
}

/* A path ending in a slash names a directory, which is never written. One stat
 * with the slash kept says what is there, its mode decides the kind, and nothing
 * is opened or created. */
static int case_slashed_paths(const char *root) {
    char directory[PATH_BYTES], folder[PATH_BYTES], file[PATH_BYTES], link[PATH_BYTES];
    case_directory(directory, root, "slashed_paths");
    join(folder, directory, "folder");
    assert(mkdir(folder, 0755) == 0);
    join(file, directory, "file.txt");
    make_file(file, "file", 0644);
    join(link, directory, "link_to_folder");
    assert(symlink("folder", link) == 0);
    join(link, directory, "link_to_file");
    assert(symlink("file.txt", link) == 0);
    join(link, directory, "dangling");
    assert(symlink("nowhere", link) == 0);
    join(link, directory, "loop");
    assert(symlink("loop", link) == 0);
    const int free_before = lowest_free_descriptor();
    const int directory_entries = count_entries(directory);
    const int folder_entries = count_entries(folder);
    static const struct { const char *name; int64_t code; } expected[] = {
        {"folder/", 5}, {"folder//", 5}, {"link_to_folder/", 5},
        {"file.txt/", 4}, {"link_to_file/", 4},
        {"missing/", 1}, {"dangling/", 1},
        {"loop/", -(int64_t)ELOOP},
    };
    for (size_t index = 0; index < sizeof expected / sizeof expected[0]; index++) {
        char path[PATH_BYTES];
        join(path, directory, expected[index].name);
        begin();
        assert(write_text_to(path, "text") == expected[index].code);
        assert(count_events(STAT_CALL, 0) == 1);
        assert(count_events(LSTAT_CALL, 0) == 0);
        assert(count_events(OPEN_CALL, 0) == 0);
        assert(count_entries(directory) == directory_entries);
        assert(count_entries(folder) == folder_entries);
        expect_clean(free_before, directory);
    }

    char path[PATH_BYTES];
    join(path, directory, "folder/");
    begin();
    inject(STAT_CALL, 0, 0, 1, EINTR);
    assert(write_text_to(path, "text") == 5);
    assert(count_events(STAT_CALL, 0) == 2);
    assert(count_events(OPEN_CALL, 0) == 0);
    assert(count_entries(directory) == directory_entries);
    expect_clean(free_before, directory);

    /* Success alone never means a directory: the mode decides. */
    begin();
    stat_reported_mode = S_IFREG | 0644;
    assert(write_text_to(path, "text") == 4);
    assert(count_events(STAT_CALL, 0) == 1);
    assert(count_events(OPEN_CALL, 0) == 0);
    assert(count_entries(directory) == directory_entries);
    expect_clean(free_before, directory);
    expect_contents(file, "file");
    return 0;
}

/* What the path names decides the failure: nothing is opened for writing, and
 * nothing is created. */
static int case_entry_kinds(const char *root) {
    char directory[PATH_BYTES], folder[PATH_BYTES], fifo[PATH_BYTES];
    char file[PATH_BYTES], inside_file[PATH_BYTES], missing_parent[PATH_BYTES];
    case_directory(directory, root, "entry_kinds");
    join(folder, directory, "folder");
    assert(mkdir(folder, 0755) == 0);
    join(fifo, directory, "pipe");
    assert(mkfifo(fifo, 0644) == 0);
    join(file, directory, "file.txt");
    make_file(file, "file", 0644);
    join(inside_file, file, "child");
    join(missing_parent, directory, "missing/child");
    const int free_before = lowest_free_descriptor();
    static const struct { const char *name; int64_t code; } expected[] = {
        {"folder", 5}, {"pipe", 7}, {"/dev/null", 7}, {"file.txt/child", 4}, {"missing/child", 1},
    };
    for (size_t index = 0; index < sizeof expected / sizeof expected[0]; index++) {
        char path[PATH_BYTES];
        if (expected[index].name[0] == '/') {
            copy_text(path, expected[index].name);
        } else {
            join(path, directory, expected[index].name);
        }
        begin();
        assert(write_text_to(path, "text") == expected[index].code);
        assert(count_events(OPEN_CALL, 0) == 0);
        expect_clean(free_before, directory);
    }
    assert(count_entries(directory) == 3);
    assert(count_entries(folder) == 0);
    return 0;
}

/* A read-only file is refused although rename alone would replace it, and a
 * writable file in a directory this process cannot write is refused because
 * the new file is created beside it. A slashed path through a directory it
 * cannot search is refused too. Root may write both. */
static int case_permission_kinds(const char *root) {
    /* The suite leaves this case out as root. */
    assert(geteuid() != 0);
    char directory[PATH_BYTES], read_only[PATH_BYTES], locked[PATH_BYTES], inside[PATH_BYTES], created[PATH_BYTES];
    char unsearchable[PATH_BYTES], inner[PATH_BYTES];
    case_directory(directory, root, "permission_kinds");
    join(read_only, directory, "read_only.txt");
    make_file(read_only, "kept", 0444);
    join(locked, directory, "locked");
    assert(mkdir(locked, 0755) == 0);
    join(inside, locked, "writable.txt");
    make_file(inside, "kept", 0644);
    join(created, locked, "created.txt");
    assert(chmod(locked, 0555) == 0);
    const int free_before = lowest_free_descriptor();

    begin();
    assert(write_text_to(read_only, "denied") == 2);
    assert(count_events(OPEN_CALL, O_EXCL) == 0);
    expect_contents(read_only, "kept");
    assert(mode_of(read_only) == 0444);
    expect_clean(free_before, directory);

    begin();
    assert(write_text_to(inside, "denied") == 2);
    expect_contents(inside, "kept");
    expect_clean(free_before, locked);

    begin();
    assert(write_text_to(created, "denied") == 2);
    expect_clean(free_before, locked);
    assert(chmod(locked, 0755) == 0);
    assert(count_entries(locked) == 1);

    /* A slashed path through a directory this process may not search. */
    join(unsearchable, directory, "unsearchable");
    assert(mkdir(unsearchable, 0755) == 0);
    join(inner, unsearchable, "inner/");
    assert(mkdir(inner, 0755) == 0);
    assert(chmod(unsearchable, 0600) == 0);
    begin();
    assert(write_text_to(inner, "denied") == 2);
    assert(count_events(STAT_CALL, 0) == 1);
    assert(count_events(OPEN_CALL, 0) == 0);
    expect_clean(free_before, directory);
    assert(chmod(unsearchable, 0755) == 0);
    assert(count_entries(unsearchable) == 1);
    assert(count_entries(inner) == 0);
    return 0;
}

/* A link is written through, in its target's directory, and stays a link. A
 * dangling link creates nothing, and a loop keeps its errno. */
static int case_symlinks(const char *root) {
    char directory[PATH_BYTES], links[PATH_BYTES], targets[PATH_BYTES], target[PATH_BYTES];
    char link[PATH_BYTES], chained[PATH_BYTES], dangling[PATH_BYTES], loop[PATH_BYTES], prefix[PATH_BYTES];
    case_directory(directory, root, "symlinks");
    join(links, directory, "links");
    join(targets, directory, "targets");
    assert(mkdir(links, 0755) == 0);
    assert(mkdir(targets, 0755) == 0);
    join(target, targets, "target.txt");
    make_file(target, "old", 0600);
    join(link, links, "link");
    assert(symlink("../targets/target.txt", link) == 0);
    join(chained, links, "chained");
    assert(symlink("link", chained) == 0);
    const int free_before = lowest_free_descriptor();

    begin();
    assert(write_text_to(link, "through the link") == 0);
    join(prefix, targets, ".blorp-tmp-");
    assert(starts_with(temporary_path(), prefix));
    assert(count_events(RENAME_CALL, 0) == 1);
    for (int index = 0; index < event_count; index++) {
        if (events[index].call == RENAME_CALL) assert(strcmp(events[index].destination, target) == 0);
    }
    expect_contents(target, "through the link");
    assert(mode_of(target) == 0600);
    struct stat status;
    assert(lstat(link, &status) == 0 && S_ISLNK(status.st_mode));
    char pointed[PATH_BYTES];
    const ssize_t pointed_length = readlink(link, pointed, sizeof pointed - 1);
    assert(pointed_length == (ssize_t)strlen("../targets/target.txt"));
    assert(memcmp(pointed, "../targets/target.txt", (size_t)pointed_length) == 0);
    expect_clean(free_before, links);
    assert(count_temporaries(targets) == 0);

    begin();
    assert(write_text_to(chained, "through two links") == 0);
    expect_contents(target, "through two links");
    assert(lstat(chained, &status) == 0 && S_ISLNK(status.st_mode));
    expect_clean(free_before, targets);

    join(dangling, links, "dangling");
    assert(symlink("nowhere", dangling) == 0);
    begin();
    assert(write_text_to(dangling, "nowhere") == 1);
    assert(count_events(OPEN_CALL, 0) == 0);
    expect_clean(free_before, links);

    join(loop, links, "loop");
    assert(symlink("loop", loop) == 0);
    begin();
    assert(write_text_to(loop, "loop") == -(int64_t)ELOOP);
    assert(count_events(OPEN_CALL, 0) == 0);
    expect_clean(free_before, links);
    assert(count_entries(links) == 4);
    assert(count_entries(targets) == 1);
    return 0;
}

static int child_case(int argc, char **argv) {
    if (argc != 3) return 2;
    const char *name = argv[1];
    const char *directory = argv[2];
    /* One allocation outside the cases, so that the strict accounting always
     * has something to balance. */
    blorp_string_release(string_of(name));
    if (strcmp(name, "order_replace") == 0) return case_order_replace(directory);
    if (strcmp(name, "order_new") == 0) return case_order_new(directory);
    if (strcmp(name, "empty_text") == 0) return case_empty_text(directory);
    if (strcmp(name, "short_write") == 0) return case_short_write(directory);
    if (strcmp(name, "interrupted") == 0) return case_interrupted(directory);
    if (strcmp(name, "flush_failure") == 0) return case_flush_failure(directory);
    if (strcmp(name, "barrier_unsupported") == 0) return case_barrier_unsupported(directory);
    if (strcmp(name, "close_failure") == 0) return case_close_failure(directory);
    if (strcmp(name, "rename_failure") == 0) return case_rename_failure(directory);
    if (strcmp(name, "directory_flush") == 0) return case_directory_flush(directory);
    if (strcmp(name, "temporary_names_exhausted") == 0) return case_temporary_names_exhausted(directory);
    if (strcmp(name, "owner") == 0) return case_owner(directory);
    if (strcmp(name, "file_too_large") == 0) return case_file_too_large(directory);
    if (strcmp(name, "path_kinds") == 0) return case_path_kinds(directory);
    if (strcmp(name, "slashed_paths") == 0) return case_slashed_paths(directory);
    if (strcmp(name, "entry_kinds") == 0) return case_entry_kinds(directory);
    if (strcmp(name, "permission_kinds") == 0) return case_permission_kinds(directory);
    if (strcmp(name, "symlinks") == 0) return case_symlinks(directory);
    if (strcmp(name, "probe_failure") == 0) return case_probe_failure(directory);
    return 2;
}

int main(int argc, char **argv) {
    blorp_memory_start();
    return blorp_memory_finish(child_case(argc, argv));
}
