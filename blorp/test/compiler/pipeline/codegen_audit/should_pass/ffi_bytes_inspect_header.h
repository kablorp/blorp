#ifndef BLORP_TEST_CODEGEN_AUDIT_FFI_BYTES_INSPECT_HEADER_H
#define BLORP_TEST_CODEGEN_AUDIT_FFI_BYTES_INSPECT_HEADER_H

static inline long inspect_bytes(blorp_Bytes* bytes) {
    return bytes ? bytes->len : 0;
}

#endif
