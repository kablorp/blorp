# Concurrency And Resources

Status: current contract with explicit open design boundaries.

This document consolidates the concurrency, virtual-thread, streaming resource,
and networking resource direction. Use [GUIDE.md](GUIDE.md) for user-facing
syntax examples and [ARCHITECTURE.md](ARCHITECTURE.md) for compiler pipeline
placement.

## Current Source Surface

Blorp has structured concurrency primitives:

- `concurrent:` for fixed child tasks that auto-join at scope exit.
- `for ... concurrently(limit: N)` for statement fan-out with explicit width.
- `List.concurrent(...)` and `List.concurrent_with_timeout(...)` for
  value-collecting fan-out.
- `detach` for explicit fire-and-forget work.
- `Channel[T]` for bounded message passing.
- `select:` for waiting on ordinary channel receive, sealed-channel, or timeout
  arms.

Timeouts accept raw millisecond integers or typed `Duration` values from
`std/units`. Timeouts are cooperative: cancellation is observed at park/yield
points such as sleep, task join, channel waits, stream iteration, and supported
runtime reactor waits.

Concurrent tasks run as fibers on the runtime scheduler. The user model is
ordinary blocking-style code; the implementation parks fibers at supported
blocking points instead of tying one blocked task to one OS thread.

## Safety Invariants

- Blorp values do not expose shared mutable state between tasks.
- A task, channel waiter, timer, resource cleanup frame, or fiber stack has one
  live owner at a time.
- Cancellation is structured. When a parent scope times out or is cancelled,
  child work is cancelled and joined through explicit cleanup paths.
- Runtime mutexes, atomics, queues, and scheduler state are encapsulated inside
  the runtime. They do not change source-level value semantics.
- Backpressure should be visible through capacities, limits, blocking waits, or
  typed results.

## Scoped Resources

`with name = acquire():` and `with name ?= acquire():` create scoped resources
with deterministic cleanup. The acquired value must have a `resource type`.

```blorp
import:
    fs: open_read

func line_count(path: String) -> Result[Int, IOError]:
    with reader ?= open_read(path):
        reader.count_lines()
```

Resource handles cannot be stored in ordinary aggregates, returned from source
functions, captured by closures, captured by `detach`, or shared across
ordinary concurrent tasks. Keep handle use inside the `with` body and pass
ordinary data to helpers.

Standard-library resources attach cleanup metadata at the declaration:

```blorp
resource type FileReader = builtin("blorp_file_close_reader")
```

Core lowering turns scoped resources into explicit cleanup nodes, including
cleanup for normal completion, `?=` short-circuit, `break`, `continue`, and
cooperative cancellation paths.

## Files, Directories, And Streams

The typed `fs` module exposes scoped file and directory handles for read, write,
append, read-write, read-append, and directory traversal. The handle and error
types are in the prelude; opener functions remain explicit `fs` imports.

Current file direction:

- Use capability traits rather than one broad file object.
- Keep manual `close` private; `with` owns cleanup.
- Use typed `IOError` at OS boundaries.
- Prefer helpers such as `count_lines()` when data does not need to materialize.
- Use `read_chunk_at(offset, max_bytes)` for stable offset reads that should
  not change a handle's current offset.

Directory handles support:

- `next_entry()` for manual single-entry loops;
- `next_entries(limit)` for explicit fixed-size batch loops;
- `entry_stream()` for fallible-stream consumers;
- `read_directory(path)` for sorted, fully materialized entries;
- `walk_files(root)` for sorted regular-file traversal that skips symlink entries
  and rejects symlink final path components while opening directories.

`Stream[T]` and `FallibleStream[T, E]` are one-shot cursors. They should stay in
direct local bindings while a pipeline is built and should be consumed by
terminal operations such as `collect_result`, `fold_result`, `count_result`,
`find_result`, `any_result`, or `all_result`.
`FallibleStream` cannot be used as the iterable in a direct `for` loop because
the loop syntax has no operation-level error result; use a terminal operation
or explicitly propagate its `Result` instead.

## Resource Sources

`ResourceSource[R, E]` is the reserved source category for APIs that produce
owned scoped resources one at a time, such as accepted TCP streams or future
database pool checkouts.

Rules:

- A resource source is not an ordinary collection.
- It cannot be hidden inside ordinary carriers such as records, unions, tuples,
  lists, dicts, `Option`, or `Result`.
- Direct source locals must be immutable and must come from producer calls, not
  copies of existing source locals.
- Sequential resource-source iteration transfers each produced resource into a
  scoped loop body that owns cleanup.
- Concurrent resource-source fan-out may move each produced resource into one
  child task only when Core metadata and cancellation cleanup make that transfer
  explicit.

TCP connection sources are the first concrete producer shape:
`connections_stop_on_error(listener)` and
`connections_continue_on_error(listener)` return
`ResourceSource[TcpStream, TcpError]` values that borrow their scoped listener
and carry an explicit accept-error policy.

## Networking Direction

Network capabilities are scoped resources or future services. Network data is
ordinary data. Repeated data is a stream. Repeated owned capabilities are
resource sources.

Current direction:

- TCP listener and stream handles are `resource type`s with private manual
  close operations.
- TCP endpoints use typed `Port`, `IpAddress`, `DnsName`, and `IpFamily`
  values rather than loosely paired strings and integers.
- TLS, UDP, WebSocket, and DNS surfaces should reuse the same operation-result
  metadata family for success ownership, error mapping, wait behavior, layout
  policy, and Core ownership contracts.
- DNS resolution may block an OS worker until a bounded resolver pool or true
  nonblocking backend exists. Do not expose a copyable resolver pool as
  ordinary data.
- WebSocket native work should keep explicit transport ownership, parsed
  connect targets, handshake state, frame validation, and error mapping at one
  runtime boundary.

## Operation Metadata

Compiler-owned runtime operations should describe:

- success payload ownership;
- error mapping;
- whether the operation does not wait, parks a fiber, blocks an OS worker, or
  checks cancellation while pulling from another source;
- boxed versus stack result layout policy;
- resource-producing behavior;
- cleanup needs if cancellation occurs while the operation is waiting.

Do not infer these facts from builtin names or module paths. Add a typed
operation manifest or Core metadata when a new runtime boundary needs to be
understood by ownership, cancellation, `select`, or codegen.

## Design Boundaries

The current surface deliberately does not promise resource-producing `select`
arms, borrowed resource parameters, a copyable service abstraction, or a
single dynamically typed `open(path, options)` API. Such features require
explicit ownership, cancellation, and result-type contracts before they become
part of this reference document. Active design work belongs in GitHub issues
and [COMPILER_PRIORITIES.md](COMPILER_PRIORITIES.md), not in a queue here.

## Validation Gate

For concurrency/resource changes, choose focused tests from:

- parser and typecheck tests for illegal resource escapes and unsupported
  syntax;
- runtime tests for cancellation, timeouts, channels, streams, and network
  operations;
- leak checks for success, timeout, cancellation, and early-return paths;
- generated-C audits when ownership or cleanup paths change;
- scheduler instrumentation checks for active, parked, cancelled, and timed-out
  task counts.
