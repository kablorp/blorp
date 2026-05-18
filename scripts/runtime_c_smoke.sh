#!/bin/bash
# Focused C-runtime smoke tests that are too low-level for .brp runtime tests.

set -euo pipefail

cd "$(dirname "$0")/.."

cc_bin="${CC:-cc}"
timeout_seconds="${BLORP_C_RUNTIME_SMOKE_TIMEOUT:-10}"
tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/blorp-c-runtime-smoke.XXXXXX")
cc_flags=(-std=c11 -O0 -w)
if [ "${BLORP_C_RUNTIME_SMOKE_SANITIZE:-0}" = "1" ]; then
    cc_flags+=(-fsanitize=address,undefined -fno-omit-frame-pointer -g)
    cc_flags+=(-DBLORP_C_RUNTIME_SMOKE_SANITIZE=1)
fi

cleanup() {
    rm -rf "$tmpdir"
}
trap cleanup EXIT

run_with_timeout() {
    local exe="$1"
    local name="$2"
    local pid watchdog rc

    "$exe" &
    pid=$!
    (
        sleep "$timeout_seconds"
        if kill -0 "$pid" 2>/dev/null; then
            echo "FAIL: runtime C smoke $name timed out after ${timeout_seconds}s" >&2
            kill -TERM "$pid" 2>/dev/null || true
            sleep 1
            kill -KILL "$pid" 2>/dev/null || true
        fi
    ) &
    watchdog=$!

    if wait "$pid"; then
        rc=0
    else
        rc=$?
    fi

    kill "$watchdog" 2>/dev/null || true
    wait "$watchdog" 2>/dev/null || true
    return "$rc"
}

io_reactor_src="$tmpdir/io_reactor_smoke.c"
io_reactor_exe="$tmpdir/io_reactor_smoke"
io_waiter_src="$tmpdir/io_waiter_smoke.c"
io_waiter_exe="$tmpdir/io_waiter_smoke"

cat > "$io_reactor_src" <<C
#define MINICORO_IMPL
#include "$PWD/compiler/lib/minicoro.h"
#include "$PWD/compiler/lib/runtime.c"

int main(void) {
    int rc = blorp_io_reactor_smoke_test();
    if (rc != 0) {
        blorp_io_reactor_shutdown();
        return rc;
    }

    for (int i = 0; i < 32; i++) {
        int fds[2];
        if (pipe(fds) != 0) {
            blorp_io_reactor_shutdown();
            return 20;
        }

        uint64_t generation = (uint64_t)(1000 + i);
        if (blorp_io_reactor_register_fd_for_smoke(
                fds[0], generation, BLORP_IO_INTEREST_READ) != 0) {
            close(fds[0]);
            close(fds[1]);
            blorp_io_reactor_shutdown();
            return 21;
        }
        if (blorp_io_reactor_update_interest(fds[0], generation, 0) != 0) {
            blorp_io_reactor_unregister_inner(fds[0], generation);
            close(fds[0]);
            close(fds[1]);
            blorp_io_reactor_shutdown();
            return 22;
        }

        unsigned char byte = (unsigned char)i;
        if (write(fds[1], &byte, 1) != 1) {
            blorp_io_reactor_unregister_inner(fds[0], generation);
            close(fds[0]);
            close(fds[1]);
            blorp_io_reactor_shutdown();
            return 23;
        }
        int suppressed_ready = blorp_io_reactor_wait_ready(
            fds[0], generation, BLORP_IO_INTEREST_READ, 5);
        if (suppressed_ready != 0) {
            blorp_io_reactor_unregister_inner(fds[0], generation);
            close(fds[0]);
            close(fds[1]);
            blorp_io_reactor_shutdown();
            return 24;
        }

        if (blorp_io_reactor_update_interest(
                fds[0], generation, BLORP_IO_INTEREST_READ) != 0) {
            blorp_io_reactor_unregister_inner(fds[0], generation);
            close(fds[0]);
            close(fds[1]);
            blorp_io_reactor_shutdown();
            return 25;
        }
        int ready = blorp_io_reactor_wait_ready(
            fds[0], generation, BLORP_IO_INTEREST_READ, 1000);
        if ((ready & BLORP_IO_INTEREST_READ) == 0) {
            blorp_io_reactor_unregister_inner(fds[0], generation);
            close(fds[0]);
            close(fds[1]);
            blorp_io_reactor_shutdown();
            return 26;
        }

        if (blorp_io_reactor_unregister_inner(fds[0], generation) != 0) {
            close(fds[0]);
            close(fds[1]);
            blorp_io_reactor_shutdown();
            return 27;
        }
        close(fds[0]);
        close(fds[1]);
    }

    blorp_io_reactor_shutdown();
    return rc;
}
C

"$cc_bin" "${cc_flags[@]}" -o "$io_reactor_exe" "$io_reactor_src" -lm -lpthread

if run_with_timeout "$io_reactor_exe" "io_reactor"; then
    echo "PASS: runtime C smoke io_reactor"
else
    rc=$?
    echo "FAIL: runtime C smoke io_reactor exited with $rc" >&2
    exit "$rc"
fi

cat > "$io_waiter_src" <<C
#define MINICORO_IMPL
#include "$PWD/compiler/lib/minicoro.h"
#include "$PWD/compiler/lib/runtime.c"

typedef struct {
    blorp_TcpInner* inner;
    blorp_IoWaitKind kind;
    long timeout_ms;
    blorp_IoWakeReason reason;
} IoParkTaskEnv;

static void* io_park_task(void* raw_env) {
    IoParkTaskEnv* env = *(IoParkTaskEnv**)raw_env;
    pthread_mutex_lock(&env->inner->mutex);
    int fd = (int)env->inner->fd;
    uint64_t generation = env->inner->generation;
    pthread_mutex_unlock(&env->inner->mutex);
    int interest =
        (env->kind == BLORP_IO_WAIT_CONNECT || env->kind == BLORP_IO_WAIT_WRITE)
            ? BLORP_IO_INTEREST_WRITE
            : BLORP_IO_INTEREST_READ;
    env->reason =
        blorp_tcp_inner_park_current_fiber(
            env->inner, env->kind, fd, generation, interest, env->timeout_ms);
    return NULL;
}

static int wait_for_waiter(blorp_TcpInner* inner, blorp_IoWaitKind kind) {
    for (int i = 0; i < 1000; i++) {
        pthread_mutex_lock(&inner->mutex);
        blorp_IoWaiter** slot = blorp_tcp_inner_waiter_slot(inner, kind);
        int ready = slot && *slot;
        pthread_mutex_unlock(&inner->mutex);
        if (ready) return 1;
        usleep(1000);
    }
    return 0;
}

static blorp_Closure* make_io_park_closure(IoParkTaskEnv* env) {
    blorp_Closure* closure = blorp_closure_new_inline((void*)io_park_task, 1);
    ((void**)closure->env)[0] = env;
    return closure;
}

static int run_io_park_task(IoParkTaskEnv* env) {
    blorp_Closure* closure = make_io_park_closure(env);
    blorp_Task* task = (blorp_Task*)blorp_task_spawn(closure);
    blorp_release(closure);
    void* joined = blorp_task_join(task);
    if (joined) blorp_release(joined);
    blorp_release(task);
    return 0;
}

int main(void) {
    int fds[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, fds) != 0) return 1;

    blorp_TcpStream* stream = blorp_tcp_stream_from_fd(fds[0]);
    if (!stream) return 70;
    blorp_TcpInner* inner = stream->inner;

    blorp_IoWaiter* read_waiter =
        blorp_io_waiter_new(BLORP_IO_WAIT_READ, NULL, inner->generation, 1234);
    if (blorp_tcp_inner_install_waiter(inner, read_waiter) != 0) return 2;
    if (!read_waiter->installed || inner->read_waiter != read_waiter) return 3;

    blorp_IoWaiter* duplicate_read =
        blorp_io_waiter_new(BLORP_IO_WAIT_READ, NULL, inner->generation, 0);
    if (blorp_tcp_inner_install_waiter(inner, duplicate_read) == 0) return 4;
    if (duplicate_read->installed) return 5;
    blorp_io_waiter_release(duplicate_read);

    if (blorp_tcp_inner_remove_waiter(inner, read_waiter) != 1) return 6;
    if (read_waiter->installed || inner->read_waiter != NULL) return 7;
    blorp_io_waiter_release(read_waiter);

    read_waiter =
        blorp_io_waiter_new(BLORP_IO_WAIT_READ, NULL, inner->generation, 0);
    blorp_IoWaiter* write_waiter =
        blorp_io_waiter_new(BLORP_IO_WAIT_WRITE, NULL, inner->generation, 0);
    if (blorp_tcp_inner_install_waiter(inner, read_waiter) != 0) return 8;
    if (blorp_tcp_inner_install_waiter(inner, write_waiter) != 0) return 9;

    blorp_IoWaiterList closed_waiters =
        blorp_tcp_inner_close_and_extract_waiters(
            inner, BLORP_IO_WAKE_CLOSED, NULL, NULL);
    if (blorp_io_waiter_list_count(&closed_waiters) != 2) return 10;
    if (inner->read_waiter != NULL || inner->write_waiter != NULL) return 11;
    if (read_waiter->installed || write_waiter->installed) return 12;
    if (read_waiter->wake_reason != BLORP_IO_WAKE_CLOSED) return 13;
    if (write_waiter->wake_reason != BLORP_IO_WAKE_CLOSED) return 14;

    blorp_io_waiter_wake_all(&closed_waiters);
    if (closed_waiters.head != NULL || closed_waiters.tail != NULL) return 15;
    blorp_io_waiter_release(read_waiter);
    blorp_io_waiter_release(write_waiter);

    read_waiter =
        blorp_io_waiter_new(BLORP_IO_WAIT_READ, NULL, inner->generation, 0);
    if (blorp_tcp_inner_install_waiter(inner, read_waiter) == 0) return 16;
    blorp_io_waiter_release(read_waiter);

    int other_fds[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, other_fds) != 0) return 17;
    blorp_TcpStream* other_stream = blorp_tcp_stream_from_fd(other_fds[0]);
    if (!other_stream) return 71;
    blorp_TcpInner* other = other_stream->inner;

    if (blorp_io_reactor_register_inner(
            other, other->fd, other->generation, BLORP_IO_INTEREST_READ) != 0) return 60;
    if (blorp_io_reactor_register_inner(
            other, other->fd, other->generation, BLORP_IO_INTEREST_WRITE) != 0) return 61;
    pthread_mutex_lock(&__blorp_io_reactor.mutex);
    blorp_IoRegistration* both_interests =
        blorp_io_reactor_find_locked(other->fd, other->generation);
    int registered_interests = both_interests ? both_interests->interests : 0;
    pthread_mutex_unlock(&__blorp_io_reactor.mutex);
    if ((registered_interests & (BLORP_IO_INTEREST_READ | BLORP_IO_INTEREST_WRITE)) !=
        (BLORP_IO_INTEREST_READ | BLORP_IO_INTEREST_WRITE)) {
        return 62;
    }
    blorp_IoRegistrationCleanup read_interest_cleanup = {
        .fd = other->fd,
        .generation = other->generation,
        .interests = BLORP_IO_INTEREST_READ,
        .registered = true
    };
    blorp_io_registration_cleanup_unregister(&read_interest_cleanup);
    if (read_interest_cleanup.registered) return 63;
    pthread_mutex_lock(&__blorp_io_reactor.mutex);
    both_interests = blorp_io_reactor_find_locked(other->fd, other->generation);
    registered_interests = both_interests ? both_interests->interests : 0;
    pthread_mutex_unlock(&__blorp_io_reactor.mutex);
    if (registered_interests != BLORP_IO_INTEREST_WRITE) return 64;
    if (blorp_io_reactor_unregister_inner(other->fd, other->generation) != 0) return 65;

    read_waiter =
        blorp_io_waiter_new(BLORP_IO_WAIT_READ, NULL, other->generation, 0);
    if (blorp_tcp_inner_install_waiter(other, read_waiter) != 0) return 18;

    blorp_IoWaiterList stale_ready = blorp_tcp_inner_extract_waiter(
        other, BLORP_IO_WAIT_READ, other->generation + 1, BLORP_IO_WAKE_READY);
    if (blorp_io_waiter_list_count(&stale_ready) != 0) return 19;
    if (!read_waiter->installed || other->read_waiter != read_waiter) return 20;

    blorp_IoWaiterList ready = blorp_tcp_inner_extract_waiter(
        other, BLORP_IO_WAIT_READ, other->generation, BLORP_IO_WAKE_READY);
    if (blorp_io_waiter_list_count(&ready) != 1) return 21;
    if (read_waiter->installed || other->read_waiter != NULL) return 22;
    if (read_waiter->wake_reason != BLORP_IO_WAKE_READY) return 23;
    blorp_io_waiter_wake_all(&ready);
    blorp_io_waiter_release(read_waiter);

    write_waiter =
        blorp_io_waiter_new(BLORP_IO_WAIT_WRITE, NULL, other->generation, 0);
    if (blorp_tcp_inner_install_waiter(other, write_waiter) != 0) return 24;
    if (blorp_tcp_inner_cancel_waiter(other, write_waiter) != 1) return 25;
    if (write_waiter->installed || other->write_waiter != NULL) return 26;
    if (!write_waiter->cancelled) return 27;
    if (write_waiter->wake_reason != BLORP_IO_WAKE_CANCELLED) return 28;
    blorp_io_waiter_release(write_waiter);

    write_waiter = blorp_io_waiter_new(
        BLORP_IO_WAIT_WRITE, NULL, other->generation, 999999999999999999ULL);
    blorp_io_deadline_queue_insert(write_waiter, NULL);
    if (!write_waiter->deadline_queued) return 29;
    if (blorp_io_deadline_queue_count() != 1) return 30;
    blorp_io_deadline_queue_remove(write_waiter);
    if (write_waiter->deadline_queued) return 31;
    if (blorp_io_deadline_queue_count() != 0) return 32;
    blorp_io_waiter_release(write_waiter);

    read_waiter =
        blorp_io_waiter_new(BLORP_IO_WAIT_READ, NULL, other->generation, 1);
    if (blorp_tcp_inner_install_waiter(other, read_waiter) != 0) return 33;
    blorp_io_deadline_queue_insert(read_waiter, other);
    if (!read_waiter->deadline_queued) return 34;
    if (blorp_io_deadline_queue_drain() != 0) return 35;
    if (other->read_waiter != NULL) return 36;
    if (read_waiter->installed || read_waiter->deadline_queued) return 37;
    if (read_waiter->wake_reason != BLORP_IO_WAKE_TIMEOUT) return 38;
    blorp_io_waiter_release(read_waiter);

    /*
     * Apple ASan is unstable for this direct minicoro embedding at process
     * teardown. Sanitized .brp TCP tests cover the fiber parking path; keep
     * this C smoke focused on non-fiber ownership invariants under ASan.
     */
#ifndef BLORP_C_RUNTIME_SMOKE_SANITIZE
    IoParkTaskEnv timeout_env = {
        .inner = other,
        .kind = BLORP_IO_WAIT_READ,
        .timeout_ms = 10,
        .reason = BLORP_IO_WAKE_NONE,
    };
    run_io_park_task(&timeout_env);
    if (timeout_env.reason != BLORP_IO_WAKE_TIMEOUT) return 39;
    if (other->read_waiter != NULL) return 40;
    if (blorp_io_deadline_queue_count() != 0) return 41;

    int cancel_fds[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, cancel_fds) != 0) return 42;
    blorp_TcpStream* cancel_stream = blorp_tcp_stream_from_fd(cancel_fds[0]);
    if (!cancel_stream) return 72;
    blorp_TcpInner* cancel_inner = cancel_stream->inner;
    IoParkTaskEnv cancel_env = {
        .inner = cancel_inner,
        .kind = BLORP_IO_WAIT_READ,
        .timeout_ms = 100000,
        .reason = BLORP_IO_WAKE_NONE,
    };
    blorp_Closure* cancel_closure = make_io_park_closure(&cancel_env);
    blorp_Task* cancel_task = (blorp_Task*)blorp_task_spawn(cancel_closure);
    blorp_release(cancel_closure);
    if (!wait_for_waiter(cancel_inner, BLORP_IO_WAIT_READ)) return 43;
    if (blorp_io_deadline_queue_count() != 1) return 44;
    blorp_task_cancel(cancel_task);
    void* cancel_joined = blorp_task_join(cancel_task);
    if (cancel_joined) blorp_release(cancel_joined);
    blorp_release(cancel_task);
    if (cancel_inner->read_waiter != NULL) return 45;
    if (blorp_io_deadline_queue_count() != 0) return 46;
    close(cancel_fds[1]);
    blorp_release(cancel_stream);

    if (blorp_tcp_inner_begin_write_op(other) != 0) return 47;
    if (!other->write_active) return 48;
    if (blorp_tcp_inner_begin_write_op(other) != -2) return 49;
    blorp_tcp_inner_end_write_op(other);
    if (other->write_active) return 50;

    int close_fds[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, close_fds) != 0) return 51;
    blorp_TcpStream* close_stream = blorp_tcp_stream_from_fd(close_fds[0]);
    if (!close_stream) return 73;
    blorp_TcpInner* close_inner = close_stream->inner;
    IoParkTaskEnv close_env = {
        .inner = close_inner,
        .kind = BLORP_IO_WAIT_READ,
        .timeout_ms = -1,
        .reason = BLORP_IO_WAKE_NONE,
    };
    blorp_Closure* close_closure = make_io_park_closure(&close_env);
    blorp_Task* close_task = (blorp_Task*)blorp_task_spawn(close_closure);
    blorp_release(close_closure);
    if (!wait_for_waiter(close_inner, BLORP_IO_WAIT_READ)) return 52;
    blorp_tcp_inner_close(close_inner);
    void* close_joined = blorp_task_join(close_task);
    if (close_joined) blorp_release(close_joined);
    blorp_release(close_task);
    if (close_env.reason != BLORP_IO_WAKE_CLOSED) return 53;
    if (close_inner->read_waiter != NULL) return 54;
    close(close_fds[1]);
    blorp_release(close_stream);
    blorp_thread_pool_shutdown();
#endif

    blorp_io_reactor_shutdown();
    close(other_fds[1]);
    blorp_release(other_stream);

    close(fds[1]);
    blorp_release(stream);
    return 0;
}
C

"$cc_bin" "${cc_flags[@]}" -o "$io_waiter_exe" "$io_waiter_src" -lm -lpthread

if run_with_timeout "$io_waiter_exe" "io_waiter"; then
    echo "PASS: runtime C smoke io_waiter"
else
    rc=$?
    echo "FAIL: runtime C smoke io_waiter exited with $rc" >&2
    exit "$rc"
fi
