typedef struct {
    int first;
    long count;
    int second;
    long total;
} LayoutForeignMixed;

LayoutForeignMixed blorp_layout_foreign_identity_impl(LayoutForeignMixed value) {
    return value;
}

int blorp_layout_bool_identity_impl(int value) {
    return value;
}

int blorp_layout_ordered_flag(long expected) {
    static long next_expected = 0;
    int is_ordered = expected == next_expected;
    next_expected += 1;
    return is_ordered;
}
