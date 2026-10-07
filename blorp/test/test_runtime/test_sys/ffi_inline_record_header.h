/* A foreign function over a fixed record that Blorp stores inline. At the
 * foreign boundary the record keeps the managed layout: an object header
 * followed by the fields, in an object the callee may read and the caller
 * releases; a returned record is a fresh object the caller owns. */
#include <string.h>

typedef struct {
    blorp_Object header;
    double x;
    double y;
} ffi_inline_point;

static void* ffi_inline_point_swap(void* point) {
    ffi_inline_point* in = (ffi_inline_point*)point;
    ffi_inline_point* out = (ffi_inline_point*)blorp_alloc(sizeof(ffi_inline_point));
    out->x = in->y;
    out->y = in->x;
    return out;
}

static double ffi_inline_point_sum(void* point) {
    ffi_inline_point* in = (ffi_inline_point*)point;
    return in->x + in->y;
}
