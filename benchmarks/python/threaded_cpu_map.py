import os
import sys
import sysconfig
from concurrent.futures import ThreadPoolExecutor


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


def worker_sum(worker_id, workers, items, rounds):
    checksum = 0
    for i in range(worker_id, items, workers):
        checksum += heavy_work(i, rounds)
    return checksum


def main():
    require_free_threaded()
    workers = env_int("BENCH_THREADS", 4)
    items = env_int("BENCH_ITEMS", 10000)
    rounds = env_int("BENCH_ROUNDS", 1000)
    with ThreadPoolExecutor(max_workers=workers) as pool:
        futures = [
            pool.submit(worker_sum, worker_id, workers, items, rounds)
            for worker_id in range(workers)
        ]
        checksum = sum(future.result() for future in futures)
    print(f"checksum: {checksum}")


if __name__ == "__main__":
    main()
