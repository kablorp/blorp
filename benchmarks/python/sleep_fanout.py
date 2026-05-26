import os
import sys
import sysconfig
import threading
import time


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


def main():
    require_free_threaded()
    tasks = env_int("BENCH_SLEEP_TASKS", 512)
    sleep_ms = env_int("BENCH_SLEEP_MS", 5)
    results = [0] * tasks

    def sleep_task(i):
        time.sleep(sleep_ms / 1000.0)
        results[i] = i

    threads = [threading.Thread(target=sleep_task, args=(i,)) for i in range(tasks)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()

    print(f"checksum: {sum(results)}")


if __name__ == "__main__":
    main()
