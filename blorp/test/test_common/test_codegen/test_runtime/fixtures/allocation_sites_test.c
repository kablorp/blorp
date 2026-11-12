#include "memory_runtime.c"

/* Two callers allocate a different number of times. Their names follow the
 * emitter's blorp_f_N scheme and the comments its module.function convention,
 * which the symbolizer maps back. */
enum { FIRST_ALLOCATIONS = 3, SECOND_ALLOCATIONS = 5, FIRST_BYTES = 8, SECOND_BYTES = 16, RESIZED_BYTES = 32 };
static void *kept[FIRST_ALLOCATIONS + SECOND_ALLOCATIONS];

/* Stands in for a runtime helper with an arbitrary name: the symbolizer charges blorp_f_20 and names this as its helper. */
static void *allocate_through_helper(size_t bytes) {
    return blorp_memory_allocate(bytes);
}

/* fixture.first */
static void blorp_f_10(void) {
    for (size_t index = 0; index < FIRST_ALLOCATIONS; index++) kept[index] = blorp_memory_allocate(FIRST_BYTES);
}

/* blorp_f_20 returns a pointer, as most emitted functions do, so a star sits between its label and its name. */
/* fixture.second */
static void **blorp_f_20(void) {
    for (size_t index = 0; index < SECOND_ALLOCATIONS; index++)
        kept[FIRST_ALLOCATIONS + index] = allocate_through_helper(SECOND_BYTES);
    kept[FIRST_ALLOCATIONS] = blorp_memory_resize(kept[FIRST_ALLOCATIONS], RESIZED_BYTES);
    return kept;
}

int main(int argc, char **argv) {
    blorp_memory_start();
    /* "idle" allocates nothing, so the table never exists when the report is written. */
    if (argc > 1 && strcmp(argv[1], "idle") == 0) return blorp_memory_finish(0);
    blorp_f_10();
    blorp_f_20();
    for (size_t index = 0; index < FIRST_ALLOCATIONS + SECOND_ALLOCATIONS; index++) blorp_memory_release(kept[index]);
    return blorp_memory_finish(0);
}
