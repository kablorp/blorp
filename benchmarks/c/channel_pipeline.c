#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

typedef struct {
    int64_t *values;
    int capacity;
    int head;
    int tail;
    int count;
    int sealed;
    pthread_mutex_t mutex;
    pthread_cond_t not_empty;
    pthread_cond_t not_full;
} Queue;

typedef struct {
    int items;
    Queue *output;
} ProducerArgs;

typedef struct {
    Queue *input;
    Queue *output;
    int rounds;
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

static int queue_init(Queue *queue, int capacity) {
    queue->values = (int64_t *)calloc((size_t)capacity, sizeof(int64_t));
    if (queue->values == NULL) {
        return 0;
    }
    queue->capacity = capacity;
    queue->head = 0;
    queue->tail = 0;
    queue->count = 0;
    queue->sealed = 0;
    pthread_mutex_init(&queue->mutex, NULL);
    pthread_cond_init(&queue->not_empty, NULL);
    pthread_cond_init(&queue->not_full, NULL);
    return 1;
}

static void queue_destroy(Queue *queue) {
    pthread_cond_destroy(&queue->not_full);
    pthread_cond_destroy(&queue->not_empty);
    pthread_mutex_destroy(&queue->mutex);
    free(queue->values);
}

static void queue_seal(Queue *queue) {
    pthread_mutex_lock(&queue->mutex);
    queue->sealed = 1;
    pthread_cond_broadcast(&queue->not_empty);
    pthread_cond_broadcast(&queue->not_full);
    pthread_mutex_unlock(&queue->mutex);
}

static int queue_send(Queue *queue, int64_t value) {
    pthread_mutex_lock(&queue->mutex);
    while (!queue->sealed && queue->count == queue->capacity) {
        pthread_cond_wait(&queue->not_full, &queue->mutex);
    }
    if (queue->sealed) {
        pthread_mutex_unlock(&queue->mutex);
        return 0;
    }
    queue->values[queue->tail] = value;
    queue->tail = (queue->tail + 1) % queue->capacity;
    queue->count++;
    pthread_cond_signal(&queue->not_empty);
    pthread_mutex_unlock(&queue->mutex);
    return 1;
}

static int queue_recv(Queue *queue, int64_t *value) {
    pthread_mutex_lock(&queue->mutex);
    while (!queue->sealed && queue->count == 0) {
        pthread_cond_wait(&queue->not_empty, &queue->mutex);
    }
    if (queue->count == 0 && queue->sealed) {
        pthread_mutex_unlock(&queue->mutex);
        return 0;
    }
    *value = queue->values[queue->head];
    queue->head = (queue->head + 1) % queue->capacity;
    queue->count--;
    pthread_cond_signal(&queue->not_full);
    pthread_mutex_unlock(&queue->mutex);
    return 1;
}

static void *producer_thread(void *ptr) {
    ProducerArgs *args = (ProducerArgs *)ptr;
    int i;
    for (i = 0; i < args->items; i++) {
        queue_send(args->output, i);
    }
    queue_seal(args->output);
    return NULL;
}

static void *worker_thread(void *ptr) {
    WorkerArgs *args = (WorkerArgs *)ptr;
    int64_t value;
    while (queue_recv(args->input, &value)) {
        queue_send(args->output, heavy_work(value, args->rounds));
    }
    return NULL;
}

int main(void) {
    int workers = env_int("BENCH_THREADS", 4);
    int items = env_int("BENCH_ITEMS", 20000);
    int rounds = env_int("BENCH_ROUNDS", 64);
    int capacity = workers * 4;
    Queue input;
    Queue output;
    ProducerArgs producer_args;
    WorkerArgs *worker_args = NULL;
    pthread_t producer;
    pthread_t *threads = NULL;
    int64_t checksum = 0;
    int received = 0;
    int i;

    if (!queue_init(&input, capacity)) {
        return 1;
    }
    if (!queue_init(&output, capacity)) {
        queue_destroy(&input);
        return 1;
    }

    threads = (pthread_t *)calloc((size_t)workers, sizeof(pthread_t));
    worker_args = (WorkerArgs *)calloc((size_t)workers, sizeof(WorkerArgs));
    if (threads == NULL || worker_args == NULL) {
        free(threads);
        free(worker_args);
        queue_destroy(&output);
        queue_destroy(&input);
        return 1;
    }

    producer_args.items = items;
    producer_args.output = &input;
    if (pthread_create(&producer, NULL, producer_thread, &producer_args) != 0) {
        free(threads);
        free(worker_args);
        queue_destroy(&output);
        queue_destroy(&input);
        return 1;
    }

    for (i = 0; i < workers; i++) {
        worker_args[i].input = &input;
        worker_args[i].output = &output;
        worker_args[i].rounds = rounds;
        if (pthread_create(&threads[i], NULL, worker_thread, &worker_args[i]) != 0) {
            return 1;
        }
    }

    while (received < items) {
        int64_t value;
        if (queue_recv(&output, &value)) {
            checksum += value;
            received++;
        }
    }

    pthread_join(producer, NULL);
    for (i = 0; i < workers; i++) {
        pthread_join(threads[i], NULL);
    }
    queue_seal(&output);

    printf("checksum: %lld\n", (long long)checksum);
    printf("processed: %d\n", received);
    free(threads);
    free(worker_args);
    queue_destroy(&output);
    queue_destroy(&input);
    return 0;
}
