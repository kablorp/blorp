# Streaming And Scoped Resources Roadmap

Status: design target and implementation roadmap.

This document sketches a coherent direction for Blorp's streaming and resource
APIs. It is intentionally more precise than a feature brainstorm: the goal is to
make resource lifetime, one-shot streaming, fallible I/O, virtual-thread
blocking behavior, and ownership semantics explicit enough that later compiler
work can make illegal states unrepresentable.

## Executive Summary

Blorp should grow a first-class `with` expression for scoped resources:

```blorp
func count_lines(path: String) -> Result[Int, IOError]:
	with reader ?= path.open_read():
		n ?= reader.lines().count()
		Ok(n)
```

The user-facing rule is simple:

```text
with acquires a scoped resource, evaluates the body, and closes the resource.
Values derived from that resource cannot escape the with block.
```

Under that surface, the design needs five pieces:

- Scoped resource bindings that are not ordinary freely copyable values.
- A cleanup model represented in the compiler IR, not hidden in C emission.
- A distinction between infallible streams and fallible I/O-backed streams.
- Fiber-aware blocking behavior for channels, TCP, and eventually file/process
  APIs where the runtime can support it.
- A phase-by-phase Core/codegen contract so resource lifetime is explicit from
  lowering through final C emission.

## Design Principles

This roadmap follows the project-level language principles:

- Safe: resource leaks, double closes, use-after-close, and escaped cursors
  should become compile-time errors where possible.
- Understandable: lifetime boundaries should be visible in source code.
- Expressive: common file, socket, channel, and database streaming should be
  compact without callback pyramids.
- Simple: the first version should not add full general-purpose lifetimes,
  arbitrary destructors, or whole-language lazy evaluation.
- Fast: file streams should read chunks, line counting should avoid allocating
  one `String` per line when the caller only needs a count, and blocking I/O
  should not accidentally pin virtual-thread workers.

## Current State Revalidation

This section records what exists today and what the design must account for.

### Stream

`std/stream.brp` defines:

```blorp
type Stream[T] = builtin
```

Current sources include `from_list`, `from_range`, `repeat`, `unfold`, `empty`,
and `from_lines`. Transformations include `map`, `filter`, `filter_map`,
`take`, `drop`, `take_while`, and `enumerate`. Terminal operations include
`collect`, `fold`, `count`, `for_each`, `find`, `any`, and `all`.

Current runtime shape:

- `blorp_Stream` is a C runtime object with a pull function, opaque state, a
  state cleanup callback, and an explicit element layout enum.
- Streams are lazy and one-shot in practice.
- `from_lines` uses `FILE*` and `getline`.
- `from_lines` returns an empty stream if open fails.
- `from_lines` opens the exact path string provided by the caller.
- Terminal operations now include cooperative cancellation checkpoints.

Correctness risks already identified:

- `from_lines` still has compatibility semantics that are wrong for new I/O
  APIs: empty-on-open-failure.
- Stream source/intermediate ABI should continue moving from scalar flags to
  named layout values as new adapters are added.
- File reads can fail after open succeeds, so an API that only returns
  `Result[Stream[T], IOError]` at open time is not enough for full I/O
  correctness.

### System File APIs

`std/system.brp` currently contains a mixture of:

- whole-file APIs: `read_file`, `write_file`, `read_bytes`, `write_bytes`;
- lossy convenience APIs: `read_all_lines` returns an empty list for missing
  files, `append_file` returns `Bool`;
- callback APIs: `for_each_line`, `for_each_chunk`;
- filesystem operations and metadata helpers.

These APIs are useful, but they mix fallible `Result` APIs with `Bool` and
empty-on-failure APIs. The resource roadmap should introduce a cleaner typed
handle layer and keep compatibility wrappers only where their behavior is
explicitly documented.

### Channels

`std/channel.brp` exposes `Channel[T]` plus send/recv/close operations.
Runtime channel waits are fiber-aware: blocking send/recv can park the current
fiber without occupying an OS worker thread.

Important distinction: `Channel.close` is a semantic operation that affects all
senders/receivers. It is not merely "release this handle". We should not blindly
retrofit every channel as a normal scoped resource. Channel-backed streams can
exist, but channel lifecycle needs its own semantics.

### TCP

`std/net/tcp.brp` now exposes opaque typed handles instead of raw `Int` file
descriptors:

```blorp
TcpListener
TcpStream
```

The current public API is:

```blorp
listen(host: String, port: Int, backlog: Int) -> Result[TcpListener, String]
accept(listener: TcpListener) -> Result[TcpStream, String]
connect(host: String, port: Int) -> Result[TcpStream, String]
read(stream: TcpStream, max_bytes: Int) -> Result[Bytes, String]
write(stream: TcpStream, data: Bytes) -> Result[Int, String]
close(handle: TcpListener) -> Void
close(handle: TcpStream) -> Void
local_port(handle: TcpListener) -> Result[Int, String]
local_port(handle: TcpStream) -> Result[Int, String]
set_timeout(handle: TcpListener, ms: Int) -> Result[Int, String]
set_timeout(handle: TcpStream, ms: Int) -> Result[Int, String]
```

Current runtime shape:

- listener and stream handles are ARC-managed builtin values wrapping shared
  runtime TCP state;
- newly created and adopted sockets are placed in nonblocking mode;
- `accept`, numeric-address `connect`, `read`, and `write` park fibers through
  the scheduler's poll-backed I/O reactor instead of pinning OS workers while
  waiting for socket readiness;
- timeout and cancellation paths wake parked socket waiters;
- `set_timeout` configures runtime virtual-thread deadlines, not kernel socket
  timeouts;
- scheduler instrumentation includes `reactor_control_wakes`,
  `reactor_poll_wakes`, `reactor_ready_events`, and `reactor_waiter_wakes`.

Remaining limitations:

- hostname resolution still uses `getaddrinfo` and can block an OS worker before
  the nonblocking socket phase begins;
- errors are still represented as `String`, not a typed `TcpError`;
- typed TCP handles are normal ARC-managed values, not compiler-scoped
  resources yet;
- TCP does not yet expose `chunks`, `lines`, or other fallible stream adapters;
- runtime interop helpers can still adopt or reveal raw fds for internal,
  package, and test use, but the public Blorp TCP API no longer accepts raw
  `Int` descriptors.

### Question-Bind Propagation And Error Types

`?=` performs `Option` and `Result` short-circuiting directly in functions that
return the corresponding carrier type. `Result` error types must remain exact
unless and until a dedicated error conversion mechanism exists. This matters for
resource APIs because file, TCP, database, parser, and application errors will
often meet inside one propagation context.

Short-term ergonomic pattern:

```blorp
union AnalyzeError:
	Io(IOError)
	Db(DbError)

func analyze(path: String, url: String) -> Result[Int, AnalyzeError]:
	with reader ?= path.open_read().map_err(func(e): Io(e)):
		file_count ?= reader.lines().count().map_err(func(e): Io(e))

		with conn ?= db.connect(url).map_err(func(e): Db(e)):
			user_count ?= conn.query_count("select count(*) from users").map_err(func(e): Db(e))
			Ok(file_count + user_count)
```

Possible later improvement:

```blorp
trait IntoError[Target]:
	pure func into_error(self: Self) -> Target
```

If added, it should apply only at explicit propagation points such as `?=`, not
as a broad implicit conversion system.

## Core Design Target

### User-Level Concepts

Blorp should expose laziness through stream types, not through general lazy
evaluation.

```text
List[T]              eager, reusable, materialized values
Stream[T]            lazy, one-shot, infallible pull source
FallibleStream[T,E]  lazy, one-shot, fallible pull source
Channel[T]           concurrent communication primitive
Resource             scoped external capability that must be closed
```

The most important teaching distinction:

```blorp
path.read_all_lines()          -- eager, materializes the file
reader.lines().count()         -- streaming, bounded memory
reader.lines().collect()       -- streaming source, eager result
```

### Resource Values Are Not Ordinary Copyable Values

This is the largest design correction from the initial sketch.

Blorp has value semantics: assignment copies, closures capture by value, and
ordinary user values should not provide shared mutable access. A file handle,
socket, transaction, row cursor, lock guard, or subprocess handle is different:
it is an external capability with state outside the Blorp value graph.

Therefore a `with`-bound resource should be a scoped capability, not an ordinary
copyable value.

Initial rules:

- A resource can be bound by `with`.
- Synchronous method calls may borrow the resource for the duration of the call.
- Stream/cursor values derived from the resource inherit its scope.
- A scoped resource can be passed only to functions/methods whose parameter is
  marked as a resource borrow or resource-consuming operation.
- A scoped resource cannot be assigned to a normal variable outside the block.
- A scoped resource cannot be put in a list, record, dict, set, closure capture,
  or global.
- A scoped resource cannot be captured by `detach`.
- A scoped resource can be used inside `concurrent:` only when the block joins
  before the resource closes and the resource type explicitly permits the
  operation.

Later, Blorp may add explicit move-only or affine values. The first `with`
design should avoid needing a full general move system by keeping resource
capabilities scoped to the block.

### Resource Borrowing And User Functions

Methods such as `reader.lines()` and `conn.read_chunk(...)` need to borrow a
resource. That borrowing is safe when the call is synchronous and the returned
value is either ordinary data or is marked as scoped to the borrowed resource.

The compiler should not allow arbitrary user functions to accept resources as
ordinary copyable parameters. Before user-defined resource helpers become
general, Blorp needs an explicit representation for borrowed resource
parameters. Possible surface syntax:

```blorp
func count_open(reader: borrow FileReader) -> Result[Int, IOError]:
	reader.lines().count()
```

The exact syntax is open. The invariant is not:

```text
passing a resource to a function must not copy it or let it escape
```

Until this exists, resource-parameter support can be limited to compiler-owned
std functions and methods with explicit resource contracts.

### Resource Protocol

Acquisition is intentionally not part of the resource protocol. Opening a file,
accepting a socket, starting a transaction, and running a query all have
different receivers, arguments, errors, and semantics.

Cleanup is the common operation:

```blorp
resource trait Resource:
	close(self: Self) -> Void
```

`close` should be infallible and idempotent from the language perspective.
If completion can fail, expose that explicitly before cleanup:

```blorp
writer.flush() -> Result[Void, IOError]
writer.finish() -> Result[Void, IOError]
writer.close() -> Void
```

The `close` operation is cleanup, not business logic.

## `with` Block API

### Syntax

Infallible acquisition:

```blorp
with resource = acquire_resource():
	body
```

Fallible acquisition:

```blorp
with resource ?= acquire_resource():
	body
```

Optional type annotation:

```blorp
with file: FileReader ?= path.open_read():
	file.read_all()
```

Anonymous guard:

```blorp
with _ = profiler.section("load"):
	load()
```

Nested resources:

```blorp
with conn ?= db.connect(url):
	with tx ?= conn.transaction():
		with rows ?= tx.query("select id, name from users"):
			n ?= rows.count()
			Ok(n)
```

Do not start with a multi-binding syntax. Nested `with` blocks make close order
obvious and avoid design pressure around partial acquisition failures.

### Expression Semantics

`with` is an expression. Its value is the value of the body.

```blorp
func count(path: String) -> Result[Int, IOError]:
	with reader ?= path.open_read():
		n ?= reader.lines().count()
		Ok(n)
```

Cleanup runs when the body exits by:

- normal completion;
- `?=` short-circuit;
- `break`;
- `continue`;
- structured-concurrency cancellation;
- timeout cancellation;
- any runtime-controlled nonlocal path.

Nested resources close in reverse acquisition order.

### Desugaring Target

Source:

```blorp
with r ?= acquire():
	body
```

Conceptual behavior:

```text
tmp = acquire()
match tmp:
	Ok(r):
		enter cleanup scope for r
		evaluate body
		close r on every exit path
	Err(e):
		propagate Err(e)
```

This should not be implemented as an ad hoc codegen trick. The Core pipeline
needs an explicit cleanup representation so Perceus, cancellation, break,
continue, and early `?=` propagation can all preserve the same invariant.

The target Core concept should be a canonical node, not just sugar:

```text
CResourceScope(binding, body, cleanup)
```

The exact field names can be chosen during implementation, but the invariant
must be explicit in the IR:

```text
every successful resource acquisition has exactly one cleanup edge
```

`cleanup` is semantic cleanup (`close`), not the same thing as Perceus
reference-count release. A resource handle may still be backed by an
ARC-managed runtime object, but `close` is the deterministic external-resource
operation. `CDrop` must not be treated as a substitute for `close`.

### Core Pipeline And Codegen Fit

The current codegen path is the Core pipeline:

```text
lower -> debug -> desugar -> mono -> synth -> match -> trait_resolve ->
resolve -> std_inline -> tailrec -> fusion -> specialize -> perceus ->
reuse -> closure -> final prepare -> emit C
```

Resource work must fit that pipeline explicitly:

- Parser/typed AST:
  - represent `with` as its own expression, including plain vs fallible
    acquisition;
  - attach resource/scoped-value facts to typed bindings and derived values;
  - reject resource escapes before Core lowering whenever the typed AST has
    enough information.
- `Core_lower`:
  - lower `with` to explicit Core, not to an emitter-only convention;
  - introduce the resource scope around the success path of fallible
    acquisition;
  - preserve locations for the acquisition, body, and cleanup diagnostics.
- `Core_lower` / `Core_desugar`:
  - lower `?=` through continuation-aware block lowering while preserving
    `CResourceScope` as canonical cleanup Core;
  - if `with ?=` is lowered through `Result`/`Option` matching, the successful
    branch must be the only branch that owns the resource cleanup edge.
- `Core_debug`, `Core_mono`, `Core_synth`, `Core_match`,
  `Core_trait_resolve`, `Core_resolve`, `Core_std_inline`, `Core_tailrec`, and
  `Core_fusion`:
  - traverse `CResourceScope` like other control-flow nodes;
  - do not duplicate, hoist, inline, fuse, or scalar-replace across a cleanup
    boundary unless the pass proves the cleanup edge is preserved exactly once;
  - treat resource scopes as barriers for transformations that would move
    effectful I/O or cleanup.
- `Core_specialize`:
  - specialize any cleanup callee and resource-borrowing intrinsics before
    ownership insertion;
  - keep erased-storage/resource ABI facts explicit instead of recovering them
    from names in emit.
- `Core_perceus`:
  - insert `CDup`/`CDrop` for normal managed values inside the scope;
  - preserve `CResourceScope`;
  - never model `close` as a `CDrop`;
  - ensure any ARC release for the handle object happens after semantic
    cleanup on the owned resource path.
- `Core_reuse`:
  - treat resource scopes as allocation-reuse barriers unless a future pass has
    resource-specific proof.
- `Core_closure`:
  - reject or preserve prior rejection of scoped-resource captures;
  - final Core must not contain a closure, detach task, or escaping concurrent
    task that captures a scoped resource or value derived from it.
- `Core_codegen_prepare`:
  - make any remaining resource ABI/layout facts explicit before final
    invariants run;
  - do not introduce new resource ownership states after this point.
- `Core_emit_c`:
  - emit cleanup from explicit Core nodes only;
  - handle normal completion, `break`, `continue`, `try`-lowered early exit,
    timeout cancellation, and structured-concurrency cancellation through the
    same cleanup edge;
  - keep emit-time checks only as defense-in-depth. The authoritative guarantee
    should come from Core invariants before final emission.

This likely needs a small `Core_resource` or `Core_cleanup` pass once the first
implementation reaches `break`/`continue` and cancellation. The pass should
make nonlocal exits through a resource scope explicit, for example with labeled
cleanup exits or cleanup-frame nodes, instead of teaching unrelated emitter
branches to remember resource state implicitly. If a new observed stage is
added, update `Core_stage`, `Core_pipeline.observed_stage_order`,
`docs/ARCHITECTURE.md`, and the stage round-trip tests in the same slice.

Required Core invariants:

- No scoped resource or scoped-derived value appears in a global initializer,
  heap container literal, returned value, detached task capture, or closure
  capture.
- Every `CResourceScope` has exactly one cleanup operation for the acquired
  resource.
- Cleanup callees are resolved before final emission.
- `CResourceScope` cannot survive in a form where a pass has duplicated its
  body without duplicating and re-proving the cleanup edge.
- No sugar-only `with` node reaches emission; only canonical cleanup Core may
  reach emission.

### Escape Rules

Allowed:

```blorp
func count_nonempty(path: String) -> Result[Int, IOError]:
	with reader ?= path.open_read():
		n ?= reader.lines()
			.filter(func(line): line.length() > 0)
			.count()
		Ok(n)
```

Rejected:

```blorp
func bad(path: String) -> Result[FileReader, IOError]:
	with reader ?= path.open_read():
		Ok(reader)
```

Rejected:

```blorp
func also_bad(path: String) -> Result[FallibleStream[String, IOError], IOError]:
	with reader ?= path.open_read():
		Ok(reader.lines())
```

Rejected:

```blorp
func detached_bad(path: String) -> Result[Void, IOError]:
	with reader ?= path.open_read():
		detach reader.read_chunk(4096)
		Ok(void)
```

Rule:

```text
Values derived from scoped resources are scoped.
Scoped values cannot escape the scope that owns the resource.
```

This rule must be represented in typed AST/inference, not guessed from function
names such as `lines` or `map`.

### Structured Concurrency

Structured work may borrow a scoped resource only if the work joins before the
resource closes and the resource type allows the operation.

Potentially allowed in a future borrowed-resource model:

```blorp
with conn ?= db.connect(url):
	users ?= conn.query_count("select count(*) from users")
	orders ?= conn.query_count("select count(*) from orders")
	Ok(users + orders)
```

But this is only correct if `DbConnection` documents and enforces concurrent
query safety for any concurrent version of the same pattern. Many database
clients require one active query per connection. In that case the type/API
should force separate connections or a pool resource.

Detached work must not capture scoped resources.

## File And Filesystem API Target

### Module Organization

Prefer adding a focused module instead of continuing to grow `std/system.brp`:

```text
std/file.brp or std/fs.brp
```

`std/system.brp` can keep compatibility helpers and process/environment
functions. New file handles, open options, typed file errors, chunk readers, and
line streams should live in the new module.

### Error Type

Use a structured error type rather than plain `String`:

```blorp
union IOError:
	NotFound(String)
	PermissionDenied(String)
	AlreadyExists(String)
	InvalidPath(String)
	InvalidMode(String)
	Interrupted(String)
	WouldBlock(String)
	UnexpectedEof(String)
	Other(String)
```

The payload shape can be refined, but it should preserve enough information for
users to match on common cases without parsing strings.

### Capability Types

Start with named handle types:

```blorp
resource type FileReader = builtin
resource type FileWriter = builtin
resource type File = builtin
```

These are easier to teach than `File[Read]`, `File[Write]`,
`File[ReadWrite]`. A later generic capability form can be added if it buys real
precision.

Common opens:

```blorp
open_read(path: String) -> Result[FileReader, IOError]
open_write(path: String) -> Result[FileWriter, IOError]
open_append(path: String) -> Result[FileWriter, IOError]
open_read_write(path: String) -> Result[File, IOError]
```

UFCS:

```blorp
with reader ?= path.open_read():
	...
```

Advanced open:

```blorp
union FileAccess:
	Read
	Write
	ReadWrite

record OpenOptions {
	access: FileAccess,
	create: Bool,
	truncate: Bool,
	append: Bool,
	create_new: Bool,
}

open(path: String, options: OpenOptions) -> Result[File, IOError]
```

Initial semantics:

- `open_read` requires the path to exist.
- `open_write` creates if missing and truncates if present.
- `open_append` creates if missing and writes at end.
- `open_read_write` requires the path to exist and does not truncate.
- `open(path, options)` is fully explicit and rejects contradictory options,
  such as `truncate = True` with `access = Read`.

### Read API

```blorp
read_chunk(self: FileReader, max_bytes: Int) -> Result[Bytes, IOError]
read_all(self: FileReader) -> Result[Bytes, IOError]
read_text(self: FileReader) -> Result[String, IOError]
chunks(self: FileReader) -> FallibleStream[Bytes, IOError]
chunks(self: FileReader, chunk_size: Int) -> FallibleStream[Bytes, IOError]
lines(self: FileReader) -> FallibleStream[String, IOError]
bytes(self: FileReader) -> FallibleStream[UInt8, IOError]
windows(self: FileReader, size: Int) -> FallibleStream[Bytes, IOError]
```

Convenience functions:

```blorp
open_lines(path: String) -> Result[FallibleStream[String, IOError], IOError]
open_chunks(path: String) -> Result[FallibleStream[Bytes, IOError], IOError]
count_lines(path: String) -> Result[Int, IOError]
```

Resource-backed fallible streams returned by `open_lines` and `open_chunks`
are themselves scoped resources.

`count_lines` should use a chunk scanner and should not allocate a `String` per
line.

### Write API

```blorp
write(self: FileWriter, data: Bytes) -> Result[Int, IOError]
write_all(self: FileWriter, data: Bytes) -> Result[Void, IOError]
write_text(self: FileWriter, text: String) -> Result[Void, IOError]
flush(self: FileWriter) -> Result[Void, IOError]
finish(self: FileWriter) -> Result[Void, IOError]
```

`finish` is for operations where successful completion matters. `close` still
exists and remains infallible cleanup.

### Read/Write API

```blorp
seek(self: File, offset: Int) -> Result[Void, IOError]
position(self: File) -> Result[Int, IOError]
read_chunk(self: File, max_bytes: Int) -> Result[Bytes, IOError]
write_all(self: File, data: Bytes) -> Result[Void, IOError]
flush(self: File) -> Result[Void, IOError]
```

Avoid C stdio read/write switching pitfalls by implementing these handles on
file descriptors or platform equivalents, not `FILE*`, once this layer exists.
If buffering is added on top, the buffer state must make read/write transitions
explicit and tested.

### Chunk Size

Default chunk size should be an implementation detail. A good initial default is
64 KiB.

Optional runtime policy:

```text
default = 64 KiB
if fstat reports a useful st_blksize, use it as a hint
clamp implementation-chosen sizes to a sane range
validate or normalize user-provided sizes
```

Clamping is not a semantic requirement. It is defensive behavior to prevent
tiny sizes from causing excessive syscalls and huge sizes from causing memory
spikes.

Correctness must not depend on chunk size. Line parsing, byte windows, UTF-8
decoding, and parser state must handle boundaries across chunks.

## Stream API Target

### Infallible Stream

`Stream[T]` should mean:

```text
lazy, one-shot, pull-based, cannot fail during pull
```

Good sources:

- lists;
- ranges;
- deterministic generators;
- in-memory bytes/string adapters where indexing is infallible by design.

Terminal operations:

```blorp
collect(self: Stream[T]) -> List[T]
fold(self: Stream[T], init: Acc, f: (Acc, T) -> Acc) -> Acc
count(self: Stream[T]) -> Int
find(self: Stream[T], pred: (T) -> Bool) -> Option[T]
any(self: Stream[T], pred: (T) -> Bool) -> Bool
all(self: Stream[T], pred: (T) -> Bool) -> Bool
```

### Fallible Stream

I/O-backed streams need a distinct shape:

```blorp
type FallibleStream[T, E] = builtin
```

Terminal operations return `Result`:

```blorp
collect(self: FallibleStream[T, E]) -> Result[List[T], E]
fold(self: FallibleStream[T, E], init: Acc, f: (Acc, T) -> Acc) -> Result[Acc, E]
count(self: FallibleStream[T, E]) -> Result[Int, E]
find(self: FallibleStream[T, E], pred: (T) -> Bool) -> Result[Option[T], E]
any(self: FallibleStream[T, E], pred: (T) -> Bool) -> Result[Bool, E]
all(self: FallibleStream[T, E], pred: (T) -> Bool) -> Result[Bool, E]
```

Transformations preserve the error type:

```blorp
map(self: FallibleStream[T, E], f: (T) -> U) -> FallibleStream[U, E]
filter(self: FallibleStream[T, E], pred: (T) -> Bool) -> FallibleStream[T, E]
take(self: FallibleStream[T, E], n: Int) -> FallibleStream[T, E]
drop(self: FallibleStream[T, E], n: Int) -> FallibleStream[T, E]
map_err(self: FallibleStream[T, E], f: (E) -> F) -> FallibleStream[T, F]
```

Callback functions that can fail are a later design problem because they need
error-type combination:

```blorp
try_map(self: FallibleStream[T, E], f: (T) -> Result[U, F]) -> ?
```

Do not add this until the error conversion story is settled.

### Stream Scope Propagation

Combinators preserve scope.

If `lines` is scoped to `reader`, then all of these are also scoped to
`reader`:

```blorp
lines.map(...)
lines.filter(...)
lines.take(10)
lines.enumerate()
```

Terminal operations erase scope only when the result contains no scoped values:

```blorp
lines.count()       -- Result[Int, IOError], allowed
lines.collect()     -- Result[List[String], IOError], allowed
```

Rejected:

```blorp
with reader ?= path.open_read():
	lines = reader.lines()
	lines
```

### `for` Over Streams

The current compiler should not accept `for x in stream` unless codegen supports
it. The target is:

```blorp
for line in lines:
	...
```

For `FallibleStream`, the loop needs an error story. Prefer not to make a
fallible loop silently discard read errors.

Possible explicit form:

```blorp
with reader ?= path.open_read():
	for line ?in reader.lines():
		...
	Ok(void)
```

This is future syntax. The first implementation can require terminal
operations or explicit `next()` APIs for fallible streams.

## TCP And Network Streaming Target

Typed handles and nonblocking readiness are already in place at the user level:

```blorp
type TcpListener = builtin
type TcpStream = builtin

listen(host: String, port: Int, backlog: Int) -> Result[TcpListener, String]
accept(self: TcpListener) -> Result[TcpStream, String]
connect(host: String, port: Int) -> Result[TcpStream, String]

read(self: TcpStream, max_bytes: Int) -> Result[Bytes, String]
write(self: TcpStream, data: Bytes) -> Result[Int, String]
close(self: TcpListener) -> Void
close(self: TcpStream) -> Void
```

The next API target is not "typed sockets" anymore; it is scoped sockets,
typed errors, and stream adapters layered on the current handles:

```blorp
resource type TcpListener = builtin
resource type TcpStream = builtin

listen(host: String, port: Int, backlog: Int) -> Result[TcpListener, TcpError]
accept(self: TcpListener) -> Result[TcpStream, TcpError]
connect(host: String, port: Int) -> Result[TcpStream, TcpError]

read_chunk(self: TcpStream, max_bytes: Int) -> Result[Bytes, TcpError]
write_all(self: TcpStream, data: Bytes) -> Result[Void, TcpError]
chunks(self: TcpStream, max_bytes: Int) -> FallibleStream[Bytes, TcpError]
lines(self: TcpStream) -> FallibleStream[String, TcpError]
```

Example:

```blorp
func read_connection(host: String, port: Int) -> Result[Int, TcpError]:
	with conn ?= connect(host, port):
		n ?= conn.chunks(16 * 1024)
			.map(func(chunk): chunk.length())
			.fold(0, func(total, n): total + n)
		Ok(n)
```

Runtime status and target:

- landed: nonblocking sockets plus a scheduler reactor using portable `poll`;
- landed: fiber parking for socket readiness in `accept`, numeric `connect`,
  `read`, and `write`;
- landed: timeout/cancellation wakeups for socket waiters;
- not landed: typed `TcpError`;
- not landed: compiler-enforced scoped resources and `with` cleanup;
- not landed: `chunks`, `lines`, and `write_all` adapters;
- not landed: nonblocking DNS or a bounded DNS worker strategy for hostname
  resolution.

Do not extend the virtual-thread-friendly claim to hostname DNS, file I/O,
database connectors, or process I/O until those operations park fibers or go
through a bounded blocking-worker path.

## Database Connector Target

Database connectors are the strongest argument for scoped resources. They have
dependent lifetimes:

```text
connection -> transaction -> statement/query -> row cursor
```

Target shape:

```blorp
with conn ?= db.connect(url):
	with tx ?= conn.transaction():
		with rows ?= tx.query("select id, name from users"):
			n ?= rows
				.filter(func(row): row.get_bool("active").get_or(False))
				.count()
			Ok(n)
```

Escape checking should reject:

```blorp
func bad(url: String) -> Result[FallibleStream[Row, DbError], DbError]:
	with conn ?= db.connect(url):
		with rows ?= conn.query("select * from users"):
			Ok(rows)
```

The returned cursor would outlive the server-side cursor or statement resource.

Concurrency rules must be connector-specific. Some connections can multiplex;
many cannot. The type/API should reflect that rather than assuming every
`DbConnection` is safe to borrow concurrently.

## Channel Streaming Target

Channels already have a good blocking story in the fiber runtime. The streaming
layer should build on that carefully.

Potential API:

```blorp
receiver(ch: Channel[T]) -> ChannelReceiver[T]
stream(self: ChannelReceiver[T]) -> Stream[T]
```

Semantics:

- receiving parks the fiber when empty;
- channel close is normal stream end;
- `Channel.close` remains an explicit semantic operation, not automatic handle
  cleanup by default;
- a channel stream should not keep the process alive after all producers are
  gone unless the channel itself is still reachable.

Avoid making `Channel[T]` itself a normal `Resource` without a clear distinction
between dropping one handle and closing the shared channel.

## Implementation Roadmap

### Phase 0: Harden Existing Stream

Goal: fix correctness bugs before adding new abstractions on top.

Completed in the current implementation:

- `Stream[T]` `for` loops emit through the runtime pull API.
- `stream.map` uses output element layout instead of inheriting input layout.
- `stream.repeat` distinguishes repeated borrowed ARC elements from owned ARC
  elements and scalar/immediate elements.
- `stream.unfold` carries explicit result-element and state layouts, including
  ARC-managed state cleanup and nullable-option tuple transfer.
- `blorp_Stream` stores one `StreamElementLayout` enum instead of independent
  `elem_is_rc` / `elem_is_owned` booleans.
- Long-running stream terminal loops include cooperative cancellation
  checkpoints.
- `from_lines` no longer truncates paths through a fixed-size stack buffer, and
  its compatibility empty-on-open-failure behavior is documented.
- Runtime, leak-check, unit, and codegen-audit coverage exists for scalar-to-RC
  and RC-to-scalar stream transforms, stream `for`, repeat/unfold layout, and
  cancellation of an infinite stream terminal.

Tasks:

- Add the new fallible file-streaming API so open/read failures are represented
  explicitly instead of reusing `from_lines`' compatibility empty-stream
  behavior.
- Audit future stream constructors and adapters so every source either has
  explicit output/state layout metadata or is clearly rejected until the
  metadata exists.
- Continue replacing compiler-to-runtime scalar layout flags with named layout
  contracts when stream APIs grow new adapters.

Tests:

- `Stream[String].map(func(s): s.length()).collect()` does not crash.
- `Stream[Int].map(func(n): n.to_string()).collect()` passes leak-check.
- `for n in from_list([1, 2, 3])` compiles and runs, or is rejected before
  codegen with a clear diagnostic.
- `from_lines` has source-audit coverage preventing fixed-size path buffers.
- Timeout/cancellation tests cover a long-running stream terminal.

### Phase 1: Add Resource And Scope Representation

Goal: represent scoped resources explicitly in syntax, typed AST, Core, and
cleanup lowering.

Completed in the current implementation:

- Parser and AST support now exists for single-binding `with` resource syntax:
  `with name = expr:`, `with name ?= expr:`, optional type annotations, and
  discard bindings.
- The parser now rejects attempted multi-binding `with` headers with a targeted
  diagnostic that points users toward nested `with` blocks for explicit close
  order.
- Acquisition expressions retain their own source location, and synthesized
  multi-statement `with` body blocks now carry the first body statement
  location so future resource diagnostics can point at acquisition and body
  failures separately.
- The AST and typed-AST compatibility layer represent the acquisition kind as
  an explicit `plain`/`try` variant instead of deriving it from punctuation or
  names later.
- Until cleanup lowering and resource escape checking exist, type inference
  rejects `with` with a targeted diagnostic so the syntax cannot reach Core
  codegen accidentally.
- Core now has an explicit `CResourceScope` node with a bound resource variable,
  committed resource type, acquisition expression, body expression, and cleanup
  expression. The node makes semantic cleanup distinct from ARC drop/release.
- Core child traversal, pretty-printers, type rewriting, monomorphization
  traversal, and Perceus ownership simulators understand `CResourceScope`.
- Core resolve and closure conversion now treat `CResourceScope` as a binding
  form: acquisition is resolved outside the new resource name, while the body
  and cleanup see the resource binding shadowing globals, imported module
  aliases, and function references.
- `Core_ssa` now treats `CResourceScope` as a binding form for mutable-local
  classification and substitution: acquisition remains in the outer scope,
  while body and cleanup are protected by the resource binding.
- Binding-sensitive Core utilities now have focused resource-scope coverage:
  module flattening preserves the local resource binding while rewriting outer
  globals and resource types, std inlining alpha-renames cloned resource
  binders, and tailrec list-spread analysis ignores uses shadowed by a resource
  binding.
- `Core_match` list-spread pruning now treats resource scopes as binding forms:
  acquisition can still use an outer spread binding, while body and cleanup uses
  of the resource name are scoped to the resource.
- `Core_trait_resolve` now treats resource scopes as binding forms, so trait
  method rewrites still apply to acquisition expressions outside the resource
  binding while body and cleanup expressions respect the new local name.
- Fusion/specialization helpers now treat resource scopes as explicit
  boundaries where they carry binding or hoisting state: collection callback
  capture analysis respects resource binders, tuple SROA does not scalar-replace
  through resource cleanup scopes, and raw tensor view collection/rewrite does
  not hoist views into or out of resource scopes.
- `Core_reuse` treats `CResourceScope` as an allocation-reuse barrier, so reuse
  decisions are not scanned or rewritten across semantic cleanup boundaries.
- `Core_codegen_prepare` clears binding-sensitive tensor storage provenance for
  resource-scope bodies and cleanup, so proofs from an outer value cannot leak
  through a shadowing resource binding.
- `Core_emit_util.collect_free_vars` treats resource scopes as binding forms,
  preserving acquisition-side free variables while preventing body/cleanup uses
  of the resource binder from leaking into emitter capture sets.
- Resource-scope invariants check that acquisition produces the committed
  resource type, the scope returns the body type, and cleanup returns `Void`.
  Final Core still rejects `CResourceScope` until backend cleanup emission is
  implemented.

Tasks:
- Type inference:
  - require the bound value to be a resource type;
  - track scoped resource identifiers;
  - track values derived from scoped resources;
  - reject scoped values escaping the block;
  - reject `detach` captures of scoped values.
- Core:
  - lower typed `with` to `CResourceScope`;
  - continue the pass audit before allowing source-level `with` to reach Core,
    with SSA shadowing, closure-conversion captures, call resolution, module
    flattening, trait-method resolution, std inlining, tailrec list-spread use
    analysis, match list-spread free-variable pruning, reuse barriers,
    collection callback capture analysis, tuple SROA barriers, raw tensor view
    specialization barriers, and codegen-prepare storage-provenance shadowing
    plus emitter free-variable collection now covered by focused regressions;
  - preserve `CResourceScope` through desugar, match, resolve, tailrec, fusion,
    specialize, reuse, and closure once lowering is enabled;
  - make early exits route through cleanup with explicit Core, preferably in a
    dedicated cleanup/resource pass when `break`/`continue` or cancellation
    require nonlocal exit rewriting;
  - make cancellation cleanup compatible with Perceus drops without confusing
    semantic `close` with ARC release.
- Invariants:
  - add stage checks for resource escape, duplicated cleanup edges, unresolved
    cleanup callees, and illegal scoped captures;
  - keep final safety checks strict so invalid or unemitted resource Core cannot
    reach C emission when development invariant checking is disabled.
- Codegen:
  - emit cleanup only from explicit Core cleanup nodes;
  - emit exactly-once cleanup on all normal and nonlocal exits;
  - preserve reverse close order for nested resources.

Tests:

- parser `should_pass` and `should_fail` for syntax;
- typecheck rejection for returning a resource;
- typecheck rejection for returning a derived stream;
- typecheck rejection for storing a resource in a record/list/global;
- typecheck rejection for detached capture;
- runtime test proving close runs on normal body completion;
- runtime test proving close runs on `?=` short-circuit;
- runtime test proving close runs on `break`/`continue`;
- runtime test proving close runs on timeout cancellation;
- `--dump-core-after` or codegen-audit coverage proving the resource scope is
  visible in Core before emission;
- codegen audit proving cleanup emission is present and ordered.

### Phase 2: Typed File Resources

Goal: introduce typed file handles without breaking existing `system` helpers.

Tasks:

- Add `std/file.brp` or `std/fs.brp`.
- Add `IOError`.
- Add resource types:
  - `FileReader`;
  - `FileWriter`;
  - `File`.
- Add open helpers:
  - `open_read`;
  - `open_write`;
  - `open_append`;
  - `open_read_write`;
  - advanced `open(path, options)`.
- Add runtime handle objects with destructors.
- Use exact path buffers; no fixed-size path truncation.
- Prefer file descriptors or platform handles over `FILE*` for the new layer.
- Keep existing `std/system.brp` helpers as compatibility wrappers for now.

Tests:

- open missing file returns `Err(NotFound(...))`;
- open permission failure returns `Err(PermissionDenied(...))` where portable;
- write/truncate/append/create semantics;
- read/write invalid operation rejected by type checker;
- handle close runs exactly once;
- leak-check for early-exit `with` blocks.

### Phase 3: Chunked Readers And Fallible Streams

Goal: make streaming file processing efficient and fully fallible.

Tasks:

- Add `FallibleStream[T, E]`.
- Add fallible stream terminal operations returning `Result`.
- Add chunked file reader:
  - default chunk size around 64 KiB;
  - optional user-provided chunk size validation/normalization;
  - preserve correctness across chunk boundaries.
- Add line decoder over chunks.
- Add fast `count_lines` using chunk scanning.
- Add byte/window adapters over chunks.
- Add cancellation/yield checks in fallible stream terminal loops.

Tests:

- `count_lines` handles empty files, trailing newline, no trailing newline,
  CRLF, and long lines crossing chunk boundaries;
- `chunks` returns expected bytes without losing boundaries;
- `lines().collect()` handles lines crossing chunk boundaries;
- mid-read error path closes the handle and returns `Err`;
- cancellation closes the handle;
- line counting allocates substantially less than `read_all_lines().length()`.

### Phase 4: TCP Resources And Fiber-Aware I/O

Goal: finish layering scoped resources and streaming ergonomics on top of the
typed, nonblocking TCP handles that now exist.

Completed in the current implementation:

- Public APIs use `TcpListener` and `TcpStream` instead of raw `Int` socket
  descriptors.
- Socket operations use nonblocking fds and a poll-backed scheduler reactor for
  readiness waits.
- `accept`, numeric `connect`, `read`, and `write` can park virtual threads
  while waiting on socket readiness.
- Timeout and cancellation paths wake parked TCP waiters.
- Typecheck regressions reject raw `Int` values passed to the public TCP API.

Tasks:

- Make `TcpListener` and `TcpStream` compiler-scoped resource types once `with`
  exists.
- Replace `String` errors with a typed `TcpError` or an explicit error
  conversion story compatible with `?=`.
- Add stream adapters for chunks and lines.
- Add `write_all` as a protocol-friendly loop over partial writes.
- Decide the DNS story:
  - document numeric hosts as the virtual-thread-friendly path;
  - add a bounded DNS worker pool; or
  - add a platform-specific async resolver abstraction.
- Decide whether and when the poll reactor should grow `kqueue`/`epoll`
  backends. The active backend must not claim native support until the native
  loops are implemented and tested.

Tests:

- accept/connect/read/write close handles exactly once;
- timeout/cancellation closes or detaches handles according to documented
  semantics;
- many sleeping or blocked numeric-address TCP fibers do not occupy one OS
  worker each;
- stream chunking preserves byte content.

### Phase 5: Channel And Pipeline Integration

Goal: make channels and streams compose without blurring their lifecycle rules.

Tasks:

- Add explicit channel receiver stream APIs.
- Decide whether a receiver is a scoped value, a normal handle, or just a view.
- Ensure channel stream terminal loops park fibers via channel recv.
- Preserve channel close semantics as explicit producer-side signaling.

Tests:

- stream over channel exits on close;
- stream over channel parks fibers rather than blocking workers;
- cancellation removes waiters from channel queues;
- no leak when a channel stream is dropped before the channel closes.

### Phase 6: Database And Package Connector Guidance

Goal: ensure optional native-backed packages use the same resource model.

Tasks:

- Document package connector rules:
  - connection, transaction, statement, and row cursor resources;
  - row streams scoped to query/transaction/connection;
  - connector-specific concurrency safety.
- Add sample connector tests with fake native handles before real database
  bindings rely on the model.

Tests:

- returned row cursor escape is rejected;
- transaction closes after row cursor;
- connection closes after transaction;
- query error propagates through fallible stream terminals.

### Phase 7: Documentation And Migration

Goal: make the new model easy to learn and avoid silent behavior drift.

Tasks:

- Update `docs/GUIDE.md`:
  - `with` syntax;
  - scoped resource rule;
  - file streaming examples;
  - fallible streams;
  - interaction with `?=`.
- Update `docs/GRAMMAR.md`.
- Update `docs/ARCHITECTURE.md` with new pipeline/Core stages.
- Update std docs and doctests.
- Mark lossy compatibility APIs clearly:
  - empty-on-failure;
  - `Bool` instead of `Result`;
  - whole-file materialization.

Migration examples:

```blorp
-- Old, eager
lines = read_all_lines(path)
lines.length()

-- New, streaming
with reader ?= path.open_read():
	n ?= reader.lines().count()
	Ok(n)
```

```blorp
-- Pre-typed TCP, raw descriptor
fd ?= tcp.connect(host, port)
data ?= tcp.read(fd, 4096)
tcp.close(fd)
Ok(data)

-- Current typed handle
stream ?= tcp.connect(host, port)
data ?= stream.read(4096)
stream.close()
Ok(data)

-- Future scoped typed handle
with stream ?= tcp.connect(host, port):
	data ?= stream.read_chunk(4096)
	Ok(data)
```

## Validation Checklist For Each Slice

Every implementation slice should include:

- Parser or typecheck tests for rejected invalid states.
- Runtime tests for successful behavior.
- Leak-check tests for resource cleanup.
- Codegen audit when cleanup lowering or ownership layout changes.
- Cancellation/timeout tests for any blocking operation.
- Documentation updates when the user-facing API changes.

Do not rely on naming heuristics such as "functions called `lines` return scoped
streams". Scope must be represented in AST/type metadata or Core.

Do not implement resource cleanup only as a destructor fallback. ARC destructors
are useful as a last line of defense, but the source-level guarantee should be
deterministic cleanup at the `with` boundary.

Do not claim an operation is virtual-thread friendly unless it parks the fiber
or goes through a bounded blocking-worker path.

## Open Questions

These should remain explicit until implementation forces an answer:

- Should the public module be named `file`, `fs`, or something else?
- Should `FallibleStream` be a distinct builtin type, or should it be encoded as
  a generic cursor protocol with fallible terminal operations?
- Should `with` eventually support multiple bindings in one header?
- Should scoped resources support explicit moves in a later affine-value model?
- What should borrowed resource parameter syntax look like for user functions?
- How much runtime idempotence should `close` provide beyond the static
  exactly-once cleanup guarantee?
- Should channel receiver streams be scoped resources, normal values, or a
  distinct receive capability?
- Should the current portable `poll` TCP reactor grow `kqueue`/`epoll` backends
  before workloads prove it necessary?
- What is the DNS strategy for hostname TCP operations: keep the blocking
  behavior explicit, use a bounded resolver pool, or add an async resolver
  abstraction?

## Recommended Next Work

The highest-ROI path is:

1. Harden current `Stream[T]` correctness.
2. Finish the `with` typed resource/Core cleanup model with a tiny fake
   resource used only for tests.
3. Build typed file resources on top of `with`.
4. Add chunked file reading and `FallibleStream`.
5. Layer scoped cleanup, typed errors, and stream adapters on top of the current
   typed nonblocking TCP handles.

This order keeps correctness ahead of ergonomics. It also prevents the new
streaming API from being built on today's known unsound stream ownership and
resource-lifetime gaps.
