#include <assert.h>

#include "memory_runtime.c"
#include "string_runtime.c"

/* Two stand-ins for emitted literal sites: backing bytes and a zero-initialized
 * site each, as the emitter declares them inside a function body. */
static const unsigned char shared_bytes[] = {'s', 'h', 'a', 'r', 'e', 'd'};
static const unsigned char other_bytes[] = {'o', 't', 'h', 'e', 'r'};
static struct blorp_string_literal_site shared_site, other_site;
/* Each mode releases the shared site's two evaluations this many times. */
enum { BALANCED_RELEASES = 2, OVER_RELEASES = 3, UNDER_RELEASES = 1 };

static struct blorp_string *evaluate(struct blorp_string_literal_site *site, const unsigned char *bytes, size_t length) {
    return blorp_string_literal(site, (const char *)bytes, (int64_t)length);
}

int main(int argc, char **argv) {
    blorp_memory_start();
    assert(argc == 2);
    const char *mode = argv[1];
    int releases;
    if (strcmp(mode, "balanced") == 0) releases = BALANCED_RELEASES;
    else if (strcmp(mode, "over_release") == 0) releases = OVER_RELEASES;
    else if (strcmp(mode, "under_release") == 0) releases = UNDER_RELEASES;
    else return 2;

    struct blorp_string *first = evaluate(&shared_site, shared_bytes, sizeof shared_bytes);
    struct blorp_string *second = evaluate(&shared_site, shared_bytes, sizeof shared_bytes);
    struct blorp_string *other = evaluate(&other_site, other_bytes, sizeof other_bytes);
    /* One String per site, created on the first evaluation only. */
    assert(first == second && first != other);
    assert(blorp_memory_counts.allocations == 2);
    assert(first->length == (int64_t)sizeof shared_bytes && memcmp(first->bytes, "shared", sizeof shared_bytes) == 0);
    assert(atomic_load(&first->references) == BLORP_STRING_LITERAL_REFERENCES + 2);
    for (int index = 0; index < releases; index++) blorp_string_release(first);
    blorp_string_release(other);
    /* No release frees a literal, balanced or not; the exit teardown does. */
    assert(blorp_memory_counts.releases == 0);
    return blorp_memory_finish(blorp_string_literals_finish(0));
}
