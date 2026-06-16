#ifndef BLORP_TEST_MEMORY_FFI_OWNERSHIP_HEADER_H
#define BLORP_TEST_MEMORY_FFI_OWNERSHIP_HEADER_H

static inline long ffi_ownership_string_score(const char* text) {
    long total = 0;
    if (!text) return 0;
    for (const unsigned char* p = (const unsigned char*)text; *p; p++) {
        total += (long)*p;
    }
    return total;
}

static inline long ffi_ownership_bytes_score(blorp_Bytes* bytes) {
    if (!bytes) return 0;
    long total = bytes->len;
    for (long i = 0; i < bytes->len; i++) {
        total += (long)bytes->data[i];
    }
    return total;
}

#endif
