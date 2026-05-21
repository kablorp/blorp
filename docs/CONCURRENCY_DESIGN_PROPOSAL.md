# Blorp Concurrency Design Proposal

Status: design proposal.

This document sketches a source-level concurrency model for Blorp that is
simpler and sounder than Go's goroutine model while preserving the same
practical power: cheap virtual tasks, direct blocking-style code, message
passing, high-concurrency servers, database work, data-engineering pipelines,
event loops, and resource-safe I/O.

This proposal intentionally looks past the current `concurrent:`,
`concurrent for`, and `detach` APIs. It uses the current resource API and
virtual-thread runtime work as constraints, but not as syntax that must remain
unchanged forever.

## Goals

- Make concurrency easy to read at the call site.
- Preserve Blorp's value semantics: no shared mutable Blorp memory between
  tasks.
- Keep resource ownership deterministic and compiler-checked.
- Make virtual-thread programming feel like ordinary blocking code.
- Avoid source-level `async` / `await`.
- Avoid Go-style unstructured goroutine leaks as the default.
- Make backpressure visible when it can block progress.
- Give servers, database clients, file pipelines, event systems, and games one
  coherent model.

## Non-Goals

- No shared mutable references.
- No locks, mutexes, or atomics as normal source-level programming tools.
- No unstructured `go f()` equivalent as the primary abstraction.
- No automatic resource cleanup through ARC destructors alone.
- No hidden task-result list with nested `Result[Result[T, E], ...]` as the
  common fan-out model.
- No claim that an operation is virtual-thread-friendly unless it parks the
  fiber or uses a bounded blocking-worker path.

## Core Thesis

Blorp concurrency should be built around two lexical ownership rules:

```text
Task scopes own child tasks.
Resource scopes own resources.
```

Everything else should preserve those rules. A child task may receive copied
ordinary values or an explicitly transferred resource item from a
resource-producing iterator. A child task may not accidentally capture a scoped
resource owned by its parent.

## User Model

The recommended teaching model should be:

```text
Use `concurrent:` for a small fixed set of independent tasks.
Use `for ... concurrently(...)` for dynamic fan-out.
Use channels for communication.
Use with for resources.
Use select when waiting on multiple independent events.
Use services or pools for intentionally shared external systems.
```

The important nouns:

| Concept | Meaning |
| --- | --- |
| `Task` | A lightweight virtual thread managed by a lexical scope. |
| `Channel[T]` | A shareable message queue for ordinary values. |
| `Resource` | A scoped external capability with exactly one cleanup owner. |
| `Service` | A shareable runtime object that internally synchronizes access, such as a DB pool. |
| `Stream[T]` | A one-shot sequential cursor. |
| `ResourceSource[R, E]` | A fallible source that produces owned resources one at a time. |
| `Waitable[T]` | A channel receive, timer, task completion, listener accept, or other operation usable in `select`. |

The language does not need a general user-visible `Task` handle in the first
version. Most programs should use lexical constructs instead of handles.

## Lessons From Other Ecosystems

This design borrows selectively:

- **Go** proves that one lightweight task per connection or request is a
  powerful default. Blorp should keep the direct style, but avoid unstructured
  goroutine lifetimes, manual resource cleanup, and shared mutable state.
- **Haskell** validates scoped resource callbacks (`bracket` / `withFile`) and
  cheap runtime threads. It also shows that cancellation cleanup must be
  protected by the runtime, not left as ordinary best-effort code.
- **OCaml Eio** is a useful model for lexical switches/scopes: child fibers and
  resources live under a clear dynamic extent.
- **Rust** highlights useful distinctions such as "can move to another task"
  and "can be shared across tasks." Blorp should capture those as simple
  declaration-level facts (`resource`, `service`, ordinary value), not
  Rust-level lifetime ceremony.
- **Scala effect systems** show the value of resource scopes, typed errors,
  races, and cancellation discipline, but Blorp should avoid making users carry
  explicit effect types through every API.

The common lesson is that the runtime can be powerful only if the source model
keeps lifetime, sharing, and cancellation visible.

## Primary Syntax

### Concurrent Loop

The core dynamic fan-out construct:

```blorp
for item in source concurrently(limit: 128):
	work(item)
```

Semantics:

- The loop is statement-only and returns `Void`.
- The parent consumes `source`.
- Each item is copied or moved into one child virtual task.
- The loop waits for all child tasks before continuing.
- `limit` caps active child tasks for this loop. It is not the OS worker-thread
  count.
- The task body does not return a value to the loop.
- Results are sent through channels, written to owned resources, or accumulated
  by higher-level library helpers.
- The task body cannot mutate outer `var` bindings.
- The task body cannot capture scoped resources or scoped-derived cursors from
  the parent.
- If an item is a resource produced by the source, the child task owns that
  resource and cleanup runs when the task exits.
- Cancellation closes resources owned by cancelled child tasks.

This replaces the current `concurrent for` mental model. Instead of making
fan-out produce `List[Result[T, ConcurrencyError]]`, fan-out is a loop modifier.
The base construct is about running work, not collecting values.

### Fixed Concurrent Block

For a small fixed set of independent tasks:

```blorp
concurrent:
	users = fetch_users()
	orders = fetch_orders()

match (users, orders):
	(Ok(us), Ok(os)): render(us, os)
	_: render_error()
```

The fixed block can also run statement tasks:

```blorp
concurrent:
	run_world(events)
	run_metrics(metrics)
	run_server(events)
```

Semantics:

- Each top-level item runs in a child task.
- The scope waits for all children before continuing.
- Bindings become available after the block joins.
- A bound task value has a task-result type such as
  `Result[T, ConcurrencyError]`, where `T` is the task body's direct result
  type.
- Non-binding statements must be `Void`-typed or explicitly discard their
  result.
- Resources follow the same rules as concurrent loops: no accidental capture of
  parent-owned resources.
- `?=` has no implicit propagation target inside the child tasks; use
  local `match`, result combinators, or helpers such as `with_resource`.
- This is useful for small fixed-width parallelism and long-running cooperating
  loops.

This is deliberately different from dynamic fan-out. Fixed-width parallelism is
small enough for named task results to stay readable:

```blorp
concurrent:
	profile = fetch_profile(user_id)
	recommendations = fetch_recommendations(user_id)

match (profile, recommendations):
	(Ok(p), Ok(rs)): render_page(p, rs)
	_: render_error()
```

Dynamic fan-out remains statement-only because implicit result collection
quickly creates nested, memory-heavy result structures. For ordinary
data-parallel result collection, prefer library helpers:

```blorp
results = urls.map_concurrently(limit: 256, fetch)
```

### Nesting

Concurrent constructs should be nestable. Nesting is necessary for real
programs: a server task may own an accept loop, each connection task may start
short-lived parser/writer subtasks, and a data pipeline may run concurrent
stages whose individual jobs use bounded fan-out.

Nesting should form a task tree:

```text
parent task
  child task scope
    child task
      nested child task scope
        grandchild task
```

Rules:

- A nested concurrent scope joins before the task that created it continues.
- Cancellation flows downward through the tree.
- Cleanup flows inward-out: grandchildren clean up before their parent task
  exits, and resources owned by a task are closed when that task exits.
- A nested task may read ordinary immutable values from enclosing scopes.
- A nested task may not mutate an outer `var`.
- A nested task may not capture a scoped resource unless the resource type
  explicitly permits the needed structured task borrow.
- `limit` is local to the construct where it appears. It limits active child
  tasks for that construct, not global worker threads.

Example:

```blorp
with listener ?= tcp.listen("", 8080, 1024):
	concurrent:
		run_metrics()

		for conn in listener.connections(on_error: Continue) concurrently(limit: 4096):
			handle_connection(conn)
```

The outer scope waits for both `run_metrics` and the accept loop. The inner
loop owns the connection tasks. If the outer scope is cancelled, the accept loop
and all live connection tasks are cancelled before `listener` cleanup runs.

The performance footgun is nested fan-out explosion:

```blorp
for account in accounts concurrently(limit: 100):
	for event in account.events concurrently(limit: 100):
		process(event)
```

This can create up to 10,000 active child tasks. That should be legal because
the limits are explicit, but instrumentation should make it visible. Later
helpers may offer inherited budgets, but the base language should avoid hidden
global throttling that makes local code hard to reason about.

### Select

`select` waits for one of several independent events:

```blorp
select:
	msg from inbox:
		handle(msg)

	_ after 1.second:
		flush()

	sealed shutdown:
		break
```

Resource-producing branches are scoped to the selected branch:

```blorp
select:
	conn from listener.connections():
		handle_connection(conn)

	sealed shutdown:
		break
```

Semantics:

- Each branch registers one wait.
- When one branch becomes ready, the runtime unregisters all losing waits.
- The selected branch runs synchronously in the current task.
- If the branch yields a resource, that resource is scoped to the branch body.
- Fairness must be specified. The preferred policy is pseudo-random or
  round-robin among ready branches, not source-order starvation.
- `select` is not the default event-system abstraction. A single
  `Channel[Event]` with a union is usually simpler when producers can already
  merge events.

## Channels

Channels should not be normal resources. A channel is a shareable communication
object. `seal(ch)` is a semantic signal, not merely handle cleanup.

There should be one channel type, and construction should require an explicit
maximum size:

```blorp
channel[T](max_size: Int) -> Channel[T]
```

The maximum size is part of the program's backpressure and memory policy. It
must be visible at the construction site instead of hidden behind an unbounded
default.

Full-channel behavior should be visible in the operation name or return value:

```blorp
try_send(ch: Channel[T], value: T) -> SendAttempt
wait_send(ch: Channel[T], value: T) -> Result[Void, ChannelSealed]
send_timeout(ch: Channel[T], value: T, ms: Int) -> SendAttempt
recv(ch: Channel[T]) -> Option[T]
try_recv(ch: Channel[T]) -> Option[T]
recv_timeout(ch: Channel[T], ms: Int) -> Option[T]
seal(ch: Channel[T]) -> Void
```

The naming matters. A method named `send` should not secretly park forever when
the buffer is full. Use `try_send` when fullness is a local branch and
`wait_send` when backpressure is intentional. A plain `send` alias should either
not exist or should be reserved for a nonblocking operation whose return type
forces the caller to handle `Full` and `Sealed`.

Recommended guidance:

- Use `Channel[Event]` for application-level event loops.
- Choose `max_size` from a real memory/backpressure budget.
- Use `wait_send` only when producer parking is intentional and the consumer is
  known to be running concurrently.
- Do not put resources in channels unless the type system grows an explicit
  resource-transfer channel. Ordinary channels carry ordinary values.
- Sealing a channel means "no more sends"; it should not be hidden in a
  resource finalizer.
- Sealing is one-way. There should be no `unseal`, because receivers rely on
  sealed-and-drained `None` meaning the stream is permanently complete.

### Channel Seal And Cleanup

Channel seal and channel memory cleanup are different.

`seal(ch)` is a protocol event:

- further sends fail;
- buffered values remain receiveable;
- receivers finish with `None` once the channel is sealed and drained;
- blocked receivers and senders are woken.

Channel memory cleanup is ordinary managed-value cleanup:

- the channel runtime object is released when no task, variable, closure, wait
  queue, or buffered value can reference it;
- buffered values are released when they are received or when the channel
  object is freed;
- cancelling a task waiting on a channel removes that waiter from the channel's
  wait queue and releases the task's channel reference.

The language should not automatically call `seal(ch)` just because a lexical
variable goes out of scope. That would make one handle's lifetime change the
protocol seen by all other producers and consumers.

This means a producer/consumer protocol must seal explicitly:

```blorp
out: Channel[Item] = channel(1024)

for path in paths concurrently(limit: 64):
	_ = out.wait_send(read_item(path))

out.seal()

for item in out:
	consume(item)
```

If producers can fail or return early, use a helper that makes the seal edge
visible:

```blorp
with sealing out:
	for path in paths concurrently(limit: 64):
		_ = out.wait_send(read_item(path))
```

`with sealing out:` would not make `Channel[T]` a resource. It would be a
scoped protocol guard that calls `seal(out)` on scope exit. The channel object
itself would still be shareable and ARC-managed.

A channel can still deadlock if all live tasks wait for messages that no task
can send. That is a liveness bug, not a cleanup rule. Structured timeouts,
explicit seal, and instrumentation should make these bugs diagnosable.

## Shared Accumulation

Concurrent task bodies may mutate local variables that they create, but they
must not mutate `var` bindings from an outer scope:

```blorp
var total: Int = 0

for item in items concurrently(limit: 128):
	total += item.cost()  -- reject: shared mutable outer var
```

Use channels or data-parallel helpers instead:

```blorp
costs: Channel[Int] = channel(items.length())

for item in items concurrently(limit: 128):
	_ = costs.try_send(item.cost())

costs.seal()
total = costs.sum()
```

or:

```blorp
total = items.map_concurrently(limit: 128, func(item): item.cost()).sum()
```

Future CRDT-style APIs may support explicit concurrent accumulation, but they
should remain distinct from ordinary `var`:

```blorp
total = items.fold_concurrently(
	limit: 128,
	zero: GCounter.zero(),
	func(item): GCounter.one(item.cost()),
).value()
```

The type must carry the algebraic safety contract: deterministic merge,
associative/commutative behavior where needed, and no arbitrary shared mutable
state.

## Resources And Concurrency

The resource API's central invariant should remain:

```text
Every successful resource acquisition has exactly one cleanup owner.
```

Concurrent work must preserve that invariant.

There are three distinct safe patterns:

- acquire the resource inside the child task;
- transfer a resource item produced by the loop source into the child task;
- borrow a parent-owned resource only when the resource type explicitly permits
  that structured task borrow and the task scope joins before cleanup.

Allowed:

```blorp
for path in paths concurrently(limit: 128):
	n = open_read(path)
		.with_resource(func(reader):
			reader.count_lines().unwrap_or(0)
		)
		.unwrap_or(0)

	_ = out.try_send((path, n))
```

Allowed:

```blorp
with listener ?= tcp.listen("", 8080, 1024):
	for conn in listener.connections() concurrently(limit: 4096):
		handle_connection(conn)
```

Rejected:

```blorp
with conn ?= tcp.connect(host, port):
	for req in requests concurrently(limit: 64):
		conn.write_all(req)  -- parent-owned resource capture
```

The fix is to acquire one resource per task, borrow a shareable service, or use
a resource type that explicitly supports safe concurrent borrowing.

### Structured Resource Borrows

The default rule should be conservative: child tasks cannot capture
parent-owned resources.

Some resources may safely support a structured task borrow. For example, a
`TcpListener` can support a single accept loop inside a joined task scope, while
a `DbConnection` often cannot safely run multiple active queries at once.

This must be declaration-level metadata, not a name heuristic:

```blorp
resource type TcpListener = builtin("blorp_tcp_close_listener")
	permits task_borrow(AcceptLoop)
```

Rules:

- The resource binding must outlive the entire task scope.
- The task scope must join or cancel before the resource cleanup edge runs.
- The resource type must opt into the specific borrow mode.
- The compiler must reject conflicting borrows, such as two exclusive accept
  loops for the same listener.
- A borrowed resource still cannot escape the child task.

This is an escape from the default only because the lifetime is still lexical
and the resource declaration names the concurrency contract.

### Resource-Producing Iteration

Some sources produce resources:

```blorp
listener.connections() -> ResourceSource[TcpStream, TcpError]
pool.checkouts() -> ResourceSource[DbConnection, DbError]
fs.walk(root).files() -> FallibleStream[String, IOError]
```

For ordinary streams, the parent task owns the cursor and child tasks receive
ordinary item values. For resource sources, each item is an owned resource
transferred into one iteration task.

Rules:

- `ResourceSource[R, E]` cannot be collected into a list.
- `ResourceSource[R, E]` cannot be stored in ordinary aggregates.
- `ResourceSource[R, E]` can be consumed sequentially by `for`.
- `ResourceSource[R, E]` can be consumed concurrently by `for ... concurrently`.
- A resource item is scoped to its iteration body.
- In a concurrent loop, resource item cleanup belongs to the child task.
- Errors from the source must have an explicit policy.

Possible source-error policy:

```blorp
for conn in listener.connections(on_error: Continue) concurrently(limit: 4096):
	handle_connection(conn)
```

or explicit event iteration:

```blorp
for event in listener.events():
	match event:
		Connected(conn): handle_connection(conn)
		AcceptFailed(err): log(err)
```

The event form is attractive, but resource-carrying union variants would need a
linear/resource-aware union model. Until then, a source-level error policy is
the smaller design.

## Timeouts And Cancellation

Timeouts should cancel timed-out work. A timeout that merely returns `TimedOut`
while child tasks keep running would violate the task-scope ownership model.

The block keyword remains `concurrent:`. Timeout syntax should layer on top of
that instead of changing the block keyword. A surrounding deadline scope is the
least ambiguous spelling if Blorp keeps block keywords argument-free:

```blorp
-- Whole block deadline: all child tasks must finish before the deadline.
with timeout(2.seconds):
	concurrent:
		users = fetch_users()
		orders = fetch_orders()

-- Per-item timeout: each iteration task gets its own deadline.
for url in urls concurrently(limit: 256, item_timeout: 500.milliseconds):
	fetch_and_send(url, results)
```

The design still needs two distinct timeout concepts. They should not share one
ambiguous parameter on concurrent loops. For loops, `timeout` sounds like a
whole-loop timeout while `item_timeout` sounds like a per-child timeout. If both
are useful, they should be separately named:

```blorp
for path in paths concurrently(
	limit: 128,
	timeout: 30.seconds,
	item_timeout: 1.second,
):
	index_file(path)
```

Semantics:

- Parent cancellation cancels all descendant task scopes.
- A scope timeout cancels every still-running child in that scope.
- An item timeout cancels only that iteration task.
- Cancellation waits for resource cleanup before the cancelled scope is
  considered finished.
- Resource cleanup runs even when cancellation happens during a channel wait,
  socket wait, file wait, sleep, timer wait, or `select`.
- Timeout and cancellation results must be explicit in task result types, for
  example `Result[T, ConcurrencyError]` or a future `TaskResult[T]`.
- User `Result` errors are ordinary values. They should not automatically
  cancel sibling tasks unless the construct has an explicit failure policy.
- Deadlines should use a monotonic clock and nested deadlines should compose by
  taking the earlier deadline.

Cancellation should be cooperative, not arbitrary interruption. Safe
cancellation points are operations where the runtime already owns a park point:

- channel send/receive waits;
- `sleep`, timers, and `select`;
- socket readiness waits;
- file and foreign blocking operations routed through the blocking-worker path;
- explicit `cancel_point()` for long CPU loops if needed.

The compiler/runtime should avoid inserting cancellation at arbitrary pure
expression boundaries. That keeps local reasoning intact and prevents cleanup
from observing half-updated local state.

Open design points:

- CPU-bound tasks can ignore cancellation until they reach a poll point. That is
  predictable, but long numeric loops may need an ergonomic `cancel_point()` or
  compiler-inserted loop backedge polls for impure task bodies.
- Cleanup should be cancellation-resistant once started. If a cleanup operation
  can block indefinitely, it needs a runtime policy rather than ordinary user
  cancellation.
- Scope-level failure policy should be explicit. Possible options are
  `cancel_on_error: true`, `failure: CancelSiblings`, or separate helpers for
  racing and fail-fast behavior.
- A timeout scope is a structured cancellation scope, not a resource. It should
  not run arbitrary user cleanup; it should request cancellation and then wait
  for the child/resource cleanup machinery to complete.
- Channel sealing is not automatic cancellation cleanup. A channel is sealed
  only by `seal(ch)` or by an explicit scoped sealing guard.

## Error Handling In Concurrent Bodies

`?=` should remain unavailable in loops and statement-task bodies unless the
language gets a very clear local propagation target. In a statement-only
concurrent loop or `concurrent:` branch, there is no useful implicit return
value for `?=` to propagate to.

Prefer local result handling:

```blorp
for path in paths concurrently(limit: 128):
	n = open_read(path)
		.with_resource(func(reader):
			reader.count_lines().unwrap_or(0)
		)
		.unwrap_or(0)

	_ = counts.try_send((path, n))
```

This implies a useful standard combinator:

```blorp
Result[R, E].with_resource(func(resource: borrow R) -> T) -> Result[T, E]
```

Meaning:

- If the result is `Err(e)`, return `Err(e)`.
- If the result is `Ok(resource)`, run the callback with a scoped resource.
- Close the resource after the callback returns, errors, or is cancelled.
- The callback cannot return the resource or scoped-derived values.

This keeps the no-`?=`-in-loops/no-`?=`-in-task-bodies rule while making
per-item resource acquisition pleasant.

For result collection, prefer explicit channels or library helpers:

```blorp
func fetch_all(urls: List[String]) -> List[FetchResult]:
	results: Channel[FetchResult] = channel(urls.length())

	for url in urls concurrently(limit: 256):
		_ = results.try_send(fetch(url))

	results.seal()
	results.collect()
```

Higher-level helpers can provide map-like behavior for ordinary values:

```blorp
urls.map_concurrently(limit: 256, fetch)
```

Those helpers are library conveniences, not the foundational concurrency
construct.

## Services

Some objects are intentionally shareable and internally synchronized. These are
not ordinary resources, and they are not ordinary immutable values either.

Examples:

- database pool;
- metrics sink;
- logger;
- DNS resolver pool;
- event bus;
- maybe a thread-safe HTTP client pool.

Proposed category:

```blorp
service type DbPool = builtin
```

Rules:

- Services are shareable across tasks.
- Service methods must document whether they park fibers, use a bounded
  blocking pool, or are pure local operations.
- Services should not expose shared mutable Blorp values.
- Services may produce resources, such as checked-out connections.

Example:

```blorp
with pool ?= db.pool(url, max_connections: 32):
	for job in jobs concurrently(limit: 128):
		_ = pool.checkout()
			.with_resource(func(conn):
				run_job(conn, job)
			)
```

`DbPool` is shareable; `DbConnection` is scoped.

## Ergonomic Growth Path

Users should be able to adopt concurrency incrementally. Each step should add
one concept, and later steps should not invalidate earlier code.

Start with direct sequential code:

```blorp
for path in paths:
	analyze(path)
```

Add concurrent execution with one modifier:

```blorp
for path in paths concurrently(limit: 32):
	analyze(path)
```

For ordinary result collection, use helpers before reaching for channels:

```blorp
results = paths.map_concurrently(limit: 32, analyze)
```

When work becomes a pipeline, introduce an explicitly sized channel:

```blorp
rows: Channel[Row] = channel(8192)

with sealing rows:
	for path in paths concurrently(limit: 32):
		parse_file(path, rows)

for row in rows concurrently(limit: 64):
	load_row(row)
```

When each item needs a resource, keep acquisition local to the task:

```blorp
for path in paths concurrently(limit: 32):
	_ = open_read(path)
		.with_resource(func(reader):
			analyze(reader)
		)
```

When the program waits on independent sources, add `select`:

```blorp
select:
	event from events:
		handle(event)

	_ after 1.second:
		flush()

	sealed shutdown:
		break
```

When a source produces resources, use resource-producing iteration:

```blorp
with listener ?= tcp.listen("", 8080, 1024):
	for conn in listener.connections(on_error: Continue) concurrently(limit: 4096):
		handle_connection(conn)
```

Performance tuning should stay in the same vocabulary:

- raise or lower `limit`;
- choose a channel `max_size`;
- replace `try_send` with `wait_send` only when backpressure is intended;
- use scheduler/channel instrumentation to find blocked or excessive tasks.

## Use Cases

### Web Server

```blorp
func serve() -> Result[Void, TcpError]:
	with listener ?= tcp.listen("", 8080, 1024):
		for conn in listener.connections(on_error: Continue) concurrently(limit: 4096):
			handle_connection(conn)

		Ok(Void)
```

Desired properties:

- one virtual task per connection;
- listener owned by parent;
- connection owned by child task;
- socket waits park fibers;
- connection closes on normal return, protocol error, timeout, or
  cancellation.

### HTTP Handler

```blorp
func handle_connection(conn: borrow TcpStream) -> Void:
	match conn.read_request():
		Ok(req):
			resp = route(req)
			_ = conn.write_all(resp.to_bytes())
		Err(_):
			_ = conn.write_all(bad_request().to_bytes())
```

The loop owns the connection resource. The handler borrows it synchronously.

### Database Querying

```blorp
func run_queries(url: String, queries: List[Query]) -> Result[Void, DbError]:
	with pool ?= db.pool(url, max_connections: 32):
		for query in queries concurrently(limit: 128):
			_ = pool.checkout()
				.with_resource(func(conn):
					match conn.query(query):
						Ok(rows):
							rows.for_each_result(process_row).unwrap_or(Void)
						Err(err):
							log_db_error(err)
				)

		Ok(Void)
```

The pool is shareable. Connections and row cursors are scoped resources.

### Data Engineering

```blorp
func ingest(paths: List[String], pool: DbPool) -> Void:
	rows: Channel[Row] = channel(8192)

	for path in paths concurrently(limit: 64):
		_ = open_read(path)
			.with_resource(func(reader):
				reader.lines()
					.filter_map(parse_row)
					.for_each_result(func(row):
						rows.wait_send(row).unwrap_or(Void)
					)
					.unwrap_or(Void)
			)

	rows.seal()

	for row in rows concurrently(limit: 64):
		_ = pool.checkout()
			.with_resource(func(conn):
				conn.insert(row).unwrap_or(Void)
			)
```

This uses channels for stage boundaries and concurrent loops for fan-out.

### Event-Based System

```blorp
union AppEvent:
	UserSignedUp(User)
	PaymentCaptured(Payment)
	Shutdown

func event_loop(events: Channel[AppEvent]) -> Void:
	for event in events:
		match event:
			UserSignedUp(user): send_welcome_email(user)
			PaymentCaptured(payment): update_ledger(payment)
			Shutdown: break
```

A single `Channel[Event]` is the preferred default when events are ordinary
data. It is explicit, testable, and does not require `select`.

Use `select` when sources cannot or should not be pre-merged:

```blorp
func event_loop(events: Channel[AppEvent], shutdown: Channel[Void]) -> Void:
	while True:
		select:
			event from events:
				handle_event(event)

			_ after 1.second:
				flush_metrics()

			sealed shutdown:
				break
```

### MMORPG Server

```blorp
func run_game() -> Result[Void, TcpError]:
	world_events: Channel[WorldEvent] = channel(16384)

	with listener ?= tcp.listen("", 7777, 1024):
		concurrent:
			run_world(world_events)
			-- TcpListener permits one structured accept-loop borrow.
			for conn in listener.connections(on_error: Continue) concurrently(limit: 20000):
				run_player_session(conn, world_events)

	Ok(Void)
```

The world task owns mutable world state locally. Player sessions send ordinary
events. No task shares mutable world memory.

### File Systems

```blorp
func count_source_lines(root: String) -> Result[Int, IOError]:
	counts: Channel[Int] = channel(8192)

	with walk ?= fs.walk(root):
		for path in walk.files() concurrently(limit: 128):
			if path.ends_with(".brp"):
				n = open_read(path)
					.with_resource(func(reader):
						reader.count_lines().unwrap_or(0)
					)
					.unwrap_or(0)

				_ = counts.wait_send(n)

	counts.seal()
	Ok(counts.sum())
```

The directory walker is parent-owned. Paths are ordinary values copied into
child tasks. Each child opens and closes its own file.

## Select Versus Union Event Channels

Blorp should support both, but they serve different purposes.

Use one `Channel[Event]` when:

- events are ordinary values;
- producers can naturally send to the same channel;
- the application wants one central event protocol;
- testability and simple tracing matter.

Use `select` when:

- sources are independent waitables;
- bridging sources would require extra tasks only to merge events;
- timers, shutdown, channel receive, and task completion must be coordinated;
- a branch receives a scoped resource, such as an accepted TCP connection;
- fairness across independent queues matters.

Tradeoff:

```text
Union event channel:
  simpler, explicit event type, easy to test,
  but requires producers or bridge tasks to merge sources.

select:
  more direct multi-source waiting,
  but needs precise fairness, cancellation, and loser-unregistration rules.
```

The default teaching guidance should be: use event channels first; use `select`
when independent waitables make bridge tasks awkward or unsafe.

## TCP Resource Target

TCP should move from typed ARC handles to scoped resources:

```blorp
resource type TcpListener = builtin("blorp_tcp_close_listener")
resource type TcpStream = builtin("blorp_tcp_close_stream")
```

API shape:

```blorp
listen(host: String, port: Int, backlog: Int) -> Result[TcpListener, TcpError]
connect(host: String, port: Int) -> Result[TcpStream, TcpError]
connections(listener: borrow TcpListener) -> ResourceSource[TcpStream, TcpError]
read_chunk(stream: borrow TcpStream, max_bytes: Int) -> Result[Bytes, TcpError]
write_all(stream: borrow TcpStream, data: Bytes) -> Result[Void, TcpError]
chunks(stream: borrow TcpStream) -> FallibleStream[Bytes, TcpError]
```

DNS must remain explicit:

- numeric hosts and already-resolved addresses are virtual-thread-friendly;
- hostname resolution either blocks on a bounded resolver pool or uses a future
  async resolver;
- docs must not claim hostname connect is fiber-friendly unless the resolver
  actually is.

For protocols needing independent reader/writer tasks:

```blorp
split(stream: TcpStream) -> Result[(TcpReader, TcpWriter), TcpError]
```

This should consume the original stream and produce two resources with explicit
permission roles. It must not create two freely copyable handles to the same
mutable socket state.

### Existing Detached TCP Failure

The current typed-handle TCP API has a concrete failure mode:
`/Users/keithphilpott/Documents/static-site/repro/tcp-detach-segv` contains a
server that accepts `TcpStream` values and runs `detach handle_client(stream)`.
The same handler is stable when called inline, but the detached server can
segfault under concurrent client load. A sanitizer trace from the original
static-site server points through the detached handler task path.

Treat this as a design constraint, not as a TCP-specific patch target. The
problem is that `TcpStream` is a mutable external capability represented as an
ordinary managed value, so the type system cannot distinguish these states:

- a stream handled synchronously by the accepting task;
- a stream explicitly moved into a joined child task;
- a stream accidentally captured by unstructured detached work;
- a stream copied into more than one task while manual close remains callable.

The resource migration should make the unsafe shape unrepresentable:

```blorp
match tcp.accept(listener):
	Ok(stream):
		detach handle_client(stream)  -- reject once TcpStream is a resource
	Err(err):
		log(err)
```

The replacement should be resource-producing iteration, where each accepted
connection is moved into exactly one child task owned by a structured scope:

```blorp
with listener ?= tcp.listen("", 8080, 1024):
	for conn in listener.connections(on_error: Continue) concurrently(limit: 4096):
		handle_connection(conn)
```

Do not infer this from function names such as `accept` or `connections`.
`TcpStream` must be declared as a resource, and Core must carry an explicit
resource-item move or structured borrow. Emission should reject any reserved
resource task-capture kind that reaches it without lowering.

## Type System And Compiler Rules

The type system should make these states unrepresentable:

- resource stored in ordinary list/record/dict/set/union/channel;
- scoped resource captured by child task without a permitted structured borrow;
- scoped-derived stream captured by child task;
- child task mutating an outer `var`;
- resource item used after transfer into a task;
- bounded send hidden behind a method that looks nonblocking;
- resource source collected into a materialized list;
- selected resource escaping its `select` branch;
- service method marked shareable without an explicit service type;
- nested task scopes with ambiguous parent/child ownership;
- channel waiters that remain reachable after timeout or cancellation;
- automatic channel seal through ordinary value drop.

Suggested new type categories:

```blorp
resource type R
service type S
type Channel[T]
type ResourceSource[R, E]
type Waitable[T]
```

`resource` and `service` should be declaration-level facts, not inferred from
names.

`for ... concurrently` lowering should carry explicit item ownership:

```text
CopyItem(T)              ordinary value copied/retained into child task
MoveResourceItem(R)      resource cleanup owner transferred to child task
```

This should be represented in typed AST/Core. Codegen should not infer transfer
semantics from function names such as `connections`.

## Runtime Requirements

The runtime target in `docs/VIRTUAL_THREADS_DESIGN.md` remains the foundation.
This source-level design assumes:

- many virtual tasks multiplex over a bounded worker pool;
- parking operations do not pin workers;
- cancellation points run cleanup for task-local resources;
- channel wait queues remove cancelled/timeout waiters;
- socket readiness integrates with the poll/kqueue/epoll reactor;
- blocking foreign or OS APIs use a bounded blocking pool with visible
  backpressure.

`limit` is operation width, not worker count. Worker capacity belongs to
runtime configuration such as `BLORP_THREADS` or a CLI option.

## Migration Roadmap

The migration should be incremental enough that every phase leaves Blorp in a
coherent state. Do not migrate TCP, channels, `select`, and `concurrent` syntax
in one change. The core order should be:

```text
runtime invariants -> source syntax -> typed ownership -> ordinary fan-out ->
channels -> timeouts -> resources -> select -> TCP/services -> deprecation
```

Each phase should update docs and grammar when syntax or standard-library APIs
change. Each phase should include parser/typecheck tests, runtime tests,
leak-check coverage where resources are involved, and Core invariant checks for
new ownership states.

### Migration Principles

- Keep `concurrent:` as the fixed block syntax.
- Introduce `for ... concurrently(...)` as the dynamic fan-out syntax.
- Preserve old syntax long enough to produce helpful migration diagnostics.
- Prefer adding new explicit operations before changing existing behavior.
- Represent ownership and cancellation in typed AST/Core before codegen relies
  on them.
- Never infer resource transfer, task borrow, or channel protocol semantics from
  function names.
- Add runtime instrumentation before relying on humans to tune limits,
  backpressure, or deadlines.
- Migrate examples only after the compiler has diagnostics for the old pattern.
- Treat runtime primitive contracts as compiler data, not scattered convention:
  when a concurrency primitive crosses the runtime ABI, its ownership,
  payload-boxing, blocking/cancellation behavior, and result shape should be
  represented once and checked by unit tests/Core invariants.

### Phase 0: Baseline Inventory

Goal: know exactly what existing concurrency code depends on.

Work:

- Catalogue all uses of `concurrent:`, `concurrent for`, `detach`, channels,
  channel close/seal behavior, timeout helpers, and TCP concurrency examples.
- Add snapshot tests for the current behavior before changing it.
- Identify which tests rely on result collection from `concurrent for`.
- Identify any code that assumes detached work can outlive resources.

Migration impact: none. This phase should only add tests and notes.

Stop condition: every later breaking change has a named test or example that
will need migration.

### Phase 1: Runtime Cancellation Foundation

Goal: make cancellation and timeout cleanup correct before adding new syntax.

Work:

- Represent task scopes explicitly in the runtime.
- Ensure scope cancellation cancels descendants before the parent continues.
- Ensure cancelled channel waits remove their waiters.
- Ensure cancelled sleeps, timers, socket waits, and blocking-worker jobs either
  park safely or complete through a well-defined cancellation path.
- Ensure task-local resources clean up on cancellation.
- Add scheduler instrumentation for active tasks, parked tasks, cancelled tasks,
  blocked sends, blocked receives, and timeout wakeups.

Tests:

- Timed-out child tasks cannot keep running after the parent observes timeout.
- Cancelled channel receivers and senders are removed from wait queues.
- Resource cleanup runs when cancellation interrupts a wait.
- Nested cancellation cleans up grandchildren before parent resources.

Implementation status: concurrent block timeouts cancel sleeping tasks, tasks
blocked in channel receive, tasks blocked in channel send, stream iteration, and
late side effects. Runtime regressions also verify that cancelled channel
senders/receivers leave the channel usable after timeout, which protects the
waiter-unregistration contract needed by `select` and resource-producing
iteration. Scheduler instrumentation now exposes channel send/receive park
counters, so tests and benchmarks can distinguish bounded-channel backpressure
from timer, scheduler, and reactor waits. Resource cleanup on cancellation and
nested cancellation ordering still need resource-specific coverage as the
resource/concurrency integration lands.

Migration impact: none visible unless existing timeout behavior is buggy. Fix
bugs here before exposing new user-facing cancellation syntax.

Stop condition: cancellation is reliable enough that syntax can promise
"timeout cancels timed-out work."

### Phase 2: Syntax Split Without Semantic Expansion

Goal: establish the final shape of block versus loop syntax.

Work:

- Keep fixed-width block syntax as `concurrent:`.
- Add parser support for `for item in source concurrently(limit: N):`, with
  `N` initially matching today's positive integer literal `max_threads`
  constraint.
- Require `limit` in the first version. If a default is ever added, it should be
  a later ergonomic decision, not the initial migration.
- Emit a migration diagnostic for `concurrent for`:

```text
`concurrent for` has moved to `for ... concurrently(limit: N)`.
Choose an explicit limit so task width and backpressure are visible.
```

Current:

```blorp
results = concurrent for item in items:
	work(item)
```

Target for statement fan-out:

```blorp
for item in items concurrently(limit: 128):
	work(item)
```

Target for result collection:

```blorp
results = items.map_concurrently(limit: 128, work)
```

Tests:

- Parser accepts `for ... concurrently(limit: N)`.
- Parser rejects missing `limit` with a clear help message.
- Parser rejects `concurrently:` as a block spelling and suggests
  `concurrent:`.
- Formatter preserves the new loop modifier.

Migration impact: old `concurrent for` can still parse during the warning
window, but new code should use the target forms. The first implementation
slice may accept both forms before adding the legacy diagnostic.

Implementation status: the parser, AST, typed AST, Core, formatter, and
expression-document bridge preserve `limit` as distinct from legacy
`max_threads`. Codegen now treats `for ... concurrently(limit: N)` as a
per-loop active-task limit by spawning and joining work in windows of at most
`N` tasks. Legacy `concurrent for` / `max_threads` still uses the older
scheduler-width path and is intentionally left separate for migration.

Stop condition: users can mechanically migrate syntax without changing program
semantics yet.

### Phase 3: Typed Task Ownership Model

Goal: make illegal captures unrepresentable before codegen learns new tricks.

Work:

- Add a typed representation for child-task captures:

```text
CopyCapture(T)
MoveResourceItem(R)
StructuredTaskBorrow(R, mode)
RejectCapture(reason)
```

- Reject mutation of outer `var` bindings from child task bodies.
- Reject capture of parent-owned resources unless the resource type explicitly
  permits the structured task borrow.
- Reject capture of scoped-derived cursors and streams.
- Represent `limit`, parent scope id, and child scope id in typed AST/Core.

Tests:

- `total += x` inside a concurrent loop is rejected.
- Capturing immutable ordinary values works.
- Capturing a parent-owned file/TCP/database resource is rejected.
- A resource item produced by a resource source is treated as moved into the
  child task.

Implementation status: Core task closure metadata now stores explicit
`TaskCopyCapture`, `TaskMoveResourceItem`, or `TaskStructuredTaskBorrow`
capture kinds instead of bare `(name, type)` pairs. Closure conversion
currently constructs only `TaskCopyCapture`; Core invariants reject the reserved
resource-oriented capture kinds until their lowering exists. `CConcurrentFor`
and each `concurrent:` binding also carry explicit parent/child task-scope
edges assigned by `Core_lower`; nested concurrent loops lowered inside a child
task body use that child as the next parent. Core invariants reject malformed
task-scope ids. Codegen converts copy captures back to the existing closure ABI
at the final emission boundary, but rejects reserved resource-oriented capture
kinds instead of silently erasing their ownership semantics. Inference now uses
one shared concurrent-task mutation check for fixed `concurrent:` bindings and
dynamic `for ... concurrently` bodies; direct assignment and subscript
assignment to outer mutable bindings are rejected before Core lowering. Codegen
does not yet consume task-scope ids at runtime. `detach` now uses the same
outer-mutation checker, so unstructured detached work cannot write an outer
mutable binding directly or through subscript assignment. The capture and
outer-mutation checks are binder-aware: local pattern binders, loop binders, and
block-local declarations do not get mistaken for captures solely because they
reuse an outer name. Fixed `concurrent:` tasks, dynamic
`for ... concurrently` bodies, and `detach` bodies also reject read-captures of
outer mutable bindings; users must bind an immutable snapshot before starting
work when a task needs the current value.

Migration impact: this will reject programs that accidentally relied on shared
mutable state or resource capture. Diagnostics should explain channels,
services, or per-task resource acquisition.

Stop condition: codegen can consume a typed child-task plan without guessing.

### Phase 4: Ordinary Dynamic Fan-Out

Goal: implement `for ... concurrently` for ordinary values only.

Work:

- Lower ordinary iterable fan-out using the typed ownership plan.
- Make the loop statement-only and `Void`-typed.
- Ensure the loop joins before continuing.
- Enforce no implicit result collection.
- Add `List.map_concurrently(limit:, func)` for ordinary result collection if
  it does not already exist with the desired semantics.

Tests:

- Tasks run concurrently and auto-join.
- Loop body values are discarded only when the body is statement-compatible.
- `map_concurrently` preserves result order if that is the chosen contract.
- Nested fan-out respects each local `limit`.

Implementation status: ordinary list fan-out with `concurrently(limit: N)` now
emits bounded windows of active child tasks, so total task allocation is capped
by the local `limit` instead of the input length. The existing implementation
still supports expression-level result collection for compatibility; the
statement-only surface and any `map_concurrently` migration helper remain to be
designed and implemented deliberately rather than smuggled into codegen.

Migration impact: result-collecting `concurrent for` users move to
`map_concurrently`; side-effecting or channel-producing users move to
`for ... concurrently`.

Stop condition: ordinary non-resource concurrent loops work end to end without
resource or TCP special cases.

### Phase 5: Fixed `concurrent:` Result Semantics

Goal: preserve the good part of current `concurrent:` while making failure,
timeout, and cancellation explicit.

Open ergonomic choice:

Option A: use ordinary `Result[T, ConcurrencyError]`.

```blorp
concurrent:
	users = fetch_users()
	orders = fetch_orders()

match users:
	Ok(value): render_users(value)
	Err(TimedOut): render_timeout()
	Err(Cancelled): render_cancelled()
```

Pros: no new type. Cons: nested results are awkward when a task itself returns
`Result[T, E]`.

Option B: add a dedicated task-result union.

```blorp
concurrent:
	users = fetch_users()
	orders = fetch_orders()

match users:
	Completed(Ok(value)): render_users(value)
	Completed(Err(err)): render_user_error(err)
	TimedOut: render_timeout()
	Cancelled: render_cancelled()
```

Pros: separates task outcome from user return values. Cons: adds a new concept.

Recommended migration: implement a named `TaskResult[T]` alias or union before
adding timeout syntax. That gives diagnostics a precise place to point and
avoids nested `Result` confusion in database and HTTP code.

Tests:

- Bound names are unavailable inside sibling tasks and available after join.
- Bound task outcomes represent cancellation and timeout explicitly.
- A task returning `Result[T, E]` does not lose the distinction between user
  error and task cancellation.

Implementation status: source-level `concurrent:` now rejects duplicate result
bindings, result bindings that redeclare an existing name in the enclosing
scope, and references to sibling result bindings from task bodies. Result
bindings are still ordinary `Result[T, ConcurrencyError]` values after the
block joins; a dedicated `TaskResult[T]` type remains an open design step before
new timeout syntax should be added.

Migration impact: existing `concurrent:` users may need to match on task
outcomes instead of assuming raw values.

Stop condition: fixed concurrent blocks have one explicit result contract.

### Phase 6: Channel API Tightening

Goal: make backpressure and producer completion visible.

Work:

- Keep one channel type: `Channel[T]`.
- Require explicit `max_size` at construction.
- Add or standardize:

```blorp
try_send(ch: Channel[T], value: T) -> SendAttempt
wait_send(ch: Channel[T], value: T) -> Result[Void, ChannelSealed]
send_timeout(ch: Channel[T], value: T, ms: Int) -> SendAttempt
recv(ch: Channel[T]) -> Option[T]
try_recv(ch: Channel[T]) -> Option[T]
recv_timeout(ch: Channel[T], ms: Int) -> Option[T]
seal(ch: Channel[T]) -> Void
```

- If channel `close` exists today, keep it as a deprecated channel-only alias
  for `seal` during migration. Do not blur this with resource close.
- Ensure cancellation of blocked senders/receivers removes waiters.
- Decide whether plain `send` exists. If it remains, its blocking behavior must
  be obvious from docs and type.
- Add a runtime primitive contract hardening checkpoint before building
  `select`: every channel/runtime primitive used by std wrappers must have
  explicit compiler-side ownership and ABI-boxing metadata, with tests that fail
  when either side is missing.

Ergonomic sketches for producer completion:

Explicit seal:

```blorp
for path in paths concurrently(limit: 64):
	_ = rows.wait_send(read_row(path))

rows.seal()
```

Scoped seal guard:

```blorp
with sealing rows:
	for path in paths concurrently(limit: 64):
		_ = rows.wait_send(read_row(path))
```

Callback helper:

```blorp
rows.sealing(func(out):
	for path in paths concurrently(limit: 64):
		_ = out.wait_send(read_row(path))
)
```

Recommended migration: implement explicit `seal` first. Add `with sealing` only
if examples keep needing scope-exit producer completion.

Tests:

- `seal` wakes blocked receivers and senders.
- Receivers drain buffered values before getting `None`.
- `seal` is one-way.
- Channel memory cleanup is separate from sealing.

Implementation status: `seal` is available and `close` remains a compatibility
alias. Channel docs and concurrency tests now use sealed/unsealed wording for
producer completion, with targeted compatibility tests left for `close`. Timed
channel waits remove their waiters on timeout, and non-blocking `try_send` /
`try_recv` now wake opposite-side fiber waiters when they make buffer progress,
matching blocking send/recv behavior. Runtime tests cover `seal` waking blocked
receivers and senders, draining buffered values before `None`, and one-way
idempotent sealing. `wait_send` now returns
`Result[Void, ChannelSealed]`, with focused doctests and runtime coverage for
success and sealed-channel cases. Supporting that shape also made `Void`
constructor payloads explicit in type inference and C layout boxing, so
`Result[Void, E]` can be constructed without weakening the ordinary
no-`Void`-arguments rule. `try_send_attempt` and `send_timeout_attempt` now
return `SendAttempt`, distinguishing accepted sends from full, sealed, and
timed-out sends without changing existing boolean APIs. `send`, `try_send`,
and `send_timeout` still return `Bool` as compatibility aliases; changing or
removing those aliases remains a later migration step. The status send hooks
also exposed a duplication hazard between runtime declarations, ownership
contracts, and Core ABI boxing metadata; Phase 6 now includes hardening tests
for that contract before adding more waitable channel operations. The first
hardening slice moved runtime `void*` payload-boxing metadata onto
`Core_ownership` builtin contract entries, and `Core_specialize` now consumes
that derived manifest instead of maintaining a second table. Unit tests enforce
that runtime ABI boxing and ownership coverage stay connected. Channel timeout
helpers now also define non-positive timeouts explicitly as immediate polls,
including on fiber-backed waits, instead of relying on runtime deadline
arithmetic side effects.

Migration impact: channel producer code should switch from `close` wording to
`seal` wording.

Stop condition: examples can express backpressure and completion without hidden
failure modes, and channel runtime primitives cannot be added without explicit
ownership and ABI-boxing coverage.

### Phase 7: Timeout And Deadline Syntax

Goal: expose cancellation only after the runtime and task-result types can
support it.

Open ergonomic choice for whole-scope deadlines:

Option A: timeout scope around ordinary code.

```blorp
with timeout(2.seconds):
	concurrent:
		users = fetch_users()
		orders = fetch_orders()
```

Pros: keeps `concurrent:` argument-free. Cons: `with` may look resource-like.

Option B: dedicated deadline block.

```blorp
deadline 2.seconds:
	concurrent:
		users = fetch_users()
		orders = fetch_orders()
```

Pros: visually distinct from resources. Cons: new control-flow syntax.

Avoid adding new options to the `concurrent` block keyword itself. The current
implementation still accepts `concurrent(timeout: N):` and
`concurrent(max_threads: N):` as existing compatibility/current behavior, but
the target teaching shape for fixed child tasks remains the bare
`concurrent:` block. New timeout work should harden the existing runtime/core
deadline behavior first, then decide whether whole-scope deadlines graduate to
a surrounding timeout construct instead of expanding the `concurrent(...)`
surface further.

Recommended migration: start with runtime/core deadline support and per-wait
timeouts. Defer whole-scope syntax until `TaskResult[T]` and cleanup behavior
are proven.

For dynamic fan-out, keep loop-wide and item-wide timeouts distinct:

```blorp
for path in paths concurrently(
	limit: 128,
	timeout: 30.seconds,
	item_timeout: 1.second,
):
	index_file(path)
```

Tests:

- Whole-scope timeout cancels every unfinished child.
- Item timeout cancels only that item task.
- Nested deadlines choose the earlier deadline.
- Cleanup cannot be interrupted by ordinary cancellation once started.

Implementation status: existing compatibility timeout forms,
`concurrent(timeout: N):`, legacy `concurrent(timeout: N) for`, and
`for ... concurrently(limit: N, timeout: M)` now compute their block/loop
deadline through shared runtime helpers. The helpers define non-positive
timeouts as immediate deadlines, round positive remaining times up to avoid
premature zero-millisecond joins, and saturate very large deadlines instead of
letting generated C open-code overflow-prone arithmetic. This is deliberately a
runtime/core hardening step, not new timeout syntax.

Migration impact: no existing code should need changes until timeout syntax is
introduced.

Stop condition: timeout behavior is predictable in nested concurrent/resource
programs.

### Phase 8: Resource-Aware Helpers

Goal: make per-item resource acquisition pleasant without allowing `?=` in loop
or task bodies.

Work:

- Add resource-aware result helper:

```blorp
Result[R, E].with_resource(func(resource: borrow R) -> T) -> Result[T, E]
```

- Enforce that the callback cannot return the resource or scoped-derived values.
- Ensure cleanup runs on normal return, error return, and cancellation.
- Keep `?=` unavailable in loops and task bodies.

Target pattern:

```blorp
for path in paths concurrently(limit: 128):
	_ = open_read(path)
		.with_resource(func(reader):
			reader.count_lines().unwrap_or(0)
		)
		.map(func(n): counts.wait_send(n))
```

Tests:

- Callback cannot return a resource, stream, cursor, or borrow.
- Cleanup runs when callback is cancelled during a wait.
- Type errors explain `with_resource` as the replacement for `?=` in loop
  bodies.

Migration impact: examples that want `with reader ?= open_read(path)` inside a
concurrent loop migrate to `open_read(path).with_resource(...)`.

Stop condition: file/database examples can acquire resources per task without
special syntax.

### Phase 9: Resource Sources

Goal: represent resource-producing iteration directly.

Work:

- Add explicit `ResourceSource[R, E]`.
- Reject collection and storage of resource sources in ordinary aggregates.
- Support sequential `for` over resource sources.
- Support concurrent `for ... concurrently` over resource sources by moving
  each resource item into the child task.
- Represent source-error policy explicitly.

Open ergonomic choice for source errors:

Policy argument:

```blorp
for conn in listener.connections(on_error: Continue) concurrently(limit: 4096):
	handle_connection(conn)
```

Event stream:

```blorp
for event in listener.events():
	match event:
		Connected(conn): handle_connection(conn)
		AcceptFailed(err): log(err)
```

Manual accept loop:

```blorp
while True:
	match listener.accept():
		Ok(conn): handle_connection(conn)
		Err(err): log(err)
```

Recommendation: start with a source-level error policy. The event-stream form
is attractive, but resource-carrying union variants need a broader
resource-aware union design.

Tests:

- Resource item cannot be used after transfer into a task.
- Child task cleanup owns transferred resource cleanup.
- Source errors follow the selected explicit policy.
- Resource source cannot be collected into `List[R]`.

Migration impact: TCP/database/file-walk code can move from manual accept/open
loops to resource-producing iteration once this phase lands.

Stop condition: the compiler can prove every produced resource has one cleanup
owner.

### Phase 10: `select` For Ordinary Waitables

Goal: add multi-source waiting after channels, timers, cancellation, and waiter
unregistration are correct.

Work:

- Start with channels and timers only.
- Specify fairness: round-robin or pseudo-random among ready branches.
- Ensure losing branches unregister their waits.
- Ensure cancellation unregisters all waits.
- Keep selected branch execution synchronous in the current task.

Syntax sketch:

```blorp
select:
	msg from inbox:
		handle(msg)

	_ after 1.second:
		flush()

	sealed shutdown:
		break
```

Alternative method-like sketch:

```blorp
select:
	inbox.recv() as msg:
		handle(msg)

	timer.after(1.second):
		flush()
```

Recommendation: keep the source-like syntax for readability, but implement only
ordinary waitables first. Resource-producing waits can come later.

Tests:

- Ready branches do not starve.
- Losing waits unregister.
- Timeout and cancellation unregister waiters.
- `sealed ch:` behaves consistently with `recv(ch) -> None`.

Migration impact: event loops can choose `select`; ordinary event-channel loops
remain valid and recommended by default.

Stop condition: channel/timer select is solid before accepting resources from
select branches.

### Phase 11: Resource-Producing `select`

Goal: allow `select` branches to produce scoped resources without escape.

Work:

- Limit a resource-producing branch to one scoped resource at first.
- Scope the resource to the selected branch body.
- Reject returning the resource, storing it, sending it over ordinary channels,
  or capturing it in child tasks unless an explicit transfer/borrow rule allows
  it.

Sketch:

```blorp
select:
	conn from listener.connections():
		handle_connection(conn)

	sealed shutdown:
		break
```

Tests:

- Selected resource cannot escape branch.
- Losing resource waits do not acquire resources.
- Cancellation during select unregisters waits and cleans selected resources if
  branch execution has started.

Migration impact: high-concurrency servers can wait on shutdown and accepts
without bridge tasks.

Stop condition: branch-scoped resources are represented explicitly in typed
AST/Core.

### Phase 12: TCP Resource Migration

Goal: migrate TCP only after resource sources, cancellation, and ordinary
select are ready.

Work:

- Define TCP listener and stream as resources:

```blorp
resource type TcpListener = builtin("blorp_tcp_close_listener")
resource type TcpStream = builtin("blorp_tcp_close_stream")
```

- Add typed `TcpError`.
- Provide `connections(listener) -> ResourceSource[TcpStream, TcpError]`.
- Keep DNS limitations explicit.
- Add `split(stream)` only if reader/writer resources can be represented as
  distinct ownership roles.

Migration sketch:

```blorp
func serve() -> Result[Void, TcpError]:
	with listener ?= tcp.listen("", 8080, 1024):
		for conn in listener.connections(on_error: Continue) concurrently(limit: 4096):
			handle_connection(conn)

	Ok(Void)
```

Tests:

- Listener cleanup cancels/joins accept-loop children correctly.
- Connection cleanup runs on normal return, protocol error, timeout, and
  cancellation.
- The detached TCP repro shape is rejected with a diagnostic pointing to
  resource-source iteration or per-task acquisition.
- Socket waits park virtual tasks rather than pinning OS workers.
- Hostname resolution docs match runtime behavior.

Migration impact: old typed ARC TCP handles should either keep working through
a compatibility layer or produce diagnostics pointing to `with` and
resource-source iteration.

Stop condition: TCP examples are resource-safe without special cases in codegen.

### Phase 13: Services And Pools

Goal: support database clients, loggers, metrics, DNS resolvers, and HTTP
client pools without pretending they are ordinary immutable values.

Work:

- Decide whether `service type` is a language declaration or compiler-recognized
  std/package metadata.
- Ensure services cannot expose shared mutable Blorp memory.
- Document whether each service method parks fibers, uses a blocking pool, or is
  pure local work.
- Add a fake DB connector test package before relying on real native bindings.

Sketch:

```blorp
with pool ?= db.pool(url, max_connections: 32):
	for query in queries concurrently(limit: 128):
		_ = pool.checkout()
			.with_resource(func(conn):
				conn.query(query).map(process_rows)
			)
```

Tests:

- Shareable service capture is allowed where ordinary resources are rejected.
- Service checkout produces scoped resources.
- Pool limits apply backpressure without blocking OS workers.

Migration impact: database and HTTP users get a safe path for shared external
systems.

Stop condition: services have a named type-system story, not a convention.

### Phase 14: Detach And Legacy Cleanup

Goal: leave one simple, sound default concurrency story.

Work:

- Demote `detach` to an explicit escape hatch.
- Reject resource capture in detached work.
- Document detached work as process-lifetime background work.
- Remove or hard-error old `concurrent for` after a migration window.
- Remove channel `close` alias after the channel `seal` migration window.
- Update guide, grammar, examples, benchmarks, and doctests.

Tests:

- `detach` cannot capture resources or scoped-derived values.
- `detach handle_client(stream)` with a TCP stream resource is a compile-time
  error, not a runtime ownership convention.
- Old syntax errors include a precise replacement.
- Preview examples use only the new concurrency model.

Migration impact: remaining legacy code receives actionable diagnostics.

Stop condition: the language has one primary concurrency path:

```text
concurrent:                    fixed child tasks
for ... concurrently(limit:)   dynamic fan-out
Channel[T] + seal              communication and completion
with                           resources
select                         independent waits
services                       intentionally shared external systems
```

## Next Implementation Queue

The branch is ready to continue, but the next changes should stay narrow. The
high-leverage sequence is:

1. Close the ordinary fan-out compatibility gap. `for ... concurrently(limit:)`
   is implemented for `List[T]`, but it still returns the historical
   `List[Result[T, ConcurrencyError]]`. Do not make it statement-only until
   `map_concurrently` or an equivalent explicit result-collection helper exists
   with tests and migration diagnostics.
2. Choose the fixed-task result contract before adding more timeout syntax.
   Existing fixed `concurrent:` bindings use `Result[T, ConcurrencyError]`.
   A dedicated `TaskResult[T]` remains open and should be settled before adding
   whole-scope deadline syntax or richer cancellation policies.
3. Keep channels ahead of `select`. Channel waiter unregistration, `seal`, and
   typed send attempts are now covered well enough to support a future ordinary
   channel/timer `select`, but do not start resource-producing `select` until
   resource ownership in branches is explicit in typed AST/Core.
4. Keep TCP out of the next slice. TCP should wait until ordinary deadlines,
   resource-aware helpers, resource sources, and ordinary `select` have stable
   semantics.

Each slice should add a failing parser/typecheck/runtime or codegen-audit test
first, and should update this queue if implementation reveals a simpler or
safer order.

## Open Questions To Settle Before Implementation

- Should fixed `concurrent:` bindings use a concrete `TaskResult[T]` union, a
  type alias over `Result[T, ConcurrencyError]`, or a construct-specific failure
  policy?
- Should whole-scope timeouts use `with timeout(duration):`, a dedicated
  deadline block, or options on individual concurrency constructs?
- Should plain `send` exist, or should channel operations always say
  `try_send`, `wait_send`, or `send_timeout`?
- Should scoped channel-seal guards use `with sealing ch:`, a callback helper,
  or an endpoint type?
- Should nested concurrent scopes support inherited budgets in addition to
  local `limit` values?
- Should CRDT-style concurrent accumulators be a standard-library feature,
  package feature, or language-recognized trait family?
- Should `select` use `msg from ch` syntax, method-call syntax, or pattern
  syntax?
- Should resource-producing `select` branches be limited to one resource per
  branch?
- What is the exact source-error policy for `ResourceSource[R, E]` in
  concurrent loops?
- Should resource-aware result combinators be called `with_resource`, `using`,
  or something shorter?
- Should services be a new declaration kind or a standard-library convention
  backed by compiler metadata?

## Release Gates

Before removing legacy concurrency paths, run:

- parser, infer, typecheck, formatter, codegen-audit, runtime, doctest, and
  leak-check suites;
- cancellation tests for every blocking operation that can park a task;
- generated C review for task-scope cleanup and waiter unregistration;
- preview examples that cover files, channels, timeouts, nested fan-out,
  `concurrent:`, `for ... concurrently`, and at least one service/pool example;
- scheduler instrumentation smoke tests showing active, parked, cancelled, and
  timed-out task counts.
