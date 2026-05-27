import os
import queue
import sys
import sysconfig
import threading


def require_free_threaded():
    if sys.version_info < (3, 14):
        raise SystemExit("Python concurrency benchmarks require Python 3.14+")
    if str(sysconfig.get_config_var("Py_GIL_DISABLED")) != "1":
        raise SystemExit("Python concurrency benchmarks require a free-threaded build")
    is_gil_enabled = getattr(sys, "_is_gil_enabled", None)
    if callable(is_gil_enabled) and is_gil_enabled():
        raise SystemExit("Python concurrency benchmarks require the GIL disabled")


def env_int(name, fallback):
    try:
        value = int(os.environ.get(name, ""))
    except ValueError:
        return fallback
    return value if value > 0 else fallback


def heavy_work(seed, rounds):
    acc = seed + 1
    for i in range(rounds):
        acc = (acc * 1103515245 + 12345 + i + seed) % 2147483647
    return acc % 1000003


def producer(items, input_queue, sentinel, workers):
    for i in range(items):
        input_queue.put(i)
    for _ in range(workers):
        input_queue.put(sentinel)


def worker(input_queue, output_queue, rounds, sentinel):
    while True:
        value = input_queue.get()
        if value is sentinel:
            return
        output_queue.put(heavy_work(value, rounds))


def main():
    require_free_threaded()
    workers = env_int("BENCH_THREADS", 4)
    items = env_int("BENCH_ITEMS", 20000)
    rounds = env_int("BENCH_ROUNDS", 64)
    capacity = workers * 4
    sentinel = object()
    input_queue = queue.Queue(maxsize=capacity)
    output_queue = queue.Queue(maxsize=capacity)

    producer_thread = threading.Thread(
        target=producer,
        args=(items, input_queue, sentinel, workers),
    )
    worker_threads = [
        threading.Thread(target=worker, args=(input_queue, output_queue, rounds, sentinel))
        for _ in range(workers)
    ]

    producer_thread.start()
    for thread in worker_threads:
        thread.start()

    checksum = 0
    for _ in range(items):
        checksum += output_queue.get()

    producer_thread.join()
    for thread in worker_threads:
        thread.join()

    print(f"checksum: {checksum}")
    print(f"processed: {items}")


if __name__ == "__main__":
    main()
