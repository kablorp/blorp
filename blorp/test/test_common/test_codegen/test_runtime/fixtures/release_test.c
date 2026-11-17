/* Exercises the release scheduler (RELEASE_RUNTIME) through two test-local
   counted layouts written to the emitted protocol: a node with one child, and
   a pair with a node child and a pair child, so parked objects of two kinds
   interleave. The suite writes memory_runtime.c (MEMORY_RUNTIME) and
   release_runtime.c (RELEASE_RUNTIME); this file declares the kinds before
   the runtime and defines the dispatch after its layouts, as emission does.
   Each mode prints one line of observations; the suite runs it under the
   strict leak check. */
#include "memory_runtime.c"
#include <assert.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

enum blorp_release_kind{test_node_kind,test_pair_kind,blorp_release_kinds};
#include "release_runtime.c"

struct test_node{_Atomic uint64_t references;struct test_node *child;};
struct test_pair{_Atomic uint64_t references;struct test_node *node;struct test_pair *pair;};

/* Observations: the deepest depth any release body ran at, how many parked
   objects the run dispatched, and how many objects were released. */
static unsigned deepest;
static size_t dispatched;
static size_t released;

static void test_node_release(struct test_node *value,unsigned depth);
static void test_pair_release(struct test_pair *value,unsigned depth);

static void test_node_drop_at(struct test_node *value,unsigned depth){
    if(value==NULL)return;
    if(atomic_fetch_sub_explicit(&value->references,UINT64_C(1),memory_order_acq_rel)!=UINT64_C(1))return;
    if(depth<BLORP_RELEASE_DEPTH_LIMIT){test_node_release(value,depth+1);return;}
    blorp_release_deep(test_node_kind,value);
}

static void test_pair_drop_at(struct test_pair *value,unsigned depth){
    if(value==NULL)return;
    if(atomic_fetch_sub_explicit(&value->references,UINT64_C(1),memory_order_acq_rel)!=UINT64_C(1))return;
    if(depth<BLORP_RELEASE_DEPTH_LIMIT){test_pair_release(value,depth+1);return;}
    blorp_release_deep(test_pair_kind,value);
}

static void observe(unsigned depth){
    if(depth>deepest)deepest=depth;
    released++;
}

static void test_node_release(struct test_node *value,unsigned depth){
    observe(depth);
    test_node_drop_at(value->child,depth);
    blorp_memory_release(value);
}

static void test_pair_release(struct test_pair *value,unsigned depth){
    observe(depth);
    test_node_drop_at(value->node,depth);
    test_pair_drop_at(value->pair,depth);
    blorp_memory_release(value);
}

static void blorp_release_dispatch(enum blorp_release_kind kind,void *dead){
    dispatched++;
    switch(kind){
    case test_node_kind:test_node_release(dead,1);break;
    case test_pair_kind:test_pair_release(dead,1);break;
    case blorp_release_kinds:abort();
    }
}

static struct test_node *node(struct test_node *child){
    struct test_node *value=blorp_memory_allocate(sizeof *value);
    if(value==NULL)abort();
    atomic_init(&value->references,UINT64_C(1));
    value->child=child;
    return value;
}

static struct test_pair *pair(struct test_node *child,struct test_pair *next){
    struct test_pair *value=blorp_memory_allocate(sizeof *value);
    if(value==NULL)abort();
    atomic_init(&value->references,UINT64_C(1));
    value->node=child;
    value->pair=next;
    return value;
}

static struct test_node *chain(size_t length){
    struct test_node *head=NULL;
    for(size_t index=0;index<length;index++)head=node(head);
    return head;
}

/* Releases `head` from the top level and prints what the release did:
   objects released, parked objects dispatched, the deepest release depth,
   allocations made during the release, and whether the run ended. */
static void release_chain(size_t length){
    struct test_node *head=chain(length);
    const size_t allocations=blorp_memory_counts.allocations;
    test_node_drop_at(head,0);
    printf("released %zu dispatched %zu deepest %u allocated %zu running %d\n",
           released,dispatched,deepest,blorp_memory_counts.allocations-allocations,blorp_release_state.running);
}

/* A spine of pairs, each holding a chain of nodes as deep as the limit, so
   parked nodes and parked pairs wait in the same run. */
static void release_mixed(size_t spine,size_t branch){
    struct test_pair *head=NULL;
    for(size_t index=0;index<spine;index++)head=pair(chain(branch),head);
    const size_t allocations=blorp_memory_counts.allocations;
    test_pair_drop_at(head,0);
    printf("released %zu dispatched %zu deepest %u allocated %zu running %d\n",
           released,dispatched,deepest,blorp_memory_counts.allocations-allocations,blorp_release_state.running);
}

/* A shared child survives its first parent's release and dies with the second. */
static void release_shared(void){
    struct test_node *shared=chain(BLORP_RELEASE_DEPTH_LIMIT*3);
    atomic_fetch_add_explicit(&shared->references,UINT64_C(1),memory_order_relaxed);
    struct test_node *first=node(shared);
    struct test_node *second=node(shared);
    test_node_drop_at(first,0);
    printf("after first released %zu\n",released);
    test_node_drop_at(second,0);
    printf("after second released %zu dispatched %zu running %d\n",released,dispatched,blorp_release_state.running);
}

int main(int argc,char **argv){
    blorp_memory_start();
    const char *mode=argc>1?argv[1]:"";
    if(strcmp(mode,"under-limit")==0)release_chain(BLORP_RELEASE_DEPTH_LIMIT);
    else if(strcmp(mode,"at-limit")==0)release_chain(BLORP_RELEASE_DEPTH_LIMIT+1);
    else if(strcmp(mode,"deep")==0)release_chain(1000000);
    else if(strcmp(mode,"mixed")==0)release_mixed(1000,BLORP_RELEASE_DEPTH_LIMIT);
    else if(strcmp(mode,"shared")==0)release_shared();
    else return 2;
    return blorp_memory_finish(0);
}
