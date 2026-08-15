#include "lsp_native_runtime.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>

#define BLORP_FIBER_STACK_SIZE_ENVIRONMENT_VARIABLE "BLORP_FIBER_STACK_SIZE"
// Full prelude typechecking exceeds 512 KiB on macOS. Keep twice the measured
// passing minimum so platform and sanitizer frames do not consume the margin.
#define BLORP_COMPILER_FIBER_STACK_MINIMUM_BYTES (2L * 1024L * 1024L)
#define BLORP_STACK_SIZE_DECIMAL_BUFFER_BYTES 32

long blorp_compiler_require_fiber_stack_size(void) {
    const char* configured = getenv(
        BLORP_FIBER_STACK_SIZE_ENVIRONMENT_VARIABLE);
    if (configured) {
        errno = 0;
        char* end = NULL;
        long parsed = strtol(configured, &end, 10);
        if (errno == 0 && end != configured && *end == '\0' &&
            parsed >= BLORP_COMPILER_FIBER_STACK_MINIMUM_BYTES) {
            return 1;
        }
    }

    char encoded[BLORP_STACK_SIZE_DECIMAL_BUFFER_BYTES];
    int length = snprintf(
        encoded,
        sizeof(encoded),
        "%ld",
        BLORP_COMPILER_FIBER_STACK_MINIMUM_BYTES);
    if (length <= 0 || (size_t)length >= sizeof(encoded)) return 0;

    return setenv(
        BLORP_FIBER_STACK_SIZE_ENVIRONMENT_VARIABLE, encoded, 1) == 0;
}

void blorp_compiler_lsp_exit_now(long status) {
    _Exit((int)status);
}
