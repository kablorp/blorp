/* Native runtime-helper unit probe, built with unmodified production fragments. */
#define _POSIX_C_SOURCE 200809L
#include <unistd.h>

/* Only the startup-timeout probe stalls at the native exec boundary. */
static int stall_exec = 0;
static int exec_ready_writer = -1;
static int probe_execve(const char *path, char *const arguments[], char *const environment[]);
/* The group-race probe fails the parent's form of setpgid (another process's
 * pid) with the EPERM Darwin returns to the call that loses a race to create
 * the same group. */
static int lose_group_race = 0;
static int probe_setpgid(pid_t process, pid_t group);
/* The capture probes count forks, and writes that fail with EPIPE. */
static int fork_count = 0;
static int broken_writes = 0;
static pid_t probe_fork(void);
/* The exec-report race: another thread's fork can land between pipe() and the
 * FD_CLOEXEC fix-up and keep that pipe's write end open. The probe forks a stray
 * process right after the numbered pipe() call, which inherits every end open. */
enum { STRAY_LIFETIME_SECONDS = 4 };
static int pipes_until_stray = 0;
static pid_t stray = -1;
static int probe_pipe(int ends[2]);
static ssize_t probe_write(int descriptor, const void *bytes, size_t length);
#define execve probe_execve
#define setpgid probe_setpgid
#define fork probe_fork
#define pipe probe_pipe
#define write probe_write
#include "process_runtime.c"
#undef write
#undef pipe
#undef fork
#undef setpgid
#undef execve

static int probe_pipe(int ends[2]) {
    const int made = pipe(ends);
    if (made == 0 && pipes_until_stray > 0 && --pipes_until_stray == 0) {
        stray = fork();
        if (stray == 0) {
            sleep(STRAY_LIFETIME_SECONDS);
            _exit(0);
        }
    }
    return made;
}

static pid_t probe_fork(void) {
    fork_count++;
    return fork();
}

static ssize_t probe_write(int descriptor, const void *bytes, size_t length) {
    const ssize_t written = write(descriptor, bytes, length);
    if (written < 0 && errno == EPIPE) broken_writes++;
    return written;
}

static int probe_setpgid(pid_t process, pid_t group) {
    if (lose_group_race && process != 0) {
        errno = EPERM;
        return -1;
    }
    return setpgid(process, group);
}

static int probe_execve(const char *path, char *const arguments[], char *const environment[]) {
    if (stall_exec) {
        const unsigned char ready = 1;
        ssize_t written;
        do {
            written = write(exec_ready_writer, &ready, sizeof ready);
        } while (written < 0 && errno == EINTR);
        if (written != (ssize_t)sizeof ready) return -1;
        for (;;) pause();
    }
    return execve(path, arguments, environment);
}

static int closed_stdio(const char *program, const char *out, const char *err) {
    int saved[3];
    for (int index = 0; index < 3; index++) {
        saved[index] = fcntl(index, F_DUPFD_CLOEXEC, 3);
        if (saved[index] < 0) return 1;
    }
    struct blorp_string *program_value = blorp_string_from_bytes(program, (int64_t)strlen(program));
    struct blorp_string *output = blorp_string_from_bytes(out, (int64_t)strlen(out));
    struct blorp_string *errors = blorp_string_from_bytes(err, (int64_t)strlen(err));
    struct blorp_string *exit_argument = blorp_string_from_bytes("exit", 4);
    struct blorp_l_0_s *arguments = blorp_list_repeat_0_s(exit_argument, 2);
    blorp_string_release(exit_argument);
    blorp_string_release(arguments->values[1]);
    arguments->values[1] = blorp_string_from_bytes("0", 1);
    for (int index = 0; index < 3; index++) {
        if (close(index) != 0) return 1;
    }
    int64_t code = 0;
    struct blorp_string *error = NULL;
    const uint8_t succeeded = blorp_process_run_to_files(program_value, arguments, output, errors,
                                                       INT64_C(10000), &code, &error);
    for (int index = 0; index < 3; index++) {
        if (dup2(saved[index], index) < 0 || close(saved[index]) != 0) return 1;
    }
    blorp_list_drop_0_s(arguments);
    blorp_string_release(program_value);
    blorp_string_release(output);
    blorp_string_release(errors);
    if (error != NULL) blorp_string_release(error);
    return succeeded && code == 0 ? 0 : 1;
}

static int unsupported_sigchld(const char *program, const char *out, const char *err) {
    struct sigaction original, changed;
    memset(&changed, 0, sizeof changed);
    changed.sa_handler = SIG_IGN;
    if (sigemptyset(&changed.sa_mask) != 0 || sigaction(SIGCHLD, &changed, &original) != 0) return 1;
    struct blorp_string *program_value = blorp_string_from_bytes(program, (int64_t)strlen(program));
    struct blorp_string *output = blorp_string_from_bytes(out, (int64_t)strlen(out));
    struct blorp_string *errors = blorp_string_from_bytes(err, (int64_t)strlen(err));
    struct blorp_string *argument = blorp_string_from_bytes("exit", 4);
    struct blorp_l_0_s *arguments = blorp_list_repeat_0_s(argument, 0);
    blorp_string_release(argument);
    int64_t code = 0;
    struct blorp_string *error = NULL;
    const uint8_t succeeded = blorp_process_run_to_files(program_value, arguments, output, errors,
                                                       INT64_C(10000), &code, &error);
    const int rejected = !succeeded && error != NULL &&
        strcmp(error->bytes, "process.run_to_files: requires default SIGCHLD") == 0;
    if (sigaction(SIGCHLD, &original, NULL) != 0) return 1;
    if (error != NULL) blorp_string_release(error);
    /* Reusing both paths proves unsupported disposition was rejected before file creation. */
    error = NULL;
    const uint8_t after = blorp_process_run_to_files(program_value, arguments, output, errors,
                                                  INT64_C(10000), &code, &error);
    blorp_list_drop_0_s(arguments);
    blorp_string_release(program_value);
    blorp_string_release(output);
    blorp_string_release(errors);
    if (error != NULL) blorp_string_release(error);
    return rejected && after ? 0 : 1;
}

/* Probe the production helper's ownership boundary: no direct zombie remains. */
static int direct_reaping(const char *program, const char *out, const char *err,
                          const char *mode) {
    struct blorp_string *program_value = blorp_string_from_bytes(program, (int64_t)strlen(program));
    struct blorp_string *output = blorp_string_from_bytes(out, (int64_t)strlen(out));
    struct blorp_string *errors = blorp_string_from_bytes(err, (int64_t)strlen(err));
    const char *operation = strcmp(mode, "reap-exit") == 0 ? "exit" :
                            strcmp(mode, "reap-signal") == 0 ? "signal" : "pause";
    struct blorp_string *argument = blorp_string_from_bytes(operation, (int64_t)strlen(operation));
    const int normal = strcmp(mode, "reap-exit") == 0;
    struct blorp_l_0_s *arguments = blorp_list_repeat_0_s(argument, normal ? 2 : 1);
    blorp_string_release(argument);
    if (normal) {
        blorp_string_release(arguments->values[1]);
        arguments->values[1] = blorp_string_from_bytes("0", 1);
    }
    int64_t code = 0;
    struct blorp_string *error = NULL;
    const int startup = strcmp(mode, "reap-startup") == 0;
    int ready[2] = {-1, -1};
    if (startup) {
        if (pipe(ready) != 0 || fcntl(ready[0], F_SETFL, O_NONBLOCK) != 0) return 1;
        exec_ready_writer = ready[1];
        stall_exec = 1;
    }
    const int64_t timeout_ms = startup || strcmp(mode, "reap-timeout") == 0 ?
        INT64_C(1000) : INT64_C(10000);
    const uint8_t succeeded = blorp_process_run_to_files(program_value, arguments, output, errors,
                                                       timeout_ms, &code, &error);
    int acknowledged = 1;
    if (startup) {
        stall_exec = 0;
        exec_ready_writer = -1;
        unsigned char byte = 0;
        acknowledged = read(ready[0], &byte, sizeof byte) == (ssize_t)sizeof byte && byte == 1;
        if (close(ready[0]) != 0) acknowledged = 0;
        if (close(ready[1]) != 0) acknowledged = 0;
    }
    int status = 0;
    errno = 0;
    const pid_t remaining = waitpid(-1, &status, WNOHANG);
    const int no_child = remaining == -1 && errno == ECHILD;
    const char *expected = strcmp(mode, "reap-signal") == 0 ?
        "process.run_to_files: child terminated by signal" : "process.run_to_files: timed out";
    const int correct = normal ? succeeded && code == 0 :
        !succeeded && error != NULL && strcmp(error->bytes, expected) == 0;
    blorp_list_drop_0_s(arguments);
    blorp_string_release(program_value);
    blorp_string_release(output);
    blorp_string_release(errors);
    if (error != NULL) blorp_string_release(error);
    return correct && no_child && acknowledged ? 0 : 1;
}

/* A lost group race leaves the spawn intact, and the child leads its own group. */
static int group_race(const char *program, const char *out, const char *err) {
    struct blorp_string *program_value = blorp_string_from_bytes(program, (int64_t)strlen(program));
    struct blorp_string *output = blorp_string_from_bytes(out, (int64_t)strlen(out));
    struct blorp_string *errors = blorp_string_from_bytes(err, (int64_t)strlen(err));
    struct blorp_string *argument = blorp_string_from_bytes("group-leader", 12);
    struct blorp_l_0_s *arguments = blorp_list_repeat_0_s(argument, 1);
    blorp_string_release(argument);
    int64_t code = 0;
    struct blorp_string *error = NULL;
    lose_group_race = 1;
    const uint8_t succeeded = blorp_process_run_to_files(program_value, arguments, output, errors,
                                                       INT64_C(10000), &code, &error);
    lose_group_race = 0;
    blorp_list_drop_0_s(arguments);
    blorp_string_release(program_value);
    blorp_string_release(output);
    blorp_string_release(errors);
    if (error != NULL) blorp_string_release(error);
    return succeeded && code == 0 ? 0 : 1;
}

/* A List[String] of owned copies, as the emitter passes one. */
static struct blorp_l_0_s *strings(int count, const char *const items[]) {
    struct blorp_string *empty = blorp_string_from_bytes("", 0);
    struct blorp_l_0_s *list = blorp_list_repeat_0_s(empty, count);
    blorp_string_release(empty);
    for (int index = 0; index < count; index++) {
        blorp_string_release(list->values[index]);
        list->values[index] = blorp_string_from_bytes(items[index], (int64_t)strlen(items[index]));
    }
    return list;
}

/* Runs capture with no directory or environment change. On success `exit` is the
 * reply's Exit code; on failure `error` is the error code. */
static uint8_t run_capture(const char *program, int count, const char *const arguments[],
                           const char *input, size_t input_length, int64_t timeout_ms,
                           int64_t *exit, int64_t *error) {
    struct blorp_string *program_value = blorp_string_from_bytes(program, (int64_t)strlen(program));
    struct blorp_l_0_s *argument_list = strings(count, arguments);
    struct blorp_l_0_s *none = strings(0, NULL);
    struct blorp_string *text = blorp_string_from_bytes(input == NULL ? "" : input,
                                                        (int64_t)input_length);
    struct blorp_l_0_s *stdin_list = blorp_list_repeat_0_s(text, input == NULL ? 0 : 1);
    blorp_string_release(text);
    struct blorp_l_0_s *reply = NULL;
    const uint8_t succeeded = blorp_process_capture(program_value, argument_list, none, none,
                                                    stdin_list, timeout_ms, &reply, error);
    if (succeeded) {
        *exit = strtoll(reply->values[0]->bytes, NULL, 10);
        blorp_list_drop_0_s(reply);
    }
    blorp_list_drop_0_s(stdin_list);
    blorp_list_drop_0_s(none);
    blorp_list_drop_0_s(argument_list);
    blorp_string_release(program_value);
    return succeeded;
}

enum { LARGE_INPUT = 1 << 20 };

/* SIGCHLD keeps its disposition, the mask is restored, and the SIGPIPE our write
 * raised is consumed, while one already pending is left for the program. */
static int capture_signals(const char *program) {
    struct sigaction before_child, after_child;
    sigset_t before_mask, after_mask, pending, pipe_only;
    if (sigaction(SIGCHLD, NULL, &before_child) != 0 ||
        pthread_sigmask(SIG_BLOCK, NULL, &before_mask) != 0) return 1;
    char *input = malloc(LARGE_INPUT);
    if (input == NULL) return 1;
    memset(input, 'x', LARGE_INPUT);
    const char *const arguments[] = {"close-stdin"};
    int64_t exit = -1, error = 0;
    const uint8_t succeeded = run_capture(program, 1, arguments, input, LARGE_INPUT,
                                          INT64_C(10000), &exit, &error);
    if (sigaction(SIGCHLD, NULL, &after_child) != 0 ||
        pthread_sigmask(SIG_BLOCK, NULL, &after_mask) != 0 || sigpending(&pending) != 0) return 1;
    const int restored = after_child.sa_handler == before_child.sa_handler &&
        after_child.sa_flags == before_child.sa_flags &&
        sigismember(&after_mask, SIGPIPE) == sigismember(&before_mask, SIGPIPE) &&
        sigismember(&pending, SIGPIPE) == 0;
    const int first = succeeded && exit == 0 && restored && broken_writes > 0;
    /* A SIGPIPE pending before the call, under a mask that blocks it, stays pending. */
    if (sigemptyset(&pipe_only) != 0 || sigaddset(&pipe_only, SIGPIPE) != 0 ||
        pthread_sigmask(SIG_BLOCK, &pipe_only, NULL) != 0 || raise(SIGPIPE) != 0) return 1;
    broken_writes = 0;
    const uint8_t again = run_capture(program, 1, arguments, input, LARGE_INPUT,
                                      INT64_C(10000), &exit, &error);
    free(input);
    if (sigpending(&pending) != 0) return 1;
    const int kept = again && exit == 0 && broken_writes > 0 && sigismember(&pending, SIGPIPE) == 1;
    int taken = 0;
    if (kept && sigwait(&pipe_only, &taken) != 0) return 1;
    if (pthread_sigmask(SIG_SETMASK, &before_mask, NULL) != 0) return 1;
    return first && kept ? 0 : 1;
}

/* SIGCHLD ignored is LaunchFailed(OtherOs(ECHILD)), decided before forking. */
static int capture_sigchld(const char *program) {
    struct sigaction original, changed;
    memset(&changed, 0, sizeof changed);
    changed.sa_handler = SIG_IGN;
    if (sigemptyset(&changed.sa_mask) != 0 || sigaction(SIGCHLD, &changed, &original) != 0) return 1;
    const char *const arguments[] = {"exit", "0"};
    int64_t exit = -1, error = 0;
    const int forks = fork_count;
    const uint8_t succeeded = run_capture(program, 2, arguments, NULL, 0, INT64_C(10000), &exit, &error);
    if (sigaction(SIGCHLD, &original, NULL) != 0) return 1;
    const int64_t expected = blorp_process_error(blorp_fs_errno_code(ECHILD), BLORP_PROCESS_LAUNCH_FAILED);
    return !succeeded && error == expected && fork_count == forks ? 0 : 1;
}

/* No child remains after an exit or a timeout, and a zero timeout never forks. */
static int capture_reap(const char *program) {
    const char *const pause_arguments[] = {"pause"};
    const char *const exit_arguments[] = {"exit", "0"};
    int64_t exit = -1, error = 0;
    const uint8_t timed = run_capture(program, 1, pause_arguments, NULL, 0, INT64_C(200), &exit, &error);
    const int timed_out = timed && exit == BLORP_PROCESS_TIMED_OUT * BLORP_PROCESS_EXIT_SPAN;
    errno = 0;
    int status = 0;
    const int none_after_timeout = waitpid(-1, &status, WNOHANG) == -1 && errno == ECHILD;
    const uint8_t ended = run_capture(program, 2, exit_arguments, NULL, 0, INT64_C(10000), &exit, &error);
    errno = 0;
    const int none_after_exit = waitpid(-1, &status, WNOHANG) == -1 && errno == ECHILD;
    const int forks = fork_count;
    const uint8_t at_once = run_capture(program, 2, exit_arguments, NULL, 0, INT64_C(0), &exit, &error);
    const int unstarted = at_once && exit == BLORP_PROCESS_TIMED_OUT * BLORP_PROCESS_EXIT_SPAN &&
        fork_count == forks;
    return timed_out && none_after_timeout && ended && exit != -1 && none_after_exit && unstarted ? 0 : 1;
}

/* A stray process holds the exec report's write end open for STRAY_LIFETIME_SECONDS. The
 * timeout is the bound: capture must return once its own child has exited, long before
 * the stray does, and with the child's own outcome. */
static int capture_stray_report_holder(const char *program) {
    const char *const arguments[] = {"exit", "0"};
    int64_t exit = -1, error = 0;
    /* capture opens the stdout, stderr and report pipes, in that order. */
    pipes_until_stray = 3;
    struct timespec started, ended;
    if (clock_gettime(CLOCK_MONOTONIC, &started) != 0) return 1;
    const uint8_t succeeded = run_capture(program, 2, arguments, NULL, 0, INT64_C(10000), &exit, &error);
    if (clock_gettime(CLOCK_MONOTONIC, &ended) != 0) return 1;
    pipes_until_stray = 0;
    int status = 0;
    if (stray > 0 && (kill(stray, SIGKILL) != 0 || waitpid(stray, &status, 0) != stray)) return 1;
    const long elapsed_ms = (long)(ended.tv_sec - started.tv_sec) * 1000 +
                            (long)((ended.tv_nsec - started.tv_nsec) / 1000000);
    return succeeded && exit == BLORP_PROCESS_EXITED * BLORP_PROCESS_EXIT_SPAN &&
           elapsed_ms < STRAY_LIFETIME_SECONDS * 1000 / 2 ? 0 : 1;
}

/* find_program on a PATH of an empty entry, a relative one, a non-executable file,
 * a directory and then the real one, each with a "tool", finds only the last. */
static int find_program_case(const char *directory) {
    char path[4096];
    if (mkdir(directory, S_IRWXU) != 0 || chdir(directory) != 0) return 1;
    static const char *const directories[] = {"relative", "plain", "folder", "folder/tool", "real"};
    for (size_t index = 0; index < sizeof directories / sizeof *directories; index++) {
        if (mkdir(directories[index], S_IRWXU) != 0) return 1;
    }
    static const char *const files[] = {"tool", "relative/tool", "plain/tool", "real/tool"};
    static const mode_t modes[] = {S_IRWXU, S_IRWXU, S_IRUSR | S_IWUSR, S_IRWXU};
    for (size_t index = 0; index < sizeof files / sizeof *files; index++) {
        const int file = open(files[index], O_WRONLY | O_CREAT | O_EXCL, modes[index]);
        if (file < 0 || close(file) != 0) return 1;
    }
    char current[2048];
    if (getcwd(current, sizeof current) == NULL) return 1;
    const int written = snprintf(path, sizeof path, ":relative:%s/plain:%s/folder:%s/real", current,
                                 current, current);
    if (written < 0 || (size_t)written >= sizeof path || setenv("PATH", path, 1) != 0) return 1;
    struct blorp_string *name = blorp_string_from_bytes("tool", 4);
    struct blorp_string *found = NULL;
    int64_t error = 0;
    const uint8_t located = blorp_process_find_program(name, &found, &error);
    char expected[2100];
    (void)snprintf(expected, sizeof expected, "%s/real/tool", current);
    const int correct = located && strcmp(found->bytes, expected) == 0;
    if (found != NULL) blorp_string_release(found);
    /* With only the empty and relative entries, the tool in both is not found. */
    if (setenv("PATH", ":relative", 1) != 0) return 1;
    found = NULL;
    const uint8_t relative = blorp_process_find_program(name, &found, &error);
    const int skipped = !relative && error == blorp_process_error(0, BLORP_PROCESS_NOT_ON_PATH);
    if (found != NULL) blorp_string_release(found);
    blorp_string_release(name);
    return correct && skipped ? 0 : 1;
}

static int child_case(int argc, char **argv) {
    if (argc < 2) return 0;
    if (strcmp(argv[1], "exit") == 0 && argc == 3) return (int)strtol(argv[2], NULL, 10);
    if (strcmp(argv[1], "argv") == 0) {
        if (argc != 6 || strcmp(argv[2], "") != 0 || strcmp(argv[3], "two words") != 0 ||
            strcmp(argv[4], "literal*$;'") != 0 || strcmp(argv[5], "caf\303\251") != 0) return 1;
        return 0;
    }
    if (strcmp(argv[1], "streams") == 0) {
        fputs("stdout text\n", stdout);
        fputs("stderr text\n", stderr);
        return 0;
    }
    if (strcmp(argv[1], "pause") == 0) { for (;;) pause(); }
    if (strcmp(argv[1], "group-leader") == 0) return getpgrp() == getpid() ? 0 : 1;
    if (strcmp(argv[1], "stdin") == 0) return getchar() == EOF ? 0 : 1;
    if (strcmp(argv[1], "signal") == 0) {
        if (raise(SIGTERM) != 0) return 1;
        return 1;
    }
    if (strcmp(argv[1], "wait") == 0 && argc == 3) {
        const int ready = open(argv[2], O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR);
        if (ready < 0 || write(ready, "ready\n", 6) != 6 || close(ready) != 0) return 1;
        for (;;) pause();
    }
    if (strcmp(argv[1], "invalid-executable") == 0 && argc == 3) {
        const int output = open(argv[2], O_WRONLY | O_CREAT | O_EXCL, S_IRWXU);
        if (output < 0 || write(output, "invalid\n", 8) != 8 || close(output) != 0) return 1;
        return 0;
    }
    /* The grandchild inherits stdout and stderr, records its pid, signals readiness
     * through a pipe, and waits forever; the child exits once it is ready. */
    if (strcmp(argv[1], "grandchild") == 0 && argc == 3) {
        int ready[2];
        if (pipe(ready) != 0) return 1;
        const pid_t grandchild = fork();
        if (grandchild < 0) return 1;
        if (grandchild == 0) {
            FILE *record = fopen(argv[2], "wx");
            if (record == NULL || fprintf(record, "%ld", (long)getpid()) < 0 || fclose(record) != 0) _exit(1);
            if (write(ready[1], "r", 1) != 1) _exit(1);
            for (;;) pause();
        }
        char byte;
        if (close(ready[1]) != 0 || read(ready[0], &byte, 1) != 1) return 1;
        fputs("parent done\n", stdout);
        return 0;
    }
    /* Whether the process has ended within five seconds, polling every 10 ms. A killed
     * grandchild is reaped by whichever process adopted it; a container's first process
     * may never reap it, so on Linux a zombie, state Z in /proc, has ended too. */
    if (strcmp(argv[1], "gone") == 0 && argc == 3) {
        const pid_t process = (pid_t)strtol(argv[2], NULL, 10);
        const struct timespec interval = {0, 10000000};
        char status_path[64];
        (void)snprintf(status_path, sizeof status_path, "/proc/%ld/stat", (long)process);
        for (int attempt = 0; attempt < 500; attempt++) {
            if (kill(process, 0) != 0 && errno == ESRCH) return 0;
            FILE *status = fopen(status_path, "r");
            if (status != NULL) {
                char line[512];
                const char *closing = fgets(line, sizeof line, status) ? strrchr(line, ')') : NULL;
                (void)fclose(status);
                if (closing != NULL && (closing[1] == ' ') && (closing[2] == 'Z' || closing[2] == 'X')) return 0;
            }
            (void)nanosleep(&interval, NULL);
        }
        return 1;
    }
    if (strcmp(argv[1], "echo-stdin") == 0) {
        int character;
        while ((character = getchar()) != EOF) {
            if (putchar(character) == EOF) return 1;
        }
        return 0;
    }
    if (strcmp(argv[1], "close-stdin") == 0) {
        const struct timespec pause_time = {0, 100000000};
        return close(STDIN_FILENO) == 0 && nanosleep(&pause_time, NULL) == 0 ? 0 : 1;
    }
    if (strcmp(argv[1], "cat-file") == 0 && argc == 3) {
        FILE *file = fopen(argv[2], "r");
        if (file == NULL) return 1;
        int character;
        while ((character = fgetc(file)) != EOF) putchar(character);
        return fclose(file) == 0 ? 0 : 1;
    }
    /* "é" is C3 A9 and "€" is E2 82 AC: each stream ends inside a character. */
    if (strcmp(argv[1], "partial") == 0 && argc == 3) {
        if (write(STDOUT_FILENO, "ok\303", 3) != 3 || write(STDERR_FILENO, "er\342\202", 4) != 4) return 1;
        const int ready = open(argv[2], O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR);
        if (ready < 0 || write(ready, "ready\n", 6) != 6 || close(ready) != 0) return 1;
        for (;;) pause();
    }
    if (strcmp(argv[1], "partial-signal") == 0) {
        if (write(STDOUT_FILENO, "ok\303", 3) != 3) return 1;
        raise(SIGTERM);
        return 1;
    }
    if (strcmp(argv[1], "cut-off-exit") == 0 && argc == 3) {
        if (write(STDOUT_FILENO, "ok\303", 3) != 3) return 1;
        return (int)strtol(argv[2], NULL, 10);
    }
    if (strcmp(argv[1], "invalid-stderr") == 0 && argc == 3) {
        if (write(STDERR_FILENO, "\377", 1) != 1) return 1;
        return (int)strtol(argv[2], NULL, 10);
    }
    if (strcmp(argv[1], "fail-streams") == 0) {
        fputs("out\n", stdout);
        fputs("err\n", stderr);
        return 7;
    }
    /* Each forces a reply the library cannot decode; the runtime aborts with the defect. */
    if (strcmp(argv[1], "bad-error-code") == 0) return (int)blorp_process_error(0, BLORP_PROCESS_NOT_ON_PATH + 2);
    if (strcmp(argv[1], "bad-exit") == 0) return (int)blorp_process_exit(BLORP_PROCESS_TIMED_OUT + 1, 0);
    if (strcmp(argv[1], "fault") == 0) {
        struct blorp_string *message = blorp_string_from_bytes("forced by the probe", 19);
        int64_t error = 0;
        return blorp_process_fault(message, &error);
    }
    if (strcmp(argv[1], "capture-signals") == 0 && argc == 5) return capture_signals(argv[2]);
    if (strcmp(argv[1], "capture-sigchld") == 0 && argc == 5) return capture_sigchld(argv[2]);
    if (strcmp(argv[1], "capture-reap") == 0 && argc == 5) return capture_reap(argv[2]);
    if (strcmp(argv[1], "capture-stray-report") == 0 && argc == 5)
        return capture_stray_report_holder(argv[2]);
    if (strcmp(argv[1], "find-program") == 0 && argc == 5) return find_program_case(argv[3]);
    if (strcmp(argv[1], "fifo") == 0 && argc == 3) return mkfifo(argv[2], S_IRUSR | S_IWUSR) == 0 ? 0 : 1;
    if (strcmp(argv[1], "symlink") == 0 && argc == 4) return symlink(argv[2], argv[3]) == 0 ? 0 : 1;
    if (strcmp(argv[1], "closedstdio") == 0 && argc == 5) return closed_stdio(argv[2], argv[3], argv[4]);
    if (argc == 5 && (strcmp(argv[1], "reap-exit") == 0 || strcmp(argv[1], "reap-signal") == 0 ||
                      strcmp(argv[1], "reap-timeout") == 0 || strcmp(argv[1], "reap-startup") == 0))
        return direct_reaping(argv[2], argv[3], argv[4], argv[1]);
    if (strcmp(argv[1], "group-race") == 0 && argc == 5) return group_race(argv[2], argv[3], argv[4]);
    if (strcmp(argv[1], "sigchld") == 0 && argc == 5) return unsupported_sigchld(argv[2], argv[3], argv[4]);
    return 1;
}

int main(int argc, char **argv) {
    blorp_memory_start();
    return blorp_memory_finish(child_case(argc, argv));
}
