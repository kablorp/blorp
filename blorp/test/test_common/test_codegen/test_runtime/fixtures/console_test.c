/* Native probe of the console natives, built with the unmodified production
 * fragments and the List[UInt8] layout a program that uses them emits. Each case
 * is one argument, after which comes a directory the case may use; a case that
 * passes returns 0 and prints nothing on standard output.
 *
 * A case supplies standard input by putting bytes in a file or pipe on
 * descriptor 0 before any read, and takes standard output (or error) to a file or
 * pipe on descriptor 1 (or 2). Each case is its own process, so stdio's buffers
 * start empty. A case that must see a process end forks it. */
#define _POSIX_C_SOURCE 200809L
#define _XOPEN_SOURCE 700
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
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <unistd.h>

#include "console_runtime.c"

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
    expect_closed_reader(blorp_console_write(data, &error), error);
    blorp_list_drop_0_b(data);
    return 0;
}

static int closed_flush(void) {
    close_reader(STDOUT_FILENO);
    bytes_list data = bytes_of("small", 5);
    int64_t error = -1;
    assert(blorp_console_write(data, &error) == BLORP_FS_SUCCEEDED);
    expect_closed_reader(blorp_console_flush(&error), error);
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
    } else if (strcmp(name, "flush_before_read") == 0) {
        failed = flush_before_read();
    } else if (strcmp(name, "interrupted_read") == 0) {
        failed = interrupted_read();
    }
    return blorp_memory_finish(failed);
}
