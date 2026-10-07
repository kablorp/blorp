#ifndef BLORP_TEST_USER_UNION_WIRE_ADAPTER_FFI_H
#define BLORP_TEST_USER_UNION_WIRE_ADAPTER_FFI_H

/* Independent external contract: these numbers do not come from source order. */
enum { BLORP_WIRE_COLOR_RED = 0, BLORP_WIRE_COLOR_BLUE = 1 };

/* Native inbound oracle cases: red, blue, below range, above range. */
static inline long blorp_wire_color_test_tag(long case_index) {
    switch (case_index) {
        case 0: return BLORP_WIRE_COLOR_RED;
        case 1: return BLORP_WIRE_COLOR_BLUE;
        case 2: return -1;
        default: return 2;
    }
}

static inline long blorp_wire_color_identity_impl(long tag) {
    return tag;
}

static inline long blorp_wire_color_is_red_impl(long tag) {
    return tag == BLORP_WIRE_COLOR_RED;
}

static inline long blorp_wire_color_is_blue_impl(long tag) {
    return tag == BLORP_WIRE_COLOR_BLUE;
}

#define BLORP_WIRE_COLOR_CALL(function, tag) \
    ({ \
        _Static_assert(sizeof(tag) == sizeof(long), \
            "wire tag arguments must retain C long storage"); \
        function(tag); \
    })

#define blorp_wire_color_identity(tag) \
    BLORP_WIRE_COLOR_CALL(blorp_wire_color_identity_impl, tag)
#define blorp_wire_color_is_red(tag) \
    BLORP_WIRE_COLOR_CALL(blorp_wire_color_is_red_impl, tag)
#define blorp_wire_color_is_blue(tag) \
    BLORP_WIRE_COLOR_CALL(blorp_wire_color_is_blue_impl, tag)

#endif
