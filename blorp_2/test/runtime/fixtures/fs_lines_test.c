/* Native probe of fs.open_read, fs.next_lines and fs.close, built with the
 * unmodified production fragments and the List[String] layout a program that
 * reads lines emits. Each case is one argument; a case that passes returns 0
 * and prints nothing.
 *
 * The system calls in the included runtime text are renamed to recording
 * wrappers (D6). Each wrapper appends the call to one event log and either
 * passes it through or returns an injected failure. The read wrapper can also
 * shorten a read, as a pipe or a FIFO may, so a case can split a line or a
 * character wherever it likes. Nothing in the production text changes, and no
 * other fragment here calls read. */
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
/* Every header the runtime text includes comes first, so the renaming macros
 * below rewrite only the runtime's calls and never a header's declarations. */
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

static int recording_open(const char *path, int flags, ...);
static ssize_t recording_read(int descriptor, void *bytes, size_t count);
static int recording_fstat(int descriptor, struct stat *status);
static int recording_close(int descriptor);
#define open recording_open
#define read recording_read
#define fstat recording_fstat
#define close recording_close
#include "fs_lines_runtime.c"
#undef open
#undef read
#undef fstat
#undef close

/* The List[String] layout of the included runtime text. */
typedef struct blorp_l_0_s lines_t;

enum call { OPEN_CALL, READ_CALL, FSTAT_CALL, CLOSE_CALL, CALL_KINDS };

enum { EVENT_CAPACITY = 1024, PATH_BYTES = 1024, LIMIT_CAPACITY = 8 };

/* A read-to-end stops after this many calls, so a broken end of file fails the
 * case instead of hanging it. */
enum { CALL_LIMIT = 64 };

/* One call as the runtime made it. `requested` is read's count and `result`
 * the call's return value. */
struct event {
    enum call call;
    int descriptor;
    size_t requested;
    long result;
    int error;
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
/* The next reads pass at most these many bytes, one limit per read, in order,
 * as a pipe that holds fewer bytes than were asked for. */
static size_t read_limits[LIMIT_CAPACITY];
static int read_limit_count = 0;
/* After the next read that succeeds, one byte is written here, so a writer
 * that waits on it knows the reader has taken what was sent. */
static int signal_after_read = -1;

static void record(enum call call, int descriptor, size_t requested, long result, int error) {
    assert(event_count < EVENT_CAPACITY);
    events[event_count++] = (struct event){call, descriptor, requested, result, error};
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

/* The runtime opens only for reading, so open takes no mode here. */
static int recording_open(const char *path, int flags, ...) {
    assert((flags & O_CREAT) == 0);
    const int injected = injected_error(OPEN_CALL);
    const int result = injected != 0 ? -1 : open(path, flags);
    const int error = outcome_error(injected, result < 0);
    record(OPEN_CALL, result, 0, result, error);
    if (result < 0) errno = error;
    return result;
}

static ssize_t recording_read(int descriptor, void *bytes, size_t count) {
    const int injected = injected_error(READ_CALL);
    size_t request = count;
    if (injected == 0 && read_limit_count > 0) {
        if (read_limits[0] < request) request = read_limits[0];
        read_limit_count--;
        memmove(read_limits, read_limits + 1, (size_t)read_limit_count * sizeof read_limits[0]);
    }
    const ssize_t result = injected != 0 ? -1 : read(descriptor, bytes, request);
    const int error = outcome_error(injected, result < 0);
    record(READ_CALL, descriptor, count, (long)result, error);
    if (result >= 0 && signal_after_read >= 0) {
        const char go = 1;
        assert(write(signal_after_read, &go, 1) == 1);
        signal_after_read = -1;
    }
    if (result < 0) errno = error;
    return result;
}

static int recording_fstat(int descriptor, struct stat *status) {
    const int injected = injected_error(FSTAT_CALL);
    const int result = injected != 0 ? -1 : fstat(descriptor, status);
    const int error = outcome_error(injected, result < 0);
    record(FSTAT_CALL, descriptor, 0, result, error);
    if (result < 0) errno = error;
    return result;
}

/* An injected failure still releases the descriptor, as Linux's close does. */
static int recording_close(int descriptor) {
    const int injected = injected_error(CLOSE_CALL);
    int result = close(descriptor);
    const int error = outcome_error(injected, result < 0);
    if (injected != 0) result = -1;
    record(CLOSE_CALL, descriptor, 0, result, error);
    if (result < 0) errno = error;
    return result;
}

/* Clears the log, every injection and every read limit. */
static void begin(void) {
    event_count = 0;
    memset(injections, 0, sizeof injections);
    read_limit_count = 0;
    signal_after_read = -1;
}

static void limit_reads(const size_t *limits, int count) {
    assert(count <= LIMIT_CAPACITY);
    memcpy(read_limits, limits, (size_t)count * sizeof limits[0]);
    read_limit_count = count;
}

static int count_events(enum call call) {
    int count = 0;
    for (int index = 0; index < event_count; index++) {
        if (events[index].call == call) count++;
    }
    return count;
}

/* The `ordinal`th read in the log, counting from 0. */
static const struct event *read_event(int ordinal) {
    for (int index = 0; index < event_count; index++) {
        if (events[index].call != READ_CALL) continue;
        if (ordinal == 0) return &events[index];
        ordinal--;
    }
    assert(!"no such read");
    return NULL;
}

/* The number the next open would return, outside the log. */
static int lowest_free_descriptor(void) {
    const int probe = open("/dev/null", O_RDONLY);
    assert(probe >= 0);
    assert(close(probe) == 0);
    return probe;
}

/* Every descriptor an open in the log returned is closed exactly once before
 * that number is returned again, and nothing else is closed. */
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

/* Each descriptor opened was closed once, and none is left open. */
static void expect_clean(int free_before) {
    expect_each_descriptor_closed_once();
    assert(lowest_free_descriptor() == free_before);
}

/* Whether the descriptor is still open, asked outside the log. */
static int is_open(int descriptor) {
    return fcntl(descriptor, F_GETFD) != -1;
}

/* "<directory>/<name>" into a caller's PATH_BYTES buffer. */
static void join(char *joined, const char *directory, const char *name) {
    const int length = snprintf(joined, PATH_BYTES, "%s/%s", directory, name);
    assert(length > 0 && length < PATH_BYTES);
}

static void write_file(const char *path, const char *bytes, size_t length) {
    FILE *stream = fopen(path, "wb");
    assert(stream != NULL);
    assert(fwrite(bytes, 1, length, stream) == length);
    assert(fclose(stream) == 0);
}

/* "<directory>/lines-<name>", holding `length` bytes. */
static void case_file(char *path, const char *directory, const char *name, const char *bytes, size_t length) {
    char file_name[PATH_BYTES];
    assert(snprintf(file_name, sizeof file_name, "lines-%s", name) > 0);
    join(path, directory, file_name);
    write_file(path, bytes, length);
}

static struct blorp_string *bytes_of(const char *bytes, size_t length) {
    return blorp_string_from_bytes(bytes, (int64_t)length);
}

static struct blorp_string *string_of(const char *text) {
    return bytes_of(text, strlen(text));
}

/* Each operation's code: 0 on success, the failure code otherwise. */
static int64_t outcome(uint8_t succeeded, int64_t error) {
    assert(succeeded == BLORP_FS_SUCCEEDED ? error == 0 : error != 0);
    return error;
}

static int64_t open_string(struct blorp_string *path, int64_t *descriptor) {
    int64_t error = 0;
    *descriptor = -1;
    const uint8_t succeeded = blorp_fs_open_read(path, descriptor, &error);
    blorp_string_release(path);
    assert(succeeded == BLORP_FS_SUCCEEDED ? *descriptor >= 0 : *descriptor == -1);
    return outcome(succeeded, error);
}

static int64_t open_path(const char *path, int64_t *descriptor) {
    return open_string(string_of(path), descriptor);
}

static int64_t open_existing(const char *path) {
    int64_t descriptor = -1;
    assert(open_path(path, &descriptor) == 0);
    return descriptor;
}

/* One next_lines call. On success `*lines` is the batch, which the caller
 * drops; on failure it is untouched, so nothing was published. */
static int64_t next_bytes(int64_t descriptor, const char *carried, size_t carried_length, lines_t **lines) {
    struct blorp_string *given = bytes_of(carried, carried_length);
    int64_t error = 0;
    *lines = NULL;
    const uint8_t succeeded = blorp_fs_next_lines(descriptor, given, lines, &error);
    blorp_string_release(given);
    assert(succeeded == BLORP_FS_SUCCEEDED ? *lines != NULL : *lines == NULL);
    return outcome(succeeded, error);
}

static int64_t next(int64_t descriptor, const char *carried, lines_t **lines) {
    return next_bytes(descriptor, carried, strlen(carried), lines);
}

static int64_t close_descriptor(int64_t descriptor) {
    int64_t error = 0;
    return outcome(blorp_fs_close(descriptor, &error), error);
}

/* The batch a call should return. */
enum { BATCH_CAPACITY = 8 };
struct batch {
    int64_t length;
    const char *lines[BATCH_CAPACITY];
};

static void expect_element(const lines_t *lines, int64_t index, const char *expected) {
    assert(index < lines->length);
    const struct blorp_string *line = lines->values[index];
    assert(line->length == (int64_t)strlen(expected));
    assert(memcmp(line->bytes, expected, strlen(expected)) == 0);
}

static void expect_batch(const lines_t *lines, const struct batch *expected) {
    assert(lines->length == expected->length);
    for (int64_t index = 0; index < expected->length; index++) expect_element(lines, index, expected->lines[index]);
}

/* The last element, which the next call is given, copied into `carried`. */
static void carry_last(const lines_t *lines, char *carried, size_t capacity) {
    const struct blorp_string *last = lines->values[lines->length - 1];
    assert((size_t)last->length < capacity);
    memcpy(carried, last->bytes, (size_t)last->length);
    carried[last->length] = '\0';
}

/* Calls next_lines from `carried` until a batch has fewer than two elements, as
 * a fold does, and checks each batch in turn. Fails after CALL_LIMIT calls. */
static void expect_batches(int64_t descriptor, const char *first_carried, const struct batch *expected, int count) {
    char carried[PATH_BYTES];
    assert(strlen(first_carried) < sizeof carried);
    memcpy(carried, first_carried, strlen(first_carried) + 1);
    int calls = 0;
    for (;;) {
        assert(calls < CALL_LIMIT);
        assert(calls < count);
        lines_t *lines = NULL;
        assert(next(descriptor, carried, &lines) == 0);
        expect_batch(lines, &expected[calls]);
        calls++;
        const int64_t length = lines->length;
        if (length >= 2) carry_last(lines, carried, sizeof carried);
        blorp_list_drop_0_s(lines);
        if (length < 2) break;
    }
    assert(calls == count);
}

/* Writes the file, opens it, reads every batch, and closes it once. */
static void expect_file_batches(const char *directory, const char *name, const char *bytes, size_t length,
                                const char *carried, const struct batch *expected, int count) {
    char path[PATH_BYTES];
    case_file(path, directory, name, bytes, length);
    const int free_before = lowest_free_descriptor();
    begin();
    const int64_t descriptor = open_existing(path);
    expect_batches(descriptor, carried, expected, count);
    assert(close_descriptor(descriptor) == 0);
    expect_clean(free_before);
}

/* The three result forms, the CR rule on each side of a call and at end of
 * file, and an empty line. */
static int case_batches(const char *directory) {
    static const struct batch empty[] = {{0, {0}}};
    expect_file_batches(directory, "empty", "", 0, "", empty, 1);
    static const struct batch newline[] = {{2, {"", ""}}, {0, {0}}};
    expect_file_batches(directory, "newline", "\n", 1, "", newline, 2);
    static const struct batch crlf[] = {{2, {"a", "b"}}, {1, {"b"}}};
    expect_file_batches(directory, "crlf", "a\r\nb", 4, "", crlf, 2);
    static const struct batch inner_cr[] = {{2, {"a\rb", ""}}, {0, {0}}};
    expect_file_batches(directory, "inner_cr", "a\rb\n", 4, "", inner_cr, 2);
    static const struct batch final_cr[] = {{1, {"a\r"}}};
    expect_file_batches(directory, "final_cr", "a\r", 2, "", final_cr, 1);
    static const struct batch carried[] = {{2, {"abc", "d"}}, {1, {"d"}}};
    expect_file_batches(directory, "carried", "c\nd", 3, "ab", carried, 2);
    static const struct batch carried_cr[] = {{2, {"a", "b"}}, {1, {"b"}}};
    expect_file_batches(directory, "carried_cr", "\nb", 2, "a\r", carried_cr, 2);
    return 0;
}

/* An invalid lead byte after the last LF needs no completion read: the line is
 * reported at once, and nothing is published. */
static int case_invalid_tail(const char *directory) {
    char path[PATH_BYTES];
    case_file(path, directory, "invalid_tail", "x\n\xF8", 3);
    const int free_before = lowest_free_descriptor();
    begin();
    const int64_t descriptor = open_existing(path);
    lines_t *lines = NULL;
    assert(next(descriptor, "", &lines) == 13);
    assert(count_events(READ_CALL) == 1);
    assert(close_descriptor(descriptor) == 0);
    expect_clean(free_before);
    return 0;
}

/* The `index`th short line: its length varies, so lines straddle the blocks
 * at every offset, and every third one ends in CRLF. */
static size_t short_line(size_t index, char *line) {
    const size_t length = 1 + (index * 7) % 23;
    for (size_t position = 0; position < length; position++) line[position] = (char)('a' + (index + position) % 26);
    return length;
}

static int ends_in_crlf(size_t index) {
    return index % 3 == 0;
}

/* A file of short lines larger than three blocks: each call makes exactly one
 * read, of one block, and the lines come back in order. The delivered lines,
 * with one byte for each LF and each removed CR, add up to the file's size. */
static int case_blocks(const char *directory) {
    enum { LINE_COUNT = 30000 };
    size_t size = 0;
    char *bytes = malloc((size_t)LINE_COUNT * 25);
    assert(bytes != NULL);
    for (size_t index = 0; index < LINE_COUNT; index++) {
        size += short_line(index, bytes + size);
        if (ends_in_crlf(index)) bytes[size++] = '\r';
        bytes[size++] = '\n';
    }
    assert(size > 3 * (size_t)BLORP_FS_LINE_BLOCK);
    char path[PATH_BYTES];
    case_file(path, directory, "blocks", bytes, size);
    free(bytes);

    const int free_before = lowest_free_descriptor();
    begin();
    const int64_t descriptor = open_existing(path);
    char carried[PATH_BYTES] = "";
    size_t delivered = 0;
    size_t next_index = 0;
    int calls = 0;
    for (;;) {
        assert(calls < CALL_LIMIT);
        const int reads_before = count_events(READ_CALL);
        lines_t *lines = NULL;
        assert(next(descriptor, carried, &lines) == 0);
        calls++;
        assert(count_events(READ_CALL) == reads_before + 1);
        assert(read_event(reads_before)->requested == (size_t)BLORP_FS_LINE_BLOCK);
        const int64_t length = lines->length;
        /* Every element but a trailing unfinished line is delivered. */
        const int64_t complete = length >= 2 ? length - 1 : length;
        for (int64_t index = 0; index < complete; index++) {
            char line[32];
            const size_t line_length = short_line(next_index, line);
            line[line_length] = '\0';
            expect_element(lines, index, line);
            delivered += line_length + 1 + (ends_in_crlf(next_index) ? 1 : 0);
            next_index++;
        }
        if (length >= 2) carry_last(lines, carried, sizeof carried);
        blorp_list_drop_0_s(lines);
        if (length < 2) break;
    }
    assert(next_index == LINE_COUNT);
    assert(delivered == size);
    assert(calls > 3);
    assert(close_descriptor(descriptor) == 0);
    expect_clean(free_before);
    return 0;
}

/* `count` copies of `fill`, then `tail`, into a fresh buffer whose length is
 * returned in `*length`. */
static char *filled(size_t count, char fill, const char *tail, size_t *length) {
    const size_t tail_length = strlen(tail);
    char *bytes = malloc(count + tail_length + 1);
    assert(bytes != NULL);
    memset(bytes, fill, count);
    memcpy(bytes + count, tail, tail_length + 1);
    *length = count + tail_length;
    return bytes;
}

/* Reads one batch from `path` with `carried` given, and checks that it holds a
 * first line of `count` copies of `fill` and then exactly `rest`. */
static void expect_long_first(int64_t descriptor, const char *carried, size_t count, char fill,
                              const struct batch *rest) {
    lines_t *lines = NULL;
    assert(next(descriptor, carried, &lines) == 0);
    assert(lines->length == rest->length + 1);
    const struct blorp_string *first = lines->values[0];
    assert(first->length == (int64_t)count);
    for (size_t position = 0; position < count; position++) assert(first->bytes[position] == fill);
    for (int64_t index = 0; index < rest->length; index++) expect_element(lines, index + 1, rest->lines[index]);
    blorp_list_drop_0_s(lines);
}

static void expect_end(int64_t descriptor) {
    lines_t *lines = NULL;
    assert(next(descriptor, "", &lines) == 0);
    assert(lines->length == 0);
    blorp_list_drop_0_s(lines);
}

/* An LF as a block's last byte ends the call with that block; an LF as the
 * next block's first byte takes a second read in the same call. A CR as a
 * block's last byte stays on the unfinished line and is removed once the next
 * call reads the LF after it. */
static int case_block_edges(const char *directory) {
    const size_t block = (size_t)BLORP_FS_LINE_BLOCK;
    char path[PATH_BYTES];
    size_t length = 0;

    char *bytes = filled(block - 1, 'a', "\nb\n", &length);
    case_file(path, directory, "edge_last", bytes, length);
    free(bytes);
    int free_before = lowest_free_descriptor();
    begin();
    int64_t descriptor = open_existing(path);
    static const struct batch after_last[] = {{1, {""}}};
    expect_long_first(descriptor, "", block - 1, 'a', &after_last[0]);
    assert(count_events(READ_CALL) == 1);
    static const struct batch then_b[] = {{2, {"b", ""}}, {0, {0}}};
    expect_batches(descriptor, "", then_b, 2);
    assert(close_descriptor(descriptor) == 0);
    expect_clean(free_before);

    bytes = filled(block, 'a', "\nb\n", &length);
    case_file(path, directory, "edge_first", bytes, length);
    free(bytes);
    free_before = lowest_free_descriptor();
    begin();
    descriptor = open_existing(path);
    static const struct batch after_first[] = {{2, {"b", ""}}};
    expect_long_first(descriptor, "", block, 'a', &after_first[0]);
    assert(count_events(READ_CALL) == 2);
    expect_end(descriptor);
    assert(close_descriptor(descriptor) == 0);
    expect_clean(free_before);

    /* "x\n", then y's up to a CR at the block's last byte, then the LF. */
    bytes = filled(block - 3, 'y', "\r\nz\n", &length);
    char *straddle = malloc(length + 2);
    assert(straddle != NULL);
    memcpy(straddle, "x\n", 2);
    memcpy(straddle + 2, bytes, length);
    free(bytes);
    assert(straddle[block - 1] == '\r' && straddle[block] == '\n');
    case_file(path, directory, "edge_cr", straddle, length + 2);
    free(straddle);
    free_before = lowest_free_descriptor();
    begin();
    descriptor = open_existing(path);
    lines_t *lines = NULL;
    assert(next(descriptor, "", &lines) == 0);
    assert(lines->length == 2);
    expect_element(lines, 0, "x");
    const struct blorp_string *unfinished = lines->values[1];
    assert(unfinished->length == (int64_t)(block - 2));
    assert(unfinished->bytes[block - 3] == '\r');
    struct blorp_string *carried = blorp_string_from_bytes(unfinished->bytes, unfinished->length);
    blorp_list_drop_0_s(lines);
    int64_t error = 0;
    assert(blorp_fs_next_lines(descriptor, carried, &lines, &error) == BLORP_FS_SUCCEEDED);
    blorp_string_release(carried);
    assert(lines->length == 3);
    assert(lines->values[0]->length == (int64_t)(block - 3));
    assert(memchr(lines->values[0]->bytes, '\r', block - 3) == NULL);
    expect_element(lines, 1, "z");
    expect_element(lines, 2, "");
    blorp_list_drop_0_s(lines);
    expect_end(descriptor);
    assert(close_descriptor(descriptor) == 0);
    expect_clean(free_before);
    return 0;
}

/* One 3 MiB line: the buffer doubles, so the reads stay at most the line's
 * block count plus two, and the line comes back whole. */
static int case_long_line(const char *directory) {
    const size_t line_length = (size_t)3 << 20;
    size_t length = 0;
    char *bytes = filled(line_length, 'x', "\n", &length);
    char path[PATH_BYTES];
    case_file(path, directory, "long_line", bytes, length);
    free(bytes);
    const int free_before = lowest_free_descriptor();
    begin();
    const int64_t descriptor = open_existing(path);
    static const struct batch unfinished[] = {{1, {""}}};
    expect_long_first(descriptor, "", line_length, 'x', &unfinished[0]);
    expect_end(descriptor);
    assert(count_events(READ_CALL) <= (int)(line_length / (size_t)BLORP_FS_LINE_BLOCK) + 2);
    assert(close_descriptor(descriptor) == 0);
    expect_clean(free_before);
    return 0;
}

/* Expects InvalidUtf8 from one call on a file of `bytes`, with the first read
 * limited to `first_limit` bytes (0 for no limit), and `reads` reads in all. The
 * descriptor stays open, and the strict accounting shows the buffer freed. */
static void expect_invalid(const char *directory, const char *name, const char *bytes, size_t length,
                           size_t first_limit, int reads) {
    char path[PATH_BYTES];
    case_file(path, directory, name, bytes, length);
    const int free_before = lowest_free_descriptor();
    begin();
    const int64_t descriptor = open_existing(path);
    if (first_limit > 0) limit_reads(&first_limit, 1);
    lines_t *lines = NULL;
    assert(next(descriptor, "", &lines) == 13);
    assert(count_events(READ_CALL) == reads);
    assert(count_events(CLOSE_CALL) == 0);
    assert(is_open((int)descriptor));
    assert(close_descriptor(descriptor) == 0);
    expect_clean(free_before);
}

/* "a\n", then a character of `width` bytes, then "\n". The first read stops
 * `split` bytes into the character; the character is finished by reads of the
 * missing bytes, each limited by `completion_limits`, and nothing more. */
static void expect_split_character(const char *directory, const char *character, size_t split,
                                   const size_t *completion_limits, int completion_reads) {
    const size_t width = strlen(character);
    char bytes[16];
    memcpy(bytes, "a\n", 2);
    memcpy(bytes + 2, character, width);
    bytes[2 + width] = '\n';
    char path[PATH_BYTES];
    case_file(path, directory, "split", bytes, width + 3);
    const int free_before = lowest_free_descriptor();
    begin();
    const int64_t descriptor = open_existing(path);
    size_t limits[LIMIT_CAPACITY];
    limits[0] = 2 + split;
    for (int index = 0; index < completion_reads; index++) limits[index + 1] = completion_limits[index];
    limit_reads(limits, completion_reads + 1);
    lines_t *lines = NULL;
    assert(next(descriptor, "", &lines) == 0);
    const struct batch first = {2, {"a", character}};
    expect_batch(lines, &first);
    blorp_list_drop_0_s(lines);
    /* The first read, then only completion reads, which ask for what is missing. */
    assert(count_events(READ_CALL) == 1 + completion_reads);
    size_t missing = width - split;
    for (int index = 0; index < completion_reads; index++) {
        const struct event *completion = read_event(index + 1);
        assert(completion->requested == missing);
        assert(completion->result > 0);
        missing -= (size_t)completion->result;
    }
    assert(missing == 0);
    const struct batch rest[] = {{2, {character, ""}}, {0, {0}}};
    expect_batches(descriptor, character, rest, 2);
    assert(close_descriptor(descriptor) == 0);
    expect_clean(free_before);
}

/* Every split of a two-, three- and four-byte character, each finished by one
 * read of exactly the missing bytes, and the four-byte one also a byte at a
 * time, as a FIFO may deliver it. End of file, or a byte that cannot continue
 * the character, before it is finished is InvalidUtf8. */
static int case_split_characters(const char *directory) {
    static const char *const characters[] = {"\xC3\xA9", "\xE2\x82\xAC", "\xF0\x9F\x98\x80"};
    static const size_t unlimited[] = {SIZE_MAX};
    for (size_t which = 0; which < sizeof characters / sizeof characters[0]; which++) {
        const size_t width = strlen(characters[which]);
        for (size_t split = 1; split < width; split++) {
            expect_split_character(directory, characters[which], split, unlimited, 1);
        }
    }
    static const size_t one_byte[] = {1, 1, 1};
    expect_split_character(directory, "\xF0\x9F\x98\x80", 1, one_byte, 3);
    expect_split_character(directory, "\xF0\x9F\x98\x80", 2, one_byte, 2);
    /* The completion read finds end of file. */
    expect_invalid(directory, "ends_in_lead", "a\n\xC3", 3, 0, 2);
    /* The completion read brings a byte that is no continuation byte. */
    expect_invalid(directory, "broken_sequence", "a\n\xC3" "b\n", 5, 3, 2);
    return 0;
}

/* One invalid line among many valid ones fails the batch, and so does a final
 * line that ends partway through a character. */
static int case_invalid_lines(const char *directory) {
    enum { LINE_COUNT = 200, INVALID_LINE = 117 };
    char bytes[LINE_COUNT * 8];
    size_t length = 0;
    for (int index = 0; index < LINE_COUNT; index++) {
        const int written = snprintf(bytes + length, sizeof bytes - length, index == INVALID_LINE ? "l%d\xFF\n" : "l%d\n", index);
        assert(written > 0);
        length += (size_t)written;
    }
    expect_invalid(directory, "invalid_among_valid", bytes, length, 0, 1);
    /* No LF at all: the final line is checked at end of file. */
    expect_invalid(directory, "only_lead", "\xC3", 1, 0, 2);
    return 0;
}

/* EINTR once each from open, fstat and read is retried, and the lines are
 * read as if nothing happened. */
static int case_interrupted(const char *directory) {
    char path[PATH_BYTES];
    case_file(path, directory, "interrupted", "a\nb\n", 4);
    const int free_before = lowest_free_descriptor();
    begin();
    inject(OPEN_CALL, 0, 1, EINTR);
    inject(FSTAT_CALL, 0, 1, EINTR);
    inject(READ_CALL, 0, 1, EINTR);
    const int64_t descriptor = open_existing(path);
    assert(count_events(OPEN_CALL) == 2 && count_events(FSTAT_CALL) == 2);
    static const struct batch expected[] = {{3, {"a", "b", ""}}, {0, {0}}};
    expect_batches(descriptor, "", expected, 2);
    assert(count_events(READ_CALL) == 3);
    assert(read_event(0)->error == EINTR && read_event(1)->result == 4 && read_event(2)->result == 0);
    assert(close_descriptor(descriptor) == 0);
    expect_clean(free_before);
    return 0;
}

/* EINTR from close is returned, never retried: on Linux the descriptor is
 * already released, and on XNU a retry could close another one. */
static int case_close_interrupted(const char *directory) {
    char path[PATH_BYTES];
    case_file(path, directory, "close_interrupted", "a\n", 2);
    const int free_before = lowest_free_descriptor();
    begin();
    const int64_t descriptor = open_existing(path);
    inject(CLOSE_CALL, 0, 1, EINTR);
    assert(close_descriptor(descriptor) == -(int64_t)EINTR);
    assert(count_events(CLOSE_CALL) == 1);
    expect_clean(free_before);
    return 0;
}

/* EIO partway through a long line: nothing is published, the buffer is freed,
 * and the descriptor stays open for the caller to close. */
static int case_read_error(const char *directory) {
    size_t length = 0;
    char *bytes = filled((size_t)1 << 20, 'x', "\n", &length);
    char path[PATH_BYTES];
    case_file(path, directory, "read_error", bytes, length);
    free(bytes);
    const int free_before = lowest_free_descriptor();
    begin();
    const int64_t descriptor = open_existing(path);
    inject(READ_CALL, 3, 1, EIO);
    lines_t *lines = NULL;
    assert(next(descriptor, "", &lines) == -(int64_t)EIO);
    assert(count_events(READ_CALL) == 4);
    assert(count_events(CLOSE_CALL) == 0);
    assert(is_open((int)descriptor));
    assert(close_descriptor(descriptor) == 0);
    expect_clean(free_before);
    return 0;
}

/* A directory is opened, refused and closed once; a missing path and a path
 * through a file open nothing; a NUL reaches no system call. */
static int case_open_failures(const char *directory) {
    char missing[PATH_BYTES], file[PATH_BYTES], inside_file[PATH_BYTES];
    join(missing, directory, "lines-missing");
    case_file(file, directory, "open_failure_file", "a\n", 2);
    assert(snprintf(inside_file, sizeof inside_file, "%s/child", file) > 0);
    int64_t descriptor = -1;

    const int free_before = lowest_free_descriptor();
    begin();
    assert(open_path(directory, &descriptor) == 5);
    assert(count_events(OPEN_CALL) == 1 && count_events(FSTAT_CALL) == 1 && count_events(CLOSE_CALL) == 1);
    expect_clean(free_before);

    begin();
    assert(open_path(missing, &descriptor) == 1);
    assert(open_path(inside_file, &descriptor) == 4);
    assert(count_events(FSTAT_CALL) == 0 && count_events(CLOSE_CALL) == 0);
    expect_clean(free_before);

    begin();
    char bytes[PATH_BYTES];
    const size_t prefix = strlen(file);
    memcpy(bytes, file, prefix);
    memcpy(bytes + prefix, "\0suffix", 7);
    assert(open_string(bytes_of(bytes, prefix + 7), &descriptor) == 12);
    assert(event_count == 0);
    return 0;
}

/* A file this process may not read is PermissionDenied. Not run as root. */
static int case_permission(const char *directory) {
    char path[PATH_BYTES];
    case_file(path, directory, "permission", "a\n", 2);
    assert(chmod(path, 0200) == 0);
    const int free_before = lowest_free_descriptor();
    begin();
    int64_t descriptor = -1;
    assert(open_path(path, &descriptor) == 2);
    expect_clean(free_before);
    assert(chmod(path, 0600) == 0);
    return 0;
}

/* A descriptor outside int's range, or negative, is EBADF's code with no
 * system call, so the cast to int never truncates. */
static int case_descriptor_range(const char *directory) {
    (void)directory;
    static const int64_t refused[] = {-1, INT64_MIN, (int64_t)INT_MAX + 1, INT64_MAX};
    begin();
    for (size_t index = 0; index < sizeof refused / sizeof refused[0]; index++) {
        lines_t *lines = NULL;
        assert(next(refused[index], "", &lines) == -(int64_t)EBADF);
        assert(close_descriptor(refused[index]) == -(int64_t)EBADF);
    }
    assert(event_count == 0);
    return 0;
}

/* A FIFO's writer sends "ab" and waits until the reader has read it, so the
 * reader is then inside the call, waiting for the rest of its line. The
 * writer sends "c\nd" and closes. The first call returns the whole line with
 * no read after the LF, and the second finds end of file. */
static int case_fifo(const char *directory) {
    char fifo[PATH_BYTES];
    join(fifo, directory, "lines.fifo");
    (void)unlink(fifo);
    assert(mkfifo(fifo, 0600) == 0);
    int go_pipe[2];
    assert(pipe(go_pipe) == 0);
    const pid_t child = fork();
    assert(child >= 0);
    if (child == 0) {
        (void)close(go_pipe[1]);
        const int writer = open(fifo, O_WRONLY);
        if (writer < 0) _exit(1);
        if (write(writer, "ab", 2) != 2) _exit(1);
        char go;
        ssize_t received;
        do {
            received = read(go_pipe[0], &go, 1);
        } while (received < 0 && errno == EINTR);
        if (received != 1) _exit(1);
        if (write(writer, "c\nd", 3) != 3) _exit(1);
        (void)close(writer);
        _exit(0);
    }
    assert(close(go_pipe[0]) == 0);
    const int free_before = lowest_free_descriptor();
    begin();
    const int64_t descriptor = open_existing(fifo);
    signal_after_read = go_pipe[1];
    lines_t *lines = NULL;
    assert(next(descriptor, "", &lines) == 0);
    static const struct batch first = {2, {"abc", "d"}};
    expect_batch(lines, &first);
    blorp_list_drop_0_s(lines);
    assert(count_events(READ_CALL) == 2);
    assert(read_event(0)->result == 2 && read_event(1)->result == 3);
    static const struct batch last[] = {{1, {"d"}}};
    expect_batches(descriptor, "d", last, 1);
    assert(count_events(READ_CALL) == 3 && read_event(2)->result == 0);
    assert(close_descriptor(descriptor) == 0);
    expect_clean(free_before);
    assert(close(go_pipe[1]) == 0);
    int status = 0;
    assert(waitpid(child, &status, 0) == child);
    assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);
    return 0;
}

static int child_case(int argc, char **argv) {
    if (argc != 3) return 2;
    const char *name = argv[1];
    const char *directory = argv[2];
    /* One allocation outside the cases, so that the strict accounting always
     * has something to balance. */
    blorp_string_release(string_of(name));
    if (strcmp(name, "batches") == 0) return case_batches(directory);
    if (strcmp(name, "invalid_tail") == 0) return case_invalid_tail(directory);
    if (strcmp(name, "blocks") == 0) return case_blocks(directory);
    if (strcmp(name, "block_edges") == 0) return case_block_edges(directory);
    if (strcmp(name, "long_line") == 0) return case_long_line(directory);
    if (strcmp(name, "split_characters") == 0) return case_split_characters(directory);
    if (strcmp(name, "invalid_lines") == 0) return case_invalid_lines(directory);
    if (strcmp(name, "interrupted") == 0) return case_interrupted(directory);
    if (strcmp(name, "close_interrupted") == 0) return case_close_interrupted(directory);
    if (strcmp(name, "read_error") == 0) return case_read_error(directory);
    if (strcmp(name, "open_failures") == 0) return case_open_failures(directory);
    if (strcmp(name, "permission") == 0) return case_permission(directory);
    if (strcmp(name, "descriptor_range") == 0) return case_descriptor_range(directory);
    if (strcmp(name, "fifo") == 0) return case_fifo(directory);
    return 2;
}

int main(int argc, char **argv) {
    blorp_memory_start();
    return blorp_memory_finish(child_case(argc, argv));
}
