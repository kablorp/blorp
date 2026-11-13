#include <assert.h>

#include "memory_runtime.c"

/* Each mode reaches its peak through a different operation, so a peak that one
 * of blorp_memory_allocate and blorp_memory_resize fails to raise reports the
 * smaller figure that mode reaches later. Releases never lower the peak. */
enum { SMALL_BYTES = 100, LARGE_BYTES = 200, BELOW_PEAK_BYTES = 250, SHRUNK_BYTES = 50, GROWN_BYTES = 400 };

/* Peak 300: both allocations live at once. Releasing the small one leaves
 * 200, and growing the large one to 250 stays below the peak. */
static void peak_by_allocation(void) {
    void *small = blorp_memory_allocate(SMALL_BYTES);
    void *large = blorp_memory_allocate(LARGE_BYTES);
    blorp_memory_release(small);
    large = blorp_memory_resize(large, BELOW_PEAK_BYTES);
    blorp_memory_release(large);
}

/* Peak 400: one allocation grows from 100 to 400, then shrinks to 50, and a
 * second allocation of 200 leaves 250 live. */
static void peak_by_resize(void) {
    void *resized = blorp_memory_allocate(SMALL_BYTES);
    resized = blorp_memory_resize(resized, GROWN_BYTES);
    resized = blorp_memory_resize(resized, SHRUNK_BYTES);
    void *large = blorp_memory_allocate(LARGE_BYTES);
    blorp_memory_release(resized);
    blorp_memory_release(large);
}

int main(int argc, char **argv) {
    blorp_memory_start();
    assert(argc == 2);
    const char *mode = argv[1];
    if (strcmp(mode, "allocation") == 0) peak_by_allocation();
    else if (strcmp(mode, "resize") == 0) peak_by_resize();
    /* "idle" allocates nothing. */
    else if (strcmp(mode, "idle") != 0) return 2;
    return blorp_memory_finish(0);
}
