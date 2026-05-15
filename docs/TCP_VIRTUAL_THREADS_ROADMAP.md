# TCP Virtual Threads Roadmap

This document defines a roadmap for making Blorp TCP operations compatible with
virtual threads. It is a design and execution plan, not a claim about the
current implementation.

## Goal

TCP APIs should remain direct-style and synchronous-looking in Blorp source,
while blocking network operations park the current fiber instead of blocking an
OS carrier thread.

Target user code should continue to look like:

```blorp
match TCP.read(stream, 4096):
	Ok(bytes): handle(bytes)
	Err(msg): log(msg)
```

The runtime implementation should make this fiber-aware internally:

```text
try recv
if ready: return bytes
if would-block:
    register current fiber as fd-read waiter
    park fiber
    resume when reactor observes fd readable
    retry recv
```

This should not require source-level `async` / `await`, promises, futures, or
explicit channels for normal TCP usage.

## Non-Goals

- Do not introduce source-level async syntax.
- Do not make TCP user APIs channel-first.
- Do not expose raw reactor handles to Blorp programs.
- Do not rely on ad hoc name checks in codegen to identify parking calls.
- Do not implement TLS, HTTP, SMTP, or WebSocket migration before the TCP base
  is correct and tested.
- Do not pursue lock-free reactor structures initially unless measurement shows
  the simple design is insufficient.

## Current State

Current TCP lives in `std/net/tcp.brp` and is backed by C runtime builtins in
`compiler/lib/runtime.c`:

- `listen(host, port, backlog) -> Result[Int, String]`
- `accept(server_fd) -> Result[Int, String]`
- `connect(host, port) -> Result[Int, String]`
- `read(fd, max_bytes) -> Result[Bytes, String]`
- `write(fd, data) -> Result[Int, String]`
- `close(fd) -> Void`
- `set_reuse_addr(fd) -> Result[Int, String]`
- `local_port(fd) -> Result[Int, String]`
- `set_timeout(fd, ms) -> Result[Int, String]`

The runtime currently uses blocking `getaddrinfo`, `accept`, `connect`,
`recv`, and `send`. Both `connect(host, ...)` and `listen(host, ...)` can call
`getaddrinfo`. That means a fiber executing TCP can pin its OS worker thread
until name resolution or the kernel operation completes.

Virtual threads already have parking infrastructure for:

- `sleep`
- channel `send` / `recv`
- task join
- timed joins / channel timeouts
- cancellation wakeups

TCP should reuse the same scheduler concept: parked fibers are not runnable,
and wakeups transfer them back to a run queue.

Implementation progress:

- Current builtin call-effect metadata distinguishes `NoWait`, `MayParkFiber`,
  and `MayBlockThread`.
- Current raw TCP operations are classified conservatively: `listen`, `accept`,
  `connect`, `read`, `write`, and `set_timeout` are `MayBlockThread`; `close`,
  `set_reuse_addr`, and `local_port` are impure `NoWait`.
- Current raw TCP runtime ownership contracts are explicit: managed arguments
  such as host strings and `Bytes` buffers are borrowed by the runtime call, and
  returned `Result` values are owned by the caller.
- `local_port` exists to make loopback tests bind port `0` without relying on
  fixed global ports.

## Design Principles

- **Direct style stays direct.** Blorp source should read like ordinary blocking
  IO, while the runtime turns would-block cases into fiber parks.
- **IO readiness is not a Blorp channel.** Channels are user-level coordination
  primitives. TCP readiness should use lower-level runtime wait queues.
- **Opaque handles over raw integers.** File descriptors should become runtime
  managed handles so arbitrary `Int` values cannot be passed as sockets.
- **Parking calls are explicit in compiler metadata.** Core should know which
  calls may park or block so optimizers do not move, duplicate, or eliminate
  them incorrectly.
- **Ownership is preserved across park points.** Arguments and buffers used by
  a parked TCP operation must remain alive until the operation returns.
- **Close/cancel is a first-class state transition.** A socket can be open,
  closing, or closed. Waiters must be woken safely on close and cancellation.
- **Correct first, then optimize.** Start with a conservative reactor design and
  tighten it with measurements.

## Target User-Facing API

The final API should move from raw `Int` descriptors to opaque handles:

```blorp
type TcpListener = builtin
type TcpStream = builtin

func listen(host: String, port: Int, backlog: Int) -> Result[TcpListener, String]:
	builtin

func accept(listener: TcpListener) -> Result[TcpStream, String]:
	builtin

func connect(host: String, port: Int) -> Result[TcpStream, String]:
	builtin

func read(stream: TcpStream, max_bytes: Int) -> Result[Bytes, String]:
	builtin

func write(stream: TcpStream, data: Bytes) -> Result[Int, String]:
	builtin

func close(stream: TcpStream) -> Void:
	builtin
```

Compatibility policy:

- Do not silently make raw-`Int` fd APIs fiber-aware while opaque handles also
  exist. That would create two subtly different socket models.
- Preferred preview path: migrate `std/net/tcp` to opaque handles in one
  source-breaking slice and update all std/pkg/tests in the same change.
- If raw fd access is still needed, move it behind an explicit low-level module
  such as `pkg/net/raw_tcp` and document it as blocking, unsafe-adjacent, and
  not virtual-thread-compatible.
- No long-lived compatibility shim should accept arbitrary `Int` and then
  internally pretend it is a managed `TcpStream`.

## Runtime Data Model

Represent TCP runtime state explicitly.

```c
typedef enum {
    BLORP_TCP_OPEN,
    BLORP_TCP_CLOSING,
    BLORP_TCP_CLOSED
} blorp_TcpState;

typedef enum {
    BLORP_IO_NONE,
    BLORP_IO_ACCEPT,
    BLORP_IO_CONNECT,
    BLORP_IO_READ,
    BLORP_IO_WRITE
} blorp_IoWaitKind;
```

Target objects:

```text
TcpListener
    fd
    state
    generation
    read_waiter / accept_waiter
    default_timeout_ms

TcpStream
    fd
    state
    generation
    connect_waiter
    read_waiter
    write_waiter
    default_timeout_ms
```

The generation prevents stale reactor events from acting on a newly reused fd.

### Handle ABI Requirements

Opaque TCP handles are not just source-level builtin type declarations. The
compiler and runtime must agree on their ABI before handle-backed TCP lands.

Required metadata:

- `TcpListener` and `TcpStream` have source anchors in `std/net/tcp.brp`.
- Env/builtin registration classifies them as nominal builtin runtime object
  types, not aliases for `Int`.
- Core type layout classifies them as managed ARC objects.
- Perceus inserts normal retain/drop operations for handle values.
- Codegen emits their C ABI as pointers to runtime structs, not boxed integers.
- `Result[TcpStream, String]` and `Result[TcpListener, String]` have correct
  release masks for both success and error payloads.
- The runtime installs destructors that close owned fds and wake/remove waiters.
- Handle values can cross channels/tasks using the normal managed-value ABI.

Initial implementation should add compiler tests that reject `Int` where a
`TcpStream` is expected and codegen-audit tests that prove successful TCP
results carry managed release policy.

### Handle Registry And Lifetime

The reactor needs fd lookup, but fd lookup must not keep Blorp ARC handles alive
forever or leave dangling pointers after user code drops a handle.

Preferred design:

- A Blorp `TcpStream` / `TcpListener` wrapper is an ARC-managed object.
- The wrapper owns a pointer to a native `TcpInner`.
- `TcpInner` has its own runtime refcount, fd, generation, state, wait slots,
  timeout metadata, and lock.
- The reactor registry maps `(fd, generation)` to `TcpInner`, not to the Blorp
  wrapper.
- The registry holds a native `TcpInner` ref only while the fd is registered.
- Event processing temporarily retains the `TcpInner` under the reactor lock,
  then releases it after wake processing.
- The Blorp wrapper destructor closes/unregisters the fd, wakes waiters, and
  releases its native `TcpInner` ref.
- `TcpInner` memory is freed only after both the wrapper and reactor/event refs
  are gone.

This separates source-level ARC lifetime from reactor event lifetime. It also
makes stale readiness events safe: if the registry no longer contains the
matching `(fd, generation)`, the event is ignored.

### Invalid States To Make Unrepresentable

- A Blorp program cannot pass an arbitrary `Int` as a TCP socket.
- A closed stream cannot have a live fd.
- A runtime handle cannot be in two ownership states at once.
- A fiber cannot be queued in both a socket wait slot and a different IO wait
  slot for the same operation.
- A stream cannot have two pending reads unless the API explicitly supports
  read multiplexing.
- A stream cannot have two unsynchronized pending writes unless the API
  explicitly serializes them.
- A close operation cannot leave a stale fiber pointer in a wait slot.
- A reactor event cannot wake a fiber for the wrong generation of an fd.
- A timeout cannot fire after the operation has completed and still wake a
  completed or recycled fiber.

Use precise runtime enums and helper constructors rather than coupled booleans.
For example, prefer a single `wait_kind` enum over independent
`is_reading` / `is_writing` / `is_connecting` flags.

## Reactor Design

### Initial Shape

Use one process-wide reactor:

- `kqueue` on macOS/BSD.
- `epoll` on Linux.
- `poll` fallback for portability and tests.

The reactor owns kernel readiness subscriptions. Socket objects own waiters and
state. Fibers are scheduled only through the existing fiber scheduler.

Recommended initial implementation: a dedicated reactor thread. This is simpler
than trying to make every worker thread participate in IO polling, and it
decouples correctness from scheduler work-stealing details.

The reactor thread:

1. Waits for fd readiness or control messages.
2. Looks up the runtime handle for the fd/generation.
3. Acquires the handle lock.
4. Transfers eligible waiters out of the handle.
5. Releases the lock.
6. Schedules the fibers through `blorp_fiber_schedule`.

### Control Wakeups

The reactor needs a way to be woken when:

- a new fd is registered;
- an fd is unregistered;
- a timeout deadline changes;
- the process is shutting down.

Use platform-specific control events:

- `eventfd` or pipe on Linux.
- `EVFILT_USER` or pipe on kqueue.
- pipe fallback for `poll`.

### Waiter Model

Each wait slot should contain an explicit waiter record:

```text
IoWaiter
    fiber
    kind
    deadline_ns
    cancelled
    generation
```

The waiter is owned by the parked fiber stack or the runtime handle, never both
ambiguously. The handoff rules should mirror the existing channel wait queue
discipline: enqueue while holding the object lock, mark parked before yielding,
remove from all wait structures on resume.

## Compiler And IR Concerns

No async lowering is required. Blorp uses stackful fibers, so a C call can park
by yielding the coroutine and later resume at the same stack frame.

The compiler needs explicit metadata before the first runtime TCP operation can
park. This is a prerequisite, not late cleanup. Without it, Perceus/reuse and
future optimization passes cannot reliably preserve liveness and call ordering
around yield points.

### Call Effect Metadata

Add a richer call-effect classification to Core/intrinsic metadata. Prefer a
structured model over a flat enum so invalid combinations are harder to
construct:

```text
CallEffect =
    Pure
  | Impure {
        wait: NoWait | MayParkFiber | MayBlockThread,
        cancellation: NotCancellationPoint | CancellationPoint
    }
```

This should be represented in the intrinsic registry or call metadata, not
recovered from function names. `Pure` must not carry wait or cancellation
metadata. Runtime IO builtins must use the `Impure` form explicitly.

For readability, the rest of this document uses `ImpureMayPark`,
`ImpureMayBlockThread`, and `ImpureNoPark` as shorthand labels for those
structured `Impure` cases, not as a recommendation to implement a flat enum.

TCP operations should be:

- `listen`: `ImpureMayBlockThread` until DNS/bind behavior is restricted or
  moved to a blocking pool
- `accept`: `ImpureMayPark`, `CancellationPoint`
- `connect`: `ImpureMayBlockThread` while DNS is inline, then
  `ImpureMayPark`, `CancellationPoint` after DNS is offloaded or restricted
- `read`: `ImpureMayPark`, `CancellationPoint`
- `write`: `ImpureMayPark`, `CancellationPoint`
- `close`: `ImpureNoPark` or narrowly `ImpureMayPark` only if close wakes via
  reactor synchronization that can wait

Foreign functions should default to `ImpureMayBlockThread` unless explicitly
declared fiber-safe or offloaded to a blocking pool.

### Optimization Barriers

Core passes must not:

- duplicate `ImpureMayPark` calls;
- reorder managed drops before a parking call if the parked call still needs
  the value;
- move a parking call across another impure call;
- fuse loops in a way that changes how many times a parking call happens;
- CSE or eliminate parking calls even if their return values appear unused.

`ImpureMayPark` should also be a liveness barrier for Perceus/reuse.

### Ownership Across Park Points

If a parked TCP call uses only the current C/fiber stack, normal liveness should
keep arguments alive. If the runtime stores pointers to Blorp values outside
the parked stack frame, it must retain or copy them explicitly.

`write(stream, bytes)` is the key case:

- Conservative initial implementation: keep `bytes` on the parked fiber stack
  and retry send after resume.
- If write buffers are stored in the reactor or stream object, the runtime must
  retain/copy the bytes until completion.
- Perceus must not drop `bytes` before the `write` call returns.

## Timeout And Cancellation Semantics

`set_timeout` currently configures kernel socket timeouts. In a fiber-aware
runtime, timeout should be a runtime operation deadline.

Cancellation must match existing structured concurrency semantics. A parent
cancellation is not an ordinary TCP result that user code should pattern-match
as `Err("cancelled")`. TCP operations should be cancellation points: when the
current task is cancelled, execution stops through the same task-cancellation
path used by channels/task joins.

Preferred timeout semantics:

- `set_timeout(stream, ms)` sets a default operation timeout on the handle.
- `read_timeout(stream, max_bytes, ms)` and `write_timeout(...)` can be added
  later if call-site timeout control is needed.
- A timeout wakes the parked fiber, removes the waiter from the socket wait
  slot, and returns an error.
- Parent cancellation wakes parked TCP waiters and resumes them only far enough
  to observe cancellation and stop the current task.

This should align with structured concurrency: cancelling a parent task should
not leave child fibers stuck in reactor wait structures.

Early implementation phases should either implement runtime deadlines before
using timeout behavior or explicitly preserve current blocking timeout behavior
only for raw legacy APIs. Fiber-aware handle APIs should not use
`SO_RCVTIMEO` / `SO_SNDTIMEO` as their primary timeout mechanism.

## Blocking DNS

`getaddrinfo` is blocking. Making socket operations non-blocking does not make
DNS fiber-compatible. This affects both `connect` and current `listen`, because
`listen(host, port, backlog)` also resolves `host`.

Initial safe path:

- Treat host-name DNS resolution as `ImpureMayBlockThread`.
- For `listen`, either restrict the fiber-aware API to numeric bind addresses
  plus empty/any-host shorthands, or offload resolution to a blocking pool.
- For `connect`, either document the blocking DNS step while only socket connect
  is fiber-aware, or offload `getaddrinfo` to a bounded blocking pool before
  non-blocking connect.

Long-term path:

- Add an async DNS resolver or a runtime DNS work pool with backpressure.
- Make `listen` and `connect` fiber-compatible end-to-end only after DNS is
  offloaded, avoided, or async.

## Partial Write Semantics

`write(stream, data)` should mean "attempt to write all bytes before returning
`Ok(len)`." However, TCP side effects cannot be rolled back. If an error,
timeout, or cancellation happens after a partial kernel send, some bytes may
already have reached the peer.

Required decision before implementation:

- Document `write` as write-all with possible partial side effects on error or
  cancellation.
- Add `write_some(stream, data) -> Result[Int, String]` if callers need
  explicit partial-progress control.
- Do not pretend cancellation makes TCP writes atomic.

Compiler/runtime ownership rules are the same either way: the data buffer must
remain alive until the write operation has stopped using it.

## Blocking Pool Scope

The roadmap needs a concrete blocking-pool decision because DNS and foreign
calls cannot be made safe by the TCP reactor alone.

Initial scope:

- Add a bounded runtime blocking pool only if TCP `listen`/`connect` need
  host-name resolution in the fiber-aware API.
- Otherwise document that host-name DNS remains blocking and keep those calls
  classified as `ImpureMayBlockThread`.
- Foreign functions remain `ImpureMayBlockThread` by default. A broader
  blocking-pool migration for arbitrary FFI should be a separate roadmap unless
  it becomes necessary for TCP preview readiness.

## Roadmap

### Phase 0: Baseline And Tests First

Goal: capture current blocking behavior, add deterministic test support, and
define the failure we are fixing before changing runtime behavior.

Tasks:

- Add a runtime test demonstrating that many fibers waiting on TCP do not scale
  today. Keep it skipped or expected-failing until the implementation lands if
  it would hang the gate.
- Add `local_port(listener)` or equivalent test-only runtime support so tests
  can bind port `0` and discover the assigned loopback port. Fixed test ports
  should not be the foundation for this workstream.
- Add a focused test for `accept` parking: one listener, many clients, limited
  carrier threads.
- Add a focused test for `read` parking: a server delays writes while many
  client fibers wait.
- Add a test that proves current `listen(host, ...)` can perform blocking host
  resolution, or restrict the initial tests to numeric loopback.
- Add scheduler stats assertions: `fiber_parks` should increase for TCP waits.
- Add a leak-check test for connect/read/write/close lifecycle.
- Add a sanitizer-compatible stress test for close-while-read-waiting.

Risks:

- TCP tests can become flaky if they depend on public ports or timing.
- CI/macOS/Linux behavior can differ around localhost connect timing.

Verification:

- Use loopback only.
- Bind port `0` and discover the assigned port if runtime support exists;
  otherwise use test-owned port allocation with retries.
- Run with `BLORP_THREADS=1`, `2`, and `4`.
- Use short operation deadlines and deterministic handshakes.
- Verify no orphaned background tasks after the test.

Done when:

- Tests fail or are marked expected-failing for the right reason.
- Failure messages distinguish worker-thread blocking from normal test timeout.
- Loopback tests can allocate ports without fixed global port numbers.

### Phase 1: Metadata, Semantics, And ABI Foundations

Goal: make the compiler and public/runtime ABI able to reason about parking IO
before any TCP operation parks a fiber.

Tasks:

- Add the minimal call-effect model:
  - `Pure`
  - `Impure { wait = NoWait; cancellation = NotCancellationPoint }`
  - `Impure { wait = MayParkFiber; cancellation = CancellationPoint }`
  - `Impure { wait = MayBlockThread; cancellation = NotCancellationPoint }`
  - any other combination must be intentional and covered by tests
- Update builtin/intrinsic metadata so current TCP calls are represented
  honestly:
  - current `listen` and host-name `connect`: `ImpureMayBlockThread`
  - future handle-backed `accept/read/write`: `ImpureMayPark`
- Add Core invariants requiring explicit effect metadata for builtins that can
  call runtime IO.
- Make `ImpureMayPark` an ownership/liveness barrier for Perceus/reuse before
  it is used by TCP.
- Decide and document cancellation semantics in tests: parent cancellation stops
  the task at TCP cancellation points; explicit timeout returns an operation
  error.
- Decide and document write semantics: `write` is write-all but may have
  partial side effects before error/cancellation; add `write_some` later if
  callers need progress-aware APIs.
- Define the opaque handle ABI:
  - managed Core type classification;
  - C pointer representation;
  - destructor contract;
  - `Result[TcpStream, String]` / `Result[TcpListener, String]` release masks;
  - channel/task transfer behavior.
- Decide raw fd compatibility: preferred path is no fiber-aware raw fd shim;
  raw APIs are removed/migrated or isolated in an explicitly blocking module.

Risks:

- Existing optimization passes may treat all impure calls as equivalent.
- Adding effect metadata without invariants can create another stale registry.
- Changing raw fd policy can require package/test updates.

Verification:

- Compiler unit tests for effect classification.
- Core invariant tests that parking calls cannot be missing metadata.
- Codegen audit for managed TCP handle result release policy.
- Typecheck tests rejecting `Int` where `TcpStream` / `TcpListener` is expected.
- Existing compiler suite remains green.

Done when:

- No fiber-aware TCP runtime implementation is needed to prove the compiler
  model and ABI shape.
- Any future `ImpureMayPark` TCP call has a known ownership/cancellation
  contract before it lands.

### Phase 2: Runtime Reactor Skeleton

Goal: add the process-wide reactor without changing TCP behavior yet.

Tasks:

- Add `blorp_IoReactor` runtime state.
- Add backend abstraction:
  - `kqueue` backend for macOS/BSD.
  - `epoll` backend for Linux.
  - `poll` fallback.
- Add control wakeup.
- Add register/unregister/update-interest APIs.
- Add reactor startup/shutdown tied to runtime initialization.
- Add internal tests through C/runtime smoke paths where possible.

Risks:

- Reactor thread shutdown can race process exit.
- Register/unregister can race fd close.
- Platform-specific event APIs differ in edge/level behavior.

Verification:

- Unit-level C smoke via generated Blorp tests that register a socketpair or
  loopback fd, wait for readiness, and close cleanly.
- Sanitizer test for register/unregister/close loops.
- `scripts/run_tests.sh runtime` with no fd leaks or process hangs.

Done when:

- Reactor can wake runtime code on fd readiness.
- No TCP public API behavior has changed yet.

### Phase 3: Explicit TCP Runtime Handles

Goal: stop treating TCP sockets as raw integers internally.

Tasks:

- Add `TcpListener` and `TcpStream` builtin types in std.
- Add ARC-managed wrapper structs and native-refcounted `TcpInner` structs with
  fd, state, generation, waiter slots, timeout, lock, and destructor/close
  behavior.
- Add the fd/generation registry over `TcpInner`, with clear ownership rules:
  registry refs are native refs, not Blorp ARC refs.
- Add constructors used by `listen` and `connect`.
- Add destructors that close open fds and wake waiters safely.
- Migrate package/tests to opaque handles, or move old raw-`Int` wrappers to an
  explicitly blocking low-level module.
- Update docs and tests to prefer opaque handles.

Risks:

- Existing package code imports `std/net/tcp` and expects `Int` fds.
- `close` semantics change from arbitrary fd close to handle close.
- Handle destruction may close fds earlier than old raw-int code expected.

Verification:

- Compiler typecheck tests reject passing `Int` to new handle APIs.
- Runtime tests cover listener close, stream close, double close, read after
  close, and write after close.
- Leak-check confirms handles release fds and managed waiters.

Done when:

- New typed API exists and is tested.
- Compatibility path is documented and isolated.

### Phase 4: Waiter Deadlines, Cancellation, And Close Lifecycle

Goal: make IO wait lifecycle robust before any public operation parks on an fd.

Tasks:

- Add `IoWaiter` records with explicit kind, fiber, deadline, cancellation
  state, and generation.
- Add runtime helpers to install, remove, wake, and cancel waiters.
- Integrate waiter deadlines with the timer queue or reactor deadline queue.
- Make close transition atomic with waiter extraction.
- Wake parked IO waiters on task cancellation.
- Remove waiters from all wait structures on resume.
- Ignore stale readiness events with generation checks.

Risks:

- Timer and reactor wakeups can race.
- Cancellation can wake a fiber while readiness is being processed.
- A closed fd can be reused by the OS before stale reactor events drain.

Verification:

- Runtime unit/smoke tests for install/remove/wake without TCP operations.
- Sanitizer stress for timeout/readiness/cancel close races using socketpair or
  loopback helper.
- Scheduler stats show no growing pending timers or waiters after tests.

Done when:

- A future `accept/read/write/connect` implementation can reuse the waiter API
  without open-coded lifecycle rules.

### Phase 5: Fiber-Aware `accept`

Goal: `accept` parks fibers when no connection is ready.

Tasks:

- Set listener fd non-blocking.
- Implement accept loop:
  - call `accept4`/`accept`;
  - return stream on success;
  - on `EAGAIN`/`EWOULDBLOCK`, register read readiness and park;
  - retry after wake;
- on close or timeout, return an operation error.
- on task cancellation, stop through the existing structured-cancellation path
  rather than returning a normal TCP result.
- Enforce one pending accept waiter per listener initially.
- Wake accept waiter on listener close.

Risks:

- Multiple accept waiters can cause thundering herd or stale waiter bugs.
- Readiness can be spurious; implementation must always retry syscall.
- Closing a listener while a fiber is parked must not UAF the waiter.

Verification:

- One fiber waits in `accept`; another connects; accept returns.
- Many listeners across fibers do not block all workers.
- Close listener while accepting returns an error and frees resources.
- Scheduler stats show TCP accept parks.
- `BLORP_THREADS=1` test passes.

Done when:

- `accept` no longer pins worker threads in fiber context.

### Phase 6: Fiber-Aware `read`

Goal: `read` parks fibers when no bytes are ready.

Tasks:

- Set stream fd non-blocking.
- Implement read loop:
  - call `recv`;
  - return `Bytes` on success;
  - return empty `Bytes` on EOF if that remains the API contract;
  - on `EAGAIN`/`EWOULDBLOCK`, register read readiness and park;
  - retry after wake.
- Enforce one pending read waiter per stream.
- Wake reader on stream close.

Risks:

- EOF and timeout need distinct results if users need to tell them apart.
- Concurrent reads need a policy. Initial policy should reject or serialize.
- Allocating `Bytes` before parking can leak if the operation is cancelled.

Verification:

- Delayed server write wakes parked client reader.
- EOF returns the documented result.
- Read timeout returns deterministic error.
- Close while read parked wakes reader safely.
- Leak-check and sanitizer for cancellation and close races.

Done when:

- Waiting TCP reads scale by parked fibers, not worker threads.

### Phase 7: Fiber-Aware `write`

Goal: `write` parks fibers when the socket send buffer is full.

Tasks:

- Implement write-all loop:
  - call `send`;
  - advance offset on partial writes;
  - on `EAGAIN`/`EWOULDBLOCK`, register write readiness and park;
  - retry until all bytes are written or error.
- Enforce one pending write waiter per stream or add explicit serialized write
  queue.
- Keep the write buffer alive across parks.
- Wake writer on stream close.
- Add `write_some` before or alongside this phase if progress-aware write
  semantics are required.

Risks:

- Partial writes plus cancellation can produce surprising, but unavoidable, TCP
  side effects.
- Concurrent writes can interleave bytes unless serialized.
- Retaining/copying write buffers incorrectly can leak or UAF.

Verification:

- Large write to slow reader parks and completes.
- Partial write count is correct on error if API exposes partial progress.
- Concurrent writes have documented deterministic behavior.
- Leak-check verifies buffer lifetime across cancellation.
- Sanitizer close-while-write-waiting test.

Done when:

- TCP writes no longer pin workers under backpressure.

### Phase 8: Fiber-Aware `connect` And `listen` DNS Policy

Goal: make socket connect fiber-aware and settle the remaining DNS/listen
blocking story.

Tasks:

- Set socket non-blocking before `connect`.
- On `EINPROGRESS`, register write readiness and park.
- On wake, check `SO_ERROR`.
- Restore no blocking mode because handles are permanently non-blocking.
- Decide and implement one DNS policy:
  - restrict fiber-aware `listen` and `connect` to numeric addresses / any-host
    shorthands; or
  - add a bounded blocking pool for `getaddrinfo`; or
  - leave hostname paths explicitly `ImpureMayBlockThread` and documented as
    not fully virtual-thread-compatible.
- Classify `listen` honestly under the chosen DNS policy.

Risks:

- DNS can still pin workers if not offloaded.
- Connect timeout behavior differs by platform.
- Failed connects can produce readiness followed by `SO_ERROR`.
- `listen(host, ...)` can still block on host resolution if not restricted.

Verification:

- Connect to local delayed accept server.
- Connect refused returns useful error.
- Timeout to unroutable address does not hang a worker indefinitely.
- Listen with numeric loopback does not use blocking DNS.
- Host-name listen/connect behavior is tested under the chosen policy.
- `BLORP_THREADS=1` connect/read/write smoke passes.

Done when:

- Socket connect itself is fiber-aware.
- DNS/listen blocking is either removed, offloaded, or explicitly isolated from
  the fiber-aware API.

### Phase 9: Package Migration

Goal: move higher-level network packages onto fiber-aware TCP.

Tasks:

- Update `pkg/net/http_client.brp`.
- Update `pkg/net/websocket.brp`.
- Update `pkg/net/smtp.brp`.
- Audit TLS. If TLS uses OpenSSL blocking calls, either:
  - keep TLS on a blocking pool, or
  - convert TLS to non-blocking `SSL_read` / `SSL_write` with WANT_READ /
    WANT_WRITE integrated with the reactor.
- Decide whether UDP should use the same reactor path.

Risks:

- TLS may block despite TCP being non-blocking.
- Protocol code may assume raw fd `Int`.
- WebSocket frame reads may need repeated read loops with clear EOF/error
  handling.

Verification:

- Package typecheck tests compile against opaque handles.
- Local loopback HTTP/WebSocket/TCP tests pass.
- Blocking TLS operations are classified as `ImpureMayBlockThread` until fixed.

Done when:

- Higher-level net packages either benefit from fiber-aware TCP or are clearly
  isolated behind blocking-pool metadata.

### Phase 10: Performance And Fairness Tuning

Goal: improve throughput and latency after correctness is proven.

Tasks:

- Benchmark many idle connections.
- Benchmark many slow readers/writers.
- Benchmark accept throughput.
- Benchmark connect storm behavior.
- Measure reactor wake batching.
- Consider per-worker reactors only if one reactor thread becomes a bottleneck.
- Consider write coalescing only after write ordering semantics are explicit.

Risks:

- Optimizing too early can obscure lifecycle bugs.
- Edge-triggered backends can miss readiness if drain loops are wrong.
- Too many worker wakeups can hurt CPU-bound programs.

Verification:

- Benchmarks under `benchmarks/` with one timed run after warmup.
- Compare `BLORP_THREADS=1`, `2`, `4`, and host CPU count.
- Track scheduler counters alongside wall time.
- Confirm no regression in non-network concurrency tests.

Done when:

- TCP wait scalability is limited by ready work and kernel IO, not parked fiber
  count.

## Testing Matrix

Run these classes after each implementation phase that changes runtime IO:

```bash
make
make fmt-check
scripts/run_tests.sh unit
scripts/run_tests.sh compiler
scripts/run_tests.sh runtime
```

Focused gates:

```bash
BLORP_THREADS=1 ./blorp test tests/test_blorp/sys/test_tcp.brp
BLORP_THREADS=2 ./blorp test tests/test_blorp/sys/test_tcp.brp
BLORP_THREADS=4 ./blorp test tests/test_blorp/sys/test_tcp.brp
./blorp test --leak-check tests/test_blorp/sys/test_tcp.brp
./blorp test --sanitize tests/test_blorp/sys/test_tcp.brp
```

Add new focused files rather than overloading one large TCP test:

- `tests/test_blorp/sys/test_tcp_basic.brp`
- `tests/test_blorp/sys/test_tcp_virtual_threads.brp`
- `tests/test_blorp/sys/test_tcp_close_races.brp`
- `tests/test_blorp/sys/test_tcp_timeouts.brp`
- `tests/test_blorp/sys/test_tcp_many_connections.brp`

## Risk Register

| Risk | Impact | Mitigation |
| --- | --- | --- |
| Stale reactor event after fd reuse | UAF or wrong fiber wake | Runtime handle generation and unregister-on-close |
| Close racing parked read/write | UAF or hung fiber | Atomic close transition that extracts and wakes waiters |
| Timeout racing readiness | Double wake or stale waiter | Idempotent scheduling plus remove-from-all-wait-structures discipline |
| DNS remains blocking | Worker pinned during listen/connect | Restrict to numeric addresses, document initially, or offload to a bounded blocking pool |
| Blocking TLS over non-blocking TCP | Worker still pinned | Treat TLS separately with WANT_READ/WANT_WRITE or blocking pool |
| Concurrent writes interleave | Protocol corruption | Enforce one writer or serialized write queue |
| Concurrent reads compete | Lost bytes or nondeterminism | Enforce one reader initially |
| Optimizer moves drops before park | UAF on parked operation | `ImpureMayPark` as ownership/liveness barrier |
| Reactor thread shutdown hangs | Test/process hangs | Explicit shutdown control event and join path |
| Platform backend mismatch | Mac/Linux divergence | kqueue/epoll/poll backend tests through same abstraction |

## Architectural End State

The intended end state is:

- TCP source code remains direct and readable.
- TCP wait operations park fibers, not OS threads.
- The compiler explicitly models parking and thread-blocking effects.
- Runtime TCP handles are opaque managed values, not arbitrary integers.
- Waiter lifecycle is represented with precise runtime states.
- Close, timeout, cancellation, and readiness races are covered by tests.
- Higher-level networking packages either use fiber-aware TCP or are explicitly
  isolated as blocking native integrations.

This keeps Blorp aligned with its existing concurrency model: structured,
direct-style, value-semantic code without exposing users to async machinery.
