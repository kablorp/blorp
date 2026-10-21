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

static void test_append_int(void) {
    struct blorp_l_0_i *root = blorp_list_repeat_0_i(INT64_C(0), INT64_C(2));
    const size_t root_id = runtime_test_allocation_id(root);
    struct blorp_l_0_i *grown = blorp_list_append_0_i(root, INT64_C(5));
    const size_t grown_id = runtime_test_allocation_id(grown);
    assert(allocation_count == 2 && destruction_count == 0);
    assert(blorp_list_length_0_i(root) == INT64_C(2));
    assert(blorp_list_length_0_i(grown) == INT64_C(3));
    assert(grown->values[0] == INT64_C(0) && grown->values[1] == INT64_C(0));
    assert(grown->values[2] == INT64_C(5));
    blorp_list_drop_0_i(root);
    assert_frees(root_id, 1);
    assert(grown->values[2] == INT64_C(5));
    blorp_list_drop_0_i(grown);
    assert_frees(grown_id, 1);
}

static void test_append_empty_int(void) {
    struct blorp_l_0_i *root = blorp_list_repeat_0_i(INT64_C(0), INT64_C(0));
    const size_t root_id = runtime_test_allocation_id(root);
    struct blorp_l_0_i *grown = blorp_list_append_0_i(root, INT64_C(5));
    const size_t grown_id = runtime_test_allocation_id(grown);
    assert(blorp_list_length_0_i(root) == INT64_C(0));
    assert(blorp_list_length_0_i(grown) == INT64_C(1) && grown->values[0] == INT64_C(5));
    blorp_list_drop_0_i(root);
    blorp_list_drop_0_i(grown);
    assert_frees(root_id, 1);
    assert_frees(grown_id, 1);
}

static void test_append_mortal_string(void) {
    struct blorp_string *text = blorp_int_to_string(INT64_C(42));
    const size_t text_id = runtime_test_allocation_id(text);
    struct blorp_l_0_s *root = blorp_list_repeat_0_s(text, INT64_C(2));
    const size_t root_id = runtime_test_allocation_id(root);
    assert(atomic_load(&text->references) == 3);
    struct blorp_l_0_s *grown = blorp_list_append_0_s(root, text);
    const size_t grown_id = runtime_test_allocation_id(grown);
    assert(allocation_count == 3 && destruction_count == 0);
    assert(atomic_load(&text->references) == 6);
    assert(blorp_list_length_0_s(grown) == INT64_C(3));
    assert(grown->values[0] == text && grown->values[1] == text && grown->values[2] == text);
    blorp_string_release(text);
    blorp_list_drop_0_s(root);
    assert_frees(root_id, 1);
    assert_frees(text_id, 0);
    assert(atomic_load(&grown->values[2]->references) == 3);
    assert_text(grown->values[2], "42", INT64_C(2));
    blorp_list_drop_0_s(grown);
    assert_frees(grown_id, 1);
    assert_frees(text_id, 1);
}

static void test_append_nested(void) {
    struct blorp_string *text = blorp_int_to_string(INT64_C(42));
    const size_t text_id = runtime_test_allocation_id(text);
    struct blorp_l_0_s *texts = blorp_list_repeat_0_s(text, INT64_C(1));
    const size_t texts_id = runtime_test_allocation_id(texts);
    blorp_string_release(text);
    struct blorp_l_1_s *nested = blorp_list_repeat_1_s(texts, INT64_C(2));
    const size_t nested_id = runtime_test_allocation_id(nested);
    assert(atomic_load(&texts->references) == 3);
    struct blorp_l_1_s *grown = blorp_list_append_1_s(nested, texts);
    const size_t grown_id = runtime_test_allocation_id(grown);
    assert(allocation_count == 4 && destruction_count == 0);
    assert(atomic_load(&texts->references) == 6);
    assert(blorp_list_length_1_s(grown) == INT64_C(3) && grown->values[2] == texts);
    blorp_list_drop_1_s(nested);
    assert_frees(nested_id, 1);
    blorp_list_drop_0_s(texts);
    assert(atomic_load(&grown->values[2]->references) == 3);
    assert_text(grown->values[2]->values[0], "42", INT64_C(2));
    blorp_list_drop_1_s(grown);
    assert_frees(grown_id, 1);
    assert_frees(texts_id, 1);
    assert_frees(text_id, 1);
}

/* Two distinct managed Entries; both texts are owned by their records. */
struct entry_pair {
    blorp_r_0 entry;
    blorp_r_0 other;
    size_t entry_id;
    size_t other_id;
    size_t text_id;
    size_t other_text_id;
};

static struct entry_pair make_entry_pair(void) {
    struct entry_pair pair;
    struct blorp_string *text = blorp_int_to_string(INT64_C(42));
    pair.text_id = runtime_test_allocation_id(text);
    pair.entry = make_entry(text);
    pair.entry_id = runtime_test_allocation_id(pair.entry);
    struct blorp_string *other_text = blorp_int_to_string(INT64_C(7));
    pair.other_text_id = runtime_test_allocation_id(other_text);
    pair.other = make_entry(other_text);
    pair.other_id = runtime_test_allocation_id(pair.other);
    return pair;
}

static void assert_entry_pair_freed(const struct entry_pair *pair) {
    assert_frees(pair->entry_id, 1);
    assert_frees(pair->other_id, 1);
    assert_frees(pair->text_id, 1);
    assert_frees(pair->other_text_id, 1);
}

static void test_set_entry_in_range(void) {
    struct entry_pair pair = make_entry_pair();
    struct blorp_l_0_r0 *root = blorp_list_repeat_0_r0(pair.entry, INT64_C(2));
    const size_t root_id = runtime_test_allocation_id(root);
    struct blorp_l_0_r0 *updated = blorp_list_set_0_r0(root, INT64_C(1), pair.other);
    const size_t updated_id = runtime_test_allocation_id(updated);
    assert(allocation_count == 6 && destruction_count == 0);
    assert(blorp_list_length_0_r0(updated) == INT64_C(2));
    assert(updated->values[0] == pair.entry && updated->values[1] == pair.other);
    assert(root->values[0] == pair.entry && root->values[1] == pair.entry);
    assert(atomic_load(&pair.entry->references) == 4);
    assert(atomic_load(&pair.other->references) == 2);
    blorp_record_drop_0(pair.entry);
    blorp_record_drop_0(pair.other);
    blorp_list_drop_0_r0(root);
    assert_frees(root_id, 1);
    assert(atomic_load(&pair.entry->references) == 1);
    assert(atomic_load(&pair.other->references) == 1);
    assert_text(updated->values[1]->blorp_rf_0_1, "7", INT64_C(1));
    blorp_list_drop_0_r0(updated);
    assert_frees(updated_id, 1);
    assert_entry_pair_freed(&pair);
}

static void test_set_entry_out_of_range(void) {
    struct entry_pair pair = make_entry_pair();
    struct blorp_l_0_r0 *root = blorp_list_repeat_0_r0(pair.entry, INT64_C(2));
    const size_t root_id = runtime_test_allocation_id(root);
    struct blorp_l_0_r0 *beyond = blorp_list_set_0_r0(root, INT64_C(2), pair.other);
    const size_t beyond_id = runtime_test_allocation_id(beyond);
    struct blorp_l_0_r0 *negative = blorp_list_set_0_r0(root, INT64_C(-1), pair.other);
    const size_t negative_id = runtime_test_allocation_id(negative);
    assert(allocation_count == 7 && destruction_count == 0);
    assert(blorp_list_length_0_r0(beyond) == INT64_C(2));
    assert(blorp_list_length_0_r0(negative) == INT64_C(2));
    assert(beyond->values[0] == pair.entry && beyond->values[1] == pair.entry);
    assert(negative->values[0] == pair.entry && negative->values[1] == pair.entry);
    assert(atomic_load(&pair.entry->references) == 7);
    assert(atomic_load(&pair.other->references) == 1);
    blorp_record_drop_0(pair.other);
    assert_frees(pair.other_id, 1);
    assert_frees(pair.other_text_id, 1);
    blorp_record_drop_0(pair.entry);
    blorp_list_drop_0_r0(root);
    blorp_list_drop_0_r0(beyond);
    assert_frees(root_id, 1);
    assert_frees(beyond_id, 1);
    assert(atomic_load(&pair.entry->references) == 2);
    blorp_list_drop_0_r0(negative);
    assert_frees(negative_id, 1);
    assert_entry_pair_freed(&pair);
}

static void test_set_inline_record(void) {
    blorp_r_2 first = { .blorp_rf_2_0 = INT64_C(1) };
    blorp_r_2 second = { .blorp_rf_2_0 = INT64_C(2) };
    struct blorp_l_0_r2 *root = blorp_list_repeat_0_r2(first, INT64_C(2));
    const size_t root_id = runtime_test_allocation_id(root);
    struct blorp_l_0_r2 *updated = blorp_list_set_0_r2(root, INT64_C(0), second);
    const size_t updated_id = runtime_test_allocation_id(updated);
    assert(allocation_count == 2 && destruction_count == 0);
    assert(updated->values[0].blorp_rf_2_0 == INT64_C(2));
    assert(updated->values[1].blorp_rf_2_0 == INT64_C(1));
    assert(root->values[0].blorp_rf_2_0 == INT64_C(1));
    blorp_list_drop_0_r2(root);
    blorp_list_drop_0_r2(updated);
    assert_frees(root_id, 1);
    assert_frees(updated_id, 1);
}

static void test_concat_entries(void) {
    struct entry_pair pair = make_entry_pair();
    struct blorp_l_0_r0 *root = blorp_list_repeat_0_r0(pair.entry, INT64_C(2));
    const size_t root_id = runtime_test_allocation_id(root);
    struct blorp_l_0_r0 *other_root = blorp_list_repeat_0_r0(pair.other, INT64_C(1));
    const size_t other_root_id = runtime_test_allocation_id(other_root);
    struct blorp_l_0_r0 *joined = blorp_list_concat_0_r0(root, other_root);
    const size_t joined_id = runtime_test_allocation_id(joined);
    assert(allocation_count == 7 && destruction_count == 0);
    assert(blorp_list_length_0_r0(joined) == INT64_C(3));
    assert(joined->values[0] == pair.entry && joined->values[1] == pair.entry);
    assert(joined->values[2] == pair.other);
    assert(atomic_load(&pair.entry->references) == 5);
    assert(atomic_load(&pair.other->references) == 3);
    blorp_record_drop_0(pair.entry);
    blorp_record_drop_0(pair.other);
    blorp_list_drop_0_r0(root);
    blorp_list_drop_0_r0(other_root);
    assert_frees(root_id, 1);
    assert_frees(other_root_id, 1);
    assert(atomic_load(&pair.entry->references) == 2);
    assert(atomic_load(&pair.other->references) == 1);
    assert_text(joined->values[2]->blorp_rf_0_1, "7", INT64_C(1));
    blorp_list_drop_0_r0(joined);
    assert_frees(joined_id, 1);
    assert_entry_pair_freed(&pair);
}

static void test_concat_empty(void) {
    struct blorp_l_0_i *empty = blorp_list_repeat_0_i(INT64_C(0), INT64_C(0));
    const size_t empty_id = runtime_test_allocation_id(empty);
    struct blorp_l_0_i *values = blorp_list_repeat_0_i(INT64_C(3), INT64_C(2));
    const size_t values_id = runtime_test_allocation_id(values);
    struct blorp_l_0_i *both = blorp_list_concat_0_i(empty, empty);
    const size_t both_id = runtime_test_allocation_id(both);
    struct blorp_l_0_i *left = blorp_list_concat_0_i(empty, values);
    const size_t left_id = runtime_test_allocation_id(left);
    struct blorp_l_0_i *right = blorp_list_concat_0_i(values, empty);
    const size_t right_id = runtime_test_allocation_id(right);
    assert(allocation_count == 5 && destruction_count == 0);
    assert(blorp_list_length_0_i(both) == INT64_C(0));
    assert(blorp_list_length_0_i(left) == INT64_C(2) && left->values[1] == INT64_C(3));
    assert(blorp_list_length_0_i(right) == INT64_C(2) && right->values[0] == INT64_C(3));
    blorp_list_drop_0_i(empty);
    blorp_list_drop_0_i(values);
    blorp_list_drop_0_i(both);
    blorp_list_drop_0_i(left);
    blorp_list_drop_0_i(right);
    assert_frees(empty_id, 1);
    assert_frees(values_id, 1);
    assert_frees(both_id, 1);
    assert_frees(left_id, 1);
    assert_frees(right_id, 1);
}

static void test_suffix_mortal_string(void) {
    struct blorp_string *text = blorp_int_to_string(INT64_C(42));
    const size_t text_id = runtime_test_allocation_id(text);
    struct blorp_l_0_s *root = blorp_list_repeat_0_s(text, INT64_C(3));
    const size_t root_id = runtime_test_allocation_id(root);
    blorp_list_dup_0_s(root);
    struct blorp_l_0_s *tail = blorp_list_suffix_0_s(root, INT64_C(1));
    const size_t tail_id = runtime_test_allocation_id(tail);
    assert(root != tail && allocation_count == 3 && destruction_count == 0);
    assert(root->length == 3 && tail->length == 2);
    assert(tail->values[0] == text && tail->values[1] == text);
    assert(atomic_load(&text->references) == 6);
    blorp_list_drop_0_s(root);
    assert_frees(root_id, 0);
    assert(atomic_load(&text->references) == 6);
    blorp_list_drop_0_s(root);
    assert_frees(root_id, 1);
    assert(atomic_load(&text->references) == 3);
    blorp_string_release(text);
    assert(atomic_load(&tail->values[0]->references) == 2);
    assert_text(tail->values[1], "42", INT64_C(2));
    blorp_list_drop_0_s(tail);
    assert_frees(tail_id, 1);
    assert_frees(text_id, 1);
}

static void test_suffix_empty(void) {
    struct blorp_string *text = blorp_int_to_string(INT64_C(42));
    const size_t text_id = runtime_test_allocation_id(text);
    struct blorp_l_0_s *root = blorp_list_repeat_0_s(text, INT64_C(1));
    const size_t root_id = runtime_test_allocation_id(root);
    struct blorp_l_0_s *tail = blorp_list_suffix_0_s(root, INT64_C(1));
    const size_t tail_id = runtime_test_allocation_id(tail);
    assert(root != tail && tail->length == 0 && allocation_count == 3);
    assert(atomic_load(&text->references) == 2);
    blorp_list_drop_0_s(tail);
    assert_frees(tail_id, 1);
    assert(atomic_load(&text->references) == 2);
    blorp_list_drop_0_s(root);
    assert_frees(root_id, 1);
    assert(atomic_load(&text->references) == 1);
    blorp_string_release(text);
    assert_frees(text_id, 1);
}

static void test_suffix_nested(void) {
    struct blorp_string *text = blorp_int_to_string(INT64_C(42));
    const size_t text_id = runtime_test_allocation_id(text);
    struct blorp_l_0_s *child = blorp_list_repeat_0_s(text, INT64_C(1));
    const size_t child_id = runtime_test_allocation_id(child);
    struct blorp_l_1_s *root = blorp_list_repeat_1_s(child, INT64_C(2));
    const size_t root_id = runtime_test_allocation_id(root);
    struct blorp_l_1_s *tail = blorp_list_suffix_1_s(root, INT64_C(1));
    const size_t tail_id = runtime_test_allocation_id(tail);
    assert(root != tail && tail->length == 1 && tail->values[0] == child);
    assert(allocation_count == 4 && atomic_load(&child->references) == 4);
    blorp_list_drop_1_s(root);
    assert_frees(root_id, 1);
    assert(atomic_load(&child->references) == 2);
    blorp_list_drop_0_s(child);
    blorp_string_release(text);
    assert(atomic_load(&tail->values[0]->references) == 1);
    assert_text(tail->values[0]->values[0], "42", INT64_C(2));
    blorp_list_drop_1_s(tail);
    assert_frees(tail_id, 1);
    assert_frees(child_id, 1);
    assert_frees(text_id, 1);
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
    else if (strcmp(argv[1], "append_int") == 0) test_append_int();
    else if (strcmp(argv[1], "append_empty_int") == 0) test_append_empty_int();
    else if (strcmp(argv[1], "append_mortal_string") == 0) test_append_mortal_string();
    else if (strcmp(argv[1], "append_nested") == 0) test_append_nested();
    else if (strcmp(argv[1], "set_entry_in_range") == 0) test_set_entry_in_range();
    else if (strcmp(argv[1], "set_entry_out_of_range") == 0) test_set_entry_out_of_range();
    else if (strcmp(argv[1], "set_inline_record") == 0) test_set_inline_record();
    else if (strcmp(argv[1], "concat_entries") == 0) test_concat_entries();
    else if (strcmp(argv[1], "concat_empty") == 0) test_concat_empty();
    else if (strcmp(argv[1], "suffix_mortal_string") == 0) test_suffix_mortal_string();
    else if (strcmp(argv[1], "suffix_empty") == 0) test_suffix_empty();
    else if (strcmp(argv[1], "suffix_nested") == 0) test_suffix_nested();
    else assert(0 && "unknown generic List runtime case");
    assert(allocation_count == destruction_count);
    return 0;
}
