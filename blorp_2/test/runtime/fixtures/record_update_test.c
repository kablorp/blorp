#include "aggregate_runtime_test.h"

static blorp_r_0 entry(int64_t number) {
    return blorp_record_make_0((struct blorp_r_0){
        .blorp_rf_0_0 = number,
        .blorp_rf_0_1 = blorp_int_to_string(number)
    });
}

/* Constructors consume owned slots. These are the distinct projection and
 * stored-occurrence acquisitions tested by the unit IR, followed by the
 * temporary's drop. No generated language function is called. */
static blorp_r_0 copied_entry(blorp_r_0 old, int64_t number) {
    struct blorp_string *text = old->blorp_rf_0_1;
    const size_t text_id = runtime_test_allocation_id(text);
    blorp_string_retain(text);
    blorp_string_retain(text);
    assert_frees(text_id, 0);
    assert(atomic_load(&text->references) == 3);
    blorp_r_0 fresh = blorp_record_make_0((struct blorp_r_0){
        .blorp_rf_0_0 = number, .blorp_rf_0_1 = text
    });
    blorp_string_release(text);
    assert_frees(text_id, 0);
    assert(atomic_load(&text->references) == 2);
    return fresh;
}

static void test_fresh(void) {
    blorp_r_0 old = entry(INT64_C(42));
    const size_t old_id = runtime_test_allocation_id(old);
    const size_t text_id = runtime_test_allocation_id(old->blorp_rf_0_1);
    blorp_r_0 fresh = copied_entry(old, INT64_C(7));
    const size_t fresh_id = runtime_test_allocation_id(fresh);
    assert(old != fresh); /* Both roots are live. */
    assert(old_id != fresh_id && allocation_count == 3);
    assert(old->blorp_rf_0_0 == 42 && fresh->blorp_rf_0_0 == 7);
    assert(old->blorp_rf_0_1 == fresh->blorp_rf_0_1);
    blorp_record_drop_0(fresh);
    assert_frees(fresh_id, 1);
    assert_frees(old_id, 0);
    assert_frees(text_id, 0);
    assert_text(old->blorp_rf_0_1, "42", 2);
    assert(atomic_load(&old->blorp_rf_0_1->references) == 1);
    blorp_record_drop_0(old);
    assert_frees(old_id, 1);
    assert_frees(text_id, 1);
}

static void test_equal(void) {
    blorp_r_0 old = entry(INT64_C(42));
    const size_t old_id = runtime_test_allocation_id(old);
    const size_t text_id = runtime_test_allocation_id(old->blorp_rf_0_1);
    blorp_r_0 fresh = copied_entry(old, old->blorp_rf_0_0);
    const size_t fresh_id = runtime_test_allocation_id(fresh);
    assert(old != fresh && old_id != fresh_id);
    assert(allocation_count == 3);
    assert(fresh->blorp_rf_0_0 == 42);
    assert_text(fresh->blorp_rf_0_1, "42", 2);
    blorp_record_drop_0(old);
    assert_frees(old_id, 1);
    assert_frees(text_id, 0);
    assert(atomic_load(&fresh->blorp_rf_0_1->references) == 1);
    blorp_record_drop_0(fresh);
    assert_frees(fresh_id, 1);
    assert_frees(text_id, 1);
}

static void test_old_alias(void) {
    blorp_r_0 old = entry(INT64_C(42));
    const size_t old_id = runtime_test_allocation_id(old);
    const size_t text_id = runtime_test_allocation_id(old->blorp_rf_0_1);
    blorp_record_dup_0(old);
    blorp_r_0 alias = old;
    blorp_r_0 fresh = copied_entry(old, INT64_C(7));
    const size_t fresh_id = runtime_test_allocation_id(fresh);
    assert(atomic_load(&old->references) == 2);
    blorp_record_drop_0(old);
    assert_frees(old_id, 0);
    assert(atomic_load(&alias->references) == 1);
    assert(atomic_load(&alias->blorp_rf_0_1->references) == 2);
    assert(alias->blorp_rf_0_0 == 42 && fresh->blorp_rf_0_0 == 7);
    blorp_record_drop_0(alias);
    assert_frees(old_id, 1);
    assert_frees(text_id, 0);
    assert_text(fresh->blorp_rf_0_1, "42", 2);
    blorp_record_drop_0(fresh);
    assert_frees(fresh_id, 1);
    assert_frees(text_id, 1);
}

static void test_escape(void) {
    blorp_r_0 old = entry(INT64_C(42));
    const size_t old_id = runtime_test_allocation_id(old);
    const size_t text_id = runtime_test_allocation_id(old->blorp_rf_0_1);
    blorp_r_0 fresh = copied_entry(old, INT64_C(7));
    const size_t fresh_id = runtime_test_allocation_id(fresh);
    struct blorp_string *escaped = fresh->blorp_rf_0_1;
    blorp_string_retain(escaped);
    assert(atomic_load(&escaped->references) == 3);
    blorp_record_drop_0(old);
    blorp_record_drop_0(fresh);
    assert_frees(old_id, 1);
    assert_frees(fresh_id, 1);
    assert_frees(text_id, 0);
    assert(atomic_load(&escaped->references) == 1);
    assert_text(escaped, "42", 2);
    blorp_string_release(escaped);
    assert_frees(text_id, 1);
}

static void test_repeated(void) {
    struct blorp_string *left = blorp_int_to_string(INT64_C(7));
    struct blorp_string *right = blorp_int_to_string(INT64_C(42));
    const size_t left_id = runtime_test_allocation_id(left);
    const size_t right_id = runtime_test_allocation_id(right);
    blorp_r_1 old = blorp_record_make_1((struct blorp_r_1){
        .blorp_rf_1_0 = left, .blorp_rf_1_1 = right
    });
    const size_t old_id = runtime_test_allocation_id(old);
    struct blorp_string *changed = old->blorp_rf_1_1;
    blorp_string_retain(changed);
    struct blorp_string *inherited = old->blorp_rf_1_1;
    blorp_string_retain(inherited);
    assert(atomic_load(&right->references) == 3);
    blorp_record_drop_1(old);
    assert_frees(old_id, 1);
    assert_frees(left_id, 1);
    assert(atomic_load(&right->references) == 2);
    blorp_string_retain(changed);
    blorp_string_retain(inherited);
    blorp_r_1 fresh = blorp_record_make_1((struct blorp_r_1){
        .blorp_rf_1_0 = changed, .blorp_rf_1_1 = inherited
    });
    const size_t fresh_id = runtime_test_allocation_id(fresh);
    assert(fresh_id != old_id); /* Old address may already have been reused. */
    blorp_string_release(changed);
    blorp_string_release(inherited);
    assert(atomic_load(&right->references) == 2);
    assert(fresh->blorp_rf_1_0 == fresh->blorp_rf_1_1);
    assert_text(fresh->blorp_rf_1_0, "42", 2);
    blorp_record_drop_1(fresh);
    assert_frees(fresh_id, 1);
    assert_frees(right_id, 1);
    assert(allocation_count == 4);
}

static void test_void_root(void) {
    blorp_r_2 old = blorp_record_make_2((struct blorp_r_2){0});
    const size_t old_id = runtime_test_allocation_id(old);
    blorp_r_2 fresh = blorp_record_make_2((struct blorp_r_2){0});
    const size_t fresh_id = runtime_test_allocation_id(fresh);
    assert(old != fresh && old_id != fresh_id && allocation_count == 2);
    assert(atomic_load(&old->references) == 1 && atomic_load(&fresh->references) == 1);
    blorp_record_drop_2(old);
    assert_frees(old_id, 1);
    assert_frees(fresh_id, 0);
    assert(sizeof *fresh == sizeof fresh->references);
    blorp_record_drop_2(fresh);
    assert_frees(fresh_id, 1);
}

static void test_union_root(void) {
    const struct blorp_u_0 empty = { .tag = blorp_v_0_1 };
    blorp_r_3 old = blorp_record_make_3((struct blorp_r_3){ .blorp_rf_3_0 = empty });
    const size_t old_id = runtime_test_allocation_id(old);
    blorp_r_3 fresh = blorp_record_make_3((struct blorp_r_3){ .blorp_rf_3_0 = old->blorp_rf_3_0 });
    const size_t fresh_id = runtime_test_allocation_id(fresh);
    assert(old != fresh && old_id != fresh_id && allocation_count == 2);
    blorp_record_drop_3(old);
    assert_frees(old_id, 1);
    assert_frees(fresh_id, 0);
    assert(fresh->blorp_rf_3_0.tag == blorp_v_0_1);
    blorp_record_drop_3(fresh);
    assert_frees(fresh_id, 1);
}

static blorp_r_4 mixed_box(void) {
    blorp_r_0 child = entry(INT64_C(42));
    struct blorp_l_0_r0 *values = blorp_list_repeat_0_r0(child, INT64_C(2));
    struct blorp_string *text = child->blorp_rf_0_1;
    blorp_string_retain(text);
    return blorp_record_make_4((struct blorp_r_4){
        .blorp_rf_4_0 = 42, .blorp_rf_4_1 = child, .blorp_rf_4_2 = values,
        .blorp_rf_4_3 = { .tag = blorp_v_1_0, .payload.blorp_up_0.blorp_uf_0 = text }
    });
}

static blorp_r_4 copied_box(blorp_r_4 old) {
    blorp_r_0 child = old->blorp_rf_4_1;
    struct blorp_l_0_r0 *values = old->blorp_rf_4_2;
    struct blorp_u_1 choice = old->blorp_rf_4_3;
    const size_t child_id = runtime_test_allocation_id(child);
    const size_t list_id = runtime_test_allocation_id(values);
    blorp_record_dup_0(child);
    blorp_list_dup_0_r0(values);
    blorp_union_dup_1(choice);
    blorp_record_drop_4(old);
    assert_frees(child_id, 0);
    assert_frees(list_id, 0);
    blorp_record_dup_0(child);
    blorp_list_dup_0_r0(values);
    blorp_union_dup_1(choice);
    blorp_r_4 fresh = blorp_record_make_4((struct blorp_r_4){
        .blorp_rf_4_0 = 7, .blorp_rf_4_1 = child, .blorp_rf_4_2 = values, .blorp_rf_4_3 = choice
    });
    blorp_record_drop_0(child);
    blorp_list_drop_0_r0(values);
    blorp_union_drop_1(choice);
    assert_frees(child_id, 0);
    assert_frees(list_id, 0);
    return fresh;
}

static void test_mixed(void) {
    blorp_r_4 old = mixed_box();
    const size_t old_id = runtime_test_allocation_id(old);
    blorp_r_0 child = old->blorp_rf_4_1;
    struct blorp_string *text = child->blorp_rf_0_1;
    const size_t child_id = runtime_test_allocation_id(child);
    const size_t text_id = runtime_test_allocation_id(text);
    const size_t list_id = runtime_test_allocation_id(old->blorp_rf_4_2);
    blorp_r_4 fresh = copied_box(old);
    const size_t fresh_id = runtime_test_allocation_id(fresh);
    assert(old_id != fresh_id && allocation_count == 5);
    assert_frees(old_id, 1);
    assert_frees(child_id, 0);
    assert_frees(text_id, 0);
    assert_frees(list_id, 0);
    assert(atomic_load(&child->references) == 3);
    assert(atomic_load(&text->references) == 2);
    assert(atomic_load(&fresh->blorp_rf_4_2->references) == 1);
    assert(fresh->blorp_rf_4_0 == 7 && fresh->blorp_rf_4_2->length == 2);
    blorp_record_drop_4(fresh);
    assert_frees(fresh_id, 1);
    assert_frees(child_id, 1);
    assert_frees(text_id, 1);
    assert_frees(list_id, 1);
}

static void test_list_alias(void) {
    blorp_r_4 old = mixed_box();
    const size_t old_id = runtime_test_allocation_id(old);
    struct blorp_l_0_r0 *alias = old->blorp_rf_4_2;
    const size_t list_id = runtime_test_allocation_id(alias);
    const size_t child_id = runtime_test_allocation_id(old->blorp_rf_4_1);
    const size_t text_id = runtime_test_allocation_id(old->blorp_rf_4_1->blorp_rf_0_1);
    blorp_list_dup_0_r0(alias);
    blorp_r_4 fresh = copied_box(old);
    const size_t fresh_id = runtime_test_allocation_id(fresh);
    assert(atomic_load(&alias->references) == 2);
    blorp_record_drop_4(fresh);
    assert_frees(old_id, 1);
    assert_frees(fresh_id, 1);
    assert_frees(list_id, 0);
    assert_frees(child_id, 0);
    assert_frees(text_id, 0);
    assert(atomic_load(&alias->references) == 1);
    assert(atomic_load(&alias->values[0]->references) == 2);
    assert(atomic_load(&alias->values[0]->blorp_rf_0_1->references) == 1);
    assert_text(alias->values[1]->blorp_rf_0_1, "42", 2);
    blorp_list_drop_0_r0(alias);
    assert_frees(list_id, 1);
    assert_frees(child_id, 1);
    assert_frees(text_id, 1);
}

static void test_inactive(void) {
    struct blorp_string *unowned = blorp_int_to_string(INT64_C(7));
    const size_t unowned_id = runtime_test_allocation_id(unowned);
    blorp_r_0 child = entry(INT64_C(42));
    struct blorp_l_0_r0 *values = blorp_list_repeat_0_r0(child, INT64_C(1));
    blorp_r_4 old = blorp_record_make_4((struct blorp_r_4){
        .blorp_rf_4_0 = 42, .blorp_rf_4_1 = child, .blorp_rf_4_2 = values,
        .blorp_rf_4_3 = { .tag = blorp_v_1_1, .payload.blorp_up_0.blorp_uf_0 = unowned }
    });
    const size_t old_id = runtime_test_allocation_id(old);
    blorp_r_4 fresh = copied_box(old);
    const size_t fresh_id = runtime_test_allocation_id(fresh);
    assert_frees(old_id, 1);
    assert_frees(unowned_id, 0);
    assert(atomic_load(&unowned->references) == 1);
    blorp_record_drop_4(fresh);
    assert_frees(fresh_id, 1);
    assert_frees(unowned_id, 0);
    assert_text(unowned, "7", 1);
    blorp_string_release(unowned);
    assert_frees(unowned_id, 1);
}

static void test_inline(void) {
    const blorp_r_5 old = { .blorp_rf_5_0 = 1, .blorp_rf_5_1 = 2 };
    const blorp_r_5 fresh = { .blorp_rf_5_0 = 9, .blorp_rf_5_1 = old.blorp_rf_5_1 };
    assert(old.blorp_rf_5_0 == 1 && fresh.blorp_rf_5_0 == 9);
    assert(fresh.blorp_rf_5_1 == 2);
    assert(allocation_count == 0 && destruction_count == 0);
}

static void test_all_replaced(void) {
    blorp_r_0 old = entry(INT64_C(42));
    const size_t old_id = runtime_test_allocation_id(old);
    const size_t old_text_id = runtime_test_allocation_id(old->blorp_rf_0_1);
    blorp_record_drop_0(old);
    assert_frees(old_id, 1);
    assert_frees(old_text_id, 1);
    blorp_r_0 fresh = entry(INT64_C(7));
    const size_t fresh_id = runtime_test_allocation_id(fresh);
    const size_t fresh_text_id = runtime_test_allocation_id(fresh->blorp_rf_0_1);
    assert(fresh_id != old_id && fresh_text_id != old_text_id);
    assert(allocation_count == 4);
    assert(fresh->blorp_rf_0_0 == 7);
    assert_text(fresh->blorp_rf_0_1, "7", 1);
    blorp_record_drop_0(fresh);
    assert_frees(fresh_id, 1);
    assert_frees(fresh_text_id, 1);
}

int main(int argc, char **argv) {
    assert(argc == 2);
    if (strcmp(argv[1], "fresh") == 0) test_fresh();
    else if (strcmp(argv[1], "equal") == 0) test_equal();
    else if (strcmp(argv[1], "old_alias") == 0) test_old_alias();
    else if (strcmp(argv[1], "escape") == 0) test_escape();
    else if (strcmp(argv[1], "repeated") == 0) test_repeated();
    else if (strcmp(argv[1], "void_root") == 0) test_void_root();
    else if (strcmp(argv[1], "union_root") == 0) test_union_root();
    else if (strcmp(argv[1], "mixed") == 0) test_mixed();
    else if (strcmp(argv[1], "list_alias") == 0) test_list_alias();
    else if (strcmp(argv[1], "inactive") == 0) test_inactive();
    else if (strcmp(argv[1], "inline") == 0) test_inline();
    else if (strcmp(argv[1], "all_replaced") == 0) test_all_replaced();
    else assert(0 && "unknown record update helper case");
    assert(allocation_count == destruction_count);
    return 0;
}
