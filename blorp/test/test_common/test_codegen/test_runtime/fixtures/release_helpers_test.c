/* Builds deep values with the helpers emitted for release_suite.brp's
   HELPERS_SOURCE and releases each from a thread with a 512 KB stack, where a
   release that recursed through the value would overflow. The suite admits
   the C names only after checking the program's typed catalogue: record 0 is
   `Node { value: Int, next: Option[Node] }`, a counted record, record 1 is
   `Branch { value: Int, children: List[Branch] }`, stored by value because its
   one counted pointer is its List, union 0 is `Option[Node]`
   stored inline (variant 0 `Some`, variant 1 `None`), union 1 is the boxed
   `Nat` (variant 0 `Zero`, variant 1 `Succ`) and union 2 is the boxed `Tree`
   (variant 0 `Leaf`, variant 1 `Fork(Tree, Int, Tree)`). Each mode prints how
   many values it built; the suite runs it under the strict leak check. */
#include "release_memory.c"
#include "release_values.c"
#include <pthread.h>
#include <stdio.h>
#include <string.h>

enum {DEPTH=1000000,RELEASE_STACK_BYTES=512*1024};

static size_t built;

/* A chain of records through the inline `Option[Node]`. */
static void record_chain(void){
    struct blorp_u_0 next={.tag=blorp_v_0_1};
    for(int64_t index=0;index<DEPTH;index++){
        blorp_r_0 node=blorp_record_make_0((struct blorp_r_0){.blorp_rf_0_0=index,.blorp_rf_0_1=next});
        next=(struct blorp_u_0){.tag=blorp_v_0_0,.payload.blorp_up_0.blorp_uf_0=node};
        built++;
    }
    blorp_union_drop_0(next);
}

/* A chain of records through Lists: each Branch's one child is the last.
   A Branch is a struct; repeating no element reads none. */
static void list_chain(void){
    blorp_r_1 head={.blorp_rf_1_0=0,.blorp_rf_1_1=blorp_list_repeat_0_r1((blorp_r_1){.blorp_rf_1_0=0},0)};
    built++;
    for(int64_t index=1;index<DEPTH;index++){
        struct blorp_l_0_r1 *children=blorp_list_repeat_0_r1(head,1);
        blorp_record_drop_1(head);
        head=(blorp_r_1){.blorp_rf_1_0=index,.blorp_rf_1_1=children};
        built++;
    }
    blorp_record_drop_1(head);
}

/* A chain of boxed `Succ` nodes. */
static void boxed_chain(void){
    struct blorp_u_1 *head=blorp_union_make_1((struct blorp_u_1){.tag=blorp_v_1_0});
    built++;
    for(int64_t index=1;index<DEPTH;index++){
        head=blorp_union_make_1((struct blorp_u_1){.tag=blorp_v_1_1,.payload.blorp_up_1.blorp_uf_0=head});
        built++;
    }
    blorp_union_drop_1(head);
}

/* A left spine of `Fork` nodes, each holding the spine so far on its left
   and one shared `Leaf` on its right: both of a node's own payloads release. */
static void tree_left_spine(void){
    struct blorp_u_2 *leaf=blorp_union_make_2((struct blorp_u_2){.tag=blorp_v_2_0});
    struct blorp_u_2 *head=blorp_union_make_2((struct blorp_u_2){.tag=blorp_v_2_0});
    built++;
    for(int64_t index=1;index<DEPTH;index++){
        blorp_union_dup_2(leaf);
        head=blorp_union_make_2((struct blorp_u_2){.tag=blorp_v_2_1,.payload.blorp_up_1={head,index,leaf}});
        built++;
    }
    blorp_union_drop_2(leaf);
    blorp_union_drop_2(head);
}

struct release_job {void (*release)(void);};

static void *run(void *job){
    ((struct release_job *)job)->release();
    return NULL;
}

/* Runs `release` on a thread whose stack holds RELEASE_STACK_BYTES. */
static int on_small_stack(void (*release)(void)){
    pthread_attr_t attributes;
    pthread_t thread;
    if(pthread_attr_init(&attributes)!=0)return 1;
    if(pthread_attr_setstacksize(&attributes,RELEASE_STACK_BYTES)!=0)return 1;
    struct release_job job={release};
    if(pthread_create(&thread,&attributes,run,&job)!=0)return 1;
    if(pthread_join(thread,NULL)!=0)return 1;
    pthread_attr_destroy(&attributes);
    printf("built %zu\n",built);
    return 0;
}

int main(int argc,char **argv){
    blorp_memory_start();
    const char *mode=argc>1?argv[1]:"";
    int status;
    if(strcmp(mode,"record-chain")==0)status=on_small_stack(record_chain);
    else if(strcmp(mode,"list-chain")==0)status=on_small_stack(list_chain);
    else if(strcmp(mode,"boxed-chain")==0)status=on_small_stack(boxed_chain);
    else if(strcmp(mode,"tree-left-spine")==0)status=on_small_stack(tree_left_spine);
    else return 2;
    if(status!=0)return status;
    return blorp_memory_finish(0);
}
