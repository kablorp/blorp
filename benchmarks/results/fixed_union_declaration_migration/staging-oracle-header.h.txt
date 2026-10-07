#ifndef BLORP_FIELDLESS_UNION_SCALAR_BRIDGE_H
#define BLORP_FIELDLESS_UNION_SCALAR_BRIDGE_H

/* The existing fieldless scalar ABI uses C long and declaration-order tags. */
static inline long bridge_scalar_tag(long value) {
    return value;
}

#endif
