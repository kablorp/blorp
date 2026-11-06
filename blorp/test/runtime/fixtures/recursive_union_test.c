#include <assert.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* A deep chain has far more nodes than a per-object table could hold, so
 * these cases observe allocation and destruction occurrences as counts.
 * Freed nodes are never dereferenced; live counts are read before release. */
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

static struct blorp_u_0 *zero(void) {
    return blorp_union_make_0((struct blorp_u_0){ .tag = blorp_v_0_0 });
}

/* Constructors take completed children: the caller already owns `child`. */
static struct blorp_u_0 *succ(struct blorp_u_0 *child) {
    return blorp_union_make_0((struct blorp_u_0){
        .tag = blorp_v_0_1,
        .payload.blorp_up_1 = { .blorp_uf_0 = child }
    });
}

/* Builds Succ^depth(Zero) iteratively, so construction never uses call depth. */
static struct blorp_u_0 *chain(size_t depth) {
    struct blorp_u_0 *node = zero();
    for (size_t index = 0; index < depth; index += 1) {
        node = succ(node);
    }
    return node;
}

static struct blorp_u_0 *child_of(const struct blorp_u_0 *node) {
    assert(node->tag == blorp_v_0_1);
    return node->payload.blorp_up_1.blorp_uf_0;
}

static void test_leaf_release(void) {
    struct blorp_u_0 *leaf = zero();
    assert(allocation_count == 1 && destruction_count == 0);
    assert(leaf->tag == blorp_v_0_0);
    assert(atomic_load(&leaf->references) == 1);
    blorp_union_drop_0(leaf);
    assert(destruction_count == 1);
}

static void test_chain_release(void) {
    struct blorp_u_0 *root = chain(3);
    assert(allocation_count == 4 && destruction_count == 0);
    assert(child_of(child_of(child_of(root)))->tag == blorp_v_0_0);
    blorp_union_drop_0(root);
    assert(destruction_count == 4);
}

static void test_nonfinal_release(void) {
    struct blorp_u_0 *root = chain(3);
    blorp_union_dup_0(root);
    assert(atomic_load(&root->references) == 2);
    blorp_union_drop_0(root);
    /* A shared root keeps its whole chain; children were never retained. */
    assert(destruction_count == 0);
    assert(atomic_load(&root->references) == 1);
    assert(atomic_load(&child_of(root)->references) == 1);
    blorp_union_drop_0(root);
    assert(destruction_count == 4);
}

static void test_shared_tail(void) {
    struct blorp_u_0 *root = chain(4);
    struct blorp_u_0 *middle = child_of(child_of(root));
    blorp_union_dup_0(middle);
    assert(allocation_count == 5);
    blorp_union_drop_0(root);
    /* The walk frees the two nodes above the retained middle and stops there. */
    assert(destruction_count == 2);
    assert(atomic_load(&middle->references) == 1);
    assert(child_of(child_of(middle))->tag == blorp_v_0_0);
    blorp_union_drop_0(middle);
    assert(destruction_count == 5);
}

static void test_two_roots_one_tail(void) {
    struct blorp_u_0 *tail = chain(2);
    struct blorp_u_0 *first = succ(tail);
    blorp_union_dup_0(tail);
    struct blorp_u_0 *second = succ(tail);
    assert(allocation_count == 5);
    assert(atomic_load(&tail->references) == 2);
    blorp_union_drop_0(first);
    assert(destruction_count == 1);
    assert(atomic_load(&tail->references) == 1);
    blorp_union_drop_0(second);
    assert(destruction_count == 5);
}

/* Final release of a 100,000-deep chain must not grow the C stack with the
 * chain, so it runs on a thread whose whole stack is 512 KiB. A recursive
 * release helper overflows this stack; the iterative walk does not. */
enum { DEEP_CHAIN_DEPTH = 100000, DEEP_STACK_BYTES = 512 * 1024 };

static void *deep_release(void *unused) {
    (void)unused;
    struct blorp_u_0 *root = chain(DEEP_CHAIN_DEPTH);
    assert(allocation_count == DEEP_CHAIN_DEPTH + 1 && destruction_count == 0);
    blorp_union_drop_0(root);
    assert(destruction_count == DEEP_CHAIN_DEPTH + 1);
    return NULL;
}

static void test_deep_release(void) {
    pthread_attr_t attributes;
    pthread_t thread;
    assert(pthread_attr_init(&attributes) == 0);
    assert(pthread_attr_setstacksize(&attributes, DEEP_STACK_BYTES) == 0);
    assert(pthread_create(&thread, &attributes, deep_release, NULL) == 0);
    assert(pthread_join(thread, NULL) == 0);
    assert(pthread_attr_destroy(&attributes) == 0);
    assert(allocation_count == DEEP_CHAIN_DEPTH + 1);
    assert(destruction_count == DEEP_CHAIN_DEPTH + 1);
}

/* Trail is union 1: Step(String, Trail) stores a String beside the self child. */
static struct blorp_u_1 *end(void) {
    return blorp_union_make_1((struct blorp_u_1){ .tag = blorp_v_1_0 });
}

static struct blorp_u_1 *step(struct blorp_string *text, struct blorp_u_1 *child) {
    return blorp_union_make_1((struct blorp_u_1){
        .tag = blorp_v_1_1,
        .payload.blorp_up_1 = { .blorp_uf_0 = text, .blorp_uf_1 = child }
    });
}

static struct blorp_u_1 *trail_child(const struct blorp_u_1 *node) {
    assert(node->tag == blorp_v_1_1);
    return node->payload.blorp_up_1.blorp_uf_1;
}

static void test_sibling_release(void) {
    struct blorp_u_1 *root = step(blorp_int_to_string(INT64_C(7)),
                                  step(blorp_int_to_string(INT64_C(42)), end()));
    /* Two Strings and three nodes. */
    assert(allocation_count == 5 && destruction_count == 0);
    assert(root->payload.blorp_up_1.blorp_uf_0->length == 1);
    assert(trail_child(root)->payload.blorp_up_1.blorp_uf_0->length == 2);
    blorp_union_drop_1(root);
    assert(destruction_count == 5);
}

static void test_sibling_shared_tail(void) {
    struct blorp_u_1 *tail = step(blorp_int_to_string(INT64_C(42)), end());
    struct blorp_u_1 *root = step(blorp_int_to_string(INT64_C(7)), tail);
    blorp_union_dup_1(tail);
    assert(allocation_count == 5);
    blorp_union_drop_1(root);
    /* The root and its own String go; the retained tail keeps its String. */
    assert(destruction_count == 2);
    assert(atomic_load(&tail->references) == 1);
    assert(tail->payload.blorp_up_1.blorp_uf_0->length == 2);
    assert(atomic_load(&tail->payload.blorp_up_1.blorp_uf_0->references) == 1);
    blorp_union_drop_1(tail);
    assert(destruction_count == 5);
}

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    if (strcmp(argv[1], "leaf_release") == 0) test_leaf_release();
    else if (strcmp(argv[1], "chain_release") == 0) test_chain_release();
    else if (strcmp(argv[1], "nonfinal_release") == 0) test_nonfinal_release();
    else if (strcmp(argv[1], "shared_tail") == 0) test_shared_tail();
    else if (strcmp(argv[1], "two_roots_one_tail") == 0) test_two_roots_one_tail();
    else if (strcmp(argv[1], "deep_release") == 0) test_deep_release();
    else if (strcmp(argv[1], "sibling_release") == 0) test_sibling_release();
    else if (strcmp(argv[1], "sibling_shared_tail") == 0) test_sibling_shared_tail();
    else return 2;
    assert(allocation_count == destruction_count);
    return 0;
}
