/* Native probe of the console natives and print, and of their blocking jobs, built with
 * the unmodified production fragments, the pool's included, and the List[UInt8] layout a
 * program that uses them emits. Each case is one argument, after which comes a directory
 * the case may use; a case that passes returns 0 and prints nothing on standard output.
 *
 * A case supplies standard input by putting bytes in a file or pipe on
 * descriptor 0 before any read, and takes standard output (or error) to a file or
 * pipe on descriptor 1 (or 2). Each case is its own process, so stdio's buffers
 * start empty. A case that must see a process end forks it. */
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
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <sched.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

/* The whole-lines case yields to the other threads inside print, between its text and its
 * LF, where a print that is not one locked operation tears. */
static int yield_before_newline = 0;
static int probe_fputc(int character, FILE *stream);
#define fputc probe_fputc
#include "console_runtime.c"
#undef fputc
#include "carrier_harness.h"

static int probe_fputc(int character, FILE *stream) {
    if (yield_before_newline) {
        (void)sched_yield();
    }
    return fputc(character, stream);
}

typedef struct blorp_l_0_b *bytes_list;

/* The reader and writer give up after this long, so a missing flush or a
 * missing retry fails the case instead of hanging it. */
enum { ALARM_SECONDS = 10, POLL_MILLISECONDS = 300, BUFFER_STEP = 65536 };

/* A shell of the List the natives borrow: `length` bytes, which the caller drops. */
static bytes_list bytes_of(const void *bytes, size_t length) {
    bytes_list result = blorp_memory_allocate(sizeof *result + length);
    assert(result != NULL);
    atomic_init(&result->references, 1);
    result->length = (int64_t)length;
    result->capacity = length;
    if (length > 0) {
        memcpy(result->values, bytes, length);
    }
    return result;
}

/* Descriptor 0 becomes a file holding exactly these bytes. */
static void feed(const void *bytes, size_t length) {
    FILE *file = tmpfile();
    assert(file != NULL);
    assert(length == 0 || fwrite(bytes, 1, length, file) == length);
    assert(fflush(file) == 0);
    assert(lseek(fileno(file), 0, SEEK_SET) == 0);
    assert(dup2(fileno(file), STDIN_FILENO) == STDIN_FILENO);
    fclose(file);
}

static void feed_text(const char *text) {
    feed(text, strlen(text));
}

/* The next line read must be exactly these bytes, or empty at end of input. */
static void expect_line(const void *expected, size_t length) {
    bytes_list line = NULL;
    int64_t error = -1;
    assert(blorp_console_read_line(&line, &error) == BLORP_FS_SUCCEEDED);
    assert(line->length == (int64_t)length);
    assert(length == 0 || memcmp(line->values, expected, length) == 0);
    blorp_list_drop_0_b(line);
}

static void expect_line_text(const char *expected) {
    expect_line(expected, strlen(expected));
}

static void expect_exact(int64_t count, const void *expected, size_t length) {
    bytes_list bytes = NULL;
    int64_t error = -1;
    assert(blorp_console_read_exact(count, &bytes, &error) == BLORP_FS_SUCCEEDED);
    assert(bytes->length == (int64_t)length);
    assert(length == 0 || memcmp(bytes->values, expected, length) == 0);
    blorp_list_drop_0_b(bytes);
}

static void expect_exact_text(int64_t count, const char *expected) {
    expect_exact(count, expected, strlen(expected));
}

static int line_lf(void) {
    feed_text("one\ntwo\n");
    expect_line_text("one\n");
    expect_line_text("two\n");
    expect_line_text("");
    return 0;
}

/* The CR stays: landing 8's library strips a CR before the LF, not this native. */
static int line_crlf(void) {
    feed_text("ab\r\ncd\r\n");
    expect_line_text("ab\r\n");
    expect_line_text("cd\r\n");
    return 0;
}

static int line_empty(void) {
    feed_text("\n\nx\n");
    expect_line_text("\n");
    expect_line_text("\n");
    expect_line_text("x\n");
    expect_line_text("");
    return 0;
}

static int line_last_without_lf(void) {
    feed_text("first\nlast");
    expect_line_text("first\n");
    expect_line_text("last");
    expect_line_text("");
    return 0;
}

static int line_end_of_input(void) {
    feed_text("");
    expect_line_text("");
    expect_line_text("");
    return 0;
}

static int line_lone_cr(void) {
    feed_text("a\rb\nc\r");
    expect_line_text("a\rb\n");
    expect_line_text("c\r");
    expect_line_text("");
    return 0;
}

/* Bytes that are not UTF-8, a NUL and a long line (many growths) arrive unchanged. */
static int line_raw_bytes(void) {
    static const unsigned char odd[] = {0xff, 0xc0, 0x00, 0x80, 0xed, 0xa0, 0x80, '\n'};
    feed(odd, sizeof odd);
    expect_line(odd, sizeof odd);
    static unsigned char long_line[1000];
    memset(long_line, 'x', sizeof long_line);
    long_line[sizeof long_line - 1] = '\n';
    feed(long_line, sizeof long_line);
    expect_line(long_line, sizeof long_line);
    return 0;
}

/* Standard input that is a directory fails with the IsADirectory code. */
static int read_directory(const char *directory) {
    const int descriptor = open(directory, O_RDONLY);
    assert(descriptor >= 0);
    assert(dup2(descriptor, STDIN_FILENO) == STDIN_FILENO);
    close(descriptor);
    bytes_list bytes = NULL;
    int64_t error = -1;
    assert(blorp_console_read_line(&bytes, &error) == BLORP_FS_FAILED);
    assert(error == BLORP_FS_IS_A_DIRECTORY);
    error = -1;
    assert(blorp_console_read_exact(1, &bytes, &error) == BLORP_FS_FAILED);
    assert(error == BLORP_FS_IS_A_DIRECTORY);
    return 0;
}

static int exact_counts(void) {
    feed_text("abcdef");
    expect_exact_text(3, "abc");
    expect_exact_text(3, "def");
    expect_exact_text(1, "");
    return 0;
}

static int exact_short(void) {
    feed_text("ab");
    expect_exact_text(5, "ab");
    expect_exact_text(5, "");
    return 0;
}

/* A count of zero or less reads nothing, so the input is still there. */
static int exact_non_positive(void) {
    feed_text("xyz\n");
    expect_exact_text(0, "");
    expect_exact_text(-5, "");
    expect_exact(INT64_MIN, "", 0);
    expect_line_text("xyz\n");
    return 0;
}

/* The count is never reserved: ASan refuses a terabyte, so only what arrived is held. */
static int exact_huge_count(void) {
    feed_text("hello");
    expect_exact_text((int64_t)1 << 40, "hello");
    expect_exact(INT64_MAX, "", 0);
    return 0;
}

/* Inputs around the growth step arrive whole, from one read and from several. */
static int exact_growth(void) {
    static unsigned char input[3 * BUFFER_STEP + 1];
    for (size_t index = 0; index < sizeof input; index++) {
        input[index] = (unsigned char)(index * 7 + index / 251);
    }
    static const size_t counts[] = {BUFFER_STEP - 1, BUFFER_STEP, BUFFER_STEP + 1, 2 * BUFFER_STEP, sizeof input};
    for (size_t index = 0; index < sizeof counts / sizeof counts[0]; index++) {
        feed(input, sizeof input);
        expect_exact((int64_t)counts[index], input, counts[index]);
        expect_exact((int64_t)sizeof input, input + counts[index], sizeof input - counts[index]);
    }
    return 0;
}

static int exact_raw_bytes(void) {
    static const unsigned char odd[] = {0xff, 0x00, 0xfe, '\n', 0xc3};
    feed(odd, sizeof odd);
    expect_exact((int64_t)sizeof odd, odd, sizeof odd);
    return 0;
}

/* One stdio buffer serves both reads: the header lines, then exactly the body. */
static int shared_buffer(void) {
    feed_text("Content-Length: 2\r\n\r\n{}");
    expect_line_text("Content-Length: 2\r\n");
    expect_line_text("\r\n");
    expect_exact_text(2, "{}");
    expect_exact_text(1, "");
    return 0;
}

/* An end of input does not hide input that arrives later, as a terminal's ^D. */
static int input_after_end(void) {
    feed_text("a\n");
    expect_line_text("a\n");
    expect_line_text("");
    assert(pwrite(STDIN_FILENO, "b\n", 2, 2) == 2);
    expect_line_text("b\n");
    return 0;
}

/* Descriptor `target` becomes a pipe whose reader has gone. */
static void close_reader(int target) {
    int ends[2];
    assert(pipe(ends) == 0);
    close(ends[0]);
    assert(dup2(ends[1], target) == target);
    close(ends[1]);
}

/* A failed operation took no SIGPIPE: none is pending and the process lives. */
static void expect_no_pending_sigpipe(void) {
    sigset_t pending;
    assert(sigpending(&pending) == 0);
    assert(sigismember(&pending, SIGPIPE) == 0);
}

/* Callers must store the call's result before passing `error`: C leaves argument order
 * unspecified, and GCC on x86_64 reads `error` before the other argument's call sets it. */
static void expect_closed_reader(uint8_t result, int64_t error) {
    assert(result == BLORP_FS_FAILED);
    assert(error == -(int64_t)EPIPE);
    expect_no_pending_sigpipe();
}

/* Standard output buffers, so only a write larger than its buffer reaches the pipe. */
static int closed_write(void) {
    close_reader(STDOUT_FILENO);
    static unsigned char large[1 << 20];
    bytes_list data = bytes_of(large, sizeof large);
    int64_t error = -1;
    const uint8_t result = blorp_console_write(data, &error);
    expect_closed_reader(result, error);
    blorp_list_drop_0_b(data);
    return 0;
}

static int closed_flush(void) {
    close_reader(STDOUT_FILENO);
    bytes_list data = bytes_of("small", 5);
    int64_t error = -1;
    assert(blorp_console_write(data, &error) == BLORP_FS_SUCCEEDED);
    const uint8_t result = blorp_console_flush(&error);
    expect_closed_reader(result, error);
    blorp_list_drop_0_b(data);
    return 0;
}

/* Standard error is unbuffered. It is put back, since the harness reads its report. */
static int closed_write_error(void) {
    const int saved = dup(STDERR_FILENO);
    assert(saved >= 0);
    close_reader(STDERR_FILENO);
    bytes_list data = bytes_of("x", 1);
    int64_t error = -1;
    const uint8_t result = blorp_console_write_error(data, &error);
    assert(dup2(saved, STDERR_FILENO) == STDERR_FILENO);
    close(saved);
    clearerr(stderr);
    expect_closed_reader(result, error);
    blorp_list_drop_0_b(data);
    return 0;
}

/* A child writes, with buffered print output before it, and exits with its reader
 * gone. It must exit 0: stdio's own flush at exit would raise SIGPIPE. */
static int closed_exit(void) {
    assert(fflush(NULL) == 0);
    const pid_t child = fork();
    assert(child >= 0);
    if (child == 0) {
        close_reader(STDOUT_FILENO);
        assert(fputs("printed\n", stdout) >= 0);
        bytes_list data = bytes_of("written", 7);
        int64_t error = -1;
        assert(blorp_console_write(data, &error) == BLORP_FS_SUCCEEDED);
        blorp_list_drop_0_b(data);
        exit(0);
    }
    int status = 0;
    assert(waitpid(child, &status, 0) == child);
    assert(WIFEXITED(status));
    assert(WEXITSTATUS(status) == 0);
    /* The accounting report must show allocations, and the forked child made them, not this process. */
    blorp_list_drop_0_b(bytes_of("done", 4));
    return 0;
}

/* A child that printed, then only flushed (or only read, which flushes first) with
 * its reader gone, must also exit with its status: the failed flush keeps the buffer,
 * and stdio's own flush at exit would raise SIGPIPE. */
static int closed_exit_without_write(int read_instead) {
    assert(fflush(NULL) == 0);
    const pid_t child = fork();
    assert(child >= 0);
    if (child == 0) {
        close_reader(STDOUT_FILENO);
        assert(fputs("printed\n", stdout) >= 0);
        int64_t error = -1;
        if (read_instead) {
            feed_text("x\n");
            expect_line_text("x\n");
        } else {
            assert(blorp_console_flush(&error) == BLORP_FS_FAILED);
        }
        exit(0);
    }
    int status = 0;
    assert(waitpid(child, &status, 0) == child);
    assert(WIFEXITED(status));
    assert(WEXITSTATUS(status) == 0);
    blorp_list_drop_0_b(bytes_of("done", 4));
    return 0;
}

/* print-style fwrite and the console write share one buffer, so their order holds. */
static int output_order(void) {
    FILE *sink = tmpfile();
    assert(sink != NULL);
    assert(dup2(fileno(sink), STDOUT_FILENO) == STDOUT_FILENO);
    int64_t error = -1;
    bytes_list second = bytes_of("B", 1);
    bytes_list fourth = bytes_of("D", 1);
    assert(fwrite("A", 1, 1, stdout) == 1);
    assert(blorp_console_write(second, &error) == BLORP_FS_SUCCEEDED);
    assert(fwrite("C", 1, 1, stdout) == 1);
    assert(blorp_console_write(fourth, &error) == BLORP_FS_SUCCEEDED);
    assert(blorp_console_flush(&error) == BLORP_FS_SUCCEEDED);
    char seen[8] = {0};
    assert(pread(fileno(sink), seen, sizeof seen, 0) == 4);
    assert(memcmp(seen, "ABCD", 4) == 0);
    blorp_list_drop_0_b(second);
    blorp_list_drop_0_b(fourth);
    fclose(sink);
    return 0;
}

/* Each of LINE_THREADS threads prints a line of its own, prints it again with print_error,
 * and writes a second line of its own with the console's write, LINES_PER_THREAD times. Every
 * line arrives whole: print and print_error hold their stream from the text to the LF, and
 * the console's write is one fwrite, which the stream's own lock keeps whole. */
enum { LINE_THREADS = 4, LINES_PER_THREAD = 10000, LINE_TEXT = 48, LINE_KINDS = 2 * LINE_THREADS };

struct line_writer {
    struct blorp_string *printed;
    bytes_list written;
};

static void *write_lines(void *argument) {
    const struct line_writer *writer = argument;
    for (int index = 0; index < LINES_PER_THREAD; index++) {
        int64_t error = -1;
        assert(blorp_string_print(writer->printed) == (uint8_t)0);
        assert(blorp_string_print_error(writer->printed) == (uint8_t)0);
        assert(blorp_console_write(writer->written, &error) == BLORP_FS_SUCCEEDED);
    }
    return NULL;
}

/* Every line of the file on `descriptor` is one of the first `kinds` lines, each `each` times. */
static void expect_whole_lines(int descriptor, char lines[][LINE_TEXT], int kinds, int each) {
    struct stat status;
    assert(fstat(descriptor, &status) == 0);
    char *text = malloc((size_t)status.st_size + 1);
    assert(text != NULL);
    assert(pread(descriptor, text, (size_t)status.st_size, 0) == status.st_size);
    text[status.st_size] = '\0';
    int counts[LINE_KINDS] = {0};
    for (char *line = text; *line != '\0';) {
        char *end = strchr(line, '\n');
        assert(end != NULL);
        *end = '\0';
        int kind = 0;
        while (kind < kinds && strcmp(line, lines[kind]) != 0) {
            kind++;
        }
        assert(kind < kinds);
        counts[kind]++;
        line = end + 1;
    }
    for (int kind = 0; kind < kinds; kind++) {
        assert(counts[kind] == each);
    }
    free(text);
}

static int whole_lines(void) {
    FILE *out = tmpfile();
    FILE *errors = tmpfile();
    assert(out != NULL && errors != NULL);
    const int saved_error = dup(STDERR_FILENO);
    assert(saved_error >= 0);
    assert(dup2(fileno(out), STDOUT_FILENO) == STDOUT_FILENO);
    assert(dup2(fileno(errors), STDERR_FILENO) == STDERR_FILENO);
    /* The printed lines, then the written ones, each without its LF. */
    char lines[LINE_KINDS][LINE_TEXT];
    struct line_writer writers[LINE_THREADS];
    for (int index = 0; index < LINE_THREADS; index++) {
        const int printed = snprintf(lines[index], LINE_TEXT, "thread %d printed this line", index);
        const int written = snprintf(lines[LINE_THREADS + index], LINE_TEXT, "thread %d wrote this line\n", index);
        assert(printed > 0 && printed < LINE_TEXT && written > 0 && written < LINE_TEXT);
        writers[index].printed = blorp_string_from_bytes(lines[index], printed);
        writers[index].written = bytes_of(lines[LINE_THREADS + index], (size_t)written);
        lines[LINE_THREADS + index][written - 1] = '\0';
    }
    pthread_t threads[LINE_THREADS];
    yield_before_newline = 1;
    for (int index = 0; index < LINE_THREADS; index++) {
        assert(pthread_create(&threads[index], NULL, write_lines, &writers[index]) == 0);
    }
    for (int index = 0; index < LINE_THREADS; index++) {
        assert(pthread_join(threads[index], NULL) == 0);
    }
    yield_before_newline = 0;
    assert(fflush(stdout) == 0);
    assert(dup2(saved_error, STDERR_FILENO) == STDERR_FILENO);
    close(saved_error);
    clearerr(stderr);
    expect_whole_lines(fileno(out), lines, LINE_KINDS, LINES_PER_THREAD);
    expect_whole_lines(fileno(errors), lines, LINE_THREADS, LINES_PER_THREAD);
    for (int index = 0; index < LINE_THREADS; index++) {
        blorp_string_release(writers[index].printed);
        blorp_list_drop_0_b(writers[index].written);
    }
    fclose(errors);
    fclose(out);
    return 0;
}

/* A reader that answers only once it has seen the prompt, so the read must flush
 * standard output before it waits. */
static int flush_before_read(void) {
    int prompt[2], answer[2];
    assert(pipe(prompt) == 0 && pipe(answer) == 0);
    assert(fflush(NULL) == 0);
    const pid_t reader = fork();
    assert(reader >= 0);
    if (reader == 0) {
        close(prompt[1]);
        close(answer[0]);
        alarm(ALARM_SECONDS);
        char seen[16];
        size_t length = 0;
        while (length < 6) {
            const ssize_t received = read(prompt[0], seen + length, sizeof seen - length);
            if (received <= 0) {
                _exit(1);
            }
            length += (size_t)received;
        }
        _exit(memcmp(seen, "prompt", 6) == 0 && write(answer[1], "answer\n", 7) == 7 ? 0 : 1);
    }
    close(prompt[0]);
    close(answer[1]);
    assert(dup2(prompt[1], STDOUT_FILENO) == STDOUT_FILENO);
    assert(dup2(answer[0], STDIN_FILENO) == STDIN_FILENO);
    close(prompt[1]);
    close(answer[0]);
    alarm(ALARM_SECONDS);
    bytes_list data = bytes_of("prompt", 6);
    int64_t error = -1;
    assert(blorp_console_write(data, &error) == BLORP_FS_SUCCEEDED);
    expect_line_text("answer\n");
    alarm(0);
    blorp_list_drop_0_b(data);
    int status = 0;
    assert(waitpid(reader, &status, 0) == reader);
    assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);
    return 0;
}

static void on_alarm(int signal_number) {
    (void)signal_number;
}

/* A signal that interrupts a blocked read is retried, and the line still arrives.
 * The handler is installed without SA_RESTART, so the read returns EINTR. */
static int interrupted_read(void) {
    int input[2];
    assert(pipe(input) == 0);
    struct sigaction action;
    memset(&action, 0, sizeof action);
    action.sa_handler = on_alarm;
    assert(sigemptyset(&action.sa_mask) == 0);
    assert(sigaction(SIGALRM, &action, NULL) == 0);
    assert(fflush(NULL) == 0);
    const pid_t writer = fork();
    assert(writer >= 0);
    if (writer == 0) {
        close(input[0]);
        poll(NULL, 0, POLL_MILLISECONDS);
        _exit(write(input[1], "late\nmore", 9) == 9 ? 0 : 1);
    }
    close(input[1]);
    assert(dup2(input[0], STDIN_FILENO) == STDIN_FILENO);
    close(input[0]);
    const struct itimerval soon = {{0, 20000}, {0, 20000}};
    assert(setitimer(ITIMER_REAL, &soon, NULL) == 0);
    expect_line_text("late\n");
    expect_exact_text(4, "more");
    const struct itimerval never = {{0, 0}, {0, 0}};
    assert(setitimer(ITIMER_REAL, &never, NULL) == 0);
    int status = 0;
    assert(waitpid(writer, &status, 0) == writer);
    assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);
    return 0;
}

/* ---- standard input as the runtime owns it ---- */

/* Descriptor 0 becomes a pipe's read end, and its write end is returned. `watch` keeps
 * the read end too, on which FIONREAD counts the bytes no reader has taken. */
static int pipe_input(int *watch) {
    int ends[2];
    assert(pipe(ends) == 0);
    assert(dup2(ends[0], STDIN_FILENO) == STDIN_FILENO);
    *watch = ends[0];
    return ends[1];
}

/* A blocking write to a pipe or terminal is whole unless a signal interrupts it, and these cases catch none. */
static void send_bytes(int writer, const void *bytes, size_t length) {
    assert(write(writer, bytes, length) == (ssize_t)length);
}

static void send_text(int writer, const char *text) {
    send_bytes(writer, text, strlen(text));
}

/* Returns once a reader has taken every byte written to the pipe `watch` reads. */
static void until_taken(int watch) {
    for (int unread = 1; unread > 0; sched_yield()) {
        assert(ioctl(watch, FIONREAD, &unread) == 0);
    }
}

/* The read end of a cancel pipe that is readable already. */
static int readable_cancel(void) {
    int ends[2];
    assert(pipe(ends) == 0);
    assert(write(ends[1], "", 1) == 1);
    return ends[0];
}

static void expect_line_cancellable(int cancel, const char *expected) {
    bytes_list line = NULL;
    int64_t error = -1;
    assert(blorp_console_read_line_cancellable(&line, &error, cancel) == BLORP_FS_SUCCEEDED);
    assert(line->length == (int64_t)strlen(expected));
    assert(memcmp(line->values, expected, strlen(expected)) == 0);
    blorp_list_drop_0_b(line);
}

/* Cancellable reads, each on a thread of its own or in place, which must end as the end of input. */
enum { PARTIAL_COUNT = 10 };
static void *line_until_cancelled(void *cancel) {
    expect_line_cancellable((int)(intptr_t)cancel, "");
    return NULL;
}
static void *exact_until_cancelled(void *cancel) {
    bytes_list bytes = NULL;
    int64_t error = -1;
    assert(blorp_console_read_exact_cancellable(PARTIAL_COUNT, &bytes, &error, (int)(intptr_t)cancel) == BLORP_FS_SUCCEEDED);
    assert(bytes->length == 0);
    blorp_list_drop_0_b(bytes);
    return NULL;
}

/* Starts `read` on a thread, sends it `length` bytes, cancels it once it has taken them
 * all, and waits for it to end. */
static void cancel_after(void *(*read)(void *), int writer, int watch, const void *bytes, size_t length) {
    int cancel[2];
    assert(pipe(cancel) == 0);
    pthread_t reader;
    assert(pthread_create(&reader, NULL, read, (void *)(intptr_t)cancel[0]) == 0);
    send_bytes(writer, bytes, length);
    until_taken(watch);
    assert(write(cancel[1], "", 1) == 1);
    assert(pthread_join(reader, NULL) == 0);
}

/* One write's chunk: each read takes its line, and the rest waits for the next. */
static int pending_rest(void) {
    int watch;
    const int writer = pipe_input(&watch);
    send_text(writer, "a\nb\nc");
    close(writer);
    expect_line_text("a\n");
    expect_line_text("b\n");
    expect_line_text("c");
    expect_line_text("");
    return 0;
}

/* An empty pipe that the parent made O_NONBLOCK, with a line written POLL_MILLISECONDS later: the read waits
 * for it, where a read through stdio failed at once with EAGAIN. */
static int nonblocking_input(void) {
    int watch;
    const int writer = pipe_input(&watch);
    assert(fcntl(STDIN_FILENO, F_SETFL, fcntl(STDIN_FILENO, F_GETFL) | O_NONBLOCK) == 0);
    assert(fflush(NULL) == 0);
    const pid_t late = fork();
    assert(late >= 0);
    if (late == 0) {
        poll(NULL, 0, POLL_MILLISECONDS);
        _exit(write(writer, "late\n", 5) == 5 ? 0 : 1);
    }
    close(writer);
    alarm(ALARM_SECONDS);
    expect_line_text("late\n");
    int status = 0;
    assert(waitpid(late, &status, 0) == late && WIFEXITED(status) && WEXITSTATUS(status) == 0);
    return 0;
}

/* With the writer open and nothing written, a cancel ends both reads at once. */
static int cancel_while_waiting(void) {
    int watch;
    const int writer = pipe_input(&watch);
    const int cancel = readable_cancel();
    alarm(ALARM_SECONDS);
    expect_line_cancellable(cancel, "");
    (void)exact_until_cancelled((void *)(intptr_t)cancel);
    close(writer);
    return 0;
}

/* A cancelled read gives back what it took, and the next read continues from it. */
static int cancel_keeps_partial(void) {
    int watch;
    const int writer = pipe_input(&watch);
    alarm(ALARM_SECONDS);
    cancel_after(line_until_cancelled, writer, watch, "par", 3);
    send_text(writer, "tial\n");
    expect_line_text("partial\n");
    cancel_after(exact_until_cancelled, writer, watch, "abcd", 4);
    send_text(writer, "efghij");
    expect_exact_text(PARTIAL_COUNT, "abcdefghij");
    return 0;
}

/* The cancel is seen only once a read needs the descriptor, so a line in the buffer wins. */
static int pending_line_beats_cancel(void) {
    int watch;
    const int writer = pipe_input(&watch);
    send_text(writer, "w\nx\ny");
    expect_line_text("w\n");
    const int cancel = readable_cancel();
    alarm(ALARM_SECONDS);
    expect_line_cancellable(cancel, "x\n");
    expect_line_cancellable(cancel, "");
    close(writer);
    expect_line_text("y");
    return 0;
}

/* A partial larger than the buffer's step goes back whole. */
enum { GROWN_PARTIAL = 200000 };
static int cancel_partial_grows(void) {
    static unsigned char line[GROWN_PARTIAL + 1];
    memset(line, 'z', GROWN_PARTIAL);
    line[GROWN_PARTIAL] = '\n';
    int watch;
    const int writer = pipe_input(&watch);
    alarm(ALARM_SECONDS);
    cancel_after(line_until_cancelled, writer, watch, line, GROWN_PARTIAL);
    send_text(writer, "\n");
    expect_line(line, sizeof line);
    return 0;
}

/* A terminal holding a partial canonical line is not readable, so a cancel reaches the
 * read waiting on it. The reader has POLL_MILLISECONDS to reach its wait: a cancel that
 * comes before then passes without testing the terminal, never wrongly. */
static int terminal_cancel(void) {
    const int terminal = posix_openpt(O_RDWR | O_NOCTTY);
    assert(terminal >= 0 && grantpt(terminal) == 0 && unlockpt(terminal) == 0);
    const int user = open(ptsname(terminal), O_RDWR | O_NOCTTY);
    assert(user >= 0 && dup2(user, STDIN_FILENO) == STDIN_FILENO);
    close(user);
    send_text(terminal, "par");
    int cancel[2];
    assert(pipe(cancel) == 0);
    alarm(ALARM_SECONDS);
    pthread_t reader;
    assert(pthread_create(&reader, NULL, line_until_cancelled, (void *)(intptr_t)cancel[0]) == 0);
    poll(NULL, 0, POLL_MILLISECONDS);
    assert(write(cancel[1], "", 1) == 1);
    assert(pthread_join(reader, NULL) == 0);
    send_text(terminal, "tial\n");
    expect_line_text("partial\n");
    return 0;
}

/* Two threads read lines in place from 2N lines of WHOLE_LINE bytes, each one letter, which
 * arrive in writes of random sizes: every line comes back whole, and exactly once. */
enum { READERS = 2, LINES_PER_READER = 8, WHOLE_LINE = 100000, ALL_LINES = READERS * LINES_PER_READER };
enum { WRITE_MASK = 8191, WRITE_JITTER_MASK = 1023 };
static unsigned char whole_input[ALL_LINES][WHOLE_LINE + 1];
static atomic_int lines_seen[ALL_LINES];
static void *read_whole_lines(void *argument) {
    (void)argument;
    for (int index = 0; index < LINES_PER_READER; index++) {
        bytes_list line = NULL;
        int64_t error = -1;
        assert(blorp_console_read_line(&line, &error) == BLORP_FS_SUCCEEDED);
        const int letter = line->values[0] - 'a';
        assert(letter >= 0 && letter < ALL_LINES && line->length == WHOLE_LINE + 1);
        assert(memcmp(line->values, whole_input[letter], WHOLE_LINE + 1) == 0);
        atomic_fetch_add(&lines_seen[letter], 1);
        blorp_list_drop_0_b(line);
    }
    return NULL;
}
static int whole_reads(void) {
    for (int index = 0; index < ALL_LINES; index++) {
        memset(whole_input[index], 'a' + index, WHOLE_LINE);
        whole_input[index][WHOLE_LINE] = '\n';
    }
    int watch;
    const int writer = pipe_input(&watch);
    alarm(ALARM_SECONDS);
    pthread_t readers[READERS];
    for (int index = 0; index < READERS; index++) {
        assert(pthread_create(&readers[index], NULL, read_whole_lines, NULL) == 0);
    }
    uint64_t random = RANDOM_SEED;
    for (size_t sent = 0, size; sent < sizeof whole_input; sent += size) {
        size = 1 + (size_t)(next_random(&random) & WRITE_MASK);
        if (size > sizeof whole_input - sent) {
            size = sizeof whole_input - sent;
        }
        send_bytes(writer, (const unsigned char *)whole_input + sent, size);
        jitter(&random, WRITE_JITTER_MASK);
    }
    close(writer);
    for (int index = 0; index < READERS; index++) {
        assert(pthread_join(readers[index], NULL) == 0);
    }
    for (int index = 0; index < ALL_LINES; index++) {
        assert(atomic_load(&lines_seen[index]) == 1);
    }
    return 0;
}

/* The file on `descriptor` holds exactly `expected`. */
static void expect_file_text(int descriptor, const char *expected) {
    char seen[256] = {0};
    assert(pread(descriptor, seen, sizeof seen, 0) == (ssize_t)strlen(expected));
    assert(memcmp(seen, expected, strlen(expected)) == 0);
}

/* A child whose in-place read holds the line lock, waiting for the rest of "par", starts
 * a cancellable read: the program must stop with the refusal, before its alarm. */
static const char LOCK_REFUSAL[] = "error: console invariant broken: a cancellable console read found the line lock "
                                   "held: the kernel admits one console reader at a time\n";
static void *hold_line_lock(void *argument) {
    (void)argument;
    bytes_list line = NULL;
    int64_t error = -1;
    (void)blorp_console_read_line(&line, &error);
    return NULL;
}
static int line_lock_refusal(void) {
    FILE *errors = tmpfile();
    assert(errors != NULL && fflush(NULL) == 0);
    const pid_t child = fork();
    assert(child >= 0);
    if (child == 0) {
        alarm(ALARM_SECONDS);
        assert(dup2(fileno(errors), STDERR_FILENO) == STDERR_FILENO);
        int watch;
        const int writer = pipe_input(&watch);
        pthread_t holder;
        assert(pthread_create(&holder, NULL, hold_line_lock, NULL) == 0);
        send_text(writer, "par");
        until_taken(watch);
        int cancel[2];
        assert(pipe(cancel) == 0);
        bytes_list line = NULL;
        int64_t error = -1;
        (void)blorp_console_read_line_cancellable(&line, &error, cancel[0]);
        _exit(0);
    }
    int status = 0;
    assert(waitpid(child, &status, 0) == child);
    assert(WIFSIGNALED(status) && WTERMSIG(status) == SIGABRT);
    expect_file_text(fileno(errors), LOCK_REFUSAL);
    fclose(errors);
    blorp_list_drop_0_b(bytes_of("done", 4));
    return 0;
}

/* ---- the console's blocking jobs ---- */

/* On a fiber: submits `job`, parks, and checks that the job's completion ended the wait. */
static void run_job(struct blorp_fiber *self, struct blorp_blocking_job *job) {
    job->waiter = self;
    job->generation = blorp_wait_arm(self);
    blorp_blocking_submit(job);
    blorp_fiber_park(self);
    assert(blorp_wait_outcome(self, job->generation) == BLORP_BLOCKING_COMPLETED);
}

/* A job's bytes and its in-place native's are the same; drops both. */
static void expect_same_bytes(bytes_list from_job, bytes_list in_place) {
    assert(from_job->length == in_place->length);
    assert(memcmp(from_job->values, in_place->values, (size_t)in_place->length) == 0);
    blorp_list_drop_0_b(from_job);
    blorp_list_drop_0_b(in_place);
}

/* Each job, run once in place and then through the pool on the same input, with its kind.
 * Both output streams go to one file, in place first, so it holds every text twice. */
static void console_jobs(struct task *task) {
    struct blorp_fiber *const self = task->fiber;
    int64_t error = -1;
    bytes_list in_place = NULL;
    feed_text("line\n");
    const uint8_t line_result = blorp_console_read_line(&in_place, &error);
    feed_text("line\n");
    struct blorp_console_read_line_job read_line;
    blorp_console_read_line_job_init(&read_line);
    assert(read_line.job.kind == BLORP_JOB_CANCELLABLE);
    run_job(self, &read_line.job);
    assert(read_line.succeeded == line_result);
    expect_same_bytes(read_line.line, in_place);

    feed_text("abcdef");
    const uint8_t exact_result = blorp_console_read_exact(6, &in_place, &error);
    feed_text("abcdef");
    struct blorp_console_read_exact_job read_exact;
    blorp_console_read_exact_job_init(&read_exact, 6);
    assert(read_exact.job.kind == BLORP_JOB_CANCELLABLE);
    run_job(self, &read_exact.job);
    assert(read_exact.succeeded == exact_result);
    expect_same_bytes(read_exact.bytes, in_place);

    FILE *out = tmpfile();
    const int saved_error = dup(STDERR_FILENO);
    assert(out != NULL && saved_error >= 0);
    assert(dup2(fileno(out), STDOUT_FILENO) == STDOUT_FILENO);
    assert(dup2(fileno(out), STDERR_FILENO) == STDERR_FILENO);
    bytes_list data = bytes_of("bytes ", 6);
    struct blorp_string *text = blorp_string_from_bytes("text", 4);
    const uint8_t wrote = blorp_console_write(data, &error);
    struct blorp_console_write_job write_job;
    blorp_console_write_job_init(&write_job, data);
    assert(write_job.job.kind == BLORP_JOB_UNBOUNDED);
    run_job(self, &write_job.job);
    assert(write_job.succeeded == wrote);
    (void)blorp_string_print(text);
    struct blorp_string_print_job print;
    blorp_string_print_job_init(&print, text);
    assert(print.job.kind == BLORP_JOB_UNBOUNDED);
    run_job(self, &print.job);
    const uint8_t flushed = blorp_console_flush(&error);
    struct blorp_console_flush_job flush;
    blorp_console_flush_job_init(&flush);
    assert(flush.job.kind == BLORP_JOB_UNBOUNDED);
    run_job(self, &flush.job);
    assert(flush.succeeded == flushed);

    const uint8_t wrote_error = blorp_console_write_error(data, &error);
    struct blorp_console_write_job write_error;
    blorp_console_write_error_job_init(&write_error, data);
    assert(write_error.job.kind == BLORP_JOB_UNBOUNDED);
    run_job(self, &write_error.job);
    assert(write_error.succeeded == wrote_error);
    (void)blorp_string_print_error(text);
    struct blorp_string_print_job print_error;
    blorp_string_print_error_job_init(&print_error, text);
    assert(print_error.job.kind == BLORP_JOB_UNBOUNDED);
    run_job(self, &print_error.job);
    assert(dup2(saved_error, STDERR_FILENO) == STDERR_FILENO);
    close(saved_error);
    clearerr(stderr);
    expect_file_text(fileno(out), "bytes bytes text\ntext\nbytes bytes text\ntext\n");
    blorp_string_release(text);
    blorp_list_drop_0_b(data);
    fclose(out);
}
static int jobs_on_helpers(void) {
    blorp_blocking_start();
    use_carriers(1);
    spawn(0, console_jobs);
    run_carriers();
    return 0;
}

/* A read_line job waiting on a pipe holding "par" is signalled, ends its wait with the end
 * of input, and leaves "par" for the next reader. */
static struct blorp_console_read_line_job waiting_read;
static void wait_for_line(struct task *task) {
    blorp_console_read_line_job_init(&waiting_read);
    run_job(task->fiber, &waiting_read.job);
    assert(waiting_read.succeeded == BLORP_FS_SUCCEEDED && waiting_read.line->length == 0);
    blorp_list_drop_0_b(waiting_read.line);
}
static void *cancel_waiting_read(void *watch) {
    until_taken((int)(intptr_t)watch);
    assert(blorp_blocking_cancel(&waiting_read.job) == BLORP_CANCEL_SIGNALLED);
    return NULL;
}
static int job_cancel_reaches_read(void) {
    int watch;
    const int writer = pipe_input(&watch);
    send_text(writer, "par");
    blorp_blocking_start();
    use_carriers(1);
    spawn(0, wait_for_line);
    pthread_t canceller;
    assert(pthread_create(&canceller, NULL, cancel_waiting_read, (void *)(intptr_t)watch) == 0);
    run_carriers();
    assert(pthread_join(canceller, NULL) == 0);
    send_text(writer, "tial\n");
    alarm(ALARM_SECONDS);
    expect_line_text("partial\n");
    return 0;
}

int main(int argc, char **argv) {
    assert(argc == 3);
    blorp_memory_start();
    const char *name = argv[1];
    int failed = 1;
    if (strcmp(name, "line_lf") == 0) {
        failed = line_lf();
    } else if (strcmp(name, "line_crlf") == 0) {
        failed = line_crlf();
    } else if (strcmp(name, "line_empty") == 0) {
        failed = line_empty();
    } else if (strcmp(name, "line_last_without_lf") == 0) {
        failed = line_last_without_lf();
    } else if (strcmp(name, "line_end_of_input") == 0) {
        failed = line_end_of_input();
    } else if (strcmp(name, "line_lone_cr") == 0) {
        failed = line_lone_cr();
    } else if (strcmp(name, "line_raw_bytes") == 0) {
        failed = line_raw_bytes();
    } else if (strcmp(name, "read_directory") == 0) {
        failed = read_directory(argv[2]);
    } else if (strcmp(name, "exact_counts") == 0) {
        failed = exact_counts();
    } else if (strcmp(name, "exact_short") == 0) {
        failed = exact_short();
    } else if (strcmp(name, "exact_non_positive") == 0) {
        failed = exact_non_positive();
    } else if (strcmp(name, "exact_huge_count") == 0) {
        failed = exact_huge_count();
    } else if (strcmp(name, "exact_growth") == 0) {
        failed = exact_growth();
    } else if (strcmp(name, "exact_raw_bytes") == 0) {
        failed = exact_raw_bytes();
    } else if (strcmp(name, "shared_buffer") == 0) {
        failed = shared_buffer();
    } else if (strcmp(name, "input_after_end") == 0) {
        failed = input_after_end();
    } else if (strcmp(name, "closed_write") == 0) {
        failed = closed_write();
    } else if (strcmp(name, "closed_flush") == 0) {
        failed = closed_flush();
    } else if (strcmp(name, "closed_write_error") == 0) {
        failed = closed_write_error();
    } else if (strcmp(name, "closed_exit") == 0) {
        failed = closed_exit();
    } else if (strcmp(name, "closed_flush_exit") == 0) {
        failed = closed_exit_without_write(0);
    } else if (strcmp(name, "closed_read_exit") == 0) {
        failed = closed_exit_without_write(1);
    } else if (strcmp(name, "output_order") == 0) {
        failed = output_order();
    } else if (strcmp(name, "whole_lines") == 0) {
        failed = whole_lines();
    } else if (strcmp(name, "flush_before_read") == 0) {
        failed = flush_before_read();
    } else if (strcmp(name, "interrupted_read") == 0) {
        failed = interrupted_read();
    } else if (strcmp(name, "pending_rest") == 0) {
        failed = pending_rest();
    } else if (strcmp(name, "nonblocking_input") == 0) {
        failed = nonblocking_input();
    } else if (strcmp(name, "cancel_while_waiting") == 0) {
        failed = cancel_while_waiting();
    } else if (strcmp(name, "cancel_keeps_partial") == 0) {
        failed = cancel_keeps_partial();
    } else if (strcmp(name, "pending_line_beats_cancel") == 0) {
        failed = pending_line_beats_cancel();
    } else if (strcmp(name, "cancel_partial_grows") == 0) {
        failed = cancel_partial_grows();
    } else if (strcmp(name, "terminal_cancel") == 0) {
        failed = terminal_cancel();
    } else if (strcmp(name, "whole_reads") == 0) {
        failed = whole_reads();
    } else if (strcmp(name, "line_lock_refusal") == 0) {
        failed = line_lock_refusal();
    } else if (strcmp(name, "jobs_on_helpers") == 0) {
        failed = jobs_on_helpers();
    } else if (strcmp(name, "job_cancel_reaches_read") == 0) {
        failed = job_cancel_reaches_read();
    }
    return blorp_memory_finish(failed);
}
