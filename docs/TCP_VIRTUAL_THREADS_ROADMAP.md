# TCP Virtual Threads Roadmap

This document defines the completed roadmap for making Blorp TCP operations
compatible with virtual threads, plus deferred follow-up work that should only
proceed when measurements justify it.

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

- `listen(host, port, backlog) -> Result[TcpListener, String]`
- `accept(listener) -> Result[TcpStream, String]`
- `connect(host, port) -> Result[TcpStream, String]`
- `read(stream, max_bytes) -> Result[Bytes, String]`
- `write(stream, data) -> Result[Int, String]`
- `close(listener_or_stream) -> Void` through TCP handle traits
- `set_reuse_addr(listener) -> Result[Int, String]`
- `local_port(listener_or_stream) -> Result[Int, String]` through TCP handle
  traits
- `set_timeout(listener_or_stream, ms) -> Result[Int, String]` through TCP
  handle traits

The runtime still uses blocking `getaddrinfo` for `listen(host, ...)` and the
DNS phase of `connect(host, ...)`. Handle-backed socket operations
(`accept`, socket `connect`, `read`, and `write`) now use nonblocking fds and
park fibers through the runtime reactor when kernel readiness is needed. That
means numeric-address socket waits no longer pin OS worker threads, while
hostname resolution can still pin a worker until DNS policy is tightened.
Numeric hosts are resolved through an explicit `AI_NUMERICHOST` path so the
documented loopback/no-DNS fast path does not depend on platform-specific
`getaddrinfo` behavior. Empty `listen("", ...)` hosts are translated to a
passive `NULL` bind host before `getaddrinfo`, so any-host binds are also an
explicit no-DNS path. Hosts longer than the runtime ABI buffer are rejected
before resolution instead of being truncated into a different hostname.

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
  `MayBlockThread`, and combined `MayBlockThreadAndParkFiber`.
- Current handle-backed TCP operations use explicit wait-effect metadata:
  `listen` and `set_timeout` are `MayBlockThread`; `accept`, `read`, and
  `write` are `MayParkFiber`; `connect` is
  `MayBlockThreadAndParkFiber` because DNS can block before socket connect
  parks on readiness; `close`, `set_reuse_addr`, and `local_port` are impure
  `NoWait`.
- Current TCP runtime ownership contracts are explicit: handles, host strings,
  and `Bytes` buffers are borrowed by runtime calls, and returned `Result`
  values are owned by the caller.
- `local_port` exists to make loopback tests bind port `0` without relying on
  fixed global ports.
- A compiler consistency test now parses std source and rejects any impure
  runtime-backed `builtin("...")` function that lacks explicit call-effect
  metadata.
- Resolved C runtime symbols now carry the same call-effect metadata as their
  std source declarations, and the compiler rejects drift between the two.
- Core foreign declarations and resolved foreign call kinds now carry explicit
  call-effect metadata: `foreign pure func` is `Pure`, and impure foreign calls
  default to `MayBlockThread`.
- Reuse analysis now treats explicit `MayParkFiber` call effects as liveness
  barriers for both runtime builtins and foreign calls, so a collection owner
  dropped before a parking call is not reused after the park point.
- `TcpListener` and `TcpStream` now have std source anchors plus managed runtime
  pointer ABI metadata. Public TCP functions now use those handles instead of
  raw `Int` descriptors.
- `Result[TcpListener, String]` and `Result[TcpStream, String]` are classified
  as managed stack results, so success and error payload release policy can be
  represented for handle-returning TCP APIs.
- The C runtime now has explicit opaque TCP wrapper structs, native-refcounted
  `TcpInner` state, fd/generation/state/wait-slot fields, ARC destructors,
  idempotent close behavior, and fd-wrapper constructors. Public
  `std/net/tcp` calls now return and accept these handles.
- Current TCP operations on existing handles coordinate through explicit waiter
  ownership, fd/generation checks, and close wakeups, so `close` cannot race
  `accept`/`read`/`write` into fd reuse or use-after-close. `listen` and
  `connect` create their fd before a Blorp handle is exposed, so user code
  cannot close that fd concurrently.
- The C runtime now has an initial process-wide IO reactor skeleton. The active
  backend is the portable `poll` loop; `kqueue` and `epoll` are named target
  backends but are not reported active until their loops exist. The skeleton has
  a control wakeup pipe, fd/generation registrations, readiness state,
  register/update/unregister helpers, startup/shutdown hooks, and a compile-time
  C smoke test. A focused runtime C smoke now compiles the runtime and verifies
  that the reactor observes pipe readiness, suppresses stale readiness after
  interest updates, and survives register/update/unregister loops without
  running inside the broad OCaml unit process. Public TCP accept/read/write and
  socket-connect readiness now park fibers through this reactor.

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

The API has moved from raw `Int` descriptors to opaque handles:

```blorp
type TcpListener = builtin
type TcpStream = builtin

trait TcpClosable:
	func close(handle: Self) -> Void

trait TcpLocalPort:
	func local_port(handle: Self) -> Result[Int, String]

trait TcpTimeout:
	func set_timeout(handle: Self, ms: Int) -> Result[Int, String]

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

func set_reuse_addr(listener: TcpListener) -> Result[Int, String]:
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
compiler and runtime must agree on their ABI so handle-backed TCP is represented
consistently across type checking, Core, ownership, and codegen.

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
        wait:
            NoWait
          | MayParkFiber
          | MayBlockThread
          | MayBlockThreadAndParkFiber,
        cancellation: NotCancellationPoint | CancellationPoint
    }
```

This should be represented in the intrinsic registry or call metadata, not
recovered from function names. `Pure` must not carry wait or cancellation
metadata. Runtime IO builtins must use the `Impure` form explicitly.

For readability, the rest of this document uses `ImpureMayPark`,
`ImpureMayBlockThread`, `ImpureMayBlockThreadAndPark`, and `ImpureNoPark` as
shorthand labels for those structured `Impure` cases, not as a recommendation
to implement a flat enum.

TCP operations should be:

- `listen`: `ImpureMayBlockThread` until DNS/bind behavior is restricted or
  moved to a blocking pool
- `accept`: `ImpureMayPark`, `CancellationPoint`
- `connect`: `ImpureMayBlockThreadAndPark`, `CancellationPoint` while DNS is
  inline and socket connect is reactor-backed, then `ImpureMayPark`,
  `CancellationPoint` after DNS is offloaded or restricted
- `read`: `ImpureMayPark`, `CancellationPoint`
- `write`: `ImpureMayPark`, `CancellationPoint`
- `close`: `ImpureNoPark` or narrowly `ImpureMayPark` only if close wakes via
  reactor synchronization that can wait

Foreign functions now default to `ImpureMayBlockThread` unless declared
`foreign pure func`. Future fiber-safe or blocking-pool annotations should
replace that default explicitly rather than relying on naming conventions.

### Optimization Barriers

Core passes must not:

- duplicate `ImpureMayPark` calls;
- reorder managed drops before a parking call if the parked call still needs
  the value;
- move a parking call across another impure call;
- fuse loops in a way that changes how many times a parking call happens;
- CSE or eliminate parking calls even if their return values appear unused.

`ImpureMayPark` is now a liveness barrier for reuse analysis, including
runtime-backed builtins and foreign calls that carry a parking call effect.

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

`set_timeout` now configures runtime operation deadlines on TCP handles. It
does not configure kernel socket timeouts.

Cancellation must match existing structured concurrency semantics. A parent
cancellation is not an ordinary TCP result that user code should pattern-match
as `Err("cancelled")`. TCP operations should be cancellation points: when the
current task is cancelled, execution stops through the same task-cancellation
path used by channels/task joins.

Preferred timeout semantics:

- `set_timeout(stream, ms)` sets a default operation timeout on the handle.
- Negative timeout values are rejected before mutating the handle.
- `read_timeout(stream, max_bytes, ms)` and `write_timeout(...)` can be added
  later if call-site timeout control is needed.
- A timeout wakes the parked fiber, removes the waiter from the socket wait
  slot, and returns an error.
- Parent cancellation wakes parked TCP waiters and resumes them only far enough
  to observe cancellation and stop the current task.

This should align with structured concurrency: cancelling a parent task should
not leave child fibers stuck in reactor wait structures.

Fiber-aware handle APIs use these runtime deadlines when registering reactor
waiters and do not use `SO_RCVTIMEO` / `SO_SNDTIMEO` as their timeout
mechanism.

## Blocking DNS

`getaddrinfo` is blocking. Making socket operations non-blocking does not make
DNS fiber-compatible. This affects both `connect` and current `listen`, because
`listen(host, port, backlog)` also resolves `host`.

Initial safe path:

- Treat host-name DNS resolution as `ImpureMayBlockThread`.
- Do not treat numeric literal addresses as blocking DNS. Done through a shared
  TCP runtime resolver that applies `AI_NUMERICHOST` when the host is a numeric
  IPv4/IPv6 literal.
- Treat empty `listen("", ...)` as a passive any-host bind, not as a hostname.
  Done by translating the lookup host to `NULL` when `AI_PASSIVE` is set.
- Reject hosts that cannot fit the runtime resolver buffer. Done for
  `listen` and `connect`; overlong hosts return `"host too long"` before any
  DNS or socket operation.
- Reject malformed runtime `String` host values before copying into the resolver
  buffer. Covered by a focused C smoke where `host.len > host.capacity`.
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
- Otherwise document that host-name DNS remains blocking and classify calls
  that both resolve names and park on sockets as
  `ImpureMayBlockThreadAndPark`.
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
  - `Impure { wait = MayBlockThreadAndParkFiber; cancellation = CancellationPoint }`
  - any other combination must be intentional and covered by tests
- Update builtin/intrinsic metadata so current TCP calls are represented
  honestly:
  - current `listen`: `ImpureMayBlockThread`
  - handle-backed `accept/read/write`: `ImpureMayPark`
  - `connect` while DNS is inline and socket connect is reactor-backed:
    `ImpureMayBlockThreadAndPark`
- Add Core invariants requiring explicit effect metadata for builtins that can
  call runtime IO.
- Add explicit call-effect metadata to Core foreign declarations and resolved
  foreign call kinds. Done: pure foreign calls are `Pure`, impure foreign calls
  default to `ImpureMayBlockThread`.
- Make `ImpureMayPark` an ownership/liveness barrier for Perceus/reuse before
  it is used by TCP. Done for reuse analysis across runtime-backed builtins and
  foreign calls carrying a parking call effect.
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

- Add `blorp_IoReactor` runtime state. Initial state exists.
- Add backend abstraction. Initial enum exists, with `poll` as the only active
  backend until native backend loops are implemented and tested:
  - `kqueue` backend for macOS/BSD.
  - `epoll` backend for Linux.
  - `poll` fallback.
- Add control wakeup. Initial control pipe exists.
- Runtime-owned reactor control fds are close-on-exec so subprocesses do not
  inherit internal wakeup pipes. Done through a shared pipe helper that uses
  atomic close-on-exec/nonblocking creation where the platform exposes it and
  otherwise falls back to immediate flag application. Covered by a focused C
  smoke.
- Add register/unregister/update-interest APIs. Initial fd/generation APIs
  exist. Runtime smoke coverage now verifies that multiple interests on one
  registration are accumulated rather than overwritten.
- Add reactor startup/shutdown tied to runtime initialization. Initial lazy
  startup and process-exit shutdown exist.
- Add internal tests through C/runtime smoke paths where possible. Source
  consistency, compile-time C smoke tests, and a focused runtime C readiness
  smoke exist.

Risks:

- Reactor thread shutdown can race process exit.
- Register/unregister can race fd close.
- Platform-specific event APIs differ in edge/level behavior.

Verification:

- Unit-level source/ABI checks and compile-time C smoke for the runtime
  skeleton.
- Focused C smoke that registers a pipe fd, waits for readiness, and closes
  cleanly without running inside the broad OCaml unit process.
- Sanitizer coverage for public TCP/fiber behavior via `./blorp test
  --sanitize tests/test_blorp/sys/test_tcp.brp`. The direct C smoke sanitizer
  mode currently exposes a minicoro/ASan compatibility issue on macOS (`failed
  to munmap`) before reporting Blorp runtime findings, so it remains a separate
  harness-hardening follow-up rather than a source of truth for TCP semantics.
- `scripts/run_tests.sh runtime` with no fd leaks or process hangs.

Done when:

- Reactor can wake runtime code on fd readiness through a focused runtime
  smoke.
- Active backend metadata never claims native kqueue/epoll until those loops are
  implemented.
- No TCP public API behavior has changed yet.

### Phase 3: Explicit TCP Runtime Handles

Goal: stop treating TCP sockets as raw integers internally.

Tasks:

- Add `TcpListener` and `TcpStream` builtin types in std. Done.
- Add ARC-managed wrapper structs and native-refcounted `TcpInner` structs with
  fd, state, generation, waiter slots, timeout, lock, and destructor/close
  behavior. Done, including waiter wakeup through the shared waiter lifecycle.
- Guard fd operations on existing handles. Done: non-parking helper operations
  still validate under the handle lifecycle, and parking operations use explicit
  waiter ownership instead of holding a lock across a blocking syscall.
- Add the fd/generation registry over `TcpInner`, with clear ownership rules:
  registry refs are native refs, not Blorp ARC refs. Public TCP parking now
  uses the reactor registry through the shared waiter lifecycle.
- Add constructors used by `listen` and `connect`. Low-level fd wrapper
  constructors exist and public TCP calls now return typed handles. Public
  `long fd` wrappers are separated from internal owned-`int fd` constructors,
  so external ABI validation and runtime-owned fd construction have distinct
  boundaries.
- Validate runtime ABI inputs before calling C socket APIs. `listen` now rejects
  backlog values outside the C `int` range instead of truncating through a cast,
  and low-level fd wrappers reject invalid or already-closed `long` fd values
  before narrowing to the runtime's `int` fd representation. They also reject
  open non-socket descriptors instead of letting pipes/files become owning TCP
  handles. Public wrapper-created handles are normalized to nonblocking mode
  before construction; listener wrappers additionally require a listening stream
  socket when the platform exposes a usable `SO_ACCEPTCONN` check.
- Public TCP handle-producing helpers reject null handles instead of producing
  `Ok(NULL)`, so wrapper failures cannot leak an invalid opaque handle into
  Blorp code.
- Runtime-managed TCP fds are marked close-on-exec at the typed wrapper
  boundary. TCP socket creation and accepted sockets also go through shared
  helpers that use atomic close-on-exec creation where the platform exposes it
  and otherwise fall back to immediate flag application. Covered by a focused C
  smoke so future socket creation paths inherit the same invariant.
- Add destructors that close open fds and wake waiters safely. Done for
  idempotent close/destructor fd cleanup and parked waiter wakeup.
- Migrate package/tests to opaque handles, or move old raw-`Int` wrappers to an
  explicitly blocking low-level module. Done for current `pkg/net` TCP users and
  tests.
- Update docs and tests to prefer opaque handles. Done for the TCP roadmap and
  TCP/package tests.

Risks:

- Existing package code imports `std/net/tcp` and expects `Int` fds.
- `close` semantics change from arbitrary fd close to handle close.
- Handle destruction may close fds earlier than old raw-int code expected.

Verification:

- Compiler typecheck tests reject passing `Int` to new handle APIs.
- Runtime tests cover listener close, stream close, double close, read after
  close, and write after close.
- Leak-check confirms handle tests leave no reported leaks.

Done when:

- New typed API exists and is tested.
- Compatibility path is documented and isolated.

### Phase 4: Waiter Deadlines, Cancellation, And Close Lifecycle

Goal: make IO wait lifecycle robust before any public operation parks on an fd.

Tasks:

- Add `IoWaiter` records with explicit kind, fiber, deadline, cancellation
  state, and generation. Initial runtime record exists.
- Add runtime helpers to install, remove, wake, and cancel waiters. Initial
  helpers exist for one waiter per operation slot.
- Integrate waiter deadlines with the timer queue or reactor deadline queue.
  Done with a dedicated IO deadline queue that extracts timed-out waiters
  before waking the parked fiber.
- Make close transition atomic with waiter extraction. Done for current handle
  close/destructor paths.
- Wake parked IO waiters on task cancellation. Cancellation extraction helper
  exists, and the shared TCP park helper removes its waiter before observing
  task cancellation. Covered by a focused C runtime smoke that cancels a task
  parked on an IO waiter and verifies both the waiter slot and deadline queue
  are cleaned up.
- Remove waiters from all wait structures on resume. Slot removal/extraction
  exists, and deadline queue removal is centralized in waiter extraction.
- Ignore stale readiness events with generation checks. Done in the readiness
  extraction helper.
- Add a shared TCP park helper for `accept/read/write/connect`. Done for
  timeout, close, readiness, and cancellation cleanup. Public operations now
  use the shared register/park/unregister helper so cancellation cannot skip
  reactor unregister cleanup.
- Make reactor registration cleanup interest-scoped. Done by treating each
  parked operation as an interest lease: read cleanup releases only read
  interest, write cleanup releases only write interest, and the fd registration
  is removed only when no interests remain.
- Make parked-fiber resumption thread-affine. Done by assigning a fiber to a
  carrier after its first resume and allowing work stealing only for never-run
  fibers. Reactor/timer/channel wakeups return parked fibers to their owner
  queue so coroutine stacks are not migrated after suspension.

Risks:

- Timer and reactor wakeups can race.
- Cancellation can wake a fiber while readiness is being processed.
- A closed fd can be reused by the OS before stale reactor events drain.

Verification:

- Runtime C smoke tests for install/remove/wake, deadline timeout,
  task-cancellation cleanup, and close wakeups without public TCP operations.
- Sanitizer stress for timeout/readiness/cancel close races using socketpair or
  loopback helper.
- Focused public TCP regression for nested multi-worker parked reads, with
  normal, sanitizer, and leak-check coverage.
- Scheduler stats show no growing pending timers or waiters after tests.

Done when:

- `accept/read/write/connect` reuse the waiter API without open-coded lifecycle
  rules.

### Phase 5: Fiber-Aware `accept`

Goal: `accept` parks fibers when no connection is ready.

Tasks:

- Set listener fd non-blocking. Done.
- Implement accept loop:
  - call `accept4`/`accept`;
  - return stream on success;
  - on `EAGAIN`/`EWOULDBLOCK`, register read readiness and park;
  - retry after wake;
- Done. Accepted streams stay nonblocking because stream operations now own
  reactor-backed nonblocking `read`/`write` behavior.
- on close or timeout, return an operation error. Done through the shared waiter
  wake reason path.
- on task cancellation, stop through the existing structured-cancellation path
  rather than returning a normal TCP result. Done for parked accept, with a
  cleanup-frame-backed reactor registration guard so cancellation cannot leak a
  retained fd registration.
- Enforce one pending accept waiter per listener initially. Done by the
  per-kind waiter slot.
- Wake accept waiter on listener close. Done through close-and-extract.

Risks:

- Multiple accept waiters can cause thundering herd or stale waiter bugs.
- Readiness can be spurious; implementation must always retry syscall.
- Closing a listener while a fiber is parked must not UAF the waiter.

Verification:

- One fiber waits in `accept`; another connects; accept returns.
- Many listeners across fibers do not block all workers.
- Close listener while accepting returns an error and frees resources. Covered by
  the focused close-wakeup regression.
- Listener timeout while accepting returns an error and frees resources. Covered
  by the focused timeout regression.
- Parent cancellation of a parked accept stops through structured cancellation
  and cleans up waiter state. Covered by the focused public concurrent-timeout
  regression.
- Scheduler stats show TCP accept parks. Covered by all parked-accept
  regressions.
- Leak-check and sanitizer pass for the focused public TCP suite. Sanitizer
  builds use a larger fiber stack because ASan stack redzones make the normal
  production fiber stack too small for deep runtime paths.
- `BLORP_THREADS=1`/single-worker test passes. Covered by the focused TCP test
  using `concurrent(max_threads: 1)`.

Done when:

- `accept` no longer pins worker threads in fiber context. Covered for the
  single-worker delayed-connect, timeout, parent-cancellation, and close-wakeup
  cases.

### Phase 6: Fiber-Aware `read`

Goal: `read` parks fibers when no bytes are ready.

Tasks:

- Set stream fd non-blocking.
  Done at `read` entry. Streams stay nonblocking and stream operation parity is
  now complete for both `read` and `write`.
- Implement read loop:
  - call `recv`;
  - return `Bytes` on success;
  - return empty `Bytes` on EOF if that remains the API contract;
  - on `EAGAIN`/`EWOULDBLOCK`, register read readiness and park;
  - retry after wake.
  Done through the shared register/park/unregister helper.
- Enforce one pending read waiter per stream. Done by the per-stream read waiter
  slot; a second concurrent reader currently receives an operation error rather
  than queueing behind the first reader.
- Wake reader on stream close. Done through close-and-extract.

Risks:

- EOF and timeout need distinct results if users need to tell them apart.
- Concurrent reads need a policy. Initial policy should reject or serialize.
- Allocating `Bytes` before parking can leak if the operation is cancelled.

Verification:

- Delayed server write wakes parked client reader. Covered by the single-worker
  delayed-write regression.
- EOF returns the documented result. Covered by the EOF regression.
- Read timeout returns deterministic error. Covered by the timeout regression.
- Close while read parked wakes reader safely. Covered by the close-wakeup
  regression.
- Parent cancellation of a parked read stops through structured cancellation
  and cleans up waiter state. Covered by the focused public concurrent-timeout
  regression.
- Leak-check and sanitizer for cancellation and close races. Covered for the
  focused TCP suite.

Done when:

- Waiting TCP reads scale by parked fibers, not worker threads. Covered for the
  single-worker delayed-write, timeout, parent-cancellation, close, and EOF
  cases.

### Phase 7: Fiber-Aware `write`

Goal: `write` parks fibers when the socket send buffer is full.

Tasks:

- Implement write-all loop:
  - call `send`;
  - advance offset on partial writes;
  - on `EAGAIN`/`EWOULDBLOCK`, register write readiness and park;
  - retry until all bytes are written or error.
  Done through the shared register/park/unregister helper.
- Suppress platform SIGPIPE behavior for socket writes so peer-close failures
  are reported through `Result` instead of terminating the process.
  Done with `MSG_NOSIGNAL` where available and `SO_NOSIGPIPE` on platforms
  that require per-socket configuration.
- Enforce one pending write waiter per stream or add explicit serialized write
  queue.
  Done with explicit per-stream write-active state. A concurrent second writer
  receives an operation error instead of interleaving bytes.
- Keep the write buffer alive across parks.
  Done by borrowing the caller-provided `Bytes` for the duration of the write
  and registering a cleanup-frame-backed write-active guard so cancellation
  releases the retained TCP inner handle.
- Wake writer on stream close.
  Done for local stream close.
- Add `write_some` before or alongside this phase if progress-aware write
  semantics are required.
  Deferred. `write` remains write-all semantically; if an error or cancellation
  happens after partial kernel progress, the API still returns `Err` without a
  byte count.

Risks:

- Partial writes plus cancellation can produce surprising, but unavoidable, TCP
  side effects.
- Concurrent writes can interleave bytes unless serialized.
- Retaining/copying write buffers incorrectly can leak or UAF.

Verification:

- Large write to slow reader parks and completes. Covered by the backpressure
  regression.
- Partial write count is correct on error if API exposes partial progress.
  Not applicable yet because `write_some` is deferred.
- Concurrent writes have documented deterministic behavior. Covered by the
  write-active runtime state and a focused C runtime smoke that proves a second
  writer cannot acquire the operation slot while the first writer owns it.
  Avoid public tests that depend on filling OS socket buffers to prove this
  invariant; that makes the test host-timing dependent.
- Zero-length writes still validate the stream handle. Covered by a regression
  where `write(stream, bytes(0))` succeeds for an open stream and fails after
  close.
- Leak-check verifies buffer lifetime across cancellation. Covered by the
  focused TCP leak-check suite.
- Sanitizer close-while-write-waiting test. Covered by the local-close
  wakeup regression.
- Peer-close write failure must not terminate the process with SIGPIPE.
  Covered by a focused runtime C smoke that writes to a closed socketpair peer
  and expects `blorp_tcp_write` to return `Err`.
- Invalid runtime write buffers are rejected rather than silently treated as an
  empty write or passed to `send` with invalid bounds. Covered by focused C
  smokes for `blorp_tcp_write(stream, NULL)`, negative `Bytes.len`, and
  `Bytes.len > Bytes.capacity`.
- Oversized read requests are rejected before allocating a buffer. Covered by a
  focused C smoke for `blorp_tcp_read(stream, LONG_MAX)` and a public runtime
  regression for the documented 64 MiB per-read limit.

Done when:

- TCP writes no longer pin workers under backpressure. Covered for completion,
  timeout, and local-close wakeup cases.

### Phase 8: Fiber-Aware `connect` And `listen` DNS Policy

Goal: make socket connect fiber-aware and settle the remaining DNS/listen
blocking story.

Tasks:

- Set socket non-blocking before `connect`.
  Done before calling `connect`.
- On `EINPROGRESS`, register write readiness and park.
  Done through the shared register/park/unregister helper.
- On wake, check `SO_ERROR`.
  Done. Refused local connections exercise this path.
- Restore no blocking mode because handles are permanently non-blocking.
  Done. Accepted streams are no longer restored to blocking mode, and stream
  operations own nonblocking behavior.
- Decide and implement one DNS policy:
  - restrict fiber-aware `listen` and `connect` to numeric addresses / any-host
    shorthands; or
  - add a bounded blocking pool for `getaddrinfo`; or
  - leave hostname paths explicitly `ImpureMayBlockThread` and documented as
    not fully virtual-thread-compatible.
  Chosen for this phase: numeric-address socket operations are fiber-aware;
  hostname resolution remains a blocking `getaddrinfo` boundary and is
  documented in `std/net/tcp`. A bounded blocking DNS pool remains a separate
  future improvement.
- Classify `listen` honestly under the chosen DNS policy.
  Done in builtin wait metadata: `listen` remains `May_block_thread`; `accept`,
  `read`, and `write` are `May_park_fiber`; `connect` is
  `May_block_thread_and_park_fiber` until DNS is split, restricted, or
  offloaded.

Risks:

- DNS can still pin workers if not offloaded.
- Connect timeout behavior differs by platform.
- Failed connects can produce readiness followed by `SO_ERROR`.
- `listen(host, ...)` can still block on host resolution if not restricted.

Verification:

- Connect to local delayed accept server.
  Covered indirectly by the single-worker accept/connect/read/write TCP tests.
- Connect refused returns useful error.
  Covered by a closed-loopback-port regression.
- Timeout to unroutable address does not hang a worker indefinitely.
  Deferred until connect exposes an operation timeout or DNS/connect timeout
  policy is expanded beyond concurrent-block cancellation.
- Listen with numeric loopback does not use blocking DNS.
  Numeric loopback coverage exists throughout the TCP suite, and an OCaml
  consistency regression now guards that the runtime uses an explicit
  `AI_NUMERICHOST` path for numeric hosts.
- Host-name listen/connect behavior is tested under the chosen policy.
  Documented as blocking in `std/net/tcp`, the standard-library overview, and
  the language guide; no hostname runtime test was added to avoid
  environment-dependent DNS behavior.
- `BLORP_THREADS=1` connect/read/write smoke passes.
  Covered by focused single-worker TCP tests.

Done when:

- Socket connect itself is fiber-aware. Done after any blocking DNS resolution.
- DNS/listen blocking is either removed, offloaded, or explicitly isolated from
  the fiber-aware API. Done by documenting hostname resolution as the remaining
  blocking boundary and keeping `listen` classified as thread-blocking metadata.

### Phase 9: Package Migration

Goal: move higher-level network packages onto fiber-aware TCP.

Tasks:

- Update `pkg/net/http_client.brp`. Done for opaque `TcpStream` handles.
- Update `pkg/net/websocket.brp`. Done for opaque `TcpStream` handles.
- Update `pkg/net/smtp.brp`. Done for opaque `TcpStream` handles.
- Audit TLS. If TLS uses OpenSSL blocking calls, either:
  - keep TLS on a blocking pool, or
  - convert TLS to non-blocking `SSL_read` / `SSL_write` with WANT_READ /
    WANT_WRITE integrated with the reactor.
  Current decision: TLS remains a blocking native-backed package for now, but
  it exposes a nominal `TlsConn` newtype over `Ptr` so raw foreign pointers do
  not leak through its public API. A typecheck regression rejects passing
  arbitrary `Ptr` values to TLS APIs.
- Decide whether UDP should use the same reactor path.
  Current decision: UDP remains a blocking native-backed package for now, but
  it exposes a nominal `UdpSocket` newtype over `Int` so raw file descriptors do
  not leak through its public API. A typecheck regression rejects passing
  arbitrary `Int` values to UDP APIs.

Risks:

- TLS may block despite TCP being non-blocking.
- Future protocol code may accidentally assume raw fd `Int`; typecheck
  coverage now catches the current package clients and UDP public APIs.
- WebSocket frame reads may need repeated read loops with clear EOF/error
  handling.

Verification:

- Package typecheck tests compile against opaque handles. Done for TCP, TLS,
  and UDP public handles.
- Local loopback HTTP/WebSocket/TCP tests pass. Done for package HTTP GET and
  WebSocket upgrade handshake over `std/net/tcp`.
- Blocking TLS operations are classified as `ImpureMayBlockThread` until fixed.

Done when:

- Higher-level net packages either benefit from fiber-aware TCP or are clearly
  isolated behind blocking-pool metadata. Done for current TCP-backed package
  clients; TLS/UDP remain explicitly blocking native-backed integrations.

### Phase 10: Performance And Fairness Tuning

Goal: improve throughput and latency after correctness is proven.

Tasks:

- Benchmark many idle connections. Initial coverage added to
  `benchmarks/blorp/tcp_virtual_threads.brp`.
- Benchmark many slow readers/writers. Initial coverage added to
  `benchmarks/blorp/tcp_virtual_threads.brp`.
- Benchmark accept throughput. Initial coverage exists through the
  accept/connect loopback cases in `benchmarks/blorp/tcp_virtual_threads.brp`.
- Benchmark connect storm behavior. Initial coverage added to
  `benchmarks/blorp/tcp_virtual_threads.brp`.
- Measure reactor wake batching. Initial scheduler counters now expose reactor
  control wakes, poll wakeups, readiness events, and waiter wakes. TCP
  diagnostic benchmarks print those counters per case.
- Suppress duplicate level-triggered readiness reports for one pending
  operation. Done by treating reactor registrations as one-shot interests and
  taking pre-park readiness after waiter installation, so readiness observed
  before the fiber yields cannot be lost.
- Add public coverage for simultaneous read/write waits on one stream. Done in
  `tests/test_blorp/sys/test_tcp_virtual_threads.brp`, which forces a large
  write and delayed read reply to park concurrently on the same client handle.
- Preserve ownership for managed task results returned through `join` and
  `concurrent` bindings. Done by carrying the task result ARC flag into the
  outer join `Result` and by using destructor-aware stack-`Result` boxing in
  generic boxing paths; leak coverage lives in
  `tests/test_blorp/concurrency/test_concurrent_managed_result_ownership.brp`,
  with boxed closure return coverage in `tests/test_blorp/types/test_stack_result.brp`.
- Replace the current broadcast wakeup for owner-specific fiber queues with
  targeted per-worker wakeups. Done for runtime fiber queues: owned fiber
  wakeups now signal the owner worker's condvar, while work items and
  timer/deadline changes still wake any waiting worker.
- Consider per-worker reactors only if one reactor thread becomes a bottleneck.
  Current decision: defer. The current benchmark counters show reactor wakeups
  and waiter resumes, but no evidence yet that the single reactor is the next
  bottleneck.
- Consider write coalescing only after write ordering semantics are explicit.
  Current decision: defer. `write` is now write-all with one active writer per
  stream; coalescing should be justified by a measured workload and must not
  weaken write-ordering semantics.

Risks:

- Optimizing too early can obscure lifecycle bugs.
- Edge-triggered backends can miss readiness if drain loops are wrong.
- Too many worker wakeups can hurt CPU-bound programs.

Verification:

- Benchmarks under `benchmarks/` with one timed run after warmup.
- Compare `BLORP_THREADS=1`, `2`, `4`, and host CPU count.
  Done on a 10-logical-CPU host for the TCP virtual-thread benchmark:
  1 thread `0.0945s`, 2 threads `0.0914s`, 4 threads `0.0953s`,
  10 threads `0.0890s`.
- Track scheduler counters alongside wall time.
- Confirm no regression in non-network concurrency tests.

Done when:

- TCP wait scalability is limited by ready work and kernel IO, not parked fiber
  count. Current closeout verification covers public TCP tests, single-worker
  execution, leak-check, sanitizer, focused runtime C reactor/waiter smoke, and
  `benchmarks/blorp/tcp_virtual_threads.brp` scheduler counters showing parked
  fibers and reactor waiter wakes across accept/connect, connect storm, idle
  connections, parked readers, and slow-reader cases.

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
