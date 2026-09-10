# Make Exact Timing Fiber-Correct And Report Self Time

**Status:** Ready after Issue 1

**Roadmap dependency:** Dense profile function IDs

**Can proceed in parallel with:** Issue 2 after the dense-ID ABI is fixed

**Unblocks:** Issue 4

## Issue Summary

Move exact-profile call stacks from OS-thread-local fixed arrays to logical
execution contexts, define the clock as scheduled-active monotonic time, and
report both inclusive and self time.

This is a correctness issue as well as a profiler improvement. A Blorp worker
thread can resume one fiber, observe it yield, and then run another fiber. The
current `_Thread_local` profile stack survives that switch. If the first fiber
yields inside a profiled call, the second fiber's calls can be pushed above the
first fiber's frames. Name-matching recovery may later discard or misattribute
frames, and wall time while the first fiber is parked can be charged to it.

## Current Behavior

The runtime currently stores:

```c
static BLORP_THREAD_LOCAL blorp_ProfileFrame
    profile_stack[BLORP_PROFILE_MAX_STACK];
static BLORP_THREAD_LOCAL int profile_stack_depth;
```

A frame contains an entry pointer and one `CLOCK_MONOTONIC` start timestamp.
On exit the runtime scans backward for a matching name, removes one frame by
shifting later frames, and adds the entire elapsed interval to the function's
inclusive total.

The scheduler in the same runtime states that the active task is fiber-scoped,
not OS-thread-scoped. `mco_resume` may return because a fiber parked on a
channel, timer, join, I/O operation, or cancellation boundary. Another fiber
then executes on the carrier thread.

The existing self-time proposal in
`docs/issues/typechecking/inference-performance-profiling.md` correctly adds
`child_ns` to each frame. This issue adopts that model but changes the time
source from raw wall intervals to a fiber's scheduled-active logical clock.

## Timing Semantics

Name the exact time domain:

> **scheduled-active monotonic time** is monotonic wall time accumulated only
> while the logical execution context is running on a carrier thread.

It includes time lost to OS preemption while the carrier is considered running,
but excludes time after the fiber yields and before it is resumed. It is not
process CPU time, thread CPU time, or end-to-end request latency.

This clock is appropriate for exact function attribution because another fiber
cannot accumulate time into a suspended call. End-to-end blocked latency belongs
in the event timeline from Issue 7.

For code executing outside a Blorp fiber, such as the main entrypoint before
task scheduling, scheduled-active time is ordinary monotonic wall time while
that root execution context is active.

## Goals

- Give every fiber its own exact-profile call stack.
- Provide a separate root/native-thread stack for calls outside a fiber.
- Eliminate the fixed 4,096-frame ceiling.
- Exclude fiber suspension intervals from exact function time.
- Calculate inclusive and self time correctly for nesting and recursion.
- Make cancellation/nonlocal unwind behavior explicit and measurable.
- Preserve profile-window epoch semantics without stale frames.
- Keep normal top-of-stack exit O(1).
- Report every abandoned, unmatched, or allocation-failed frame.

## Non-Goals

- Do not produce an end-to-end blocking timeline.
- Do not call scheduled-active time CPU time.
- Do not sample stacks in this issue.
- Do not move counters to per-worker shards yet.
- Do not change scheduler ownership or allow shared mutable access to a running
  fiber.
- Do not add a cycle collector or retain fibers solely to keep profile data
  alive after their normal lifecycle.
- Do not preserve malformed stacks silently for the sake of a complete-looking
  report.

## Proposed Runtime Representation

Use one reusable stack abstraction for both fiber and root contexts:

```c
typedef struct {
    blorp_ProfileFunctionId id;
    uint64_t start_active_ns;
    uint64_t child_active_ns;
} blorp_ProfileFrame;

typedef struct {
    blorp_ProfileFrame *frames;
    size_t depth;
    size_t capacity;
    unsigned long epoch;
    uint64_t active_elapsed_ns;
    uint64_t resumed_at_ns;
    bool running;
} blorp_ProfileExecutionState;
```

`blorp_Fiber` owns one `blorp_ProfileExecutionState`. Non-fiber execution uses a
thread-local root state because foreign/native threads may enter runtime code
without a Blorp task.

The stack grows geometrically using named initial and growth policies. There is
no semantic maximum. Growth failure follows the explicit profiler failure rule
and increments `stack_growth_failures`; it must not overwrite existing frames
or write out of bounds. Recycled fibers clear depth, epoch, timestamps, and
diagnostics before reuse, while retaining or freeing capacity according to one
documented pool policy.

Do not put the profile stack in `blorp_Task` if the coroutine/fiber is the
actual scheduling and suspension unit. The profile execution state must follow
the entity whose active clock stops at `mco_resume` return and resumes at its
next `mco_resume`.

## O(1) Scheduled-Active Clock

Do not walk every active frame on each yield. Maintain one logical clock per
execution state:

```c
static uint64_t profile_active_now(blorp_ProfileExecutionState *state) {
    uint64_t total = state->active_elapsed_ns;
    if (state->running) {
        total += monotonic_now_ns() - state->resumed_at_ns;
    }
    return total;
}
```

Around the scheduler's resume boundary:

```c
profile_execution_resume(&fiber->profile_state, now_before_resume);
mco_result result = mco_resume(fiber->coro);
profile_execution_suspend(&fiber->profile_state, now_after_resume);
```

`resume` sets `resumed_at_ns` and `running`. `suspend` adds the elapsed carrier
interval to `active_elapsed_ns` and clears `running`. Function entry/exit reads
this logical clock. A parked interval therefore advances no function frame,
regardless of which other fibers execute on the same worker.

For the root TLS context, initialize it as running on first use and stop it only
at profile window/report boundaries or thread teardown. State clearly that root
time uses wall elapsed while the root thread is in the profiled program.

## Inclusive And Self-Time Algorithm

On entry:

```text
start_active_ns = execution_active_now()
child_active_ns = 0
push(id, start_active_ns, child_active_ns)
```

On a normal top-frame exit:

```text
end = execution_active_now()
inclusive = max(0, end - frame.start_active_ns)
self = max(0, inclusive - frame.child_active_ns)
entry[id].inclusive += inclusive
entry[id].self += self
entry[id].calls += 1
pop frame
if parent exists: parent.child_active_ns += inclusive
```

Recursion is ordinary nesting. Each invocation contributes its inclusive time
to its immediate parent invocation; the aggregate self time of the recursive
function remains the sum of its per-frame self intervals.

Every snapshot must satisfy:

```text
0 <= self_ns <= inclusive_ns
```

Across all normally completed calls in one non-overlapping execution context,
self time partitions measured active work. Inclusive time does not and must not
be summed for a total percentage.

## Mismatched Exit And Cancellation Semantics

Numeric IDs make the expected fast path exact:

```text
top.id == ending_id
```

If it does not match, use one named slow recovery path. Search downward by ID
only to support a known nonlocal unwind that skipped generated exits. Frames
above the matched frame are abandoned and do not increment completed call
counts. Increment:

```text
unmatched_ends
abandoned_frames
recovered_nonlocal_exits
```

The matched frame may record inclusive time, but it must not claim the
abandoned interval as self time. The existing issue's conservative rule is
acceptable: subtract the interval from the earliest abandoned child start to
the common end, discard all abandoned frames, and add only the matched
inclusive interval to its surviving parent.

Prefer a direct cancellation/unwind hook that abandons the current fiber stack
at the runtime's established `setjmp`/`longjmp` boundary. If that hook makes the
generic backward search unnecessary, delete the tolerant scan and require
strict top matching. Do not infer cancellation from a name mismatch.

When a coroutine dies with live frames, abandon and count them before recycling
its fiber. A process signal must only set an atomic request; reporting and stack
reconciliation remain outside the signal handler.

## Window Semantics

Retain and document the existing epoch rule:

- beginning a window pauses recording;
- waits for in-flight end commits;
- advances the global epoch;
- clears aggregate counters;
- lazily invalidates every execution state's old stack on its next touch;
- starts recording in the new epoch; and
- a call crossing the boundary contributes to neither window.

Ending a window similarly pauses, waits, advances the epoch, and leaves old
frames invalid. Do not iterate all fibers merely to clear their stacks. On next
resume or probe, an epoch mismatch sets depth to zero and records any discarded
depth as `window_abandoned_frames`.

If the current window API is process-global and non-nestable, preserve that
behavior. Scoped/nested recording sessions belong in Issue 6 or 7.

## Lifecycle And Ownership

Update every fiber construction, reset, recycle, destroy, and abnormal cleanup
path. The stack buffer is profiler-owned native memory and must not appear as a
Blorp ARC object. It must be freed exactly once if a cached fiber object is
ultimately destroyed.

Relevant runtime areas include:

- `struct blorp_Fiber`;
- fiber object initialization and recycling;
- the worker loop around `mco_resume`;
- coroutine-dead handling;
- cancellation cleanup and task completion;
- global scheduler shutdown; and
- root/non-fiber runtime entry.

Run leak checks with profiling enabled. A test that only observes ordinary task
completion will miss cancellation and pool-shutdown leaks.

## Implementation Steps

1. Add a deterministic regression fixture with two fibers on one worker. Fiber
   A enters a profiled parent and parks; Fiber B completes profiled calls; Fiber
   A resumes and exits. Demonstrate the current stack interleaving or wrong
   timing before implementing.
2. Add a synthetic nested/recursive self-time fixture.
3. Introduce `blorp_ProfileExecutionState` and stack helpers with native unit
   tests.
4. Attach state to fibers and add root TLS state.
5. Integrate the O(1) active logical clock around `mco_resume`.
6. Cut start/end over to the current execution state.
7. Implement top-frame self/inclusive accounting.
8. Implement explicit cancellation/window abandonment diagnostics.
9. Remove `BLORP_PROFILE_MAX_STACK` and the old TLS fixed array.
10. Cover fiber recycling, scheduler shutdown, and abnormal task completion.
11. Update report labels and documentation to say scheduled-active time.
12. Measure exact profiling before and after; the correctness fix must not add
    work proportional to active depth at yield/resume.

## Tests

### Timing invariants

Cover without narrow duration tolerances:

- one leaf: `inclusive >= self >= 0`;
- one parent/child: parent inclusive is at least child inclusive and parent self
  excludes child;
- two sequential children: parent self excludes both;
- direct recursion: every completed invocation is counted and self never
  exceeds inclusive;
- mutual recursion with distinct IDs;
- a zero-duration or clock-resolution tie remains nonnegative;
- normal nesting uses no mismatch recovery; and
- one synthetic nonlocal unwind reports abandoned frames exactly.

### Fiber behavior

Run with `--threads 1` and multiple fibers so thread pinning cannot hide
interleaving. Cover:

- a child fiber parks while a second fiber runs;
- channel wait, timer wait, join wait, and cancellation;
- parked time is excluded from the first fiber's scheduled-active total;
- another fiber's calls never become children of the parked frame;
- a recycled fiber begins with an empty profile state;
- worker shutdown frees dynamic stacks; and
- multiple workers aggregate the same function without stack corruption.

Use synchronization barriers or channels to make scheduling order exact. Do
not assert that a sleep lasted within a few milliseconds.

### Window and signal behavior

Cover calls wholly before, wholly inside, wholly after, and crossing a window.
Repeat a window to prove counters and frames reset. Preserve the existing
SIGTERM/SIGINT lifecycle fixtures and ensure a requested report cannot deadlock
on a fiber-state lock.

## Fast Feedback Loop

First run the new native stack helper test and one deterministic single-worker
fiber fixture. Then:

```bash
bin/blorp test blorp/test/compiler/stage_10_backend/test_core_emit.brp
scripts/test runtime
scripts/test leak
blorp/test/cli/test_cli.sh --smoke --timeout 30
```

Use a small standalone C harness for stack growth and corrupt-ID recovery so an
iteration does not rebuild the compiler. Run the sanitizer owner for the same
harness after the representation settles.

Before review:

```bash
make
scripts/test compiler-blorp runtime leak cli
scripts/test compiler-core-sanitize
make quality
```

Then run the exact-profiler overhead microbenchmark and one optimized compiler
self-profile.

## Performance Evidence

Record:

- function entry/exit operations;
- scheduler resume/suspend operations;
- clock reads at probes and scheduler boundaries;
- stack growth count and maximum observed depth;
- normal top exits and slow mismatch recoveries;
- abandoned frames by cause;
- profiled/unprofiled wall time and retired instructions; and
- fiber pool retained bytes attributable to profile stacks.

The scheduler integration must be O(1) per resume/suspend, independent of
profile depth. Normal exit must be O(1). Slow unwind may be O(depth) because it
is diagnostic and exceptional, but its count must appear in the result.

## Acceptance Criteria

- [ ] Each Blorp fiber owns an independent exact-profile execution state.
- [ ] Non-fiber execution has an explicitly separate root state.
- [ ] Fiber suspension time and other-fiber execution are excluded from
      scheduled-active function time.
- [ ] Resume/suspend cost is O(1), not O(active stack depth).
- [ ] `BLORP_PROFILE_MAX_STACK` and the fixed TLS stack are removed.
- [ ] Stack growth failure is explicit and memory-safe.
- [ ] Exact results include clearly labeled inclusive and self nanoseconds.
- [ ] Percentages use self time or another partitioning value, never summed
      inclusive time.
- [ ] Normal exits are strict O(1) top-frame matches.
- [ ] Cancellation, nonlocal unwind, window crossing, and dead fibers account
      for abandoned frames explicitly.
- [ ] Deterministic one-worker interleaving tests prove stacks cannot mix.
- [ ] Fiber recycle/shutdown paths pass leak and sanitizer checks.
- [ ] Existing signal lifecycle behavior remains intact.
- [ ] Measurement confirms no per-depth scheduler work was introduced.

## Pitfalls And Review Questions

- Was the state attached to `Task` even though `Fiber` is the suspension unit?
- Does `profile_active_now` double-count an interval after repeated resume?
- Can an epoch change leave `running` true with a stale `resumed_at_ns`?
- Does a root-thread call become a child of the last fiber run on that thread?
- Are fiber objects zeroed correctly when recycled from the pool?
- Can report code inspect a stack while its fiber is running?
- Does cancellation free or abandon frames before `longjmp` invalidates local
  state?
- Are inclusive and self totals named with their clock semantics?
- Did the implementation use `CLOCK_THREAD_CPUTIME_ID` and then accidentally
  lose time when a pinned fiber changes carrier in a future scheduler?
- Did a profiling-only allocation become visible to language leak accounting?

This issue is incomplete if self time is added while the active stack remains
OS-thread-local.
