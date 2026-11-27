#include <assert.h>
#include <pthread.h>

#include "memory_runtime.c"
#include "string_runtime.c"
#include "string_concat.c"

/* Stand-ins for emitted literals: the emitter writes the same declarations. */
BLORP_STATIC_STRING(shared, 6, 6, {'s', 'h', 'a', 'r', 'e', 'd', 0});
BLORP_STATIC_STRING(other, 5, 5, {'o', 't', 'h', 'e', 'r', 0});

/* "é" is two bytes, both above 127, and one code point: a signed char image
 * would overflow here under GCC's -Werror. */
BLORP_STATIC_STRING(accented, 2, 1, {0xc3, 0xa9});

static size_t reference_count(const struct blorp_string *value) {
    return atomic_load(&value->references);
}

/* A read of a literal with bytes above 127 is the object, with its counts. */
static void read_accented(void) {
    struct blorp_string *value = blorp_string_literal_acquire(&accented.value);
    assert(value == &accented.value);
    assert(value->length == 2 && value->code_points == 1);
    assert((unsigned char)value->bytes[0] == 0xc3 && (unsigned char)value->bytes[1] == 0xa9);
    blorp_string_release(value);
}

/* An append to a literal copies it: the result is another String, and the
 * literal keeps its bytes and its count. */
static int copies_on_append(void) {
    struct blorp_string *literal = blorp_string_literal_acquire(&shared.value);
    struct blorp_string *grown = blorp_string_append_bytes_take_left(literal, "!", 1, 1);
    assert(grown != &shared.value && grown->length == 7 && memcmp(grown->bytes, "shared!", 8) == 0);
    assert(shared.value.length == 6 && memcmp(shared.value.bytes, "shared", 7) == 0);
    assert(reference_count(&shared.value) == BLORP_STRING_LITERAL_REFERENCES);
    blorp_string_release(grown);
    read_accented();
    return blorp_memory_finish(blorp_string_literals_finish(0));
}

/* Every thread reads and releases the one literal many times, all starting
 * together. No read allocates, and the count ends where it began. */
enum { READING_THREADS = 8, READS_PER_THREAD = 10000 };
static atomic_int started;

static void *read_repeatedly(void *argument) {
    (void)argument;
    atomic_fetch_add(&started, 1);
    while (atomic_load(&started) < READING_THREADS) {}
    for (int read = 0; read < READS_PER_THREAD; read++) {
        struct blorp_string *value = blorp_string_literal_acquire(&shared.value);
        assert(value == &shared.value);
        blorp_string_release(value);
    }
    return NULL;
}

static int threaded_reads(void) {
    pthread_t threads[READING_THREADS];
    for (size_t thread = 0; thread < READING_THREADS; thread++)
        if (pthread_create(&threads[thread], NULL, read_repeatedly, NULL) != 0) abort();
    for (size_t thread = 0; thread < READING_THREADS; thread++)
        if (pthread_join(threads[thread], NULL) != 0) abort();
    assert(reference_count(&shared.value) == BLORP_STRING_LITERAL_REFERENCES);
    return blorp_memory_finish(blorp_string_literals_finish(0));
}

#if BLORP_MEMORY_DIAGNOSTICS
/* Reads the shared literal twice and `other` once, then releases the shared
 * one `releases` times. */
static int release_shared(int releases) {
    struct blorp_string *first = blorp_string_literal_acquire(&shared.value);
    struct blorp_string *second = blorp_string_literal_acquire(&shared.value);
    struct blorp_string *third = blorp_string_literal_acquire(&other.value);
    /* A read allocates nothing, and every read of a literal is the one object. */
    assert(first == second && first != third);
    assert(blorp_memory_counts.allocations == 0);
    assert(first->length == 6 && memcmp(first->bytes, "shared", 7) == 0);
    assert(reference_count(first) == BLORP_STRING_LITERAL_REFERENCES + 2);
    for (int index = 0; index < releases; index++) blorp_string_release(first);
    blorp_string_release(third);
    /* No release frees a literal, balanced or not, and the exit teardown has
     * nothing to free. */
    assert(blorp_memory_counts.releases == 0);
    return blorp_memory_finish(blorp_string_literals_finish(0));
}

/* One literal is read and never released, and another is released without a
 * read: the finish reports both, and neither hides the other. */
static int two_unbalanced(void) {
    (void)blorp_string_literal_acquire(&shared.value);
    blorp_string_release(&other.value);
    return blorp_memory_finish(blorp_string_literals_finish(0));
}

/* Each diagnostic mode releases the shared literal's two reads this many times. */
enum { BALANCED_RELEASES = 2, OVER_RELEASES = 3, UNDER_RELEASES = 1 };
#else
/* Without diagnostics no read, retain or release writes a literal's count,
 * however unbalanced, while any other String is still counted. */
static int uncounted(void) {
    enum { READS = 3, RETAINS = 2 };
    struct blorp_string *literal = NULL;
    for (int index = 0; index < READS; index++) literal = blorp_string_literal_acquire(&shared.value);
    assert(literal == &shared.value);
    assert(reference_count(literal) == BLORP_STRING_LITERAL_REFERENCES);
    for (int index = 0; index < RETAINS; index++) blorp_string_retain(literal);
    assert(reference_count(literal) == BLORP_STRING_LITERAL_REFERENCES);
    for (int index = 0; index < READS + RETAINS + 1; index++) blorp_string_release(literal);
    assert(reference_count(literal) == BLORP_STRING_LITERAL_REFERENCES);
    /* The literal's bytes are still there, so nothing freed it. */
    assert(memcmp(literal->bytes, "shared", 7) == 0);
    /* Another literal reads as itself, and is no more counted. */
    assert(blorp_string_literal_acquire(&other.value) == &other.value);
    assert(reference_count(&other.value) == BLORP_STRING_LITERAL_REFERENCES);
    struct blorp_string *made = blorp_string_from_bytes("other", 5);
    blorp_string_retain(made);
    assert(reference_count(made) == 2);
    blorp_string_release(made);
    assert(reference_count(made) == 1);
    blorp_string_release(made);
    return blorp_memory_finish(blorp_string_literals_finish(0));
}
#endif

/* "threaded_reads" runs in both memory modes, "uncounted" only without
 * diagnostics, and the others only with them. */
int main(int argc, char **argv) {
    blorp_memory_start();
    assert(argc == 2);
    const char *mode = argv[1];
    if (strcmp(mode, "threaded_reads") == 0) return threaded_reads();
    if (strcmp(mode, "copies_on_append") == 0) return copies_on_append();
#if BLORP_MEMORY_DIAGNOSTICS
    if (strcmp(mode, "balanced") == 0) return release_shared(BALANCED_RELEASES);
    if (strcmp(mode, "over_release") == 0) return release_shared(OVER_RELEASES);
    if (strcmp(mode, "under_release") == 0) return release_shared(UNDER_RELEASES);
    if (strcmp(mode, "two_unbalanced") == 0) return two_unbalanced();
#else
    if (strcmp(mode, "uncounted") == 0) return uncounted();
#endif
    return 2;
}
