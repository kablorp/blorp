#include <assert.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

enum { PRODUCT_DEPTH = 128, PRODUCT_WIDTH = 128, OBSERVATION_CAPACITY = 1024 };

/* Allocation occurrences, not addresses, are the oracle. Every free selects a
 * still-live occurrence before calling real free; no freed object is read. */
static struct {
    uintptr_t address;
    size_t frees;
} observations[OBSERVATION_CAPACITY];
static size_t allocation_count;

static void *product_allocate(size_t bytes) {
    assert(allocation_count < OBSERVATION_CAPACITY);
    void *result = malloc(bytes);
    assert(result != NULL);
    observations[allocation_count].address = (uintptr_t)result;
    observations[allocation_count].frees = 0;
    allocation_count += 1;
    return result;
}

static size_t allocation_id(const void *value) {
    for (size_t index = 0; index < allocation_count; index += 1) {
        if (observations[index].address == (uintptr_t)value && observations[index].frees == 0) {
            return index;
        }
    }
    assert(0 && "release must refer to a live allocation occurrence");
    abort();
}

static void product_deallocate(void *value) {
    if (value == NULL) return;
    const size_t id = allocation_id(value);
    observations[id].frees += 1;
    free(value);
}

/* Only production runtime fragments are included; no language functions or
 * fixture main are present. The Blorp suite writes both fragments unchanged. */
#define malloc product_allocate
#define free product_deallocate
#include "string_runtime.c"
#include "record_runtime.c"
#undef free
#undef malloc

static void assert_frees(size_t id, size_t expected) {
    assert(id < allocation_count);
    assert(observations[id].frees == expected);
}

static void assert_all_frees(size_t expected) {
    for (size_t id = 0; id < allocation_count; id += 1) assert_frees(id, expected);
}

static blorp_r_0 leaf(int64_t value) {
    return blorp_record_make_0((struct blorp_r_0){
        .blorp_rf_0_0 = { .tag = blorp_v_0_0, .payload.blorp_up_0 = { .blorp_uf_0 = value } },
        .blorp_rf_0_1 = value
    });
}

static blorp_r_0 field(blorp_r_0 child, int64_t span) {
    return blorp_record_make_0((struct blorp_r_0){
        .blorp_rf_0_0 = { .tag = blorp_v_0_2, .payload.blorp_up_2 = { .blorp_uf_0 = child, .blorp_uf_1 = span } },
        .blorp_rf_0_1 = span
    });
}

/* Allocate exactly the initialized slots, as a production literal does. All
 * children passed to these constructors are completed and already owned. */
static struct blorp_l_0_r0 *children(size_t count) {
    struct blorp_l_0_r0 *result = product_allocate(sizeof *result + count * sizeof *result->values);
    atomic_init(&result->references, 1);
    result->length = 0;
    return result;
}

static blorp_r_0 call(struct blorp_l_0_r0 *arguments, int64_t span) {
    return blorp_record_make_0((struct blorp_r_0){
        .blorp_rf_0_0 = { .tag = blorp_v_0_1, .payload.blorp_up_1 = {
            .blorp_uf_0 = blorp_int_to_string(span), .blorp_uf_1 = arguments
        } },
        .blorp_rf_0_1 = span
    });
}

static void test_leaf(void) {
    blorp_r_0 root = leaf(73);
    assert(allocation_count == 1);
    assert(root->blorp_rf_0_0.tag == blorp_v_0_0);
    assert(root->blorp_rf_0_0.payload.blorp_up_0.blorp_uf_0 == 73);
    blorp_record_drop_0(root);
}

static void test_call(void) {
    struct blorp_l_0_r0 *arguments = children(2);
    arguments->values[arguments->length++] = leaf(7);
    arguments->values[arguments->length++] = leaf(42);
    blorp_r_0 root = call(arguments, 73);
    assert(allocation_count == 5);
    assert_all_frees(0);
    blorp_record_drop_0(root);
}

static void test_field(void) {
    blorp_r_0 root = field(leaf(7), 42);
    assert(allocation_count == 2);
    assert_all_frees(0);
    blorp_record_drop_0(root);
}

static void test_nonfinal(void) {
    struct blorp_l_0_r0 *arguments = children(1);
    arguments->values[arguments->length++] = field(leaf(7), 42);
    blorp_r_0 root = call(arguments, 73);
    assert(allocation_count == 5);
    blorp_record_dup_0(root);
    blorp_record_drop_0(root);
    assert_all_frees(0);
    assert(root->blorp_rf_0_0.payload.blorp_up_1.blorp_uf_1->values[0]->blorp_rf_0_1 == 42);
    blorp_record_drop_0(root);
}

static void test_repeated(void) {
    blorp_r_0 shared = field(leaf(7), 42);
    const size_t shared_id = allocation_id(shared);
    const size_t leaf_id = allocation_id(shared->blorp_rf_0_0.payload.blorp_up_2.blorp_uf_0);
    struct blorp_l_0_r0 *arguments = children(2);
    blorp_record_dup_0(shared);
    blorp_record_dup_0(shared);
    arguments->values[arguments->length++] = shared;
    arguments->values[arguments->length++] = shared;
    blorp_r_0 root = call(arguments, 73);
    assert(allocation_count == 5);
    blorp_record_drop_0(root);
    for (size_t id = 0; id < allocation_count; id += 1) {
        assert_frees(id, id == shared_id || id == leaf_id ? 0 : 1);
    }
    assert(atomic_load(&shared->references) == 1);
    assert(shared->blorp_rf_0_1 == 42);
    blorp_record_drop_0(shared);
}

static void test_acquired(void) {
    blorp_r_0 root = field(field(leaf(7), 42), 73);
    blorp_r_0 middle = root->blorp_rf_0_0.payload.blorp_up_2.blorp_uf_0;
    blorp_record_dup_0(middle);
    const size_t root_id = allocation_id(root);
    const size_t middle_id = allocation_id(middle);
    blorp_record_drop_0(root);
    assert_frees(root_id, 1);
    assert_frees(middle_id, 0);
    blorp_r_0 child = middle->blorp_rf_0_0.payload.blorp_up_2.blorp_uf_0;
    const size_t child_id = allocation_id(child);
    blorp_record_dup_0(child);
    blorp_record_drop_0(middle);
    assert_frees(middle_id, 1);
    assert_frees(child_id, 0);
    assert(child->blorp_rf_0_1 == 7);
    blorp_record_drop_0(child);
}

static void test_deep(void) {
    blorp_r_0 root = leaf(0);
    blorp_r_0 retained = NULL;
    size_t retained_count = 0;
    for (int64_t depth = 1; depth <= PRODUCT_DEPTH; depth += 1) {
        if (depth % 2 == 0) {
            struct blorp_l_0_r0 *arguments = children(1);
            arguments->values[arguments->length++] = root;
            root = call(arguments, depth);
        } else {
            root = field(root, depth);
        }
        if (depth == PRODUCT_DEPTH / 2) {
            retained = root;
            blorp_record_dup_0(retained);
            retained_count = allocation_count;
        }
    }
    assert(allocation_count == PRODUCT_DEPTH * 2 + 1);
    assert_all_frees(0);
    blorp_record_drop_0(root);
    for (size_t id = 0; id < allocation_count; id += 1) {
        assert_frees(id, id < retained_count ? 0 : 1);
    }
    assert(retained->blorp_rf_0_1 == PRODUCT_DEPTH / 2);
    blorp_record_drop_0(retained);
}

static void test_wide(void) {
    struct blorp_l_0_r0 *arguments = children(PRODUCT_WIDTH);
    for (int64_t index = 0; index < PRODUCT_WIDTH; index += 1) {
        arguments->values[arguments->length++] = leaf(index);
    }
    for (int64_t index = 0; index < PRODUCT_WIDTH; index += 1) {
        assert(arguments->values[index]->blorp_rf_0_1 == index);
    }
    blorp_r_0 root = call(arguments, 73);
    blorp_r_0 retained = arguments->values[PRODUCT_WIDTH / 2];
    const size_t retained_id = allocation_id(retained);
    blorp_record_dup_0(retained);
    assert(allocation_count == PRODUCT_WIDTH + 3);
    blorp_record_drop_0(root);
    for (size_t id = 0; id < allocation_count; id += 1) assert_frees(id, id == retained_id ? 0 : 1);
    assert(retained->blorp_rf_0_1 == PRODUCT_WIDTH / 2);
    blorp_record_drop_0(retained);
}

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    if (strcmp(argv[1], "leaf") == 0) test_leaf();
    else if (strcmp(argv[1], "call") == 0) test_call();
    else if (strcmp(argv[1], "field") == 0) test_field();
    else if (strcmp(argv[1], "nonfinal") == 0) test_nonfinal();
    else if (strcmp(argv[1], "repeated") == 0) test_repeated();
    else if (strcmp(argv[1], "acquired") == 0) test_acquired();
    else if (strcmp(argv[1], "deep") == 0) test_deep();
    else if (strcmp(argv[1], "wide") == 0) test_wide();
    else return 2;
    assert_all_frees(1);
    return 0;
}
