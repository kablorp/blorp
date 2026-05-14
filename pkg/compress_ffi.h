// compress_ffi.h - zlib compression wrapper for blorp FFI
// Provides: deflate, inflate, gzip compress/decompress
// Requires: -lz (zlib)
// Note: Forward declarations must match runtime.c struct layouts.

#ifndef BLORP_COMPRESS_FFI_H
#define BLORP_COMPRESS_FFI_H

#include <zlib.h>
#include <string.h>
#include <stdlib.h>
#include <limits.h>

// Forward declarations from blorp runtime
extern blorp_Result* blorp_result_ok(void* value);
extern blorp_Result* blorp_result_err(void* value);
extern blorp_String* blorp_string_create(const char* cstr);
extern blorp_Bytes* blorp_bytes_new(long capacity);
extern void* blorp_retain(void* obj);

// Max decompression output (256MB) to prevent zip bombs
#define BLORP_MAX_DECOMPRESS_SIZE (256UL * 1024 * 1024)

// Helper: create a Result with release_mask set for RC inner values
static inline blorp_Result* result_ok_rc(void* value) {
    blorp_Result* r = blorp_result_ok(value);
    r->release_mask = 1UL;
    return r;
}

static inline blorp_Result* result_err_rc(void* value) {
    blorp_Result* r = blorp_result_err(value);
    r->release_mask = 1UL;
    return r;
}

// Helper: create a Bytes from raw data
static inline blorp_Bytes* bytes_from_raw(const unsigned char* data, long len) {
    blorp_Bytes* b = blorp_bytes_new(len);
    if (len > 0 && data) {
        memcpy(b->data, data, (size_t)len);
        b->len = len;
    }
    return b;
}

// Deflate (raw deflate, no gzip header)
static inline blorp_Result* blorp_deflate_compress(blorp_Bytes* input) {
    if (!input || input->len == 0) {
        return result_ok_rc((void*)blorp_bytes_new(0));
    }
    uLongf dest_len = compressBound((uLong)input->len);
    unsigned char* dest = (unsigned char*)malloc(dest_len);
    if (!dest) {
        return result_err_rc((void*)blorp_string_create("out of memory"));
    }
    int rc = compress2(dest, &dest_len, input->data, (uLong)input->len, Z_DEFAULT_COMPRESSION);
    if (rc != Z_OK) {
        free(dest);
        return result_err_rc((void*)blorp_string_create("deflate failed"));
    }
    blorp_Bytes* result = bytes_from_raw(dest, (long)dest_len);
    free(dest);
    return result_ok_rc((void*)result);
}

// Inflate (raw inflate, reverses deflate)
static inline blorp_Result* blorp_deflate_decompress(blorp_Bytes* input) {
    if (!input || input->len == 0) {
        return result_ok_rc((void*)blorp_bytes_new(0));
    }
    uLongf dest_len = (uLong)input->len * 4;
    if (dest_len < 256) dest_len = 256;
    unsigned char* dest = (unsigned char*)malloc(dest_len);
    if (!dest) {
        return result_err_rc((void*)blorp_string_create("out of memory"));
    }
    int rc;
    while (1) {
        uLongf try_len = dest_len;
        rc = uncompress(dest, &try_len, input->data, (uLong)input->len);
        if (rc == Z_OK) {
            dest_len = try_len;
            break;
        } else if (rc == Z_BUF_ERROR) {
            dest_len *= 2;
            if (dest_len > BLORP_MAX_DECOMPRESS_SIZE) {
                free(dest);
                return result_err_rc((void*)blorp_string_create("decompressed size exceeds limit"));
            }
            unsigned char* new_dest = (unsigned char*)realloc(dest, dest_len);
            if (!new_dest) {
                free(dest);
                return result_err_rc((void*)blorp_string_create("out of memory"));
            }
            dest = new_dest;
        } else {
            free(dest);
            return result_err_rc((void*)blorp_string_create("inflate failed"));
        }
    }
    blorp_Bytes* result = bytes_from_raw(dest, (long)dest_len);
    free(dest);
    return result_ok_rc((void*)result);
}

// Gzip compress (with gzip header/trailer)
static inline blorp_Result* blorp_gzip_compress(blorp_Bytes* input) {
    if (!input || input->len == 0) {
        return result_ok_rc((void*)blorp_bytes_new(0));
    }
    if (input->len > (long)UINT_MAX) {
        return result_err_rc((void*)blorp_string_create("input too large (>4GB)"));
    }
    z_stream strm;
    memset(&strm, 0, sizeof(strm));
    // windowBits 15 + 16 = gzip format
    int rc = deflateInit2(&strm, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY);
    if (rc != Z_OK) {
        return result_err_rc((void*)blorp_string_create("gzip init failed"));
    }
    uLongf dest_len = deflateBound(&strm, (uLong)input->len);
    unsigned char* dest = (unsigned char*)malloc(dest_len);
    if (!dest) {
        deflateEnd(&strm);
        return result_err_rc((void*)blorp_string_create("out of memory"));
    }
    strm.next_in = input->data;
    strm.avail_in = (uInt)input->len;
    strm.next_out = dest;
    strm.avail_out = (uInt)dest_len;
    rc = deflate(&strm, Z_FINISH);
    if (rc != Z_STREAM_END) {
        free(dest);
        deflateEnd(&strm);
        return result_err_rc((void*)blorp_string_create("gzip compress failed"));
    }
    long written = (long)strm.total_out;
    deflateEnd(&strm);
    blorp_Bytes* result = bytes_from_raw(dest, written);
    free(dest);
    return result_ok_rc((void*)result);
}

// Gzip decompress
static inline blorp_Result* blorp_gzip_decompress(blorp_Bytes* input) {
    if (!input || input->len == 0) {
        return result_ok_rc((void*)blorp_bytes_new(0));
    }
    if (input->len > (long)UINT_MAX) {
        return result_err_rc((void*)blorp_string_create("input too large (>4GB)"));
    }
    z_stream strm;
    memset(&strm, 0, sizeof(strm));
    // windowBits 15 + 32 = auto-detect gzip/zlib format
    int rc = inflateInit2(&strm, 15 + 32);
    if (rc != Z_OK) {
        return result_err_rc((void*)blorp_string_create("gzip init failed"));
    }
    uLongf dest_len = (uLong)input->len * 4;
    if (dest_len < 256) dest_len = 256;
    unsigned char* dest = (unsigned char*)malloc(dest_len);
    if (!dest) {
        inflateEnd(&strm);
        return result_err_rc((void*)blorp_string_create("out of memory"));
    }
    strm.next_in = input->data;
    strm.avail_in = (uInt)input->len;
    while (1) {
        strm.next_out = dest + strm.total_out;
        strm.avail_out = (uInt)(dest_len - strm.total_out);
        rc = inflate(&strm, Z_NO_FLUSH);
        if (rc == Z_STREAM_END) {
            break;
        } else if (rc == Z_OK || rc == Z_BUF_ERROR) {
            if (strm.avail_out == 0) {
                dest_len *= 2;
                if (dest_len > BLORP_MAX_DECOMPRESS_SIZE) {
                    free(dest);
                    inflateEnd(&strm);
                    return result_err_rc((void*)blorp_string_create("decompressed size exceeds limit"));
                }
                unsigned char* new_dest = (unsigned char*)realloc(dest, dest_len);
                if (!new_dest) {
                    free(dest);
                    inflateEnd(&strm);
                    return result_err_rc((void*)blorp_string_create("out of memory"));
                }
                dest = new_dest;
            } else {
                free(dest);
                inflateEnd(&strm);
                return result_err_rc((void*)blorp_string_create("gzip decompress failed"));
            }
        } else {
            free(dest);
            inflateEnd(&strm);
            return result_err_rc((void*)blorp_string_create("gzip decompress failed"));
        }
    }
    long written = (long)strm.total_out;
    inflateEnd(&strm);
    blorp_Bytes* result = bytes_from_raw(dest, written);
    free(dest);
    return result_ok_rc((void*)result);
}

#endif // BLORP_COMPRESS_FFI_H
