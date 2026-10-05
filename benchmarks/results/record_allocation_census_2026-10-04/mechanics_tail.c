/* Separately tests counters and real emitted makers/reuse under pthreads. */
static void* s5_worker(void* unused) {
    (void)unused;
    for (long i = 0; i < 10; i++) {
        brp_ty1* scalar = brp_ty1_make(i);
        BLORP_INSTALL_TAG(scalar, "FreshScalar");
        BLORP_INSTALL_TAG(scalar, "FreshScalar");
        blorp_release(scalar);
        brp_ty3* base = brp_ty3_make(i, 2);
        blorp_retain(base);
        brp_ty3* changed = __blorp_reuse_record_brp_ty3(base, i + 1, 2);
        if (changed == base) abort();
        blorp_release(base);
        blorp_release(changed);
    }
    return NULL;
}
int main(void) {
    pthread_t threads[4];
    for (unsigned i = 0; i < 4; i++)
        if (pthread_create(&threads[i], NULL, s5_worker, NULL)) abort();
    for (unsigned i = 0; i < 4; i++)
        if (pthread_join(threads[i], NULL)) abort();
    brp_ty2* unique = brp_ty2_make(1, 2);
    brp_ty2* updated = __blorp_reuse_record_brp_ty2(unique, 3, 2);
    if (updated != unique) abort();
    blorp_release(updated);
    if (atomic_load(&s5_counts[84]) != 40 || atomic_load(&s5_counts[86]) != 80 || atomic_load(&s5_counts[85]) != 1) abort();
    puts("S5_MECHANICS_OK fresh=40 shared=80 unique=1 reinstall_extra=0 joined_threads=4");
    return 0;
}
