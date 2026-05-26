#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

typedef struct {
    int worker_id;
    int workers;
    int items;
    int rounds;
    int64_t checksum;
} WorkerArgs;

static int env_int(const char *name, int fallback) {
    const char *raw = getenv(name);
    char *end = NULL;
    long value;
    if (raw == NULL || raw[0] == '\0') {
        return fallback;
    }
    value = strtol(raw, &end, 10);
    if (end == raw || *end != '\0' || value <= 0 || value > 2147483647L) {
        return fallback;
    }
    return (int)value;
}

static int64_t heavy_work(int64_t seed, int rounds) {
    int64_t acc = seed + 1;
    int i;
    for (i = 0; i < rounds; i++) {
        acc = (acc * 1103515245LL + 12345LL + i + seed) % 2147483647LL;
    }
    return acc % 1000003LL;
}

static void *worker_sum(void *ptr) {
    WorkerArgs *args = (WorkerArgs *)ptr;
    int64_t checksum = 0;
    int i;
    for (i = args->worker_id; i < args->items; i += args->workers) {
        checksum += heavy_work(i, args->rounds);
    }
    args->checksum = checksum;
    return NULL;
}

int main(void) {
    int workers = env_int("BENCH_THREADS", 4);
    int items = env_int("BENCH_ITEMS", 10000);
    int rounds = env_int("BENCH_ROUNDS", 1000);
    pthread_t *threads = (pthread_t *)calloc((size_t)workers, sizeof(pthread_t));
    WorkerArgs *args = (WorkerArgs *)calloc((size_t)workers, sizeof(WorkerArgs));
    int64_t checksum = 0;
    int i;

    if (threads == NULL || args == NULL) {
        free(threads);
        free(args);
        return 1;
    }

    for (i = 0; i < workers; i++) {
        args[i].worker_id = i;
        args[i].workers = workers;
        args[i].items = items;
        args[i].rounds = rounds;
        if (pthread_create(&threads[i], NULL, worker_sum, &args[i]) != 0) {
            free(threads);
            free(args);
            return 1;
        }
    }

    for (i = 0; i < workers; i++) {
        pthread_join(threads[i], NULL);
        checksum += args[i].checksum;
    }

    printf("checksum: %lld\n", (long long)checksum);
    free(threads);
    free(args);
    return 0;
}
