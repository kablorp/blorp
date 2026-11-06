#include "aggregate_runtime_test.h"

static blorp_r_0 pair(struct blorp_string *left, struct blorp_string *right) {
    return blorp_record_make_0((struct blorp_r_0){
        .blorp_rf_0_0 = left,
        .blorp_rf_0_2 = right
    });
}

static void test_retain(void) {
    struct blorp_string *left = blorp_int_to_string(INT64_C(7));
    struct blorp_string *right = blorp_int_to_string(INT64_C(42));
    const size_t left_id = runtime_test_allocation_id(left);
    const size_t right_id = runtime_test_allocation_id(right);
    blorp_r_0 root = pair(left, right);
    const size_t root_id = runtime_test_allocation_id(root);
    assert(allocation_count == 3);
    blorp_record_dup_0(root);
    blorp_record_drop_0(root);
    assert_frees(root_id, 0);
    assert_frees(left_id, 0);
    assert_frees(right_id, 0);
    assert_text(root->blorp_rf_0_0, "7", 1);
    assert_text(root->blorp_rf_0_2, "42", 2);
    blorp_record_drop_0(root);
    assert_frees(root_id, 1);
    assert_frees(left_id, 1);
    assert_frees(right_id, 1);
}

static void test_repeated(void) {
    struct blorp_string *text = blorp_int_to_string(INT64_C(42));
    const size_t text_id = runtime_test_allocation_id(text);
    blorp_string_retain(text);
    blorp_r_0 root = pair(text, text);
    const size_t root_id = runtime_test_allocation_id(root);
    assert(root->blorp_rf_0_0 == root->blorp_rf_0_2);
    assert(atomic_load(&text->references) == 2);
    blorp_record_drop_0(root);
    assert_frees(root_id, 1);
    assert_frees(text_id, 1);
}

static void test_escape(void) {
    struct blorp_string *text = blorp_int_to_string(INT64_C(42));
    const size_t text_id = runtime_test_allocation_id(text);
    blorp_r_0 root = pair(text, blorp_int_to_string(INT64_C(7)));
    const size_t root_id = runtime_test_allocation_id(root);
    blorp_string_retain(root->blorp_rf_0_0);
    blorp_record_drop_0(root);
    assert_frees(root_id, 1);
    assert_frees(text_id, 0);
    assert_text(text, "42", 2);
    blorp_string_release(text);
    assert_frees(text_id, 1);
}

static void test_void(void) {
    blorp_r_1 root = blorp_record_make_1((struct blorp_r_1){0});
    const size_t root_id = runtime_test_allocation_id(root);
    assert(sizeof *root == sizeof root->references);
    assert(allocation_count == 1);
    blorp_record_dup_1(root);
    blorp_record_drop_1(root);
    assert_frees(root_id, 0);
    blorp_record_drop_1(root);
    assert_frees(root_id, 1);
}

int main(int argc, char **argv) {
    assert(argc == 2);
    if (strcmp(argv[1], "retain") == 0) test_retain();
    else if (strcmp(argv[1], "repeated") == 0) test_repeated();
    else if (strcmp(argv[1], "escape") == 0) test_escape();
    else if (strcmp(argv[1], "void") == 0) test_void();
    else assert(0 && "unknown tuple runtime case");
    assert(allocation_count == destruction_count);
    return 0;
}
