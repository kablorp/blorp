#include <assert.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Deep and wide structures have far more nodes than a per-object table could
 * hold, so these cases observe allocation and destruction as counts. Freed
 * objects are never dereferenced. */
static size_t allocation_count;
static size_t destruction_count;

static void *runtime_test_allocate(size_t bytes) {
    void *result = malloc(bytes);
    assert(result != NULL);
    allocation_count += 1;
    return result;
}

static void runtime_test_deallocate(void *value) {
    if (value == NULL) return;
    destruction_count += 1;
    free(value);
}

/* Both includes are written by the Blorp TestSuite from the same pure
 * production emission functions used by normal compilation. */
#define malloc runtime_test_allocate
#define free runtime_test_deallocate
#include "string_runtime.c"
#include "record_runtime.c"
#undef free
#undef malloc

/* Expr is record 0 { form: Form, span: Int }; Form is union 0 with
 * Leaf(Int) = variant 0, Call(String, List[Expr]) = variant 1 and
 * Field(Expr, Int) = variant 2. */
static blorp_r_0 leaf(int64_t value) {
    return blorp_record_make_0((struct blorp_r_0){
        .blorp_rf_0_0 = { .tag = blorp_v_0_0, .payload.blorp_up_0 = { .blorp_uf_0 = value } },
        .blorp_rf_0_1 = value
    });
}

/* Constructors take completed children: the caller already owns `inner`. */
static blorp_r_0 field(blorp_r_0 inner, int64_t span) {
    return blorp_record_make_0((struct blorp_r_0){
        .blorp_rf_0_0 = { .tag = blorp_v_0_2, .payload.blorp_up_2 = { .blorp_uf_0 = inner, .blorp_uf_1 = span } },
        .blorp_rf_0_1 = span
    });
}

/* A fresh List root over `count` leaves, built the way an emitted literal is
 * and counted like every other allocation. */
static struct blorp_l_0_r0 *leaves(size_t count) {
    struct blorp_l_0_r0 *root = runtime_test_allocate(sizeof *root + count * sizeof *root->values);
    assert(root != NULL);
    atomic_init(&root->references, 1);
    root->length = 0;
    for (size_t index = 0; index < count; index += 1) {
        root->values[index] = leaf((int64_t)index);
        root->length += 1;
    }
    return root;
}

static blorp_r_0 call(struct blorp_string *name, struct blorp_l_0_r0 *arguments, int64_t span) {
    return blorp_record_make_0((struct blorp_r_0){
        .blorp_rf_0_0 = { .tag = blorp_v_0_1, .payload.blorp_up_1 = { .blorp_uf_0 = name, .blorp_uf_1 = arguments } },
        .blorp_rf_0_1 = span
    });
}

static void test_field_chain_release(void) {
    blorp_r_0 root = field(field(leaf(1), 2), 3);
    assert(allocation_count == 3 && destruction_count == 0);
    blorp_record_drop_0(root);
    assert(destruction_count == 3);
}

static void test_call_with_list_release(void) {
    blorp_r_0 root = call(blorp_int_to_string(INT64_C(7)), leaves(3), 9);
    /* three leaves, the list root, the String, the call node */
    assert(allocation_count == 6 && destruction_count == 0);
    blorp_record_drop_0(root);
    assert(destruction_count == 6);
}

static void test_shared_subtree_survives_its_first_parent(void) {
    blorp_r_0 shared = leaf(5);
    blorp_record_dup_0(shared);
    blorp_r_0 first = field(shared, 1);
    blorp_r_0 second = field(shared, 2);
    assert(allocation_count == 3);
    blorp_record_drop_0(first);
    assert(destruction_count == 1);
    assert(atomic_load(&shared->references) == 1);
    assert(shared->blorp_rf_0_1 == 5);
    blorp_record_drop_0(second);
    assert(destruction_count == 3);
}

static void test_nonfinal_release_keeps_the_tree(void) {
    blorp_r_0 root = call(blorp_int_to_string(INT64_C(7)), leaves(2), 9);
    blorp_record_dup_0(root);
    blorp_record_drop_0(root);
    assert(destruction_count == 0);
    assert(root->blorp_rf_0_0.payload.blorp_up_1.blorp_uf_1->length == 2);
    blorp_record_drop_0(root);
    assert(destruction_count == 5);
}

/* The group's release helpers call one another directly, so release depth
 * follows structure depth; these cases run on the default stack. The deep
 * case alternates Field nodes with one-element Call lists, as nested checked
 * expressions do. */
enum { DEEP_DEPTH = 1000, WIDE_COUNT = 100000 };

static void test_deep_release(void) {
    blorp_r_0 root = leaf(0);
    for (int64_t depth = 1; depth <= DEEP_DEPTH; depth += 1) {
        if (depth % 2 == 0) {
            struct blorp_l_0_r0 *arguments = runtime_test_allocate(sizeof *arguments + sizeof *arguments->values);
            atomic_init(&arguments->references, 1);
            arguments->length = 1;
            arguments->values[0] = root;
            root = call(blorp_int_to_string(depth), arguments, depth);
        } else {
            root = field(root, depth);
        }
    }
    /* one node per level plus the leaf; each Call level adds its String and List */
    const size_t expected = DEEP_DEPTH + 1 + DEEP_DEPTH;
    assert(allocation_count == expected && destruction_count == 0);
    blorp_record_drop_0(root);
    assert(destruction_count == expected);
}

static void test_wide_release(void) {
    blorp_r_0 root = call(blorp_int_to_string(INT64_C(1)), leaves(WIDE_COUNT), 1);
    assert(allocation_count == WIDE_COUNT + 3 && destruction_count == 0);
    blorp_record_drop_0(root);
    assert(destruction_count == WIDE_COUNT + 3);
}

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    if (strcmp(argv[1], "field_chain") == 0) test_field_chain_release();
    else if (strcmp(argv[1], "call_list") == 0) test_call_with_list_release();
    else if (strcmp(argv[1], "shared_subtree") == 0) test_shared_subtree_survives_its_first_parent();
    else if (strcmp(argv[1], "nonfinal") == 0) test_nonfinal_release_keeps_the_tree();
    else if (strcmp(argv[1], "deep") == 0) test_deep_release();
    else if (strcmp(argv[1], "wide") == 0) test_wide_release();
    else return 2;
    assert(allocation_count == destruction_count);
    return 0;
}
