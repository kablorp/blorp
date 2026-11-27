/* Drives the helpers emitted for static_object_suite.brp's SOURCE on static
   objects written as the emitter writes a constant's. The suite admits the C
   names only after checking the program's typed catalogue: record 0 is
   `Entry { text: String, note: String }`, a counted record, and the Lists are
   of Entry and of String. */
#include <assert.h>
#include <pthread.h>

#include "static_memory.c"
#include "static_values.c"

BLORP_STATIC_STRING(text, 4, 4, {'t', 'e', 'x', 't'});
BLORP_STATIC_STRING(note, 4, 4, {'n', 'o', 't', 'e'});
static struct blorp_r_0 entry = {BLORP_STATIC_RECORD_REFERENCES, .blorp_rf_0_0 = &text.value, .blorp_rf_0_1 = &note.value};
BLORP_STATIC_LIST(entries, blorp_l_0_r0, blorp_r_0, 2, {&entry, &entry});
BLORP_STATIC_LIST(texts, blorp_l_0_s, struct blorp_string *, 1, {&text.value});

static void at_bases(void) {
    assert(atomic_load(&entries.value.references) == BLORP_STATIC_REFERENCES);
    assert(atomic_load(&texts.value.references) == BLORP_STATIC_REFERENCES);
    assert(atomic_load(&entry.references) == BLORP_STATIC_RECORD_REFERENCES);
    assert(atomic_load(&text.value.references) == BLORP_STATIC_REFERENCES);
}

/* Every retain and release is balanced, and none frees a static object. */
static int never_freed(void) {
    enum { COPIES = 3 };
    for (int copy = 0; copy < COPIES; copy++) {
        blorp_list_dup_0_r0(&entries.value);
        blorp_record_dup_0(&entry);
    }
    for (int copy = 0; copy < COPIES; copy++) {
        blorp_list_drop_0_r0(&entries.value);
        blorp_record_drop_0(&entry);
    }
    at_bases();
    assert(entries.value.length == 2 && entries.value.values[1] == &entry);
    return blorp_memory_finish(0);
}

/* An update of an owned copy of a static List copies it, and leaves the
   static List as it was. A record update builds a new record from the
   static one's acquired fields. */
static int copies_on_update(void) {
    blorp_list_dup_0_r0(&entries.value);
    struct blorp_l_0_r0 *grown = blorp_list_append_take_left_0_r0(&entries.value, &entry);
    assert(grown != &entries.value && grown->length == 3 && grown->values[2] == &entry);
    blorp_list_dup_0_s(&texts.value);
    struct blorp_string *replacement = blorp_string_from_bytes("next", 4);
    struct blorp_l_0_s *replaced = blorp_list_set_take_left_0_s(&texts.value, 0, replacement);
    assert(replaced != &texts.value && texts.value.values[0] == &text.value);
    /* The set acquired its own reference, so the record takes this one. */
    blorp_string_retain(entry.blorp_rf_0_0);
    blorp_r_0 updated = blorp_record_make_0((struct blorp_r_0){.blorp_rf_0_0 = entry.blorp_rf_0_0, .blorp_rf_0_1 = replacement});
    assert(updated != &entry && entry.blorp_rf_0_1 == &note.value);
    blorp_record_drop_0(updated);
    blorp_list_drop_0_r0(grown);
    blorp_list_drop_0_s(replaced);
    at_bases();
    return blorp_memory_finish(0);
}

/* Every thread copies and drops the static List and record many times, all
   starting together, and the counts end where they began. */
enum { READING_THREADS = 8, READS_PER_THREAD = 10000 };
static atomic_int started;

static void *read_repeatedly(void *argument) {
    (void)argument;
    atomic_fetch_add(&started, 1);
    while (atomic_load(&started) < READING_THREADS) {}
    for (int read = 0; read < READS_PER_THREAD; read++) {
        blorp_list_dup_0_r0(&entries.value);
        blorp_record_dup_0(&entry);
        blorp_record_drop_0(&entry);
        blorp_list_drop_0_r0(&entries.value);
    }
    return NULL;
}

static int threaded_reads(void) {
    pthread_t threads[READING_THREADS];
    for (size_t thread = 0; thread < READING_THREADS; thread++)
        if (pthread_create(&threads[thread], NULL, read_repeatedly, NULL) != 0) abort();
    for (size_t thread = 0; thread < READING_THREADS; thread++)
        if (pthread_join(threads[thread], NULL) != 0) abort();
    at_bases();
    return blorp_memory_finish(0);
}

#if BLORP_MEMORY_DIAGNOSTICS
/* A List is retained and not released, and a record released once more than
   it was retained: the finish reports both. */
static int unbalanced(void) {
    blorp_list_dup_0_r0(&entries.value);
    blorp_record_drop_0(&entry);
    return blorp_memory_finish(0);
}
#endif

/* "unbalanced" runs only with diagnostics; the others in both memory modes. */
int main(int argc, char **argv) {
    blorp_memory_start();
    assert(argc == 2);
    const char *mode = argv[1];
    if (strcmp(mode, "never_freed") == 0) return never_freed();
    if (strcmp(mode, "copies_on_update") == 0) return copies_on_update();
    if (strcmp(mode, "threaded_reads") == 0) return threaded_reads();
#if BLORP_MEMORY_DIAGNOSTICS
    if (strcmp(mode, "unbalanced") == 0) return unbalanced();
#endif
    return 2;
}
