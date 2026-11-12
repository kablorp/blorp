/* Native fs-helper unit probe, built with the unmodified production fragments.
 * Each case is one argument; a case that passes returns 0 and prints nothing. */
#define _POSIX_C_SOURCE 200809L
#include <assert.h>
#ifdef NDEBUG
#error the cases keep their work inside assert, so NDEBUG would skip it
#endif
#include <fcntl.h>
#include <signal.h>
#include <stdarg.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <unistd.h>

/* The production close is counted, so that each path can be shown to close the
 * descriptor it opened exactly once, and the production open's interrupted
 * calls are counted, so that a retry can be shown to have run. Both calls are
 * the real ones. */
static int close_calls = 0;
static int last_closed = -1;
static int interrupted_opens = 0;
static int counting_close(int descriptor);
static int counting_open(const char *path, int flags, ...);
#define close counting_close
#define open counting_open
#include "fs_runtime.c"
#undef close
#undef open

static int counting_close(int descriptor) {
    close_calls++;
    last_closed = descriptor;
    return close(descriptor);
}

/* The read fragment never creates a file, so open takes no mode here. */
static int counting_open(const char *path, int flags, ...) {
    assert((flags & O_CREAT) == 0);
    const int descriptor = open(path, flags);
    if (descriptor < 0 && errno == EINTR) interrupted_opens++;
    return descriptor;
}

/* The number the next open would return, without disturbing the counts. */
static int lowest_free_descriptor(void) {
    const int probe = open("/dev/null", O_RDONLY);
    assert(probe >= 0);
    assert(close(probe) == 0);
    return probe;
}

static struct blorp_string *string_of(const char *text) {
    return blorp_string_from_bytes(text, (int64_t)strlen(text));
}

/* "<directory>/<name>" as a C string in a shared buffer. */
static const char *path_in(const char *directory, const char *name) {
    static char path[1024];
    const int length = snprintf(path, sizeof path, "%s/%s", directory, name);
    assert(length > 0 && (size_t)length < sizeof path);
    return path;
}

static void write_bytes(const char *path, const char *bytes, size_t length) {
    FILE *stream = fopen(path, "wb");
    assert(stream != NULL);
    assert(fwrite(bytes, 1, length, stream) == length);
    assert(fclose(stream) == 0);
}

struct outcome {
    uint8_t succeeded;
    struct blorp_string *text;
    int64_t error;
};

/* Reads a path given as raw bytes, so a NUL can be embedded in it. */
static struct outcome read_bytes(const char *bytes, size_t length) {
    struct blorp_string *path = blorp_string_from_bytes(bytes, (int64_t)length);
    struct outcome outcome = {0, NULL, 0};
    outcome.succeeded = blorp_fs_read_text(path, &outcome.text, &outcome.error);
    blorp_string_release(path);
    return outcome;
}

static struct outcome read_path(const char *path) {
    return read_bytes(path, strlen(path));
}

/* A failure is reported with its code and no String. */
static void expect_failure(struct outcome outcome, int64_t code) {
    assert(outcome.succeeded == BLORP_FS_FAILED);
    assert(outcome.text == NULL);
    assert(outcome.error == code);
}

/* A success holds exactly these bytes, which are then released. */
static void expect_text(struct outcome outcome, const char *bytes, size_t length) {
    assert(outcome.succeeded == BLORP_FS_SUCCEEDED);
    assert(outcome.text->length == (int64_t)length);
    assert(memcmp(outcome.text->bytes, bytes, length) == 0);
    blorp_string_release(outcome.text);
}

/* An operation that opened a descriptor closed it once, and that one was it. */
static void expect_one_close(int before, int expected_descriptor) {
    assert(close_calls == before + 1);
    assert(last_closed == expected_descriptor);
    assert(lowest_free_descriptor() == expected_descriptor);
}

static int64_t entry_code(const char *path, int64_t *error) {
    struct blorp_string *name = string_of(path);
    int64_t kind = -1;
    int64_t unused = 0;
    const uint8_t succeeded = blorp_fs_entry_kind(name, &kind, error != NULL ? error : &unused);
    blorp_string_release(name);
    return succeeded == BLORP_FS_SUCCEEDED ? kind : -1;
}

/* Every code is a numeric literal, never an enum name, so a table that swapped
 * two of them would fail here, and fs.brp's decoder constants are the other
 * half of the agreement. */
static int case_codes(void) {
    static const struct { int number; int64_t code; } named[] = {
        {ENOENT, 1}, {EACCES, 2}, {EPERM, 2}, {EEXIST, 3}, {ENOTDIR, 4}, {EISDIR, 5},
        {ENOTEMPTY, 6}, {EROFS, 8}, {ENOSPC, 9}, {EDQUOT, 9}, {EFBIG, 10}, {EOVERFLOW, 10},
        {EXDEV, 11},
    };
    for (size_t index = 0; index < sizeof named / sizeof named[0]; index++) {
        assert(blorp_fs_errno_code(named[index].number) == named[index].code);
    }
    /* No errno with a named kind comes back as OtherOs, and every other errno
     * keeps its number, negated. */
    for (int number = 1; number < 256; number++) {
        int64_t expected = -(int64_t)number;
        for (size_t index = 0; index < sizeof named / sizeof named[0]; index++) {
            if (named[index].number == number) expected = named[index].code;
        }
        assert(blorp_fs_errno_code(number) == expected);
    }
    /* A mask keeps the kinds it names and sends every other errno negated, named or not. The
     * masks here are synthetic: the operations' own are proved through their natives. */
    static const uint32_t masks[] = {
        BLORP_FS_KIND(NOT_FOUND) | BLORP_FS_KIND(NOT_A_DIRECTORY),
        BLORP_FS_KIND(NO_SPACE),
    };
    for (size_t which = 0; which < sizeof masks / sizeof masks[0]; which++) {
        for (int number = 1; number < 256; number++) {
            int64_t expected = -(int64_t)number;
            for (size_t index = 0; index < sizeof named / sizeof named[0]; index++) {
                if (named[index].number == number && (masks[which] & (UINT32_C(1) << named[index].code)) != 0) {
                    expected = named[index].code;
                }
            }
            assert(blorp_fs_errno_code_within(number, masks[which]) == expected);
        }
    }
    /* The codes that no errno produces. */
    assert(BLORP_FS_NOT_A_REGULAR_FILE == 7);
    assert(BLORP_FS_PATH_CONTAINS_NUL == 12);
    assert(BLORP_FS_INVALID_UTF8 == 13);
    assert(BLORP_FS_ENTRY_ABSENT == 0 && BLORP_FS_ENTRY_FILE == 1 && BLORP_FS_ENTRY_DIRECTORY == 2);
    assert(BLORP_FS_ENTRY_SYMLINK == 3 && BLORP_FS_ENTRY_OTHER == 4);
    /* One allocation, so that the strict accounting has something to balance. */
    blorp_string_release(string_of("codes"));
    return 0;
}

/* The growth arithmetic never overflows and stops at the largest String. */
static int case_growth(void) {
    const size_t largest = (size_t)INT64_MAX;
    assert(blorp_fs_grown_capacity(4096, 1u << 20) == 8192);
    assert(blorp_fs_grown_capacity(8192, 10000) == 10000);
    assert(blorp_fs_grown_capacity(10000, 10000) == 0);
    assert(blorp_fs_grown_capacity(largest / 2, largest) == largest - 1);
    assert(blorp_fs_grown_capacity(largest / 2 + 1, largest) == largest);
    assert(blorp_fs_grown_capacity(largest - 1, largest) == largest);
    assert(blorp_fs_grown_capacity(largest, largest) == 0);
    blorp_string_release(string_of("growth"));
    return 0;
}

/* A NUL names no file, so a path whose prefix exists must not reach the
 * operating system: no descriptor is opened, and the prefix is not read. */
static int case_nul(const char *directory) {
    const char *existing = path_in(directory, "nul_target");
    write_bytes(existing, "present", 7);
    char bytes[1024];
    const size_t prefix = strlen(existing);
    memcpy(bytes, existing, prefix);
    memcpy(bytes + prefix, "\0suffix", 7);
    const int before = close_calls;
    expect_failure(read_bytes(bytes, prefix + 7), 12);
    assert(close_calls == before);

    struct blorp_string *path = blorp_string_from_bytes(bytes, (int64_t)(prefix + 7));
    int64_t kind = -1;
    int64_t error = 0;
    assert(blorp_fs_entry_kind(path, &kind, &error) == BLORP_FS_FAILED);
    assert(error == 12 && kind == -1);
    blorp_string_release(path);
    return 0;
}

/* Reading to the end of a file takes every size, around the first buffer's
 * capacity and past several doublings, and closes its descriptor once. */
static int case_sizes(const char *directory) {
    static const size_t sizes[] = {0, 1, 4095, 4096, 4097, 8191, 8192, 100000};
    const char *path = path_in(directory, "sizes.txt");
    for (size_t index = 0; index < sizeof sizes / sizeof sizes[0]; index++) {
        const size_t length = sizes[index];
        char *bytes = malloc(length + 1);
        assert(bytes != NULL);
        for (size_t position = 0; position < length; position++) {
            bytes[position] = (char)('a' + (position % 26));
        }
        write_bytes(path, bytes, length);
        const int before = close_calls;
        const int expected = lowest_free_descriptor();
        expect_text(read_path(path), bytes, length);
        expect_one_close(before, expected);
        free(bytes);
    }
    /* Valid UTF-8, including a multi-byte character and an embedded NUL. */
    static const char mixed[] = "h\xc3\xa9llo \xe2\x9c\x93\0end";
    write_bytes(path, mixed, sizeof mixed - 1);
    expect_text(read_path(path), mixed, sizeof mixed - 1);
    return 0;
}

/* Each failure reports its code, and a path that was opened is closed once. */
static int case_failures(const char *directory) {
    const char *file = path_in(directory, "failures_file.txt");
    write_bytes(file, "text", 4);
    char inside_file[1024];
    assert(snprintf(inside_file, sizeof inside_file, "%s/child", file) > 0);
    char missing[1024];
    assert(snprintf(missing, sizeof missing, "%s/failures_missing", directory) > 0);

    /* No descriptor is opened for either, so none is closed. */
    int before = close_calls;
    int expected = lowest_free_descriptor();
    expect_failure(read_path(missing), 1);
    expect_failure(read_path(inside_file), 4);
    assert(close_calls == before);
    assert(lowest_free_descriptor() == expected);

    /* A directory opens, so it is rejected after the open and then closed. */
    before = close_calls;
    expect_failure(read_path(directory), 5);
    expect_one_close(before, expected);

    const char *invalid = path_in(directory, "failures_invalid.bin");
    write_bytes(invalid, "ab\xff\xfe" "cd", 6);
    before = close_calls;
    expected = lowest_free_descriptor();
    expect_failure(read_path(invalid), 13);
    expect_one_close(before, expected);
    return 0;
}

/* A read that fails reports its errno and frees what it had read. */
static int case_read_error(const char *directory) {
    const char *path = path_in(directory, "write_only.txt");
    write_bytes(path, "text", 4);
    const int descriptor = open(path, O_WRONLY);
    assert(descriptor >= 0);
    char *contents = NULL;
    size_t length = 0;
    assert(blorp_fs_read_descriptor(descriptor, &contents, &length) == -(int64_t)EBADF);
    assert(contents == NULL);
    assert(close(descriptor) == 0);
    blorp_string_release(string_of("read error"));
    return 0;
}

/* lstat kinds: a link is never followed, and a missing path or a file used as
 * a directory is the absent code rather than a failure. */
static int case_entry_kinds(const char *directory) {
    const char *file = path_in(directory, "kinds_file.txt");
    write_bytes(file, "x", 1);
    assert(entry_code(file, NULL) == 1);

    char folder[1024];
    assert(snprintf(folder, sizeof folder, "%s/kinds_folder", directory) > 0);
    if (mkdir(folder, 0700) != 0) assert(errno == EEXIST);
    assert(entry_code(folder, NULL) == 2);

    char link_to_file[1024];
    assert(snprintf(link_to_file, sizeof link_to_file, "%s/kinds_link", directory) > 0);
    (void)unlink(link_to_file);
    assert(symlink("kinds_file.txt", link_to_file) == 0);
    assert(entry_code(link_to_file, NULL) == 3);

    char dangling[1024];
    assert(snprintf(dangling, sizeof dangling, "%s/kinds_dangling", directory) > 0);
    (void)unlink(dangling);
    assert(symlink("kinds_nowhere", dangling) == 0);
    assert(entry_code(dangling, NULL) == 3);

    char loop[1024];
    assert(snprintf(loop, sizeof loop, "%s/kinds_loop", directory) > 0);
    (void)unlink(loop);
    assert(symlink("kinds_loop", loop) == 0);
    assert(entry_code(loop, NULL) == 3);

    char fifo[1024];
    assert(snprintf(fifo, sizeof fifo, "%s/kinds_fifo", directory) > 0);
    (void)unlink(fifo);
    assert(mkfifo(fifo, 0600) == 0);
    assert(entry_code(fifo, NULL) == 4);

    char missing[1024];
    assert(snprintf(missing, sizeof missing, "%s/kinds_missing", directory) > 0);
    assert(entry_code(missing, NULL) == 0);
    char inside_file[1024];
    assert(snprintf(inside_file, sizeof inside_file, "%s/child", file) > 0);
    assert(entry_code(inside_file, NULL) == 0);

    /* Looking through the loop is a failure whose number is kept, negated. */
    char through_loop[1024];
    assert(snprintf(through_loop, sizeof through_loop, "%s/inside", loop) > 0);
    int64_t error = 0;
    assert(entry_code(through_loop, &error) == -1);
    assert(error == -(int64_t)ELOOP);
    return 0;
}

/* The interval timer's handler lets a child writer go on: one byte per tick.
 * Installed without SA_RESTART, so a blocked call returns EINTR. */
static int go_pipe[2];
static volatile sig_atomic_t ticks = 0;
enum { TICK_MICROSECONDS = 20000 };

static void on_tick(int signal_number) {
    (void)signal_number;
    const int saved = errno;
    const char go = 1;
    ticks++;
    const ssize_t written = write(go_pipe[1], &go, 1);
    (void)written;
    errno = saved;
}

static void start_ticks(void) {
    struct sigaction action;
    memset(&action, 0, sizeof action);
    action.sa_handler = on_tick;
    sigemptyset(&action.sa_mask);
    action.sa_flags = 0;
    assert(sigaction(SIGALRM, &action, NULL) == 0);
    const struct itimerval every = {{0, TICK_MICROSECONDS}, {0, TICK_MICROSECONDS}};
    assert(setitimer(ITIMER_REAL, &every, NULL) == 0);
}

static void stop_ticks(void) {
    const struct itimerval never = {{0, 0}, {0, 0}};
    assert(setitimer(ITIMER_REAL, &never, NULL) == 0);
}

static void wait_for_go(void) {
    char go;
    ssize_t received;
    do {
        received = read(go_pipe[0], &go, 1);
    } while (received < 0 && errno == EINTR);
    assert(received == 1);
}

static void write_all(int descriptor, const char *bytes, size_t length) {
    size_t done = 0;
    while (done < length) {
        const ssize_t written = write(descriptor, bytes + done, length - done);
        if (written < 0 && errno == EINTR) continue;
        assert(written > 0);
        done += (size_t)written;
    }
}

static void expect_child_exit(pid_t child) {
    int status = 0;
    assert(waitpid(child, &status, 0) == child);
    assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);
}

static const char *make_fifo(const char *directory, const char *name) {
    const char *path = path_in(directory, name);
    (void)unlink(path);
    assert(mkfifo(path, 0600) == 0);
    return path;
}

/* open blocks until a writer exists. The writer waits for the first tick, so
 * the reader's open returns EINTR at least once, which the counting open sees,
 * and must be retried, not failed. */
static int case_interrupted_open(const char *directory) {
    const char *fifo = make_fifo(directory, "interrupted_open.fifo");
    assert(pipe(go_pipe) == 0);
    const pid_t child = fork();
    assert(child >= 0);
    if (child == 0) {
        wait_for_go();
        const int writer = open(fifo, O_WRONLY);
        if (writer < 0) _exit(1);
        write_all(writer, "after the tick", 14);
        (void)close(writer);
        _exit(0);
    }
    start_ticks();
    const int before = close_calls;
    expect_text(read_path(fifo), "after the tick", 14);
    stop_ticks();
    assert(ticks >= 1);
    assert(interrupted_opens >= 1);
    assert(close_calls == before + 1);
    expect_child_exit(child);
    return 0;
}

/* A FIFO has no size, and a writer appends one chunk per tick while the reader
 * is blocked. Each tick interrupts the read, which is retried, until the writer
 * closes. The writer's open is the readiness handshake: the reader's open
 * returns only once the writer exists, and each chunk waits for a tick. */
static int case_appending_writer(const char *directory) {
    enum { CHUNKS = 10, CHUNK_SIZE = 20000 };
    const char *fifo = make_fifo(directory, "appending_writer.fifo");
    assert(pipe(go_pipe) == 0);
    const pid_t child = fork();
    assert(child >= 0);
    if (child == 0) {
        const int writer = open(fifo, O_WRONLY);
        if (writer < 0) _exit(1);
        for (int chunk = 0; chunk < CHUNKS; chunk++) {
            wait_for_go();
            char bytes[CHUNK_SIZE];
            memset(bytes, 'a' + chunk, sizeof bytes);
            write_all(writer, bytes, sizeof bytes);
        }
        (void)close(writer);
        _exit(0);
    }
    start_ticks();
    const int before = close_calls;
    struct outcome outcome = read_path(fifo);
    stop_ticks();
    assert(ticks >= CHUNKS);
    assert(outcome.succeeded == BLORP_FS_SUCCEEDED);
    assert(outcome.text->length == (int64_t)CHUNKS * CHUNK_SIZE);
    for (int chunk = 0; chunk < CHUNKS; chunk++) {
        for (int position = 0; position < CHUNK_SIZE; position += 997) {
            assert(outcome.text->bytes[chunk * CHUNK_SIZE + position] == 'a' + chunk);
        }
        assert(outcome.text->bytes[(chunk + 1) * CHUNK_SIZE - 1] == 'a' + chunk);
    }
    blorp_string_release(outcome.text);
    assert(close_calls == before + 1);
    expect_child_exit(child);
    return 0;
}

static int child_case(int argc, char **argv) {
    if (argc != 3) return 2;
    const char *name = argv[1];
    const char *directory = argv[2];
    if (strcmp(name, "codes") == 0) return case_codes();
    if (strcmp(name, "growth") == 0) return case_growth();
    if (strcmp(name, "nul") == 0) return case_nul(directory);
    if (strcmp(name, "sizes") == 0) return case_sizes(directory);
    if (strcmp(name, "failures") == 0) return case_failures(directory);
    if (strcmp(name, "read_error") == 0) return case_read_error(directory);
    if (strcmp(name, "entry_kinds") == 0) return case_entry_kinds(directory);
    if (strcmp(name, "interrupted_open") == 0) return case_interrupted_open(directory);
    if (strcmp(name, "appending_writer") == 0) return case_appending_writer(directory);
    return 2;
}

int main(int argc, char **argv) {
    blorp_memory_start();
    return blorp_memory_finish(child_case(argc, argv));
}
