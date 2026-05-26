#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

typedef struct {
    int id;
    int sleep_ms;
    int64_t value;
} TaskArgs;

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

static void *sleep_task(void *ptr) {
    TaskArgs *args = (TaskArgs *)ptr;
    usleep((useconds_t)args->sleep_ms * 1000U);
    args->value = args->id;
    return NULL;
}

int main(void) {
    int tasks = env_int("BENCH_SLEEP_TASKS", 512);
    int sleep_ms = env_int("BENCH_SLEEP_MS", 5);
    pthread_t *threads = (pthread_t *)calloc((size_t)tasks, sizeof(pthread_t));
    TaskArgs *args = (TaskArgs *)calloc((size_t)tasks, sizeof(TaskArgs));
    int64_t checksum = 0;
    int i;

    if (threads == NULL || args == NULL) {
        free(threads);
        free(args);
        return 1;
    }

    for (i = 0; i < tasks; i++) {
        args[i].id = i;
        args[i].sleep_ms = sleep_ms;
        if (pthread_create(&threads[i], NULL, sleep_task, &args[i]) != 0) {
            free(threads);
            free(args);
            return 1;
        }
    }

    for (i = 0; i < tasks; i++) {
        pthread_join(threads[i], NULL);
        checksum += args[i].value;
    }

    printf("checksum: %lld\n", (long long)checksum);
    free(threads);
    free(args);
    return 0;
}
