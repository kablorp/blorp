#ifndef BLORP_COMPILER_CLI_OUTPUT_H
#define BLORP_COMPILER_CLI_OUTPUT_H

#include <errno.h>
#include <limits.h>
#include <unistd.h>

static inline long blorp_compiler_cli_write_all(
    long descriptor,
    const blorp_Bytes* output
) {
    if (!output || output->len < 0) return 0;
    long offset = 0;
    while (offset < output->len) {
        long remaining = output->len - offset;
        size_t count = (size_t)(remaining > SSIZE_MAX ? SSIZE_MAX : remaining);
        ssize_t written = write(
            (int)descriptor,
            output->data + offset,
            count
        );
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) return 0;
        offset += (long)written;
    }
    return 1;
}

#endif
