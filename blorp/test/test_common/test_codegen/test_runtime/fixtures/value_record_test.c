/* Drives the helpers emitted for value_record_suite.brp's SOURCE. The suite
   admits the C names only after checking the program's typed catalogue:
   record 0 is `Named { name: String, count: Int }`, stored by value, and
   record 1 the counted closure environment holding one Named. Each mode
   prints how many allocations a step leaves live beyond those live when it
   began, read from the memory runtime's own counts; the suite runs it under
   the strict leak check, and ASan rejects any use of a released String. */
#include "value_memory.c"
#include "value_records.c"
#include <stdio.h>
#include <string.h>

static size_t live_since(size_t start){return blorp_memory_counts.live-start;}

static blorp_r_0 named(int64_t count){
    return (blorp_r_0){.blorp_rf_0_0=blorp_string_from_bytes("one",3),.blorp_rf_0_1=count};
}

/* A copy acquires the one String; the String is released only by the
   second drop. */
static void copy(void){
    const size_t start=blorp_memory_counts.live;
    blorp_r_0 value=named(1);
    blorp_record_dup_0(value);
    const size_t copied=live_since(start);
    blorp_record_drop_0(value);
    const size_t after_one=live_since(start);
    blorp_record_drop_0(value);
    printf("copied %zu after one drop %zu after both %zu\n",copied,after_one,live_since(start));
}

/* The List buffer holds three copies of the struct; reading one acquires it. */
static void list(void){
    const size_t start=blorp_memory_counts.live;
    blorp_r_0 value=named(2);
    struct blorp_l_0_r0 *values=blorp_list_repeat_0_r0(value,3);
    blorp_record_drop_0(value);
    const size_t stored=live_since(start);
    blorp_r_0 element;
    if(!blorp_list_get_0_r0(values,1,&element))return;
    const size_t read=live_since(start);
    blorp_record_drop_0(element);
    blorp_list_drop_0_r0(values);
    printf("stored %zu read %zu after drop %zu\n",stored,read,live_since(start));
}

/* The environment cell takes the record by value; copying the cell only
   counts the cell, and its last drop releases the record's String. */
static void capture(void){
    const size_t start=blorp_memory_counts.live;
    blorp_r_1 environment=blorp_record_make_1((struct blorp_r_1){.blorp_rf_1_0=named(3)});
    const size_t held=live_since(start);
    blorp_record_dup_1(environment);
    blorp_record_drop_1(environment);
    const size_t after_copy=live_since(start);
    blorp_record_drop_1(environment);
    printf("held %zu after copy %zu after drop %zu\n",held,after_copy,live_since(start));
}

int main(int argc,char **argv){
    blorp_memory_start();
    const char *mode=argc>1?argv[1]:"";
    if(strcmp(mode,"copy")==0)copy();
    else if(strcmp(mode,"list")==0)list();
    else if(strcmp(mode,"capture")==0)capture();
    else return 2;
    return blorp_memory_finish(0);
}
