typedef struct {
    int first;
    long count;
    int second;
    long total;
} LayoutForeignMixed;

LayoutForeignMixed blorp_layout_foreign_identity_impl(LayoutForeignMixed value) {
    return value;
}

static long blorp_layout_next_expected = 0;

int blorp_layout_bool_identity_impl(int value) {
    return value;
}

int blorp_layout_ordered_flag(long expected) {
    int is_ordered = expected == blorp_layout_next_expected;
    blorp_layout_next_expected += 1;
    return is_ordered;
}

long blorp_layout_ordered_count(long expected) {
    int is_ordered = expected == blorp_layout_next_expected;
    blorp_layout_next_expected += 1;
    return is_ordered ? 42 : 0;
}
