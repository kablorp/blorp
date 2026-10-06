#ifndef BLORP_TEST_FFI_BYTES_MUTATION_HEADER_H
#define BLORP_TEST_FFI_BYTES_MUTATION_HEADER_H

static inline long ffi_mutate_first_byte(blorp_Bytes* bytes) {
    if (bytes && bytes->len > 0) {
        bytes->data[0] = 90;
    }
    return bytes ? bytes->len : 0;
}

#endif
