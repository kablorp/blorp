#include "aggregate_runtime_test.h"

static blorp_r_1 pair_root(struct blorp_string *first,
                           struct blorp_string *second) {
    return blorp_record_make_1((struct blorp_r_1){
        .blorp_rf_1_0 = {
            .tag = blorp_v_1_0,
            .payload.blorp_up_0 = { .blorp_uf_0 = first, .blorp_uf_1 = second }
        }
    });
}

static void test_distinct_cleanup(void) {
    struct blorp_string *first = blorp_int_to_string(INT64_C(7));
    struct blorp_string *second = blorp_int_to_string(INT64_C(42));
    const size_t first_id = runtime_test_allocation_id(first);
    const size_t second_id = runtime_test_allocation_id(second);
    blorp_r_1 root = pair_root(first, second);
    const size_t root_id = runtime_test_allocation_id(root);
    assert(first_id != second_id && first_id != root_id && second_id != root_id);
    assert(allocation_count == 3 && destruction_count == 0);
    assert(atomic_load(&first->references) == 1);
    assert(atomic_load(&second->references) == 1);
    assert(root->blorp_rf_1_0.payload.blorp_up_0.blorp_uf_0 == first);
    assert(root->blorp_rf_1_0.payload.blorp_up_0.blorp_uf_1 == second);
    blorp_record_drop_1(root);
    assert_frees(first_id, 1);
    assert_frees(second_id, 1);
    assert_frees(root_id, 1);
    assert(destruction_count == 3);
}

static void test_repeated_pointer(void) {
    struct blorp_string *child = blorp_int_to_string(INT64_C(42));
    const size_t child_id = runtime_test_allocation_id(child);
    /* Two owning slots require two references before transfer to the root. */
    blorp_string_retain(child);
    blorp_r_1 root = pair_root(child, child);
    const size_t root_id = runtime_test_allocation_id(root);
    assert(allocation_count == 2 && destruction_count == 0);
    assert(atomic_load(&child->references) == 2);
    assert(root->blorp_rf_1_0.payload.blorp_up_0.blorp_uf_0 == child);
    assert(root->blorp_rf_1_0.payload.blorp_up_0.blorp_uf_1 == child);
    blorp_record_drop_1(root);
    assert_frees(child_id, 1);
    assert_frees(root_id, 1);
    assert(destruction_count == 2);
}

static void test_first_escape(void) {
    struct blorp_string *first = blorp_int_to_string(INT64_C(7));
    struct blorp_string *second = blorp_int_to_string(INT64_C(42));
    const size_t first_id = runtime_test_allocation_id(first);
    const size_t second_id = runtime_test_allocation_id(second);
    blorp_r_1 root = pair_root(first, second);
    const size_t root_id = runtime_test_allocation_id(root);
    struct blorp_string *escaped = root->blorp_rf_1_0.payload.blorp_up_0.blorp_uf_0;
    assert_text(escaped, "7", 1);
    blorp_string_retain(escaped);
    blorp_record_drop_1(root);
    assert_frees(first_id, 0);
    assert_frees(second_id, 1);
    assert_frees(root_id, 1);
    assert(atomic_load(&escaped->references) == 1);
    assert_text(escaped, "7", 1);
    blorp_string_release(escaped);
    assert_frees(first_id, 1);
    assert(destruction_count == 3);
}

static void test_second_escape(void) {
    struct blorp_string *first = blorp_int_to_string(INT64_C(7));
    struct blorp_string *second = blorp_int_to_string(INT64_C(42));
    const size_t first_id = runtime_test_allocation_id(first);
    const size_t second_id = runtime_test_allocation_id(second);
    blorp_r_1 root = pair_root(first, second);
    const size_t root_id = runtime_test_allocation_id(root);
    struct blorp_string *escaped = root->blorp_rf_1_0.payload.blorp_up_0.blorp_uf_1;
    assert_text(escaped, "42", 2);
    blorp_string_retain(escaped);
    blorp_record_drop_1(root);
    assert_frees(first_id, 1);
    assert_frees(second_id, 0);
    assert_frees(root_id, 1);
    assert(atomic_load(&escaped->references) == 1);
    assert_text(escaped, "42", 2);
    blorp_string_release(escaped);
    assert_frees(second_id, 1);
    assert(destruction_count == 3);
}

static void test_nonfinal_release(void) {
    struct blorp_string *first = blorp_int_to_string(INT64_C(7));
    struct blorp_string *second = blorp_int_to_string(INT64_C(42));
    const size_t first_id = runtime_test_allocation_id(first);
    const size_t second_id = runtime_test_allocation_id(second);
    blorp_r_1 root = pair_root(first, second);
    const size_t root_id = runtime_test_allocation_id(root);
    blorp_record_dup_1(root);
    assert(atomic_load(&root->references) == 2);
    assert(atomic_load(&first->references) == 1);
    assert(atomic_load(&second->references) == 1);
    blorp_record_drop_1(root);
    assert(atomic_load(&root->references) == 1);
    assert(destruction_count == 0);
    assert_text(root->blorp_rf_1_0.payload.blorp_up_0.blorp_uf_0, "7", 1);
    assert_text(root->blorp_rf_1_0.payload.blorp_up_0.blorp_uf_1, "42", 2);
    blorp_record_drop_1(root);
    assert_frees(first_id, 1);
    assert_frees(second_id, 1);
    assert_frees(root_id, 1);
    assert(destruction_count == 3);
}

static void test_union_dup(void) {
    struct blorp_string *first = blorp_int_to_string(INT64_C(7));
    struct blorp_string *second = blorp_int_to_string(INT64_C(42));
    const size_t first_id = runtime_test_allocation_id(first);
    const size_t second_id = runtime_test_allocation_id(second);
    struct blorp_u_1 value = {
        .tag = blorp_v_1_0,
        .payload.blorp_up_0 = { .blorp_uf_0 = first, .blorp_uf_1 = second }
    };
    blorp_union_dup_1(value);
    assert(allocation_count == 2 && destruction_count == 0);
    assert(atomic_load(&first->references) == 2);
    assert(atomic_load(&second->references) == 2);
    blorp_union_drop_1(value);
    assert(atomic_load(&first->references) == 1);
    assert(atomic_load(&second->references) == 1);
    assert_text(first, "7", 1);
    assert_text(second, "42", 2);
    assert(destruction_count == 0);
    blorp_union_drop_1(value);
    assert_frees(first_id, 1);
    assert_frees(second_id, 1);
    assert(destruction_count == 2);
}

static void test_inactive(void) {
    struct blorp_string *first = blorp_int_to_string(INT64_C(7));
    struct blorp_string *second = blorp_int_to_string(INT64_C(42));
    const size_t first_id = runtime_test_allocation_id(first);
    const size_t second_id = runtime_test_allocation_id(second);
    blorp_r_1 root = blorp_record_make_1((struct blorp_r_1){
        .blorp_rf_1_0 = {
            .tag = blorp_v_1_4,
            .payload.blorp_up_0 = { .blorp_uf_0 = first, .blorp_uf_1 = second }
        }
    });
    const size_t root_id = runtime_test_allocation_id(root);
    blorp_union_dup_1(root->blorp_rf_1_0);
    blorp_union_drop_1(root->blorp_rf_1_0);
    blorp_record_drop_1(root);
    assert_frees(root_id, 1);
    assert_frees(first_id, 0);
    assert_frees(second_id, 0);
    assert(atomic_load(&first->references) == 1);
    assert(atomic_load(&second->references) == 1);
    assert_text(first, "7", 1);
    assert_text(second, "42", 2);
    blorp_string_release(first);
    blorp_string_release(second);
    assert(destruction_count == 3);
}

static void test_mixed(void) {
    struct blorp_string *text = blorp_int_to_string(INT64_C(42));
    const size_t text_id = runtime_test_allocation_id(text);
    blorp_r_1 root = blorp_record_make_1((struct blorp_r_1){
        .blorp_rf_1_0 = {
            .tag = blorp_v_1_1,
            .payload.blorp_up_1 = {
                .blorp_uf_0 = INT64_C(7), .blorp_uf_1 = 2.5,
                .blorp_uf_2 = text, .blorp_uf_3 = (uint8_t)0
            }
        }
    });
    const size_t root_id = runtime_test_allocation_id(root);
    assert(root->blorp_rf_1_0.payload.blorp_up_1.blorp_uf_0 == INT64_C(7));
    assert(root->blorp_rf_1_0.payload.blorp_up_1.blorp_uf_1 == 2.5);
    assert(root->blorp_rf_1_0.payload.blorp_up_1.blorp_uf_2 == text);
    assert(root->blorp_rf_1_0.payload.blorp_up_1.blorp_uf_3 == (uint8_t)0);
    blorp_union_dup_1(root->blorp_rf_1_0);
    assert(atomic_load(&text->references) == 2);
    blorp_union_drop_1(root->blorp_rf_1_0);
    assert(atomic_load(&text->references) == 1);
    assert(allocation_count == 2 && destruction_count == 0);
    blorp_record_drop_1(root);
    assert_frees(text_id, 1);
    assert_frees(root_id, 1);
    assert(destruction_count == 2);
}

static void test_nested(void) {
    struct blorp_string *first = blorp_int_to_string(INT64_C(7));
    struct blorp_string *second = blorp_int_to_string(INT64_C(42));
    const size_t first_id = runtime_test_allocation_id(first);
    const size_t second_id = runtime_test_allocation_id(second);
    blorp_r_0 child = blorp_record_make_0((struct blorp_r_0){ .blorp_rf_0_0 = first });
    const size_t child_id = runtime_test_allocation_id(child);
    blorp_r_1 root = blorp_record_make_1((struct blorp_r_1){
        .blorp_rf_1_0 = {
            .tag = blorp_v_1_2,
            .payload.blorp_up_2 = {
                .blorp_uf_0 = child,
                .blorp_uf_1 = { .tag = blorp_v_0_0,
                    .payload.blorp_up_0 = { .blorp_uf_0 = second } }
            }
        }
    });
    const size_t root_id = runtime_test_allocation_id(root);
    assert(allocation_count == 4 && destruction_count == 0);
    assert(root->blorp_rf_1_0.payload.blorp_up_2.blorp_uf_0 == child);
    assert_text(root->blorp_rf_1_0.payload.blorp_up_2.blorp_uf_1.payload.blorp_up_0.blorp_uf_0, "42", 2);
    blorp_record_dup_0(child);
    blorp_record_drop_1(root);
    assert_frees(root_id, 1);
    assert_frees(second_id, 1);
    assert_frees(child_id, 0);
    assert_frees(first_id, 0);
    assert(atomic_load(&child->references) == 1);
    assert_text(child->blorp_rf_0_0, "7", 1);
    blorp_record_drop_0(child);
    assert_frees(first_id, 1);
    assert_frees(child_id, 1);
    assert(destruction_count == 4);
}

static void test_repeated_roots(void) {
    struct blorp_string *text = blorp_int_to_string(INT64_C(42));
    const size_t text_id = runtime_test_allocation_id(text);
    blorp_r_0 child = blorp_record_make_0((struct blorp_r_0){ .blorp_rf_0_0 = text });
    const size_t child_id = runtime_test_allocation_id(child);
    blorp_record_dup_0(child);
    blorp_r_1 root = blorp_record_make_1((struct blorp_r_1){
        .blorp_rf_1_0 = { .tag = blorp_v_1_3,
            .payload.blorp_up_3 = { .blorp_uf_0 = child, .blorp_uf_1 = child } }
    });
    const size_t root_id = runtime_test_allocation_id(root);
    assert(atomic_load(&child->references) == 2);
    assert(atomic_load(&text->references) == 1);
    blorp_union_dup_1(root->blorp_rf_1_0);
    assert(atomic_load(&child->references) == 4);
    assert(atomic_load(&text->references) == 1);
    blorp_union_drop_1(root->blorp_rf_1_0);
    assert(atomic_load(&child->references) == 2);
    assert(destruction_count == 0);
    blorp_record_drop_1(root);
    assert_frees(root_id, 1);
    assert_frees(child_id, 1);
    assert_frees(text_id, 1);
    assert(destruction_count == 3);
}

static void test_void_only(void) {
    struct blorp_u_1 value = {
        .tag = blorp_v_1_5, .payload.blorp_up_5 = { .blorp_uf_0 = (uint8_t)0 }
    };
    assert(value.tag != blorp_v_1_4);
    blorp_union_dup_1(value);
    blorp_union_drop_1(value);
    blorp_r_1 root = blorp_record_make_1((struct blorp_r_1){ .blorp_rf_1_0 = value });
    const size_t root_id = runtime_test_allocation_id(root);
    assert(allocation_count == 1 && destruction_count == 0);
    blorp_record_drop_1(root);
    assert_frees(root_id, 1);
    assert(destruction_count == 1);
}

static void test_empty_only(void) {
    struct blorp_u_1 value = { .tag = blorp_v_1_4 };
    assert(value.tag != blorp_v_1_5);
    blorp_union_dup_1(value);
    blorp_union_drop_1(value);
    blorp_r_1 root = blorp_record_make_1((struct blorp_r_1){ .blorp_rf_1_0 = value });
    const size_t root_id = runtime_test_allocation_id(root);
    assert(allocation_count == 1 && destruction_count == 0);
    blorp_record_drop_1(root);
    assert_frees(root_id, 1);
    assert(destruction_count == 1);
}

int main(int argc, char **argv) {
    assert(argc == 2);
    if (strcmp(argv[1], "distinct_cleanup") == 0) test_distinct_cleanup();
    else if (strcmp(argv[1], "repeated_pointer") == 0) test_repeated_pointer();
    else if (strcmp(argv[1], "first_escape") == 0) test_first_escape();
    else if (strcmp(argv[1], "second_escape") == 0) test_second_escape();
    else if (strcmp(argv[1], "nonfinal_release") == 0) test_nonfinal_release();
    else if (strcmp(argv[1], "union_dup") == 0) test_union_dup();
    else if (strcmp(argv[1], "inactive") == 0) test_inactive();
    else if (strcmp(argv[1], "mixed") == 0) test_mixed();
    else if (strcmp(argv[1], "nested") == 0) test_nested();
    else if (strcmp(argv[1], "repeated_roots") == 0) test_repeated_roots();
    else if (strcmp(argv[1], "void_only") == 0) test_void_only();
    else if (strcmp(argv[1], "empty_only") == 0) test_empty_only();
    else assert(0 && "unknown runtime case");
    return 0;
}
