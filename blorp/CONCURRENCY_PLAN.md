# Concurrency plan

**Status: plan, 2026-11-24.** Keith started landing 1 after Spike P. It was
revised after two rounds of review.
- **Round 1:** four reviews of the API, strategy, ergonomics and
  implementation plan.
- **Round 2:** three reviews of soundness, safety and ergonomics.
- **Folded in:** both rounds; see [Reviews](#reviews).
- **Decisions:** Keith has settled every design decision; see
  [Decisions](#decisions).
- **Order:** pure tasks, which run in parallel, come first, and a spike comes
  before each half.
- **Spike P ran on 2026-11-24.** The verdict is to continue, with three
  design changes; see [Spike P results](#spike-p-results).

**Keith's direction:**
- a minimal set of runtime constructs that combine into the concurrency APIs;
- concurrency that feels consistent, blorpy and safe;
- virtual threads, and no blue/green (`async`) functions;
- parallelism separate from concurrency, and pure;
- a clear way to handle timeouts, with a `first:` block;
- the fiber implementation written in Blorp, with no OS thread primitive
  reachable by users;
- the core capabilities only, erring on the side of simplicity.

## Problem

Blorp has no concurrency. The language principles promise it: thread safety
by default (principle 3), and `concurrent:` blocks with no orphaned tasks
(principle 15). The compiler and its library have neither threads nor fibers.

The retired compiler had `concurrent:` blocks, `concurrent for`, `detach`,
channels and minicoro fibers. Its notes record what went wrong:
- **Timeouts were per join.** `concurrent(timeout: 100):` gave each join a
  fresh 100 ms, so N tasks could take N × 100 ms.
- **Channel bugs.**
  - A timed-out receive left its fiber in the wait queue: a use after free.
  - A channel freed without `close` never woke its waiters.
  - Sleeping fibers leaked at shutdown.
- **Costs that defeated parallel work.** Parsing 405 files through tasks ran
  about 3× slower than serially, for two reasons:
  - cancellation bookkeeping walked a per-task cleanup stack on every
    reference-count increment and decrement;
  - yield points inserted in loops migrated CPU-bound fibers between threads.
- **Fixed stacks.** A 256 KiB default fiber stack crashed on deep recursion.

This design keeps the old model's good shape, structured blocks, and removes
the machinery behind those failures.

## The model

Blorp's value model already does most of the hard part:
- assignment copies;
- closures capture immutable values by value and cannot capture a `var`;
- values never form cycles;
- every reference-count operation is atomic, and every copy-on-write
  uniqueness test is an acquire load, so a task that updates a value it
  shares with another task copies it instead of writing in place.

Atomic counts make sharing safe, not free. Tasks that retain one shared
value contend on its count: in Spike P, four threads retaining one table per
element ran at half the speed of one thread.

So **no two tasks can share mutable state**, and data races are impossible
by construction. No `Send`/`Sync`-style classification is needed: every
value may move between tasks. The one new kind of value is a channel, a
handle whose copies refer to one queue; the `Message` bound under
"Channels" keeps it from breaking principle 2.

Six rules:

1. **Two mechanisms, one block.**
   - **Where each task runs.** Each direct statement of a `concurrent:` block
     is a task. Whether it is pure, meaning it calls nothing impure, is a
     fact check publishes once. A pure task runs on a pool of OS threads, in
     parallel; an impure task runs as a fiber, and waits on time, I/O and
     other tasks.
   - **Purity.** A block of only pure tasks may appear in a pure function.
   - **The other two forms always use fibers.** `concurrent for` and
     `concurrent_map` take bodies whose purity they cannot see. Pure data
     parallelism is `parallel_map`.
   - **Why one block.** For pure work, the first draft's two blocks computed
     the same thing and differed only in speed, so Keith merged them
     (decision 16). The two mechanisms stay separate.
2. **Every task belongs to a block that waits for it.** Nothing outlives the
   block that started it, so there is no `detach`.
3. **Blocking is ordinary.** Any impure function may block, and blocking
   parks the fiber, not the carrier thread. There is no `async`, no `await`,
   and no function colour.
4. **Cancellation means that everything you wait on closes.** A cancelled
   task is never interrupted mid-computation, and nothing unwinds.
   - **Waits return at once,** and each still yields to the other fibers:
     - `sleep` returns early;
     - `receive` returns `None`, and `send` returns `False`;
     - each native returns as "Cancelling natives" says.
   - **Nested blocks.** A block nested in a cancelled task passes the
     cancellation to its own tasks and still waits for them. Tasks started
     inside a cancelled task start cancelled.
   - **A cancelled `first:`** with no winner yet returns `Timeout`, whether or
     not it has a deadline. One that already has a winner keeps it.
   - **Pure work is not cut short.** It runs to its end, so a deadline bounds
     waits, not computation.
   - **The task then runs to its end.** Blorp has no exceptions, so no
     cleanup stack is needed.
5. **A task can ask whether it was cancelled.** `cancelled()` returns `True`
   once it was. A loop that carries on after a `Timeout` or a `sleep` tests
   it, or it would spin once cancelled.
6. **Time belongs to the runtime.** In tests the clock is virtual, so a
   one-minute timeout takes no real time.

## Usage

### Pure tasks, which come first

A pure task runs on every core and gives exactly what the serial code gives.
A `concurrent:` block whose tasks are all pure may be used in a pure
function, and so may `parallel_map`.

```blorp
pure func scores(lines: List[String]) -> List[Int]:
    lines.parallel_map(score)                    -- List[Int]; score must be pure; the order is kept


pure func summary(samples: List[Float]) -> Summary:
    concurrent:                                  -- pure, because both tasks are
        mean: Float = samples.mean()             -- runs on the pool
        spread: Float = samples.spread()         -- runs on the pool
    { mean = mean, spread = spread }


-- Nesting is allowed: a thread waiting on a join runs other work meanwhile,
-- so an inner parallel_map cannot starve the outer one.
pure func score_files(files: List[List[String]]) -> List[List[Int]]:
    files.parallel_map(scores)
```

A block may mix the two kinds of task, each running where it fits:

```blorp
func check_and_score(target: Path, lines: List[String]) -> Report:
    concurrent:
        tests: Result[Captured, CaptureError] = capture(test_command(target))   -- impure: a fiber
        scores: List[Int] = lines.parallel_map(score)                           -- pure: the pool
    report(tests, scores)
```

**Order of a mixed block.** The block starts its fibers, runs its pure
tasks' joins from the parent, which parks meanwhile, then waits for the
fibers.

**Where a task runs follows from purity, not from the line.** Adding a
`print` to a pure task makes it impure, moving it from the pool onto the
fibers. An impure task shares one carrier thread with every other fiber, so
CPU-heavy impure work does not run in parallel; make it a pure task. The
README's rule that purity is "declared and checked, never inferred" stays
true for functions; a task's purity is checked from what it calls.

A pure task never waits, never does I/O and is never cancelled. So it runs
on the pool with no fiber, no cancellation state and no yield points:
exactly the costs that made the old parallel parse slower than serial.

Two natives carry it, on a pool of OS threads with work stealing:
- **`join`,** as in Rayon, runs two pure callables, possibly at once, and
  returns both results. A block's pure tasks are nested joins.
- **`parallel_map`** is native and specialized per callback, so each element
  is a direct call with no closure. It writes into a List sized up front,
  with one allocation, and splits adaptively, as Rayon does, down to a piece
  of one element.
  - **Native, not Blorp.** Spike P found that recursive halving written in
    Blorp, appending at each leaf and concatenating at each level, ran 3.3×
    slower than `map` on one thread, and never beat it.
  - **Adaptive, not fixed.** No fixed chunk size fits every workload: a
    nested map needed pieces of one element, and the cheapest elements
    needed about 256 per piece.

Its jobs live on the joining thread's stack and its result is allocated once,
so how it splits never shows in any count.

**Allocation counts.** In Spike P, counts were identical at 1 and 4 threads
and from run to run, and they stay so for every program. A task borrows its
environment from the joining code, which holds it until the join returns, so
a task never finds a captured value unique: a task that updates one always
copies it, whatever the timing. The landing-2a review found the same counts
and peak heap in 30 runs of each of 1 and 4 threads with two tasks growing
one captured List. Peak heap can still differ, since it depends on the order
in which tasks allocate.

### The concurrency MVP

The first concurrency release is:
- the `concurrent:` and `first:` blocks;
- `First`, the time functions and `cancelled`.

Fibers run on one carrier thread, and `main` is the first fiber. The
existing blocking natives (files, console, processes) park the fiber while a
helper thread makes the call; a program that starts no task never uses the
helpers.

**Run several things and wait for all of them.** Each statement directly in
a `concurrent:` block runs as its own task. The block ends when every task
has finished, and its bindings are visible after it.

```blorp
import:
    io/process: Command, Captured, CaptureError, capture

func check_all(target: Path) -> Report:
    concurrent:                          -- these three run at the same time
        format: Result[Captured, CaptureError] = capture(format_command(target))
        tests: Result[Captured, CaptureError] = capture(test_command(target))
        docs: Result[Captured, CaptureError] = capture(docs_command(target))
    report(format, tests, docs)          -- Report
```

**Take whichever finishes first; this is how every timeout is written.**
`first:` is an expression whose branches run at the same time. The first to
finish gives the value; the others are cancelled and waited for before the
block returns.

**Every `first:` returns `First[A]`,** with or without a deadline:

```blorp
union First[A]:
    Finished(A)                          -- a branch finished first, with this value
    Timeout                              -- the deadline came first, or the block was cancelled
```

- **The work branches all have type `A`,** typed as `if` and `match` arms
  are: by the annotation's `A` when there is one, or else by the first work
  branch. There must be at least one.
- **`timeout(duration)` is the block's deadline,** not a branch with a value.
  - It is written as a line directly in the block, at most once, by
    convention as the first line. If it comes first, the block gives
    `Timeout`.
  - Its argument is evaluated before the race.
  - The checker recognizes it by what the call resolves to, the designated
    `concurrency.timeout`, in either call syntax. Any other use of
    `timeout`, such as a binding or a function value, is an error.

```blorp
import:
    concurrency: First(Finished, Timeout), timeout
    time: seconds

func run_with_deadline(command: Command) -> First[Result[Captured, CaptureError]]:
    first:                               -- both run; the first to finish wins
        timeout(seconds(30))             -- the deadline: Timeout after 30 s
        capture(command)                 -- Result[Captured, CaptureError]
```

A `match` covers each common shape:

```blorp
-- A timeout as an error, when the work already returns a Result.
func fastest_mirror(path: Path) -> Result[Page, String]:
    answer: First[Result[Page, String]] = first:
        timeout(seconds(25))
        fetch(mirror_a, path)            -- Result[Page, String]
        fetch(mirror_b, path)            -- Result[Page, String]
    match answer:
        Finished(result): result         -- result: Result[Page, String]
        Timeout: Err("no mirror answered within 25 seconds")


-- A fallback value.
fetched: First[Rate] = first:
    timeout(milliseconds(500))
    fetch_rate()                         -- Rate
rate: Rate = match fetched:
    Finished(fresh): fresh               -- fresh: Rate
    Timeout: cached_rate


-- One deadline around a whole group, nested blocks included.
checked: First[Report] = first:
    timeout(seconds(5))
    check_all(target)                    -- Report; check_all runs a concurrent: block
```

**When several branches are ready at once,** the winner is chosen at random
among them, as Go's `select` does, so no branch can starve. Under `simulate`
the choice comes from the seed. A deadline and a branch that finish at the
same virtual instant are ready together.

**Two costs of one type.**
- **A race with no deadline still has a `Timeout` arm.** It is taken only
  when the block is cancelled, so it usually means "this was abandoned".
- **`Finished(Err(message))`** means a branch finished first, with an error.

**Wait, and notice cancellation.**

```blorp
-- A ticker that stops once the first: it runs under has decided.
func tick_until_cancelled() -> Void:
    while cancelled().not():
        sleep(seconds(1))
        print("still working")
    void
```

The MVP surface:
- `concurrent:` and `first:`;
- `First`, with `Finished` and `Timeout`;
- `sleep`, `timeout` and `cancelled`;
- `Duration`, with `milliseconds` and `seconds`;
- `concurrent_map`, below, which needs no channels;
- the testing entry point `simulate`.

### Concurrent loops and bounded fan-out

**`concurrent for` runs each iteration as its own task,** always as a fiber,
and waits for all of them, wherever it appears. A plain `for` is always
sequential, even inside `concurrent:`. A line therefore shows on its face
whether it fans out.

```blorp
-- One task per file. The close runs once every iteration has finished.
-- concurrent for starts every iteration at once: for many paths, use a
-- bounded worker pool, as below.
func read_all(paths: List[Path], lines: Channel[String]):
    concurrent for path in paths:
        send_lines(path, lines)
    lines.close()
```

`concurrent for` has no bound, and each iteration is a fiber. Linux allows
about 32,000 of them at its default mapping limit, so bound any loop over
data of unknown size. For a bound, or for results in input order, use
`concurrent_map`:

```blorp
union Outcome:
    Passed(Captured)
    Failed(CaptureError)
    TimedOut


-- At most four suites run at once, each with its own deadline.
func run_suites(suites: List[Suite]) -> List[Outcome]:
    suites.concurrent_map(4, run_one)


func run_one(suite: Suite) -> Outcome:
    reply: First[Result[Captured, CaptureError]] = first:
        timeout(seconds(60))
        capture(suite.command())         -- Result[Captured, CaptureError]
    match reply:
        Finished(Ok(output)): Passed(output)
        Finished(Err(error)): Failed(error)
        Timeout: TimedOut
```

`parallel_map` takes a pure function and no bound, because the pool already
has one thread per core. `concurrent_map` takes any function, through an
ordinary parameter, and requires a bound, because waiting work has no
natural limit. A limit below 1 is treated as 1.

**Work that discovers more work** nests blocks, so each task's parent stays
visible:

```blorp
func check_tree(directory: Path) -> List[Problem]:
    concurrent:
        here: List[Problem] = check_files(directory)
        below: List[List[Problem]] = directory.subdirectories().concurrent_map(4, check_tree)
    here.concat(flattened(below))
```

There is no task-group value: Keith left `with_tasks` and `start` out. A
group a task cannot capture would add closures and no capability.

### Channels

A channel is one handle, `Channel[T]`. Copies of the handle refer to one
queue, so it is the one value whose copies alias, and for that reason it has
no `==`. Its operations are impure, and the kernel synchronizes them.

| Operation | Result | Behaviour |
| --- | --- | --- |
| `channel(capacity)` | `Channel[T]` | the element type comes from an annotation; capacity 0 is a rendezvous, a negative capacity is 0, and no buffer is allocated up front |
| `send(value)` | `Bool` | parks while the buffer is full; `True` once the value is buffered or handed over, `False` if the channel is closed or the task cancelled |
| `receive()` | `Option[T]` | parks while it is empty; `None` once closed and drained, or when cancelled |
| `close()` | `Void` | wakes parked receivers once the buffer drains, and wakes parked senders with `False`, dropping their values; closing twice does nothing |
| `for item in channel:` | a loop | receives until `None` |

Waiters are served first in, first out.

**A pipeline: producers and a consumer, in one block.**

```blorp
import:
    concurrency: Channel, channel

-- Reads every file at once and totals the scores of their lines.
func total_score(paths: List[Path]) -> Int:
    lines: Channel[String] = channel(64)
    concurrent:
        read_all(paths, lines)                   -- one task: every reader, then close
        total: Int = sum_scores(lines)           -- another task, running alongside
    total


func sum_scores(lines: Channel[String]) -> Int:
    var total: Int = 0
    for line in lines:                           -- ends once the channel is closed and drained
        total = total + score(line)
    total
```

Forgetting `lines.close()` in `read_all` ends in a deadlock report. Its help
depends on the kind of wait:

```text
deadlock: every task is waiting
  sum_scores (total.brp:14) waits to receive on the channel made at total.brp:5
help: a channel ends only when it is closed; call close() after its last producer finishes
```

**A worker pool: four workers share one queue.**

```blorp
func process_all(jobs: Channel[Job], results: Channel[Outcome]):
    concurrent for _ in 0..4:
        work(jobs, results)
    results.close()


func work(jobs: Channel[Job], results: Channel[Outcome]):
    for job in jobs:
        if results.send(run(job)).not():
            break
    void
```

A `concurrent for` over a channel starts one task per item, as fast as they
arrive. The worker pool is its bounded form.

**Choosing between channels.** A `first:` branch that is one channel
operation, a call that resolves to `receive` or `send` in either call syntax,
commits exactly once. It may be alone or the sole payload of a variant
constructor. Its channel and value expressions are evaluated before the race,
in source order. A losing `receive` takes no value, and a losing `send`
delivers none.

A channel operation anywhere else inside a `first:` branch is rejected,
because it could lose a value it had already received. That includes
`jobs.receive().map(JobReceived)`. A channel never pairs two waiters of the
same selection, so `first: c.send(1); c.receive()` cannot commit both. This
replaces a `select` statement:

```blorp
union Event:
    JobReceived(Option[Request])
    StopRequested(Option[String])


func next_event(jobs: Channel[Request], stop: Channel[String]) -> First[Event]:
    first:
        timeout(seconds(5))
        JobReceived(jobs.receive())              -- Event; jobs.receive() is Option[Request]
        StopRequested(stop.receive())            -- Event; stop.receive() is Option[String]


func serve(jobs: Channel[Request], stop: Channel[String]):
    var running: Bool = True
    while running.and(cancelled().not()):
        event: First[Event] = next_event(jobs, stop)
        match event:
            Finished(JobReceived(Some(request))): handle(request)     -- request: Request
            Finished(JobReceived(None)): running = False              -- jobs closed
            Finished(StopRequested(_)): running = False               -- a stop, or stop closed
            Timeout: report_idle()
    void
```

**The `Message` bound.** A channel's element type must be a `Message`: a type
containing no `Channel` and no callable, at any depth. Otherwise
`inbox.send(Reply(inbox))` would leave a queue holding itself, and a queued
closure could capture its own channel; neither would ever be freed.
- **It is derived like automatic equality,** from the type's structure. It
  looks through opaque representations, ignores phantom parameters, and is
  checked at every substitution.
- **Generic channel code restates it,** as every declaration bound in Blorp
  is restated:

```blorp
func boxed[T: Message](value: T) -> Channel[T]:
    inbox: Channel[T] = channel(1)
    delivered: Bool = inbox.send(value)
    inbox
```

Without the bound, `boxed` is rejected at `Channel[T]`, with the message
`Channel[T] requires T: Message` and the help `add Message to T's bounds`. A
concrete type that fails names the path to the offending part, as in
`Channel[Envelope] cannot carry Envelope.reply, a Channel`. Keith accepted
that queues of closures are ruled out.

**Why `close` is explicit.** Closing a channel when its last sender was
released would make a program's behaviour depend on where the ownership
phase ends each value's last obligation. The README says those labels
"change where a program copies, never what it computes". The rule also has
exceptions, such as a value a loop iteration inherits, which ends at the back
edge. An explicit `close` is placed by the code that knows producing is done,
usually after a `concurrent for`, as in `read_all`.

### Cancelling natives

A losing branch or a cancelled task may be inside a native. Each one has a
defined result. A native called in a task that is already cancelled returns
that result at once, without starting anything.

| Native | When cancelled |
| --- | --- |
| `capture` | Kills the child's process group and returns `Ok`, with the `Exit` `Cancelled`. Its existing poll loop gains a cancel descriptor. `Cancelled` replaces `TimedOut`, which goes with `Command.timeout_ms`. |
| `output` | The same kill, returning `Err(Unsuccessful(Cancelled))`, since it returns `Ok` only for an exit of 0. |
| `run` (terminal) | Its child shares the program's process group, so a group kill would kill the program. It sends SIGKILL to the child's own PID, under a per-call lock, using the reservation `blorp_process_reap` already keeps against a reused PID. Grandchildren survive. |
| `read_line`, `read_exact` | Return end of input, `Ok(None)`. The kernel owns stdin, with one buffer behind a line lock, and polls it rather than setting `O_NONBLOCK` on a descriptor the parent shares. A cancelled read keeps any partial line for the next reader. |
| `print`, `write`, `flush` | Not cancellable. The output still happens, under a line lock so lines never tear. A write to a full pipe can block without bound. |
| File reads and writes | Regular files are bounded and not cancellable. A non-regular file, found by `fstat`, is unbounded, cancellable and poll-based like the console: a FIFO, `/dev/stdin` or a terminal. |
| `sleep`, `receive`, `send`, joins | As rule 4 says. |

`first:` is how every timeout is written. So once `capture` is cancellable,
`Command.timeout_ms`, an `Int` of milliseconds, goes, in the same landing
(root `AGENTS.md`, rule 14).

### Where failures and cancellation come from

**Concurrency adds no error type of its own.** A task always runs to its
end and produces a value of its own type, so `concurrent:` bindings are not
wrapped (decision 15). The old compiler's `Result[A, ConcurrencyError]`
existed for task failures and per-join timeouts, and neither exists now.

| Failure | Where it shows up |
| --- | --- |
| The network, a file, a process | the I/O function's own `Result` |
| A deadline | `First[A]`'s `Timeout`, where `timeout(...)` is written |
| Cancellation | each wait's closed or error case, `cancelled()`, and `Timeout` from a cancelled `first:` |
| Out of memory, fiber stack overflow, too many fibers | stops the program with a message, as an out-of-memory error does today (principle 1) |
| Deadlock | stops the program with a report, or `Err(Deadlock)` under `simulate` |

```blorp
func load_dashboard(user: UserId) -> Result[Dashboard, FetchError]:
    concurrent:
        profile: Result[Page, FetchError] = fetch(profile_url(user))
        orders: Result[Page, FetchError] = fetch(orders_url(user))
    profile_page: Page ?= profile        -- ?= is allowed after the block, not inside a task
    orders_page: Page ?= orders
    Ok(dashboard(profile_page, orders_page))
```

**Cancellation starts only at `first:`:**

| Source | What it cancels |
| --- | --- |
| A `first:` that has a winner, or whose deadline came first | its losing branches |
| A cancelled task | every block nested inside it |
| `concurrent:` | nothing: one task's `Err` does not stop its siblings |
| The runtime, under `simulate`, on a deadlock | every parked fiber, so each can end before `Err(Deadlock)` |

So a `concurrent:` block is only ever cancelled as a whole, when the `first:`
above it has already decided not to use its result:

```blorp
checked: First[Report] = first:
    timeout(seconds(5))
    check_all(target)                    -- Report
```

If the deadline comes first:
1. `check_all`'s block passes the cancellation to its tasks.
2. Each `capture` kills its child and returns `Ok`, with the `Exit`
   `Cancelled`.
3. `check_all` builds a `Report` from them.
4. `first:` discards that `Report` and returns `Timeout`.

**Two consequences to design around.** Code after a cancelled block still
runs, because nothing unwinds.
- **Do lasting effects after the race, in the `Finished` arm.** A check
  inside the branch, such as `if cancelled().not(): save(result)`, checks
  then acts, so a non-cancellable write that has started still completes
  after the branch has lost.

  ```blorp
  checked: First[Report] = first:
      timeout(seconds(5))
      check_all(target)                  -- Report
  match checked:
      Finished(report): save(report)     -- only a winning result is saved
      Timeout: print("the checks took longer than 5 seconds")
  ```

- **Keep a channel's producers and consumers in the same race branch.** A
  cancelled producer still runs its `close`, so a consumer outside the
  branch would see a normal end of a truncated stream. Where they must be
  apart, send an explicit last value.

`cancelled()` is `True` only under a `first:` that has already decided. At a
program's top level, it is always `False`.

### Deadlocks

**Among the waits users write, only channels can deadlock.** The only other
wait is a block waiting for its own tasks. There is no task-handle value, so
a task cannot hold its parent or a sibling and wait on it: the waits between
blocks form a tree, and a tree has no cycle. Pure tasks never wait at all,
and users have no locks, so there are no lock-ordering deadlocks either. The
runtime's own risks are under "Inside the runtime", below.

These are the ways a channel can deadlock:

**1. A forgotten `close`,** the most common:

```blorp
func read_all(paths: List[Path], lines: Channel[String]):
    concurrent for path in paths:
        send_lines(path, lines)
    -- lines.close() is missing, so `for line in lines` in sum_scores waits forever
```

**2. The consumer after the block that feeds it:**

```blorp
results: Channel[Int] = channel(0)               -- a rendezvous: each send waits for a receive
concurrent:
    produce(results)                             -- parks on its first send: nobody receives yet
total: Int = sum_all(results)                    -- would receive, but runs only after the block
```

Make the consumer a task in the same block.

**3. A task that waits on itself:**

```blorp
inbox: Channel[Int] = channel(1)
first_sent: Bool = inbox.send(1)                 -- fits in the buffer
second_sent: Bool = inbox.send(2)                -- parks: the only receiver is this task, later
```

**4. Two tasks each waiting on the other:**

```blorp
concurrent:
    left: Option[Int] = ping(to_right, from_right)   -- receives from from_right, then sends
    right: Option[Int] = ping(to_left, from_left)    -- receives from from_left, then sends
```

**5. A cycle of full buffers,** where stages send to each other's full
inboxes. Larger buffers move the problem rather than remove it.

**6. A `first:` with no deadline** whose branches all wait on channels nothing
will feed or close.

**A deadline ends every wait, but not every branch.** When a `first:`'s
deadline fires, the losers are cancelled, and their waits return. The block
returns once the losers finish. A loser that is computing, or that is
blocked in a native that cannot be cancelled, delays it.

**What the runtime detects.** A deadlock is reported when every fiber is
parked, and no timer, I/O, pool work or queued native is pending:

| Case | Detected |
| --- | --- |
| Cases 1 to 6, when the rest of the program is also stopped | yes: the report names who waits on what, and where each channel was made |
| Two tasks deadlocked while another runs, such as a ticker or a long `sleep` | not until the rest of the program also stops |
| Waiting on outside I/O that never comes, such as an unclosed stdin or a child that never exits | no: that is a hang, not a deadlock, and `timeout` is the remedy |
| An impure task that never waits | no: on one carrier it also starves every other fiber |
| A cancelled loop that ignores its cancellation | no: test `cancelled()` in such loops |

**When a deadlock is found outside `simulate`,** the report is written to
stderr first. The program then stops without resuming any fiber, so no user
code runs on values computed under cancellation. It is an infrastructure
stop, like running out of memory: it uses the same exit, and it is exempt
from the strict leak check. Under `simulate`, every parked fiber is cancelled
and run to its end, and then the result is `Err(Deadlock)`. A cleanup run
that never ends hangs `simulate`.

**Inside the runtime,** these keep the kernel itself from deadlocking:
- **Channel choice.** A selection locks every channel it waits on in address
  order while it registers, as Go's `sellock` does. Its claim is a C
  compare-and-swap on the selection itself, so no other kernel lock is ever
  taken under a channel's.
- **The blocking pool.** A native that can wait without bound never waits
  for a free helper, as described under "The runtime".
- **No user code under a lock.** No trait method or other user function runs
  under a kernel lock.

**How users avoid deadlocks:**
- close each channel after its last producer, usually just after a
  `concurrent for`;
- make consumers tasks of the same block as their producers;
- put a `timeout` on any wait that depends on something outside the
  program;
- run `simulate` over many seeds, where a deadlock comes back as
  `Err(Deadlock)`.

### The whole surface

| Name | Kind | What it does |
| --- | --- | --- |
| `concurrent:` | block | each direct statement as a task, pure ones on the pool and impure ones as fibers; waits for all |
| `parallel_map(f)` | List method | pure data parallelism, in order |
| `concurrent for` | loop | each iteration as a fiber; waits for all |
| `concurrent_map(Int, f)` | List method | bounded fan-out, as fibers, in input order |
| `first:` | block | runs branches concurrently, takes the first, cancels the rest; always `First[A]` |
| `First[A]`, `Finished`, `Timeout` | union | what every `first:` returns |
| `timeout(Duration)` | clause of `first:` | the block's deadline |
| `sleep(Duration)` | function | parks the fiber |
| `cancelled() -> Bool` | function | whether this task was cancelled |
| `Duration`, `milliseconds`, `seconds` | type, constructors | a length of time |
| `Channel[T]`, `channel`, `send`, `receive`, `close` | type, functions | a bounded channel |
| `for item in channel:` | loop | receives until closed |
| `Message` | bound | a type a channel can carry |
| `simulate`, `elapsed`, `Deadlock` | function, function, type | the deterministic test runtime |

That is 2 blocks, two `for` forms, one bound, and about 15 functions and
types.

`Duration` is in the `time` module. It is `Equatable` and `Orderable`, its
constructors and arithmetic saturate, and a negative duration is zero.
Everything else is in `concurrency`. Its functions are impure, except
`milliseconds`, `seconds` and `parallel_map`, which are pure.

### The rules, and their messages

**Each task is checked as the body of an unscoped `func() -> T`** passed to
an ordinary parameter. Its purity is published from what it calls. The tasks
are:
- a direct statement of `concurrent:`;
- the body of `concurrent for`;
- a work branch of `first:`.

Today's closure rules then settle most cases with their existing messages:
- no `var` capture;
- no `break` or `continue` across a task;
- no resource and no scoped callable, because a closure capturing either is
  scoped, and an ordinary parameter rejects it.

The remaining rules are new. Each is checked at the earliest phase that can
see it, with an exact message, help and span:

| Rule | Example rejection, with help |
| --- | --- |
| A task may not use another task's binding from the same block | `orders is bound by this concurrent block, so the other tasks cannot use it` / `if a line needs orders, put it after the block` |
| A task may not use a resource | `writer is a resource, so a concurrent task cannot use it` / `open the resource inside the task` |
| `?=` is not allowed in a task | `?= cannot leave a concurrent task` / `match the result inside the task, or use ?= after the block` |
| A task may not assign an outer `var` | `a concurrent task cannot assign var total` / `bind the task's result, and assign it after the block` |
| A `concurrent:` block in a pure function has only pure tasks | `fetch(url) is impure, so this concurrent block cannot be in a pure function` / `remove pure from the function, or keep only pure tasks in the block` |
| `first:`, `concurrent for`, channels, time and `cancelled` are impure | `first is impure, so a pure function cannot use it` / `remove pure from the function` |
| `parallel_map`'s function is pure | `parallel_map needs a pure function: read_text is impure` / `use concurrent_map for impure work` (until landing 5, `use a for loop for impure work`) |
| A `first:` branch may not be pure | `solve(puzzle) is pure, so first: cannot stop it` / `run pure work before or after the race, as its own concurrent: task` |
| The work branches of `first:` have one type | `the branches of first: have different types: this one is Int, the first is Result[Page, String]` / `give every branch one type, for example by wrapping each in a variant of one union, as Event does` |
| `timeout(...)` is a clause of `first:`, used once | `timeout(...) is the deadline of a first: block, so it cannot be used here` / `timeout takes no value; write it once, directly inside first:, where it ends the block with Timeout` |
| A channel operation inside a `first:` branch is the whole branch | `jobs.receive() inside map(...) could lose its value if this branch loses` / `write the branch as JobReceived(jobs.receive()), or receive before the race` |
| A channel's element type is a `Message` | `Channel[T] requires T: Message` / `add Message to T's bounds` |
| `channel(...)` with no annotation | `cannot infer the element type of channel` / `give the binding a type: lines: Channel[String] = channel(64)` |
| A first work branch that is a generic constructor, with no annotation | `cannot infer A for this first: block` / `annotate the result, as in reply: First[Reply] = first:` |
| Kernel builtins are declared only by the kernel module | `kernel.park is private to the concurrency library` / `use the concurrency library's functions` |

`concurrent:` is a `Void` statement with no final expression. Its direct
bindings join the enclosing scope, which is new: an `if` block's do not.

**Why a pure `first:` branch is rejected.** A pure branch never waits, so it
can never be cancelled, and waiting for it would make the timeout
meaningless. Abandoning it would let the program exit while it still runs,
reading literals that exit frees. A CPU-bound impure branch has the same
limit outside the checker: it runs until its next wait. On one carrier it
also delays every timer, so make heavy work a pure task.

**Stack overflow.** A fiber's stack is a lazily committed reservation behind
a guard gap of at least 64 KiB, so a frame larger than a page cannot step
over it into the next fiber's stack. Where the C compiler supports it,
`-fstack-clash-protection` is on. Pool threads get the same guard. Running
out of stack, or failing to map a stack or start a thread, is an
infrastructure stop with a message, as running out of memory is today.

**What a user cannot do:**
- create an OS thread, lock or atomic;
- share mutable state, except through a channel's synchronized queue;
- leave a task running past its block;
- observe a data race.

## Testing

`simulate(seed, body)` returns `Result[T, Deadlock]`. It runs `body` on one
carrier, with a scheduler that makes every choice from `seed` and a virtual
clock. The rules:
- **The clock.** When every fiber is parked and no I/O or pool work is
  pending, the clock jumps to the earliest timer. With no timer, that is a
  deadlock. So `sleep` and timeouts take no real time, and blocking I/O runs
  to completion with no virtual time passing.
- **A deadlock is a value.** Every parked fiber is cancelled and run to its
  end first, then the result is `Err(Deadlock(report))`.
- **Channels belong to their runtime.** A channel that crosses into or out of
  `simulate` acts as closed and empty there. `T` must be a `Message`, so no
  channel can be returned.
- **Nesting.** A nested `simulate` runs to completion inside its caller, with
  its own clock starting at zero.
- **Pure tasks** run serially. That gives the same result by construction,
  and pure work has no races to find.
- **`elapsed()`** is the time since the runtime started: virtual time under
  `simulate`, and the monotonic clock outside it. Use it only for durations.

```blorp
import:
    concurrency: Deadlock, Channel, First(Finished, Timeout), channel, simulate, elapsed, timeout
    time: Duration, seconds
    test: TestSuite

-- The timeout fires at exactly one second of virtual time, instantly.
private func gives_up_after_one_second() -> Bool:
    outcome: Result[(First[Reply], Duration), Deadlock] = simulate(0, func() -> (First[Reply], Duration):
        reply: First[Reply] = first:
            timeout(seconds(1))
            slow_reply(seconds(5))       -- Reply
        (reply, elapsed())
    )
    outcome == Ok((Timeout, seconds(1)))


-- A property over many interleavings: every job is counted exactly once,
-- whatever order the scheduler picks.
private func counts_every_job_once() -> Bool:
    var failing: List[Int] = []
    for seed in 0..200:
        if simulate(seed, func() -> Int: count_jobs(jobs_fixture())) != Ok(100):
            failing = failing.append(seed)
    failing == []


-- A losing receive takes no value: after the deadline wins, the job sent next
-- is still the one received.
private func a_losing_receive_takes_nothing() -> Bool:
    outcome: Result[(First[Option[Int]], Bool, Option[Int]), Deadlock] = simulate(0, func() -> (First[Option[Int]], Bool, Option[Int]):
        jobs: Channel[Int] = channel(1)
        event: First[Option[Int]] = first:
            timeout(seconds(1))
            jobs.receive()               -- Option[Int]
        delivered: Bool = jobs.send(7)
        (event, delivered, jobs.receive())
    )
    outcome == Ok((Timeout, True, Some(7)))


-- A forgotten close is reported, not hung.
private func reports_an_unclosed_channel() -> Bool:
    match simulate(0, sums_without_closing):
        Err(_): True
        Ok(_): False


-- Parallel results never depend on scheduling.
private pure func parallel_map_matches_map() -> Bool:
    inputs: List[Int] = [3, 1, 4, 1, 5, 9, 2, 6]
    inputs.parallel_map(square) == inputs.map(square)


TESTS: TestSuite = {
    description = "concurrency",
    tests = [
        ("gives up after one second", gives_up_after_one_second),
        ("counts every job once", counts_every_job_once),
        ("a losing receive takes nothing", a_losing_receive_takes_nothing),
        ("reports an unclosed channel", reports_an_unclosed_channel),
        ("parallel map matches map", parallel_map_matches_map)
    ]
}
```

`Deadlock` is `record Deadlock { report: String }`. A record is not a
pattern, so tests match `Err(_)`.

**A gap in the harness.** A `TestSuite` callback returns only a `Bool`, so
`counts_every_job_once` cannot show which seeds failed. A failure message for
test callbacks is a separate change; until then, a failing property is
narrowed by printing `failing`.

The kernel's state transitions are pure, and touch no native. They live in
a module that tests can import, `concurrency/transitions`, so most of the
kernel is tested with no threads at all:

```blorp
-- A send to a channel with a parked receiver hands the value straight over.
private pure func send_hands_off_to_a_waiting_receiver() -> Bool:
    waiting: ChannelState[String] = empty_channel(1).with_receiver(fiber(7))
    (after_send, step) = waiting.offer(fiber(3), "job")
    (step == Handoff(fiber(7), "job")).and(after_send.waiting_receivers() == 0)
```

## The runtime

### Pure tasks: a pool, and no kernel

`join` and the pool are written in C. Pure work needs no scheduler state, so
nothing here waits for the concurrency kernel. These are the prerequisites:
- **String literals become immortal,** with no count writes, and each site is
  published once.
  - **Today each site is published lazily with no synchronization**
    (`string.brp:237` says so). In Spike P, ThreadSanitizer found 11 races,
    and the diagnostics build crashed at exit on a duplicate registry entry.
  - **A safe publish alone is not enough.** One literal shared by four
    threads still ran at 0.39× of one thread, because every use writes its
    count.
- **The diagnostics allocator** spins on an `atomic_flag` with no backoff
  (`memory.brp:25, 36-39`), and `make test` builds with diagnostics on. Use a
  mutex. Spike P measured the allocation-heavy workload's diagnostics build
  at 4.3× slower on four threads.
- **Peak heap** becomes order-dependent under threads. The README's claim
  that it repeats exactly holds only for programs that run no parallel work;
  say so.
- **Pool thread stacks.** Take the main thread's size from `RLIMIT_STACK`,
  with a cap when it is unlimited, and the guard described above. macOS
  gives secondary threads 512 KiB by default, so deep pure recursion would
  otherwise overflow in `parallel_map` and not in `map`.
- **A fiber calling `parallel_map`** parks while the pool works, rather than
  blocking its carrier. The pool's work counts as pending for deadlock
  detection.

### Concurrency: a kernel written in Blorp

**C, in `src/common/codegen/runtime/`:**
- **The context switch,** a file-scope `__asm__` per target, since each
  program is one C file.
  - arm64 saves x19–x29, x30, sp and d8–d15, and never touches x18 on
    Darwin.
  - x86-64 saves rbx, rbp, r12–r15, rsp, MXCSR and the x87 control word.
  - `endbr64` and `bti c` are emitted under CET and BTI.
  - Not `ucontext`, which is deprecated on macOS and makes a system call per
    switch.
- **Fiber stacks.** A reservation committed lazily, with the guard gap
  described above. Stacks never move. The entry has a null frame pointer, so
  `backtrace()`, lldb and gdb stop there.
- **Sanitizers.** `__sanitizer_start_switch_fiber` and
  `__sanitizer_finish_switch_fiber` run on every switch, which CI's ASan
  builds require.
- **`park` and `unpark(fiber)`,** with permit semantics: a wake that arrives
  before its park is kept, and the park consumes it. Parking releases the
  kernel lock only after the switch has saved the fiber, as Go's `gopark`
  does. A wait that returns at once still yields.
- **Carriers, the clock, and a blocking pool.**
  - The pool grows on demand.
  - **Unbounded natives never queue.** A native that can wait without bound,
    a pipe, console or non-regular-file read, never waits for a free helper.
    At a cap it could wait for the very write queued behind it, so it always
    gets a helper until readiness I/O replaces it. Only bounded natives, on
    regular files, count against the cap.
  - **A fork lock serializes spawning.** The descriptors are made `CLOEXEC`
    only after `pipe()`, and macOS has no `pipe2`.
  - **SIGINT and SIGQUIT.** `run` swaps these process-wide dispositions until
    its child is reaped. So they are saved and restored under a lock with a
    count: the first `run` in saves them, and the last one out restores them.
  - **Cancel descriptors** for the cancellable natives. Each costs two file
    descriptors, against macOS's default limit of 256.
- **A waiter never owns its fiber.** Otherwise a parked fiber would form a
  cycle: the channel, its waiter, the fiber, its stack, and the channel.

**Blorp, everything with logic in it:**
- run queues and scheduling;
- block scopes, joining and the cancellation tree;
- wait queues, as ring buffers, since a List pattern rebuilds the rest of the
  list on every dequeue;
- timers and channels;
- exactly-once choice;
- deadlock detection and the simulated runtime.

**Shared state without shared mutation.** A scheduler needs state that
several carrier threads change. Blorp cannot express shared mutable state,
by design. So the kernel gets one private builtin type, a locked cell, and
two natives around it:

```blorp
-- Kernel-private. A value several carriers share, behind a lock.
private type Guarded[T] = builtin

-- Locks the cell and moves its value out. Only `update` calls it.
private func take[T](cell: Guarded[T]) -> T:
    builtin("kernel.take")

-- Stores the value, receiving its ownership, and unlocks the cell.
private func put[T](cell: Guarded[T], value: T) -> Void:
    builtin("kernel.put")

-- Runs a pure step under the lock. `update` is ordinary Blorp, so
-- specialization makes the step a direct call: no closure is built, and the
-- moved value keeps a count of one, so copy-on-write changes it in place.
private func update[T, R](cell: Guarded[T], step: pure (T) -> (T, R)) -> R:
    (next, result) = step(take(cell))
    put(cell, next)
    result
```

A closure-taking native would not work. A closure stored at runtime gets a
counted environment and borrows its argument: measured, 1,000 steps that
each append to a List made 2,001 allocations as a runtime closure against 1
as a direct call.

Every operation is then a pure transition over ordinary values:

```blorp
record ChannelState[T] {
    buffer: Ring[T],
    receivers: Ring[Waiter],            -- parked, waiting for a value
    senders: Ring[(Waiter, T)],         -- parked, waiting for room
    closed: Bool
}


union SendStep[T]:
    Handoff(Waiter, T)                  -- wake that receiver with the value
    Buffered
    Park
    Refused                             -- closed: send returns False


pure func offer[T](state: ChannelState[T], sender: Waiter, value: T) -> (ChannelState[T], SendStep[T]):
    if state.closed:
        (state, Refused)
    else:
        match state.receivers.pop():
            Some((waiting, rest)):
                ({ state | receivers = rest }, Handoff(waiting, value))
            None:
                if state.buffer.has_room():
                    ({ state | buffer = state.buffer.push(value) }, Buffered)
                else:
                    ({ state | senders = state.senders.push((sender, value)) }, Park)
```

`send` runs `update(channel, offer(...))`, then acts on the step: it unparks
the receiver, returns, parks or returns `False`.

**Exactly-once choice.** It cannot be one cell's transition, because a
selection waits on several channels at once.
- **Registering.** A selection locks each channel it waits on in address
  order, as Go's `sellock` does.
- **Claiming.** A channel that pops a waiter belonging to a selection claims
  that selection with a C compare-and-swap before handing over. If the claim
  fails, the selection is already decided, and the channel tries the next
  waiter. A channel never pairs two waiters of the same selection.
- **The cases Spike K must cover:** a selecting sender meeting a selecting
  receiver, and a selection matching itself.

**The state record and the step union are the seam.** If measurement says a
transition must be C, it is replaced one for one. The Blorp version stays as
the reference it is checked against under `simulate`.

### Keeping OS primitives from users

- **Labels.** The kernel's builtin labels are accepted only in a new kind of
  module that the loader designates by path, as it designates the foundation
  modules. Raw file builtins today are accepted in any library module, so
  this is new.
- **Private wrappers.** Each native is a `private func` that nothing can
  import. The pure transitions, which touch no native, are public in
  `concurrency/transitions`, so tests can import them.
- **A custom `--library-root`** is trusted code, as it is today, and is
  outside this guarantee.
- **`foreign func`, later, is the one hole.** A thread started through C is
  outside Blorp's guarantees. The FFI rule will be that only kernel carriers
  and pool threads run Blorp code.

### What the compiler needs

1. **Syntax:**
   - `concurrent:`, `first:` and `concurrent for`. These are contextual
     words, as `fixed` is, recognized only at the head of a statement or
     initializer, before `:` and a newline. `first` appears on 628 lines of
     `src` today, and `first: T = value` is a valid annotated binding, so the
     parser needs two tokens of lookahead;
   - the unused `select` and `detach` keywords are released.
2. **Check:**
   - the rules above;
   - each task's purity, published once from what it calls;
   - `first:` typing: the block is always `First[A]`, with `A` from the work
     branches by the `if`/`match` rule;
   - the deadline clause, a branch kind recognized by what the call resolves
     to;
   - the channel-operation branch, a branch kind recognized the same way;
   - the `Message` bound: built in, and derived like automatic equality;
   - then a rewrite of each block, and of `for item in channel:`, into calls
     of designated kernel functions, with one lambda per task. A pure task
     becomes a `join`, and an impure one a fiber.

   This is how Dict literals become calls today. Later phases see ordinary
   calls and loops, so specialize, lower, own and verify need no new forms.
3. **Builtins:**
   - the designated kernel module kind;
   - `Guarded[T]`, a builtin type outside `_base`;
   - natives whose parameters are callables, for `join`, which `RuntimeType`
     has no form for today;
   - `put` receiving its operand's ownership, by generalizing
     `reuses_first_operand` to name the operand;
   - per-instance trampolines emitted for a native that calls a closure,
     since a C fragment cannot name a closure's per-signature struct.
4. **M:N, later:** thread-local state is read only through `noinline`
   accessors, since a compiler may cache a thread-local's address across the
   switch.

**Seed rotations.** The pinned seed builds only the compiler, stage A, from
`src`. Every fixture is compiled by A and by B, which are both built from the
current source (`scripts/blorp-fixpoint`). The seed rejects an unknown
builtin label at parse time, but it reads only the library modules that
`src` imports. So:
- **No rotation for a new module that `src` never imports.** `concurrency`
  is one, and the compiler's own source uses no concurrency
  (`blorp/AGENTS.md`). Landings 2, 3, 5 and 6 add their syntax, natives,
  library code and fixtures together.
- **A rotation before a module `src` imports uses a new label.** Running
  natives on helper threads does not need one. Emit calls each system
  operation's C directly, so the move is runtime C behind unchanged labels
  and contracts, in `io/files` and `io/console` alike. Landing 4 therefore
  rotates nothing. It still measures the self-compile cost, since the
  compiler's own C changes.

The first draft of this plan put a rotation after every compiler landing, as
the UInt8 and LSP plans had. Those needed one because `src` used their new
features.

## Spikes

Each spike runs on a branch that never lands. Its results go into this
document, and its compiled code sets the landing ceilings.

### Spike P: pure tasks, first

**The question.** Does `parallel_map` over pure Blorp closures, on a pool of
OS threads, speed up realistic work close to linearly? And where does the
cost go when it does not: reference counts on shared values, the allocator,
or chunking?

**Build.** Compile a Blorp program that uses `map`. Append a hand-written C
pool and `join`, written against the emitted closure and List names, and
patch the call. This needs Keith's approval, because `blorp/AGENTS.md` asks
for it before test execution rewrites emitted code. The branch never lands.

**Workloads:**
- a pure CPU-bound function per element;
- an allocation-heavy function (the allocator was about a third of the
  2026-11-02 self-compile profile);
- a large captured lookup table;
- elements of uneven cost;
- tiny elements, which set the inline threshold;
- nested maps.

**Measure:**
- speed-up on 1, 2, 3 and 4 threads, matching the 4 performance cores of the
  machine it ran on, plus 8 threads as a separate row that spills onto
  efficiency cores;
- work inflation in retired instructions;
- reference-count operations and allocations per element;
- the output, which must be identical to `map`'s.

Time without memory diagnostics, and count with them.

**Decide:**
- **Continue** at about 0.7 × linear or better on four threads, for at least
  the CPU-bound and allocation-heavy workloads.
- **Otherwise,** report the cost by cause.

**Budget:** about three working days.

### Spike P results

It ran on 2026-11-24, on an Apple Silicon machine with 4 performance cores.
Raw samples, scripts and the patched sources are in the main checkout's
ignored `build/concurrency/spike-p/`.
- **What was built.** A C pool with one Chase-Lev deque per thread, a
  Rayon-style `join`, and `parallel_map` writing into a List sized up front.
- **Load.** Other sessions kept the machine loaded throughout, at a load
  average of about 6 during the main run.
- **How it was measured.** Each figure is the median of 7 runs. Speed-up is
  of the map itself against the serial `map` program.

| Workload | 1 | 2 | 3 | 4 | 8 | Instructions, 4 threads against serial | Allocations and counts per element |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| CPU-bound | 1.01 | 1.96 | 2.95 | 3.95 | 7.53 | 1.000 | 0 and 0 |
| Allocation-heavy | 1.18 | 0.76 | 2.28 | 2.64 | 3.16 | 0.992 | 1 allocation and 3 resizes; 1 count |
| Captured table, read | 1.11 | 2.07 | 3.01 | 3.78 | 6.06 | 0.878 | 0 and 0 |
| Captured table, retained per element | 1.01 | 0.86 | 0.67 | 0.50 | 0.45 | 0.886 | 0; 2 counts |
| Uneven cost | 0.83 | 1.78 | 2.92 | 4.14 | 6.48 | 0.999 | 0 and 0 |
| Tiny elements | 3.43 | 5.84 | 7.49 | 8.08 | 7.89 | 0.444 | 0 and 0 |
| Nested, fixed pieces of 1,024 | 1.01 | 1.92 | 1.90 | 1.89 | 1.88 | 1.012 | about 0 |
| Nested, outer pieces of 1 | 1.01 | 2.02 | 2.98 | 3.98 | 6.80 | 0.988 | about 0 |
| Halving written in Blorp | 0.34 | 0.50 | 0.57 | 0.65 | 0.70 | 2.211 | about 0 |
| One shared string literal | 1.05 | 0.61 | 0.42 | 0.39 | 0.42 | 0.974 | 1 allocation; 3 counts |

The allocation-heavy workload's two-thread runs were bimodal: 1.44 in a run
at default priority. Its four-thread figure was 0.74 and 0.81 of linear in
two other runs.

**Correctness held everywhere:**
- every parallel output matched the serial one byte for byte;
- the strict leak check was clean;
- allocation and count totals were identical at 1 and 4 threads;
- ThreadSanitizer was clean, with literals kept out of the callbacks.

No workload did more work in parallel: instructions on four threads were
within 1% of one thread.

**The decision: continue.** The CPU-bound workload reached 0.99 of linear on
four threads, and the allocation-heavy one about 0.7 (0.66 to 0.81 over three
runs).

**The three design changes**, folded in above:
1. **`parallel_map` is native,** with adaptive splitting, not Blorp halving.
2. **String literals become immortal.**
3. **Atomic counts are a cost to design around,** not a free guarantee.

**Costs to remove later,** each removable rather than structural:
- **Count contention on a shared value.** Elide a retain and release pair
  when the value stays borrowed for the whole of a task's span: the retained
  table ran at 0.50× on four threads. It is structural only for a value that
  many tasks really own.
- **The allocator.** It took 80 to 86% of samples in the allocation-heavy
  workload, including a clock read on every free and macOS's zero-on-free.
  The remedy is fewer allocator calls per element, or a thread-caching
  allocator.
- **The serial `map` itself** retires 2.25× the instructions of a loop into
  a List sized up front, because of the copy-on-write test on `append` and an
  `Option` per element.
- **Waking idle workers.** A tiny map pays this on every call; it was not
  isolated.

**Not covered:** a quiet machine, and Linux.

### Landing 1 results

**What landed:** publish-once literals under a lock, and the diagnostics
allocator's mutex. The literal site still retains in every build.

| Measure | Change |
| --- | --- |
| Stage-2 `-O2` self-compile, instructions | −0.16% |
| Stage-2 `-O2` self-compile, cycles | about 0 (−0.63%, at a load average of 5 to 10) |
| `self-compile-cost`, fixed input, allocations | 0.0000% |
| `self-compile-cost`, fixed input, peak heap | +0.0008% |
| `self-compile-cost`, fixed input, instructions | +0.0144% (this row runs the seed's runtime) |
| Production lines | +20 net |
| Test lines | +118 net |

**Evidence:**
- **The gate.** `make -C blorp test INSTRUCTION_CHECK=on` passed, 3,460
  cases, with every e2e ceiling holding.
- **The tests fail when their fix is broken,** 20 runs of 20 each, as
  rerun by the code review; the unbroken build passes 20 of 20:
  - remove the publish lock;
  - keep the lock but drop its recheck;
  - remove the allocator lock.
- **ThreadSanitizer, run by hand,** found 0 reports in 5 runs; the old code
  reported races on every run.
- **Linux, with GCC 13 and Clang 18 on amd64 and arm64,** built and passed
  the probes with `-Werror -pedantic -pthread` and the sanitizers. That run
  tested the runtime before the split, which is a superset of what landed.
  The Seed CI run covers the landed form.

**The diagnostics mutex's cost.** Only the diagnostics build has this lock,
so the normal build and the self-compile ceilings are unaffected. The code
review measured it with stage-2 C files:

| Build | Instructions | Cycles |
| --- | ---: | ---: |
| Diagnostics, `-O2`, one thread | +13.9% | +7% |
| Diagnostics, `-O0`, one thread (how `blorp-test` is built) | +2.55% | +1.3% |
| Four threads allocating and releasing | — | 0.23–0.26 s, against 1.09–1.20 s for the spin lock |

The e2e instruction ceilings measure `blorp-test`, which runs the seed's
runtime, so they would have absorbed about +2.5% at the next seed rotation.
Landing 1b replaced the mutex before any rotation; see its results.

**Measuring a runtime change.** `self-compile-cost` builds both compilers from
the pinned seed, so the compiler it measures runs the seed's runtime: its
rows cannot see a change to the runtime fragments. For landing 1 they showed
+0.05% instructions while the real cost of skipping literal counts was
+2.4%. Landing 1 therefore measured stage-2 compilers as well:
- each side's compiler compiles the base source;
- the result is linked at `-O2`;
- that compiler then compiles the base source again.

The prototype is `build/landing1/stage2/stage2.py` in the landing's
worktree. A `--stage2` mode for `self-compile-cost` would make this
routine, and every landing that changes the runtime needs it.

**Stage-2 variants, fixed input, `-O2`,** median of 7 alternating rounds, at a
load average of about 6:

| Variant | Instructions | Cycles |
| --- | ---: | ---: |
| Publish once, the site still retains, no checks (what landed) | −0.16% | +0.22%, noise |
| Publish once, the site does not retain | −0.33% | −0.87% |
| Checks in retain and release, so counts are never written | +2.37% to +2.40% | +2.35% to +2.58% |
| Retain check only | about +0.24% | |
| Release check only | about +2.3% | |
| Both checks, with retain and release kept out of line | +0.80% | +1.30% |

Allocations were identical in every variant, at 13,189,121.

**The audit: state a pure task can reach.**

| State | Where | Verdict |
| --- | --- | --- |
| Literal sites | `emit.brp:356` | fixed: an atomic pointer, published under the lock |
| The literal registry | `string.brp:247` | fixed: pushed under the literal lock, and read at exit after every task |
| Literal counts | `string.brp` | fixed in landing 1b: a normal build never writes them |
| Memory counts, peak heap, the allocation-site table | `memory.brp:22, 25, 64, 65` | fixed: under the diagnostics lock, a mutex in landing 1 and test-and-test-and-set from landing 1b. Peak heap becomes order-dependent under threads, and its README note landed with landing 2a |
| `blorp_memory_strict`, the image base | `memory.brp:28, 66` | safe: written once at start |
| Allocation-sites output | `memory.brp:63, 140` | safe: written at start and finish. Landing 2 must stop pool workers allocating before the program finishes |
| The release state | `memory.brp:266` | safe: `_Thread_local` |
| Empty-list owners and roots | `list.brp:261, 380` | safe: atomic in diagnostics only, and the roots are `static const` |
| Literal bytes and callable operation tables | `emit.brp:360, 780` | safe: read-only |
| Per-object counts | runtime and emit | safe: atomic, with acquire uniqueness tests |
| libc `malloc`, `free`, `snprintf`, `strtod`, `errno` | float runtime | safe: the locale is only read |
| Impure-only state: temporary files, console exit, fork, environ, signals, stdio | `fs.brp`, `console.brp`, `process.brp`, `sigpipe.brp` | deferred to landing 4 |

The inventory covers every writable data symbol in the objects of all 790 e2e
fixtures, in both builds, plus a scan of the runtime.

### Landing 1b results

**What landed:**
- **A normal build never writes a literal's count.** The literal base is now
  the count's top bit. Retain and release return at once for a String whose
  count is at or above it, and the site no longer retains. Diagnostic builds
  count literals as before, and keep the balance check at exit.
- **Release is split.** It inlines as the one-bit test and a call to its
  counted half, `blorp_string_release_counted`, which is kept out of line.
  Diagnostic builds release through the counted half alone. It is out of
  line there too, so a diagnostics `-O2` build no longer inlines String
  release; at `-O0` their code is unchanged (−0.001% instructions).
- **The diagnostics allocator's lock is test-and-test-and-set.** Taking it
  when it is free costs one exchange. A waiting thread reads the lock, and
  yields after 100 reads.
- **No emit change.**

**Why this form.** To clang's inliner, the test and a call cost about what
the decrement, compare and call to `free` cost before. So the drop helpers
inline as they did, and what is left is the test itself. Lean 4 splits
`lean_dec_ref` the same way. Its inline part tests for a persistent object
and decrements a single-threaded count with a plain store. The atomic
decrement of an object shared between threads, and the free, are out of
line in `lean_dec_ref_cold`. Every Blorp count is atomic, so the whole
decrement is out of line.

**The forms tried.** Stage-2 `-O2` self-compile, normal build, fixed input
(`b366e2a17`), against base. Each figure is a median of 7 alternating rounds
unless noted.

| Form | Instructions | Cycles | Load average |
| --- | ---: | ---: | --- |
| Checks inline, base `SIZE_MAX/2` (landing 1's form) | +2.93% | +2.00% | 7 to 10 |
| 1. Lean-style cold free path | +2.93% | +1.92% | 7 to 10 |
| Checks inline, top-bit base | +2.61% | +3.46% | 6 to 7 |
| 2. Release out of line only in drop helpers | +1.02% | +0.35% | 7 to 10 |
| 2, top-bit base | +0.82% | +1.60% | 6 to 7 |
| 3. Test inline, counted half out of line | +0.55%, +0.61% | −0.34%, +0.68% | 5 to 10 |
| 3, top-bit base (prototype) | +0.34%, +0.28% | +0.75%, +0.81% | 5 to 7 |
| 3, top-bit, release test only | +0.06%, −0.03% | +1.08%, +0.21% | 3 to 6 |
| 3, top-bit, with a unique-owner shortcut (11 rounds) | +0.40% | +0.30% | 3 |
| **What landed: 3, top-bit** | **+0.28%** | **+0.36%** | 2.5 to 3.5 |

- **The landed row** pools the 65 rounds of five runs, and compares the two
  sides' medians (`stage2/samples.jsonl`); pairing each round instead gives
  +0.26 to +0.27% instructions and +0.26 to +0.48% cycles. The runs alone
  gave:
  - +0.24% instructions and +0.43% cycles (7 rounds);
  - +0.26% and +1.24% (15 rounds);
  - +0.25% and +0.34% (21 rounds);
  - +0.29% and +0.40% (11 rounds);
  - +0.27% and +0.19% (11 rounds).
- **Instruction counts vary.** One binary's retired instructions vary by up
  to 0.6% between runs on this loaded machine, so single runs of 7 differ
  by about 0.1%.
- **Form 1 is form "checks inline" in a normal build.** There the free
  branch is already one call to `free`.
- **Form 2** makes drop helpers smaller than before, so they inline in
  different places: 269 helpers changed call sites.
- **The release-only test** leaves retain unchecked, so a literal's count
  still grows when the literal is duplicated. That writes its line, and the
  count would wrap after 2^63 duplications. It saves about 0.25%
  instructions but no cycles, so the landed form tests both.
- **The unique-owner shortcut** frees at a count of 1 without decrementing.
  It did not pay.
- **Allocations** were 13,307,464 for both sides. Peak heap differed by 2
  bytes, which is the longer output path the measurement names.
- **Output was identical** in every run.
- **Diagnostics at `-O0`:** −0.001% instructions against base (5 rounds), so
  `blorp-test` pays nothing for part 1.

**Inlining, from the `-O2` assembly.** A record's release body keeps its
shape: each String field's `ldaddal`, compare and call to `free` becomes a
load, a `tbnz` on the top bit and a call to the counted half. These are the
call sites of the drop helpers that checking inline de-inlines most. Landing 1's
`blorp_union_drop_225` is `blorp_union_drop_229` here, the same
`Option` of the same record shape.

| Helper | Base | Checks inline, top bit | Landed |
| --- | ---: | ---: | ---: |
| `blorp_union_drop_229` | 62 | 589 | 62 |
| `blorp_union_drop_254` | 36 | 274 | 35 |
| `blorp_list_release_0_r269` | 1 | 135 | 1 |
| `blorp_union_drop_246` | 10 | 120 | 10 |
| `blorp_union_drop_358` | 0 | 105 | 0 |
| `blorp_union_drop_at_350` | 0 | 91 | 0 |
| `blorp_union_drop_245` | 5 | 63 | 5 |
| `blorp_union_drop_257` | 5 | 58 | 5 |

Of 1,695 helpers, 1,663 keep their call sites exactly.
`blorp_union_drop_199` gains 44 call sites, from the retain test.

**GCC 13** (`-O2`, arm64 image) inlines differently, but the same way round:
- checking inline moved 2,862 call sites;
- the landed form moved 1,108, with 3,231 fewer direct calls than base;
- `blorp_record_drop_at_58` is called from 246 sites in base, 433 with checks
  inline, and 197 landed;
- user CPU time, which is all the VM measures, was −0.63% landed and +0.86%
  with checks inline (7 rounds);
- GCC on arm64 calls an outline-atomics helper for every atomic
  read-modify-write, in base as well.

**The benefit.** This is Spike P's shared-literal map (w7). The output was
identical in every run.

| Runtime | 1 thread (21 rounds) | 4 threads, median and range (11 rounds) |
| --- | ---: | ---: |
| Base | 34.9 ms | 75.5 ms (47–84) |
| Landed | 35.2 ms | 14.2 ms (12–96) |

- **Four threads ran 5.3× faster** than base, at a load average of 4.
- **One of the 11** four-thread runs took 96 ms. Landing 1's prototype ran
  that slowly in most runs; the cause is not isolated.
- **One thread** differs by noise.

**The lock.** Diagnostics builds, against the old spin lock for one thread
and the mutex for four. The one-thread figures are 7 alternating rounds at
a load average of 3 to 10. The probe allocates and releases a million
64-byte blocks per thread.

One-thread cells give instructions, then cycles, against the spin lock.
Four-thread cells give the time against the mutex's in the same run.

| Lock | One thread, `-O0` | One thread, `-O2` | Four threads, `-O0` | Four threads, `-O2` |
| --- | ---: | ---: | ---: | ---: |
| Spin lock | 0, 0 | 0, 0 | 3.1× | 5.0× |
| Mutex (landing 1) | +2.54%, +0.92% | +14.1%, +8.3% | 1 (620 ms) | 1 (444 ms) |
| Test-and-test-and-set | +0.11%, +0.18% | +0.56%, +0.58% | 0.55× | 0.36× |
| The same, with a CPU pause | +0.11%, +0.27% | +0.81%, +0.47% | 0.54× | 0.40× |
| `os_unfair_lock` | +0.46%, +0.30% | +3.65%, +2.56% | 1.44× | 1.42× |
| **What landed** | **+0.11%, +0.08%** | **+0.54%, +0.66%** | **0.65×** | **0.43×** |

- **The criteria:** within +0.5% of the spin lock at `-O0`, and within 1.5×
  of the mutex on four threads. The landed lock meets both, and is the
  simplest that does. The pause needs a platform `#if` and bought nothing.
- **The spin count:** 10 and 100 reads before yielding ran alike, and 1,000
  ran slower.
- **More threads than cores** (`-O0`, 3 runs):

  | Threads | Mutex | Landed | Spin lock |
  | ---: | ---: | ---: | ---: |
  | 8 | 1.3–2.0 s | 0.55–0.71 s | 6.0–9.6 s |
  | 16 | 2.3–3.6 s | 1.13–1.30 s | 28–35 s |

- **This mutex ran slower** than in landing 1's review (0.41–0.62 s against
  0.23–0.26 s), under a different load.

**Tests:**
- `string_literal_suite` has its uncounted case back. In a normal build,
  after three evaluations, two retains and six releases, a literal is still
  at its base, and an ordinary String is still counted.
- **It fails when its fix is broken:**
  - with a site that writes the count directly, at the assert after
    evaluation;
  - without the retain skip, after the retains;
  - without the release skip, after the releases.

  `threaded_publish` also fails in the normal build without the site or
  release skip.
- **The peak heap suite's `threads` case** fails 20 of 20 runs without the
  lock, and passes 20 of 20 with it.
- **ThreadSanitizer** found 0 reports in 5 runs of the threaded probes.
- **Linux, with GCC 13 and Clang 18 on amd64 and arm64,** built and passed
  every probe. The flags were `-Werror -pedantic -pthread` with the
  sanitizers, and a sample program ran in both modes.

**Measures:**

| Measure | Change |
| --- | --- |
| Stage-2 `-O2` self-compile, instructions | +0.28% |
| Stage-2 `-O2` self-compile, cycles | +0.36% |
| Stage-2 diagnostics, `-O0`, against the mutex | −2.4% instructions |
| w7 on four threads | 5.3× faster |
| `self-compile-cost 1fa321907`, fixed input, allocations | 0.0000% |
| `self-compile-cost 1fa321907`, fixed input, peak heap | +0.0018% |
| `self-compile-cost 1fa321907`, fixed input, instructions | −0.07% (this row runs the seed's runtime) |
| Production lines | +35 net |
| Test lines | +29 net |

The raw samples and scripts are in `build/landing1b/`, ignored, in the
landing's worktree.

### Landing 2 results

Landing 2 is the front end of `concurrent:` blocks for pure tasks. The native
`join` moved to landing 2a, after a first stop: lines were over the ceiling,
and direct-call trampolines need own and verify changes.

**What it does:**
- **Syntax.** `concurrent:` is a contextual word, recognized only before
  `:` and a line end. Each line of the block is a task, and a task rejects
  `?=`, `break` and `continue` that would leave it. The formatter and the
  grammar follow; the language server needs no change.
- **Load.** `concurrency.brp` has its own module role by path. The loader
  queues it once its queue drains and some loaded module used a block, so a
  program without one loads exactly what it did.
- **Check.**
  - Each task's whole statement is checked once, as any statement is, as the
    body of a pure `() -> T` lambda whose row check builds directly. The
    lambda returns what the statement bound: nothing, its one binding, or a
    tuple of several, which costs one allocation when its elements are managed.
  - Two or more tasks become the right-leaning chain of the module's `join`,
    and one task a call of its `run`, which runs it in place: a checked form
    cannot call a lambda value directly without a closure. After the block
    each name a task bound is bound once more, as the task bound it.
  - A nested block binds what its own tasks bind, so its names follow the
    outer block too; Keith decided on 2026-10-02 that nested blocks are not
    errors.
  - `join` and `run` are validated where they are designated. Landing 2a can
    move `join`'s check into its `runtime_contract`, which checks the same
    shape.
  - Every rule of the brief's table is worded for the task, as are an
    expression task's value (the existing rule that an expression statement
    is Void) and an assignment of any outer binding, var or immutable, which
    has one message.
  - The resource pass is the one authority for a task's resource and
    scoped-callable captures. It reads the lambda's origin and rejects the
    first such capture at its first use, by the name it was used by: a
    capture records that name with its span. A lent Self in an inherited
    default names the type instead, as that rejection's rewording needs.
  - A task's bindings are the head of its statement's scope. A rest that is
    not the block's scope, or a callable among them, is a checker invariant.
  - `concurrent: x = 1` on one line reports "unknown type"; no carrier
    brings the `concurrent` word to that rejection, so it has no hint.
- **`join` and `run` are written in Blorp,** so a block's tasks run one after
  the other. Specialization calls each task's lambda directly, with no
  closure.

**Ceilings, corrected by the coordinator on 2026-11-25:**

| Ceiling | Old | New |
| --- | ---: | ---: |
| Production lines | +1,000 | +1,060, then +1,080 |
| Test lines | +900 | +1,200, then +1,400 |

The growth audit found that check needs about twice the brief's estimate of
250–400 lines for its rules, not bloat; the native moved out, and the
audit's cuts apply. The second test correction, from +1,200 to +1,400, is
for necessary coverage of the rules and cases review asked for. The second
production correction, from +1,060 to +1,080, pays for the last review's
fixes: each rejected capture named at its use, and the task's scope checked
as an invariant.

**Lines,** from `bd6922f69`: production +1,076 net, 16 over the +1,060
ceiling, and tests +1,382 net, within +1,400. The tests add the review's
cases, a shared marked-rejection helper and a language-server definition
test.
- **A first fix round** reached +1,193 production: its fixes added more than
  the audit's cuts removed.
- **A simplification round** checked each task's whole statement and
  rebound its names once, in place of applying its pattern a second time
  after the block. It also moved the capture rules to the resource pass,
  and dropped the one-line hint and the nested-block rejection.
- **A review round**, after the rebase onto `bd6922f69` (+1,045), named each
  capture rejection at its use and made the task's scope an invariant, at
  about +55. Folding the one-task result into the join operand's shape took
  back about 24, which left it 16 over; the coordinator corrected the
  ceiling.

**Cost,** `self-compile-cost bd6922f69 070073d22 --rounds 3`, on arm64
macOS 26.7.1 with Apple clang 21.0.0, `-O0`. The fixed-input C is identical
(`82852fffae471842`).

| Measure | Base | Candidate | Change |
| --- | ---: | ---: | ---: |
| Fixed input, allocations | 13,161,848 | 13,161,868 | +0.0002% |
| Fixed input, peak heap | 187,091,716 | 187,091,975 | +0.0001% |
| Fixed input, instructions | 13,369,098,024 | 13,373,402,448 | +0.032% |
| Own source, allocations | 13,161,848 | 13,313,945 | +1.16% |
| Own source, peak heap | 187,091,715 | 190,306,457 | +1.72% |
| Own source, instructions | 13,348,111,648 | 13,509,311,358 | +1.21% |

The fixed-input instruction samples overlap: the base's three span
13,365–13,390 M and the candidate's 13,362–13,378 M. The previous row,
against `eb2edd2cc`, was +0.0082%.

Three earlier versions missed the cost ceilings, and each fix is its own
commit:
- **+0.35% allocations.** Every line asked whether it started a block, and
  the eager `and()` built two shifted parser states each time.
- **+0.17% peak heap.** A second Span in the block's node grew every
  statement by 16 bytes, since a statement List holds its elements inline.
- **+0.02% allocations, +0.11% instructions.** Routing every declaration
  through the task binder built an extra record and a tuple per binding.

Against a compiler built from `bd6922f69`, every existing fixture under
`test/test_compile/fixtures` compiles to the same C, or the same diagnostic:
761 files, 627 of them programs. Only the landing's six block fixtures
differ. The compiler's own source at `bd6922f69` compiles to the same C
(`82852fffae471842`). The raw samples are in `build/landing2/`, ignored, in
the landing's worktree.

### Landing 2a results

Landing 2a makes `join` the native `concurrency.join`, on landing 2b's
pool, so a block's tasks run at once. `run` stays Blorp.

**What it does:**
- **Check.** `concurrency.join` is a builtin label, which only the
  `ConcurrencyModule` role may declare ("concurrency.join is private to the
  concurrency library", help "run tasks with a concurrent: block"). The
  library-only rule for raw file handles became one table of restricted
  builtins. Its runtime contract, from the operation's `TaskTypes`, is
  `join[A, B]` with no bounds, two `pure () -> A` and `pure () -> B`
  parameters and an `(A, B)` result, through a new `TaskRuntimeType`
  parameter form and a `PairResult` result form.
  `join_shaped` is gone: the designation asks only that `join`'s body is the
  native, and the contract gives its shape. A builtin body now forwards its
  callable parameters to the native.
- **Specialize.** A new call target, `JoinTasks(TaskJoin)`, names the two
  task instances, as a call of a static callable parameter names its one.
  The call's arguments are the environments of the tasks that take one, left
  first. The instances are requested as the Blorp `join` requested them, so
  no instance numbering changes. `ConcurrencyJoin` never leaves
  specialization: its arms after it fail loudly, and `runtime_signature`
  became fallible for the pair result, which only join has.
- **Own.** A join's task instances join the instances taken as callables,
  which are pinned to the borrowed ABI (Lean's borrowed parameters, as own
  already did for callables). Pinning reaches only those instances, since
  each task lambda is created once, for its block's join.
- **Verify.** Each task goes through `pinned_callable`, the check that
  instances taken as callables already use, takes at most its environment,
  and the call's value must be a record whose fields are the two tasks'
  results.
- **Emit.** One job per pair of tasks, named by their instances, holds the
  environments, numbered in argument order, and the non-Void results,
  numbered by the task's position in the pair. Two static trampolines call
  the task functions directly (Rayon's `join`, with the job on the joining
  thread's stack). The call fills the job, calls
  `blorp_join` and builds the pair from the result slots, moved, as
  `ConstructRecordDefinition` builds a record. `JOIN_RUNTIME` and the POSIX
  prelude are included only for a program with a join, whose `main` also
  calls the pool's `blorp_join_requested_threads` before any user code, so
  `BLORP_THREADS=x` stops it with status 1 before it prints.

The summary fixture's join instance:

```c
struct blorp_job_3_4{blorp_r_1 environment_0;blorp_r_2 environment_1;int64_t result_0;int64_t result_1;};
static void blorp_job_3_4_0(void *job){struct blorp_job_3_4 *const slots=job;slots->result_0=blorp_f_3(slots->environment_0);}
static void blorp_job_3_4_1(void *job){struct blorp_job_3_4 *const slots=job;slots->result_1=blorp_f_4(slots->environment_1);}
/* concurrency.join */ blorp_r_0 blorp_f_5(blorp_r_1 blorp_p_0,blorp_r_2 blorp_p_1){...
  struct blorp_job_3_4 blorp_runtime_2={.environment_0=blorp_vl_0,.environment_1=blorp_vl_1};
  blorp_join(blorp_job_3_4_0,blorp_job_3_4_1,&blorp_runtime_2);
  const blorp_r_0 blorp_vl_2=((struct blorp_r_0){.blorp_rf_0_0=blorp_runtime_2.result_0,.blorp_rf_0_1=blorp_runtime_2.result_1});...}
```

**Tests:**
- **E2e.** A Fibonacci fixture runs `fibonacci(24)` through 75,024 joins.
  Every block fixture runs with the driver's `BLORP_THREADS`, which
  `make test` leaves unset: one thread per processor.
- **Thread counts by hand.** The harness cannot set an environment variable
  per run. All seven fixtures, built as the harness builds them, give the
  same stdout and strict counts with `BLORP_THREADS` unset, 1 and 4 (4, 10,
  8, 10, 1, 1 and 6 allocations). `BLORP_THREADS=x` and `0` stop a program that prints
  first with status 1, the message and empty stdout; empty and `2` run it.
  The smallest harness change: an `environment` field on `NativeRun`, merged
  over `without_diagnostics` in `launch`, which six construction sites fill.
- **The consuming fixture** is landing 2's `shared_capture`, whose
  `values.append(7)` task took its environment owned and dropped it before
  this landing. A `void_tasks` fixture covers tasks that return Void: a job
  slot and a pair member are left out, and a job of two capture-free loops
  has no slot.
- **Check.** The label restriction, with exact text and span; a native join
  of another shape, rejected by its contract; a Blorp `join` is no longer
  the library's join.
- **Verify and own.** A unit suite checks that each task borrows its
  environment when own's test labelling owns every other parameter. It
  rejects, at the call, a join whose tasks are the wrong way round ("a
  join's result does not hold its tasks' results"), one that names an
  instance owning a parameter ("pinned instance has an owned parameter") and
  one that names a two-parameter instance ("a joined task takes no argument
  but its environment"). Without the pin, or without verify's pin check, a
  case fails.
- **ThreadSanitizer** found nothing in the six fixtures at 4 threads, three
  runs each of the normal build and one of the diagnostics build for the
  three that allocate.
- **The tests bite.** Without the pin, verify rejects `shared_capture`
  ("pinned instance has an owned parameter"); with verify's check removed as
  well, ASan reports a heap-use-after-free in `blorp_list_dup`. With the
  trampolines' result slots swapped, `summary` prints `52 14`, and the three
  fixtures whose results differ in type fail to compile.

**Timing,** four CPU-bound pure tasks (`spin` with 200,000,000 rounds each),
`-O2`, no diagnostics, on an Apple M4 (4 performance and 6 efficiency
cores), macOS 26.7.1, Apple clang 21.0.0. Seven interleaved runs each, and
each sample includes two Python start-ups, which lowers the ratio. Other
sessions loaded the machine: the load average was 3.1 to 3.4 for the final
commit's run, and 2.1 for an earlier one whose C differed only in names.

| `BLORP_THREADS` | Final median | Final range | Earlier median |
| --- | ---: | ---: | ---: |
| 1 | 2.908 s | 2.864–3.197 s | 2.284 s |
| 4 | 0.907 s | 0.832–0.935 s | 0.685 s |
| Speed-up | 3.21× | | 3.34× |

**Cost,** `self-compile-cost ee5755113 cbd54cb73 --rounds 3`, on the same
machine, `-O0`. The fixed-input C is identical (`8f14763f5c063f7e`).

| Measure | Base | Candidate | Change |
| --- | ---: | ---: | ---: |
| Fixed input, allocations | 13,313,945 | 13,313,948 | +0.0000% |
| Fixed input, peak heap | 190,306,052 | 190,306,117 | +0.0000% |
| Fixed input, instructions | 13,525,901,556 | 13,525,533,087 | −0.0027% |
| Own source, allocations | 13,313,945 | 13,409,383 | +0.72% |
| Own source, instructions | 13,511,214,535 | 13,618,026,409 | +0.79% |

The fixed-input instruction samples overlap: 13,524.7–13,533.9 M for the
base and 13,519.1–13,534.7 M for the candidate.

An earlier version missed the ceilings, at +0.34% allocations and +0.22%
instructions. `ConcurrencyJoin(Element, Element)` was the first operation
whose copy acquires two counts, so a `CallTarget` could cost two and every
`ConcreteCall` became a heap record, made once per call in specialization and
again in emission. The two types now share one `TaskTypes` record, and a
copy acquires one count again. A second fix kept the task-instance request
to joins, where it had built a Result for every runtime call.

Every fixture under `test/test_compile/fixtures` but the seven block
fixtures compiles to the same C, or the same diagnostic, as a compiler built
from `ee5755113`: 761 of 768 files. The compiler's own source at
`ee5755113` compiles to the same C (`8f14763f5c063f7e`). Raw samples are in
`build/landing2a/` of the landing's worktree.

**Lines** for the native, from `ee5755113` and without the pool's 347
production and 587 test lines: production +476 net (554 added, 78 removed),
within +500. Tests are +437 net, over the +300 estimate: they stood at +244
before the soundness review, whose requested cases added 193, the verify and
own cases and the Void fixture. Of the rest, three codegen tests read the
now fallible `runtime_signature`, and five pin the label help, which gains
`concurrency.join`. The coordinator corrected the test ceiling from +300 to
+440 on 2026-11-25, for the verify and own cases and the fixture that
review asked for; the shared test support has no source-to-lowered-program
helper to reuse.

**Follow-ups,** not in this landing:
- **A checked call target for join.** Check could give `join` a call target
  of its own, so that `ConcurrencyJoin` and `PairResult` cannot exist after
  specialization. That would remove the five arms that refuse them and make
  `runtime_signature` total again.
- **A per-run environment in the e2e harness,** `NativeRun.environment`, so
  the start-time check and the runs at 1 and 4 threads become automated
  tests. Landing 3 will want it.

**The pool (landing 2b),** cherry-picked unchanged:
- **Test-line ceiling corrections:** +400, then +490, +520 and +590.
- **Leapfrogging.** A thread waiting for a stolen half takes tasks only from
  that half's thief (Wagner and Calder), so the stack never exceeds the
  serial run's. Against helping with any task, a C benchmark of four
  workloads (Fibonacci with and without a cutoff, uneven leaves and uneven
  halves) at 1, 2, 4 and 8 threads gave medians within 5% in its second run.
  The first run's gaps of 10 to 20% at one thread, where both take the same
  path, were noise.
- **Two review blockers, fixed.** Helping with any task could overflow a
  stack the serial run fits, which leapfrogging fixed. A waiter paused before
  its leapfrog steal could win an unrelated task its thief pushed after
  finishing the awaited one; the steal now checks `done` before the CAS.
- **Fork, for landing 4.** Idle workers take the pool mutex at any time, to
  sleep and to be woken, so a forked child that runs Blorp code needs a
  `pthread_atfork` reset of it.

### Landing 3 results

Landing 3 adds `parallel_map`, the native `concurrency.parallel_map`, on
landing 2b's pool, which is unchanged.

**What it does:**
- **Check.** `concurrency.brp` declares the public `parallel_map[A, B]`, whose
  body is the native. Its contract is pure, with a `List[A]` and a
  `pure (A) -> B` parameter and a `List[B]` result. Join's task form
  generalized into `PureCallableRuntimeType`, a record of parameter and
  result types, so a copy still acquires one count. The label joins 2a's
  restricted builtins ("concurrency.parallel_map is private to the
  concurrency library", help "import parallel_map from concurrency"). An
  impure named function or method given to the map is rejected with
  "parallel_map needs a pure function: read_text is impure", help "use a for
  loop for impure work". Check knows the map by its body: the call's
  contract, made where the callee's accepted function is in hand, says
  whether the pool runs its callbacks (`pooled_callbacks`), and each
  callable argument reads that from the pending call.
- **Specialize.** A new call target, `MapElements(MapCallback)`, names a
  static callback's instance (`DirectCallback`) or, for a stored closure,
  the map's element and result types (`ClosureCallback`). The map's callback
  is requested as a call of a callable parameter is, so a stored closure
  needs no instance; join's tasks keep the rule that a task is static. The
  call's arguments are the List, then the instance's environment or the
  closure, as the callable parameter's binding gives them.
- **Own.** A direct callback joins the instances taken as callables, pinned
  to the borrowed ABI. A closure's instance is pinned where the closure is
  made.
- **Verify.** A direct callback goes through `pinned_callable` and takes an
  element and at most its environment; the call's parameters are the List
  of its element and its environment, and its result the List of its
  result. A closure callback's call takes the List and `(A) -> B`.
- **Emit.** One job per callback: `blorp_map_7` for the instance `blorp_f_7`,
  `blorp_map_p1_s_r_i_e` for a closure of `(String) -> Int`. Each has a
  struct, a piece that calls the callback for each index of its range, and a
  run function the call calls. It returns the empty root for an empty input,
  and otherwise allocates the result once, runs `blorp_join_range` and then
  sets the length. `JOIN_RANGE_RUNTIME`, after `JOIN_RUNTIME`, splits as
  Rayon's `LengthSplitter` does on `blorp_join`; a right half knows it was
  stolen when the thread running it is not the one that split it, so the
  pool needed no change. The start-time `BLORP_THREADS` check is emitted for
  a program that uses the pool through either native.
- **The stack.** Each split nests `blorp_join_range_run`, `blorp_join` and
  `blorp_join_finish`, for about log2(count) levels per map. The serial
  `map` has none of these frames, so `blorp_join_wait`'s bound, the serial
  run's stack plus a few frames per join, does not count them.

The job and call for the problem's program, `square` over five Ints:

```c
struct blorp_map_1{const struct blorp_l_0_i* values;struct blorp_l_0_i* result;};
static void blorp_map_1_piece(void *job,int64_t low,int64_t high){struct blorp_map_1 *const slots=job;
  for(int64_t index=low;index<high;index++)slots->result->values[index]=blorp_f_1(slots->values->values[index]);}
static struct blorp_l_0_i* blorp_map_1_run(const struct blorp_l_0_i* values){const int64_t count=values->length;
  if(count==0)return (struct blorp_l_0_i*)blorp_list_empty_acquire(&blorp_list_empty_0_i);
  ...allocate result with count slots...
  struct blorp_map_1 job={.values=values,.result=result};
  blorp_join_range(blorp_map_1_piece,&job,count);result->length=count;return result;}
/* concurrency.parallel_map */ struct blorp_l_0_i* blorp_f_2(struct blorp_l_0_i* blorp_p_0){...
  struct blorp_l_0_i* const blorp_vl_1=blorp_map_1_run(blorp_vl_0);...}
```

**Tests:**
- **The harness.** A `NativeRun` has an `environment`, set over the run's
  isolated one, and a `StrictReport`: balanced allocations, or nothing for
  a program the runtime stops before it starts. The strict build prints no
  leak report for `BLORP_THREADS=x`, which exits in the runtime, so the
  brief's field alone could not express that run. Every block and map
  fixture runs at `BLORP_THREADS` unset, 1 and 4 with exact stdout and
  counts, and `BLORP_THREADS=x` stops a block program and a map program with
  status 1, the message and empty stdout.
- **E2e,** eight map fixtures: a named callback over Ints, which also
  matches `map` and maps to `List[Void]`; a lambda capturing a List, over
  Strings; a closure from a record field; a nested map over
  `List[List[Int]]`; an empty input, with no allocation in the whole
  program; a callback that appends to its row, balanced and clean under
  ASan; a map in a block's task, from a module that imports `concurrency`;
  and 10,000 elements, by their sum and six positions. At 4 threads that
  map ran as 103 pieces on four threads; at 1 thread as one.
- **`List[Void]`:** `map` takes a Void callback, so the map does too. A
  `List[Void]` holds a byte per element and a Void function returns that
  byte, so the job needs no case of its own.
- **Check:** the impure function and the impure method, with exact text and
  span, and the label in a user module.
- **Verify:** a callback with the wrong result ("call result type does not
  match its contract"), one that owns a parameter ("pinned instance has an
  owned parameter"), one with a second parameter, read as an environment the
  call does not lend ("call is missing its argument"), one with three ("a
  mapped callback takes an element and at most its environment"), and a
  stored closure of `(String) -> Int` named as a map of Ints ("call argument
  type does not match its contract"). The join and map suites share
  `test_verify/native_call_inputs.brp`.
- **ThreadSanitizer** found nothing in the eight fixtures at 4 threads:
  three runs each of the normal build and one of the diagnostics build.
- **The tests bite:**
  - without own's pin, the consuming fixture fails in verify ("pinned
    instance has an owned parameter") and the borrow case fails; with
    verify's check also removed, ASan reports a heap-use-after-free in
    `blorp_list_dup_0_i`;
  - results written at `length-1-index` fail six of the seven non-empty
    fixtures; the map in a task sums its results, so order cannot show;
  - a piece that counts `length++`, as a List literal does, gives 6 to 20
    ThreadSanitizer races per run on the 10,000-element fixture and wrong
    output;
  - check's pooled rule and the label restriction, each removed, fail their
    cases.
- **A bite experiment that found no race.** The brief expected
  ThreadSanitizer to report one when a changed run function set the length
  before `blorp_join_range`. It reported none in three runs, and the output
  was right: no piece reads or writes the length, and nothing reads the
  result before the join returns. The shipped code sets the length after the
  join, so it counts only written slots, as emit's comment says.

**Timing,** Spike P's workloads with `map` replaced, `-O2`, no
diagnostics, on an Apple M4 (4 performance and 6 efficiency cores), macOS
26.7.1, Apple clang 21.0.0. Seven interleaved runs after one warm-up, each
wall time a `perf_counter` around the child (`/usr/bin/time` reports 10 ms
steps), so it includes process start and the setup loops. Load average 1.4
to 1.8.

| Workload | `map` | 1 thread | 4 threads | Speed-up | 1 thread against `map` |
| --- | ---: | ---: | ---: | ---: | ---: |
| CPU-bound (w1) | 0.4819 s | 0.4815 s | 0.1382 s | 3.48× | −0.1% |
| Tiny elements (w5) | 0.1400 s | 0.0587 s | 0.0585 s | 1.00× | −58% |
| Nested (w6) | 0.1875 s | 0.1870 s | 0.0558 s | 3.35× | −0.2% |

Every configuration printed the same output as `map`. Instructions at 4
threads were within 0.1% of 1 thread for w1 and w6, and 7.5% above it for
w5, whose fifty small maps wake idle workers each time. Tiny elements gain
nothing whole-program: the map is a small part of w5 beside its setup and
fifty serial checksums, which Spike P's region timing left out.

**Cost,** `self-compile-cost dee4a2445 7eccd55b3 --rounds 9`, on the same
machine, `-O2`. The fixed-input C is identical (`47286d12d57dc754`):

| Measure | Base | Candidate | Change |
| --- | ---: | ---: | ---: |
| Fixed input, allocations | 13,409,321 | 13,409,322 | +0.0000% |
| Fixed input, peak heap | 191,321,020 | 191,321,085 | +0.0000% |
| Fixed input, instructions | 13,619,944,970 | 13,626,422,401 | +0.0476% |
| Own source, allocations | 13,409,321 | 13,482,218 | +0.5436% |
| Own source, instructions | 13,620,158,752 | 13,701,111,131 | +0.5944% |

The fixed-input samples are 13,614.2–13,624.6 M for the base and
13,619.6–13,632.0 M for the candidate.

- **Two costs were found on the way.** The first candidate cost +0.175%:
  check fetched the call's signature list for every argument of every call.
  The call's contract now carries `pooled_callbacks`, decided where the
  callee's accepted function is already in hand. That left about +0.13%,
  which was emit's.
- **A compiler cost to remove later: Lists carried through a `match`.**
  `program_inventory`'s loop over every block operation carries each `var`
  List it builds through its `match`, and acquires and releases each once
  per operation: 152,749 dups and drops each on the fixed input, about 0.1%
  of instructions per List. A sixth List, `map_jobs`, cost that; call-count
  builds of the script's two `compiler.c` found it
  (`landing3-evidence/cost-investigation/`). Joins and maps now share one
  `pool_jobs` List, so the walk carries five again.

**Identity.** Every fixture under `test/test_compile/fixtures` but the
eight map fixtures compiles to the same C, or the same diagnostic, as a
compiler built from `dee4a2445` with that revision's library: 771 of 780.
The ninth, `missing_library_import`, differs only in the library path its
diagnostic names, since the base ran against an extracted copy. The seven
block fixtures are among the 771.

**Lines,** from `dee4a2445`, over both ceilings, which stopped the landing
for a growth audit:
- **production** +533 net (619 added, 86 removed), against +450;
- **tests** +725 net, against +550: step 0 +85 and the native +640.

**Ceilings, corrected by the coordinator on 2026-11-26:**

| Ceiling | Old | New |
| --- | ---: | ---: |
| Production lines | +450 | +540 |
| Test lines | +550 | +730 |

The brief's figures were estimates from uncompiled sketches. The audit below
found no bloat: the growth is the emitted job, written out (about 125); the
plan's own impure-callback message, which names the map (+89); and the
range splitter's C (+73). The tests grew by the verify cases for both
callback kinds, among them the closure rejection that review asked for, and
by eight fixtures, each run at three thread counts.

| Area | Production | What it holds |
| --- | ---: | --- |
| Emit | +180 | the job, piece and run function (about 125), the inventory, requirements and names |
| Check, the impure-callback message | +89 | the rendering (+37), `pooled_callbacks` on the contract and pending call (+22), through the worklist (+18), the decision (+9) and the error (+3) |
| The range splitter | +73 | `JOIN_RANGE_RUNTIME`, C |
| Specialize | +64 | `MapCallback`, its request and translation, and the shared callable-parameter request |
| Check, the native | +63 | the label, operation, contract, generalized callable form and restriction |
| Verify | +47 | the map's signature for both callbacks |
| Own and the library | +17 | the pin, and `parallel_map` |

| Area | Tests |
| --- | ---: |
| Step 0: the harness and the block runs | +85 |
| The eight fixtures | +181 |
| Their e2e cases | +96 |
| The verify suite and its shared helper, less what join's suite lost | +287 |
| The check cases | +76 |

The estimate did not foresee the emitted job's size once formatted, nor that
naming the map in the impure message means carrying a callable's use through
check's worklist.

### Spike K: the concurrency kernel

**The question.** Can the Blorp kernel, with pure transitions through
`take`, `put` and `update`, a native context switch and permit-based parking,
keep its invariants under real races, and run a channel round trip with no
allocation in the steady state, in about the time the same algorithm takes
in C?

**Build.** Plain Blorp stubs (`take_state`, `put_state`, `switch_to`) for the
spike's concrete types, with their emitted bodies replaced by C: a mutex
around a slot, the assembly switch, and the park permit. `update` stays in
Blorp. A probe in the first plan review already ran an arm64 `__asm__` switch
with the ASan annotations, a recursion depth of 1,000 on the fiber, and a
clean exit under the harness's flags.

**Cases:**
- a ping-pong, and a channel of capacity 64 kept half full;
- exactly-once choice across two channels with simultaneous senders,
  including a selecting sender meeting a selecting receiver;
- a wake from a helper thread racing a park;
- cancelling a parked fiber (the old use-after-free), and a timer racing a
  handoff;
- task start and join cost, the cost behind the old 3× slowdown;
- 10,000 and 100,000 live fibers, against Linux's default
  `vm.max_map_count` of 65,530;
- one native call's round trip through the blocking pool;
- two to four carriers on one channel.

The C baseline is the same algorithm: a lock per channel and the same
queues. The 3× threshold then measures code generation alone.

**Decide:**
- **Continue** if a message allocates nothing in the steady state, a round
  trip is within about 3× the C baseline, and every race case keeps its
  invariant.
- **Costs the compiler can remove**, such as a closure, a boxed step or a
  copy, are recorded and do not stop the work (root `AGENTS.md`).
- **Structural costs,** such as a lock per operation or two cells per
  operation, trigger the fallback: the hot transitions move to C behind the
  seam, and the logic stays in Blorp.

**Budget:** about four working days.

### Spike K results

It ran on 2026-11-26 on the Apple Silicon machine of Spike P: 10 cores, 4 of
them performance cores, 32 GiB, macOS 26.7.1 and Apple clang 21. Linux runs
used the cached test images: arm64 Ubuntu 24.04 in Docker's linuxkit 7.0.14
VM, with clang 18 and glibc 2.39, and amd64 under Rosetta for the x86-64
switch.
- **Where things are.** The spike's sources are on the unlanded branch
  `spike/concurrency-kernel`, under `spike/kernel/`. Raw samples, logs and
  builds are in the main checkout's ignored `build/concurrency/spike-k/`.
- **Load.** Other sessions kept the Mac at a load average of 2 to 4 during
  timing.
- **Review.** A review on Opus checked these results, and its probes are in
  `review/`.

**What was built.**
- **The kernel, in Blorp:** 904 lines of logic in `kernel.brp`.
  - `Ring[T]` over a List, and `Waiter`.
  - `ChannelState`, and the pure transitions `offer`, `accept`,
    `next_sender`, `attempt`, `registered`, `without_fiber` and
    `closed_state`.
  - `send`, `receive` with an optional deadline, `close`, and two-branch
    choice, which locks its channels in id order.
  - Per-carrier run queues, the scheduler loop, and join scopes.
  - The cases and `main` are another 1,037 lines; the 51 native stubs are
    248.
- **The patch.** `patch.py` finds each stub by its marker
  `/* kernel.NAME */` and reads its types from the emitted signature.
  - **It checks the ABI:** own must have given every owning stub its
    parameter owned, and `Scope` must be a struct passed by value with an
    empty dup helper.
  - **It replaces the bodies,** and includes the runtime after the
    prototypes.
  - **Anything else fails loudly.**
- **The C runtime,** `spike_kernel.h`:
  - the switch, for arm64 (Mach-O and ELF) and x86-64;
  - stacks of 256 KiB, lazily committed above a 64 KiB `PROT_NONE` guard,
    and cached for reuse;
  - the ASan and TSan fiber annotations on every switch;
  - park and wake with permits, on one atomic word per fiber;
  - a wait word per fiber, the generation shifted left 2 bits with the
    phase below, and its compare-and-swap claim;
  - one to four carriers with an eventcount idle wait;
  - a timer thread, two helper threads for blocking natives, and a
    watchdog;
  - the cell tables.
- **The C baseline,** `baseline.c`, 449 lines: the same algorithm on the
  same runtime, with the same locks, rings, claims and permits. The review
  confirmed it is the same algorithm.

**Ownership across the seam.**
- **No mismatch remains,** so the C needs no retain:
  - `take_*` returns its state owned;
  - own made each `put_*` and `new_*_cell` own its counted parameter, and
    `patch.py` checks that it did, failing closed;
  - `Scope` crosses by value and holds nothing counted, which `patch.py`
    asserts;
  - `Task` crosses as its C enum.
- **The placeholder decides the ABI.** A placeholder that reaches an
  in-place operand, `state.buffer.push(cell)`, is owned. The first one
  tried stored the state in a List literal, and own inferred it borrowed:
  the caller dropped the state after the call, and the C would have had to
  retain it. That is 2 count operations per `put`.
- **Landing 4 still needs `put` to own its operand by name,** by
  generalizing `reuses_first_operand`. A placeholder is not a contract.

**`update` stays Blorp, and is a direct call.** `update_queue` calls its step,
`next_ready`, as `blorp_f_41`, and the program has no closure.
- **Channel operations cannot use `update` as written.** A waiter's claim is
  a C compare-and-swap, so impure. It must run between pure steps while
  the cell is held: claim, or drop the waiter and try the next.
- **So `send`, `receive` and choice** take the state, loop over a pure step
  and a claim, and then put it back.

**Round trips, Blorp against C.**
- **How it was measured.** `-O2` without diagnostics, with the kernel's
  default spinning lock in both programs. Each figure is the median of 7
  interleaved runs at 2N, in nanoseconds per unit; the steady-state figures,
  (median(2N) − median(N)) / N, agree within 5%.
- **The runs.** macOS is the final run, at a load of about 3.7; its
  "Earlier" column is the first run, at 2 to 3. Linux ran once, at a load
  of 1 to 2.
- **N was** 200,000 round trips, 2,000,000 messages, or 200,000 tasks.
- **Cycles and instructions** come from macOS's `/usr/bin/time -l`, per
  unit, on one carrier. The Linux image has no counters, so Linux has none.

| Unit | Carriers | macOS C | macOS Blorp | Ratio | Earlier | Cycles, C : Blorp | Linux C | Linux Blorp | Ratio |
| --- | ---: | ---: | ---: | ---: | ---: | --- | ---: | ---: | ---: |
| Ping-pong round trip | 1 | 109 | 306 | 2.80 | 2.42 | 419 : 1,095 (2.6×) | 114 | 264 | 2.32 |
| Ping-pong round trip | 4 | 472 | 1,110 | 2.35 | 2.19 | | 478 | 1,269 | 2.66 |
| Half-full: a send and a receive | 1 | 6.8 | 70.6 | 10.4 | 10.5 | 25 : 252 (10.1×) | 6.3 | 56.0 | 8.9 |
| Pipeline message | 1 | 10.0 | 74.0 | 7.4 | 7.0 | 39 : 266 (6.8×) | 10.1 | 81.3 | 8.1 |
| Pipeline message | 4 | 20.4 | 107.5 | 5.3 | 1.24 | | 22.8 | 81.2 | 3.6 |
| Task, batches of 1 | 1 | 138 | 182 | 1.32 | 1.31 | 518 : 668 (1.3×) | 153 | 208 | 1.36 |
| Task, batches of 1 | 4 | 135 | 182 | 1.35 | 1.33 | | 150 | 209 | 1.39 |
| Task, batches of 64 | 1 | 77 | 96 | 1.24 | 1.24 | 278 : 347 (1.25×) | 86 | 109 | 1.27 |
| Task, batches of 64 | 4 | 706 | 895 | 1.27 | 1.53 | | 304 | 322 | 1.06 |

- **The half-full case is one fiber,** so its 4-carrier figures equal its
  1-carrier ones and are left out.
- **Instructions per unit,** on one carrier on macOS, C against Blorp:
  - ping-pong, 822 against 3,860;
  - half-full, 181 against 1,613;
  - pipeline, 189 against 1,645;
  - task, 1,672 against 2,233.
- **The ping-pong spread.** Paired by round, the final 1-carrier ping-pong
  ratios ran 2.37 to 3.05, with three of the seven runs at 2.95 or above.
- **The pipeline spread.** The 4-carrier pipeline settles into a different
  regime from run to run: C ran 78 to 90 ns in the first run and 20 to 22
  ns in the final one, so its ratio is not stable.

So, against the rule's "a round trip within about 3×":
- **The switching round trip passes.** Ping-pong is 2.3 to 2.8× in time, and
  2.6× in cycles.
- **The buffered round trip fails.** The half-full channel is the brief's
  other case-1 round trip. It is 8.9 to 10.4× as measured, and an estimated
  3.1 to 3.6× once the attributed removable work is gone.
- **The pipeline fails as well:** 3.6 to 8.1×.
- **Tasks are within 1.4×.**

**Allocations and counts per message.** These are steady-state figures,
(count at 2N − count at N) / N, from a diagnostics build with
`BLORP_LEAK_CHECK=strict` clean at both sizes. The C baseline makes neither.

| Unit | Allocations | Count operations | Attributed to |
| --- | ---: | ---: | --- |
| Ping-pong round trip, 1 carrier | 4 | 64 | `blorp_record_make_11`, in `offer` and `accept` |
| Ping-pong round trip, 4 carriers | 4 | 72 | the same, plus run-queue pops by carriers that woke without work |
| Buffered send and receive | 2 | 28 | the same |
| Pipeline message, 1 carrier | 2.03 | 28.4 | the same; a few parks add run-queue traffic |
| Task, batches of 1 | 1 | 16 | the runtime's fiber record, which C allocates too; counts on the run-queue Ring |
| Task, batches of 64 | 1 | 8.1 | the same |

- **`BLORP_ALLOCATION_SITES`,** rerun on the final binaries at 20,000 rounds
  (emitted C `ac3dfba49a43fdee`), puts every per-message allocation in
  `blorp_record_make_11`. That is the heap `ChannelState`, rebuilt by every
  `{ state | ... }`.
- **The rebuild, in the emitted C,** is three field dups, the old record's
  drop, and a fresh `blorp_record_make_11`; `with_buffered` is the smallest
  example.
- **No other source.** There is no closure, no boxed step, no tuple and no
  List copy: each ring's List is updated in place, and `pop` dups its List
  rather than copying it.

**Where the time goes,** on the buffered path, one carrier, macOS.
- **The removable work, alone.** `removable.c` performs exactly what the
  counts attribute to one send and receive: two rebuilds and 28 count
  operations. It retires about 1,030 instructions in 180 to 200 cycles,
  45 to 47 ns.
- **Unit costs.** A free and then a malloc of the record retires 496
  instructions in 67 cycles, using the review's `unit.c`. A dependent dup
  and drop pair is 6 instructions in 14 cycles.

  | | macOS | Linux |
  | --- | ---: | ---: |
  | A free then a malloc of the record | 17 to 21 ns | 5.2 ns |
  | A dup and drop pair | 3.5 ns | 3.5 ns |
  | An uncontended lock and unlock | 0.9 ns | 0.9 ns |

- **The allocator's share,** by instructions and cycles: two pairs are 992
  of Blorp's 1,613 instructions (61%) and about 134 of its 252 cycles
  (53%).
  - **`sample` shows more:** 79% of the carrier's samples, of which 748 of
    1,556 are in `mach_absolute_time`, under `_xzm_free`. That is likely
    skid, so the cycle figure stands.
  - **What the samples do show:** macOS 26's free reads the clock and
    zeroes the block.
- **What remains:** 581 instructions, against C's 181. At the measured IPC
  of 6.4 to 7.2 that is 81 to 91 cycles, against C's 25.
- **The ratio once the removable work is gone,** by estimate:

  | Path | System | Measured | Estimated without it | How |
  | --- | --- | ---: | ---: | --- |
  | Buffered | macOS | 10.1× in cycles | 3.1 to 3.6× | the 581 remaining instructions at IPC 6.4 to 7.2; 2.6 to 3.8× across both programs' run spread |
  | Buffered | Linux | 8.9× in time | not verifiable | no counters in the image; subtracting `removable.c`'s 29 ns gives about 4.3×, unchecked |
  | Ping-pong | macOS | 2.6× in cycles | 1.2 to 1.7× | the remaining ~1,800 of 3,860 instructions at its IPC of 3.5, or the isolated cycles subtracted |
  | Ping-pong | Linux | 2.3× in time | not verifiable | |

- **What the estimate assumes removed.** Both remedies below:
  - **reuse alone** removes the 2 allocations and about 14 of the 28 count
    operations (the rebuild's field dups and release);
  - **the other 14** need dup and drop elision: moving out of the dying
    `(state, step)` tuple, and a borrowed `pop`.
- **What remains is general code generation, not structural.** Structs over
  16 bytes, such as `Ring` and the step tuples, are passed and returned
  through memory; Option and tuple values are shuffled; every List access
  is bounds-checked.
- **A measured ratio** would need a rewrite of emitted helpers, such as a
  free list behind `blorp_record_make_11` or plain counts. This spike's
  approval does not cover that.

**Contention amplifies a long critical section.**
- **The transition runs under the cell's lock,** so the record rebuild's
  malloc and free do too.
- **With pthread mutexes,** cross-carrier ping-pong spent its time in
  `__psynch_mutexwait`. The retained samples show medians of 73,537
  involuntary context switches at 200,000 round trips and 93,178 at
  400,000, against 50 and 87 for C. macOS mutexes block in the kernel at
  the first contention. With the spinning lock, Blorp's are 247 and 343.
- **The spike's default lock** spins 64 times, then calls `sched_yield`,
  and never sleeps. No kernel lock is held across a park, so spinning
  cannot deadlock. But a lock that never sleeps wastes a core when
  carriers outnumber cores, and that oversubscription was not tested. Go's
  runtime locks spin, yield, and then sleep on a futex.

The same final macOS run with pthread mutexes in both programs, medians in
nanoseconds:

| Unit | Carriers | C, mutex | Blorp, mutex | Ratio | Blorp, spinning lock |
| --- | ---: | ---: | ---: | ---: | ---: |
| Ping-pong round trip | 1 | 152 | 339 | 2.23 | 306 |
| Ping-pong round trip | 4 | 552 | 1,789 | 3.24 | 1,110 |
| Half-full: a send and a receive | 1 | 12.2 | 76.7 | 6.3 | 70.6 |
| Pipeline message | 4 | 104 | 220 | 2.12 | 107.5 |

The spinning lock takes 38% off Blorp's cross-carrier round trip and 15% off
C's: the longer Blorp section collides more often.

**Scheduling across carriers costs both programs alike.** These are costs of
the shared runtime, not of Blorp:
- **Cross-carrier ping-pong** is about 4× the 1-carrier figure in both: 109
  to 472 ns in C, and 306 to 1,110 in Blorp.
- **Tasks in batches of 64 on 4 carriers** cost 706 ns a task in C, against
  77 on 1 carrier; on Linux, 304 against 86.
- **Each cross-carrier wake** goes through the eventcount, and often a
  sleeping carrier's condition variable.

The old compiler's 3× was task and scheduling cost. Here the gap between
Blorp and C is absent: 1.06 to 1.53× for tasks. The scheduling cost itself
is not.

**Race cases.** Each runs 100,000 rounds, in three macOS builds (`-O2`, ASan
and UBSan with the strict leak check, and diagnostics with counts and the
strict leak check) and three Linux ones (`-O2`, ASan, and TSan with
`halt_on_error=1`).

| Build | Runs | Failures |
| --- | ---: | ---: |
| macOS: each of three builds, on the revised binaries | 22 | 0 |
| arm64 Linux: each of three builds, on the revised binaries | 22 | 0 |
| amd64 Linux under Rosetta, `-O2` and ASan, 20,000 rounds | 14 | 0 |

- **What the 22 runs are:**
  - choice, self-choice, helper-wake, cancel and timer, on 1 and 4
    carriers;
  - then ping-pong, pipeline, choice and helper-wake on 2, 3 and 4
    carriers, for case 8.
- **So there are duplicates.** Choice and helper-wake on 4 carriers run
  twice.
- **Ping-pong and the pipeline use carriers 0 and 1 at every count,** so
  their 3- and 4-carrier runs add only idle carriers.

**Which runs race.**
- **On one carrier,** choice, self-choice and cancel run every fiber on one
  thread in turn.
  - **Cancel is deterministic** there: 25,000 received and 75,000
    cancelled in every build.
  - **Choice passes without the claim's CAS.**
  - **Helper-wake and the timer do race:** the helper and timer threads run
    beside the carrier.
- **Self-choice never contends the CAS.** Each selection's two waiters are on
  one channel, so its claimers serialize under that channel's lock.
- **The jitters,** in relax instructions:
  - helper-wake: up to 96 on carrier 0, and up to 144 on carrier 3;
  - the canceller: up to 192;
  - cancel's racing sender: up to 160;
  - the timer case's sender: up to 25,600.
- **Deadlines** are 2 to 5 µs.

The invariants each case asserts in the program:
- **Choice:** two rendezvous channels.
  - **Senders:** a plain sender on each channel, and two selecting senders
    over both.
  - **Receivers:** two selecting receivers over both, and a plain receiver
    on each.
  - **After the run:** after 400,000 distinct values, the count, sum and sum
    of squares received equal those sent, and every selection completes
    branch 0 or 1.
  - **Before closing:** close drains every ring, so the waiter check runs
    first. No sender waiter may be left, and no channel may hold more than
    its 3 receivers' waiters. With the leave skipped, that check fails:
    26,003 receiver waiters on one carrier, and 67 on four.
- **Self-choice:** two pairs, each selecting a send and a receive on one
  channel. Sends equal receives, 200,000 pairs; no fiber received its own
  value; and no waiter is left once every fiber has finished.
- **Helper wake:** a helper thread unparks the fiber while it parks. All
  100,000 wakes arrive, with the watchdog armed.
- **Cancel:** a target parked on a receive is cancelled, and every other
  round a sender races the cancel.
  - Either the target got the value and the channel is empty, or it was
    cancelled and any raced value is still buffered.
  - No cancelled waiter is left, and a probe send after the scope is
    retired meets none.
- **Timer:** a receive with a deadline races a send. Exactly one of a value
  and a timeout happens, and a timed-out value is still in the channel.

**Where each cancel and timeout met its fiber.** These are path counters, at
100,000 rounds. A cancel or timeout can find its fiber:
- **parked:** the carrier has published PARKED;
- **mid-park:** the fiber has decided to park, but its carrier has not yet
  published PARKED;
- **arming:** it has armed its wait and not yet parked;
- **at arm:** the wait's own check after arming sees the cancel;
- **at top:** `receive`'s `cancelled()` sees it before arming.

Misses are cancels that found no armed wait, and timers whose claim lost to
a handoff.

| Run | Outcome | Parked | Mid-park | Arming | At arm | At top | Missed |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| macOS `-O2`, 1 carrier | 75,000 cancelled | 75,000 | 0 | 0 | 0 | 0 | 25,000 |
| macOS `-O2`, 4 carriers | 97,399 cancelled | 49,454 | 630 | 341 | 46,537 | 437 | 49,575 |
| Linux `-O2`, 4 carriers | 99,658 cancelled | 14,741 | 5,473 | 4,367 | 74,309 | 768 | 75,419 |
| Linux TSan, 1 carrier | 75,000 cancelled | 75,000 | 0 | 0 | 0 | 0 | 25,000 |
| Linux TSan, 4 carriers | 80,975 cancelled | 49,000 | 431 | 920 | 10,886 | 19,738 | 49,649 |
| macOS `-O2`, 1 carrier | 50,522 timed out | 50,522 | 0 | 0 | | | 7,651 |
| macOS `-O2`, 4 carriers | 49,187 timed out | 49,183 | 3 | 1 | | | 7,672 |
| Linux `-O2`, 4 carriers | 33,737 timed out | 33,732 | 2 | 3 | | | 9,265 |
| Linux TSan, 1 carrier | 26,094 timed out | 26,071 | 13 | 10 | | | 31,811 |
| Linux TSan, 4 carriers | 11,154 timed out | 11,148 | 3 | 3 | | | 8,098 |

Each row's classes sum to its cancels or timeouts. A cancel's misses equal
its at-arm and at-top hits plus the rounds whose target received the value.

- **The cancel windows are exercised only on 4 carriers.** On one carrier,
  every cancel met a parked fiber.
- **The timer rarely meets a window,** a few dozen times in 100,000: it is
  armed after the wait registers, and its deadline is at least 2 µs.
  Under TSan it does so even on one carrier, since the timer thread races
  the carrier.

**The bites.** Each change was made in its own build, and each run checks
the invariant.

| Change | Case | Result |
| --- | --- | --- |
| No permit: a wake before its park is dropped | 4, on 1 and 4 carriers | the watchdog's "no switch for 3000 ms with N fibers live", exit 3 |
| No claim CAS, no widening | 3, on 4 carriers | 213 and 335 waits claimed twice in two runs; 400,065 and 400,169 values received for 400,000 sent |
| No claim CAS, no widening | 5, cancel, on 4 carriers | 312 and 156 double claims; "cancelled, and the racing value was lost" |
| No claim CAS, no widening | 5, timer, on 4 carriers | 386 and 403 double claims; "timed out, and the value was lost" |
| No claim CAS, no widening | 5, timer, on 1 carrier | 123 double claims, since the timer thread races the carrier |
| No claim CAS, no widening, under TSan, 20,000 rounds | 3, cancel and timer, on 4 carriers | data races in all three: in `spike_claim`'s outcome write, and in choice and cancel also in the delivery; 114, 25 and 23 double claims |
| A cancelled waiter does not leave its queue | 5, under ASan | `heap-use-after-free` in `spike_claim`: the probe send claims a waiter whose fiber record the scope's retire freed |
| A selection does not leave its other queue | 3, on 1 and 4 carriers | the pre-close check fails, as above |

**Widening the claim's window.** It is `SPIKE_CLAIM_WINDOW`, relax
instructions between the test and the store, 0 by default. Set to 64, it
raised cancel's double claims to 1,841 and 1,549. Choice, at 270 and 256,
and the timer, at 424 and 456, barely changed. The first report's 93 double
claims in choice came from that widened build.

**Where the CAS is needed.**
- **Between claimers under different locks:** in a selection over two
  channels, and between a channel, the timer and a canceller. The bites
  above show all three.
- **Not within one channel,** where that channel's lock serializes every
  claim: without it, choice and cancel still passed on one carrier, and so
  did self-choice on four.

**Not shown: the rule that a waiter never owns its fiber.**
- **The cycle cannot form here.** Ring entries hold Ints, not references,
  and channels are Ints too. So the plan's cycle, from the channel through
  its waiter and fiber and the fiber's stack back to the channel, cannot
  form in the spike.
- **What the bite build did instead.** The `SPIKE_WAITER_OWNS_FIBER` build
  simulates the waiter's reference with a count on the fiber record, taken
  when the wait arms and dropped by `end_wait`.
  - **With the leave,** the strict leak check is clean in the cancel and
    timer cases. That shows balanced bookkeeping, not the rule.
  - **Without the leave,** 78,995 records leaked and the run exited 99. But
    the leak comes from `SPIKE_SKIP_LEAVE` also skipping `end_wait`'s
    simulated release, not from a queue holding a reference.
- **So the rule is untested.**

**Fiber limits** (case 6).

| | macOS, arm64 (16 KiB pages) | Linux, arm64 (4 KiB pages) |
| --- | --- | --- |
| Mappings per live fiber | 2.0: the stack and its guard | 2.0 |
| Resident per parked fiber | 16.6 KB: one page and its record | 4.3 KB |
| 10,000 parked fibers | 169 MB resident; parked in 27 ms | 47 MB; 26 ms |
| 100,000 parked fibers | 1.67 GB resident; parked in 0.30 s | 433 MB; 0.26 s |
| Where it stops | not on mappings: the probe was granted 4,000,000 guarded reservations, 1.2 TiB; memory stops it near 2 million parked fibers in 32 GiB | at half of `vm.max_map_count`: 131,055 live fibers at this VM's 262,144, where mprotect fails with ENOMEM; about 32,750 at the default 65,530 |

- **A page guard splits a mapping,** so two mappings per fiber is the floor
  with guard pages. 100,000 fibers on a default Linux needs
  `vm.max_map_count` raised, or another guard scheme.
- **The default's stop is derived, not observed.** `vm.max_map_count` is
  global to the shared Docker VM, so it was not lowered.
- **No fiber hit its guard.** Stack overflow was not tested.

**Natives, tasks and the stack.**
- **A native's round trip through the blocking pool,** case 7, is about 2.0
  µs on 1 and 4 carriers. A helper's wake in case 4 is 2.1 µs. Both are the
  helper's condition-variable wake; a direct call costs about 1 ns.
- **Per task,** case 2:
  - **allocations:** one, the runtime's fiber record, which C allocates too;
  - **counts:** 16 in batches of 1, and 8.1 in batches of 64;
  - **stacks:** reused from the cache.
- **What the real design adds:** a task's closure environment, one more
  allocation for a capturing lambda, unless the runtime stores it in the
  fiber record.
- **A deep drop on a fiber,** a chain of a million nodes, used 8.4 to 9.0
  KB of stack on arm64 and 4.2 KB on x86-64. Blorp's bounded release is
  128 levels, then a loop.

**Parking: a design difference from the plan.**
- **The plan's protocol** releases the kernel lock only after the switch
  has saved the fiber, as Go's `gopark` does.
- **The spike did not build it.** It puts the cell back before parking:
  `send` puts at `kernel.brp:324` and parks at `336`, and `receive_until`
  puts at `410` and parks at `420`. It then relies on the permit and on
  publishing PARKED on the carrier's stack after the switch
  (`spike_kernel.h`, `spike_switch_to`, lines 540 to 556). A waker queues
  the fiber only once it sees PARKED.
- **Pinning matters here.** Fibers stay on the carrier that started them,
  so no other carrier can resume a half-saved fiber.
- **So the difference is untested until fibers migrate.** The path counters
  show the window is reached: 630 cancels met a fiber mid-park.

**Design changes, for the landings that own them.** The plan's design
sections were not edited.
1. **Landing 5: a scope's child count goes down on the carrier.** It must
   happen after the fiber's last switch and after its record is filed, as
   Go's `goexit` runs on g0. The strict leak check found the first version
   leaking one 136-byte fiber record in a 4-carrier ping-pong run: the
   child lowered the count on its own stack, and the parent retired the
   scope before the record was filed.
2. **Landing 5: the scope owns its children's records until it is
   retired.** A canceller in the scope then never touches a freed record.
   The cancellation tree must give that guarantee, since a cancelled fiber
   cannot wait for a handshake.
3. **Landings 4 and 5: exactly one party wakes a wait, its claim's
   winner.** So no permit is ever stale. When the fiber was not parked, the
   permit exchange is the waker's last touch of it. When it was parked,
   `enqueue` also reads `fiber_carrier`, and the fiber stays parked until
   it is queued. The kernel asserts the rule: "a fiber woke before its wait
   was claimed".
4. **Landing 4: kernel locks spin, then block.** They spin briefly, then
   sleep, as Go's do, rather than spin forever or use macOS pthread mutexes.
5. **Landing 5: a cancel must not claim a join's wait.** Rule 4 has a
   cancelled block still wait for its tasks.
6. **Landings 4 and 5: helper jobs are retired as timers are.** A waiter
   that ends without its native's result removes its job, under the job
   queue's lock, before moving on.
7. **Landing 6: channel operations loop a pure step and a claim under the
   held cell,** rather than one `update`.
8. **Landing 6: channels wait for in-place reuse of a uniquely owned
   record.** Landing 5, the MVP, has no channels.
9. **Landing 4: the emitted file sets feature macros before its first
   include.** glibc declares `clock_gettime` and `nanosleep` under
   `-std=c11` only with `_POSIX_C_SOURCE`, and the runtime arrives mid-file;
   the spike passes it on the command line.

**Thread-locals.**
- **Fibers stay on the carrier that started them,** and `spike_switch_to`
  asserts it.
- **A fiber touches these thread-locals:**
  - `spike_self`, the carrier;
  - Blorp's `blorp_release_state`;
  - libc's, such as `errno` and the allocator's per-thread state; macOS
    reaches them through `_tlv_get_addr`, which the profile shows.
- **Migration would need more than accessors.** Under ASan, the code after
  a fiber switches back records the carrier's stack in the carrier pointer
  it read before the switch. M:N, landing 7, needs that re-read, beside the
  plan's `noinline` accessors.

**Latent use-after-frees no case exercises.** Both are risks for landings 4
and 5.
- **A cancelled join.** `spike_cancel` claims any armed wait, a join's
  included. `join_scope` then retires the scope while its children still
  run, against rule 4. Their records are later filed under a retired, and
  perhaps reused, scope.
- **A cancelled native.** Its helper job stays queued after the waiter
  returns. The job's later `spike_claim` touches a record that the scope's
  retire may have freed.

**The decision, as the rule gives it.**
- **Every race case kept its invariant,** in normal, ASan and TSan builds on
  1 to 4 carriers. The section above says which runs race, and each bite
  failed as expected; the waiter-ownership rule is untested.
- **Each message allocates twice in the steady state,** from one cause. Own
  does not yet update a uniquely owned heap record in place, so every
  `{ state | ... }` of `ChannelState` allocates. The cause is removable.
- **The switching round trip is within 3×:** 2.3 to 2.8× in time, and 2.6×
  in cycles.
- **The buffered round trip is not.**
  - **As measured:** 8.9 to 10.4×, and 10.1× in cycles.
  - **After the attributed removable work,** by estimate: 3.1 to 3.6× on
    macOS. Linux cannot be checked without counters.
  - **What remains** is general code generation.
- **No structural cost was found.**
  - **Locks:** an operation takes exactly the locks the C baseline takes,
    one channel cell plus the woken fiber's run queue.
  - **Choice:** a selection takes two channel cells, as Go's does.
- **So the rule says continue,** with the transitions in Blorp. The seam
  still lets a hot transition move to C one for one, if the buffered gap
  stays after the compiler work. Whether that residual is acceptable is
  Keith's judgement.

**Costs to remove,** each removable by the compiler:
- **The record rebuild per transition:**
  - two allocations per buffered send and receive;
  - 61% of its instructions and about half its cycles on macOS.

  In-place reuse of a uniquely owned record removes it, as Lean 4 and Koka
  reuse a constructor cell. It also removes about 14 of the 28 count
  operations.
- **The other count traffic:** moving fields out of the dying
  `(state, step)` tuple, and a borrowed `pop`.
- **The longer critical section.** Reuse shortens it; until then, the
  spinning lock contains it.
- **General code generation:** about 580 instructions against C's 181. Structs
  over 16 bytes go through memory, and Options and tuples are shuffled.

**Not covered:**
- a quiet machine, and Linux cycle counts;
- native x86-64 hardware, and CET and BTI;
- a measured, not estimated, ratio with the removable costs gone;
- channel messages other than Int, and generic channel states;
- the rule that a waiter never owns its fiber;
- a fiber's stack guard being hit;
- a timer as a branch of a selection, and choice over more than two
  branches;
- cancelled joins and cancelled natives, the latent use-after-frees above;
- oversubscription: more carriers than cores, where a lock that never
  sleeps wastes cores;
- the cancellation tree, `simulate` and deadlock detection;
- a timer queue in Blorp, untested by the brief's choice, which put the
  timer in C;
- the plan's lock-after-switch parking, and fiber migration.

### Landing 4a results

**What landed:** the process and print natives are correct on any number of
threads, and a program on one thread behaves as before. It is runtime C and
one emission rule, with no seed rotation: no label or contract changed.
- **The fork lock,** `blorp_process_fork_lock`, a `pthread_rwlock_t` in
  `PROCESS_HELPERS_RUNTIME`, as Go's `syscall.ForkLock`.
  - `blorp_process_pipe` holds the read side from `pipe()` until both ends
    are `FD_CLOEXEC`. macOS has no `pipe2`.
  - Both forks hold the write side. The parent releases it as soon as `fork`
    returns, and the child, which runs only async-signal-safe code until it
    execs, never touches it. So no `pthread_atfork` is needed.
  - No wait, poll or read holds it.
  - Every other descriptor a native makes is close-on-exec atomically
    (`O_CLOEXEC`, `F_DUPFD_CLOEXEC`), so only the pipe needed the read side.
  - Taking or releasing it aborts on any failure, as the literal lock does,
    through three helpers: take the read side, take the write side, and
    release.
- **The counted swap,** `blorp_process_interrupt_swap`: a count of the runs
  waiting with SIGINT and SIGQUIT ignored, and the caller's dispositions.
  - The first run in saves and ignores both; the last one out restores them,
    as glibc's `system` counts. Every run's child resets both from the saved
    ones, as before.
  - Entering and leaving happen under the fork lock's write side, so a fork
    sees no swap or a whole one. Every path of `run` after a successful enter
    reaches its one leave, and leaving more often than entering is a runtime
    defect, which aborts with its message.
  - `capture` reads the count under the same write side, just before its
    fork. While a run holds the signals, its child takes the caller's
    dispositions back before exec, as it would have inherited them.
  - `exit_interrupted` holds the write side from its `sigaction` to its
    `raise`, so no run on another thread ignores SIGINT again in between.
- **Whole lines.** `print` and `print_error` hold their stream with
  `flockfile` from the text to the LF. A console write is one `fwrite`,
  which C11's stream lock keeps whole; the line case checks it too.
- **Change 9.** A program that prints or prints errors requests
  `PROCESS_POSIX_PRELUDE`, since glibc declares `flockfile` under `-std=c11`
  only with `_POSIX_C_SOURCE`. The prelude is the first fragment whenever it
  is requested, so it precedes the file's first `#include` in every fragment
  order. Its `#error` now names the Blorp runtime, not only process and fs.

**One difference from the brief.** The brief gave the swap a mutex of its own
for `exit_interrupted` to hold. Every change to the count and the
dispositions already holds the fork lock's write side, so a second lock would
guard the same fact. `exit_interrupted` takes the write side instead, across
a `sigaction` and a `raise` only.

**The window, measured** with the case's own timings, on macOS under ASan:

| | A's capture of `cat` | Descriptors B's child holds beyond its own |
| --- | ---: | ---: |
| Main | 3,037 ms | 2, the ends of A's stdin pipe |
| Without the read side | 3,018 to 3,036 ms | 2 |
| This landing | 206 to 236 ms | 0 |

**A reader-preferring lock.** glibc's default rwlock prefers readers, so a
stream of pipe creations could hold a fork off. In the window case the
waiting fork began 8 to 12 µs after A's window closed on macOS, 56 to 108
µs on emulated x86-64 with GCC, and 48 to 87 µs on arm64 with Clang, in five
runs each. Readers hold the lock only for a `pipe()` and a few `fcntl`s.

**Tests,** in the existing direct-C suites, with the probes' macro
interposition. `raise` joins it, and `exec_ready_writer` now announces any
child about to exec, not only the stalled one.

| Case | What it checks | Fails without |
| --- | --- | --- |
| `capture-fork-window` | B's child holds no more descriptors than it does alone, the exact check; and A, held 200 ms in its stdin pipe's window, finishes within half of B's child's 3 s life | the read side: A took 3,018 to 3,036 ms, and B's child held A's two ends |
| `run-overlapping-interrupts` | two runs overlap with the caller at the defaults, ignoring both, and with a handler: each child finds the caller's, both stay ignored while the second waits, and the caller's stand after both | the count: with a save per call, B's child found both ignored and SIGINT stayed ignored after both runs |
| `capture-during-run` | the same three callers: a capture's child finds the caller's dispositions while a run waits | the snapshot: its child found both ignored |
| `exit-interrupted-during-run` | the process ends by SIGINT while a run waits, and while a run starts between the `sigaction` and the `raise` | the write side in `exit_interrupted`: the starting run ignored SIGINT again, and the native returned |
| `run-exec-failure` | a failed exec is `LaunchFailed(NotFound)` and leaves no holder: the next run ignores both while it waits and restores them | a leave skipped after a failed exec |
| `whole_lines` (console) | four threads, 10,000 iterations each, of `print`, `print_error` and a console write, with an `fputc` that yields before the LF: every line whole | `flockfile` on either stream: lines tore every run |
| `print requests the POSIX declarations before any header` | a printing program's C starts with the prelude | the two print requirements in `needs_posix` |

The requirement table now includes the prelude, so every case there also
says whether a program gets it: print, print_error and both do, and the rest
do not. `test_unused_declarations_select_no_fs_fragments` still holds.

**Evidence:**
- **Bites.** Each runtime break above ran 3 times against the final
  runtime and failed 3 of 3, and the unbroken build passed 3 of 3. The
  window, swap and exec breaks are in the generated process runtime, the
  line breaks, one per stream, in the console runtime. The emission break,
  in `emit.brp`, failed the four print cases of the requirement suite.
- **Stress,** with the suites' flags (ASan and UBSan): each new process case
  20 of 20 on macOS, and each new case, the line case included, 10 of 10 on
  both Linux targets.
- **ThreadSanitizer,** by hand, on the line case: 0 reports in 23 runs on
  macOS and 3 on arm64 Linux. The fork cases run under ASan and UBSan only, since TSan with
  `fork` in a threaded process is unreliable.
- **Linux,** in the cached images, with the suites' flags: GCC 13.3 on
  x86-64 and Clang 18.1 on arm64 built the three probes and passed 24
  process modes, including every new one and the pty probe, seven console
  cases including `whole_lines`, and the three print cases. Every fixture's
  C compiled in both memory modes with `-std=c11 -Wall -Wextra -Werror
  -pedantic`, but `generic/lambda/capture_managed`, whose empty struct
  main's C has too and which the e2e does not run (`surface.brp`). Both
  libcs declare `flockfile` under the prelude.
- **No new compiler output.** GCC prints its column-tracking note for the
  same 228 of those compiles with main's C and with this landing's, and
  Clang its errors for the same 2.
- **Rough edge.** In the x86-64 image, which runs emulated on this host, a
  `poll` in the probes' handshake returned EINTR with no handler installed,
  and the four cases that start a run on a second thread failed at once.
  The probe now retries EINTR, as it should anyway.
- **The gate,** `make -C blorp test INSTRUCTION_CHECK=on`, at `90e7a7528`
  and again at `3eb2d36a3`, after the review's fixups: 3,582 cases passed
  and one failed, an e2e allocation ceiling, since raised. Every instruction ceiling
  held.
  `variants_alias_destructure` (`surface.brp`), whose ceiling main's
  previous commit set at exactly its count, compiles with 59,776
  allocations against 59,775.
  - **Measured, matched:** both diagnostic compilers at equal-length
    absolute paths, an empty environment, and a fresh output file, as the
    harness has. A printing program's compile makes one more allocation:
    59,775 to 59,776 for this fixture, 63,308 to 63,309 for
    `variants/erased_equality` and 64,203 to 64,204 for
    `argument_input/basic`. `arithmetic/nesting`, which neither prints nor
    has the prelude, and `process/natives_run`, which had it already, do
    not change.
  - **Why:** a printing program's compile now reads the
    `PROCESS_POSIX_PRELUDE` literal, whose site makes its String once. With
    `BLORP_ALLOCATION_SITES` on this fixture, base against candidate, the
    one allocation row that differs is `emit.emit <- blorp_string_literal`:
    11 allocations and 29,818 bytes, then 12 and 30,241, the extra one the
    423-byte prelude String. The fragment list is two allocations either
    way, and its growth is a resize, which is not counted.
  - **Raised to 59,776,** which Keith approved on 2026-11-26, as the
    repository's remedy for a measured change.
  - **Reproducing a count by hand** needs the harness's conditions: the
    count changes with the output path's length, and with whether the
    output file already exists.

**Fixture C,** every e2e fixture compiled by main's compiler and by this
one, at `90e7a7528` and again at `3eb2d36a3`, after the review's fixups,
with the same result. Status, stdout and stderr are identical for all 782. Each differing hunk was
required to be one contiguous run of an old fragment's lines and of a new
one's, and none was not; a stray line injected into a copy of one file is
reported. The classes:

| Class | Fixtures |
| --- | ---: |
| Identical C | 311 |
| Rejected, no C | 136 |
| The prelude only (its `#error` text) | 6 |
| The prelude and the print bodies | 321 |
| The prelude, the print bodies and the process fragments | 8 |

281 of these gained the prelude, because they print; 54 had it already. None
lost it.

**Cost,** `self-compile-cost 34008c1cf HEAD --rounds 3`, fixed-input row:

| Measure | Base `34008c1cf` | Candidate `90e7a7528` | Change | Ceiling |
| --- | ---: | ---: | ---: | ---: |
| Allocations | 13,507,896 | 13,507,896 | +0.0000% | +0.05% |
| Peak heap, bytes | 192,302,220 | 190,860,498 | −0.7497% | +0.1% |
| Instructions, median of 3 | 13,748,313,887 | 13,734,764,878 | −0.0986% | +0.1% |

The own-source row: allocations +0.0033%, peak heap −0.7110%, instructions
−0.0759%. The fixed-input C differs from the base's in 11 lines, the
prelude's `#error` and the print bodies, 70 bytes in all.

**Why peak heap fell 0.75%.** `join` copies its first fragment, the prelude,
then doubles that buffer until the whole file fits, 2^17 times here. The new
`#error` line is 11 bytes shorter, so the prelude is 350 bytes, not 361, and
the final buffer is 45,875,200 bytes, not 47,316,992: 1,441,792 fewer, less
the 70 the file grew, which is the measured 1,441,722.
- **The bisect,** one round each: the process slice alone, and with only
  `emit.brp` added, leave the fixed-input C and its peak identical; with
  only `string.brp` added, the print bodies, the peak moves by +81 bytes.
- **What it says about the metric:** every byte of the first fragment moves
  this peak by 131,072 bytes. A `join` that reserved the total first would
  remove that, as a change of its own.

The script runs the seed's runtime, so it does not see the print change. The
compiler prints only diagnostics, so that is acceptable. What it does see is
the compiler's own output, which had the prelude already, since the compiler
reads files.

**Lines,** against ceilings of +220 and +550:
- production: +160 and −62, so +98 net, all in `process.brp` (+87),
  `emit.brp` (+4) and `string.brp` (+7);
- test: +552 and −24, so +528 net, most of it the probes: `process_child.c`
  +361 and `console_test.c` +109.

**The audit: state an impure native touches.** Landing 1 covered what a pure
task can reach.

| State | Natives | Verdict |
| --- | --- | --- |
| Pipe ends between `pipe()` and `FD_CLOEXEC` | `capture`, `run` | made safe: the fork lock's read side |
| `fork` | `capture`, `run` | made safe: the write side, and a child that runs only async-signal-safe code until exec |
| Other descriptors | fs opens, `/dev/null`, `blorp_process_private`, `fdopendir`'s copy | safe: close-on-exec atomically |
| SIGINT and SIGQUIT dispositions | `run`, `capture`'s child, `exit_interrupted` | made safe: the counted swap under the write side |
| SIGCHLD's disposition | `capture`, `run` | safe: only read |
| SIGPIPE and the signal mask | `capture`, console writes and flushes | safe: blocked in the calling thread only, and a write's SIGPIPE goes to the thread that wrote |
| The forking thread's signal mask | `capture`, `run`, `exit_interrupted` | left to 4c and landing 5: a child inherits the mask of the thread that forks it, and `exit_interrupted`'s `raise` reaches only its own thread. Safe while natives run on the main thread; once they run on helpers, either the helpers keep the main thread's mask, or the child's mask is set explicitly, as glibc's `system` does with `posix_spawnattr_setsigmask` |
| The children, and `blorp_process_reap`'s reservation | `capture`, `run` | safe: each native waits only for its own child by PID, and `capture` keeps its child unreaped until its group is killed; no Blorp code waits for any child. `run` reaping through the reservation, so a canceller can kill its child, is landing 5 |
| Process groups and the terminal's foreground group | `capture`, `run` | safe: `capture`'s child makes its own group, and `run` changes neither. Two runs at once share the terminal, a question for landing 5's API |
| stdout and stderr | `print`, `print_error`, console writes and flushes, `run`'s and `exit_interrupted`'s flushes | made safe: whole lines. Output from two threads is ordered by who takes the stream first, and `run`'s "the caller's output first" holds for the calling thread's own output |
| stdin's buffer, and `ferror` and `clearerr` on it | `read_line`, `read_exact` | left to 4d: two readers interleave characters, and one's `clearerr` can hide the other's error |
| The console's exit handler | console helpers, `run`, `exit_interrupted` | safe: registered once through `pthread_once`. It closes stdout at exit, so landing 5 must have every helper idle by then, as landing 2 did for pool workers |
| The current directory | `current_directory`; `capture`'s and `run`'s `directory` | safe: only read in the parent; the `chdir` is the child's |
| The environment | `capture` and `run` read `environ`; `find_program` reads `PATH` | safe: only read. No native writes it, so a later one that sets a variable needs a lock around every reader |
| `errno` | every native | safe: thread-local |
| The temporary-name counter | `write_text`, `write_bytes` | safe: `_Atomic` |
| `realpath`, `mkdtemp`, `readdir` | fs | safe: reentrant on glibc and macOS; each `readdir` reads its own stream |
| Open files and writers | `open_read`, `next_lines`, `read_chunk`, `close`, the writer natives | safe: each handle is one owner's loan, and the natives keep no state between calls (D37) |
| Reads of a FIFO, `/dev/stdin` or a terminal | fs reads | left to 4e: unbounded, so a helper may wait without bound |
| The allocation-sites file | `blorp_memory_start`, in diagnostics builds | unchanged: opened at the start, without close-on-exec, so every child inherits it, as before |
| A cancelled native's child | `capture`, `run` | left to 4c and landing 5 |

**Not covered:**
- helper threads themselves, which landing 4c brings; these cases use
  pthreads directly;
- a fork that does not take the lock, as foreign code's would; the exec
  report still defends `capture` and `run` against it, as the
  `capture-stray-report` case shows;
- a measured fork wait under many concurrent readers, beyond the window
  case.

### Landing 4b results

**What landed:** `FIBER_RUNTIME`, in `src/common/codegen/runtime/fiber.brp`,
proven by a direct-C suite, `test_runtime/fiber_suite.brp` with
`fixtures/fiber_test.c`. Nothing emits it yet; landing 5 is its first user.
- **The shared stack rule.** The pool's stack size, guard and pause moved
  from `JOIN_RUNTIME` to a new `THREAD_RUNTIME`, which emit places before
  it, renamed from `blorp_join_` to `blorp_thread_`. Fibers follow it.
- **The interface:**
  - `struct blorp_fiber_context`, what a switch saves and resumes, a fiber's
    or a thread's own, and `struct blorp_fiber`, a context with its stack and
    entry;
  - `blorp_fiber_create(entry, argument)`, `blorp_fiber_switch(from, to)`,
    `blorp_fiber_destroy(fiber)` and `blorp_fiber_thread_context()`;
  - `struct blorp_kernel_lock`, `BLORP_KERNEL_LOCK_INITIALIZER`,
    `blorp_kernel_lock` and `blorp_kernel_unlock`.

**Differences from the brief:**
- **A thread's context and a fiber are two types.** The switch takes
  contexts and destroy takes a fiber, so destroying a thread's own context
  does not compile.
- **Create never returns NULL.** A stack that cannot be mapped stops the
  program with its cause, as the pool's thread start does, so no caller can
  forget a check: "error: cannot start a fiber: mmap failed: Cannot allocate
  memory".
- **The record lives at the top of its stack's mapping,** as Boost.Context
  places its control structure. So a fiber allocates nothing beyond its
  mapping, and the strict leak check sees nothing.
- **arm64 saves FPCR too.** The brief's register list leaves it out, but its
  test asks that fibers keep their own rounding modes. AAPCS64 leaves FPCR to
  the program as global state, and glibc's aarch64 `swapcontext` saves it.
  A fiber starts with its creator's control state, as C11 starts a thread.
- **The switch refuses what a kernel must never do,** with "fiber runtime
  invariant broken": leaving a context that is not running or that runs on
  another thread, resuming one that is neither new nor suspended, destroying
  one that is neither new nor finished, and resuming a fiber on a thread
  other than the one it first ran on. The last two turn the thread-local
  comment at the switch into a checked rule.
- **A destroyed fiber is `BLORP_FIBER_CACHED`,** set under the cache's lock
  before the stack can be taken, so a second destroy, or a switch to it,
  meets the refusals above. Without it a double destroy cached one stack
  twice and two creates then shared it; the review's probe showed it.
- **The lock spins, yields, then blocks,** in the three phases of Go's
  runtime locks, on a word of its own rather than a pthread mutex taken by
  trylock. The lock measurement below gives the reasons.
- **Fresh stacks are advised `MADV_NOHUGEPAGE` on Linux,** so that a
  stack's size costs address space and not memory where transparent huge
  pages are `always`. The fiber limits below give the measurement.
- **ASan.** A stack is poisoned when it is cached and unpoisoned when it is
  handed out again.
  - **A fresh mapping is not unpoisoned.** `__asan_unpoison_memory_region`
    clears shadow with `memset`, which made an eighth of each 8 MiB stack
    resident: 9.7 GB at 10,000 fibers, until the OOM killer ended the run on
    arm64 Linux. Without it, that case peaks at 87 MiB with Clang and 110
    MiB with GCC.
  - **Before a stack is unmapped,** only the frames live at its fiber's last
    switch are cleaned, from its saved stack pointer to the top. Every
    deeper frame returned, and so unpoisoned itself.

**The switch.**
- **The registers.** arm64 saves x19 to x29, x30, d8 to d15 and FPCR in a
  176-byte frame, and never touches x18. x86-64 saves rbx, rbp, r12 to r15,
  MXCSR and the x87 control word. Any other target is an `#error`.
- **A first entry** returns into `blorp_fiber_enter`, which puts the fiber
  in the first argument register, clears the return address, and jumps to
  `blorp_fiber_start` through x16 on arm64 and r12 on x86-64. The frame
  pointer is null too, so `backtrace()` stops at the entry.
- **When an entry returns,** its fiber switches to the context that last
  resumed it, and is finished.
- **Landing pads:** `bti c` under `__ARM_FEATURE_BTI_DEFAULT`, and `endbr64`
  under `__CET__`'s IBT bit. The entry stub is reached by `ret`, which
  neither checks.
- **Pointer authentication:** x30 is saved and restored as it is, and each
  frame authenticates with its own stack pointer, which never moves.

**BTI and PAC on arm64 Linux.** The Docker VM's CPU, on an M4, has both.
Neither of the image's compilers turns branch protection on by default.
- **A forced BTI link cannot start.** Ubuntu's `crt1.o` and libc are not
  BTI-marked, so a `-z force-bti` program dies with SIGILL before `main`.
- **So a probe maps its own text with `PROT_BTI` once it runs.** It is
  `build/concurrency/landing4b-evidence/tools/bti.c`, in the main checkout's
  ignored evidence directory, with the landing's other scripts. Built with
  `-mbranch-protection=standard` and bound at startup (`-z now`, since the
  unmarked link's lazy-binding PLT stub has no landing pad), a first entry
  and an indirect call to the switch both pass, with Clang and with GCC. Without `bti c` in the switch,
  the indirect call dies with SIGILL. With the entry stub branching through
  x15, which `bti c` does not accept, the first entry dies with SIGILL.
- **The whole probe passes with `-mbranch-protection=standard`,** so with
  every C frame signing its return address.

**Shadow stacks.**
- **CI runs with them off.** CI's "Linux x64 GCC" job compiles with Ubuntu's
  GCC 13.3, whose `-fcf-protection` default sets `__CET__` to 3, and every
  library in the image is marked for IBT and SHSTK.
  - **glibc 2.39 never marks SHSTK usable by default:**
    `sysdeps/x86/cpu-features.c` has `#if CET_ENABLED && 0` around it, so
    `dl_cet_check_startup` clears it.
  - **They come on only with a tunable,** and then only on a CPU and kernel
    (6.6 or later) that support them. `glibc.cpu.hwcaps=SHSTK` alone
    enables them only in a binary marked for them, which Clang's builds are
    not; `glibc.cpu.hwcaps=SHSTK:glibc.cpu.x86_shstk=on` always enables them
    (glibc's `manual_tunables.texi`).
  - **The Seed jobs compile with Clang,** which does not set `__CET__`.
- **So the runtime detects them and stops.** This is the brief's
  recommended choice.
  - **The first fiber reads `rdsspq`,** a no-op that leaves 0 when shadow
    stacks are off. When they are on, it stops with "error: cannot start a
    fiber: this process runs with shadow stacks, which Blorp fibers do not
    support yet".
  - **arm64 Linux's guarded control stack** is the same hazard, so it is
    read with `chkfeat` (`hint #40`).
- **The test.** The suite runs its `registers` case with both tunables set,
  which must either pass or stop with that message and its hint. If the
  runtime missed shadow stacks, the first `ret` of a switch would fault,
  which the case rejects. Emulated x86-64 has no CET, so only the first ran
  here; CI's native run is the one that can reach the second.
- **Switching shadow stacks,** as glibc's `swapcontext` does, waits for a
  platform that turns them on by default.

**Fiber limits.** Each fiber touches one page and parks. Stacks are the main
thread's 8 MiB, which is 8,176 KiB on macOS, plus the 64 KiB guard.

| | macOS, arm64 (16 KiB pages) | Linux, arm64 (4 KiB pages) |
| --- | --- | --- |
| Mappings per live fiber | 2.0 | 2.0 |
| Resident per parked fiber | 16.4 KB | 4.1 to 4.3 KB |
| Page tables per parked fiber | not reported | 4.1 KB |
| 10,000 parked | 165 MB resident; parked in 45 ms | 42 MB resident and 41 MB of page tables; parked in 34 ms |
| 100,000 parked | 1.64 GB resident and 806 GB reserved, granted; parked in 0.67 s | 412 MB resident and 413 MB of page tables, 806 GB reserved, granted; parked in 0.33 s |
| Where it stops | not on mappings or address space at 100,000 | at half of `vm.max_map_count`: about 131,000 live fibers at this VM's 262,144, where `mprotect` fails with ENOMEM and the program stops with "error: cannot start a fiber: mprotect failed: Cannot allocate memory"; about 32,700 at the default 65,530 |

- **Spike K measured 16.6 KB and 4.3 KB per parked fiber** with 256 KiB
  stacks, so the larger stacks cost address space, not resident pages.
- **On Linux they cost page tables,** 4.1 KB per parked fiber, as much as
  its page. Each fiber's touched page is in its own 2 MiB region, so it
  needs a page-table page of its own; Spike K's 256 KiB stacks shared one
  among 8.
- **Transparent huge pages.** The VM's are `always`, as on RHEL; Ubuntu's
  are `madvise`. A first touch then commits a whole 2 MiB page wherever the
  2 MiB block is inside the mapping. A mapping of 8 MiB and 64 KiB shifts
  the next by 64 KiB against that grid, so one fiber in 32 got one for its
  top page: 656 MB of the 696 MB resident at 10,000 parked fibers. So each
  fresh mapping is advised `MADV_NOHUGEPAGE` before its guard is set, which
  took that to 42 MB with the same two mappings per fiber; JDK 21 has a
  mitigation for thread stacks for the same reason.

**The cache keeps its stacks' touched pages.** Its bound,
`BLORP_FIBER_CACHED_STACKS`, is 64.

| | macOS | Linux, arm64 |
| --- | ---: | ---: |
| A cycle of create, switch, finish and destroy, from the cache | 92 to 102 ns | 42 to 64 ns |
| The same, when each fiber touched 64 KiB | 868 to 935 ns | 417 to 570 ns |
| A cycle that releases the cached stack's pages | 6,039 to 6,159 ns | 332 to 598 ns |
| Releasing, when each fiber touched 64 KiB | 14,328 to 15,820 ns | 15,969 to 18,707 ns |
| A cycle with no cache: mmap, mprotect, first touch, munmap | 13,929 to 14,999 ns | 4,002 to 5,691 ns |
| The cache, after 128 fibers that touched 1 MiB each | 72.7 MB resident | 70.8 MB resident |
| 10,000 shallow fibers parked after them | 236 MB resident, 277 MB footprint | 112 MB resident |
| The same, releasing cached pages | 236 MB resident, 206 MB footprint | 42 MB resident |

- **Releasing costs 6 to 60 times a cached cycle,** and on macOS most of
  what the cache saves, while the memory it frees is bounded already: at
  most the bound's 64 stacks, each holding what its fiber touched. That is
  a page or two for a fiber that waits on natives, and 512 MiB in the worst
  case, 64 stacks touched to their full 8 MiB.
- **glibc releases a dead thread's stack before caching it**
  (`advise_stack_range`), but a thread costs far more than a fiber.
- **macOS's `MADV_FREE_REUSABLE`** lowers the footprint, but leaves the
  pages resident until memory is short.

**The kernel lock.** It spins 64 rounds reading the word with a pause, then
yields 16 times, then sleeps on a mutex and condition variable.
- **Against Spike K's spin-then-yield lock,** on Spike K's C baseline cases,
  medians of 5 interleaved runs:

| Case | macOS, 4 carriers | Linux arm64, 4 carriers | Linux arm64, 8 carriers on 4 CPUs |
| --- | ---: | ---: | ---: |
| ping-pong | 1.11 | 1.01 | 1.05 |
| half-full | 1.09 | 1.09 | 1.20 |
| pipeline | 1.51 | 1.05 | 0.92 |
| tasks | 0.97 | 1.04 | 1.03 |
| task-batches | 1.02 | 0.87 | 1.13 |

- **Why a word of its own.** A pthread mutex taken by trylock while spinning
  cost 1.63 times Spike K's lock on the uncontended `half-full` on macOS:
  `pthread_mutex_trylock` and `unlock` are calls with checks of their own.
  The word, read before it is tried, cost 1.08.
- **Why it yields before sleeping.** On macOS's `pipeline`, 2,000,000
  messages on 4 carriers, with 64 spins:
  - **with 1 yield,** it slept about 21,000 times, and every unlock after a
    sleep signals, about 186,000 times; 200 to 234 ms;
  - **with 4,** about 5,000 sleeps; 146 to 170 ms;
  - **with 16,** 6 to 8 sleeps; 93 to 120 ms, against Spike K's 61 to 72 ms
    in that run.
- **Why the word is last.** The structure is 116 bytes on macOS and 96 on
  Linux, against Spike K's 4. With the word last, taking the lock and
  touching what it guards share a cache line when a lock heads a structure.
  Moving it from first to last took macOS's `pipeline` from 397 to 649 ms
  down to 253 to 429 ms, before the yields were added.
- **What remains is the lock's size.** macOS's `pipeline` is the one case
  over 1.5. Spike K's own algorithm, padded to the same size with its word
  last, ran it at 1.69, so the rest is the size, not the algorithm. In a
  kernel cell, the lock sits beside a pointer to the Blorp value, so the
  size should matter less there. A smaller lock would need a table of
  sleepers keyed by address, as Go's semaphore table and WebKit's ParkingLot
  have.
- **`pipeline` is layout-sensitive on macOS.** Two builds of Spike K's
  identical code ran it at 40 ms and 190 ms. So it was measured against
  Spike K's algorithm at the same size, as above.
- **It does not burn cores.** Eight threads on 4 CPUs (`taskset`), one
  holding the lock asleep for 20 ms at a time: Spike K's lock used 4.00 CPUs
  while waiting, this one 0.00. The harness is
  `build/concurrency/landing4b-evidence/tools/lock_bench.c`.
  - **Sleeping costs throughput behind a sleeping holder:** with that 20 ms
    holder this lock made 43 acquisitions a second against Spike K's 53,
    about 19% fewer (`lock/burn-linux-arm64-8-on-4.txt`): a waiter that
    sleeps must be woken after the unlock.
  - **Under full contention,** with no holder, this one did 2 to 5% fewer
    acquisitions than Spike K's, on about 3 CPUs instead of 4.

**Tests,** in the new suite. Each "bite" was a single change to the fragment,
run against every case: it failed the case named, and only that one, on
macOS, and in both Linux images where it applies.

| Case | What it checks | Fails without |
| --- | --- | --- |
| registers | three contexts each set every callee-saved register and its own rounding mode, switch through each other, and find them all unchanged | restoring x25, d12 or FPCR (arm64), or r13, MXCSR or the x87 control word (x86-64) |
| depth | 1,000 frames of 4 KiB on a fiber | |
| deep drop | a million-node chain released on a fiber through the release scheduler; the strict leak check balances | |
| overflow | a fiber recursing without end faults inside its guard, which the fault handler checks | the guard: the overflow writes below the stack, so the fault is outside the guard, or, on x86-64 under ASan, ASan reports the write into the mapping below as a stack-buffer-overflow |
| scale | 10,000 fibers created, switched through and destroyed, allocating nothing | |
| cache | a destroyed fiber's stack is reused without a mapping, and the cache unmaps beyond its bound | the bound: stacks past it stay mapped; the cache |
| backtrace | `backtrace()` on a fiber ends two frames after its caller's caller, at `blorp_fiber_start` | the entry's null return address |
| lock totals | 4 and 8 threads incrementing under the lock | the lock |
| lock sleeps | a waiter behind a holder asleep for 300 ms uses under a quarter of that in CPU time | the sleep: it spins and yields without end |
| shadow stacks | `registers` under the shadow-stack tunables passes, or stops with the runtime's message | |
| refusals | mmap and mprotect failures stop with their causes; destroying a suspended fiber, from a fiber, destroying one twice, switching to a destroyed or finished one, switching away from another thread's context, and resuming one on another thread stop with their rules | the ASan hooks (the abort on a fiber makes ASan warn that it ignores `__asan_handle_no_return`; this is the destroy-suspended case's abort); the thread checks; the cached state (a double destroy and a switch to a destroyed fiber both pass without it, and cache-never fails them too) |

- **Two probes run every case that can:** `-O0` with ASan and UBSan, and
  `-O2` as a program is built. Frames whose size a case relies on keep it by
  escaping to an empty `asm`, since Clang splits a 4 KiB volatile array it
  can see whole into its two used bytes.
- **Fake stacks.** Each ASan case runs with `detect_stack_use_after_return`
  set, so every switch saves and restores them; Linux turns them on by
  default and macOS does not. The deep drop runs without them, since they
  would move its frames off the fiber's stack, and GCC's took 42 to 56 s on
  it, on the main thread as on a fiber.
- **ThreadSanitizer,** by hand on arm64 Linux: the register, depth, cache,
  backtrace and both lock cases, at `-O1` and `-O2`, 3 times each with Clang
  and GCC, with no report.

**Evidence:**
- **Platforms.** Every case passed on macOS with Apple Clang 21, on arm64
  Linux with Clang 18.1 and GCC 13.3, and on emulated x86-64 Linux with GCC
  13.3, CET on, and Clang 18.1. No x86-64 case ran natively here; CI's Linux
  x64 jobs are the native run.
- **Which fragment.** The cases, TSan and the BTI runs used the final
  fragment. The bites used the one before the huge-page advice, which adds
  one `madvise` to the mapping path and changes no code a bite breaks.
- **Fixture C,** every e2e fixture compiled by main's compiler and by this
  one: status, stdout and stderr are identical for all 784. 632 emit
  identical C and 136 are rejected. The other 16, the programs with the
  pool, differ exactly by the old `JOIN_RUNTIME` text being replaced by the
  new `THREAD_RUNTIME` and `JOIN_RUNTIME`, byte for byte; a stray change
  planted in one is reported.
- **The gate,** on the rebased head (`make -C blorp test
  INSTRUCTION_CHECK=on`, with the pool and fiber suites in it): exit 0, 3,658
  passed and none failed. `git diff --check` is clean. The fiber probe,
  built as the suite builds it, also passed on arm64 Linux, with Clang 18.1
  and GCC 13.3: 27 runs each. The new bites, `no-cached-state` and
  `wrong-context`, fail only their own cases on macOS, and the register,
  guard and ASan-hook bites still fail theirs.

**Cost,** `self-compile-cost 94b463fda 6544584d3 --rounds 3`, fixed-input
row:

| Measure | Base `94b463fda` | Candidate `6544584d3` | Change |
| --- | ---: | ---: | ---: |
| Allocations | 13,693,537 | 13,693,537 | +0.0000% |
| Peak heap, bytes | 192,204,970 | 192,204,970 | +0.0000% |
| Instructions, median of 3 | 13,945,447,181 | 13,939,642,242 | −0.0416% |

The fixed-input C is identical. The own-source row: allocations +0.0047%,
peak heap −0.0054%, instructions +0.0421%, as the compiler's source grew.
The final commit, `282a5d207`, differs from the measured one only in
`fiber.brp`, which no compiler module imports, and the compiler's C it
builds is byte for byte the same.

**Lines,** against ceilings of +500 and +600, from `origin/main` after the
rebase:
- **production:** +451 and −29, so +422 net: `fiber.brp` +403; `thread.brp` +39; `join.brp` +5 and −28;
  `emit.brp` +4 and −1;
- **test:** +865, within the corrected ceiling below. `fiber_test.c` is 506
  lines and `fiber_suite.brp` 353; the driver
  and the pool suite take 6. The review's fixes cut the fixture's own
  shadow-stack detector (27 lines) and added three refusal cases (double
  destroy, a switch to a destroyed fiber, a switch from another thread's
  context: 36 fixture lines and 20 suite lines), so they net +26 from the
  +839 the review measured.
  - **Beyond the brief's list,** about 165 lines: the lock-sleeps case, the
    mapping failures, and the invariant refusals. One refusal, destroying a
    suspended fiber from a fiber, is also the case that the ASan-hook bite
    fails.

**The test ceiling, corrected by the coordinator on 2026-11-27:**

| Ceiling | Old | New |
| --- | ---: | ---: |
| Test lines | +600 | +815, then +870 |

- **The first correction** follows the review's growth audit. The estimate
  left out about 105 lines of fixture infrastructure, and about 165 lines
  are necessary cases beyond the brief: the mapping failures, the invariant
  refusals and lock-sleeps. 27 duplicate lines were cut.
- **The second** pays for the three refusal cases the review asked for
  (about 56 lines).

**Not covered:**
- native x86-64 hardware, and with it CET's IBT and shadow stacks;
- switching shadow stacks;
- a fiber that migrates between carriers, which landing 7 would need with
  thread-local accessors;
- a carrier that exits while its fibers live: each fiber records its
  carrier's context, a thread-local, so landing 5's carriers must outlive
  their fibers;
- parking, permits and the blocking pool, which are 4c's;
- a measured kernel workload in Blorp with this lock, since Spike K's
  Blorp kernel was not rebuilt; the comparison used its C baseline.

**Follow-ups for landing 5:**
- **A program stops at about 32,700 live fibers** at Linux's default
  `vm.max_map_count` (65,530, two mappings per fiber), with "mprotect failed:
  Cannot allocate memory", which does not name the real cause. Landing 5
  should say that the map count is the limit.
- **`THREAD_RUNTIME` is emitted only under the pool requirement,** with no
  include guard, so landing 5 must emit it once for the pool and the fibers.
- **TSan has no repeatable gate.** Its runs here were by hand.
- **The `PTHREAD_STACK_MIN` floor** is in `fiber.brp`, a second stack rule
  beside `THREAD_RUNTIME`'s. Moving it into the shared rule changes the
  pool's C, so it stays out of 4b.

### Landing 4c results

**What landed:** the parts of the runtime that wait, proven by direct-C
suites. Nothing emits them yet; landing 5 is their first user.
- **Parking, in `FIBER_RUNTIME`:** `blorp_fiber_run(fiber)` runs a fiber
  from its carrier's own context and returns how it stopped, `enum
  blorp_fiber_stop`: parked, yielded or finished. `blorp_fiber_park(self)`
  consumes a permit and yields, or switches back to the carrier, which
  publishes the park only after the switch saved the fiber, as Go's
  `gopark` releases its lock after `mcall`. A fiber that switches back
  without parking keeps any permit its wait's winner left, as Spike K's
  yield did.
- **The wait word and its fused claim, also there:**
  - `blorp_wait_arm(self)` arms the fiber's next wait and returns its
    generation;
  - `blorp_wait_end(fiber, generation, outcome)` is the claim and the wake
    in one call. It returns `enum blorp_wait_claim`: lost, woken (the fiber
    was not parked, and its park consumes the permit) or queue (the fiber
    is parked until the caller queues it). A party that lost has no wake to
    give, so no permit is ever stale (Spike K's change 3);
  - `blorp_wait_outcome(self, generation)` reads the winner's outcome, and
    stops the program with "a fiber woke before its wait was claimed".
- **The idle wait, also there:** `struct blorp_idle`, with
  `blorp_idle_init`, `_epoch`, `_wait` and `_notify`. It is Spike K's
  eventcount, which carriers and helpers share. `BLORP_IDLE_SPINS`, 20,000
  rounds of the thread pause, is Spike K's spin count.
- **The blocking pool, a new `BLOCKING_RUNTIME`** in `runtime/blocking.brp`,
  after `FIBER_RUNTIME` and `PROCESS_HELPERS_RUNTIME`:
  - `struct blorp_blocking_job`, with its three kinds, `enum
    blorp_job_kind`: bounded, unbounded and cancellable;
  - `blorp_blocking_start`, `blorp_blocking_submit` and
    `blorp_blocking_cancel`, which returns `enum blorp_blocking_cancel`:
    withdrawn, signalled or not reached;
  - `blorp_kernel_queue`, declared for the kernel to supply. The suites
    supply it.
- **One pure move:** `blorp_process_pipe` moved from `PROCESS_LAUNCH_RUNTIME`
  into `PROCESS_HELPERS_RUNTIME`, so the cancel pipes reuse it. Its text is
  unchanged but for `static`, since that fragment's functions are external.

**Change 6, as 4c realizes it.** Spike K's change 6 had a waiter that ends
without its native's result remove its own job. Here a cancel never claims a
native's wait. It goes through the job, under the pool's lock:
- **No helper has taken the job:** it is withdrawn and never runs, and the
  canceller ends the wait with its own result.
- **It runs, and is cancellable:** the cancel writes one byte to its
  helper's cancel pipe, and the job ends the wait as usual.
- **Otherwise** it runs to its end.

So only a job, or the canceller that withdrew it, ends a native's wait. A
waiter never moves on while a helper can touch it, and needs no wait for
its job's release. The completion checks the rule: a job whose wait another
party ended stops the program with "a blocking job's wait was ended by
another party". No native was found whose wait needs another party.
- **One order differs from the brief.** The brief has the completion end the
  wait and then mark the job finished. A waiter woken by that end may free
  the job before the mark. So the job is retired first and its wait ended
  second, both under the lock, and a cancel that finds it retired still
  knows the wait has ended. The bite that restores the brief's order passes
  under ASan, since the window is nanoseconds against a resume that takes
  microseconds; TSan reports it (below).
- **Landing 5's obligations.** A cancel reads the job, so the canceller must
  keep it alive: the waiter frees it only after its wait ends, and leaves
  its wait under a lock the canceller holds while it cancels. The suites'
  cancellers do so with a `leave` lock. And a job is published to
  cancellers only once it is submitted: a cancel of a zeroed job stops the
  program with "a job was cancelled before it was submitted".

**Other differences from the brief:**
- **The park word has four states:** none, permit, parking and parked.
  Parking is a fiber that chose to park and switched away, so the carrier
  reads the fiber's choice from the word itself, where Spike K kept it on
  the carrier.
- **The pool starts explicitly.** `blorp_blocking_start` records the signal
  mask every helper sets. A submit before it stops the program, since the
  helpers' mask would otherwise be an unset `sigset_t`.
- **A cancel pipe is made by the submit that starts its helper,** under the
  fork lock's read side, so the submit that would exceed the descriptor
  limit stops at once with one message. Made on each new helper, several
  helpers starting together each printed the failure before the abort.
- **A job that cannot be cancelled gets -1 for its cancel descriptor,** which
  `poll` ignores, so its kind is visible to the native.
- **The cancel pipe's read end does not block,** so a drain that finds no
  byte, because the job read it against the contract, stops the program
  with "a cancelled job read its cancel descriptor, which only its helper
  drains". A blocking drain would hang the helper silently, and strand the
  job already handed to it (the review's probe). The drain runs before the
  waiter is queued, so a failed one stops the program before the waiter
  goes on.
- **A job state for a job never submitted,** `BLORP_JOB_UNSUBMITTED`, is the
  zero, so a zeroed job no longer reads as queued.
- **The wait's phases are `BLORP_WAIT_PHASE_*`,** with the mask derived from
  the bit count, so no phase reads like a claim's result.
- **The idle wait counts its sleepers,** where Spike K had a flag, so more
  than one thread may wait on one. The Dekker pair is unchanged: a waiter
  counts itself, then reads the epoch; a notify moves the epoch, then reads
  the count, all four sequentially consistent.
- **No party touches a fiber record after destroy,** design change 2,
  which landing 5's scope owns. A cached record keeps its wait word when it
  is reused, so a party that breaks the rule there holds a generation that
  loses. That is all it gives: a full cache unmaps a record, a new mapping
  can come back at the same address with its word at 0, and the review's
  probe showed a stale claim for generation 1 winning there. So there is no
  generation floor, and the rule is landing 5's.
- **A fiber parks exactly once for each wait it arms,** and the wait word
  says whether a park is owed, so no second field can disagree with it. Its
  winner moves the word to ended, the fiber's park moves it on to resting,
  which is also a new fiber's phase, and only a resting word can be armed.
  That takes no fourth phase. The rule is enforced at the arm, the park and
  the destroy: the arm refuses a word that is not resting, the park refuses
  one that is, since no wait is armed for it, and the destroy refuses a
  fiber that finished with a wait armed or a park owed, whose winner could
  still touch the record after it goes to another fiber. The park's entry
  check is one relaxed load of the line it touches anyway.
  The phases, the bit count and the mask are one enum, so the assertion
  that the phases fit compares constants of one type, as GCC's
  `-Wenum-compare` requires. After the end only the fiber writes the word,
  since every other party's compare-and-swap expects armed and, failing,
  writes nothing; the park's step is a relaxed load and store. The rule
  matters across threads: a fiber that armed again without parking never
  synchronized with the last winner's permit, which could then land during
  the next wait and queue a fiber parked on it, or leave its outcome
  unordered (the second review's probe).
- **Refusals beyond the brief's:** arming a wait before parking for the
  last, whether that one is still armed or has ended, which replaces the
  first round's armed-twice check;
  parking a fiber that another fiber resumed, which nobody would publish;
  a submit before the pool starts; a completion whose wait another party
  ended; a helper whose cancel pipe cannot be made; a cancel of a job never
  submitted; a cancelled job that read its cancel descriptor; a park with no
  wait armed; and destroying a fiber that finished with a wait armed or a
  park owed.

**The cap is 16 bounded jobs at once,** `BLORP_BLOCKING_BOUNDED_CAP`.
Nothing measures it yet. libuv's 4 is a known bottleneck for programs heavy
in files, and Tokio allows 512, so it is conservative: four times libuv's,
and 16 helpers' cancel pipes are 32 descriptors, an eighth of macOS's
default limit. Unbounded and cancellable jobs never count against it.

**Descriptors on a default macOS.** `launchctl limit maxfiles` gives a soft
limit of 256. With stdin, stdout and stderr open, 253 remain, so 126
helpers, two descriptors each. Measured: 200 fibers each submitting a job
that blocks until all have started ran 126 helpers, and the 127th submit
stopped the program with "error: cannot start a blocking helper: pipe
failed: Too many open files" (`limits/`). Each running `capture` holds up
to 8 descriptors more. So a program that waits on more than about 120
unbounded natives at once needs a higher limit, which landing 5 can raise
to the hard limit at start, as Go has done since 1.19.

**The helpers' mask.** `blorp_blocking_start` records the calling thread's
mask, and each helper sets exactly that mask when it starts, so it never
keeps one its creator had blocked for a moment, as the SIGPIPE guard does.
Its creator blocks every signal around `pthread_create` and then restores
its own mask, as Go starts its threads, so the helper never runs with its
creator's mask, even before its first line. The `starts` case checks that
the creator then has exactly its own mask back, compared with the mask it
read before the submit, since a probe inherits its parent's.
Landing 5 calls it from the main thread before any submit; the code says
so. Left to landing 5, when natives move to helpers:
`exit_interrupted`'s `raise`, which reaches only its own thread, and
resetting a child's mask before `exec`.

**The round trip.** A no-op job through a helper and back, one fiber on one
carrier, 200,000 in turn, `-O2`, median of 7 runs on macOS at a load of
about 4.8 (`round-trip/`):

| Idle waits | Round trip | Range |
| --- | ---: | ---: |
| Spinning first, as built | 356 ns | 276 to 428 ns |
| Never spinning (`BLORP_IDLE_SPINS=0`) | 2,340 ns | 2,300 to 2,447 ns |

Spike K's 2.0 µs was its helpers' condition-variable wake, which the second
row matches. With the spin, neither the carrier nor the helper sleeps
between back-to-back jobs. Nothing gates on either figure.

**Tests.** Parking and waits are in the fiber suite; the pool is in a new
`test_runtime/blocking_suite.brp` with `fixtures/blocking_test.c`, run
after the fiber suite. A shared `fixtures/carrier_harness.h` stands in for
landing 5's scheduler: carrier threads with locked run queues, idling on
`blorp_idle`, the `blorp_kernel_queue` the pool calls, and a watchdog that
ends a run with "watchdog: no progress for 5000 ms with N fibers live: a
lost wake". Race cases run 100,000 rounds on 1 and 4 carriers, one fiber
per carrier.

| Case | What it checks | Fails without |
| --- | --- | --- |
| permit | a wake before its park leaves a permit, so the park yields; a wake after the park is published finds it parked, and its waker queues it | the permit |
| yield keeps permit | a fiber whose wait was won while it ran switches back without parking, and its next park still yields | the carrier keeping the permit: the second run parks |
| stale | a wait ends once, and a party holding an earlier generation never ends a later one | the generation in the claim |
| wake race | a thread ends each wait while its fiber parks, both jittered: no wake is lost | the permit: the watchdog |
| claim race | four threads race to end each wait: exactly one wins | the compare-and-swap: two winners |
| idle race | a notify, jittered against a waiter that jitters before it idles, is never lost | either half of the Dekker pair: the watchdog |
| idle sleeps | a thread idle for 300 ms uses under a quarter of it in processor time | the sleep |
| woke unclaimed, armed twice, skipped park, finished owing, parked unarmed, parked by a fiber | each stops with its rule; armed twice and skipped park with "a fiber armed a wait before parking for its last one" | its check; for skipped park, a check that refuses only an armed wait |
| starts | no helper before the first submit; a helper started from a fiber whose carrier blocked SIGINT has the recorded mask, SIGUSR2 alone; its cancel pipe is above stderr with stdin closed | the mask; the private pipe |
| never queued | 33 unbounded and cancellable jobs, each blocked until all have started, all complete, on 33 helpers | counting them against the cap: the watchdog |
| capped | 33 bounded jobs held at a gate: exactly 16 run at once, and a cancel withdraws one queued behind them, which never runs | the cap: 29 at once |
| cancels | a job its new helper has not taken is withdrawn and never runs; a running cancellable one is signalled, once; the next job on that helper finds the pipe drained; a running unbounded one is not reached and has no descriptor; one helper serves them all | the drain |
| withdraw race | cancellable jobs, each freed as soon as its wait ends, raced by a canceller from their submit: exactly one of withdrawn and completed, and the wait ended once; then two descriptors per helper, each close-on-exec | the pool's lock in a cancel: double ends; the private pipe |
| stale cancel | the same, raced from the job's start, around its end: no cancel reaches the next job | the drain; the pool's lock in a cancel |
| before start, thread fails, pipe fails, ended elsewhere, cancel unsubmitted, drain consumed | each stops with its message | its check; for the drain, the read end's `O_NONBLOCK` |

- **Two probes run every case that can,** as in 4b: `-O0` with ASan and
  UBSan, and `-O2`. The sanitized probes build with `BLORP_IDLE_SPINS=0`,
  so every idle wait sleeps and a notify can land between its look and its
  sleep; the optimized ones spin as programs do.
- **Each pool race frees its job as soon as its wait ends,** and its
  canceller holds a `leave` lock while it cancels, which the waiter takes
  before freeing the job, as landing 5's waiter will leave its wait.

**Which paths the races took,** counted by an evidence-only copy of the
fixtures (`paths/`), on macOS:

| Race | Probe, carriers | Wakes before the park | Wakes of a parked fiber | Lost claims |
| --- | --- | ---: | ---: | ---: |
| wake | sanitized, 1 / 4 | 38,741 / 5,509 | 61,259 / 94,491 | |
| wake | optimized, 1 / 4 | 36,571 / 19,371 | 63,429 / 80,629 | |
| claim | sanitized, 1 / 4 | 40,091 / 15,961 | 59,909 / 84,039 | 224,733 / 221,670 |
| claim | optimized, 1 / 4 | 58,266 / 14,636 | 41,734 / 85,364 | 248,330 / 92,907 |

| Race | Probe, carriers | Withdrawn | Signalled | Not reached | Canceller too late |
| --- | --- | ---: | ---: | ---: | ---: |
| withdraw | sanitized, 1 / 4 | 25,869 / 34,503 | 66,800 / 56,408 | 3,094 / 7,734 | 634 / 905 |
| withdraw | optimized, 1 / 4 | 2,508 / 20,236 | 96,139 / 68,665 | 1,046 / 9,168 | 50 / 581 |
| stale cancel | sanitized, 1 / 4 | 0 / 0 | 98,193 / 81,467 | 1,466 / 16,044 | 41 / 1,901 |
| stale cancel | optimized, 1 / 4 | 0 / 0 | 99,648 / 75,510 | 306 / 18,719 | 6 / 1,142 |

**The bites.** Each is one change to a fragment, run against every case of
both suites, on macOS and in the arm64 image with Clang, with the same
outcome on both (`bites/`, `linux/final-bites.log`). A failing race failed
every run of it that is named.

| Bite | Fails | Also fails, through the same path |
| --- | --- | --- |
| No permit: a wake that finds the fiber not yet parked is dropped | permit, at its assertion; the wake race, by the watchdog | the claim race and the pool's cases, whose wakes also meet fibers not yet parked |
| A claim without the compare-and-swap: a load, a test and a store | the claim race: "wait 46 of fiber 0 was ended twice" | nothing |
| A yield that stores none over the park word, the review's blocker | yield keeps permit: its second run parks | nothing |
| A claim that ignores the generation | stale | the claim race, whose late parties hold earlier generations |
| A notify that reads the sleeper count before it moves the epoch | the idle race, sanitized, by the watchdog | the wake and claim races and the pool's cases, whose carriers and helpers idle on it |
| An idle wait that sleeps without rechecking the epoch | the same | the same |
| An idle wait that never sleeps | idle sleeps | nothing |
| Unbounded and cancellable jobs counted against the cap | never queued, by the watchdog | nothing |
| No cap | capped: "29 bounded jobs ran at once, against a cap of 16", or no job left queued to withdraw | nothing |
| A cancel outside the pool's lock | the withdraw race: "a blocking job's wait was ended by another party", or its own check | the stale-cancel race: a signal that raced the drain reached the next job |
| No drain | the stale-cancel race: "a stale cancel reached a job"; cancels; drain consumed | in some runs, the withdraw race on 1 carrier, optimized: undrained bytes filled the pipe, and a cancel's write blocked under the lock |
| The wait ended before the job is retired, the brief's order | nothing under ASan, so `make -C blorp test` passes with it | only TSan, run by hand: the withdraw race in every run, a data race between the waiter's `free` and the helper's retire |
| A helper that keeps its creator's mask | starts | nothing |
| The creator's mask not restored after a helper starts | starts: the carrier keeps every signal blocked | nothing |
| The arm refusing only a wait still armed, the first round's check | skipped park: the second arm is accepted, and the run ends without the refusal | nothing |
| A cancel pipe from a plain `pipe()` | starts | the pool races' descriptor check |
| A cancel pipe's read end left blocking | drain consumed: the helper hangs in its drain, and the run times out | nothing |
| Each new refusal's check removed, the pipe failure's included | its refusal; the arm's check fails both armed twice and skipped park; the destroy's and the park's entry checks fail finished owing and parked unarmed | nothing |

- **The cascades are expected.** The permit and the idle wait are what the
  carriers and helpers run on, so breaking either loses wakes in the cases
  that wait. No bite fails a case that does not use what it breaks.

**Evidence** (in the main checkout's ignored
`build/concurrency/landing4c-evidence/`, with the scripts in `tools/`):
- **Platforms.** Both probes passed every case on macOS with Apple Clang
  21, on arm64 Linux with Clang 18.1 and GCC 13.3, and on emulated x86-64
  Linux with GCC 13.3. CI's Linux x64 jobs are the native x86-64 run.
- **GCC's fake stacks on arm64.** GCC's ASan build of the 1-carrier stale
  race takes 17.7 s with fake stacks and 2.8 s without; Clang's takes 2.7 s
  either way, and GCC's on x86-64 3.2 s. CI has no arm64 GCC job, and the
  suite's child timeout is 60 s.
- **ThreadSanitizer,** by hand in the arm64 image: every case of both probes
  that does not abort, none of which forks, at `-O1` and `-O2`, 3 times each
  with Clang and GCC: no report.
- **Fixture C,** every e2e fixture compiled by main's compiler and by this
  one: status, stdout and stderr are identical for all 782. 639 emit
  identical C and 135 are rejected. The other 8 differ exactly by the move,
  byte for byte, and the classifier first checks that the moved text is the
  old one less `static`; a stray change planted in one is reported:
  - **5 move it:** the programs with `capture` or `run`, whose
    `PROCESS_LAUNCH_RUNTIME` loses it and `PROCESS_HELPERS_RUNTIME` gains it;
  - **3 gain it unused:** `process/natives_exit_interrupted`,
    `natives_fault` and `natives_find_program`, which have the helpers but
    no launch. It is external there, as the helpers' functions are, so no
    compiler warns.
- **The gate,** `make -C blorp test INSTRUCTION_CHECK=on` on the final
  landing commit `3bb258991`, after the review's fixes and on main's
  `de4d40413`: exit 0, 3,700 passed and none failed. The fiber suite runs
  31 tests and the pool suite 12. `git diff --check` is clean.
- **Seed CI** on that commit, run 46134292868: every platform job passes,
  Linux x64 GCC included, and the Seed job proves the fixpoint on all three
  targets, with x86-64 run natively. An earlier run failed on Linux x64 GCC,
  whose `-Wenum-compare` rejected a check comparing two enums' constants;
  the wait phases and their mask are now one enum.
- **During the review's rounds,** the implementer ran both probes in the
  arm64 image with Clang and GCC, under ASan and UBSan and at `-O2`, and
  built them with GCC in the amd64 image. The non-aborting new case, yield
  keeps permit, is TSan clean in 3 runs on each probe. The fixes change only
  `fiber.brp`'s and `blocking.brp`'s fragments, which no compiler module
  imports, so no program's C changes: `git grep -n
  "runtime/fiber\|runtime/blocking" -- blorp/src` finds nothing.
- **The review's probes** (`review-probes/`): after a won wait and a plain
  switch, the fiber's next park yields; a stale claim on an unmapped
  record's reused address still wins, as documented above; and a job that
  reads its cancel byte stops the program with the drain's message.

**Cost,** on the final landing commit after the review's fixes,
`self-compile-cost de4d40413 3bb258991 --rounds 3`, fixed-input row:

| Measure | Base `de4d40413` | Candidate `3bb258991` | Change |
| --- | ---: | ---: | ---: |
| Allocations | 13,685,669 | 13,685,669 | +0.0000% |
| Peak heap, bytes | 190,820,897 | 190,820,897 | +0.0000% |
| Instructions, median of 3 | 13,882,225,077 | 13,869,750,045 | −0.0899% |

The fixed-input C is identical (`e251cb8905a09a48`). The own-source row:
allocations +0.0000%, peak heap +0.0003%, instructions −0.0433%. No compiler
module imports the new fragments. Raw samples are in
`build/concurrency/landing4c-evidence/cost-final/`.

**Lines,** from `1b0ee4565`, after three reviews' fixes:
- **production:** +467 and −24, so +443 net: `blocking.brp` +279;
  `fiber.brp` +170 and −6; `process.brp` +18 and −18, the move;
- **test:** +1,159 and −13, so +1,146 net, against the brief's estimate of
  +900. The growth audit, before the reviews' fixes added 92:

  | Part | Lines | Of which beyond the brief's list |
  | --- | ---: | ---: |
  | `fixtures/blocking_test.c` | 425 | about 16: submit before start, pipe fails, ended elsewhere |
  | `blocking_suite.brp` | 210 | about 23 for those three; about 135 is the probe runner each runtime suite has, building, running and matching |
  | `fixtures/fiber_test.c` | +232 and −4 | about 22: armed twice, parked by a fiber |
  | `fixtures/carrier_harness.h` | 140 | none: the brief's carrier loop, run queues and watchdog |
  | `fiber_suite.brp` | +57 and −9 | about 14 for those two |
  | `driver.brp` | +3 | |

  The first review's fixes then added the yield-keeps-permit case and two
  refusals: `blocking_test.c` +14, `blocking_suite.brp` +14,
  `fiber_test.c` +20 and `fiber_suite.brp` +4. The second's added the
  skipped-park refusal and the creator's-mask check: `fiber_test.c` +6,
  `fiber_suite.brp` +4 and `blocking_test.c` +6. The third's added the
  finished-owing and parked-unarmed refusals: `fiber_test.c` +10 and
  `fiber_suite.brp` +14.

  - **Where the estimate fell short:** the carrier harness and the second
    suite's probe runner, about 275 lines, as 4b's estimate left out its
    fixture infrastructure.
  - **The refusals beyond the brief,** about 75 lines with their suite
    entries, make five rules fail loudly. Cutting them, and their nine
    production lines, would leave about +980, still over.

**The test ceiling, corrected by the coordinator on 2026-11-28:**

| Ceiling | Old | New |
| --- | ---: | ---: |
| Test lines | +900 | +1,110, then +1,130, then +1,150 |

- **The first correction:** the review's growth audit found nothing to cut.
  Both fixtures share the carrier harness, and every case is either a brief
  item or a refusal the review asked to keep. The estimate left out about
  275 lines of infrastructure, as 4b's did. The new figure also pays for
  the review's three regression cases, about 52 lines.
- **The second** pays for the second review's two cases, about 16 lines:
  the skipped park, and the creator's mask after a helper starts.
- **The third** pays for the third review's two refusal cases, about 24
  lines: a fiber that finishes with a park owed, and a park with no wait
  armed.
- **Left for a later change:** `blocking_suite.brp` copies
  `fiber_suite.brp`'s probe runner, and `pool_suite.brp` follows the same
  pattern. Sharing it would save about 100 lines across the three suites.

**Not covered:**
- retiring idle helpers: helpers never exit;
- native x86-64 hardware; CI's Linux x64 jobs are the native run;
- the idle spin's length on x86-64, where `pause` takes 10 to 140 cycles by
  model, so 20,000 rounds may spin for up to about 1 ms;
- a repeatable TSan gate: its runs here were by hand;
- a party that keeps a fiber record past its destroy: the kept wait word
  makes it lose only while the record stays cached;
- fiber migration: a fiber still stays on the carrier that started it.

**Follow-ups for landing 5:**
- **Start the pool from the main thread,** with `blorp_blocking_start`,
  before any other thread runs Blorp code.
- **Supply `blorp_kernel_queue`,** which queues a fiber on its own carrier.
- **Park exactly once for each wait armed,** before arming the next and
  before finishing: the arm, the park and the destroy refuse otherwise.
- **No party touches a fiber record after destroy,** design change 2: a
  stale party on an unmapped record's reused address can win a claim.
- **Publish a job to cancellers only after its submit.**
- **Hold off a waiter's leaving its wait while cancelling,** under one lock
  that the canceller holds across `blorp_blocking_cancel` and its own end
  of a withdrawn wait, as the suites' `leave` lock does.
- **Raise the descriptor limit** to the hard limit at start, or report it
  as the cause, since a default macOS allows 126 helpers.
- **The mask's two rows:** `exit_interrupted`'s `raise`, and a child's mask
  before `exec`, once natives run on helpers.
- **`THREAD_RUNTIME` is emitted once** for the pool, the fibers and the
  helpers, as 4b's follow-up says for two of them.

## Landings

Each is a vertical slice that can be tested on its own. Every one runs
`make -C blorp test`, a dispatched Seed job, and `self-compile-cost
--rounds 3` against its ceilings. Ceilings are set from the spikes'
compiled code.

**Pure tasks, after Spike P:**
1. **Thread-safety prerequisites, for what a pure task can touch:**
   - **String literals,** published once under a lock, with an acquire load on
     the fast path. Each site still allocates exactly once.
   - **The diagnostics allocator's lock** becomes a mutex, and the literal
     registry is pushed under the literal lock.
   - **An audit** of every global that emitted C or the runtime changes and a
     pure task can reach. Each one is made safe, or the plan records why it
     already is; the table is under "Landing 1 results".

   A pure task cannot spawn a process, read the console or print. So the
   fork lock, the counted signal swap and the line lock go with the first
   helper threads, in landing 4. Pool stack sizes and guards go with the pool,
   in landing 2.

   **Landing 1b: stop writing a literal's count in a normal build.** This was
   split out of landing 1, because it cost about +2.4% instructions and
   +2.3% cycles on a one-thread `-O2` self-compile.
   - **Why it costs that.** The check itself is two instructions, but the
     larger release pushes emitted drop helpers past clang's inline
     threshold.
   - **What it must solve.** It needs an emit-side fix, such as an
     out-of-line release only in drop helpers, or a release with a cold
     free path. It lands before landing 3, where shared literals would
     otherwise contend.
   - **Done** with no emit change, together with a test-and-test-and-set
     diagnostics lock: see "Landing 1b results".
2. **`concurrent:` for pure tasks, the front end,** with no seed rotation
   (see "What the compiler needs"):
   - `concurrent:` syntax and its checks, accepting only pure tasks for now.
     Until landing 4, an impure task is rejected with `concurrent tasks must
     be pure until the concurrency runtime lands`;
   - the designated `concurrency` module, loaded when a module uses the
     block;
   - its private `join` and `run`, written in Blorp, so a block's tasks run
     one after the other;
   - the README section, grammar and fixtures.

   **Landing 2a: the native `join`.** `join` becomes a native with callable
   parameters and per-instance trampolines that call each task's lambda
   directly. Own gives the task instances a native calls the borrowed ABI,
   as it does for instances taken as callables, and verify checks each
   task's callee against its slot. Only the concurrency module may declare
   `concurrency.*` labels. It is built on landing 2b's pool, so no serial C
   body lands.

   **Landing 2b: the pool.** A work-stealing pool runs `join`'s tasks at
   once, with thread counts, stack sizes and guards. It is runtime C only.
3. **`parallel_map`:** native, specialized per callback, and splitting
   adaptively on the pool. Done: see "Landing 3 results".

**Concurrency, after Spike K:**

4. **Kernel support.** The coordinator split it on 2026-11-26 into seven
   slices, after a survey of the code. Each is tested on its own, most as
   direct-C suites, as landing 2b's pool was.
   - **4a. Natives safe on several threads:**
     - the fork lock;
     - the counted SIGINT and SIGQUIT swap, including `capture`'s child
       and `exit_interrupted`;
     - whole lines from `print` and `print_error`;
     - feature macros before the first include (Spike K's change 9);
     - an audit of the globals that impure natives touch.

     Done: see "Landing 4a results".
   - **4b. The fiber primitives:**
     - kernel locks that spin, then block (change 4);
     - the switch for arm64 and x86-64, with CET and BTI;
     - fiber stacks with a lazy commit, a guard and a cache;
     - the ASan and TSan switch hooks.

     See "Landing 4b results".
   - **4c. Parking and the blocking pool:**
     - park and unpark with permits;
     - the wait word and its claim, with one waker per wait (change 3's C
       half);
     - the carrier's idle wait;
     - the blocking pool. It grows on demand, never queues an unbounded
       native, and caps the bounded ones;
     - withdrawing a job (change 6);
     - one cancel pipe per helper, which bounds descriptors.

     See "Landing 4c results".
   - **4d. The console:** the kernel-owned stdin with its line lock;
     poll-based console reads that can be cancelled; and a job for each
     blocking native.
   - **4e. Non-regular-file reads.** `open` on a FIFO blocks before `fstat`
     can run, so this slice starts with a design for telling which reads
     are unbounded.
   - **4f. The kernel module and its cell:**
     - a `KernelModule` role, designated by its path,
       `concurrency/kernel.brp`, which only the concurrency module may
       import;
     - the `Guarded[T]` type, and its constructor, `kernel.guard`.
   - **4g. `kernel.take`, `kernel.put` and `update`.**
     - `put` receives its value through a new rule that names the operand a
       runtime operation owns. In-place reuse moves only operand 0, so it
       cannot express this.

   **No seed rotation.** Every native keeps its label and contract, so the
   modules that `src` imports do not change.

   **Moved to landing 5:** `first:` and impure tasks in `concurrent:`.
   `first:` is typed `First[A]`, and an impure task runs as a fiber, so
   neither can work before landing 5.
5. **The MVP:**
   - `first:` syntax, and impure tasks in `concurrent:`, moved from landing
     4;
   - fibers, block scopes and the cancellation tree;
   - `run` reaping through `blorp_process_reap`'s reservation, so a
     canceller can kill its child (it reaps with a plain `waitpid` today);
   - `First`, `sleep`, `timeout` and `cancelled`;
   - `Duration`, `concurrent_map` and `simulate`;
   - cancellable `capture`, `output` and `run`, and `Command.timeout_ms`
     deleted;
   - `parallel_map`'s impure-callback help, "use a for loop for impure work"
     since landing 3, becomes "use concurrent_map for impure work"
     (`PARALLEL_CALLBACK_HELP` in `check/render.brp`);
   - Spike K's design changes 1, 2, 3, 5 and 6, so a cancel never claims a
     join's wait.

   The first user is the e2e test driver, which runs its cases as processes
   with timeouts: exactly the MVP's shape, outside compiler source.
6. **Channels:**
   - `Channel[T]` and the `Message` bound;
   - `concurrent for`, and `for item in channel:`;
   - channel branches in `first:`;
   - Spike K's design changes 7 and 8.

   It waits for in-place reuse of a uniquely owned record, a compiler change
   of its own. Without it, Spike K's channel messages allocated twice each.

**Only for a named workload that needs them:**

7. **Several carriers.** M:N scheduling and work stealing, for impure CPU
   work that pure tasks do not cover.
8. **Readiness-based I/O.** Without networking it helps only pipes and
   terminals, since epoll refuses regular files.

**Size,** from the first plan review, which read the code:

| Area | Likely lines |
| --- | ---: |
| Parse, formatter, language-server tokens, grammar | 240–340 |
| Check: the rules, typing, branch kinds, the `Message` bound, rewrites, module kind | 750–1,100 |
| Specialize, own, verify, emit: `Guarded`, the received operand, trampolines | 400–700 |
| The Blorp kernel and API | 1,500–2,500 |
| C: the pool, four switch variants, ASan hooks, the blocking pool, the stdin buffer | 1,100–1,500 |

## Decisions

Keith settled these on 2026-11-24:

1. **Blocks.** `concurrent:` and `first:` are syntax, because they are
   control flow whose branches must not run eagerly. The first draft's
   `parallel:` block merged into `concurrent:` (decision 16).
2. **Cancellation means waits close:** no interruption, no unwinding, and no
   new result types.
3. **No `detach`.**
4. **`Duration`,** not bare `Int` milliseconds.
5. **Channel choice through `first:`,** by channel-operation branches.
6. **No resources in concurrent tasks.**
7. **Parallelism first,** now pure tasks first.
8. **No task-group value.**
9. **Channels close explicitly, and are one handle.**
10. **`concurrent for`** runs each iteration as a task. A plain `for` is
    always sequential.
11. **A channel's element type contains no `Channel` or callable,** so
    queues of closures are ruled out. This is enforced by the `Message`
    bound (decision 19).
12. **`cancelled() -> Bool`** lets a task see its cancellation.
13. **`send` returns `Bool`:** `True` once delivered.
14. **Every `first:` returns `First[A]`,** with or without a deadline.
    - `timeout(duration)` is the block's deadline clause, and
      `after(duration, value)` is gone.
    - Keith rejected a block whose type changes with its clauses.
    - He also rejected the `Option` of the first draft, whose `None` also
      meant a closed channel.
15. **`concurrent:` bindings are not wrapped,** and every failure belongs to
    the type of what failed.
    - Keith agreed that network and other I/O failures belong in the I/O
      functions' own results.
    - He considered a `Concurrent[A]` wrapper. Its only other case,
      `Cancelled`, can arise only when the `first:` above has already
      discarded the result.
16. **One `concurrent:` block for pure and impure tasks.**
    - The first draft's `parallel:` block is merged into it, since for pure
      work the two computed the same thing.
    - Pure tasks run on the pool, and impure ones as fibers, so the two
      mechanisms stay separate.
    - A block of only pure tasks may appear in a pure function.
    - `parallel_map` stays, for a pure function with no bound.
17. **`Finished(A)`, not `Success(A)`,** as `First`'s first variant, so
    `Finished(Err(message))` reads as "a branch finished, with an error".
18. **Ready branches are chosen at random,** as Go's `select` does, so none
    starves. The choice is seeded under `simulate`.
19. **The `Message` bound** is how generic channel code states that its
    element type can be sent. It is built in and derived like automatic
    equality.

**Corrections the reviews made, within those decisions:**
- **Rejected:**
  - a pure `first:` branch, since abandoning one, as first drafted, was
    unsound;
  - a channel operation inside a `first:` branch that is not the whole
    branch.
- **`first:`'s work branches follow the `if`/`match` typing rule,** and the
  deadline clause has no type.
- **A cancelled `first:` with no winner returns `Timeout`,** with or without
  a deadline.
- **`concurrent for` and `concurrent_map` always run fibers.** Only
  `concurrent:`'s direct statements are placed by purity.
- **Deadlocks:** outside `simulate`, a deadlock stops the program without
  running user code, after writing its report.
- **The blocks are contextual words.**
- **Renames:** `map_concurrently` is `concurrent_map`, matching
  `parallel_map`'s word order, and `now` is `elapsed`. `collect` is cut.

**Approvals Keith gives later:**
- **Spike P's build** patches emitted C on a branch that never lands
  (`blorp/AGENTS.md`). This is needed first.
- **A TSan run** would be a new harness mode. Spike K ran TSan by hand
  instead, so it added none.
- **Spike K's build** replaced its stubs' emitted bodies with C, on a branch
  that never lands. Keith approved it on 2026-11-26.
- **Deleting `Command.timeout_ms`** is a breaking change, in landing 5.

## What we take from other languages

| From | Taken | Left behind |
| --- | --- | --- |
| Trio (Python) | Nurseries, where every task has a parent that waits for it. Cancel scopes, and timeouts as scopes (`move_on_after`). `MockClock`'s autojump. | Cancellation as an exception raised at each checkpoint |
| OCaml 5: Eio and Domainslib | The nearest whole design. Fibers with `Fiber.first` and `Fiber.both`, beside a separate pool for parallel domains. | Effects as the mechanism |
| Haskell | `concurrently` and `race` from `async`, which `concurrent:` and `first:` generalize. `System.Timeout.timeout` returning `Maybe`, as `first:` returns `First`. | Asynchronous exceptions |
| Kotlin coroutines | Structured concurrency; `isActive`, which `cancelled()` mirrors; `withTimeoutOrNull`; `select` clauses; `runTest`'s virtual time | `suspend` functions, a colour |
| Java virtual threads | Blocking code on cheap threads with no colours; `StructuredTaskScope`; the lesson of pinning, which purity rules out for a kernel step | Interruption as an exception; unstructured `Thread.start` |
| Go | Channels and `close`; a receive on a closed channel returning at once; `select`, with its random choice among ready cases; `gopark` unlocking only after the switch; `sellock`; `ForkLock` | Unstructured goroutines; a `context` passed by hand, which is easy to ignore; a panic on sending to a closed channel |
| Rayon | `join` as the one parallel primitive, with work stealing | — |
| Verse | Blocks whose lines are tasks (`sync`, `race`) | — |
| Concurrent ML | Exactly-once choice through a claim per selection | Events as a first-class user type |
| Erlang | No shared state; communication by message | Linked processes killing each other |
| Rust | Data-race freedom guaranteed by the compiler | `Send` and `Sync`, which value semantics makes unnecessary; `async` colours |

**Where Blorp differs:**
- **Cancellation is a value, not an exception.** Go's context comes closest:
  a closed channel plus an error value, passed by hand. Blorp's is Go's
  context made implicit and structured. A cancelled wait returns its closed
  case, and `cancelled()` covers loops that wait on nothing else.
- **One bound classifies what may cross,** and only for channels: `Message`.
  Value semantics makes everything else sendable.
- **Parallelism needs no keyword of its own.** A pure task gets it, checked
  by the purity system Blorp already has.

## Not in this proposal

- Shared-memory primitives for users: mutexes, atomics or thread-local storage.
- Actors, supervisors and restart policies.
- Preemption: a busy impure task delays its cancellation, and on one carrier
  every timer, until its next wait.
- Parallel reductions, which would need a rule about floating-point
  reassociation.
- Fail-fast `?=` across tasks, as Haskell's `concurrently` and Go's errgroup
  do. It is rejected for now, and could come later.
- Signal handling.
- Real-time scheduling and priorities.
- Networking.
- x86-64 macOS, which CI does not run, unless a runner is added.
- Distributed computation.

## Reviews

**Round 1** read the draft at `09d56c02f`:
- the **API** review (Opus): sound with changes, 4 blockers;
- the **strategy** review (Opus): sound with changes, 3 blockers;
- the **ergonomics** review (Sonnet): good with changes, 3 blockers;
- the **implementation-plan** review (Opus): buildable with changes, 5
  blockers.

Its blockers, all resolved:
- `first:` examples that did not type-check;
- timeouts that did not bound time;
- channel reference cycles;
- a concurrent plain `for`;
- a park/wake race;
- a closure-taking `update` that allocated on every step;
- a reserved `first`;
- the rewrite in the wrong phase;
- the `send` ceremony.

**Round 2** read the draft at `e04231258`:
- the **soundness** review (Opus): sound with changes, 2 blockers;
- the **safety** review (Opus): safe with changes, 3 blockers;
- the **ergonomics** review (Sonnet): good with changes, no blockers.

Its blockers, all resolved above:
- **The `Message` bound.** Written types could not enforce the cycle rule
  through generics and opaque types.
- **Cancelling `first:`.** A cancelled `first:` with no deadline was
  unspecified, and the service loop never stopped.
- **The deadlock exit** ran user code on values computed under cancellation,
  and might never report.
- **Cancelling `run`** with a group kill would have killed the program
  itself.

Round 2 also confirmed, against the runtime's code:
- every reference-count operation is atomic;
- copy-on-write tests are acquire loads, so a shared value is copied, never
  updated in place;
- the closure rules keep resources and scoped callables out of tasks and off
  the pool.

Also folded in from round 2:
- detection that counts pool work and queued natives;
- non-regular files treated as unbounded;
- a kernel-owned stdin buffer;
- the counted signal swap;
- Go-style `sellock` for exactly-once choice;
- the cancellation idioms;
- immortal string literals, published once;
- the qualified determinism claim;
- the 64 KiB stack guard and defined failures;
- channels confined to `simulate`;
- `concurrent_map` and `concurrent for` always running fibers;
- task purity published by check;
- `cancelled().not()`, final `void`s and other corrected examples;
- the transitions module public for tests;
- the harness gap for seed reporting.
