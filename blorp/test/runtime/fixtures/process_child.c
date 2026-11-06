/* Native runtime-helper unit probe, built with unmodified production fragments. */
#define _POSIX_C_SOURCE 200809L
#include <unistd.h>

/* Only the startup-timeout probe stalls at the native exec boundary. */
static int stall_exec = 0;
static int exec_ready_writer = -1;
static int probe_execve(const char *path, char *const arguments[], char *const environment[]);
#define execve probe_execve
#include "process_runtime.c"
#undef execve

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
    if (strcmp(argv[1], "fifo") == 0 && argc == 3) return mkfifo(argv[2], S_IRUSR | S_IWUSR) == 0 ? 0 : 1;
    if (strcmp(argv[1], "symlink") == 0 && argc == 4) return symlink(argv[2], argv[3]) == 0 ? 0 : 1;
    if (strcmp(argv[1], "closedstdio") == 0 && argc == 5) return closed_stdio(argv[2], argv[3], argv[4]);
    if (argc == 5 && (strcmp(argv[1], "reap-exit") == 0 || strcmp(argv[1], "reap-signal") == 0 ||
                      strcmp(argv[1], "reap-timeout") == 0 || strcmp(argv[1], "reap-startup") == 0))
        return direct_reaping(argv[2], argv[3], argv[4], argv[1]);
    if (strcmp(argv[1], "sigchld") == 0 && argc == 5) return unsupported_sigchld(argv[2], argv[3], argv[4]);
    return 1;
}

int main(int argc, char **argv) {
    blorp_memory_start();
    return blorp_memory_finish(child_case(argc, argv));
}
