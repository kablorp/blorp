#ifndef BLORP_COMPILER_INDEXED_GRAPH_FFI_H
#define BLORP_COMPILER_INDEXED_GRAPH_FFI_H

#include <stdbool.h>

/*
 * Allocation identity is only a fast path. Source-level graph compatibility
 * falls back to exact semantic comparison, so correctness never depends on
 * whether an optimizer shares or eliminates equivalent allocations.
 */
static inline bool blorp_compiler_indexed_graphs_are_same_allocation(
    const void* left,
    const void* right
) {
    return left == right;
}

#endif
