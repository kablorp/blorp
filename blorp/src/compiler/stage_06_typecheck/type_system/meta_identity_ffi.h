#ifndef BLORP_COMPILER_META_IDENTITY_FFI_H
#define BLORP_COMPILER_META_IDENTITY_FFI_H

#include <stdbool.h>

/*
 * Run tokens are allocated only by the impure compiler-host constructor.
 * Future session IDs must retain their token while comparisons are possible;
 * ARC then prevents address reuse during those comparisons.
 */
static inline bool blorp_compiler_run_tokens_are_same_allocation(
    const void* left,
    const void* right
) {
    return left == right;
}

/* Copies of a session retain one allocation. Reconstructed equal keys still
 * need the full value comparison in Blorp. */
static inline bool blorp_compiler_meta_sessions_are_same_allocation(
    const void* left,
    const void* right
) {
    return left == right;
}

#endif
