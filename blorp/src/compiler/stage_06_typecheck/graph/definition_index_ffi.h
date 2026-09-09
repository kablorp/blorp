#ifndef BLORP_COMPILER_DEFINITION_INDEX_FFI_H
#define BLORP_COMPILER_DEFINITION_INDEX_FFI_H

#include <stdbool.h>

static inline bool blorp_compiler_definition_tables_are_same_allocation(
    const void* left,
    const void* right
) {
    return left == right;
}

#endif
