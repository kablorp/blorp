#include "aggregate_runtime_test.h"

static void test_fresh_transfer(void) {
    struct blorp_string *child = blorp_int_to_string(INT64_C(42));
    const size_t child_id = runtime_test_allocation_id(child);
    blorp_r_0 root = blorp_record_make_0((struct blorp_r_0){
        .blorp_rf_0_0 = child
    });
    const size_t root_id = runtime_test_allocation_id(root);
    assert(child_id != root_id);
    assert(allocation_count == 2);
    assert(destruction_count == 0);
    assert(atomic_load(&root->references) == 1);
    assert(atomic_load(&child->references) == 1);
    assert(root->blorp_rf_0_0 == child);
    assert_text(root->blorp_rf_0_0, "42", 2);
    /* The fresh child obligation was transferred, not copied or retained. */
    blorp_record_drop_0(root);
    assert_frees(root_id, 1);
    assert_frees(child_id, 1);
}

static void test_root_retain(void) {
    struct blorp_string *child = blorp_int_to_string(INT64_C(7));
    const size_t child_id = runtime_test_allocation_id(child);
    blorp_r_0 root = blorp_record_make_0((struct blorp_r_0){
        .blorp_rf_0_0 = child
    });
    const size_t root_id = runtime_test_allocation_id(root);
    blorp_record_dup_0(root);
    assert(atomic_load(&root->references) == 2);
    assert(atomic_load(&child->references) == 1);
    assert(allocation_count == 2);
    assert(destruction_count == 0);
    blorp_record_drop_0(root);
    blorp_record_drop_0(root);
    assert_frees(root_id, 1);
    assert_frees(child_id, 1);
}

static void test_nonfinal_release(void) {
    struct blorp_string *child = blorp_int_to_string(INT64_C(-42));
    const size_t child_id = runtime_test_allocation_id(child);
    blorp_r_0 root = blorp_record_make_0((struct blorp_r_0){
        .blorp_rf_0_0 = child
    });
    const size_t root_id = runtime_test_allocation_id(root);
    blorp_record_dup_0(root);
    blorp_record_drop_0(root);
    assert(atomic_load(&root->references) == 1);
    assert(atomic_load(&child->references) == 1);
    assert_frees(root_id, 0);
    assert_frees(child_id, 0);
    assert(destruction_count == 0);
    assert(root->blorp_rf_0_0 == child);
    assert_text(root->blorp_rf_0_0, "-42", 3);
    blorp_record_drop_0(root);
    assert_frees(root_id, 1);
    assert_frees(child_id, 1);
}

static void test_final_release(void) {
    struct blorp_string *first = blorp_int_to_string(INT64_C(7));
    const size_t first_id = runtime_test_allocation_id(first);
    struct blorp_string *second = blorp_int_to_string(INT64_C(-42));
    const size_t second_id = runtime_test_allocation_id(second);
    blorp_r_1 root = blorp_record_make_1((struct blorp_r_1){
        .blorp_rf_1_0 = first,
        .blorp_rf_1_1 = second
    });
    const size_t root_id = runtime_test_allocation_id(root);
    assert(first_id != second_id);
    assert(first_id != root_id);
    assert(second_id != root_id);
    assert(allocation_count == 3);
    assert(destruction_count == 0);
    assert_text(root->blorp_rf_1_0, "7", 1);
    assert_text(root->blorp_rf_1_1, "-42", 3);
    blorp_record_drop_1(root);
    /* Only numeric observation IDs are used after final release. */
    assert_frees(first_id, 1);
    assert_frees(second_id, 1);
    assert_frees(root_id, 1);
    assert(destruction_count == 3);
}

static void test_independent_child(void) {
    struct blorp_string *child = blorp_int_to_string(INT64_C(42));
    const size_t child_id = runtime_test_allocation_id(child);
    blorp_r_0 root = blorp_record_make_0((struct blorp_r_0){
        .blorp_rf_0_0 = child
    });
    const size_t root_id = runtime_test_allocation_id(root);
    struct blorp_string *escaped = root->blorp_rf_0_0;
    blorp_string_retain(escaped);
    assert(atomic_load(&escaped->references) == 2);
    blorp_record_drop_0(root);
    assert_frees(root_id, 1);
    assert_frees(child_id, 0);
    assert(destruction_count == 1);
    assert(atomic_load(&escaped->references) == 1);
    assert_text(escaped, "42", 2);
    blorp_string_release(escaped);
    assert_frees(child_id, 1);
}

static void test_repeated_pointer(void) {
    struct blorp_string *child = blorp_int_to_string(INT64_C(42));
    const size_t child_id = runtime_test_allocation_id(child);
    /* Each stored slot receives one independently owned obligation. */
    blorp_string_retain(child);
    blorp_r_1 root = blorp_record_make_1((struct blorp_r_1){
        .blorp_rf_1_0 = child,
        .blorp_rf_1_1 = child
    });
    const size_t root_id = runtime_test_allocation_id(root);
    assert(allocation_count == 2);
    assert(atomic_load(&root->references) == 1);
    assert(atomic_load(&child->references) == 2);
    assert(root->blorp_rf_1_0 == root->blorp_rf_1_1);
    assert_text(root->blorp_rf_1_0, "42", 2);
    assert_text(root->blorp_rf_1_1, "42", 2);
    blorp_record_drop_1(root);
    assert_frees(root_id, 1);
    assert_frees(child_id, 1);
    assert(destruction_count == 2);
}

static void test_nested_lifetime(void) {
    struct blorp_string *text = blorp_int_to_string(INT64_C(42));
    const size_t text_id = runtime_test_allocation_id(text);
    blorp_r_0 child = blorp_record_make_0((struct blorp_r_0){
        .blorp_rf_0_0 = text
    });
    const size_t child_id = runtime_test_allocation_id(child);
    blorp_r_2 root = blorp_record_make_2((struct blorp_r_2){
        .blorp_rf_2_0 = child
    });
    const size_t root_id = runtime_test_allocation_id(root);
    assert(allocation_count == 3);
    blorp_record_dup_2(root);
    assert(atomic_load(&root->references) == 2);
    assert(atomic_load(&child->references) == 1);
    assert(atomic_load(&text->references) == 1);
    /* Acquire the child root while its parent is still live. */
    blorp_r_0 escaped = root->blorp_rf_2_0;
    blorp_record_dup_0(escaped);
    assert(atomic_load(&child->references) == 2);
    blorp_record_drop_2(root);
    assert_frees(root_id, 0);
    assert_frees(child_id, 0);
    assert_frees(text_id, 0);
    assert(atomic_load(&root->references) == 1);
    assert(atomic_load(&child->references) == 2);
    blorp_record_drop_2(root);
    assert_frees(root_id, 1);
    assert_frees(child_id, 0);
    assert_frees(text_id, 0);
    assert(atomic_load(&escaped->references) == 1);
    assert(atomic_load(&escaped->blorp_rf_0_0->references) == 1);
    assert_text(escaped->blorp_rf_0_0, "42", 2);
    blorp_record_drop_0(escaped);
    assert_frees(child_id, 1);
    assert_frees(text_id, 1);
    assert(destruction_count == 3);
}

static void test_union_active(void) {
    struct blorp_string *child = blorp_int_to_string(INT64_C(42));
    const size_t child_id = runtime_test_allocation_id(child);
    blorp_r_3 root = blorp_record_make_3((struct blorp_r_3){
        .blorp_rf_3_0 = { .tag = blorp_v_0_0, .payload.blorp_up_0.blorp_uf_0 = child }
    });
    const size_t root_id = runtime_test_allocation_id(root);
    assert(atomic_load(&child->references) == 1);
    blorp_record_dup_3(root);
    assert(atomic_load(&root->references) == 2);
    assert(atomic_load(&child->references) == 1);
    blorp_record_drop_3(root);
    assert_frees(root_id, 0);
    assert_frees(child_id, 0);
    assert_text(root->blorp_rf_3_0.payload.blorp_up_0.blorp_uf_0, "42", 2);
    blorp_record_drop_3(root);
    assert_frees(root_id, 1);
    assert_frees(child_id, 1);
}

static void test_union_inactive(void) {
    struct blorp_string *unowned = blorp_int_to_string(INT64_C(42));
    const size_t child_id = runtime_test_allocation_id(unowned);
    /* The inactive storage has a live external pointer, not an obligation. */
    blorp_r_3 root = blorp_record_make_3((struct blorp_r_3){
        .blorp_rf_3_0 = { .tag = blorp_v_0_1, .payload.blorp_up_0.blorp_uf_0 = unowned }
    });
    const size_t root_id = runtime_test_allocation_id(root);
    blorp_record_dup_3(root);
    blorp_record_drop_3(root);
    blorp_record_drop_3(root);
    assert_frees(root_id, 1);
    assert_frees(child_id, 0);
    assert(atomic_load(&unowned->references) == 1);
    assert_text(unowned, "42", 2);
    blorp_string_release(unowned);
    assert_frees(child_id, 1);
}

static void test_union_escape(void) {
    struct blorp_string *child = blorp_int_to_string(INT64_C(42));
    const size_t child_id = runtime_test_allocation_id(child);
    blorp_r_3 root = blorp_record_make_3((struct blorp_r_3){
        .blorp_rf_3_0 = { .tag = blorp_v_0_0, .payload.blorp_up_0.blorp_uf_0 = child }
    });
    const size_t root_id = runtime_test_allocation_id(root);
    struct blorp_u_0 escaped = root->blorp_rf_3_0;
    blorp_union_dup_0(escaped);
    assert(atomic_load(&child->references) == 2);
    blorp_record_drop_3(root);
    assert_frees(root_id, 1);
    assert_frees(child_id, 0);
    assert(atomic_load(&escaped.payload.blorp_up_0.blorp_uf_0->references) == 1);
    assert_text(escaped.payload.blorp_up_0.blorp_uf_0, "42", 2);
    blorp_union_drop_0(escaped);
    assert_frees(child_id, 1);
}

static struct blorp_l_0_s *make_list(void) {
    char first[] = "first";
    char second[] = "second";
    char *arguments[] = { first, second };
    return blorp_list_from_argv(2, arguments);
}

static void test_list_transfer(void) {
    struct blorp_l_0_s *child = make_list();
    const size_t list_id = runtime_test_allocation_id(child);
    const size_t first_id = runtime_test_allocation_id(child->values[0]);
    const size_t second_id = runtime_test_allocation_id(child->values[1]);
    blorp_r_4 root = blorp_record_make_4((struct blorp_r_4){
        .blorp_rf_4_0 = child
    });
    const size_t root_id = runtime_test_allocation_id(root);
    assert(allocation_count == 4);
    assert(atomic_load(&root->references) == 1);
    assert(atomic_load(&child->references) == 1);
    assert(atomic_load(&child->values[0]->references) == 1);
    assert(atomic_load(&child->values[1]->references) == 1);
    assert(blorp_list_length_0_s(root->blorp_rf_4_0) == 2);
    assert_text(child->values[0], "first", 5);
    assert_text(child->values[1], "second", 6);
    blorp_record_drop_4(root);
    assert_frees(root_id, 1);
    assert_frees(list_id, 1);
    assert_frees(first_id, 1);
    assert_frees(second_id, 1);
}

static void test_list_retain(void) {
    struct blorp_l_0_s *child = make_list();
    const size_t list_id = runtime_test_allocation_id(child);
    const size_t first_id = runtime_test_allocation_id(child->values[0]);
    const size_t second_id = runtime_test_allocation_id(child->values[1]);
    blorp_r_4 root = blorp_record_make_4((struct blorp_r_4){
        .blorp_rf_4_0 = child
    });
    const size_t root_id = runtime_test_allocation_id(root);
    blorp_record_dup_4(root);
    assert(atomic_load(&root->references) == 2);
    assert(atomic_load(&child->references) == 1);
    assert(atomic_load(&child->values[0]->references) == 1);
    assert(atomic_load(&child->values[1]->references) == 1);
    assert(allocation_count == 4);
    assert(destruction_count == 0);
    blorp_record_drop_4(root);
    assert(atomic_load(&root->references) == 1);
    assert_frees(root_id, 0);
    assert_frees(list_id, 0);
    assert_frees(first_id, 0);
    assert_frees(second_id, 0);
    assert_text(root->blorp_rf_4_0->values[1], "second", 6);
    blorp_record_drop_4(root);
    assert_frees(root_id, 1);
    assert_frees(list_id, 1);
    assert_frees(first_id, 1);
    assert_frees(second_id, 1);
}

static void test_list_escape(void) {
    struct blorp_l_0_s *child = make_list();
    const size_t list_id = runtime_test_allocation_id(child);
    const size_t first_id = runtime_test_allocation_id(child->values[0]);
    const size_t second_id = runtime_test_allocation_id(child->values[1]);
    blorp_r_4 root = blorp_record_make_4((struct blorp_r_4){
        .blorp_rf_4_0 = child
    });
    const size_t root_id = runtime_test_allocation_id(root);
    struct blorp_l_0_s *escaped = root->blorp_rf_4_0;
    blorp_list_dup_0_s(escaped);
    assert(atomic_load(&escaped->references) == 2);
    assert(atomic_load(&escaped->values[0]->references) == 1);
    assert(atomic_load(&escaped->values[1]->references) == 1);
    blorp_record_drop_4(root);
    assert_frees(root_id, 1);
    assert_frees(list_id, 0);
    assert_frees(first_id, 0);
    assert_frees(second_id, 0);
    assert(atomic_load(&escaped->references) == 1);
    struct blorp_string *element = NULL;
    assert(blorp_list_get_0_s(escaped, 1, &element) == 1);
    assert(element == escaped->values[1]);
    assert(atomic_load(&element->references) == 2);
    struct blorp_string *missing = NULL;
    assert(blorp_list_get_0_s(escaped, 2, &missing) == 0);
    assert(missing == NULL);
    blorp_list_drop_0_s(escaped);
    assert_frees(list_id, 1);
    assert_frees(first_id, 1);
    assert_frees(second_id, 0);
    assert(atomic_load(&element->references) == 1);
    assert_text(element, "second", 6);
    blorp_string_release(element);
    assert_frees(second_id, 1);
}

static void test_list_empty(void) {
    struct blorp_l_0_s *child = blorp_list_from_argv(0, NULL);
    const size_t list_id = runtime_test_allocation_id(child);
    blorp_r_4 root = blorp_record_make_4((struct blorp_r_4){
        .blorp_rf_4_0 = child
    });
    const size_t root_id = runtime_test_allocation_id(root);
    assert(allocation_count == 2);
    assert(blorp_list_length_0_s(root->blorp_rf_4_0) == 0);
    struct blorp_string *missing = NULL;
    assert(blorp_list_get_0_s(root->blorp_rf_4_0, 0, &missing) == 0);
    assert(missing == NULL);
    blorp_record_drop_4(root);
    assert_frees(root_id, 1);
    assert_frees(list_id, 1);
}

static void test_void_root(void) {
    /* Void's existing canonical zero carrier owns no child allocation. */
    blorp_r_5 root = blorp_record_make_5((struct blorp_r_5){
        .blorp_rf_5_0 = (uint8_t)0
    });
    const size_t root_id = runtime_test_allocation_id(root);
    assert(allocation_count == 1);
    assert(root->blorp_rf_5_0 == (uint8_t)0);
    blorp_record_dup_5(root);
    blorp_record_drop_5(root);
    assert_frees(root_id, 0);
    blorp_record_drop_5(root);
    assert_frees(root_id, 1);
}

static void test_number_present(void) {
    blorp_r_6 root = blorp_record_make_6((struct blorp_r_6){
        .blorp_rf_6_0 = { .tag = blorp_v_1_0, .payload.blorp_up_0.blorp_uf_0 = INT64_C(42) }
    });
    const size_t root_id = runtime_test_allocation_id(root);
    assert(allocation_count == 1);
    assert(root->blorp_rf_6_0.payload.blorp_up_0.blorp_uf_0 == INT64_C(42));
    blorp_record_drop_6(root);
    assert_frees(root_id, 1);
}

static void test_number_absent(void) {
    blorp_r_6 root = blorp_record_make_6((struct blorp_r_6){
        .blorp_rf_6_0 = { .tag = blorp_v_1_1 }
    });
    const size_t root_id = runtime_test_allocation_id(root);
    assert(allocation_count == 1);
    assert(root->blorp_rf_6_0.tag == blorp_v_1_1);
    blorp_record_dup_6(root);
    blorp_record_drop_6(root);
    assert_frees(root_id, 0);
    blorp_record_drop_6(root);
    assert_frees(root_id, 1);
}

static void test_record_union_escape(void) {
    struct blorp_string *text = blorp_int_to_string(INT64_C(42));
    const size_t text_id = runtime_test_allocation_id(text);
    blorp_r_0 child = blorp_record_make_0((struct blorp_r_0){
        .blorp_rf_0_0 = text
    });
    const size_t child_id = runtime_test_allocation_id(child);
    blorp_r_7 root = blorp_record_make_7((struct blorp_r_7){
        .blorp_rf_7_0 = { .tag = blorp_v_2_0, .payload.blorp_up_0.blorp_uf_0 = child }
    });
    const size_t root_id = runtime_test_allocation_id(root);
    blorp_record_dup_7(root);
    assert(atomic_load(&root->references) == 2);
    assert(atomic_load(&child->references) == 1);
    assert(atomic_load(&text->references) == 1);
    blorp_record_drop_7(root);
    assert_frees(root_id, 0);
    assert_frees(child_id, 0);
    assert_frees(text_id, 0);
    struct blorp_u_2 escaped = root->blorp_rf_7_0;
    blorp_union_dup_2(escaped);
    assert(atomic_load(&child->references) == 2);
    assert(atomic_load(&text->references) == 1);
    blorp_record_drop_7(root);
    assert_frees(root_id, 1);
    assert_frees(child_id, 0);
    assert_frees(text_id, 0);
    assert(atomic_load(&escaped.payload.blorp_up_0.blorp_uf_0->references) == 1);
    assert_text(escaped.payload.blorp_up_0.blorp_uf_0->blorp_rf_0_0, "42", 2);
    blorp_union_drop_2(escaped);
    assert_frees(child_id, 1);
    assert_frees(text_id, 1);
}

static void test_record_union_inactive(void) {
    struct blorp_string *text = blorp_int_to_string(INT64_C(42));
    const size_t text_id = runtime_test_allocation_id(text);
    blorp_r_0 unowned = blorp_record_make_0((struct blorp_r_0){
        .blorp_rf_0_0 = text
    });
    const size_t child_id = runtime_test_allocation_id(unowned);
    blorp_r_7 root = blorp_record_make_7((struct blorp_r_7){
        .blorp_rf_7_0 = { .tag = blorp_v_2_1, .payload.blorp_up_0.blorp_uf_0 = unowned }
    });
    const size_t root_id = runtime_test_allocation_id(root);
    blorp_record_drop_7(root);
    assert_frees(root_id, 1);
    assert_frees(child_id, 0);
    assert_frees(text_id, 0);
    assert(atomic_load(&unowned->references) == 1);
    assert(atomic_load(&text->references) == 1);
    assert_text(unowned->blorp_rf_0_0, "42", 2);
    blorp_record_drop_0(unowned);
    assert_frees(child_id, 1);
    assert_frees(text_id, 1);
}

static void test_mixed_scalars(void) {
    struct blorp_string *text = blorp_int_to_string(INT64_C(42));
    const size_t text_id = runtime_test_allocation_id(text);
    blorp_r_8 root = blorp_record_make_8((struct blorp_r_8){
        .blorp_rf_8_0 = INT64_C(7),
        .blorp_rf_8_1 = 2.5,
        .blorp_rf_8_2 = text
    });
    const size_t root_id = runtime_test_allocation_id(root);
    assert(root->blorp_rf_8_0 == INT64_C(7));
    assert(root->blorp_rf_8_1 == 2.5);
    assert_text(root->blorp_rf_8_2, "42", 2);
    blorp_record_drop_8(root);
    assert_frees(root_id, 1);
    assert_frees(text_id, 1);
}

int main(int argc, char **argv) {
    assert(argc == 2);
    if (strcmp(argv[1], "fresh_transfer") == 0) {
        test_fresh_transfer();
    } else if (strcmp(argv[1], "root_retain") == 0) {
        test_root_retain();
    } else if (strcmp(argv[1], "nonfinal_release") == 0) {
        test_nonfinal_release();
    } else if (strcmp(argv[1], "final_release") == 0) {
        test_final_release();
    } else if (strcmp(argv[1], "independent_child") == 0) {
        test_independent_child();
    } else if (strcmp(argv[1], "repeated_pointer") == 0) {
        test_repeated_pointer();
    } else if (strcmp(argv[1], "nested_lifetime") == 0) {
        test_nested_lifetime();
    } else if (strcmp(argv[1], "union_active") == 0) {
        test_union_active();
    } else if (strcmp(argv[1], "union_inactive") == 0) {
        test_union_inactive();
    } else if (strcmp(argv[1], "union_escape") == 0) {
        test_union_escape();
    } else if (strcmp(argv[1], "list_transfer") == 0) {
        test_list_transfer();
    } else if (strcmp(argv[1], "list_retain") == 0) {
        test_list_retain();
    } else if (strcmp(argv[1], "list_escape") == 0) {
        test_list_escape();
    } else if (strcmp(argv[1], "list_empty") == 0) {
        test_list_empty();
    } else if (strcmp(argv[1], "void_root") == 0) {
        test_void_root();
    } else if (strcmp(argv[1], "number_present") == 0) {
        test_number_present();
    } else if (strcmp(argv[1], "number_absent") == 0) {
        test_number_absent();
    } else if (strcmp(argv[1], "record_union_escape") == 0) {
        test_record_union_escape();
    } else if (strcmp(argv[1], "record_union_inactive") == 0) {
        test_record_union_inactive();
    } else if (strcmp(argv[1], "mixed_scalars") == 0) {
        test_mixed_scalars();
    } else {
        fprintf(stderr, "unknown record runtime test: %s\n", argv[1]);
        return EXIT_FAILURE;
    }
    assert(allocation_count == destruction_count);
    for (size_t index = 0; index < allocation_count; index += 1) {
        assert_frees(index, 1);
    }
    return EXIT_SUCCESS;
}
