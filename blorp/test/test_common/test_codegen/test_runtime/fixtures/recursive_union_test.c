#include <assert.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "tree_memory.c"

/* Each node is one allocation occurrence. A release must name a live
 * occurrence, so a second release of a node aborts, and every occurrence must
 * end released exactly once. */
enum { OBSERVATION_CAPACITY = 64 };
struct observation { void *address; int releases; };
static struct observation observations[OBSERVATION_CAPACITY];
static size_t allocations, releases;

static size_t live_id(void *address) {
    for (size_t index = 0; index < allocations; index++)
        if (observations[index].releases == 0 && observations[index].address == address) return index;
    abort();
}
static void *observed_allocate(size_t bytes) {
    assert(allocations < OBSERVATION_CAPACITY);
    void *address = blorp_memory_allocate(bytes);
    assert(address != NULL);
    observations[allocations++] = (struct observation){address, 0};
    return address;
}
static void observed_release(void *address) {
    if (!address) return;
    observations[live_id(address)].releases++;
    releases++;
    blorp_memory_release(address);
}
#undef blorp_memory_allocate
#undef blorp_memory_release
#define blorp_memory_allocate observed_allocate
#define blorp_memory_release observed_release
#include "tree_values.c"
#undef blorp_memory_allocate
#undef blorp_memory_release

/* `union Tree: Leaf | Node(Tree, Int, Tree)`, the suite's only layout. */
typedef struct blorp_u_0 tree;

static tree *leaf(void) {
    return blorp_union_make_0((tree){.tag = blorp_v_0_0});
}

/* The node takes one reference to each child, as a constructor does. */
static tree *node(tree *left, int64_t key, tree *right) {
    return blorp_union_make_0((tree){.tag = blorp_v_0_1, .payload.blorp_up_1 = {left, key, right}});
}

static int released(size_t id) {
    assert(id < allocations);
    return observations[id].releases;
}

/* One leaf under both slots of a node, and that node under both slots of the
 * root: three objects, each freed once, after its last owner. */
static void shared(void) {
    tree *bottom = leaf();
    blorp_union_dup_0(bottom);
    tree *child = node(bottom, 1, bottom);
    blorp_union_dup_0(child);
    tree *root = node(child, 2, child);
    assert(allocations == 3);
    blorp_union_drop_0(root);
}

/* Releasing a parent leaves a subtree another owner still holds. */
static void retained(void) {
    tree *left_leaf = leaf();
    tree *right_leaf = leaf();
    tree *kept = node(left_leaf, 1, right_leaf);
    blorp_union_dup_0(kept);
    tree *root_leaf = leaf();
    tree *root = node(kept, 2, root_leaf);
    blorp_union_drop_0(root);
    assert(released(4) == 1 && released(3) == 1);
    assert(released(0) == 0 && released(1) == 0 && released(2) == 0);
    blorp_union_drop_0(kept);
}

/* A spine through each of a node's two own payloads. */
static void spines(void) {
    enum { DEPTH = 10 };
    tree *right = leaf();
    for (int64_t key = 0; key < DEPTH; key++) right = node(leaf(), key, right);
    tree *left = leaf();
    for (int64_t key = 0; key < DEPTH; key++) left = node(left, key, leaf());
    blorp_union_drop_0(right);
    blorp_union_drop_0(left);
}

int main(int argc, char **argv) {
    assert(argc == 2);
    blorp_memory_start();
    if (strcmp(argv[1], "shared") == 0) shared();
    else if (strcmp(argv[1], "retained") == 0) retained();
    else if (strcmp(argv[1], "spines") == 0) spines();
    else abort();
    for (size_t id = 0; id < allocations; id++) assert(released(id) == 1);
    assert(allocations > 0 && allocations == releases);
    return blorp_memory_finish(0);
}
