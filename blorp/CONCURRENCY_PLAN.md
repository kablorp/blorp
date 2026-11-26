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
| `parallel_map`'s function is pure | `parallel_map needs a pure function: read_text is impure` / `use concurrent_map for impure work` |
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
- **A rotation before a module `src` imports uses a new label.** Moving
  natives onto helper threads changes `io/files` and `io/console`, which
  `src` imports, so landing 4's new labels reach the seed before those
  modules use them. That landing also measures the self-compile cost, since
  the compiler's own C changes.

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
   adaptively on the pool.

**Concurrency, after Spike K:**

4. **Kernel support:**
   - `Guarded`, `take` and `put`;
   - the switch, stacks and park;
   - the blocking pool with cancel descriptors;
   - the fork lock, the counted signal swap and the line lock;
   - the kernel-owned stdin;
   - poll-based console and non-regular-file reads;
   - `first:` syntax, and impure tasks in `concurrent:`.

   Then a seed rotation.
5. **The MVP:**
   - fibers, block scopes and the cancellation tree;
   - `First`, `sleep`, `timeout` and `cancelled`;
   - `Duration`, `concurrent_map` and `simulate`;
   - cancellable `capture`, `output` and `run`, and `Command.timeout_ms`
     deleted.

   The first user is the e2e test driver, which runs its cases as processes
   with timeouts: exactly the MVP's shape, outside compiler source.
6. **Channels:**
   - `Channel[T]` and the `Message` bound;
   - `concurrent for`, and `for item in channel:`;
   - channel branches in `first:`.

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
- **A TSan run** would be a new harness mode. Spike K needs it for the race
  cases, on its own branch.
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
