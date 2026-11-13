/* Native runtime-helper unit probe, built with unmodified production fragments. */
#define _POSIX_C_SOURCE 200809L
/* The pty probe needs posix_openpt and TIOCSCTTY, which glibc declares only under these;
 * PROCESS_POSIX_PRELUDE sets them too, but after the headers below have fixed the macros. */
#define _XOPEN_SOURCE 700
#define _DEFAULT_SOURCE
#if defined(__APPLE__)
#define _DARWIN_C_SOURCE
#endif
#include <unistd.h>

/* Only the startup-timeout probe stalls at the native exec boundary. */
static int stall_exec = 0;
static int exec_ready_writer = -1;
static int probe_execve(const char *path, char *const arguments[], char *const environment[]);
/* The run probes set this to how SIGINT and SIGQUIT must stand when the child execs, 0 for the
 * default and 1 for ignored, which is the state a handler of the caller's must not reach. */
static int interrupts_at_exec = -1;
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
#include <sys/ioctl.h>
#include <sys/resource.h>

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

static int fork_failure = 0;

static pid_t probe_fork(void) {
    fork_count++;
    if (fork_failure != 0) {
        errno = fork_failure;
        return -1;
    }
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
    if (interrupts_at_exec >= 0) {
        const int numbers[] = {SIGINT, SIGQUIT};
        for (size_t index = 0; index < 2; index++) {
            struct sigaction action;
            if (sigaction(numbers[index], NULL, &action) != 0 ||
                action.sa_handler != (interrupts_at_exec == 1 ? SIG_IGN : SIG_DFL)) {
                errno = EPERM;
                return -1;
            }
        }
    }
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

enum { LARGE_INPUT = 1 << 20, INTERRUPT_WAIT_SECONDS = 5 };

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
    const int64_t expected = blorp_process_error(-(int64_t)ECHILD, BLORP_PROCESS_LAUNCH_FAILED);
    return !succeeded && error == expected && fork_count == forks ? 0 : 1;
}

/* A failed fork is LaunchFailed. SystemCallError names PermissionDenied (code 2) but not NoSpace,
 * so ENOSPC arrives as the OS's own number and EACCES as the named kind. */
static int capture_fork_failure(const char *program) {
    const char *const arguments[] = {"exit", "0"};
    int64_t exit = -1, error = 0;
    fork_failure = ENOSPC;
    const uint8_t unnamed = run_capture(program, 2, arguments, NULL, 0, INT64_C(10000), &exit, &error);
    const int unnamed_ok = !unnamed && error == blorp_process_error(-(int64_t)ENOSPC, BLORP_PROCESS_LAUNCH_FAILED);
    fork_failure = EACCES;
    const uint8_t named = run_capture(program, 2, arguments, NULL, 0, INT64_C(10000), &exit, &error);
    const int named_ok = !named && error == blorp_process_error(2, BLORP_PROCESS_LAUNCH_FAILED);
    fork_failure = 0;
    return unnamed_ok && named_ok ? 0 : 1;
}

/* Whether no child of this process remains, reaped or not. */
static int no_child(void) {
    int status = 0;
    errno = 0;
    return waitpid(-1, &status, WNOHANG) == -1 && errno == ECHILD;
}

/* No child remains after a timeout, an exit or a signal, and a zero timeout never forks. */
static int capture_reap(const char *program) {
    const char *const pause_arguments[] = {"pause"};
    const char *const exit_arguments[] = {"exit", "0"};
    const char *const signal_arguments[] = {"signal"};
    int64_t exit = -1, error = 0;
    const uint8_t timed = run_capture(program, 1, pause_arguments, NULL, 0, INT64_C(200), &exit, &error);
    const int timed_out = timed && exit == BLORP_PROCESS_TIMED_OUT * BLORP_PROCESS_EXIT_SPAN &&
        no_child();
    const uint8_t ended = run_capture(program, 2, exit_arguments, NULL, 0, INT64_C(10000), &exit, &error);
    const int exited = ended && exit == BLORP_PROCESS_EXITED * BLORP_PROCESS_EXIT_SPAN && no_child();
    const uint8_t killed = run_capture(program, 1, signal_arguments, NULL, 0, INT64_C(10000), &exit,
                                       &error);
    const int signaled = killed && exit == BLORP_PROCESS_SIGNALED * BLORP_PROCESS_EXIT_SPAN + SIGTERM &&
        no_child();
    const int forks = fork_count;
    const uint8_t at_once = run_capture(program, 2, exit_arguments, NULL, 0, INT64_C(0), &exit, &error);
    const int unstarted = at_once && exit == BLORP_PROCESS_TIMED_OUT * BLORP_PROCESS_EXIT_SPAN &&
        fork_count == forks;
    return timed_out && exited && signaled && unstarted ? 0 : 1;
}

/* A child stalled before exec has neither exec'd nor written its report: the deadline
 * covers startup, so the call times out and the child is killed and reaped. The stall
 * writes one byte first, so the probe knows the child reached exec. */
static int capture_startup(const char *program) {
    int ready[2] = {-1, -1};
    if (pipe(ready) != 0 || fcntl(ready[0], F_SETFL, O_NONBLOCK) != 0) return 1;
    exec_ready_writer = ready[1];
    stall_exec = 1;
    const char *const arguments[] = {"exit", "0"};
    int64_t exit = -1, error = 0;
    const uint8_t succeeded = run_capture(program, 2, arguments, NULL, 0, INT64_C(1000), &exit, &error);
    stall_exec = 0;
    exec_ready_writer = -1;
    unsigned char byte = 0;
    const int acknowledged = read(ready[0], &byte, sizeof byte) == (ssize_t)sizeof byte && byte == 1;
    if (close(ready[0]) != 0 || close(ready[1]) != 0) return 1;
    return succeeded && exit == BLORP_PROCESS_TIMED_OUT * BLORP_PROCESS_EXIT_SPAN && acknowledged &&
        no_child() ? 0 : 1;
}

/* With stdin, stdout and stderr closed, each descriptor capture opens would take one of
 * their numbers; it moves them above stderr, so the child's streams stay its own. */
static int capture_closed_stdio(const char *program) {
    int saved[3];
    for (int index = 0; index < 3; index++) {
        saved[index] = fcntl(index, F_DUPFD_CLOEXEC, 3);
        if (saved[index] < 0) return 1;
    }
    for (int index = 0; index < 3; index++) {
        if (close(index) != 0) return 1;
    }
    const char *const arguments[] = {"streams"};
    struct blorp_string *program_value = blorp_string_from_bytes(program, (int64_t)strlen(program));
    struct blorp_l_0_s *argument_list = strings(1, arguments);
    struct blorp_l_0_s *none = strings(0, NULL);
    struct blorp_l_0_s *reply = NULL;
    int64_t error = 0;
    const uint8_t succeeded = blorp_process_capture(program_value, argument_list, none, none, none,
                                                    INT64_C(10000), &reply, &error);
    for (int index = 0; index < 3; index++) {
        if (dup2(saved[index], index) < 0 || close(saved[index]) != 0) return 1;
    }
    /* The child inherits this probe's strict leak check, whose report follows its stderr. */
    const int correct = succeeded && strcmp(reply->values[0]->bytes, "0") == 0 &&
        strcmp(reply->values[1]->bytes, "stdout caf\303\251\n") == 0 &&
        strncmp(reply->values[2]->bytes, "stderr caf\303\251\n", strlen("stderr caf\303\251\n")) == 0;
    if (succeeded) blorp_list_drop_0_s(reply);
    blorp_list_drop_0_s(none);
    blorp_list_drop_0_s(argument_list);
    blorp_string_release(program_value);
    return correct ? 0 : 1;
}

/* A lost group race leaves the launch intact: only the child creates its group. */
static int capture_group_race(const char *program) {
    const char *const arguments[] = {"group-leader"};
    int64_t exit = -1, error = 0;
    lose_group_race = 1;
    const uint8_t succeeded = run_capture(program, 1, arguments, NULL, 0, INT64_C(10000), &exit, &error);
    lose_group_race = 0;
    return succeeded && exit == BLORP_PROCESS_EXITED * BLORP_PROCESS_EXIT_SPAN ? 0 : 1;
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
 * a directory and then the real one, each with a "tool", finds only the last.
 * The real one's name is not ASCII, so the found path counts its code points. */
static int find_program_case(const char *directory) {
    char path[4096];
    if (mkdir(directory, S_IRWXU) != 0 || chdir(directory) != 0) return 1;
    static const char *const directories[] = {"relative", "plain", "folder", "folder/tool", "r\303\251al"};
    for (size_t index = 0; index < sizeof directories / sizeof *directories; index++) {
        if (mkdir(directories[index], S_IRWXU) != 0) return 1;
    }
    static const char *const files[] = {"tool", "relative/tool", "plain/tool", "r\303\251al/tool"};
    static const mode_t modes[] = {S_IRWXU, S_IRWXU, S_IRUSR | S_IWUSR, S_IRWXU};
    for (size_t index = 0; index < sizeof files / sizeof *files; index++) {
        const int file = open(files[index], O_WRONLY | O_CREAT | O_EXCL, modes[index]);
        if (file < 0 || close(file) != 0) return 1;
    }
    char current[2048];
    if (getcwd(current, sizeof current) == NULL) return 1;
    const int written = snprintf(path, sizeof path, ":relative:%s/plain:%s/folder:%s/r\303\251al", current,
                                 current, current);
    if (written < 0 || (size_t)written >= sizeof path || setenv("PATH", path, 1) != 0) return 1;
    struct blorp_string *name = blorp_string_from_bytes("tool", 4);
    struct blorp_string *found = NULL;
    int64_t error = 0;
    const uint8_t located = blorp_process_find_program(name, &found, &error);
    char expected[2100];
    (void)snprintf(expected, sizeof expected, "%s/r\303\251al/tool", current);
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

/* run, with the environment that keeps the child's own leak report out of this probe's stderr. */
static uint8_t run_program(const char *program, int count, const char *const arguments[],
                           int64_t *ended, int64_t *error) {
    static const char *const removed[] = {"BLORP_LEAK_CHECK", "BLORP_MEMORY_STATS"};
    struct blorp_string *program_value = blorp_string_from_bytes(program, (int64_t)strlen(program));
    struct blorp_l_0_s *argument_list = strings(count, arguments);
    struct blorp_l_0_s *none = strings(0, NULL);
    struct blorp_l_0_s *environment = strings(2, removed);
    const uint8_t succeeded = blorp_process_run(program_value, argument_list, none, environment,
                                                ended, error);
    blorp_list_drop_0_s(environment);
    blorp_list_drop_0_s(none);
    blorp_list_drop_0_s(argument_list);
    blorp_string_release(program_value);
    return succeeded;
}

#define RUN_EXITED(status) ((int64_t)BLORP_PROCESS_EXITED * BLORP_PROCESS_EXIT_SPAN + (status))
#define RUN_SIGNALED(signal) ((int64_t)BLORP_PROCESS_SIGNALED * BLORP_PROCESS_EXIT_SPAN + (signal))

enum { DISPOSITION_DEFAULT = 0, DISPOSITION_IGNORED = 1, DISPOSITION_OTHER = 2 };

static int disposition_of(int signal_number) {
    struct sigaction action;
    if (sigaction(signal_number, NULL, &action) != 0) return DISPOSITION_OTHER;
    if (action.sa_handler == SIG_DFL) return DISPOSITION_DEFAULT;
    return action.sa_handler == SIG_IGN ? DISPOSITION_IGNORED : DISPOSITION_OTHER;
}

static void nothing(int signal_number) { (void)signal_number; }

/* Sets SIGINT and SIGQUIT to `handler`; returns whether both calls worked. */
static int set_interrupts(void (*handler)(int)) {
    struct sigaction action;
    memset(&action, 0, sizeof action);
    action.sa_handler = handler;
    return sigemptyset(&action.sa_mask) == 0 && sigaction(SIGINT, &action, NULL) == 0 &&
           sigaction(SIGQUIT, &action, NULL) == 0;
}

/* A harness started in the background by a non-interactive shell (`&`) hands its children
 * SIGINT and SIGQUIT ignored. The probes that read how the signals stand begin from the
 * defaults, so they do not depend on how they were started. */
static int start_from_defaults(void) { return set_interrupts(SIG_DFL); }

/* SIGINT and SIGQUIT are restored after Exited and after Signaled, whatever they were: default,
 * ignored (which the child then inherits) or a handler (which must not run in the child: both
 * stand at the default from the fork until exec, which probe_execve checks). The child reports how it sees them as its status: 1 for SIGINT ignored and
 * 2 for SIGQUIT. Each case ends by restoring the defaults. */
static int run_signals(const char *program) {
    const char *const observe[] = {"observe-signals"};
    const char *const terminate[] = {"signal"};
    int64_t ended = -1, error = 0;
    interrupts_at_exec = 0;
    int correct = start_from_defaults() && disposition_of(SIGINT) == DISPOSITION_DEFAULT &&
                  disposition_of(SIGQUIT) == DISPOSITION_DEFAULT;
    correct = correct && run_program(program, 1, observe, &ended, &error) && ended == RUN_EXITED(0) &&
              disposition_of(SIGINT) == DISPOSITION_DEFAULT &&
              disposition_of(SIGQUIT) == DISPOSITION_DEFAULT;
    correct = correct && run_program(program, 1, terminate, &ended, &error) &&
              ended == RUN_SIGNALED(SIGTERM) && disposition_of(SIGINT) == DISPOSITION_DEFAULT &&
              disposition_of(SIGQUIT) == DISPOSITION_DEFAULT;
    interrupts_at_exec = 1;
    correct = correct && set_interrupts(SIG_IGN);
    correct = correct && run_program(program, 1, observe, &ended, &error) && ended == RUN_EXITED(3) &&
              disposition_of(SIGINT) == DISPOSITION_IGNORED &&
              disposition_of(SIGQUIT) == DISPOSITION_IGNORED;
    correct = correct && run_program(program, 1, terminate, &ended, &error) &&
              ended == RUN_SIGNALED(SIGTERM) && disposition_of(SIGINT) == DISPOSITION_IGNORED &&
              disposition_of(SIGQUIT) == DISPOSITION_IGNORED;
    interrupts_at_exec = 0;
    correct = correct && set_interrupts(nothing);
    correct = correct && run_program(program, 1, observe, &ended, &error) && ended == RUN_EXITED(0) &&
              disposition_of(SIGINT) == DISPOSITION_OTHER &&
              disposition_of(SIGQUIT) == DISPOSITION_OTHER;
    interrupts_at_exec = -1;
    return set_interrupts(SIG_DFL) && correct ? 0 : 1;
}

/* Ctrl-C without a terminal: the child sends SIGINT to its own group, which is this
 * process's, so it reaches this process too. The call survives it, reports the child's
 * Signaled, and restores SIGINT. */
static int run_interrupt_group(const char *program) {
    const char *const arguments[] = {"interrupt-group"};
    int64_t ended = -1, error = 0;
    if (!start_from_defaults()) return 1;
    const uint8_t succeeded = run_program(program, 1, arguments, &ended, &error);
    return succeeded && ended == RUN_SIGNALED(SIGINT) &&
           disposition_of(SIGINT) == DISPOSITION_DEFAULT &&
           disposition_of(SIGQUIT) == DISPOSITION_DEFAULT ? 0 : 1;
}

/* What this process printed, still buffered because stdout is a pipe, comes before what the
 * child prints. The driver compares the pipe's contents. */
static int run_flush(const char *program) {
    const char *const arguments[] = {"print-line"};
    int64_t ended = -1, error = 0;
    if (fputs("caller line\n", stdout) == EOF) return 1;
    return run_program(program, 1, arguments, &ended, &error) && ended == RUN_EXITED(0) ? 0 : 1;
}

/* P11: a child that calls exit_interrupted with output still buffered is Signaled(SIGINT),
 * and its output arrives after the caller's. */
static int run_exit_interrupted(const char *program) {
    const char *const arguments[] = {"exit-interrupted"};
    int64_t ended = -1, error = 0;
    if (fputs("caller line\n", stdout) == EOF) return 1;
    return run_program(program, 1, arguments, &ended, &error) && ended == RUN_SIGNALED(SIGINT) ? 0 : 1;
}

/* exit_interrupted cannot end a process that has SIGINT blocked: the native returns, so the
 * library's caller can exit 130 itself. The child blocks SIGINT and reports through its status. */
static int run_interrupt_blocked(const char *program) {
    const char *const arguments[] = {"interrupt-blocked"};
    int64_t ended = -1, error = 0;
    return run_program(program, 1, arguments, &ended, &error) && ended == RUN_EXITED(0) ? 0 : 1;
}

/* SIGCHLD ignored is LaunchFailed(OtherOs(ECHILD)), decided before forking. */
static int run_sigchld(const char *program) {
    struct sigaction original, changed;
    memset(&changed, 0, sizeof changed);
    changed.sa_handler = SIG_IGN;
    if (sigemptyset(&changed.sa_mask) != 0 || sigaction(SIGCHLD, &changed, &original) != 0) return 1;
    const char *const arguments[] = {"exit", "0"};
    int64_t ended = -1, error = 0;
    if (!start_from_defaults()) return 1;
    const int forks = fork_count;
    const uint8_t succeeded = run_program(program, 2, arguments, &ended, &error);
    if (sigaction(SIGCHLD, &original, NULL) != 0) return 1;
    const int64_t expected = blorp_process_error(-(int64_t)ECHILD, BLORP_PROCESS_LAUNCH_FAILED);
    return !succeeded && error == expected && fork_count == forks &&
           disposition_of(SIGINT) == DISPOSITION_DEFAULT ? 0 : 1;
}

/* A failed fork is LaunchFailed, and leaves SIGINT and SIGQUIT as they were. */
static int run_fork_failure(const char *program) {
    const char *const arguments[] = {"exit", "0"};
    int64_t ended = -1, error = 0;
    if (!start_from_defaults()) return 1;
    fork_failure = ENOSPC;
    const uint8_t failed = run_program(program, 2, arguments, &ended, &error);
    fork_failure = 0;
    return !failed && error == blorp_process_error(-(int64_t)ENOSPC, BLORP_PROCESS_LAUNCH_FAILED) &&
           disposition_of(SIGINT) == DISPOSITION_DEFAULT &&
           disposition_of(SIGQUIT) == DISPOSITION_DEFAULT && no_child() ? 0 : 1;
}

/* The session of the pty probe: runs `mode` of the child on this terminal and reports how it
 * ended and how SIGINT and SIGQUIT stand afterwards. */
static int run_session(const char *program, const char *mode) {
    const char *const arguments[] = {mode};
    int64_t ended = -1, error = 0;
    if (!run_program(program, 1, arguments, &ended, &error)) {
        printf("parent: failed %lld\n", (long long)error);
        return fflush(stdout) == 0 ? 1 : 2;
    }
    printf("parent: %s(%lld)\n", ended / BLORP_PROCESS_EXIT_SPAN == BLORP_PROCESS_EXITED ? "Exited" : "Signaled",
           (long long)(ended % BLORP_PROCESS_EXIT_SPAN));
    printf("parent: SIGINT %s, SIGQUIT %s\n",
           disposition_of(SIGINT) == DISPOSITION_DEFAULT ? "default" : "changed",
           disposition_of(SIGQUIT) == DISPOSITION_DEFAULT ? "default" : "changed");
    return fflush(stdout) == 0 ? 0 : 2;
}

/* A session on a pseudo-terminal: a new session whose controlling terminal is the pty, running
 * this program in `run-session` mode. Linux makes the pty the controlling terminal when the
 * session leader opens it; Darwin only on TIOCSCTTY, which Linux accepts again as a no-op. */
enum { TERMINAL_LOG = 8192, TERMINAL_STEP_MS = 5000 };

struct terminal_session {
    int master;
    pid_t leader;
    char log[TERMINAL_LOG];
    size_t used;
};

static int terminal_start(struct terminal_session *session, const char *program, const char *mode) {
    session->used = 0;
    session->log[0] = '\0';
    session->master = posix_openpt(O_RDWR | O_NOCTTY);
    if (session->master < 0 || grantpt(session->master) != 0 || unlockpt(session->master) != 0) return 1;
    const char *name = ptsname(session->master);
    if (name == NULL) return 1;
    session->leader = fork();
    if (session->leader == 0) {
        if (setsid() < 0) _exit(120);
        const int slave = open(name, O_RDWR);
        if (slave < 0) _exit(121);
#ifdef TIOCSCTTY
        if (ioctl(slave, TIOCSCTTY, 0) != 0) _exit(122);
#endif
        if (dup2(slave, STDIN_FILENO) < 0 || dup2(slave, STDOUT_FILENO) < 0 ||
            dup2(slave, STDERR_FILENO) < 0) _exit(123);
        if (slave > STDERR_FILENO && close(slave) != 0) _exit(124);
        char *const arguments[] = {(char *)program, "run-session", (char *)program, (char *)mode, NULL};
        execv(program, arguments);
        _exit(125);
    }
    return session->leader < 0;
}

/* Reads the terminal until the log holds `text`; a step that makes no progress for
 * TERMINAL_STEP_MS fails, so a hung session cannot hang the probe. */
static int terminal_expect(struct terminal_session *session, const char *text) {
    while (strstr(session->log, text) == NULL) {
        struct pollfd ready = {session->master, POLLIN, 0};
        if (poll(&ready, 1, TERMINAL_STEP_MS) <= 0) return 1;
        const ssize_t got = read(session->master, session->log + session->used,
                                 TERMINAL_LOG - 1 - session->used);
        if (got <= 0) return 1;
        session->used += (size_t)got;
        session->log[session->used] = '\0';
    }
    return 0;
}

static int terminal_type(struct terminal_session *session, const char *keys) {
    return write(session->master, keys, strlen(keys)) == (ssize_t)strlen(keys) ? 0 : 1;
}

/* Reaps the session, and always kills its group first on failure, so no path leaves a child. */
static int terminal_finish(struct terminal_session *session, int failed) {
    if (failed) (void)kill(-session->leader, SIGKILL);
    int status = 0;
    while (waitpid(session->leader, &status, 0) < 0 && errno == EINTR) {}
    const int ended = WIFEXITED(status) && WEXITSTATUS(status) == 0;
    return close(session->master) == 0 && ended && !failed ? 0 : 1;
}

static int terminal_case(const char *program, const char *mode, const char *keys,
                         const char *awaited, const char *const expected[]) {
    struct terminal_session session;
    if (terminal_start(&session, program, mode) != 0) return 1;
    int failed = awaited != NULL && terminal_expect(&session, awaited);
    failed = failed || (keys != NULL && terminal_type(&session, keys));
    for (int index = 0; !failed && expected[index] != NULL; index++) {
        failed = terminal_expect(&session, expected[index]);
    }
    return terminal_finish(&session, failed);
}

/* What a user does on a terminal: types a line the child reads, which shows live output and
 * a child in the terminal's foreground group, then presses Ctrl-C and Ctrl-\. */
static int run_terminal(const char *program) {
    const char *const typed[] = {"child: second hello", "parent: Exited(0)",
                                 "parent: SIGINT default, SIGQUIT default", NULL};
    const char *const foreground[] = {"child: foreground", "parent: Exited(0)", NULL};
    const char *const interrupted[] = {"parent: Signaled(2)", "parent: SIGINT default, SIGQUIT default", NULL};
    const char *const quit[] = {"parent: Signaled(3)", "parent: SIGINT default, SIGQUIT default", NULL};
    if (!start_from_defaults()) return 1;
    return terminal_case(program, "live", "hello\n", "child: first", typed) == 0 &&
           terminal_case(program, "foreground", NULL, NULL, foreground) == 0 &&
           terminal_case(program, "wait", "\003", "child: waiting", interrupted) == 0 &&
           terminal_case(program, "wait", "\034", "child: waiting", quit) == 0 ? 0 : 1;
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
        /* Not ASCII, so each captured String must count its code points. */
        fputs("stdout caf\303\251\n", stdout);
        fputs("stderr caf\303\251\n", stderr);
        return 0;
    }
    if (strcmp(argv[1], "pause") == 0) { for (;;) pause(); }
    if (strcmp(argv[1], "group-leader") == 0) return getpgrp() == getpid() ? 0 : 1;
    if (strcmp(argv[1], "stdin") == 0) return getchar() == EOF ? 0 : 1;
    if (strcmp(argv[1], "signal") == 0) {
        if (raise(SIGTERM) != 0) return 1;
        return 1;
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
    /* The children of the run tests, which print nothing the driver would show: each reports
     * what it found as its status. */
    if (strcmp(argv[1], "env-equals") == 0 && argc == 4) {
        const char *value = getenv(argv[2]);
        return value != NULL && strcmp(value, argv[3]) == 0 ? 0 : 1;
    }
    if (strcmp(argv[1], "env-unset") == 0 && argc == 3) return getenv(argv[2]) == NULL ? 0 : 1;
    if (strcmp(argv[1], "file-exists") == 0 && argc == 3) return access(argv[2], F_OK) == 0 ? 0 : 1;
    /* The children of the run probes, which share the probe's terminal and group. */
    if (strcmp(argv[1], "observe-signals") == 0) {
        return (disposition_of(SIGINT) == DISPOSITION_IGNORED ? 1 : 0) +
               (disposition_of(SIGQUIT) == DISPOSITION_IGNORED ? 2 : 0) +
               (disposition_of(SIGINT) == DISPOSITION_OTHER || disposition_of(SIGQUIT) == DISPOSITION_OTHER ? 4 : 0);
    }
    if (strcmp(argv[1], "interrupt-group") == 0) {
        if (kill(0, SIGINT) != 0) return 1;
        sleep(INTERRUPT_WAIT_SECONDS);
        return 2;
    }
    if (strcmp(argv[1], "print-line") == 0) return fputs("child line\n", stdout) == EOF ? 1 : 0;
    if (strcmp(argv[1], "exit-interrupted") == 0) {
        int64_t error = 0;
        if (fputs("child buffered\n", stdout) == EOF) return 1;
        (void)blorp_process_exit_interrupted(&error);
        return 2;
    }
    /* With SIGINT blocked it cannot end the process: the native returns, as the library says. */
    if (strcmp(argv[1], "interrupt-blocked") == 0) {
        sigset_t interrupt_only;
        int64_t error = -1;
        if (sigemptyset(&interrupt_only) != 0 || sigaddset(&interrupt_only, SIGINT) != 0 ||
            pthread_sigmask(SIG_BLOCK, &interrupt_only, NULL) != 0) return 1;
        return blorp_process_exit_interrupted(&error) == BLORP_PROCESS_ERROR && error == 0 ? 0 : 1;
    }
    if (strcmp(argv[1], "live") == 0) {
        char line[64];
        if (fputs("child: first\n", stdout) == EOF || fflush(stdout) != 0) return 1;
        while (fgets(line, sizeof line, stdin) == NULL) {
            if (!ferror(stdin) || errno != EINTR) return 1;
            clearerr(stdin);
        }
        return printf("child: second %s", line) < 0 ? 1 : 0;
    }
    if (strcmp(argv[1], "foreground") == 0) {
        const int owned = tcgetpgrp(STDIN_FILENO) == getpgrp();
        return fputs(owned ? "child: foreground\n" : "child: background\n", stdout) == EOF || !owned ? 1 : 0;
    }
    if (strcmp(argv[1], "wait") == 0) {
        /* Ctrl-\ ends it with a core dump by default, which CI should not collect. */
        const struct rlimit no_core = {0, 0};
        if (setrlimit(RLIMIT_CORE, &no_core) != 0) return 1;
        if (fputs("child: waiting\n", stdout) == EOF || fflush(stdout) != 0) return 1;
        for (;;) pause();
    }
    /* Each forces a reply the library cannot decode; the runtime aborts with the defect. */
    if (strcmp(argv[1], "bad-error-code") == 0) return (int)blorp_process_error(0, BLORP_PROCESS_NOT_ON_PATH + 2);
    if (strcmp(argv[1], "bad-exit") == 0) return (int)blorp_process_exit(BLORP_PROCESS_TIMED_OUT + 1, 0);
    if (strcmp(argv[1], "fault") == 0) {
        struct blorp_string *message = blorp_string_from_bytes("forced by the probe", 19);
        int64_t error = 0;
        return blorp_process_fault(message, &error);
    }
    /* A native probe is given this program's own path, then a path it may create. */
    if (argc == 4) {
        if (strcmp(argv[1], "capture-signals") == 0) return capture_signals(argv[2]);
        if (strcmp(argv[1], "capture-sigchld") == 0) return capture_sigchld(argv[2]);
        if (strcmp(argv[1], "capture-reap") == 0) return capture_reap(argv[2]);
        if (strcmp(argv[1], "capture-fork-failure") == 0) return capture_fork_failure(argv[2]);
        if (strcmp(argv[1], "capture-startup") == 0) return capture_startup(argv[2]);
        if (strcmp(argv[1], "capture-closed-stdio") == 0) return capture_closed_stdio(argv[2]);
        if (strcmp(argv[1], "capture-group-race") == 0) return capture_group_race(argv[2]);
        if (strcmp(argv[1], "capture-stray-report") == 0) return capture_stray_report_holder(argv[2]);
        if (strcmp(argv[1], "find-program") == 0) return find_program_case(argv[3]);
        if (strcmp(argv[1], "run-signals") == 0) return run_signals(argv[2]);
        if (strcmp(argv[1], "run-interrupt-group") == 0) return run_interrupt_group(argv[2]);
        if (strcmp(argv[1], "run-flush") == 0) return run_flush(argv[2]);
        if (strcmp(argv[1], "run-exit-interrupted") == 0) return run_exit_interrupted(argv[2]);
        if (strcmp(argv[1], "run-sigchld") == 0) return run_sigchld(argv[2]);
        if (strcmp(argv[1], "run-fork-failure") == 0) return run_fork_failure(argv[2]);
        if (strcmp(argv[1], "run-terminal") == 0) return run_terminal(argv[2]);
        if (strcmp(argv[1], "run-session") == 0) return run_session(argv[2], argv[3]);
        if (strcmp(argv[1], "run-interrupt-blocked") == 0) return run_interrupt_blocked(argv[2]);
    }
    return 1;
}

int main(int argc, char **argv) {
    blorp_memory_start();
    return blorp_memory_finish(child_case(argc, argv));
}
