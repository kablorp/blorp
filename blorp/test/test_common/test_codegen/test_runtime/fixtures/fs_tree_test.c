/* Native probe of fs.remove_directory_tree and fs.create_temporary_directory,
 * built with the unmodified production fragments. Each case is one argument;
 * a case that passes returns 0 and prints nothing.
 *
 * The system calls in the included runtime text are renamed to recording
 * wrappers (D6). A wrapper counts the call and either passes it through or
 * returns an injected failure, so a case can bound the descriptors the walk
 * holds and provoke what no file system here gives on demand: another device,
 * a moved directory, a hidden or vanished entry, a name that is not UTF-8, a
 * failed readdir or fdopendir, and EINTR. Nothing in the production text
 * changes.
 *
 * Sandboxing comes first, because a broken refusal would remove whatever the
 * path names. Every case works in a sandbox two levels inside its own scratch
 * directory, and a case that expects nothing removed arms the removing
 * wrappers to abort the process instead of passing through. The device cases
 * inject devices and never run against a real mount. */
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
static int recording_openat(int directory, const char *name, int flags, ...);
static int recording_close(int descriptor);
static int recording_fcntl(int descriptor, int command, ...);
static DIR *recording_fdopendir(int descriptor);
static struct dirent *recording_readdir(DIR *stream);
static int recording_closedir(DIR *stream);
static int recording_fstat(int descriptor, struct stat *status);
static int recording_unlinkat(int directory, const char *name, int flags);
static int recording_rmdir(const char *path);
static char *recording_mkdtemp(char *template_path);
#define open recording_open
#define openat recording_openat
#define close recording_close
#define fcntl recording_fcntl
#define fdopendir recording_fdopendir
#define readdir recording_readdir
#define closedir recording_closedir
#define fstat recording_fstat
#define unlinkat recording_unlinkat
#define rmdir recording_rmdir
#define mkdtemp recording_mkdtemp
#include "fs_tree_runtime.c"
#undef open
#undef openat
#undef close
#undef fcntl
#undef fdopendir
#undef readdir
#undef closedir
#undef fstat
#undef unlinkat
#undef rmdir
#undef mkdtemp

enum call {
    OPEN_CALL, OPENAT_CALL, CLOSE_CALL, FCNTL_CALL, FDOPENDIR_CALL, READDIR_CALL, CLOSEDIR_CALL,
    FSTAT_CALL, UNLINKAT_CALL, RMDIR_CALL, MKDTEMP_CALL,
    CALL_KINDS
};

enum {
    PATH_BYTES = 1024,
    NAME_BYTES = 256,
    /* Descriptors a wrapper tracks; the deep chain runs under a limit of 32. */
    DESCRIPTOR_SLOTS = 4096,
    /* The walk holds the current directory, a child or parent, and the reading copy. */
    DESCRIPTOR_BOUND = 3,
    /* More levels than the plan's 300, and a path longer than PATH_MAX on both platforms. */
    CHAIN_DEPTH = 320,
    CHAIN_DESCRIPTOR_LIMIT = 32,
    IDENTITY_SLOTS = 64,
    RECEIVED_NAME_SLOTS = 64
};

/* Fails the calls of one kind: the first `skip` pass, and the next `failures`
 * fail with `error`. */
struct injection {
    int skip;
    int failures;
    int error;
};

/* fstat of a descriptor opened under `name` reports another device or inode:
 * the first `skip` such calls pass, and the next one is changed. */
enum identity_field { NO_CHANGE, DEVICE_CHANGE, INODE_CHANGE };
struct identity_change {
    const char *name;
    int skip;
    enum identity_field field;
};

struct identity {
    dev_t device;
    ino_t inode;
};

static int calls[CALL_KINDS];
/* unlinkat calls with AT_REMOVEDIR, which remove a directory. */
static int directory_unlinks = 0;
static struct injection injections[CALL_KINDS];
static struct identity_change identity_change;
/* unlinkat and rmdir abort the process instead of removing anything. */
static int removal_forbidden = 0;
/* unlinkat without AT_REMOVEDIR refuses a real directory with this errno, as
 * macOS does with EPERM, or at a mount point with EBUSY. 0 leaves it alone. */
static int directory_unlink_error = 0;
/* unlinkat without AT_REMOVEDIR refuses this one name with `refused_error`. */
static const char *refused_name = NULL;
static int refused_error = 0;
/* unlinkat removes this name and then reports ENOENT, as when another process
 * removed it first. */
static const char *vanishing_name = NULL;
/* readdir passes over this name, so the walk never sees it. */
static const char *hidden_name = NULL;
/* readdir returns these names before the real ones; NULL ends the array.
 * unlinkat reports success for them without a system call. */
static const char *const *crafted_names = NULL;
static const char *const *crafted_remaining = NULL;
/* readdir fails the case if it reads a directory that unlinkat has already
 * removed from: each directory's names are read in full before any removal. */
static int checking_read_order = 0;
static struct identity removed_from[IDENTITY_SLOTS];
static int removed_from_count = 0;
/* The first names unlinkat received since begin(), and how many it received. */
static char received_names[RECEIVED_NAME_SLOTS][NAME_BYTES];
static int received_name_count = 0;
static struct dirent returned_entry;

/* Each descriptor the runtime holds, with the name it was opened under. */
static unsigned char descriptor_held[DESCRIPTOR_SLOTS];
static char descriptor_names[DESCRIPTOR_SLOTS][NAME_BYTES];
static int held_count = 0;
static int most_held = 0;

static void copy_name(char *target, const char *name) {
    const size_t length = strlen(name);
    assert(length < NAME_BYTES);
    memcpy(target, name, length + 1);
}

static void hold(int descriptor, const char *name) {
    assert(descriptor >= 0 && descriptor < DESCRIPTOR_SLOTS);
    assert(!descriptor_held[descriptor]);
    descriptor_held[descriptor] = 1;
    copy_name(descriptor_names[descriptor], name);
    held_count++;
    if (held_count > most_held) most_held = held_count;
}

/* A descriptor is released exactly once, and only one the runtime holds. */
static void release(int descriptor) {
    assert(descriptor >= 0 && descriptor < DESCRIPTOR_SLOTS);
    assert(descriptor_held[descriptor]);
    descriptor_held[descriptor] = 0;
    held_count--;
}

/* The errno to inject into this call, or 0 to pass it through. */
static int injected_error(enum call call) {
    calls[call]++;
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

static void forbidden(const char *call, const char *name) {
    fprintf(stderr, "%s(%s) reached while removal is forbidden\n", call, name);
    abort();
}

static struct identity identity_of(int descriptor) {
    struct stat status;
    assert(fstat(descriptor, &status) == 0);
    return (struct identity){status.st_dev, status.st_ino};
}

static int read_after_removal(struct identity directory) {
    for (int index = 0; index < removed_from_count; index++) {
        if (removed_from[index].device == directory.device && removed_from[index].inode == directory.inode) return 1;
    }
    return 0;
}

static void note_removal_from(int directory) {
    if (!checking_read_order) return;
    const struct identity removed = identity_of(directory);
    if (read_after_removal(removed)) return;
    assert(removed_from_count < IDENTITY_SLOTS);
    removed_from[removed_from_count++] = removed;
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
    if (injected != 0) {
        errno = injected;
        return -1;
    }
    const int result = open(path, flags, mode);
    if (result >= 0) hold(result, path);
    return result;
}

static int recording_openat(int directory, const char *name, int flags, ...) {
    int mode = 0;
    if ((flags & O_CREAT) != 0) {
        va_list arguments;
        va_start(arguments, flags);
        mode = va_arg(arguments, int);
        va_end(arguments);
    }
    const int injected = injected_error(OPENAT_CALL);
    if (injected != 0) {
        errno = injected;
        return -1;
    }
    const int result = openat(directory, name, flags, mode);
    if (result >= 0) hold(result, name);
    return result;
}

static int recording_close(int descriptor) {
    calls[CLOSE_CALL]++;
    release(descriptor);
    return close(descriptor);
}

static int recording_fcntl(int descriptor, int command, ...) {
    va_list arguments;
    va_start(arguments, command);
    const int argument = va_arg(arguments, int);
    va_end(arguments);
    const int injected = injected_error(FCNTL_CALL);
    if (injected != 0) {
        errno = injected;
        return -1;
    }
    assert(command == F_DUPFD_CLOEXEC);
    const int result = fcntl(descriptor, command, argument);
    if (result >= 0) hold(result, descriptor_names[descriptor]);
    return result;
}

/* An injected failure leaves the descriptor open, as fdopendir's does. */
static DIR *recording_fdopendir(int descriptor) {
    const int injected = injected_error(FDOPENDIR_CALL);
    if (injected != 0) {
        errno = injected;
        return NULL;
    }
    return fdopendir(descriptor);
}

/* The entry is copied field by field: a real entry may be shorter than
 * struct dirent, so copying the whole struct could read past it. */
static struct dirent *returned(const char *name) {
    memset(&returned_entry, 0, sizeof returned_entry);
    const size_t length = strlen(name);
    assert(length < sizeof returned_entry.d_name);
    memcpy(returned_entry.d_name, name, length + 1);
    return &returned_entry;
}

/* An injected failure returns NULL with errno set and consumes no entry. */
static struct dirent *recording_readdir(DIR *stream) {
    const int injected = injected_error(READDIR_CALL);
    if (checking_read_order) assert(!read_after_removal(identity_of(dirfd(stream))));
    if (injected != 0) {
        errno = injected;
        return NULL;
    }
    if (crafted_remaining != NULL && *crafted_remaining != NULL) return returned(*crafted_remaining++);
    const int before = errno;
    for (;;) {
        struct dirent *entry = readdir(stream);
        if (entry == NULL || hidden_name == NULL || strcmp(entry->d_name, hidden_name) != 0) {
            if (entry != NULL) errno = before;
            return entry;
        }
    }
}

static int recording_closedir(DIR *stream) {
    calls[CLOSEDIR_CALL]++;
    release(dirfd(stream));
    return closedir(stream);
}

static int recording_fstat(int descriptor, struct stat *status) {
    const int injected = injected_error(FSTAT_CALL);
    if (injected != 0) {
        errno = injected;
        return -1;
    }
    const int result = fstat(descriptor, status);
    if (result == 0 && identity_change.field != NO_CHANGE && strcmp(descriptor_names[descriptor], identity_change.name) == 0) {
        if (identity_change.skip > 0) {
            identity_change.skip--;
        } else {
            if (identity_change.field == DEVICE_CHANGE) status->st_dev = (dev_t)(status->st_dev + 1);
            if (identity_change.field == INODE_CHANGE) status->st_ino = (ino_t)(status->st_ino + 1);
            identity_change.field = NO_CHANGE;
        }
    }
    return result;
}

static int is_crafted(const char *name) {
    for (const char *const *crafted = crafted_names; crafted != NULL && *crafted != NULL; crafted++) {
        if (strcmp(*crafted, name) == 0) return 1;
    }
    return 0;
}

static int recording_unlinkat(int directory, const char *name, int flags) {
    if (removal_forbidden) forbidden("unlinkat", name);
    const int injected = injected_error(UNLINKAT_CALL);
    if ((flags & AT_REMOVEDIR) != 0) directory_unlinks++;
    if (received_name_count < RECEIVED_NAME_SLOTS) copy_name(received_names[received_name_count], name);
    received_name_count++;
    note_removal_from(directory);
    if (injected != 0) {
        errno = injected;
        return -1;
    }
    if (is_crafted(name)) return 0;
    if ((flags & AT_REMOVEDIR) == 0) {
        if (refused_name != NULL && strcmp(name, refused_name) == 0) {
            errno = refused_error;
            return -1;
        }
        struct stat status;
        if (directory_unlink_error != 0 && fstatat(directory, name, &status, AT_SYMLINK_NOFOLLOW) == 0 && S_ISDIR(status.st_mode)) {
            errno = directory_unlink_error;
            return -1;
        }
    }
    const int result = unlinkat(directory, name, flags);
    if (result == 0 && vanishing_name != NULL && strcmp(name, vanishing_name) == 0) {
        errno = ENOENT;
        return -1;
    }
    return result;
}

static int recording_rmdir(const char *path) {
    if (removal_forbidden) forbidden("rmdir", path);
    const int injected = injected_error(RMDIR_CALL);
    if (injected != 0) {
        errno = injected;
        return -1;
    }
    return rmdir(path);
}

static char *recording_mkdtemp(char *template_path) {
    const int injected = injected_error(MKDTEMP_CALL);
    if (injected != 0) {
        errno = injected;
        return NULL;
    }
    return mkdtemp(template_path);
}

/* Clears the counts and every injection before the call a case observes. */
static void begin(void) {
    memset(calls, 0, sizeof calls);
    directory_unlinks = 0;
    memset(injections, 0, sizeof injections);
    identity_change = (struct identity_change){NULL, 0, NO_CHANGE};
    removal_forbidden = 0;
    directory_unlink_error = 0;
    refused_name = NULL;
    refused_error = 0;
    vanishing_name = NULL;
    hidden_name = NULL;
    crafted_names = NULL;
    crafted_remaining = NULL;
    checking_read_order = 0;
    removed_from_count = 0;
    received_name_count = 0;
}

static int system_calls(void) {
    int total = 0;
    for (int call = 0; call < CALL_KINDS; call++) total += calls[call];
    return total;
}

/* The number the next open would return, outside the wrappers. */
static int lowest_free_descriptor(void) {
    const int probe = open("/dev/null", O_RDONLY);
    assert(probe >= 0);
    assert(close(probe) == 0);
    return probe;
}

static struct blorp_string *bytes_of(const char *bytes, size_t length) {
    return blorp_string_from_bytes(bytes, (int64_t)length);
}

static struct blorp_string *string_of(const char *text) {
    return bytes_of(text, strlen(text));
}

/* A path with a NUL embedded after its own bytes. */
static struct blorp_string *nul_path(const char *path) {
    char bytes[PATH_BYTES];
    const size_t length = strlen(path);
    assert(length + 7 < PATH_BYTES);
    memcpy(bytes, path, length);
    memcpy(bytes + length, "\0suffix", 7);
    return bytes_of(bytes, length + 7);
}

static int64_t outcome(uint8_t succeeded, int64_t error) {
    assert(succeeded == BLORP_FS_SUCCEEDED ? error == 0 : error != 0);
    return error;
}

/* Every call, failed or not, releases each descriptor it opened exactly once
 * and never holds more than the bound. */
static int64_t remove_tree_string(struct blorp_string *path) {
    const int free_before = lowest_free_descriptor();
    most_held = 0;
    int64_t error = 0;
    const uint8_t succeeded = blorp_fs_remove_directory_tree(path, &error);
    blorp_string_release(path);
    assert(held_count == 0);
    assert(most_held <= DESCRIPTOR_BOUND);
    assert(lowest_free_descriptor() == free_before);
    return outcome(succeeded, error);
}

static int64_t remove_tree(const char *path) {
    return remove_tree_string(string_of(path));
}

/* On success `*directory` is the new path, which the caller releases. */
static int64_t temporary_strings(struct blorp_string *parent, struct blorp_string *prefix, struct blorp_string **directory) {
    const int free_before = lowest_free_descriptor();
    int64_t error = 0;
    *directory = NULL;
    const uint8_t succeeded = blorp_fs_create_temporary_directory(parent, prefix, directory, &error);
    blorp_string_release(parent);
    blorp_string_release(prefix);
    assert(succeeded == BLORP_FS_SUCCEEDED ? *directory != NULL : *directory == NULL);
    assert(held_count == 0);
    assert(lowest_free_descriptor() == free_before);
    return outcome(succeeded, error);
}

static int64_t temporary_failure(const char *parent, const char *prefix) {
    struct blorp_string *directory = NULL;
    const int64_t error = temporary_strings(string_of(parent), string_of(prefix), &directory);
    assert(error != 0);
    return error;
}

/* "<directory>/<name>" into a caller's PATH_BYTES buffer. */
static void join(char *joined, const char *directory, const char *name) {
    const int length = snprintf(joined, PATH_BYTES, "%s/%s", directory, name);
    assert(length > 0 && length < PATH_BYTES);
}

static void make_directory(const char *path) {
    assert(mkdir(path, 0755) == 0);
}

static void make_file(const char *path) {
    FILE *stream = fopen(path, "wb");
    assert(stream != NULL);
    assert(fputs(path, stream) >= 0);
    assert(fclose(stream) == 0);
}

static int exists(const char *path) {
    struct stat status;
    return lstat(path, &status) == 0;
}

static int is_directory(const char *path) {
    struct stat status;
    return lstat(path, &status) == 0 && S_ISDIR(status.st_mode);
}

/* Makes "<directory>/tree-<name>/sandbox/inner" and works inside it, so the
 * names `.` and `..` and every relative path stay inside the case's own
 * scratch directory. */
static void enter_sandbox(const char *directory, const char *name) {
    char scratch[PATH_BYTES], sandbox[PATH_BYTES], inner[PATH_BYTES];
    const int length = snprintf(scratch, PATH_BYTES, "%s/tree-%s", directory, name);
    assert(length > 0 && length < PATH_BYTES);
    make_directory(scratch);
    join(sandbox, scratch, "sandbox");
    make_directory(sandbox);
    join(inner, sandbox, "inner");
    make_directory(inner);
    assert(chdir(inner) == 0);
}

/* A small tree at `root`: files, links to a file, to a directory and to
 * nothing, a FIFO, an empty directory and a full one two levels deep. */
static void make_tree(const char *root) {
    char path[PATH_BYTES];
    make_directory(root);
    join(path, root, "file");
    make_file(path);
    join(path, root, "second");
    make_file(path);
    join(path, root, "file_link");
    assert(symlink("file", path) == 0);
    join(path, root, "directory_link");
    assert(symlink("full", path) == 0);
    join(path, root, "dangling");
    assert(symlink("missing", path) == 0);
    join(path, root, "fifo");
    assert(mkfifo(path, 0644) == 0);
    join(path, root, "empty");
    make_directory(path);
    join(path, root, "full");
    make_directory(path);
    join(path, root, "full/inner");
    make_file(path);
    join(path, root, "full/deeper");
    make_directory(path);
    join(path, root, "full/deeper/deepest");
    make_file(path);
    join(path, root, "full/deeper/empty");
    make_directory(path);
}

static int case_tree_missing(const char *directory) {
    enter_sandbox(directory, "missing");
    make_directory("kept");
    begin();
    assert(remove_tree("missing") == 1);
    assert(remove_tree("kept/missing") == 1);
    begin();
    assert(remove_tree("") == 1);
    assert(remove_tree_string(nul_path("kept")) == 12);
    assert(system_calls() == 0);
    assert(is_directory("kept"));
    return 0;
}

/* Only a real directory is a root: a file, and a link to anything, is
 * NotADirectory, and the link, its target and the target's contents survive. */
static int case_tree_not_directories(const char *directory) {
    enter_sandbox(directory, "not_directories");
    make_directory("target");
    make_file("target/inside");
    make_file("file");
    assert(symlink("target", "directory_link") == 0);
    assert(symlink("file", "file_link") == 0);
    assert(symlink("missing", "dangling") == 0);
    begin();
    removal_forbidden = 1;
    assert(remove_tree("file") == 4);
    assert(remove_tree("directory_link") == 4);
    assert(remove_tree("file_link") == 4);
    assert(remove_tree("dangling") == 4);
    assert(exists("directory_link") && exists("target/inside") && exists("file_link") && exists("file") && exists("dangling"));
    return 0;
}

/* POSIX resolves `link/` to the target, so trailing slashes are stripped first:
 * `link/` is the link, and `a/./` names `.`. A path of slashes keeps one. */
static int case_tree_trailing_slashes(const char *directory) {
    enter_sandbox(directory, "trailing_slashes");
    make_directory("target");
    make_file("target/inside");
    assert(symlink("target", "link") == 0);
    begin();
    removal_forbidden = 1;
    assert(remove_tree("link/") == 4);
    assert(remove_tree("link//") == 4);
    assert(remove_tree("target/./") == -(int64_t)EINVAL);
    assert(exists("link") && exists("target/inside"));
    removal_forbidden = 0;
    make_tree("slashed");
    assert(remove_tree("slashed//") == 0);
    assert(!exists("slashed"));
    return 0;
}

/* rmdir can never remove a final `.` or `..` as named, so these are refused
 * before any system call, rather than emptied first. */
static int case_tree_dot_refusals(const char *directory) {
    enter_sandbox(directory, "dot_refusals");
    make_directory("a");
    make_file("a/inside");
    begin();
    removal_forbidden = 1;
    const char *const refused[] = {".", "a/.", "..", "a/..", "./.", "a/../.."};
    for (size_t index = 0; index < sizeof refused / sizeof refused[0]; index++) {
        assert(remove_tree(refused[index]) == -(int64_t)EINVAL);
    }
    assert(system_calls() == 0);
    assert(exists("a/inside"));
    return 0;
}

/* `/`'s `..` is itself, so the root check refuses it as a mount point. */
static int case_tree_slash_root(const char *directory) {
    enter_sandbox(directory, "slash_root");
    begin();
    removal_forbidden = 1;
    assert(remove_tree("/") == 11);
    assert(remove_tree("//") == 11);
    assert(calls[READDIR_CALL] == 0);
    return 0;
}

/* A root whose `..` is on another device is a mount point: the walk would
 * empty the mounted file system before its rmdir failed with EBUSY. */
static int case_tree_root_mount_point(const char *directory) {
    enter_sandbox(directory, "root_mount_point");
    make_tree("mounted");
    begin();
    removal_forbidden = 1;
    identity_change = (struct identity_change){"..", 0, DEVICE_CHANGE};
    assert(remove_tree("mounted") == 11);
    assert(calls[READDIR_CALL] == 0);
    assert(exists("mounted/full/deeper/deepest"));
    return 0;
}

static int case_tree_removed(const char *directory) {
    enter_sandbox(directory, "removed");
    make_directory("empty");
    begin();
    assert(remove_tree("empty") == 0);
    assert(!exists("empty"));
    make_tree("tree");
    begin();
    assert(remove_tree("tree") == 0);
    assert(!exists("tree"));
    /* An absolute path is removed the same way. */
    char absolute[PATH_BYTES], working[PATH_BYTES];
    assert(getcwd(working, sizeof working) != NULL);
    join(absolute, working, "absolute");
    make_tree(absolute);
    assert(remove_tree(absolute) == 0);
    assert(!exists(absolute));
    return 0;
}

/* An empty child that can be read but not searched is read, has no names,
 * and is removed from its parent without entering it, which `..` could not
 * climb out of. */
static int case_tree_unsearchable_child(const char *directory) {
    enter_sandbox(directory, "unsearchable_child");
    make_directory("root");
    make_directory("root/read_only");
    assert(chmod("root/read_only", 0400) == 0);
    make_directory("root/read_write");
    assert(chmod("root/read_write", 0600) == 0);
    begin();
    assert(remove_tree("root") == 0);
    assert(!exists("root"));
    return 0;
}

/* A child that cannot be opened at all is removed only when it is empty. One
 * that is not empty is PermissionDenied, its contents and everything outside
 * the tree untouched. Root may open anything, so the suite leaves this case
 * out as root. */
static int case_tree_unopenable_child(const char *directory) {
    assert(geteuid() != 0);
    enter_sandbox(directory, "unopenable_child");
    make_directory("outside");
    make_file("outside/kept");
    make_directory("empty_tree");
    make_directory("empty_tree/closed");
    assert(chmod("empty_tree/closed", 0) == 0);
    begin();
    assert(remove_tree("empty_tree") == 0);
    assert(!exists("empty_tree"));
    make_directory("full_tree");
    make_directory("full_tree/closed");
    make_file("full_tree/closed/inside");
    assert(symlink("../../outside", "full_tree/closed/link") == 0);
    assert(chmod("full_tree/closed", 0) == 0);
    begin();
    assert(remove_tree("full_tree") == 2);
    assert(chmod("full_tree/closed", 0755) == 0);
    assert(exists("full_tree/closed/inside") && exists("full_tree/closed/link"));
    assert(exists("outside/kept"));
    return 0;
}

/* A link inside the tree to a directory outside it is removed as a link, and
 * the directory it names keeps its contents. */
static int case_tree_link_out(const char *directory) {
    enter_sandbox(directory, "link_out");
    make_directory("outside");
    make_file("outside/kept");
    make_directory("outside/nested");
    make_file("outside/nested/kept");
    make_directory("tree");
    char working[PATH_BYTES], target[PATH_BYTES];
    assert(getcwd(working, sizeof working) != NULL);
    join(target, working, "outside");
    assert(symlink(target, "tree/absolute") == 0);
    assert(symlink("../outside", "tree/relative") == 0);
    begin();
    assert(remove_tree("tree") == 0);
    assert(!exists("tree"));
    assert(exists("outside/kept") && exists("outside/nested/kept"));
    return 0;
}

static const char chain_name[] = "level-directory-name";

/* Removes the chain under `root` from the bottom up, outside the wrappers,
 * when the removal under test failed and left it. */
static void remove_chain_by_hand(const char *root) {
    for (int depth = CHAIN_DEPTH; depth >= 0; depth--) {
        int current = open(root, O_RDONLY | O_DIRECTORY);
        if (current < 0) return;
        for (int level = 0; level < depth && current >= 0; level++) {
            const int next = openat(current, chain_name, O_RDONLY | O_DIRECTORY);
            close(current);
            current = next;
        }
        if (current < 0) continue;
        if (depth == CHAIN_DEPTH) {
            (void)unlinkat(current, "bottom", 0);
        } else {
            (void)unlinkat(current, chain_name, AT_REMOVEDIR);
        }
        close(current);
    }
    (void)rmdir(root);
}

/* A chain deeper than the plan's 300 levels, whose full path is longer than
 * PATH_MAX, built with mkdirat. The walk keeps one descriptor per step rather
 * than one per level, so it removes the chain under a limit of 32. */
static int case_tree_deep_chain(const char *directory) {
    enter_sandbox(directory, "deep_chain");
    make_directory("chain");
    int current = open("chain", O_RDONLY | O_DIRECTORY);
    assert(current >= 0);
    for (int level = 0; level < CHAIN_DEPTH; level++) {
        assert(mkdirat(current, chain_name, 0755) == 0);
        const int next = openat(current, chain_name, O_RDONLY | O_DIRECTORY);
        assert(next >= 0);
        assert(close(current) == 0);
        current = next;
    }
    const int bottom = openat(current, "bottom", O_WRONLY | O_CREAT | O_EXCL, 0644);
    assert(bottom >= 0);
    assert(close(bottom) == 0);
    assert(close(current) == 0);
    assert(CHAIN_DEPTH * (int)sizeof chain_name > PATH_MAX);
    struct rlimit limit;
    assert(getrlimit(RLIMIT_NOFILE, &limit) == 0);
    limit.rlim_cur = CHAIN_DESCRIPTOR_LIMIT;
    assert(setrlimit(RLIMIT_NOFILE, &limit) == 0);
    begin();
    const int64_t error = remove_tree("chain");
    if (error != 0) remove_chain_by_hand("chain");
    assert(error == 0);
    assert(!exists("chain"));
    assert(most_held <= DESCRIPTOR_BOUND);
    return 0;
}

/* macOS readdir can skip entries while the directory changes, so every name
 * of a directory is read before any is removed from it. */
static int case_tree_read_order(const char *directory) {
    enter_sandbox(directory, "read_order");
    make_tree("tree");
    char path[PATH_BYTES];
    for (int index = 0; index < 20; index++) {
        char name[NAME_BYTES];
        const int length = snprintf(name, sizeof name, "full/many-%02d", index);
        assert(length > 0 && length < NAME_BYTES);
        join(path, "tree", name);
        make_file(path);
    }
    begin();
    checking_read_order = 1;
    assert(remove_tree("tree") == 0);
    assert(!exists("tree"));
    return 0;
}

/* Linux refuses a directory with EISDIR and macOS with EPERM, so with EPERM
 * injected Linux runs macOS's path, entering each directory. */
static int case_tree_directory_eperm(const char *directory) {
    enter_sandbox(directory, "directory_eperm");
    make_tree("tree");
    begin();
    directory_unlink_error = EPERM;
    assert(remove_tree("tree") == 0);
    assert(!exists("tree"));
    return 0;
}

/* macOS refuses a mount point with EBUSY before any device check, so EBUSY
 * leads to the device check too, which stops the walk there. */
static int case_tree_mount_point_ebusy(const char *directory) {
    enter_sandbox(directory, "mount_point_ebusy");
    make_directory("tree");
    make_directory("tree/mounted");
    make_file("tree/mounted/kept");
    begin();
    directory_unlink_error = EBUSY;
    identity_change = (struct identity_change){"mounted", 0, DEVICE_CHANGE};
    assert(remove_tree("tree") == 11);
    assert(exists("tree/mounted/kept"));
    assert(calls[RMDIR_CALL] == 0);
    return 0;
}

/* EPERM for a file, which openat answers with ENOTDIR, keeps the unlink's
 * own failure: PermissionDenied. */
static int case_tree_file_eperm(const char *directory) {
    enter_sandbox(directory, "file_eperm");
    make_directory("tree");
    make_file("tree/protected");
    begin();
    refused_name = "protected";
    refused_error = EPERM;
    assert(remove_tree("tree") == 2);
    assert(exists("tree/protected"));
    return 0;
}

/* An entry another process removes first is no failure. */
static int case_tree_vanished_entry(const char *directory) {
    enter_sandbox(directory, "vanished_entry");
    make_tree("tree");
    begin();
    vanishing_name = "second";
    assert(remove_tree("tree") == 0);
    assert(!exists("tree"));
    /* A directory gone between the refused unlink and the openat. */
    make_directory("again");
    make_directory("again/child");
    begin();
    inject(OPENAT_CALL, 1, 1, ENOENT);
    assert(remove_tree("again") == 6);
    assert(is_directory("again/child"));
    assert(rmdir("again/child") == 0 && rmdir("again") == 0);
    return 0;
}

/* A child on another device is a mount point: nothing under it is removed. */
static int case_tree_child_device(const char *directory) {
    enter_sandbox(directory, "child_device");
    make_directory("tree");
    make_directory("tree/mounted");
    make_file("tree/mounted/kept");
    make_directory("tree/mounted/inner");
    begin();
    identity_change = (struct identity_change){"mounted", 0, DEVICE_CHANGE};
    assert(remove_tree("tree") == 11);
    assert(exists("tree/mounted/kept") && is_directory("tree/mounted/inner"));
    return 0;
}

/* The second `..` the walk opens is the climb from `child`, which reports
 * another inode, as when another process moved `child` elsewhere: the walk
 * stops before it follows `..` or removes anything more. */
static int case_tree_moved_directory(const char *directory) {
    enter_sandbox(directory, "moved_directory");
    make_directory("tree");
    make_directory("tree/child");
    make_file("tree/child/file");
    make_file("tree/child/other");
    begin();
    identity_change = (struct identity_change){"..", 1, INODE_CHANGE};
    assert(remove_tree("tree") == 14);
    assert(is_directory("tree/child"));
    assert(!exists("tree/child/file") && !exists("tree/child/other"));
    assert(calls[RMDIR_CALL] == 0 && directory_unlinks == 0);
    assert(rmdir("tree/child") == 0 && rmdir("tree") == 0);
    return 0;
}

/* An entry the walk never saw, as one created during the walk, leaves the
 * root not empty, and its rmdir fails. */
static int case_tree_hidden_entry(const char *directory) {
    enter_sandbox(directory, "hidden_entry");
    make_tree("tree");
    begin();
    hidden_name = "second";
    assert(remove_tree("tree") == 6);
    assert(exists("tree/second") && !exists("tree/file") && !exists("tree/full"));
    /* Hidden in a child, the climb's unlinkat is the one that fails. */
    make_directory("tree/child");
    make_file("tree/child/inner");
    make_file("tree/child/visible");
    begin();
    hidden_name = "inner";
    assert(remove_tree("tree") == 6);
    assert(exists("tree/child/inner") && !exists("tree/child/visible"));
    return 0;
}

static int case_tree_read_failures(const char *directory) {
    enter_sandbox(directory, "read_failures");
    make_tree("tree");
    begin();
    inject(READDIR_CALL, 2, 1, EIO);
    assert(remove_tree("tree") == -(int64_t)EIO);
    assert(calls[UNLINKAT_CALL] == 0);
    begin();
    inject(FDOPENDIR_CALL, 0, 1, EMFILE);
    assert(remove_tree("tree") == -(int64_t)EMFILE);
    begin();
    inject(FCNTL_CALL, 0, 1, EMFILE);
    assert(remove_tree("tree") == -(int64_t)EMFILE);
    /* In a child, after some of the root's entries are gone. */
    begin();
    inject(FDOPENDIR_CALL, 1, 1, ENOMEM);
    assert(remove_tree("tree") == -(int64_t)ENOMEM);
    begin();
    inject(FSTAT_CALL, 0, 1, EIO);
    assert(remove_tree("tree") == -(int64_t)EIO);
    /* RemoveTreeError lacks NoSpace, so the OS's own number arrives. */
    begin();
    inject(FSTAT_CALL, 0, 1, ENOSPC);
    assert(remove_tree("tree") == -(int64_t)ENOSPC);
    assert(is_directory("tree"));
    return 0;
}

/* Each retried call returns EINTR once, at each of its first positions in the
 * walk, and the removal still succeeds. The later positions reach a child's
 * fstat, the climb's openat of `..` and unlinkat with AT_REMOVEDIR. A position
 * past the walk's last call of that kind injects nothing. */
enum { INTERRUPTED_POSITIONS = 12 };
static int case_tree_interrupted(const char *directory) {
    enter_sandbox(directory, "interrupted");
    const enum call retried[] = {OPEN_CALL, OPENAT_CALL, UNLINKAT_CALL, FSTAT_CALL, READDIR_CALL, FCNTL_CALL};
    for (size_t index = 0; index < sizeof retried / sizeof retried[0]; index++) {
        for (int skip = 0; skip < INTERRUPTED_POSITIONS; skip++) {
            make_tree("tree");
            begin();
            inject(retried[index], skip, 1, EINTR);
            assert(remove_tree("tree") == 0);
            assert(!exists("tree"));
            assert(injections[retried[index]].failures == 0 || calls[retried[index]] <= skip);
        }
    }
    return 0;
}

/* A name that is not UTF-8 is removed by its bytes. macOS refuses to create
 * one, so there readdir returns it, and unlinkat must receive those bytes. */
static int case_tree_invalid_utf8_name(const char *directory) {
    enter_sandbox(directory, "invalid_utf8_name");
    static const char name[] = "invalid-\xff\xfe";
    make_directory("tree");
    char path[PATH_BYTES];
    join(path, "tree", name);
#ifdef __APPLE__
    FILE *refused = fopen(path, "wb");
    assert(refused == NULL && errno == EILSEQ);
    static const char *const crafted[] = {name, NULL};
    begin();
    crafted_names = crafted;
    crafted_remaining = crafted;
#else
    make_file(path);
    begin();
#endif
    assert(remove_tree("tree") == 0);
    assert(!exists("tree"));
    int received = 0;
    assert(received_name_count <= RECEIVED_NAME_SLOTS);
    for (int index = 0; index < received_name_count; index++) {
        if (memcmp(received_names[index], name, sizeof name) == 0) received++;
    }
    assert(received == 1);
    return 0;
}

/* Root may remove anything, so the suite leaves this case out as root. In a
 * parent without write permission, Linux refuses a directory with EACCES
 * before EISDIR, so the child survives untouched; macOS refuses it with
 * EPERM, so the walk empties the child before the parent refuses its rmdir. */
static int case_tree_permission(const char *directory) {
    assert(geteuid() != 0);
    enter_sandbox(directory, "permission");
    make_directory("tree");
    make_directory("tree/child");
    make_file("tree/child/file");
    assert(chmod("tree", 0555) == 0);
    begin();
    assert(remove_tree("tree") == 2);
    assert(is_directory("tree/child"));
#ifdef __APPLE__
    assert(!exists("tree/child/file"));
#else
    assert(exists("tree/child/file"));
#endif
    assert(chmod("tree", 0755) == 0);
    return 0;
}

/* The path is the parent, one '/', the prefix and six more bytes. */
static void expect_temporary(const struct blorp_string *made, const char *expected_start) {
    const size_t start = strlen(expected_start);
    assert((size_t)made->length == start + 6);
    assert(memcmp(made->bytes, expected_start, start) == 0);
    assert(memchr(made->bytes + start, '/', 6) == NULL);
    struct stat status;
    assert(lstat(made->bytes, &status) == 0);
    assert(S_ISDIR(status.st_mode));
    assert((status.st_mode & 07777) == 0700);
}

static struct blorp_string *temporary(const char *parent, const char *prefix) {
    struct blorp_string *made = NULL;
    assert(temporary_strings(string_of(parent), string_of(prefix), &made) == 0);
    return made;
}

static int case_temporary_created(const char *directory) {
    enter_sandbox(directory, "temporary_created");
    (void)umask(022);
    char working[PATH_BYTES], start[PATH_BYTES];
    assert(getcwd(working, sizeof working) != NULL);
    begin();
    struct blorp_string *first = temporary(working, "scratch-");
    struct blorp_string *second = temporary(working, "scratch-");
    join(start, working, "scratch-");
    expect_temporary(first, start);
    expect_temporary(second, start);
    assert(strcmp(first->bytes, second->bytes) != 0);
    assert(calls[MKDTEMP_CALL] == 2);
    /* A relative parent gives a relative path. */
    make_directory("relative");
    struct blorp_string *relative = temporary("relative", "r");
    expect_temporary(relative, "relative/r");
    /* An empty prefix is six bytes of name. */
    struct blorp_string *bare = temporary("relative", "");
    expect_temporary(bare, "relative/");
    /* A prefix that is not ASCII keeps its code points: two in "\303\251-". */
    struct blorp_string *accented = temporary("relative", "\303\251-");
    expect_temporary(accented, "relative/\303\251-");
    assert(accented->code_points == (int64_t)strlen("relative/") + 2 + 6);
    assert(rmdir(first->bytes) == 0 && rmdir(second->bytes) == 0 && rmdir(relative->bytes) == 0 && rmdir(bare->bytes) == 0);
    assert(rmdir(accented->bytes) == 0);
    blorp_string_release(first);
    blorp_string_release(second);
    blorp_string_release(relative);
    blorp_string_release(bare);
    blorp_string_release(accented);
    return 0;
}

static int case_temporary_trailing_slash(const char *directory) {
    enter_sandbox(directory, "temporary_trailing_slash");
    make_directory("parent");
    begin();
    struct blorp_string *made = temporary("parent/", "p");
    expect_temporary(made, "parent/p");
    assert(rmdir(made->bytes) == 0);
    blorp_string_release(made);
    return 0;
}

static int case_temporary_interrupted(const char *directory) {
    enter_sandbox(directory, "temporary_interrupted");
    begin();
    inject(MKDTEMP_CALL, 0, 1, EINTR);
    struct blorp_string *made = temporary(".", "i");
    expect_temporary(made, "./i");
    assert(calls[MKDTEMP_CALL] == 2);
    assert(rmdir(made->bytes) == 0);
    blorp_string_release(made);
    return 0;
}

/* The directory is always made directly in the parent. */
static int case_temporary_prefix_slash(const char *directory) {
    enter_sandbox(directory, "temporary_prefix_slash");
    make_directory("nested");
    begin();
    assert(temporary_failure(".", "nested/p") == -(int64_t)EINVAL);
    assert(temporary_failure(".", "/") == -(int64_t)EINVAL);
    assert(system_calls() == 0);
    return 0;
}

static int case_temporary_failures(const char *directory) {
    enter_sandbox(directory, "temporary_failures");
    make_file("file");
    begin();
    assert(temporary_failure("missing", "p") == 1);
    assert(temporary_failure("file", "p") == 4);
    begin();
    assert(temporary_failure("", "p") == 1);
    struct blorp_string *unused = NULL;
    assert(temporary_strings(nul_path("."), string_of("p"), &unused) == 12);
    assert(temporary_strings(string_of("."), nul_path("p"), &unused) == 12);
    assert(system_calls() == 0);
    /* AlreadyExists would describe the parent, which does exist. */
    begin();
    inject(MKDTEMP_CALL, 0, 1, EEXIST);
    assert(temporary_failure(".", "p") == -(int64_t)EEXIST);
    assert(calls[MKDTEMP_CALL] == 1);
    /* TemporaryDirectoryError lacks FileTooLarge, so the OS's own number arrives. */
    begin();
    inject(MKDTEMP_CALL, 0, 1, EFBIG);
    assert(temporary_failure(".", "p") == -(int64_t)EFBIG);
    return 0;
}

/* Root may write anywhere, so the suite leaves this case out as root. */
static int case_temporary_permission(const char *directory) {
    assert(geteuid() != 0);
    enter_sandbox(directory, "temporary_permission");
    make_directory("locked");
    assert(chmod("locked", 0555) == 0);
    begin();
    assert(temporary_failure("locked", "p") == 2);
    assert(chmod("locked", 0755) == 0);
    return 0;
}

static int child_case(int argc, char **argv) {
    if (argc != 3) return 2;
    const char *name = argv[1];
    const char *directory = argv[2];
    /* One allocation outside the cases, so that the strict accounting always
     * has something to balance. */
    blorp_string_release(string_of(name));
    if (strcmp(name, "tree_missing") == 0) return case_tree_missing(directory);
    if (strcmp(name, "tree_not_directories") == 0) return case_tree_not_directories(directory);
    if (strcmp(name, "tree_trailing_slashes") == 0) return case_tree_trailing_slashes(directory);
    if (strcmp(name, "tree_dot_refusals") == 0) return case_tree_dot_refusals(directory);
    if (strcmp(name, "tree_slash_root") == 0) return case_tree_slash_root(directory);
    if (strcmp(name, "tree_root_mount_point") == 0) return case_tree_root_mount_point(directory);
    if (strcmp(name, "tree_removed") == 0) return case_tree_removed(directory);
    if (strcmp(name, "tree_unsearchable_child") == 0) return case_tree_unsearchable_child(directory);
    if (strcmp(name, "tree_unopenable_child") == 0) return case_tree_unopenable_child(directory);
    if (strcmp(name, "tree_link_out") == 0) return case_tree_link_out(directory);
    if (strcmp(name, "tree_deep_chain") == 0) return case_tree_deep_chain(directory);
    if (strcmp(name, "tree_read_order") == 0) return case_tree_read_order(directory);
    if (strcmp(name, "tree_directory_eperm") == 0) return case_tree_directory_eperm(directory);
    if (strcmp(name, "tree_mount_point_ebusy") == 0) return case_tree_mount_point_ebusy(directory);
    if (strcmp(name, "tree_file_eperm") == 0) return case_tree_file_eperm(directory);
    if (strcmp(name, "tree_vanished_entry") == 0) return case_tree_vanished_entry(directory);
    if (strcmp(name, "tree_child_device") == 0) return case_tree_child_device(directory);
    if (strcmp(name, "tree_moved_directory") == 0) return case_tree_moved_directory(directory);
    if (strcmp(name, "tree_hidden_entry") == 0) return case_tree_hidden_entry(directory);
    if (strcmp(name, "tree_read_failures") == 0) return case_tree_read_failures(directory);
    if (strcmp(name, "tree_interrupted") == 0) return case_tree_interrupted(directory);
    if (strcmp(name, "tree_invalid_utf8_name") == 0) return case_tree_invalid_utf8_name(directory);
    if (strcmp(name, "tree_permission") == 0) return case_tree_permission(directory);
    if (strcmp(name, "temporary_created") == 0) return case_temporary_created(directory);
    if (strcmp(name, "temporary_trailing_slash") == 0) return case_temporary_trailing_slash(directory);
    if (strcmp(name, "temporary_interrupted") == 0) return case_temporary_interrupted(directory);
    if (strcmp(name, "temporary_prefix_slash") == 0) return case_temporary_prefix_slash(directory);
    if (strcmp(name, "temporary_failures") == 0) return case_temporary_failures(directory);
    if (strcmp(name, "temporary_permission") == 0) return case_temporary_permission(directory);
    return 2;
}

int main(int argc, char **argv) {
    blorp_memory_start();
    return blorp_memory_finish(child_case(argc, argv));
}
