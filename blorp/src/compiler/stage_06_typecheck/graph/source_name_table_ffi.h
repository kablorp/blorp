#ifndef BLORP_COMPILER_SOURCE_NAME_TABLE_FFI_H
#define BLORP_COMPILER_SOURCE_NAME_TABLE_FFI_H

#include <stdbool.h>

static inline bool blorp_compiler_source_name_tables_are_same_allocation(
    const void* left,
    const void* right
) {
    return left == right;
}

#endif
