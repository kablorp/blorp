#ifndef BLORP_TEST_COMPILER_RECORD_LAYOUT_FFI_H
#define BLORP_TEST_COMPILER_RECORD_LAYOUT_FFI_H

#define blorp_layout_foreign_identity(value) \
    ({ \
        extern __typeof__(value) blorp_layout_foreign_identity_impl(__typeof__(value)); \
        blorp_layout_foreign_identity_impl(value); \
    })

#define blorp_layout_bool_identity(value) \
    ({ \
        extern __typeof__(value) blorp_layout_bool_identity_impl(__typeof__(value)); \
        blorp_layout_bool_identity_impl(value); \
    })

#define blorp_layout_foreign_heap_flag(value) \
    ({ \
        _Static_assert(sizeof((value)->flag) == sizeof(int), \
            "foreign heap Bool fields must retain C int storage"); \
        (value)->flag; \
    })

int blorp_layout_ordered_flag(long expected);

#endif
