# Networking Resources Roadmap

Status: implementation roadmap after the first TCP resource checkpoint.

This document folds the current TCP resource status into a broader plan for all
networking APIs. The goal is one coherent model for network handles, protocol
sessions, servers, clients, pools, streams, cancellation, and virtual-thread
blocking behavior.

The guiding rule is:

```text
Network capabilities are scoped resources or services. Network data is ordinary
data. Repeated data is a stream. Repeated owned capabilities are a resource
source.
```

## Design Principles

- Make external capabilities explicit with `resource type` or a future
  `service` category. Do not model sockets, TLS sessions, database connections,
  or WebSocket sessions as ordinary copyable values.
- Keep resource cleanup compiler-owned. Public APIs should not expose manual
  `close` when `with` can own cleanup.
- Preserve Blorp value semantics: no shared mutable Blorp memory between
  virtual tasks.
- Let direct blocking-style code be the user model, but require operations to
  either park the current fiber or go through a bounded blocking-worker path
  before claiming virtual-thread friendliness.
- Represent ownership, cancellation points, operation result shapes, and
  resource-derived values explicitly in compiler data. Avoid name-based
  heuristics in typechecking or codegen.
- Keep source APIs ergonomic, but reject shapes that make lifetime ambiguous:
  resource storage in ordinary aggregates, detached resource capture, accidental
  concurrent capture, and escaped streams/cursors.

## Current TCP Status

The first TCP resource checkpoint has landed.

`std/net/tcp.brp` now defines scoped resource handles:

```blorp
resource type TcpListener = builtin("blorp_tcp_close_listener")
resource type TcpStream = builtin("blorp_tcp_close_stream")
```

Public TCP operations now use typed errors and scoped handles:

```blorp
listen(host: String, port: Int, backlog: Int) -> Result[TcpListener, TcpError]
accept(listener: TcpListener) -> Result[TcpStream, TcpError]
connect(host: String, port: Int) -> Result[TcpStream, TcpError]
read_chunk(stream: TcpStream, max_bytes: Int) -> Result[Bytes, TcpError]
chunks(stream: TcpStream, max_bytes: Int) -> FallibleStream[Bytes, TcpError]
lines(stream: TcpStream) -> FallibleStream[String, TcpError]
write(stream: TcpStream, data: Bytes) -> Result[Int, TcpError]
write_all(stream: TcpStream, data: Bytes) -> Result[Void, TcpError]
```

Landed behavior:

- `with listener ?= listen(...):` and `with stream ?= connect(...):` install
  cleanup through Core `CResourceScope`.
- TCP manual `close` is private; public code cannot import and call it.
- Numeric-address `accept`, `connect`, `read`, and `write` park fibers through
  the scheduler reactor instead of occupying OS workers while waiting for socket
  readiness.
- Cancellation and timeout wake parked TCP waiters.
- Resource cleanup consumes the scoped TCP handle, closes/wakes the runtime
  socket state, and releases the resource wrapper.
- The compiler rejects ordinary TCP resource parameters/returns, matching a
  resource acquisition result outside `with ?=`, detached capture, concurrent
  capture, and resource-containing storage.
- Module-qualified calls such as `Tcp.write(stream, data)` preserve
  resource-operation metadata.
- Deterministic leak coverage exists for parked TCP `accept`, `read`, and
  cancelled resource-source fan-out. Generated-C audit coverage protects owned
  `Bytes` cleanup around TCP writes and owned stack `Result` temporaries that
  remain live while later operations may park.
- `connections_stop_on_error(listener)` and
  `connections_continue_on_error(listener)` expose the first
  `ResourceSource[TcpStream, TcpError]` producers.
- Sequential `for` over TCP connection sources transfers each accepted stream
  into a scoped loop body and closes it on normal exit, `break`, `continue`, or
  cancellation.
- `for resource in source concurrently(limit: N):` now supports
  `ResourceSource[R, E]` in statement position. Core marks the item as a
  move-resource item, task closure metadata records a moved capture, emission
  moves the raw ownership slot into one child task, task entry nulls the closure
  slot, and the child immediately rebinds the item into `CResourceScope`.
- `chunks(stream, max_bytes)` exposes a scoped
  `FallibleStream[Bytes, TcpError]` over TCP reads. It treats an empty peer read
  as normal end-of-stream and maps read failures through the same generic
  fallible-stream terminal ABI used by file and UDP streams.
- `lines(stream)` builds on TCP byte chunks and yields scoped
  `FallibleStream[String, TcpError]` values with file-compatible line framing:
  trailing `\n` and optional `\r` are stripped, and a final unterminated line is
  yielded when the peer closes.

Current limitations:

- `connections_continue_on_error` now continues after typed accept timeouts.
  Broader transient policies should be added only when the runtime exposes
  stable typed error classes for those cases.
- Hostname resolution still uses blocking DNS before the nonblocking socket
  phase. Numeric hosts are the virtual-thread-friendly path.
- Portable deterministic parked-write/connect cancellation baselines remain
  open because local socket behavior can complete before the test observes a
  parked wait.
- `pkg/net/smtp.brp` and `pkg/net/websocket.brp` no longer contain old TCP
  ownership patterns. SMTP has scoped plain-TCP and guarded STARTTLS paths.
  WebSocket frame/handshake helpers remain in the package, while
  `std/net/websocket` now owns the scoped session resource surface and native
  `ws://` runtime backend. Package WebSocket connection validation now matches
  the std URL-shape rules before reporting the scoped-resource migration error.

## General Network Ownership Categories

### Resources

Use `resource type` for capabilities with a single cleanup owner:

- TCP listener and stream.
- TLS session.
- UDP socket.
- WebSocket connection.
- HTTP server listener.
- HTTP client connection when it is not pooled.
- Database connection, transaction, statement, query cursor.
- File-system watcher or event subscription.

Resource APIs should be acquired with `with`:

```blorp
with stream ?= tcp.connect(host, port):
	data ?= stream.read_chunk(4096)
	Ok(data.length())
```

Ordinary user functions cannot accept or return resources until the language has
a precise user-visible borrowed-resource model. Prefer compiler-owned resource
operations, callbacks, resource-source iteration, or returning ordinary data.

### Services

Use a service-like category for intentionally shared runtime objects that own
internal synchronization:

- Database pools.
- HTTP client pools.
- DNS resolver pools.
- Game session registries.
- Metrics/logging sinks.

Services are not ordinary shared mutable Blorp data. They are external runtime
objects with an explicit concurrency contract. A service may produce scoped
resources, such as a database connection checkout:

```blorp
with pool ?= db.pool(url, max_connections: 32):
	for job in jobs concurrently(limit: 128):
		_ = pool.checkout()
			.with_resource(func(conn):
				process_job(conn, job)
			)
```

### Ordinary Data

Network payloads are ordinary values:

- `Bytes`
- datagrams
- DNS answers
- HTTP request/response structs
- WebSocket frames
- decoded protocol messages
- database rows after copying out of a cursor

Ordinary data can move through channels, lists, dicts, and concurrent tasks.

### Fallible Streams

Use `FallibleStream[T, E]` for repeated ordinary data that can fail:

- TCP byte chunks.
- TCP lines.
- TLS byte chunks.
- UDP datagrams from one socket.
- WebSocket frames.
- HTTP response body chunks.
- database rows when rows are copied ordinary values.
- file-system events.

Streams remain scoped-derived values. They cannot escape the resource owner.
The runtime terminal-operation ABI is now protocol-neutral: fallible stream
pulls report an explicit error domain plus kind/detail, and codegen maps that
domain into the `E` in `FallibleStream[T, E]`. File streams, UDP datagram
streams, TCP byte-chunk streams, TCP line streams, and TLS byte-chunk streams
now share this terminal ABI; future database streams should add domains rather
than cloning file-specific terminal builtins.

### Resource Sources

Use `ResourceSource[R, E]` for repeated owned resources:

- accepted TCP connections;
- database pool checkouts, if represented as an iteration source;
- accepted TLS sessions layered on a TCP listener;
- file or directory walkers that open handles one at a time;
- worker-owned game/client sessions when each child task owns a session
  resource.

`ResourceSource` values are not collections. They cannot be stored in ordinary
aggregates, hidden inside `Option`, captured by closures, sent through channels,
or returned from ordinary user functions.

## Target API Sketches

### TCP Server

```blorp
import:
	net/http as HTTP: Request, Response
	net/tcp as TCP: TcpError

pure func route(req: Request) -> Response:
	HTTP.ok_text("handled " + req.path)

func serve() -> Result[Void, TcpError]:
	with listener ?= TCP.listen("", 8080, 1024):
		ignored ?= TCP.set_timeout(listener, 1000)
		for conn in TCP.connections_continue_on_error(listener) concurrently(limit: 4096):
			match TCP.read_chunk(conn, 8192):
				Ok(raw):
					response: Response = match HTTP.parse_request(raw):
						Ok(req): route(req)
						Err(msg): HTTP.error_response(400, msg)
					match TCP.write_all(conn, HTTP.format_response(response)):
						Ok(_): void
						Err(_): void
				Err(_): void
		Ok(void)
```

This is the currently supported webserver shape. Each accepted `TcpStream` is
moved into exactly one child task, and cleanup runs when that task exits or is
cancelled. User-defined handler functions should accept ordinary HTTP
`Request` values and return ordinary `Response` values; they should not accept
`TcpStream` resources. That keeps resource ownership in compiler-visible
operations while application routing stays easy to factor and test.

### TCP Client Streaming

```blorp
func download(host: String, port: Int) -> Result[Int, TcpError]:
	with stream ?= tcp.connect(host, port):
		stream
			.chunks(16 * 1024)
			.fold_result(0, func(total, chunk): Ok(total + chunk.length()))
```

This requires TCP chunk adapters over a scoped stream.

### TLS

```blorp
with tcp_stream ?= tcp.connect(host, 443):
	with tls ?= tls.connect(tcp_stream, host):
		_ ?= tls.write_all(request)
		tls.chunks(16 * 1024).collect_result()
```

Decision for the first implementation: `TlsSession` is a dependent resource
created inside an existing `TcpStream` scope. It does not consume the TCP stream
yet, because the compiler does not currently have a general resource-to-resource
move/consume model. Instead, the nested scopes make cleanup order explicit: TLS
native state is closed first, then the TCP stream closes. The TLS runtime
finalizer must not close the underlying TCP fd directly.

Target shape:

```blorp
resource type TlsSession = builtin("blorp_tls_close_session")

union TlsError:
	InvalidInput(String)
	HandshakeFailed(String)
	Transport(String)
	Certificate(String)
	Protocol(String)
	TimedOut(String)
	Closed(String)
	Busy(String)
	Unsupported(String)
	Other(String)

func connect(stream: TcpStream, server_name: String) -> Result[TlsSession, TlsError]
func read_chunk(session: TlsSession, max_bytes: Int) -> Result[Bytes, TlsError]
func chunks(session: TlsSession, max_bytes: Int) -> FallibleStream[Bytes, TlsError]
func write(session: TlsSession, data: Bytes) -> Result[Int, TlsError]
func write_all(session: TlsSession, data: Bytes) -> Result[Void, TlsError]
```

Current status: the `std/net/tls` resource surface has landed with typed
unsupported runtime stubs. Public TLS operations that take `TlsSession` or
`TcpStream` are compiler-owned resource operations with explicit metadata;
ordinary user functions still cannot accept resources. The session remains
nested under its parent TCP scope. While a dependent `TlsSession` is live, the
compiler now makes the parent `TcpStream` unavailable inside that nested scope;
code must use the TLS session until the TLS `with` block closes. This prevents
raw TCP reads/writes from interleaving with TLS protocol state. Independently
owned resource results remain distinct: `Tcp.accept(listener)` produces an
owned `TcpStream` and does not make the listener unavailable. `chunks(session,
max_bytes)` now reuses the generic fallible-stream terminal ABI with an
explicit TLS error domain, so terminal operations return `Result[...,
TlsError]`.

Durable compiler coverage now pins the generated-C shape for
`TLS.chunks(session, max_bytes).collect_result()`: the std wrapper calls
`blorp_tls_chunks_raw`, terminal operations use
`blorp_fallible_stream_collect_raw`, and the terminal bridge maps
`BLORP_FALLIBLE_STREAM_ERROR_DOMAIN_TLS` into `std_net_tls__TlsError`.

Nested TLS acquisition can now map acquisition errors at the `with ?=`
boundary:

```blorp
with stream ?= tcp.connect(host, 443) on err => Transport(tcp.message(err)):
	with session ?= tls.connect(stream, host):
		...
```

A normal `Result.map_err` call is still intentionally invalid on
`Result[TcpStream, TcpError]` or `Result[TlsSession, TlsError]` because that
would pass a resource-containing carrier through an ordinary function parameter
before `with` installs cleanup.

`Transport` carries a string detail in this first bridge because the generic
operation-result metadata currently maps runtime errors to single-constructor
string payloads. If HTTP/WebSocket need nested `TcpError` transport causes, add
that as an explicit operation-result payload shape instead of special-casing
TLS in codegen.

Later, if HTTP/WebSocket need transport ownership transfer for cleaner APIs,
add a real resource-consume IR operation rather than faking ownership with
cleanup flags.

### UDP

```blorp
with sock ?= udp.bind("", 9000):
	for packet in sock.datagrams() concurrently(limit: 512):
		handle_packet(packet)
```

UDP sockets are resources; datagrams are ordinary values. Concurrent datagram
handling is safe because each packet is copied ordinary data. Concurrent writes
on the same UDP socket are explicit: `send_to` is one-shot nonblocking, while
`send_to_wait` parks the current virtual thread and rejects overlapping parked
sends as `Busy` rather than sharing socket write state implicitly. Numeric
variants `bind_numeric`, `send_to_numeric`, and `send_to_wait_numeric` reject
hostnames before resolver APIs are reached, matching TCP's enforceable no-DNS
path for virtual-thread-friendly setup and sends. Higher-level protocols that
need sustained fan-in should still use a service-like send queue.

### DNS

DNS is not automatically virtual-thread-friendly while it calls blocking
resolver APIs. Either implement nonblocking DNS or route lookup through a
bounded worker service with explicit cancellation behavior.

```blorp
answer ?= dns.resolve("example.com")
Ok(answer)
```

Current TCP status: `std/net/tcp` now has a typed endpoint surface:
`IpFamily`, `IpAddress`, `DnsName`, `InterfaceScope`, and `Port`.
Applications can construct `Port` values only through validation, so concrete
ports are 1 through 65535 and ephemeral listener binds use explicit
`listen_*_any_port` APIs instead of magic port 0. Numeric addresses and DNS
names are separated at the type level: use `ipv4(...)`/`parse_ip(...)` for
numeric endpoints and `dns_name(...)` for name resolution. Listener helpers now
distinguish loopback, any-interface, validated IP, and scoped IPv6-IP binds.
Connection helpers distinguish loopback, validated IP, scoped IPv6-IP, and DNS
name connects. The older raw `listen`/`connect` and `listen_numeric`/
`connect_numeric` forms remain available as compatibility surfaces while
tests/docs migrate, but they should not be treated as the preferred API for new
code. Once a socket exists, readiness waits still park the current virtual
thread through the reactor.

Open ergonomic gap: many user inputs are generic host strings that may be DNS
names, IPv4 literals, IPv6 literals, or scoped IPv6 literals. The current typed
surface can represent each case, but callers must branch before choosing
`connect_ip`, `connect_scoped_ip`, or `connect_name`. A future `Host` endpoint
type or compiler-owned `connect_host` bridge could make that common case
concise without collapsing validated names and numeric addresses back into raw
strings.

Current `std/net/dns` status: the first compiler-owned `resolve(hostname)`
operation has landed. It returns `Result[List[String], DnsError]` with copied
ordinary address strings and no resolver handle. The raw runtime operation now
uses the same typed operation-result manifest as TCP, UDP, TLS, WebSocket, and
file operations, including an exact `List[String]` success-payload shape, so
the std wrapper no longer classifies stringly runtime errors. The runtime
backend currently uses the platform blocking resolver directly, so it is
documented as blocking and marked impure but not as a cancellation point. This
keeps resolver state out of ordinary Blorp values while preserving a stable
surface for a future bounded resolver service. Current `pkg/net/dns` still wraps
the same platform resolver through a DNS-only FFI header for package
compatibility; its raw string-returning FFI helper remains private so callers
cannot bypass the typed wrapper.

Near-term decision: do not model a configurable resolver as an ordinary
resource yet. A resource resolver would be hard to use in concurrent loops
because scoped resources cannot be captured by child tasks, and allowing that
would weaken the resource model. Until Blorp has an explicit service category,
the safer std shape is the compiler-owned resolver operation that now exists,
with a later backend swap to a bounded runtime resolver pool:

```blorp
dns.resolve(hostname: String) -> Result[List[String], DnsError]
dns.resolve_with(hostname: String, options: ResolveOptions) -> Result[List[String], DnsError]
```

`resolve` is impure today because it consults the host environment. Once the
runtime pool lands, resolver waits should become cancellation-point aware and
the pool should own all shared mutable resolver state. Blorp code should still
only see ordinary copied address data. Later, a first-class `service type
Resolver` can add explicit pool sizing and observability without relaxing
scoped-resource capture rules.

### HTTP Client

```blorp
with client ?= http.client(max_connections: 64):
	responses: Channel[HttpResult] = channel(1024)
	for url in urls concurrently(limit: 256):
		_ = responses.send(client.get(url))
	responses.seal()
```

The client should be a service/pool, not a resource captured accidentally by
tasks. The service type must opt into shared concurrent use and own its internal
connection resources.

### WebSocket

```blorp
with socket ?= websocket.connect(url):
	for message in socket.messages():
		handle_message(message)
```

The package module intentionally exposes only ordinary frame and handshake
helpers. Scoped connection ownership has moved to `std/net/websocket`, where
the session resource surface and native `ws://` runtime backend now exist.
`wss://` is layered through the TLS resource backend and reports typed
`Unsupported` when native TLS is not available. That keeps the important
ownership invariant in place: a WebSocket connection cannot be represented as a
copyable package record while protocol work continues.

Current and target shape:

```blorp
resource type WebSocketSession = builtin("blorp_websocket_close_session")

union Message:
	Text(String)
	Binary(Bytes)
	Close(Int, String)
	Ping(Bytes)
	Pong(Bytes)

union WebSocketError:
	InvalidUrl(String)
	HandshakeFailed(String)
	Transport(String)
	Tls(String)
	Protocol(String)
	TimedOut(String)
	Closed(String)
	Busy(String)
	Unsupported(String)
	Other(String)

func native_available() -> Bool
func connect(url: String) -> Result[WebSocketSession, WebSocketError]
func receive(session: WebSocketSession) -> Result[Message, WebSocketError]
func messages(session: WebSocketSession) -> FallibleStream[Message, WebSocketError]
func send_text(session: WebSocketSession, text: String) -> Result[Void, WebSocketError]
func send_binary(session: WebSocketSession, bytes: Bytes) -> Result[Void, WebSocketError]
func send_ping(session: WebSocketSession, bytes: Bytes) -> Result[Void, WebSocketError]
func send_pong(session: WebSocketSession, bytes: Bytes) -> Result[Void, WebSocketError]
func send_close(session: WebSocketSession, code: Int, reason: String) -> Result[Void, WebSocketError]
```

The first implementation should prefer one session resource with an explicit
one-reader/one-writer runtime policy. Reads are exposed as ordinary `Message`
values and `FallibleStream[Message, WebSocketError]`; writes are explicit
operations that may park. If overlapping same-direction operations occur,
return `Busy` rather than allowing implicit shared socket state. Split
reader/writer resources should wait until TLS and TCP role needs are clear
enough to justify a general role-resource design.

Important constraint: a scoped `WebSocketSession` cannot be captured by a
`concurrent:` child task under the current resource rules. That is correct.
The first valid shape is a same-task session loop. A truly bidirectional
read/write session should use one of these explicitly-designed shapes, not an
accidental resource capture:

- split `WebSocketReader` and `WebSocketWriter` resources moved into exactly one
  task each;
- a compiler-owned session driver that owns the resource and exposes ordinary
  message channels;
- a future service category for intentionally shared protocol actors.

### Database Connectors

```blorp
with pool ?= db.pool(url, max_connections: 32):
	for event in events concurrently(limit: 128):
		_ = pool.checkout()
			.with_resource(func(conn):
				conn.execute(event.to_sql())
			)
```

Connections, transactions, statements, and cursors should be resources.
Connection pools should be services. Rows should be ordinary values once copied
out of the cursor.

### Event Systems And Games

```blorp
with server ?= game.listen("", 7777):
	for session in server.sessions() concurrently(limit: 10000):
		run_session(session)
```

MMORPG-style sessions should be resources or services depending on ownership.
Per-client network sessions are resources; global world state should not be a
shared mutable Blorp object. Use channels, service messages, or future
explicitly-designed CRDT/state primitives.

## Compiler And Runtime Foundations

### Generalize Operation Metadata

Current TCP typed-result bridging has TCP-specific emitter logic. Before
copying the pattern to UDP, TLS, HTTP, DNS, or database packages, introduce a
general operation-result description:

```text
operation builtin:
  result carrier: Result[Success, Error]
  runtime result struct/layout
  success payload kind
  error classification mapping
  ownership of each argument
  wait behavior: does not wait, parks a fiber, or blocks an OS worker
```

This has landed for TCP, TLS, UDP, WebSocket, and typed file resource runtime
operations, including file opens and read/write/count calls. The manifest
records result carrier shape, payload ownership, resource-result policy,
explicit error mapping, argument ownership, layout policy, and wait behavior.
`ParksFiber` operations derive cancellation-point metadata, while
`BlocksOsWorker` operations derive OS-worker-blocking metadata without
pretending to be fiber-cancellable. Unit coverage compares the table against
`runtime_decl.c`, pins both fiber-parking and OS-worker-blocking
classifications, and checks that raw operation-result builtins derive their
impure, cancellation-point, OS-worker-blocking, and Core ownership contracts
from the manifest instead of second hand-maintained name lists. File resource
opens are explicitly marked boxed-result-only in that manifest, so a future
stack-resource acquisition ABI must be represented before codegen can emit it.

Fallible stream source constructors now share the same metadata direction. File,
TCP, TLS, and UDP stream-producing raw builtins are registered in a single
manifest with their raw C symbol, error domain, and argument ownership shape.
Builtin impurity metadata and Core ownership contracts are derived from that
manifest, so adding another fallible source no longer requires parallel edits in
the effect table and Perceus/codegen ownership table.

Fallible stream terminal operations now use the same metadata family. The
terminal manifest records each raw terminal builtin's runtime result struct,
success payload shape, argument ownership, and any `void*` ABI argument
positions. Core emission uses the manifest instead of a local name switch, and
the Core ownership table derives terminal contracts from it.

### Preserve Resource Operation Metadata

The compiler already needs to know when a builtin resource operation returns
ordinary data via `@resource_result_ordinary`. Extend this pattern without
falling back to function-name guesses. Module-qualified operations must preserve
the same metadata as selectively imported operations.

Current implementation note: resource-result policy is explicit in compiler
metadata as ordinary, dependent, or independently owned. TLS connect remains
dependent on the parent stream; TCP accept is marked as independently owned so
accepted streams do not unnecessarily lock the listener that produced them.
Named record/union declarations also carry an explicit resource-storage fact in
the environment. Later inference checks combine that declaration fact with
concrete type arguments instead of reopening aggregate bodies repeatedly. This
keeps resource-carrier rejection cheap while preserving the invariant that
ordinary values cannot hide resource ownership.

The canonical names for `Stream`, `FallibleStream`, and `ResourceSource` now
live in one compiler metadata module. Inference, typecheck, Core lowering,
Core invariants, layout, and C type emission ask that shared module instead of
carrying local string lists for qualified and mangled `std/stream` names.

Operation-result metadata also exposes the cross-product needed for future
resource-producing `select`: a runtime operation either does not suspend, parks
a fiber while returning ordinary data, parks a fiber while returning a resource
with an explicit independent/dependent ownership policy, or blocks an OS worker.
This keeps future select lowering from reconstructing ownership and scheduler
facts from unrelated builtin names or source-level `Result` shapes.

### Make Concurrent Resource-Source Moves Explicit

Sequential resource-source iteration can transfer one resource into a scoped
loop body. Concurrent iteration needs an explicit IR state:

```text
source next -> owned resource item -> child task owns resource scope
```

The parent must not own cleanup after transfer. The child must install cleanup
before any cancellation point. If child spawn fails, the parent must close the
resource item.

The same rule applies to ordinary owned values inside the child. Stack
`Result` values are not heap pointers, but a successful network read can leave
their owned payload live across a later cancellation point. Emission now
registers those stack-result temporaries by slot address so cancellation drains
their payloads through the same task-local cleanup stack as resources and
ordinary ARC pointers.

The channel boundary has the same ownership shape for stack `Result` payloads.
When a `Result` is boxed into a retaining channel send, the temporary box gets a
cleanup frame and a normal post-call release. When a selected or iterated channel
value is received, the generated code consumes the boxed stack result with the
runtime stack-result bridge instead of copying the struct and leaking the box.

### Keep Cancellation Points Auditable

Blocking operations that may park must be marked in builtin metadata. This is
already true for core channel operations, sleep/yield, and runtime networking
result bridges. Raw result-returning networking builtins now get that metadata
from the operation-result manifest's `wait_behavior` field. `ParksFiber`
operations become cancellation points; `BlocksOsWorker` operations become
`Os_worker_blocking` builtins, not cancellation points. The current DNS resolver
is explicitly classified as `BlocksOsWorker` until it moves behind a bounded
resolver service or true nonblocking backend. Future DNS worker waits, HTTP pool
waits, and database pool checkouts should extend the manifest instead of adding
ad hoc name sets. Stream-producing wrappers that do not return an
operation-result carrier now get impurity and ownership metadata from the
fallible-stream source
manifest. Fallible-stream terminals carry their own `wait_behavior` metadata
and are marked as cancellation points, matching the runtime terminal loops that
check cancellation and may park while pulling from TCP, TLS, UDP, or future
I/O-backed sources. Cancellation-point metadata still belongs on the terminal
operation that actually pulls from the source, not on the constructor that
creates the cursor.

### Clarify One-Waiter Policies

TCP currently supports one parked waiter per handle and operation kind. That is
a documented policy boundary. Other networking resources should explicitly
choose:

- one reader plus one writer;
- many independent waiters;
- service-owned serialization;
- compile-time rejection of overlapping waits.

The choice belongs in the resource/service contract, not in accidental runtime
behavior.

## Migration Phases

### Phase 0: Documentation And Inventory

Status: in progress. The stale `docs/GUIDE.md` TCP section has been updated to
describe scoped TCP resources, sequential resource-source iteration, and the
remaining concurrent fan-out limitation.

Goals:

- Inventory all `pkg/net` and examples that store TCP streams, accept TCP
  streams as ordinary parameters, or call manual TCP close.
- Add a short compatibility note that `pkg/net` is currently behind the scoped
  TCP API and should not be treated as the target design.

Current inventory:

- `pkg/net/http_client.brp`: TCP side migrated to scoped stream acquisition
  and ordinary `Bytes` response parsing. HTTPS now imports `std/net/tls`,
  checks `TLS.native_available()` before opening a transport, and otherwise
  returns an explicit TLS resource-gap error without going through the old
  package TLS pointer path.
- `pkg/net/smtp.brp`: plain TCP path migrated to scoped TCP acquisition. The
  module no longer stores `TcpStream` in ordinary values or calls manual
  `TCP.close`. STARTTLS now imports `std/net/tls`, checks
  `TLS.native_available()` before opening a transport, and uses a typed scoped
  TCP -> TLS session path when a native TLS backend profile is available.
- `pkg/net/websocket.brp`: old handle-owning client API removed. The module now
  typechecks as ordinary frame/handshake helpers with a typed migration error.
  Scoped session ownership has moved to `std/net/websocket`, whose first
  resource surface exposes connection acquisition, explicit reads/writes, and
  a native `ws://` runtime backend. The package helper now mirrors the std
  boundary for URL shape: scheme, authority host, optional port, fragments,
  user-info, and raw control/space bytes are validated before returning the
  migration error, so generic HTTP URLs and malformed WebSocket authorities are
  not treated as valid connection requests.
- `benchmarks/blorp/tcp_virtual_threads.brp`: migrated to scoped listeners,
  scoped client streams, TCP connection sources, and channel aggregation. It is
  again usable as the current TCP virtual-thread benchmark.
- `std/net/tls.brp`: first dependent scoped `TlsSession` surface has landed over
  `TcpStream`, with typed unsupported runtime stubs and compiler metadata.
- `pkg/net/tls.brp`: raw pointer/manual-close helpers have been removed. The
  package still reports an explicit scoped-resource gap instead of exposing
  copyable native session pointers.
- `pkg/net/udp.brp`: raw file-descriptor helpers have been removed. The package
  now reports an explicit scoped-resource gap instead of exposing copyable
  socket handles. The old raw UDP FFI header has also been removed, so no
  package-native escape hatch can recreate the descriptor API. The first real
  UDP resource now lives in `std/net/udp` with scoped socket acquisition,
  `bind`, `send_to`, and `local_port`.
- `std/net/dns.brp`: exposes the compiler-owned `resolve` operation with typed
  `DnsError` values and ordinary copied address data. Its raw builtin is now
  bridged through typed operation-result metadata rather than a boxed
  `Result[..., String]` shim. The compiler metadata records this implementation
  as blocking an OS worker, not parking a fiber, so the remaining scheduler
  limitation is explicit. `pkg/net/dns.brp` still uses the platform blocking
  resolver through a DNS-only FFI header for package compatibility; its raw FFI
  function is private.
- TLS and UDP expose a package-boundary design constraint: compiler-owned
  resource finalizers are currently std-owned only, so these migrations require
  either moving core resources into `std/net` plus runtime support, as UDP now
  does, or adding an audited package-resource mechanism.

Exit criteria:

- `docs/GUIDE.md`, `docs/STREAMING_RESOURCES_ROADMAP.md`, and this roadmap
  agree on TCP status.
- Every known package migration has a named tracking item.

### Phase 1: General Networking Operation Metadata

Status: landed for current resources. `compiler/lib/operation_result_metadata.ml`
contains the runtime-result bridge table for TCP, TLS, UDP, WebSocket, DNS, and
typed file open/read/write/count operations. Codegen consumes that table instead
of carrying inline subsystem-specific operation switches, and unit coverage pins
the current entries, error mappings, wait behavior, layout policies, and
argument ownership. The same manifest now feeds builtin effect metadata and Core
ownership contracts for operation-result bridges, fallible-stream sources, and
fallible-stream terminals, so result bridge declarations, error tags,
cancellation points, blocking platform calls, and ownership drift in one visible
place instead of surfacing later as generated-C or ARC failures.

Goals:

- Replace TCP-specific typed bridge assumptions with reusable operation-result
  metadata.
- Include cancellation-point, argument ownership, result shape, and error
  classification data in one compiler-owned source of truth.
- Add unit tests that fail when runtime declarations and compiler metadata drift.

Exit criteria:

- Adding UDP/TLS typed resource operations does not require another bespoke
  emitter branch.
- File resource-open results move through this manifest with an explicit
  boxed-result-only layout policy. A future stack-resource acquisition ABI must
  add a new explicit policy rather than falling through the generic stack result
  path by accident.

### Phase 2: Concurrent Resource-Source Iteration

Status: landed for TCP connection sources. TCP connection sources compile and run with
`for conn in Tcp.connections_stop_on_error(listener) concurrently(limit: N):`.
The compiler now has explicit move-resource item metadata in Core and task
closure emission, with typecheck, codegen-audit, unit, and TCP runtime coverage.

Goals:

- Extend `for resource in source concurrently(limit: N):` beyond TCP as more
  `ResourceSource[R, E]` producers land.
- Keep each resource item moved into exactly one child task.
- Keep child cleanup installed before the child can park.
- Close the item if task spawn/batch setup fails.
- Reject result collection for resource-source fan-out unless a helper has an
  explicit ownership story.

Tests:

- Typecheck: source cannot be captured, copied, stored, or returned.
- Codegen audit: child task has cleanup for transferred resource.
- Runtime: accepted TCP streams close on normal exit and source timeout.
- Leak-check: cancelled child task closes its accepted stream. Landed in
  `tcp_concurrent_source_cancelled_stream.brp`, which cancels the parent only
  after it parks joining a child that owns an accepted stream.

Exit criteria:

- The target TCP server sketch compiles and runs.
- Deterministic cancelled-child leak coverage exists for a moved resource item.
  Landed for TCP connection sources.

### Phase 3: Finish TCP Surface

Goals:

- Finalize broader `connections_continue_on_error` transient-error behavior
  beyond accept timeouts if runtime error classes justify it.
- TCP `chunks(stream, max_bytes)` and `lines(stream)` now exist on the generic
  fallible-stream terminal ABI.
- Add deterministic cancellation coverage for TCP connect and write if a
  portable parked-state harness can be made reliable.
- Keep hostname DNS limitation visible in docs and error messages.
- Defer split reader/writer TCP roles until TLS and WebSocket can share one
  broader role-resource design. Do not add TCP-only roles that protocols would
  later have to fork or emulate.

Exit criteria:

- TCP examples, benchmarks, and runtime tests use scoped resources and no public
  manual close.

### Phase 4: Migrate Package Networking Off Old TCP Shapes

Status: TCP-owning package shapes removed. `http_client` and `smtp` have
scoped plain-TCP paths plus guarded `std/net/tls` paths for HTTPS and STARTTLS;
`websocket` no longer exposes a copyable connection handle. Remaining work in
this phase is richer native-profile behavior and protocol coverage on top of
the scoped resource surfaces.

Targets:

- `pkg/net/http_client.brp` TCP path is migrated, and HTTPS now targets the
  scoped `std/net/tls` surface behind `TLS.native_available()`.
- `pkg/net/smtp.brp` plain TCP path is migrated, and STARTTLS now targets the
  scoped `std/net/tls` surface behind `TLS.native_available()`.
- `pkg/net/websocket.brp` old TCP-owning client API is removed; keep it in this
  phase for ordinary frame/handshake helpers only. Its placeholder `connect`
  now returns typed `WebSocketError` values that point callers at the std
  resource surface.

Goals:

- Remove manual `TCP.close` calls.
- Stop storing `TCP.TcpStream` in ordinary unions/records.
- Convert helpers that accept streams into resource operations, scoped
  callbacks, or methods that return ordinary data.
- Keep HTTPS and STARTTLS explicit about their native-runtime gaps. TLS now has
  an OpenSSL native profile; WebSocket protocol implementation lives behind the
  std scoped resource surface for native `ws://`, with `wss://` gated on TLS
  availability.

Exit criteria:

- Package TCP call sites compile against the resource TCP API without special
  exemptions.

Current notes:

- The package import test now covers `pkg/net/http_client`, `pkg/net/smtp`,
  `pkg/net/tls`, `pkg/net/udp`, and `pkg/net/websocket`.
- Runtime coverage now pins ordinary package helper behavior for WebSocket
  masking/handshake helpers, WebSocket's package migration error, explicit
  native capability query, and invalid-URL errors. The package helper mirrors
  the std WebSocket URL-shape boundary before reporting its scoped-resource
  migration error. Runtime coverage also pins std DNS's typed
  lookup/invalid-host behavior, package DNS's typed lookup error messages,
  SMTP's explicit STARTTLS resource-gap error, HTTP's explicit HTTPS/TLS
  resource-gap error, and the TLS/UDP placeholder error surfaces.
- `examples/pkg_network.brp` imports WebSocket only for ordinary frame helpers,
  not for a connection-owning API.
- Protocol packages with many read/write helpers expose a real ergonomics gap:
  without a borrowed-resource parameter model or scoped callback helper, the
  resource-safe implementation must keep repeated stream operations inside one
  `with` body. That is correct, but not the long-term ergonomic target.

### Phase 5: TLS Resources

Status: first std resource surface landed. `std/net/tls.brp` defines
`TlsSession`, `TlsError`, `connect`, `read_chunk`/`read`, `write`, and
`write_all` as compiler-owned resource operations over scoped `TcpStream`.
`chunks(session, max_bytes)` shares the generic fallible-stream terminal ABI
with TCP/file/UDP streams, and `native_available()` exposes whether the active
runtime profile is a real native TLS implementation. The portable default
profile still returns typed `Unsupported`; the opt-in OpenSSL profile now
performs nonblocking native handshakes, reads, and writes through the same TCP
reactor path as plain TCP. The old package surface no longer exposes opaque
`Ptr` sessions, blocking read/write calls, or manual close. HTTPS and SMTP
STARTTLS now target `std/net/tls` but short-circuit on
`native_available() == False` so portable unsupported builds remain
deterministic and network-free.

Native backend decision:

- Keep `std/net/tls` always available at the Blorp API level. Programs should
  not need package FFI or manual close to typecheck TLS code.
- Keep the default portable runtime as typed `Unsupported` until a native TLS
  backend is explicitly enabled by the build/runtime profile. The current
  runtime compile path uses fixed baseline linker flags (`-lm`, `-lpthread`);
  silently requiring OpenSSL, SecureTransport, or platform frameworks for every
  program would make ordinary builds less portable.
- Native backends must be nonblocking over the existing scoped `TcpStream` fd
  or explicitly routed through a bounded worker service with cancellation
  semantics. The first native backend is the OpenSSL profile; it keeps the fd
  nonblocking and maps `SSL_ERROR_WANT_READ`/`SSL_ERROR_WANT_WRITE` onto the
  runtime reactor instead of occupying an OS scheduler thread.
- Keep the backend-neutral runtime boundary:
  `tls_backend_new`, `tls_backend_handshake_step`, `tls_backend_read_step`,
  `tls_backend_write_step`, `tls_backend_close`, and
  `tls_backend_error_detail`. Runtime state owns backend internals; Blorp code
  only sees copied `Bytes`, `Int`, `Void`, and `TlsError`.
- Represent runtime session state explicitly, not as coupled booleans. The
  minimum state machine is `Handshaking`, `Open`, `Closing`, `Closed`, and
  `Failed`. Operations on the wrong state return typed `Closed`, `Busy`,
  `Protocol`, or `Other` rather than exposing partial handles.
- Keep cleanup ownership nested: `TlsSession` frees TLS-native state first and
  does not close the parent TCP fd. The enclosing `TcpStream` resource remains
  responsible for the socket. The compiler now enforces the protocol half of
  that nesting by making the parent stream unavailable while the dependent
  session scope is active.
- Same-session overlapping operations should be impossible from normal Blorp
  code because scoped resources cannot be captured by concurrent tasks. The
  runtime should still guard backend state and return `Busy` if an internal or
  future role-resource path tries to enter the same session concurrently.

Implementation sequence:

1. Add the native backend abstraction with an always-unsupported implementation
   selected by default. Keep the public runtime ABI unchanged. Landed at the
   current boundary level: public TLS operations now route through explicit
   backend operation tables and an explicit `TlsSession` state model. The
   default unsupported backend implements the same connect/read/write/write_all
   and close hooks that native backends fill in. Dispatch now goes
   through one active-backend selector and validates table completeness before
   I/O, so an incomplete internal backend reports a typed `Other` error instead
   of jumping through a null operation pointer. Resource cleanup now transitions
   sessions through `Closing` while the backend close hook runs, then marks them
   `Closed`. TLS read/write/write_all operations also install an atomic
   same-session operation guard and return typed `Busy` for overlap, with a
   cancellation cleanup frame so native cancellation cannot leave the
   session stuck busy. Backend I/O now routes through explicit
   `handshake_step`, `read_step`, and `write_step` hooks; public connect now
   consumes the provisional backend session through a handshake driver before
   exposing it, while public read/write helpers adapt backend steps to today's
   `Result` surface. Failed, cancelled, or not-ready handshakes release the
   provisional session instead of exposing a partially initialized handle.
   Backend `WantRead`/`WantWrite` results now go through the same TCP reactor
   wait machinery as ordinary `TcpStream` reads and writes, so a native backend
   can park the current virtual thread on the underlying stream rather than
   blocking an OS scheduler thread or returning a spurious user-visible `Busy`.
2. Add deterministic runtime coverage for state transitions that do not require
   a real TLS server: invalid input, closed session, oversized reads, and
   unsupported backend mapping. Landed so far: invalid server names and the
   default unsupported backend are covered through real scoped TCP streams, and
   `std/test.tls_state_probe_for_test` now exercises closed, closing,
   handshaking, failed, open, invalid read/write, incomplete backend dispatch,
   backend cleanup transition, overlapping-operation `Busy`, and TLS
   chunk-stream terminal mappings through internal runtime sessions. It also
   checks successful synthetic connect-plus-handshake, read, write, write_all,
   and reactor-backed `WantRead`/`WantWrite` continuations. The probe returns
   only `Bool`, so it does not expose fake resource handles to user code.
   TLS cancellation-point metadata is also pinned by unit coverage, and the
   codegen audit suite now verifies that owned `Bytes` locals passed to TLS
   writes are protected by task-local cancellation cleanup while the write may
   park.
3. Add an opt-in native backend build path. Landed as a structured runtime TLS
   backend profile: `BLORP_TLS_BACKEND=unsupported` is the portable default,
   while `BLORP_TLS_BACKEND=openssl` selects the OpenSSL backend, compile
   define, runtime-cache key, manifest entry, include flags, and link flags.
   OpenSSL arguments come from `BLORP_OPENSSL_CFLAGS`/`BLORP_OPENSSL_LIBS` when
   set, otherwise `pkg-config`. Default builds remain portable and do not
   require native TLS libraries. The backend table carries an explicit
   capability mask for native connect, handshake, read, and write progression,
   so high-level packages can distinguish an unsupported profile from a usable
   native implementation without guessing from the profile name.
4. Implement nonblocking handshake/read/write loops on top of the existing TCP
   fd readiness machinery. Landed for synthetic backends and the OpenSSL
   profile. The OpenSSL backend keeps the socket nonblocking, maps
   `SSL_ERROR_WANT_READ`/`SSL_ERROR_WANT_WRITE` to the runtime reactor, verifies
   hostnames through OpenSSL's verification parameters, and reports typed
   certificate, protocol, transport, timeout, closed, busy, invalid-input, and
   unsupported errors through the existing `TlsError` surface. Owned input bytes
   are still registered across every cancellation point by the generated
   operation-result bridge, as with channel sends and stream terminal callbacks.
5. Migrate HTTPS, SMTP STARTTLS, and WebSocket connection paths from package
   placeholders onto std resource surfaces. HTTPS and SMTP STARTTLS slices have
   landed: `pkg/net/http_client` and `pkg/net/smtp` import `std/net/tls` and
   have scoped `TcpStream` -> `TlsSession` paths guarded by
   `native_available()`, so portable unsupported behavior does not open the
   network. WebSocket now has a `std/net/websocket` scoped session surface and a
   runtime backend for native `ws://` TCP sessions. `wss://` uses the same
   transport-owner path through `TlsSession` when native TLS is available and
   otherwise returns typed `Unsupported` before opening a socket.
   `WebSocket.native_available()` is now an explicit capability query for the
   WebSocket protocol backend, and `connect` validates `ws://`/`wss://` scheme,
   authority host, optional port, fragments, raw control/space bytes, and
   user-info ambiguity before reaching transport acquisition.

Goals:

- Replace `Ptr` TLS sessions with `resource type TlsSession`. Landed in
  `std/net/tls`.
- Add a backend capability query. Landed as `TLS.native_available()`, backed by
  an explicit runtime operation-table capability set rather than inferred from
  the selected profile name. The runtime probe now covers both negative
  placeholder profiles and positive complete-capability backends, so the native
  path has a pinned availability invariant.
- Keep the first TLS session a dependent resource nested under a scoped
  `TcpStream`. Landed at the API/metadata/type-rule level: the parent stream
  cannot be used directly while the session is live. OpenSSL native backend
  support now uses that same dependent scope; other platform backends remain
  future work behind the same capability boundary.
- Keep `TlsError` typed. Landed with string transport details.
- Add TLS chunk adapters on the generic fallible-stream terminal ABI. Landed
  with a TLS error domain.
- Make TLS read/write operations fiber-aware or explicitly route them through a
  bounded blocking-worker service before replacing the unsupported stubs.

Exit criteria:

- TLS has the same scoped cleanup guarantees as TCP.

### Phase 6: UDP Resources

Status: closed for the current checkpoint. Scoped UDP support lives in
`std/net/udp`. `UdpSocket` is a
resource with compiler-owned cleanup metadata. Runtime support covers socket
creation, `bind`, no-DNS `bind_numeric`, one-shot nonblocking `send_to`,
no-DNS `send_to_numeric`, virtual-thread-aware `send_to_wait`,
no-DNS `send_to_wait_numeric`, `recv_from`, fallible
`datagrams(socket, max_bytes)` streams, and `local_port`, with typed
`UdpError`/`Datagram` bridging through the shared operation-result metadata
manifest and the generic fallible-stream terminal ABI.
`pkg/net/udp.brp` remains a placeholder and no longer exposes raw integer file
descriptors, blocking receive calls, or manual close.

Goals:

- Keep the scoped socket API portable in `std/net`; plain package FFI still
  cannot own compiler-managed cleanup edges.
- Model received datagrams as ordinary values. The reactor now stores a typed
  IO-wait owner instead of embedding `TcpInner` in registration and deadline
  state; TCP and UDP are concrete owner variants. Registration, parking, and
  cancellation cleanup now dispatch through this owner tag, so new networking
  protocols should add owner operations instead of duplicating reactor wait
  control flow.
- Treat a parked IO waiter as a cancellation-sensitive owned value. The shared
  wait path now registers a task-local cleanup frame for the waiter, removes it
  from its owner/deadline queue during non-local cancellation, and releases it
  before the task exits.
- Keep fallible datagram streams on top of `recv_from` without allowing scoped
  stream/cursor values to escape their owning socket. The source now exists as
  `datagrams(socket, max_bytes) -> FallibleStream[Datagram, UdpError]`. The
  typecheck suite now pins this for UDP, TCP, and TLS stream producers: their
  `FallibleStream` values cannot be hidden in `Result` carriers or passed
  through ordinary calls after being derived from scoped resources.
- Reuse the generic fallible-stream terminal bridge. UDP now has its own stream
  error domain and source pull adapter; new protocols should follow that shape
  instead of adding protocol-specific terminal operations.
- Keep UDP send behavior explicit. `send_to` remains a nonblocking one-shot
  operation that can report `Busy`; `send_to_wait` parks one virtual thread on
  socket writability and rejects a second overlapping parked send as `Busy`.
  Sustained concurrent producers should be modeled as a send service or queue
  instead of implicit shared mutable resource state.
- Keep no-DNS UDP paths explicit and tested. `bind_numeric` accepts numeric IPv4
  hosts plus `""` for passive bind-any; `send_to_numeric` and
  `send_to_wait_numeric` accept numeric IPv4 hosts only. Hostnames are rejected
  as `InvalidInput` before `getaddrinfo`.
- Treat owned values pulled from fallible streams as cancellation-sensitive
  temporaries while user callbacks run. Terminal operations now register pulled
  owned items with task-local cleanup before `fold_result`, `find_result`,
  `any_result`, and `all_result` callbacks, so cancellation inside a predicate
  or fold callback releases the item.

Exit criteria:

- UDP DNS/game examples do not expose raw descriptors or manual close. The old
  `pkg/net/udp` raw-descriptor surface now reports a typed resource-migration
  error and points callers at `std/net/udp`.
- Leak-check coverage proves scoped `UdpSocket` cleanup on normal exits and
  cancellation-adjacent paths. Current baselines cover cancelled `recv_from`,
  cancelled datagram-stream receive, and cancellation while a datagram stream
  callback owns the pulled `Datagram`.

### Phase 7: DNS Strategy

Goals:

- Keep the std and package resolver clearly documented as blocking until a
  bounded resolver service lands. The std `resolve` surface now exists as a
  compiler-owned typed operation-result bridge returning ordinary copied address
  data, and the public std function is the direct builtin boundary so compiler
  metadata is visible at source call sites; the package helper remains
  package-FFI-backed.
- Keep no-DNS TCP paths explicit and tested. The preferred surface now uses
  validated endpoint values: `ipv4(...)`/`parse_ip(...)` feed `listen_ip` and
  `connect_ip`, while `dns_name(...)` feeds `connect_name`. The older
  `listen_numeric(host, port, backlog)` and `connect_numeric(host, port)`
  remain as compatibility helpers until the remaining tests/docs are migrated.
- Replace the current blocking std DNS backend with a bounded runtime resolver
  pool unless a true nonblocking resolver is available on all target platforms.
- Defer user-configurable resolver pool handles until Blorp has an explicit
  service category. Do not represent a shared resolver pool as a normal
  resource captured by concurrent tasks.
- If a nonblocking DNS backend is added later, keep the surface API stable and
  swap the runtime implementation behind the same typed operation metadata.
- Avoid silently pinning unbounded OS workers.
- Make cancellation and timeout behavior explicit.

Exit criteria:

- Hostname TCP/HTTP connection paths have a documented and tested concurrency
  behavior. Current checkpoint: the blocking DNS limitation remains documented,
  std DNS returns only ordinary copied data, and TCP now has tested no-DNS
  resource acquisition APIs for callers that need virtual-thread-friendly
  connection setup.

### Phase 8: HTTP And WebSocket

Status: first WebSocket std resource surface landed. `std/net/websocket.brp`
defines `WebSocketSession`, `WebSocketError`, ordinary `Message` values,
`native_available()`, `connect(url) -> Result[WebSocketSession,
WebSocketError]`, `receive(session) -> Result[Message, WebSocketError]`, and
explicit send operations for text, binary, ping, pong, and close frames.
Runtime connect validates URL authority, optional port, and no-fragment shape,
then the active runtime backend acquires a scoped TCP or TLS transport,
performs the HTTP upgrade handshake, and publishes an `Open` session only after
that succeeds. The important invariant is already in place: a connection cannot
be represented as a copyable record or hidden inside ordinary data. The runtime
now routes WebSocket operations through an
explicit backend table with a native capability mask, an active backend
selector, table-completeness checks, explicit session states, and cleanup-state
transitions. The runtime now treats backend capability bits as authoritative
dispatch gates, so a backend cannot accidentally receive connect, receive, or
send operations for capabilities it has not declared. Availability also depends
on an explicit backend-kind allow list, so the portable unsupported backend or
an unknown enum value cannot become "native" merely by carrying a complete
operation table in an internal probe. WebSocket sessions now also carry an
explicit tagged transport owner (`None`, `TcpStream`, or `TlsSession`) separate
from backend-private parser state. That gives future native backends a typed
place to transfer TCP/TLS ownership into the session instead of hiding scoped
resources inside opaque backend state. Internal WebSocket transport operations
now read bytes and write complete byte buffers through that tagged owner,
centralizing TCP/TLS error mapping before frame parsing is introduced. Outgoing
client-frame serialization is now also centralized: opcode validation, masked
payload writing, extended-length encoding, and control-frame size limits live at
one runtime boundary instead of being left to each future send hook. Incoming
server-frame decoding now has the matching runtime boundary for complete frames:
reserved bits, fragmentation, server masking, minimal length encoding, exact
payload length, control-frame limits, close-code shape, and UTF-8 text/reason
validity are rejected before a native backend can produce a typed message. The
transport side now has an exact-read helper that assembles a single complete
server frame from TCP/TLS chunks, treats EOF during a frame as typed `Closed`,
and keeps the in-progress frame buffer on the task-local cancellation cleanup
stack while reads may park. The send side now mirrors that ownership rule:
serialized client frames and synthesized text/close payloads are cleanup-owned
while a transport write may park, so cancellation cannot skip their release.
Transport-backed receive and send callbacks now sit behind an internal backend
table used by runtime probes; it intentionally lacks connect/handshake
capabilities, so it exercises frame I/O without making the active portable
backend look native-capable.
`connect` now parses the raw URL into an explicit backend connect
target before dispatch: secure/plain scheme, copied host/path/query strings,
IPv6-literal marker, and defaulted or explicit port are represented as fields
instead of leaving future backends to re-parse a raw string or retain borrowed
URL slices. The backend handshake hook receives that parsed target directly, so
future HTTP upgrade code does not need hidden connect-time URL state. The
runtime validates the parsed target again at the backend boundary, keeping
malformed internal targets out of backend code. Runtime helpers now also own
WebSocket client key generation, canonical HTTP upgrade request construction,
strict server handshake validation, including status, `Upgrade`, `Connection`,
and `Sec-WebSocket-Accept` checks, and a transport-backed handshake driver that
writes the request, reads through the HTTP header terminator, preserves any
post-handshake frame bytes in the session read buffer, and validates the
response before a session can be published. Backend `connect` now
creates only a provisional `Handshaking` session; the runtime registers that
session for cancellation cleanup, drives the backend handshake hook, and
publishes an `Open` session only after the hook succeeds. A backend that skips
that state transition is rejected as an invalid backend state. The test-only
runtime probe covers placeholder availability, positive complete-capability
backends, incomplete backend dispatch, parsed connect-target fields, a real
loopback `ws://` TCP connect plus HTTP upgrade through the active runtime
backend, handshaking-state I/O rejection, closed and failed sessions, cleanup
transition, successful synthetic sends, and the receive-boundary guard that
rejects backend success without a concrete frame kind. WebSocket receive no
longer asks runtime backends to manufacture the source-level `Message` union
directly: backends
return an explicit runtime frame result (`Text`, `Binary`, `Close`, `Ping`, or
`Pong`) with copied payload fields, and the operation-result bridge constructs
the visible `std/net/websocket::Message` union in generated C. This keeps the
runtime/backend ABI independent from generated std constructor names while
preserving one owned success payload for ARC cleanup. WebSocket sessions now
also carry explicit read and write
operation slots: overlapping receives return typed `Busy`, overlapping writes
return typed `Busy`, and cancellation cleanup clears the slot before unwinding.
That represents the one-reader/one-writer policy in runtime state instead of
leaving it as a backend convention. Those slots are now stored as explicit
operation-state enums, matching the TLS operation guard, so invalid integer
states are not part of the session layout. Successful `send_close` now moves
the session into `Closing`, so later I/O is rejected at the session-state
boundary instead of leaving post-close use as a backend convention. Receiving a
close frame moves the session into an explicit `CloseReceived` state: ordinary
reads and writes are rejected, but one close reply is still permitted before
the session enters `Closing`. Close-frame sends also validate
reserved/out-of-range close codes and the 123-byte reason limit before any
backend can put an invalid close frame on the wire. Text and binary sends
validate missing or malformed payload objects before backend dispatch, and
ping/pong sends enforce the WebSocket 125-byte control-frame payload limit at
the runtime boundary.
WebSocket `messages(session) -> FallibleStream[Message, WebSocketError]`
remains deferred. The runtime one-reader/one-writer state is now explicit, but
fallible stream pulls still have to return layout-compatible source values
directly. WebSocket receive intentionally returns a runtime frame result and
lets the operation-result bridge construct the source-level `Message` union in
generated C, so adding a message stream should first add a stream element bridge
or role-resource model instead of teaching the runtime about generated std
constructors. Runtime coverage also pins the current HTTP-over-TCP server
pattern: concurrent resource-source fan-out owns each accepted `TcpStream`,
while routing is factored into pure functions over ordinary `net/http` request
and response values. Codegen audit coverage pins the cancellation-cleanup shape
for both owned HTTP response bytes passed to `Tcp.write_all` and stack `Result`
temporaries that carry read/parse/write payloads inside a resource-source child
task, so a cancellation while the write is parked cannot skip local payload
release.

Goals:

- Treat HTTP client pools as services.
- Treat HTTP request/response bodies as fallible streams.
- Treat WebSocket sessions as resources. Landed for the session owner,
  explicit reads/writes, one-reader/one-writer runtime guards, and
  backend/session runtime boundary; streams and read/write role resources remain
  deferred until TCP/TLS/WebSocket can share one coherent role model.
- Avoid capturing scoped resources in server handlers; use resource-source
  iteration for accepted connections and services for shared state.

Exit criteria:

- A high-concurrency HTTP server and WebSocket echo server can be written in
  direct style without manual cleanup or shared mutable memory. The HTTP/TCP
  side is covered by `tests/test_blorp/sys/test_http_resource_server.brp`;
  WebSocket remains pending on message-stream or reader-role ergonomics.

### Phase 9: Database And External Services

Goals:

- Use the same resource/service split for database connectors.
- Model pools as services, checked-out connections as resources, transactions
  and cursors as scoped dependent resources, and copied rows as ordinary data.
- Reuse operation metadata and cancellation audits for blocking database waits.

Exit criteria:

- Database examples align with networking examples instead of inventing a
  second resource story.

### Phase 10: Select And Waitables

Goals:

- Decide how `select` interacts with resource-producing waits such as accept,
  datagram receive, WebSocket frame receive, and DB notification receive.
- Keep resource ownership explicit if a selected branch produces a resource.
- Avoid a select API that can leak a resource from an unchosen arm.
- Keep the current channel/timer-only `select` boundary explicit in diagnostics
  until selected-branch resource ownership is represented in typed AST and Core.

Current checkpoint:

- Ordinary channel receive, sealed-channel, and timer arms are implemented.
- Typed AST now carries the checked channel element type for receive and sealed
  channel arms, so Core lowering no longer has to rediscover `Channel[T]` from
  the channel expression. This keeps the current ordinary-waitable subset
  explicit across the AST -> Core boundary.
- Inference now classifies select waitables through an explicit internal
  `select_waitable_kind`: ordinary channels, resource sources,
  resource-producing waits, and unsupported values. This keeps the intentional
  resource-producing boundary represented as a compiler state instead of a
  fall-through channel mismatch.
- The non-channel cases now flow through explicit rejection variants that keep
  the rejected type, so diagnostics and future resource-producing `select`
  lowering do not have to reconstruct that information from a generic channel
  mismatch.
- ResourceSource and resource-producing select arms are still intentionally
  rejected. The typechecker now reports this as the missing ownership model
  rather than as a generic channel-type mismatch.
- Operation-result metadata now classifies runtime result bridges by both wait
  behavior and result ownership: ordinary fiber waits, resource-producing fiber
  waits, non-suspending operations, and OS-worker-blocking operations. Future
  `select` work should consume that classification instead of inventing a local
  list of acceptable networking calls.
- Select inference now resolves module function calls back to their compiler
  builtin runtime operation when available. Receive and sealed arms such as
  `stream from Tcp.accept(listener):` or `sealed Tcp.accept(listener):` are still
  rejected, but they are rejected as resource-producing fiber waits with
  explicit ownership notes, not as generic channel mismatches. Ordinary
  operation-result waits and OS-worker blocking operations are similarly
  distinguished while they remain unsupported in `select`. Transparent source
  wrappers such as type ascriptions are unwrapped before operation-result
  classification, so `(Tcp.read_chunk(...) as Result[...])` cannot bypass the
  explicit waitable boundary. UFCS and selective-import calls flow through the
  same metadata path as qualified module calls, so `stream.read_chunk(16)` and
  `read_chunk(stream, 16)` cannot accidentally degrade to a generic
  `Channel[T]` mismatch. Std operation-result APIs that should participate in
  this classification must expose the runtime builtin at the public std
  boundary rather than hiding it behind trivial wrappers; `std/net/dns.resolve`
  now does this for the blocking resolver operation, and the codegen builtin
  registry points at `resolve` rather than the deleted private `resolve_raw`
  wrapper. Each operation-result bridge now carries an explicit source-module
  enum, so the audit does not infer std ownership from runtime builtin name
  prefixes. Unit coverage parses that module's std source and audits that
  every operation-result bridge is exposed by at least one public std function
  with a direct `builtin(...)` body, so scheduler/ownership metadata does not
  get lost behind private raw wrappers. Fallible stream source metadata now
  carries the same explicit source-module enum, and unit coverage applies the
  same public-direct std audit to I/O-backed stream producers such as file
  chunks, TCP/TLS chunks, and UDP datagrams.

Exit criteria:

- `select` can wait on ordinary messages and resource-producing operations only
  where ownership is statically clear.

## Testing Strategy

Every phase should add failing tests first:

- Parser/formatter tests for new source forms.
- Typecheck failures for resource escape, capture, aggregate storage, ordinary
  params/returns, and stale manual-close imports.
- Unit tests for builtin metadata, operation result manifests, and Core
  invariants.
- Codegen audit tests for cleanup frames around cancellation points.
- Codegen audit tests for resource-source child tasks that own both a moved
  resource and ordinary response/request payloads across cancellation points.
- Codegen audit tests for stack `Result` temporaries whose owned payloads stay
  live across later cancellation points.
- Codegen audit and leak tests for stack `Result` values crossing channel
  send/select/iteration boundaries.
- Runtime tests for loopback networking, timeouts, seal/close interactions,
  reactor wakeups, and protocol behavior.
- Leak-check baselines for cancellation while parked in accept/read/write,
  resource-source child tasks, TLS reads/writes, UDP receives, DNS waits, and
  database waits.
- Sanitizer tests for TCP/TLS/UDP runtime paths.
- Stress/property tests where ordering matters: channels, datagrams,
  WebSocket frames, HTTP response bodies, and pool checkout fairness.

## Open Decisions

- Should userland ever get a borrowed-resource parameter model, or should
  resource helpers remain compiler-owned plus callback/resource-source based?
- Should `ResourceSource[R, E]` expose source errors as stop/continue policy
  constructors, an event stream, or a typed terminal result?
- Should services be a first-class type category or a library convention backed
  by trusted builtin/foreign declarations?
- How much DNS behavior should be portable versus delegated to platform
  libraries?
- Which networking operations deserve `select` support before resource-producing
  select is fully designed?

Resolved for now:

- TCP split reader/writer resources should not land as a TCP-only feature.
  Revisit them with TLS and WebSocket so role resources have one coherent
  ownership and concurrency model.

## Next Checkpoint

The TLS integration-hardening checkpoint is now closed:

- `scripts/test-tls-openssl-local` exercises the OpenSSL profile against a
  locally generated trusted TLS endpoint without public network access.
- HTTPS and STARTTLS package helpers are tested under both portable default and
  `BLORP_TLS_BACKEND=openssl` profiles, so capability guards are pinned.
- OpenSSL setup now validates protocol-version setup, verification-parameter
  availability, hostname inputs, trust-store loading, nonblocking handshake,
  `write_all`, and `read_chunk` without weakening scoped cleanup.
- WebSocket package and std URL validation now agree on the authority boundary,
  and the std runtime backend now reaches native transport acquisition only
  after that boundary is checked.

The next high-ROI slice should be chosen from these bounded options:

1. Define the WebSocket native-runtime plan in terms of explicit backend steps:
   URL parse result, TCP/TLS acquisition boundary, HTTP upgrade handshake,
   frame read/write steps, close-state transitions, and error mapping. Do not
   add `messages(session)` until stream element bridging or reader-role
   resources can preserve the existing operation-result boundary for
   source-level `Message` union construction. The first part has landed:
   `connect` dispatches through an
   explicit parsed connect target rather than a raw URL string, and that target
   now carries copied Blorp strings instead of borrowed slices into the original
   URL. The backend handshake hook receives the same target, and the handshake
   boundary validates the target before dispatch. Runtime helpers now generate
   client keys, construct the HTTP upgrade request from the parsed target, and
   validate server upgrade responses before a backend can publish an open
   session. WebSocket sessions now carry an explicit runtime read buffer for
   bytes that were already pulled from TCP/TLS but not yet consumed by frame
   decoding. The transport-backed handshake driver uses chunked transport
   reads, stores any early post-upgrade frame bytes in that buffer, and then
   frame reads consume buffered bytes before touching the underlying transport.
   The active runtime backend now acquires `ws://` sessions through TCP and
   `wss://` sessions through `TcpStream` plus `TlsSession` when native TLS is
   available. Owned TCP streams are registered for cancellation cleanup while
   the TLS handshake may park, and the resulting TCP/TLS handle is consumed into
   the WebSocket session's tagged transport owner rather than retained in
   backend-private state. Runtime probe coverage now includes a local loopback
   `ws://` server that performs the upgrade and sends an early text frame, so
   active-backend transport acquisition, handshake publication, read buffering,
   and receive are checked without external network dependencies.
   The handshake driver uses an explicit provisional-session transition guarded
   by cancellation cleanup. Successful
   close-frame sends also now move the session into `Closing`, with close-code
   and close-reason validation enforced before backend dispatch. Incoming close
   frames now move through an explicit `CloseReceived` state that permits only
   the protocol close reply. Ping/pong control-frame size validation and
   send-payload shape validation also run before backend dispatch. Backend
   capability bits are now checked before operation dispatch rather than being
   only an availability hint, and native availability now also requires an
   explicit backend-kind allow list rather than treating every nonzero enum
   value as native-capable. Session transport ownership is now an explicit
   tagged owner for either a TCP stream or TLS session, so native backends have
   a cleanup-owned field for the underlying transport rather than an opaque
   resource hidden in backend state. Transport reads/writes now dispatch through
   that tagged owner and map TCP/TLS failures into `WebSocketError` in one
   runtime boundary. Outgoing client-frame serialization now has one runtime
   helper that enforces valid opcodes, masking, extended payload lengths, and
   control-frame size limits before transport write. Complete incoming
   server-frame decoding now has one runtime helper that rejects malformed wire
   frames before constructing typed receive results, plus a transport exact-read
   helper that turns partial TCP/TLS chunks into one complete frame without
   leaking the in-progress frame across cancellation. Client-frame sending now
   keeps serialized frames and synthesized payload buffers on cancellation
   cleanup while transport writes may park. An internal transport-frame backend
   now routes backend receive/send callbacks through those helpers for probe
   coverage, while remaining unavailable as a native backend because it lacks
   connect/handshake capabilities. Receive results now use an explicit runtime
   frame kind and operation-result union bridge, so future native backends do
   not need to depend on source-level `Message` constructors.
2. Advance DNS without weakening the service model: the compiler-owned
   `std/net/dns.resolve` operation with documented blocking behavior has landed.
   The raw runtime bridge is now typed end-to-end, including exact
   `List[String]` success-payload metadata. The remaining DNS step is a bounded
   runtime resolver pool or true nonblocking backend behind the same
   ordinary-data API. Do not expose a copyable resolver pool as ordinary data.
3. Tighten select/waitable design for resource-producing operations before
   broadening select to accept/TCP/UDP/WebSocket waits, because unchosen
   resource-producing arms must not leak ownership.

TLS is now the reference protocol for reusing scoped resource ownership,
operation metadata, cancellation cleanup, readiness parking, native-profile
selection, and streaming patterns without weakening compiler restrictions.
