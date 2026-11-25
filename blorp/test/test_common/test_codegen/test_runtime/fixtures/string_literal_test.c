#include <assert.h>
#include <pthread.h>

#include "memory_runtime.c"
#include "string_runtime.c"

/* Backing bytes for stand-ins for emitted literal sites. Each site is a
 * zero-initialized static, which the emitter declares inside a function body. */
static const unsigned char shared_bytes[] = {'s', 'h', 'a', 'r', 'e', 'd'};

static struct blorp_string *evaluate(struct blorp_string_literal_site *site, const unsigned char *bytes, size_t length) {
    return blorp_string_literal(site, (const char *)bytes, (int64_t)length);
}

static size_t reference_count(const struct blorp_string *value) {
    return atomic_load(&value->references);
}

/* Every thread evaluates each raced site once, all starting together, so many
 * threads find a site empty at once. Each keeps what it got until all are done. */
enum { RACING_THREADS = 8, RACED_SITES = 64 };
static struct blorp_string_literal_site raced_sites[RACED_SITES];
static struct blorp_string *raced[RACING_THREADS][RACED_SITES];
static atomic_int started;

static void *race(void *argument) {
    struct blorp_string **evaluated = argument;
    atomic_fetch_add(&started, 1);
    while (atomic_load(&started) < RACING_THREADS) {}
    for (size_t site = 0; site < RACED_SITES; site++) evaluated[site] = evaluate(&raced_sites[site], shared_bytes, sizeof shared_bytes);
    return NULL;
}

/* One String per site, which every thread shares; in the diagnostics build,
 * teardown balances too. */
static int threaded_publish(void) {
    pthread_t threads[RACING_THREADS];
    for (size_t thread = 0; thread < RACING_THREADS; thread++)
        if (pthread_create(&threads[thread], NULL, race, raced[thread]) != 0) abort();
    for (size_t thread = 0; thread < RACING_THREADS; thread++)
        if (pthread_join(threads[thread], NULL) != 0) abort();
#if BLORP_MEMORY_DIAGNOSTICS
    assert(blorp_memory_counts.allocations == RACED_SITES);
#endif
    for (size_t site = 0; site < RACED_SITES; site++) {
        for (size_t thread = 0; thread < RACING_THREADS; thread++) {
            assert(raced[thread][site] == raced[0][site]);
            blorp_string_release(raced[thread][site]);
        }
        assert(reference_count(raced[0][site]) == BLORP_STRING_LITERAL_REFERENCES);
    }
    return blorp_memory_finish(blorp_string_literals_finish(0));
}

#if BLORP_MEMORY_DIAGNOSTICS
/* Releases the shared site's two evaluations `releases` times. */
static int release_shared(int releases) {
    static const unsigned char other_bytes[] = {'o', 't', 'h', 'e', 'r'};
    static struct blorp_string_literal_site shared_site, other_site;
    struct blorp_string *first = evaluate(&shared_site, shared_bytes, sizeof shared_bytes);
    struct blorp_string *second = evaluate(&shared_site, shared_bytes, sizeof shared_bytes);
    struct blorp_string *other = evaluate(&other_site, other_bytes, sizeof other_bytes);
    /* One String per site, created on the first evaluation only. */
    assert(first == second && first != other);
    assert(blorp_memory_counts.allocations == 2);
    assert(first->length == (int64_t)sizeof shared_bytes && memcmp(first->bytes, "shared", sizeof shared_bytes) == 0);
    assert(reference_count(first) == BLORP_STRING_LITERAL_REFERENCES + 2);
    for (int index = 0; index < releases; index++) blorp_string_release(first);
    blorp_string_release(other);
    /* No release frees a literal, balanced or not; the exit teardown does. */
    assert(blorp_memory_counts.releases == 0);
    return blorp_memory_finish(blorp_string_literals_finish(0));
}

/* Each diagnostic mode releases the shared site's two evaluations this many times. */
enum { BALANCED_RELEASES = 2, OVER_RELEASES = 3, UNDER_RELEASES = 1 };
#else
/* Without diagnostics no evaluation, retain or release writes a literal's
 * count, however unbalanced, while any other String is still counted. */
static int uncounted(void) {
    enum { EVALUATIONS = 3, RETAINS = 2 };
    static const unsigned char other_bytes[] = {'o', 't', 'h', 'e', 'r'};
    static struct blorp_string_literal_site site;
    struct blorp_string *literal = NULL;
    for (int index = 0; index < EVALUATIONS; index++) literal = evaluate(&site, shared_bytes, sizeof shared_bytes);
    assert(reference_count(literal) == BLORP_STRING_LITERAL_REFERENCES);
    for (int index = 0; index < RETAINS; index++) blorp_string_retain(literal);
    assert(reference_count(literal) == BLORP_STRING_LITERAL_REFERENCES);
    for (int index = 0; index < EVALUATIONS + RETAINS + 1; index++) blorp_string_release(literal);
    assert(reference_count(literal) == BLORP_STRING_LITERAL_REFERENCES);
    struct blorp_string *made = blorp_string_from_bytes((const char *)other_bytes, (int64_t)sizeof other_bytes);
    blorp_string_retain(made);
    assert(reference_count(made) == 2);
    blorp_string_release(made);
    assert(reference_count(made) == 1);
    blorp_string_release(made);
    return blorp_memory_finish(blorp_string_literals_finish(0));
}
#endif

/* "threaded_publish" runs in both memory modes, "uncounted" only without
 * diagnostics, and the others only with them. */
int main(int argc, char **argv) {
    blorp_memory_start();
    assert(argc == 2);
    const char *mode = argv[1];
    if (strcmp(mode, "threaded_publish") == 0) return threaded_publish();
#if BLORP_MEMORY_DIAGNOSTICS
    if (strcmp(mode, "balanced") == 0) return release_shared(BALANCED_RELEASES);
    if (strcmp(mode, "over_release") == 0) return release_shared(OVER_RELEASES);
    if (strcmp(mode, "under_release") == 0) return release_shared(UNDER_RELEASES);
#else
    if (strcmp(mode, "uncounted") == 0) return uncounted();
#endif
    return 2;
}
