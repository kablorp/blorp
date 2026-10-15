#include "aggregate_runtime_test.h"

/* The Blorp suite verifies the complete concrete catalogue before these names
 * are used. Every case runs in a fresh process through the existing harness. */

static void test_int_zero(void) {
    struct blorp_l_0_i *root = blorp_list_repeat_0_i(INT64_C(0), INT64_C(1));
    const size_t root_id = runtime_test_allocation_id(root);
    int64_t out = INT64_C(91);
    assert(blorp_list_length_0_i(root) == INT64_C(1));
    assert(blorp_list_get_0_i(root, INT64_C(0), &out) == 1);
    assert(out == INT64_C(0));
    out = INT64_C(91);
    assert(blorp_list_get_0_i(root, INT64_C(1), &out) == 0);
    assert(out == INT64_C(91));
    assert(allocation_count == 1 && destruction_count == 0);
    blorp_list_drop_0_i(root);
    assert_frees(root_id, 1);
}

static void test_float_zero(void) {
    struct blorp_l_0_f *root = blorp_list_repeat_0_f(0.0, INT64_C(2));
    const size_t root_id = runtime_test_allocation_id(root);
    double out = 91.5;
    assert(blorp_list_length_0_f(root) == INT64_C(2));
    assert(blorp_list_get_0_f(root, INT64_C(1), &out) == 1);
    assert(out == 0.0 && root->values[0] == 0.0);
    out = 91.5;
    assert(blorp_list_get_0_f(root, INT64_C(2), &out) == 0);
    assert(out == 91.5);
    assert(allocation_count == 1 && destruction_count == 0);
    blorp_list_drop_0_f(root);
    assert_frees(root_id, 1);
}

static void test_void_zero(void) {
    struct blorp_l_0_v *root = blorp_list_repeat_0_v(UINT8_C(0), INT64_C(2));
    const size_t root_id = runtime_test_allocation_id(root);
    uint8_t out = UINT8_C(91);
    assert(blorp_list_length_0_v(root) == INT64_C(2));
    assert(blorp_list_get_0_v(root, INT64_C(0), &out) == 1);
    assert(out == UINT8_C(0));
    out = UINT8_C(91);
    assert(blorp_list_get_0_v(root, INT64_C(2), &out) == 0);
    assert(out == UINT8_C(91));
    assert(allocation_count == 1 && destruction_count == 0);
    blorp_list_drop_0_v(root);
    assert_frees(root_id, 1);
}

static void test_inline_union_zero(void) {
    struct blorp_u_0 element = {
        .tag = blorp_v_0_0,
        .payload.blorp_up_0 = { .blorp_uf_0 = INT64_C(0) }
    };
    struct blorp_l_0_u0 *root = blorp_list_repeat_0_u0(element, INT64_C(2));
    const size_t root_id = runtime_test_allocation_id(root);
    struct blorp_u_0 out = { .tag = blorp_v_0_1 };
    assert(blorp_list_length_0_u0(root) == INT64_C(2));
    assert(blorp_list_get_0_u0(root, INT64_C(1), &out) == 1);
    assert(out.tag == blorp_v_0_0);
    assert(out.payload.blorp_up_0.blorp_uf_0 == INT64_C(0));
    out.tag = blorp_v_0_1;
    assert(blorp_list_get_0_u0(root, INT64_C(2), &out) == 0);
    assert(out.tag == blorp_v_0_1);
    assert(allocation_count == 1 && destruction_count == 0);
    blorp_list_drop_0_u0(root);
    assert_frees(root_id, 1);
}

static void test_inline_record_zero(void) {
    blorp_r_2 element = { .blorp_rf_2_0 = INT64_C(0) };
    struct blorp_l_0_r2 *root = blorp_list_repeat_0_r2(element, INT64_C(2));
    const size_t root_id = runtime_test_allocation_id(root);
    blorp_r_2 out = { .blorp_rf_2_0 = INT64_C(91) };
    assert(blorp_list_length_0_r2(root) == INT64_C(2));
    assert(root->values[0].blorp_rf_2_0 == INT64_C(0));
    assert(root->values[1].blorp_rf_2_0 == INT64_C(0));
    assert(blorp_list_get_0_r2(root, INT64_C(1), &out) == 1);
    assert(out.blorp_rf_2_0 == INT64_C(0));
    out.blorp_rf_2_0 = INT64_C(91);
    assert(blorp_list_get_0_r2(root, INT64_C(2), &out) == 0);
    assert(out.blorp_rf_2_0 == INT64_C(91));
    assert(allocation_count == 1 && destruction_count == 0);
    blorp_list_drop_0_r2(root);
    assert_frees(root_id, 1);
}

static void empty_repeat(int64_t count) {
    struct blorp_string *text = blorp_int_to_string(INT64_C(42));
    const size_t text_id = runtime_test_allocation_id(text);
    struct blorp_l_0_s *root = blorp_list_repeat_0_s(text, count);
    const size_t root_id = runtime_test_allocation_id(root);
    struct blorp_string *out = text;
    assert(blorp_list_length_0_s(root) == INT64_C(0));
    assert(atomic_load(&text->references) == 1);
    assert(blorp_list_get_0_s(root, INT64_C(0), &out) == 0);
    assert(out == text);
    assert(allocation_count == 2 && destruction_count == 0);
    blorp_list_drop_0_s(root);
    assert_frees(root_id, 1);
    assert_frees(text_id, 0);
    assert(atomic_load(&text->references) == 1);
    assert_text(text, "42", 2);
    blorp_string_release(text);
    assert_frees(text_id, 1);
}

static void test_lookup_bounds(void) {
    struct blorp_l_0_i *root = blorp_list_repeat_0_i(INT64_C(7), INT64_C(2));
    const size_t root_id = runtime_test_allocation_id(root);
    int64_t out = INT64_C(91);
    assert(blorp_list_get_0_i(root, INT64_C(-1), &out) == 0);
    assert(out == INT64_C(91));
    assert(blorp_list_get_0_i(root, INT64_C(2), &out) == 0);
    assert(out == INT64_C(91));
    assert(blorp_list_get_0_i(root, INT64_MAX, &out) == 0);
    assert(out == INT64_C(91));
    assert(blorp_list_get_0_i(root, INT64_MIN, &out) == 0);
    assert(out == INT64_C(91));
    assert(allocation_count == 1 && destruction_count == 0);
    blorp_list_drop_0_i(root);
    assert_frees(root_id, 1);
}

static void test_literal_string(void) {
    /* Literal byte storage is copied into a mortal String root by production. */
    static const char bytes[] = "a\0\xc3\xa9";
    struct blorp_string *text = blorp_string_from_bytes(bytes, INT64_C(4));
    const size_t text_id = runtime_test_allocation_id(text);
    struct blorp_l_0_s *root = blorp_list_repeat_0_s(text, INT64_C(1));
    const size_t root_id = runtime_test_allocation_id(root);
    assert(atomic_load(&text->references) == 2);
    blorp_string_release(text);
    assert(atomic_load(&text->references) == 1);
    struct blorp_string *escaped = NULL;
    assert(blorp_list_get_0_s(root, INT64_C(0), &escaped) == 1);
    assert(escaped == text && atomic_load(&escaped->references) == 2);
    blorp_list_drop_0_s(root);
    assert_frees(root_id, 1);
    assert_frees(text_id, 0);
    assert(atomic_load(&escaped->references) == 1);
    assert_text(escaped, bytes, 4);
    blorp_string_release(escaped);
    assert_frees(text_id, 1);
}

static void test_mortal_repeat(void) {
    struct blorp_string *text = blorp_int_to_string(INT64_C(42));
    const size_t text_id = runtime_test_allocation_id(text);
    struct blorp_l_0_s *root = blorp_list_repeat_0_s(text, INT64_C(3));
    const size_t root_id = runtime_test_allocation_id(root);
    assert(blorp_list_length_0_s(root) == INT64_C(3));
    assert(atomic_load(&text->references) == 4);
    assert(root->values[0] == text && root->values[1] == text && root->values[2] == text);
    blorp_string_release(text);
    assert(atomic_load(&root->values[0]->references) == 3);
    assert(allocation_count == 2 && destruction_count == 0);
    blorp_list_drop_0_s(root);
    assert_frees(root_id, 1);
    assert_frees(text_id, 1);
}

static void test_mortal_get_escape(void) {
    struct blorp_string *text = blorp_int_to_string(INT64_C(42));
    const size_t text_id = runtime_test_allocation_id(text);
    struct blorp_l_0_s *root = blorp_list_repeat_0_s(text, INT64_C(1));
    const size_t root_id = runtime_test_allocation_id(root);
    blorp_string_release(text);
    struct blorp_string *escaped = NULL;
    assert(blorp_list_get_0_s(root, INT64_C(0), &escaped) == 1);
    assert(escaped == text && atomic_load(&escaped->references) == 2);
    blorp_list_drop_0_s(root);
    assert_frees(root_id, 1);
    assert_frees(text_id, 0);
    assert(atomic_load(&escaped->references) == 1);
    assert_text(escaped, "42", 2);
    blorp_string_release(escaped);
    assert_frees(text_id, 1);
}

static void test_root_dup(void) {
    struct blorp_string *text = blorp_int_to_string(INT64_C(42));
    const size_t text_id = runtime_test_allocation_id(text);
    struct blorp_l_0_s *root = blorp_list_repeat_0_s(text, INT64_C(2));
    const size_t root_id = runtime_test_allocation_id(root);
    blorp_list_dup_0_s(root);
    assert(atomic_load(&root->references) == 2);
    assert(atomic_load(&text->references) == 3);
    blorp_list_drop_0_s(root);
    assert(atomic_load(&root->references) == 1);
    assert(atomic_load(&text->references) == 3);
    assert(destruction_count == 0);
    blorp_string_release(text);
    assert(atomic_load(&root->values[0]->references) == 2);
    blorp_list_drop_0_s(root);
    assert_frees(root_id, 1);
    assert_frees(text_id, 1);
}

static blorp_r_0 make_entry(struct blorp_string *text) {
    return blorp_record_make_0((struct blorp_r_0){
        .blorp_rf_0_0 = INT64_C(7), .blorp_rf_0_1 = text
    });
}

static void test_entry_escape(void) {
    struct blorp_string *text = blorp_int_to_string(INT64_C(42));
    const size_t text_id = runtime_test_allocation_id(text);
    blorp_r_0 entry = make_entry(text);
    const size_t entry_id = runtime_test_allocation_id(entry);
    assert(atomic_load(&entry->references) == 1 && atomic_load(&text->references) == 1);
    struct blorp_l_0_r0 *root = blorp_list_repeat_0_r0(entry, INT64_C(2));
    const size_t root_id = runtime_test_allocation_id(root);
    assert(atomic_load(&entry->references) == 3 && atomic_load(&text->references) == 1);
    blorp_record_drop_0(entry);
    assert(atomic_load(&entry->references) == 2);
    blorp_r_0 escaped = NULL;
    assert(blorp_list_get_0_r0(root, INT64_C(0), &escaped) == 1);
    assert(escaped == entry && atomic_load(&escaped->references) == 3);
    blorp_list_drop_0_r0(root);
    assert_frees(root_id, 1);
    assert_frees(entry_id, 0);
    assert_frees(text_id, 0);
    assert(atomic_load(&escaped->references) == 1);
    assert(escaped->blorp_rf_0_0 == INT64_C(7));
    struct blorp_string *escaped_text = escaped->blorp_rf_0_1;
    blorp_string_retain(escaped_text);
    assert(atomic_load(&escaped_text->references) == 2);
    blorp_record_drop_0(escaped);
    assert_frees(entry_id, 1);
    assert(atomic_load(&escaped_text->references) == 1);
    assert_text(escaped_text, "42", 2);
    blorp_string_release(escaped_text);
    assert_frees(text_id, 1);
}

static void test_nested_escape(void) {
    struct blorp_string *text = blorp_int_to_string(INT64_C(42));
    const size_t text_id = runtime_test_allocation_id(text);
    struct blorp_l_0_s *child = blorp_list_repeat_0_s(text, INT64_C(2));
    const size_t child_id = runtime_test_allocation_id(child);
    blorp_string_release(text);
    struct blorp_l_1_s *root = blorp_list_repeat_1_s(child, INT64_C(2));
    const size_t root_id = runtime_test_allocation_id(root);
    assert(atomic_load(&child->references) == 3);
    assert(atomic_load(&child->values[0]->references) == 2);
    blorp_list_drop_0_s(child);
    struct blorp_l_0_s *escaped = NULL;
    assert(blorp_list_get_1_s(root, INT64_C(1), &escaped) == 1);
    assert(escaped == child && atomic_load(&escaped->references) == 3);
    blorp_list_drop_1_s(root);
    assert_frees(root_id, 1);
    assert_frees(child_id, 0);
    assert_frees(text_id, 0);
    assert(atomic_load(&escaped->references) == 1);
    assert(blorp_list_length_0_s(escaped) == INT64_C(2));
    assert(atomic_load(&escaped->values[0]->references) == 2);
    assert_text(escaped->values[1], "42", 2);
    blorp_list_drop_0_s(escaped);
    assert_frees(child_id, 1);
    assert_frees(text_id, 1);
}

static void test_union_distinct(void) {
    struct blorp_string *first = blorp_int_to_string(INT64_C(7));
    struct blorp_string *second = blorp_int_to_string(INT64_C(42));
    const size_t first_id = runtime_test_allocation_id(first);
    const size_t second_id = runtime_test_allocation_id(second);
    struct blorp_u_1 value = {
        .tag = blorp_v_1_0,
        .payload.blorp_up_0 = { .blorp_uf_0 = first, .blorp_uf_1 = second }
    };
    struct blorp_l_0_u1 *root = blorp_list_repeat_0_u1(value, INT64_C(2));
    const size_t root_id = runtime_test_allocation_id(root);
    assert(atomic_load(&first->references) == 3 && atomic_load(&second->references) == 3);
    blorp_union_drop_1(value);
    assert(atomic_load(&first->references) == 2 && atomic_load(&second->references) == 2);
    blorp_list_drop_0_u1(root);
    assert_frees(root_id, 1);
    assert_frees(first_id, 1);
    assert_frees(second_id, 1);
}

static void test_union_equal(void) {
    struct blorp_string *text = blorp_int_to_string(INT64_C(42));
    const size_t text_id = runtime_test_allocation_id(text);
    blorp_string_retain(text);
    struct blorp_u_1 value = {
        .tag = blorp_v_1_0,
        .payload.blorp_up_0 = { .blorp_uf_0 = text, .blorp_uf_1 = text }
    };
    struct blorp_l_0_u1 *root = blorp_list_repeat_0_u1(value, INT64_C(2));
    const size_t root_id = runtime_test_allocation_id(root);
    assert(atomic_load(&text->references) == 6);
    blorp_union_drop_1(value);
    assert(atomic_load(&text->references) == 4);
    blorp_list_drop_0_u1(root);
    assert_frees(root_id, 1);
    assert_frees(text_id, 1);
}

static void test_union_inactive(void) {
    struct blorp_string *first = blorp_int_to_string(INT64_C(7));
    struct blorp_string *second = blorp_int_to_string(INT64_C(42));
    const size_t first_id = runtime_test_allocation_id(first);
    const size_t second_id = runtime_test_allocation_id(second);
    struct blorp_u_1 value = {
        .tag = blorp_v_1_2,
        .payload.blorp_up_0 = { .blorp_uf_0 = first, .blorp_uf_1 = second }
    };
    struct blorp_l_0_u1 *root = blorp_list_repeat_0_u1(value, INT64_C(2));
    const size_t root_id = runtime_test_allocation_id(root);
    assert(atomic_load(&first->references) == 1 && atomic_load(&second->references) == 1);
    blorp_list_drop_0_u1(root);
    assert_frees(root_id, 1);
    assert_frees(first_id, 0);
    assert_frees(second_id, 0);
    assert_text(first, "7", 1);
    assert_text(second, "42", 2);
    blorp_string_release(first);
    blorp_string_release(second);
    assert_frees(first_id, 1);
    assert_frees(second_id, 1);
}

static void test_union_nested(void) {
    struct blorp_string *text = blorp_int_to_string(INT64_C(42));
    const size_t text_id = runtime_test_allocation_id(text);
    blorp_r_0 entry = make_entry(text);
    const size_t entry_id = runtime_test_allocation_id(entry);
    struct blorp_l_0_r0 *children = blorp_list_repeat_0_r0(entry, INT64_C(2));
    const size_t children_id = runtime_test_allocation_id(children);
    struct blorp_u_1 value = {
        .tag = blorp_v_1_1,
        .payload.blorp_up_1 = { .blorp_uf_0 = entry, .blorp_uf_1 = children }
    };
    struct blorp_l_0_u1 *root = blorp_list_repeat_0_u1(value, INT64_C(2));
    const size_t root_id = runtime_test_allocation_id(root);
    assert(atomic_load(&entry->references) == 5 && atomic_load(&children->references) == 3);
    blorp_union_drop_1(value);
    struct blorp_u_1 escaped = { .tag = blorp_v_1_2 };
    assert(blorp_list_get_0_u1(root, INT64_C(0), &escaped) == 1);
    assert(escaped.tag == blorp_v_1_1);
    assert(atomic_load(&entry->references) == 5 && atomic_load(&children->references) == 3);
    blorp_list_drop_0_u1(root);
    assert_frees(root_id, 1);
    assert_frees(children_id, 0);
    assert_frees(entry_id, 0);
    assert_frees(text_id, 0);
    assert(atomic_load(&children->references) == 1 && atomic_load(&entry->references) == 3);
    assert(escaped.payload.blorp_up_1.blorp_uf_0 == entry);
    assert(escaped.payload.blorp_up_1.blorp_uf_1 == children);
    assert_text(entry->blorp_rf_0_1, "42", 2);
    blorp_union_drop_1(escaped);
    assert_frees(children_id, 1);
    assert_frees(entry_id, 1);
    assert_frees(text_id, 1);
}

static void test_mixed(void) {
    struct blorp_string *first = blorp_int_to_string(INT64_C(7));
    struct blorp_string *second = blorp_int_to_string(INT64_C(42));
    struct blorp_string *third = blorp_int_to_string(INT64_C(99));
    const size_t first_id = runtime_test_allocation_id(first);
    const size_t second_id = runtime_test_allocation_id(second);
    const size_t third_id = runtime_test_allocation_id(third);
    struct blorp_u_1 choice = {
        .tag = blorp_v_1_0,
        .payload.blorp_up_0 = { .blorp_uf_0 = first, .blorp_uf_1 = second }
    };
    struct blorp_l_0_u1 *choices = blorp_list_repeat_0_u1(choice, INT64_C(2));
    const size_t choices_id = runtime_test_allocation_id(choices);
    blorp_union_drop_1(choice);
    blorp_r_0 entry = make_entry(third);
    const size_t entry_id = runtime_test_allocation_id(entry);
    struct blorp_l_0_r0 *entries = blorp_list_repeat_0_r0(entry, INT64_C(2));
    const size_t entries_id = runtime_test_allocation_id(entries);
    blorp_record_drop_0(entry);
    blorp_r_1 envelope = blorp_record_make_1((struct blorp_r_1){
        .blorp_rf_1_0 = choices, .blorp_rf_1_1 = entries
    });
    const size_t envelope_id = runtime_test_allocation_id(envelope);
    struct blorp_l_0_r1 *root = blorp_list_repeat_0_r1(envelope, INT64_C(2));
    const size_t root_id = runtime_test_allocation_id(root);
    assert(atomic_load(&envelope->references) == 3);
    assert(atomic_load(&choices->references) == 1 && atomic_load(&entries->references) == 1);
    assert(atomic_load(&first->references) == 2 && atomic_load(&second->references) == 2);
    assert(atomic_load(&entry->references) == 2 && atomic_load(&third->references) == 1);
    blorp_record_drop_1(envelope);
    assert(atomic_load(&root->values[0]->references) == 2);
    assert(allocation_count == 8 && destruction_count == 0);
    blorp_list_drop_0_r1(root);
    assert_frees(root_id, 1);
    assert_frees(envelope_id, 1);
    assert_frees(entries_id, 1);
    assert_frees(entry_id, 1);
    assert_frees(choices_id, 1);
    assert_frees(first_id, 1);
    assert_frees(second_id, 1);
    assert_frees(third_id, 1);
}

static void repeat_count(int64_t count) {
    struct blorp_string *text = blorp_int_to_string(INT64_C(42));
    const size_t text_id = runtime_test_allocation_id(text);
    blorp_r_0 entry = make_entry(text);
    const size_t entry_id = runtime_test_allocation_id(entry);
    size_t before = allocation_count;
    struct blorp_l_0_r0 *root = blorp_list_repeat_0_r0(entry, count);
    const size_t root_id = runtime_test_allocation_id(root);
    assert(allocation_count == before + 1);
    assert(blorp_list_length_0_r0(root) == count);
    assert(atomic_load(&entry->references) == (size_t)count + 1);
    assert(atomic_load(&text->references) == 1);
    for (int64_t index = 0; index < count; index += 1) {
        assert(root->values[index] == entry);
    }
    before = allocation_count;
    struct blorp_l_0_i *numbers = blorp_list_repeat_0_i(INT64_C(7), count);
    const size_t numbers_id = runtime_test_allocation_id(numbers);
    assert(allocation_count == before + 1);
    assert(blorp_list_length_0_i(numbers) == count);
    for (int64_t index = 0; index < count; index += 1) {
        assert(numbers->values[index] == INT64_C(7));
    }
    assert(destruction_count == 0);
    blorp_record_drop_0(entry);
    assert(atomic_load(&root->values[0]->references) == (size_t)count);
    blorp_list_drop_0_r0(root);
    assert_frees(root_id, 1);
    assert_frees(entry_id, 1);
    assert_frees(text_id, 1);
    blorp_list_drop_0_i(numbers);
    assert_frees(numbers_id, 1);
}

int main(int argc, char **argv) {
    assert(argc == 2);
    if (strcmp(argv[1], "int_zero") == 0) test_int_zero();
    else if (strcmp(argv[1], "float_zero") == 0) test_float_zero();
    else if (strcmp(argv[1], "void_zero") == 0) test_void_zero();
    else if (strcmp(argv[1], "inline_union_zero") == 0) test_inline_union_zero();
    else if (strcmp(argv[1], "inline_record_zero") == 0) test_inline_record_zero();
    else if (strcmp(argv[1], "negative_repeat") == 0) empty_repeat(INT64_C(-1));
    else if (strcmp(argv[1], "zero_repeat") == 0) empty_repeat(INT64_C(0));
    else if (strcmp(argv[1], "minimum_repeat") == 0) empty_repeat(INT64_MIN);
    else if (strcmp(argv[1], "lookup_bounds") == 0) test_lookup_bounds();
    else if (strcmp(argv[1], "literal_string") == 0) test_literal_string();
    else if (strcmp(argv[1], "mortal_repeat") == 0) test_mortal_repeat();
    else if (strcmp(argv[1], "mortal_get_escape") == 0) test_mortal_get_escape();
    else if (strcmp(argv[1], "root_dup") == 0) test_root_dup();
    else if (strcmp(argv[1], "entry_escape") == 0) test_entry_escape();
    else if (strcmp(argv[1], "nested_escape") == 0) test_nested_escape();
    else if (strcmp(argv[1], "union_distinct") == 0) test_union_distinct();
    else if (strcmp(argv[1], "union_equal") == 0) test_union_equal();
    else if (strcmp(argv[1], "union_inactive") == 0) test_union_inactive();
    else if (strcmp(argv[1], "union_nested") == 0) test_union_nested();
    else if (strcmp(argv[1], "mixed") == 0) test_mixed();
    else if (strcmp(argv[1], "repeat_16") == 0) repeat_count(INT64_C(16));
    else if (strcmp(argv[1], "repeat_32") == 0) repeat_count(INT64_C(32));
    else if (strcmp(argv[1], "repeat_64") == 0) repeat_count(INT64_C(64));
    else if (strcmp(argv[1], "repeat_128") == 0) repeat_count(INT64_C(128));
    else assert(0 && "unknown generic List runtime case");
    assert(allocation_count == destruction_count);
    return 0;
}
