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

#define blorp_layout_enum_identity(value) \
    ({ \
        _Static_assert(sizeof(value) == sizeof(long), \
            "enum scalar arguments must retain C long storage"); \
        (value); \
    })

#define blorp_layout_foreign_heap_flag(value) \
    ({ \
        _Static_assert(sizeof((value)->first) == sizeof(int), \
            "foreign heap Bool fields must retain C int storage"); \
        _Static_assert(sizeof((value)->second) == sizeof(int), \
            "foreign heap Bool fields must retain C int storage"); \
        (value)->first && (value)->count == 42 && !(value)->second; \
    })

#define blorp_layout_foreign_heap_state(value) \
    ({ \
        _Static_assert(sizeof((value)->state) == sizeof(long), \
            "foreign heap enum fields must retain C long storage"); \
        (value)->state == 1 && (value)->count == 42; \
    })

int blorp_layout_ordered_flag(long expected);
long blorp_layout_ordered_count(long expected);

#endif
