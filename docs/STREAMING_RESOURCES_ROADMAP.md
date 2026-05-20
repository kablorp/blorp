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
		reader.count_lines()
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
ordinary copyable parameters. Blorp now has an explicit first step for
source-defined helpers that borrow a scoped resource for one synchronous call:

```blorp
func count_open(reader: borrow FileReader) -> Result[Int, IOError]:
	reader.lines().count()
```

Current rules are deliberately narrow:

- `borrow` parameters are valid only on source functions with bodies;
- the parameter type must be a direct `resource type`, not a container that
  contains a resource;
- the function is treated as returning ordinary data only after its visible body
  type-checks;
- dependent stream/cursor returns from source-defined borrowed helpers are still
  future work because scope must be represented explicitly in the returned
  value.

The invariant is:

```text
passing a resource to a function must not copy it or let it escape
```

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
- `Core_resource`:
  - rewrite `break` and `continue` that leave one or more active resource
    scopes into explicit cleanup-exit Core;
  - keep loop-local `break` and `continue` inside nested loops plain, because
    the surrounding resource scope still completes normally after the loop;
  - preserve innermost-first cleanup order for nested resource scopes.
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

The current implementation uses a small `Core_resource` pass after closure
conversion and before final codegen preparation. It lowers resource-scope
`break` and `continue` exits to `CResourceCleanupExit` nodes instead of teaching
unrelated emitter branches to remember resource state implicitly. Timeout and
structured-concurrency cancellation are handled by registering the same semantic
resource finalizer from `CResourceScope` with the task cancellation cleanup
stack, then popping that registration before normal cleanup or cleanup-exit
control flow. Future true nonlocal early-propagation work should extend this
same explicit cleanup-edge model rather than adding parallel cleanup mechanisms.
If a new observed stage is added later, update `Core_stage`,
`Core_pipeline.observed_stage_order`, `docs/ARCHITECTURE.md`, and the stage
round-trip tests in the same slice.

Required Core invariants:

- No scoped resource or scoped-derived value appears in a global initializer,
  heap container literal, returned value, detached task capture, or closure
  capture.
- Every `CResourceScope` has exactly one cleanup operation for the acquired
  resource.
- Cleanup callees are resolved before final emission.
- `CResourceScope` cannot survive in a form where a pass has duplicated its
  body without duplicating and re-proving the cleanup edge.
- `CResourceCleanupExit` must contain at least one cleanup action, have `Void`
  type, and contain only `Void` cleanup actions.
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
resource type FileReader = builtin("blorp_file_close_reader")
resource type FileWriter = builtin("blorp_file_close_writer")
resource type File = builtin("blorp_file_close")
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
count_lines(self: FileReader) -> Result[Int, IOError]
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

`count_lines` uses a chunk scanner and does not allocate a `String` per line.

### Write API

```blorp
write_chunk(self: FileWriter, data: Bytes) -> Result[Int, IOError]
write_bytes(self: FileWriter, data: Bytes) -> Result[Void, IOError]
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
read_text_rw(self: File) -> Result[String, IOError]
read_bytes_rw(self: File) -> Result[Bytes, IOError]
read_chunk_rw(self: File, max_bytes: Int) -> Result[Bytes, IOError]
count_lines_rw(self: File) -> Result[Int, IOError]
write_text_rw(self: File, text: String) -> Result[Void, IOError]
write_bytes_rw(self: File, data: Bytes) -> Result[Void, IOError]
write_chunk_rw(self: File, data: Bytes) -> Result[Int, IOError]
flush(self: File) -> Result[Void, IOError]
```

Avoid C stdio read/write switching pitfalls by implementing these handles on
file descriptors or platform equivalents, not `FILE*`, once this layer exists.
If buffering is added on top, the buffer state must make read/write transitions
explicit and tested.

The current implementation uses explicit `*_rw` names for `File` operations.
This is less elegant than sharing `read_text`/`write_text`, but it keeps the
permission model type-safe without relying on same-module overloads that Blorp
does not support yet.

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
- `Stream[T]` and `FallibleStream[T, E]` are now treated as one-shot cursor
  carriers by inference. The compiler rejects capturing stream values in
  closures, `detach`, `concurrent:`, and `concurrent for` task bodies, including
  aliases or aggregates that contain streams.
- The compiler rejects storing `Stream`/`FallibleStream` values in ordinary
  aggregate literals and declarations: tuples, lists, dicts, records, structs,
  and unions cannot hide one-shot cursor state. Direct local stream bindings and
  pipeline reassignment remain allowed.
- Global `Stream`/`FallibleStream` bindings are rejected so mutable cursor state
  cannot become shared program state.
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
- Decide whether normal local aliases of stream values should require a future
  explicit consume/affine model. Aggregate storage is now rejected, but direct
  local bindings are still intentionally allowed so pipeline construction stays
  ergonomic.

Tests:

- `Stream[String].map(func(s): s.length()).collect()` does not crash.
- `Stream[Int].map(func(n): n.to_string()).collect()` passes leak-check.
- `for n in from_list([1, 2, 3])` compiles and runs, or is rejected before
  codegen with a clear diagnostic.
- `from_lines` has source-audit coverage preventing fixed-size path buffers.
- Timeout/cancellation tests cover a long-running stream terminal.
- Closure, `detach`, `concurrent:`, and `concurrent for` bodies reject captured
  `Stream`/`FallibleStream` values while still allowing streams created and
  consumed wholly inside the task.
- Tuple/list/dict/record/union storage of `Stream`/`FallibleStream` values is
  rejected, while direct local stream bindings remain accepted.
- Top-level `Stream`/`FallibleStream` bindings are rejected.

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
- `resource type Name = builtin` is parsed, formatted, represented in type
  declarations, and registered in the environment as an explicit resource type
  kind instead of a name-based convention. Resource declarations can also carry
  std-only cleanup metadata as `builtin("c_cleanup_name")`; typechecking stores
  that metadata in the session and Core lowering consumes it when building
  cleanup edges.
- Resource cleanup metadata follows the same session lifecycle as module-loaded
  type and trait indexes: `Modules.reset` clears the registry, and unit coverage
  prevents cleanup metadata from leaking across reset boundaries.
- Type inference now validates `with` acquisitions against explicit resource
  types, binds the resource only inside the `with` body, preserves the checked
  resource type on the typed binding, and rejects directly returning a resource
  or resource-containing type from the `with` body.
- Core now has an explicit `CResourceScope` node with a bound resource variable,
  committed resource type, acquisition expression, body expression, and cleanup
  expression. The node makes semantic cleanup distinct from ARC drop/release.
- Core lowering now lowers typed plain `with` to `CResourceScope` and lowers
  fallible `with ?=` through a carrier match whose success arm owns the
  resource cleanup scope. Wildcard guards receive compiler-generated resource
  names so cleanup still has a stable target.
- Core lowering shares one explicit `Option`/`Result` carrier classifier for
  direct `?=` and fallible `with ?=`, and unit coverage now proves a body-level
  `?=` continuation stays inside the successful resource scope. Because direct
  `?=` is currently continuation-shaped rather than a true nonlocal exit,
  normal `CResourceScope` cleanup still owns both success and carrier-failure
  body results.
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
  Final Core now permits well-formed `CResourceScope` on normal completion
  paths; it still rejects `break` and `continue` that would exit the resource
  scope until a cleanup-edge rewriting pass can preserve cleanup across those
  nonlocal exits. Loop-local `break` and `continue` inside a nested loop are
  allowed because normal cleanup still runs after that loop completes.
- Resource-scope invariants now also require cleanup to be one direct
  finalizer call whose sole argument is the scoped resource binding. `Void`
  placeholders, multi-argument cleanup calls, and cleanup calls on unrelated
  values are rejected before backend emission.
- Resource-scope invariants reject Core where the scope body returns a
  resource-containing type. This keeps the Core contract aligned with typed
  inference: scoped capabilities may be used inside a `with`, but the scope
  result must be ordinary data.
- Resource-scope and closure/task capture invariants now use an explicit Core
  aggregate-component map plus alias-only type normalization for resource
  containment checks, so records and unions whose fields or payloads contain
  resources are caught structurally without depending on codegen layout
  registry construction.
- Closure/task metadata invariants reject resource-containing captures in
  `CClosureCreate`, closure ABI metadata, and task closure metadata. This makes
  scoped-resource capture rejection a Core contract as well as a source
  typechecking rule.
- Type inference now records a `with`-bound resource identifier as a scoped
  resource binding in the environment. This makes the capability distinction
  explicit instead of recovering it from names or surrounding syntax.
- The type checker rejects ordinary local bindings that would copy a resource
  value out of the scoped binding, including implicit local declarations,
  explicit `var` declarations, and tuple destructuring.
- The type checker rejects closures and `detach` bodies that capture a scoped
  resource binding. This closes the immediate lifetime hole where deferred work
  could retain a resource after the `with` cleanup boundary.
- The type checker rejects passing a resource value to an ordinary source-level
  call. Source functions may opt into a checked borrow with `param: borrow
  ResourceType`; compiler-owned builtin operations continue to use explicit
  resource-operation metadata.
- The type checker rejects non-builtin function signatures whose by-value
  parameters or return type contain concrete resources. Borrowed source
  parameters must name a direct resource type, must have a function body, and
  cannot make a resource or scoped-derived value escape through the return.
- Collection literal inference rejects resource elements directly, so a
  resource cannot be placed into a list, dict, set, or tensor/vector literal
  even when the literal is immediately discarded rather than assigned.
- Tuple literal inference and record field inference reject resource elements
  directly, and top-level variable finalization rejects resource-typed globals.
  Resource capabilities now stay out of the ordinary heap-shaped value graph in
  the direct source forms the compiler currently knows how to check.
- Resource-containing type detection now follows record field types and union
  payload types, including generic substitutions, rather than only direct named
  resource types and type arguments. This closes the hole where a builtin could
  return a named aggregate whose fields or payloads contained a resource and
  have it treated as ordinary copyable data.
- Type checking now rejects record/struct fields and union payload declarations
  whose types contain resources. Resource-bearing aggregate shapes are rejected
  before they can reach Core layout metadata or generated-code preparation.
- Statement-position inference rejects discarded resource-containing values,
  including explicit `_ = ...` discards. This closes the path where a resource
  acquisition result or fallible acquisition carrier could be created without a
  `with` cleanup edge.
- Constructor calls use ordinary call inference for their payloads, so
  `Some(handle)`-style attempts to wrap a scoped resource are rejected by the
  same resource-argument rule as user-defined calls.
- Function metadata now carries an explicit resource-argument policy. Ordinary
  source functions reject resource arguments because parameters copy values;
  compiler-owned builtin operations may opt into resource arguments without
  reusing the broader builtin/user/foreign origin tag.
- Builtin origin no longer implies the resource-argument opt-in. Function
  registration defaults to rejecting resource arguments, so compiler-owned
  resource operations must carry an explicit borrow policy.
- The compiler-owned resource-operation policy now includes an explicit result
  policy. Resource operations default to returning scoped-dependent values, and
  `@resource_result_ordinary` marks builtin operations whose result is ordinary
  data that may escape the `with` body when its type contains no resource.
- The type checker rejects `@resource_result_ordinary` on non-builtin source or
  foreign functions. Source borrowed-resource helpers do not need the annotation:
  their visible bodies are checked directly and are registered as returning
  ordinary data.
- The type checker also rejects `@resource_result_ordinary` on builtin
  declarations with no direct resource parameter. Resource-containing container
  parameters do not opt a builtin into resource-operation metadata because the
  current borrow model only accepts direct `with` bindings. The pre-scan of
  local resource type names keeps validation declaration-order independent.
- The type checker marks local bindings, tuple destructuring bindings, and
  `?=` bindings as scoped-resource-derived when their value expression refers
  to a scoped resource or another derived value. Final block expressions,
  closures, and `detach` bodies reject those scoped-derived values so cursors,
  streams, and similar dependent values cannot outlive the owning `with`.
- The type checker now also validates scoped-derived body results at the `with`
  boundary itself. This closes the single-statement body hole where
  `with handle = ...: cursor_from(handle)` was represented as a bare call
  rather than an `EBlock`, so it bypassed final-block escape checking.
- Mutable assignment now rejects both resource-containing values and
  scoped-resource-derived values. Until operation result metadata can
  distinguish ordinary data from dependent scoped values, mutable slots are
  treated as possible scope-escape boundaries rather than trying to propagate
  lifetime facts through assignment side effects.
- `concurrent:` and `concurrent for` task bodies now reject captures of scoped
  resources and scoped-resource-derived values. Concurrent task result types
  also cannot contain resources, so structured task joins cannot create
  ordinary `Result[Resource, ConcurrencyError]` values without an explicit
  cleanup owner.
- Ordinary calls now reject scoped-resource-derived arguments as well as direct
  resource arguments. This keeps a dependent cursor, stream, or borrowed value
  from losing its scoped-origin fact when copied into a normal source function
  parameter or constructor payload, including inline values computed directly
  from a scoped resource.
- Aggregate construction now rejects scoped-resource-derived values in tuple
  literals, collection literals, record literals, record update fields, and
  record update bases. This keeps dependent cursors, streams, and borrowed
  values out of ordinary copyable containers until resource operation result
  metadata can prove a value is ordinary data.
- Compiler-owned resource operations now require resource-containing arguments
  to be direct `with`-scoped bindings. A fresh resource-producing expression
  such as `use(open_resource())` is rejected because the operation borrows the
  resource but does not own its cleanup edge.
- The C emitter now emits normal-completion cleanup directly from explicit
  `CResourceScope` cleanup nodes in both expression and statement contexts.
  Normal completion remains represented by `CResourceScope`; nonlocal loop
  control exits use a separate explicit cleanup-exit node.
- Final Core nonlocal-exit checks are now control-flow aware enough to
  distinguish resource-scope exits from `break` and `continue` captured by a
  nested loop inside the resource body.
- `Core_resource` now rewrites active resource-scope `break` and `continue`
  exits into `CResourceCleanupExit`, preserving innermost-first cleanup order
  for nested scopes while leaving loop-local exits inside nested loops as plain
  loop control.
- Final Core invariants now accept rewritten cleanup exits and reject malformed
  cleanup exits with no cleanup stack, non-`Void` type, or non-`Void` cleanup
  actions. The emitter prints cleanup-exit nodes directly before the final
  `break` or `continue`.
- The C emitter now registers each resource scope's semantic finalizer with the
  task cancellation cleanup stack. Normal completion and cleanup-exit control
  flow pop that registration before running the normal finalizer, while timeout
  and structured-concurrency cancellation run the registered finalizer before
  unwinding the task.

Tasks:
- Type inference:
  - audit remaining non-literal producers for diagnostics and regression
    coverage;
  - extend borrowed-resource parameter metadata from the current ordinary-result
    source-helper model to an explicit scoped-dependent return contract before
    source helpers can define cursor or stream producers;
  - apply the explicit operation result metadata to future file/TCP/database
    APIs: chunk reads, counts, and whole-resource reads should be marked
    ordinary when they return plain data, while cursor/stream adapters should
    keep the default scoped-dependent policy.
- Core:
  - continue the pass audit as source-level `with` reaches Core for
    resource-typed acquisitions, with SSA shadowing, closure-conversion
    captures, call resolution, module flattening, trait-method resolution, std
    inlining, tailrec list-spread use analysis, match list-spread free-variable
    pruning, reuse barriers, collection callback capture analysis, tuple SROA
    barriers, raw tensor view specialization barriers, and codegen-prepare
    storage-provenance shadowing plus emitter free-variable collection now
    covered by focused regressions;
  - preserve `CResourceScope` through desugar, match, resolve, tailrec, fusion,
    specialize, reuse, and closure once lowering is enabled;
  - extend the explicit `Core_resource` cleanup-exit model from
    `break`/`continue` to future true nonlocal early-propagation paths if the
    language grows one;
  - keep cancellation cleanup registration derived from the direct-finalizer
    resource-scope invariant, without confusing semantic `close` with ARC
    release.
- Invariants:
  - unresolved cleanup callees are covered by the existing post-specialize
    `CKUnknown` invariant as long as resource-scope children remain traversed;
  - continue adding stage checks if new scoped-resource carriers are introduced
    after typed inference or closure conversion;
  - keep final safety checks strict so invalid or unemitted resource Core cannot
    reach C emission when development invariant checking is disabled.
- Codegen:
  - normal-completion cleanup is emitted only from explicit Core cleanup nodes;
  - keep `break`/`continue` cleanup emission explicit through
    `CResourceCleanupExit`;
  - keep cancellation cleanup stack registration and pop points in sync with
    `CResourceScope` and `CResourceCleanupExit`;
  - extend exactly-once cleanup to future true nonlocal early propagation;
  - preserve reverse close order for nested resources.

Tests:

- parser `should_pass` and `should_fail` for syntax;
- typecheck rejection for returning a resource;
- typecheck rejection for returning a derived stream;
- typecheck rejection for storing a resource in a tuple/record/list/global;
- typecheck rejection for detached capture;
- unit coverage for ordinary local copies, tuple destructuring, closure
  captures, and direct `detach` captures of a scoped resource binding;
- unit coverage for rejecting resource arguments to ordinary user-defined
  calls and constructor payloads, including scoped-resource-derived arguments;
- unit coverage for rejecting fresh resource-producing expressions passed
  directly to compiler-owned resource operations;
- unit coverage for rejecting list literal storage, tuple literal storage,
  record literal storage, record update storage, and global binding of scoped
  resource values, including scoped-resource-derived aggregate elements and
  record update bases;
- unit coverage proving named records with resource fields and unions with
  resource payloads are rejected when resource-containing aggregate values are
  bound as ordinary locals;
- unit coverage for rejecting discarded resource values and discarded fallible
  resource carriers;
- unit coverage for rejecting scoped-derived local escapes, closure captures,
  and `detach` captures;
- unit coverage proving builtin resource operations can mark ordinary-data
  results as escapable, inline ordinary results can enter ordinary calls in
  both direct-call and UFCS form, and unmarked dependent results still cannot
  escape;
- unit coverage proving unmarked dependent results cannot escape from
  single-statement `with` bodies;
- unit coverage proving `@resource_result_ordinary` is limited to builtin
  operations with direct resource parameters, including forward-declared local
  resource types and rejecting resource-containing container parameters;
- unit coverage proving body-level `?=` lowering remains inside the successful
  resource scope for fallible `with ?=`;
- unit coverage for rejecting scoped-resource captures in `concurrent:` and
  `concurrent for`, plus resource-containing concurrent task results;
- runtime test proving close runs on normal body completion;
- runtime semantics coverage and codegen-audit coverage proving cleanup wraps
  body-level `?=` short-circuit paths for user-facing resource-backed APIs;
- unit coverage proving `break`/`continue` cleanup exits are represented in
  Core and emitted in C with reverse nested-resource close order;
- source-level runtime `break`/`continue` coverage remains pending because the
  current user-facing file acquisitions are fallible `with ?=` forms, and
  `with ?=` is rejected directly inside loop bodies. Core_resource unit tests
  and codegen audits cover cleanup-exit lowering until Blorp has a plain
  resource acquisition or a resource-aware loop acquisition shape.
- runtime test proving close runs on timeout cancellation;
- codegen audit proving cancellation cleanup registration and normal pop are
  emitted from explicit resource cleanup metadata;
- `--dump-core-after` or codegen-audit coverage proving the resource scope is
  visible in Core before emission;
- unit invariant coverage proving resource-scope body types are rejected when a
  named record field or union payload contains a resource;
- unit coverage proving source aggregate declarations cannot embed resource
  types in record/struct fields or union payloads;
- unit emitter coverage proving normal-completion cleanup emission is present
  and ordered in expression and statement contexts, including loop-local
  `break`/`continue` where cleanup runs after the nested loop;
- codegen audit proving cleanup emission is present and ordered, including a
  source-level file-resource case where loop-local `break`/`continue` occur
  inside the resource body.

### Phase 2: Typed File Resources

Goal: introduce typed file handles without breaking existing `system` helpers.

Completed in the current implementation:

- `std/file.brp` defines a typed `IOError` union, stable `message` helper, and
  `Stringable` implementation. This gives file-resource APIs a typed error
  surface instead of stringly typed system errors.
- `std/file.brp` defines opaque resource type anchors for `FileReader`,
  `FileWriter`, and `File`, each with explicit compiler-owned cleanup metadata.
- `open_read(path)` returns `Result[FileReader, IOError]`, `open_write(path)`
  returns `Result[FileWriter, IOError]`, `open_append(path)` returns
  `Result[FileWriter, IOError]`, and `open_read_write(path)` returns
  `Result[File, IOError]`. These are backed by runtime file-descriptor handles.
  The implementation uses exact path buffers and rejects empty or interior-NUL
  paths as `InvalidInput`.
- The write-mode opens now cover the first permission-specific resource split:
  `open_write` creates/truncates, `open_append` creates/preserves existing
  contents, and `open_read_write` requires an existing path and preserves file
  contents.
- The generated-C bridge converts runtime file-open error facts into the
  source-level `IOError` union before wrapping them in `Result.Err`. This keeps
  the public API typed while avoiding a runtime dependency on generated union
  constructor names.
- `read_text(reader)` and `write_text(writer, text)` are now
  permission-specific compiler-owned resource operations. They borrow direct
  `FileReader` and `FileWriter` scoped bindings, convert runtime file errors to
  typed `IOError`, and mark their successful results as ordinary data that may
  leave the `with` body.
- `with reader ?= open_read(path): ...` now works when `open_read` is imported
  selectively, and `with reader ?= F.open_read(path): ...` works with qualified
  module imports. The type checker registers canonical resource types used by
  imported or qualified resource APIs without exposing accidental bare aliases.
- Core lowering now reconstructs `Result.Err` carriers for `?=` failure paths
  instead of reusing the right-hand-side `Result` when the success type changes.
  This matters for resource acquisition because the opened handle has a
  different success type than the enclosing computation.
- File-resource cleanup is emitted through compiler-owned runtime builtins
  registered from the resource type declaration, so scoped cleanup does not
  depend on importing a source-level `close` function or matching file-resource
  names in codegen.
- Compiler integration coverage proves explicit cleanup metadata remains
  std-only; user modules cannot declare `resource type Name =
  builtin("cleanup")`.
- File finalizers are private module internals. Selective `file: close` imports
  are rejected, and module-qualified calls do not fall back to unrelated bare
  functions when the module has no exported function by that name.
- Typecheck integration tests prove imported std file resources can be named in
  type positions and still cannot be embedded in record fields or union
  payloads.
- Typecheck integration tests also prove ordinary source functions cannot take
  or return `FileReader`-containing values. File handles must enter user code
  through compiler-owned resource acquisition and stay scoped by `with`.
- Runtime coverage proves a body-level `?=` inside a file-resource `with`
  returns the enclosing `Err` correctly, and codegen-audit coverage proves the
  file cleanup still wraps that body short-circuit path.
- Runtime coverage proves write-mode acquisition semantics for create,
  truncate, append/preserve, and existing-only read-write opens. Codegen-audit
  coverage proves `FileWriter` and `File` cleanup metadata emits the matching
  finalizers.
- Runtime coverage proves text written through a scoped `FileWriter` can be
  read back through a scoped `FileReader`. Typecheck coverage rejects the
  invalid permission states of reading from a writer and writing through a
  reader. Codegen-audit coverage proves file text operations use the explicit
  resource-operation bridge and still emit scoped cleanup.
- `read_bytes(reader)` and `write_bytes(writer, data)` are now
  permission-specific compiler-owned resource operations with the same typed
  `IOError` bridge and ordinary-result escape behavior as the text operations.
  Runtime coverage proves bytes written through a scoped writer can be read
  back through a scoped reader. Typecheck coverage rejects reading bytes from a
  writer and writing bytes through a reader.
- `write_chunk(writer, data)` is now a permission-specific compiler-owned
  resource operation that performs one runtime write attempt and returns the
  number of bytes written. `write_bytes` remains the write-all helper.
- Read-write `File` handles now have an explicit operation surface:
  `read_text_rw`, `read_bytes_rw`, `read_chunk_rw`, `count_lines_rw`,
  `write_text_rw`, `write_bytes_rw`, and `write_chunk_rw`. These use the same
  typed `IOError` bridge and current-offset file-descriptor semantics as the
  permission-specific reader/writer operations. The `*_rw` suffix is a
  deliberate interim naming choice until call resolution supports a cleaner
  overload or trait-dispatch story.
- The private-finalizer policy is now general for std-owned resource
  declarations: `resource type Name = builtin("c_cleanup_name")` records
  explicit compiler cleanup metadata, and `with` lowering emits that metadata
  rather than using resource-name or module-specific heuristics. Future TCP and
  package resources should reuse this declaration-level model.

Tasks:

- Add advanced `open(path, options)` once there is a typed options shape whose
  invalid states are represented explicitly.
- Keep existing `std/system.brp` helpers as compatibility wrappers for now.

Tests:

- open missing file returns `Err(NotFound(...))`;
- open permission failure returns `Err(PermissionDenied(...))` where portable;
- write/truncate/append/create semantics;
- text and byte read/write invalid operations rejected by type checker;
- byte write/read round-trip through scoped handles;
- chunk write returns the number of bytes written and rejects reader handles at
  typecheck time;
- read-write handles support text, byte, chunk, and line-count operations and
  reject reader/writer-only handles for `*_rw` calls;
- handle close runs exactly once;
- leak-check for early-exit `with` blocks.

### Phase 3: Chunked Readers And Fallible Streams

Goal: make streaming file processing efficient and fully fallible.

Completed in the current implementation:

- Added `FallibleStream[T, E]` as a distinct builtin stream carrier for
  sources that can fail while pulling.
- Added `collect_result(self: FallibleStream[T, E]) -> Result[List[T], E]` as
  the first fallible terminal operation. The name is intentionally distinct for
  now because same-module overloads are not available yet.
- Added streaming fallible terminals for `fold_result`, `count_result`,
  `find_result`, `any_result`, and `all_result`. They stop at the first source
  error, return `Result`, and include cooperative cancellation checkpoints in
  their pull loops. `find_result` uses an explicit
  `Result[Option[T], E]` bridge ABI for nullable-managed options and primitive
  stack-option payloads.
- Hardened `collect_result` so the runtime list it returns uses the concrete
  `List[T]` storage layout selected by the compiler. Inline primitive lists
  such as `List[UInt8]` are no longer accidentally produced as pointer-backed
  lists.
- Added `read_chunk(self: FileReader, max_bytes: Int) -> Result[Bytes, IOError]`.
  It advances the scoped reader, returns empty bytes at EOF, and rejects
  non-positive sizes with `Err(InvalidInput(...))`.
- Added `chunks(self: FileReader) -> FallibleStream[Bytes, IOError]` with a
  default 64 KiB runtime chunk size.
- Added `chunks_with_size(self: FileReader, chunk_size: Int) ->
  FallibleStream[Bytes, IOError]` for explicit chunk sizing. Non-positive
  sizes surface as `Err(InvalidInput(...))` from terminal operations.
- Added `lines(self: FileReader) -> FallibleStream[String, IOError]` using the
  same chunked file reader foundation. It handles lines crossing chunk
  boundaries and returns strings without trailing `\n` or `\r\n`.
- Added `count_lines(self: FileReader) -> Result[Int, IOError]`, a chunk
  scanner that counts remaining file lines without allocating one `String` per
  line.
- Added `bytes(self: FileReader) -> FallibleStream[UInt8, IOError]`, an
  internally buffered byte stream over the remaining scoped reader contents.
- Added `windows(self: FileReader, size: Int) -> FallibleStream[Bytes, IOError]`,
  a sliding byte-window stream. Each item is an owned `Bytes` value of exactly
  `size` bytes; files shorter than `size` produce an empty stream, and
  non-positive sizes surface as `Err(InvalidInput(...))` from terminal
  operations.
- Taught the scoped-resource checker that `FallibleStream` carries a scoped
  dependency. Compiler-owned terminal operations marked
  `@resource_result_ordinary` erase that dependency; ordinary calls and returns
  still cannot let scoped-derived streams escape.
- Hardened `@resource_result_ordinary` validation so annotated builtins cannot
  return resources, streams, or values that contain scoped dependency carriers.
  The annotation is now reserved for true terminal operations that produce
  ordinary data.
- Removed an import-order dependency in resource-operation metadata: imported
  functions now classify resource parameters from the exporting module's
  resource declarations, even when the resource type is not imported by name.
- Added Core ownership/layout metadata and C runtime declarations so
  `FallibleStream` is retained and released like other managed builtin values.

Tasks:

- Extend `find_result` beyond nullable-managed and primitive stack-option
  payloads if boxed-union `Option` payloads become a real source need.
- Add cancellation/yield checks in future fallible stream producers as they are
  introduced.

Tests:

- `count_lines` handles empty files, trailing newline, no trailing newline,
  CRLF, and long lines crossing chunk boundaries;
- `chunks` returns expected bytes without losing boundaries;
- `lines().collect()` handles lines crossing chunk boundaries;
- `bytes().collect_result()` returns exact byte values and preserves
  `List[UInt8]` inline storage;
- `windows(n).collect_result()` returns sliding owned `Bytes` windows, handles
  short files as empty streams, and reports invalid sizes as typed errors;
- `fold_result`, `count_result`, `find_result`, `any_result`, and `all_result`
  cover success, typed source errors, generated-C bridge emission, and callback
  terminals;
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
- Should `with` eventually support multiple bindings in one header?
- Should scoped resources support explicit moves in a later affine-value model?
- Should source-defined helpers ever be able to produce scoped-dependent
  streams or cursors, and if so should that require explicit return syntax?
- Should `?=` inside closures remain part of the language? Existing std/tests use
  carrier-returning closures, so any future restriction needs a deliberate
  migration path.
- If `with ?=` stays unavailable directly in loop bodies, what should the
  preferred loop-local resource acquisition shape be: explicit `match` around
  the loop, a resource-aware loop helper, or APIs that acquire outside the loop?
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

1. Design the typed `open(path, options)` shape so impossible file-mode
   combinations are unrepresentable.
2. Decide whether `File` should keep explicit `*_rw` operation names or wait
   for a broader overload/trait-dispatch improvement before exposing shared
   `read_text`/`write_text` names.
3. Keep hardening `Stream[T]` and `FallibleStream[T, E]` as new producers are
   introduced.
4. Design explicit scoped-dependent return syntax before source-defined helpers
   are allowed to produce streams or cursors.
5. Layer scoped cleanup, typed errors, and stream adapters on top of the current
   typed nonblocking TCP handles.

This order keeps correctness ahead of ergonomics. It also prevents the new
streaming API from being built on today's known unsound stream ownership and
resource-lifetime gaps.
