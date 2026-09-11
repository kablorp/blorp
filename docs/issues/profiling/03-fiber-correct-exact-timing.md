# Make Exact Timing Fiber-Correct And Report Self Time

**Status:** Implemented

**Roadmap dependencies:** Dense profile function IDs and explicit profiling
modes/selection

**Unblocks:** Issue 4

## Issue Summary

Move exact-profile call stacks from OS-thread-local fixed arrays to logical
execution contexts, define the clock as scheduled-active monotonic time, and
report both inclusive and self time.

This is a correctness issue as well as a profiler improvement. A Blorp worker
thread can resume one fiber, observe it yield, and then run another fiber. The
prior `_Thread_local` profile stack survived that switch. If the first fiber
yields inside a profiled call, the second fiber's calls can be pushed above the
first fiber's frames. Name-matching recovery may later discard or misattribute
frames, and wall time while the first fiber is parked can be charged to it.

## Prior Behavior

The runtime previously stored:

```c
static BLORP_THREAD_LOCAL blorp_ProfileFrame
    profile_stack[BLORP_PROFILE_MAX_STACK];
static BLORP_THREAD_LOCAL int profile_stack_depth;
```

A frame contains a compiler-assigned dense function ID, a profile-window epoch,
and one `CLOCK_MONOTONIC` start timestamp. On the normal exit path the runtime
matches the top frame by numeric ID. Its exceptional recovery path scans
backward for the ID, removes the matching frame by shifting later frames, and
adds the entire elapsed interval to the function's inclusive total. Issue 2
also split count-only and exact probes; this issue must not add exact stack or
clock work to count-only probes.

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

## Runtime Representation

Use one reusable stack abstraction for both fiber and root contexts:

```c
typedef struct {
    blorp_ProfileFunctionId id;
    uint64_t start_active_ns;
    uint64_t child_active_ns;
    unsigned long epoch;
} blorp_ProfileFrame;

typedef struct blorp_ProfileExecutionState {
    blorp_ProfileFrame *frames;
    size_t depth;
    size_t capacity;
    size_t dropped_depth;
    size_t suppressed_dropped_depth;
    unsigned long epoch;
    uint64_t active_elapsed_ns;
    uint64_t resumed_at_ns;
    bool running;
    bool registered;
    struct blorp_ProfileExecutionState *registry_next;
} blorp_ProfileExecutionState;
```

`blorp_Fiber` owns one `blorp_ProfileExecutionState`. Non-fiber execution uses a
thread-local root state because foreign/native threads may enter runtime code
without a Blorp task.

The stack grows geometrically using named initial and growth policies. There is
no semantic maximum. Growth failure follows the explicit profiler failure rule
and increments `stack_growth_failures`; it must not overwrite existing frames
or write out of bounds. Recycled fibers account for any surviving frames and
free their exact-profile buffer before entering the object pool. This
no-retention policy prevents idle pooled fibers from retaining profiling memory.
Reused fibers begin with an empty descriptor.

Allocate stack storage lazily on the first exact-profile entry. The compiler
places `BLORP_PROFILE_EXACT_TIMING=1` before the runtime only for exact-profile
artifacts. Ordinary and count-only runtimes compile the fiber descriptor and
scheduler hooks out completely; they do not allocate, initialize, branch on,
resume, suspend, or destroy exact-profile state. Blorp-owned external runtime
objects are keyed by this mode so an exact generated artifact cannot reuse an
ordinary runtime object.

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

For the root TLS context, initialize it as running on first use and stop it at
report or thread teardown. Each frame start is relative to the current window,
so crossing frames are suppressed by epoch without restarting the root clock.
Root time uses wall elapsed while the root thread is in the profiled program.

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
counts. When a matching frame is found below the top, increment:

```text
out_of_order_ends
abandoned_frames
recovered_nonlocal_exits
```

Increment `unmatched_ends` only when no matching frame exists. The matched
frame records inclusive time but does not claim the abandoned interval as self
time. The runtime captures the execution-state depth before the established
cancellation `setjmp` and accounts unsuppressed frames plus overflow debt after
`longjmp`. Before classifying that debt, cancellation synchronizes the state to
the current profile-window epoch. Frames invalidated by a window transition are
therefore charged to the window exactly once, never relabeled as cancellation.
It does not infer cancellation from a name mismatch.

When a coroutine dies with live frames, abandon and count them before recycling
its fiber. A process signal must only set an atomic request; reporting and stack
reconciliation remain outside the signal handler. Live exact execution states
are registered without retaining their owning fiber. Report disables new exact
operations, waits for in-flight frame and scheduler-clock operations, and then
accounts every registered root or fiber state. Abandonment diagnostics separate
window, cancellation, dead/shutdown, signal, and recovered nonlocal-exit causes.

## Window Semantics

Retain and document the existing epoch rule:

- beginning a window closes frame-operation admission and pauses recording;
- waits for in-flight frame mutations and counter commits;
- advances the global epoch;
- clears aggregate counters;
- lazily invalidates every execution state's old stack on its next touch;
- starts recording in the new epoch; and
- a call crossing the boundary contributes to neither window.

Ending a window uses the same frame-admission gate, pauses, waits, advances the
epoch, and leaves old frames invalid. Do not iterate all fibers merely to clear
their stacks. On the next probe, an epoch mismatch marks old frames and dropped
overflow debt as suppressed and accounts them once as
`window_abandoned_frames`, but preserves their order until matching exits
consume them. Clearing depth would make a crossing exit look unmatched and
could incorrectly match an older recursive invocation. Resume/suspend remains
independent of the frame gate, O(1), and does not walk frames for epoch
maintenance.

Window transitions, final reporting, and cleanup share one lifecycle mutex.
Reporting therefore cannot snapshot counters while a window resets them or
reopens frame admission, and a stale window operation cannot reactivate
profiling after cleanup.

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

The prior generated entrypoint registered `blorp_profile_report` after the
runtime constructor registers scheduler teardown. Since `atexit` runs in
reverse order, that reports before fibers are drained. Move final report
ownership to the runtime teardown boundary so scheduler shutdown and abandoned
fiber/root state are accounted before the report; do not retain two competing
exit-report registrations.

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

Use count-only or phase timing to identify a narrow target before exact
profiling. Exact-all profiling is an acceptance stress case, not the normal
feedback loop: Issue 2 measured it at `+160.39%` retired instructions, while
one selected exact function measured `+0.07%`.

Before review:

```bash
make
scripts/test compiler-blorp runtime leak cli
scripts/test compiler-core-sanitize
make quality
```

Then run the exact-profiler overhead microbenchmark and one optimized compiler
self-profile.

Use one unmeasured warmup followed by three alternating parent/candidate pairs.
Three pairs are sufficient for correctness work or a clear signal. Increase to
five only when the median result is within two percent, crosses an acceptance
boundary, or has enough dispersion to change the conclusion. Do not run ten
pairs by default. Retired instructions are the primary overhead signal when
wall time is noisy.

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

## Implementation Result

Exact-profile runtimes attach one dynamically growing profile execution state
to each `blorp_Fiber` and use a separately owned pthread/TLS root state outside
a fiber. Scheduler resume/suspend hooks advance one scheduled-active clock and
do not inspect frames. Exact entry/exit records inclusive and self nanoseconds;
the report sorts by self time and uses self time for percentages.

The fixed 4,096-frame array is gone. Allocation failure creates explicit
`dropped_depth` debt, preserving balanced exits without writing outside the
stack. Window crossings retain suppressed frames and overflow debt in stack
order. Window transitions gate frame mutations without stopping the O(1)
scheduler clock. Report/window/cleanup control operations are serialized, and
cancellation synchronizes the current epoch before attributing abandonment.
Cancellation, window, dead/shutdown, signal, and nonlocal abandonment have
separate counters. The runtime owns the final report after scheduler shutdown;
generated programs no longer register a competing report with `atexit`.

Final diagnostics include stack growths/failures, maximum depth, total and
cause-specific abandoned frames, recovered nonlocal exits, and existing ID and
call counters. Exact stack storage is lazy. Off and calls modes compile the
fiber descriptor and scheduler hooks out and never allocate it or read the
exact clock. Buffers are freed when fibers are recycled rather than retained in
the pool. Report quiesces all registered execution states before inspecting
them, including parked fibers during deferred signal handling.

## Validation And Measurement

All raw artifacts are ignored under `logs/profiling-issue-03/`. Measurements
used the parent at `bc16e67e`, one warmup, and three alternating pairs. The
parent compiler SHA was
`d88dbd65a3727a0b76cfbe02cfa0de44956e939b5891204e08f7da5dbe884351`;
the candidate compiler SHA was
`e8c1dfd584f879b9f9f54fdd68465f0b0ae933ad2a7a0ad35d6281d29e73bf3a`.
The measured candidate source patch SHA was
`e46df9d2b63c23c068688c742e076bc65e3ba04c134c33089829b40548bf5814`.
The pinned bootstrap was `0.0.1-dev.170c6c920ec1`, SHA-256
`155d15f76dc5e455c6a15abafee41da93d3d8f058cf507226160a8cfd27dc28a`.
Both exact workers compiled `blorp/src/main.brp` with Apple clang 21.0.0 at
`-O2`; their SHAs were
`00ce37f4fd3e50a2a3c095d01a047bf0b327d6bb2356192c18e08cf0cc62afca`
and
`4bbd969d58e9ccae1558fc8c08c7d0d729153affd856347ff90884cade237d87`.
Every generated response was byte-identical at
`464e4cc28e025dd0f0ce62fa4d32992c7edf8a24c878f01dba278503ed3f1e55`.
The clean host-monitor logs contain no overlapping compiler, build, or
benchmark process.

Final correctness review then added lifecycle-mutex serialization for
report/window/cleanup operations and current-epoch synchronization before
cancellation attribution. The final production-source patch SHA is
`037be57cd135c02246cb6f795228f0f3a09ca11a2a9643db5836242f719f83c1`.
These changes do not alter the exact entry/exit or resume/suspend hot paths or
the steady-state profiling-off path. Profiling-off cleanup gains only constant
uncontended lifecycle synchronization, so the paired timing matrix was not
repeated. The final native regressions exercise both corrected interleavings
directly.

### Compiler exact-all stress

`logs/profiling-issue-03/compiler-runs-final-clean4/` contains the accepted
exact-all runs. Exact-all deliberately profiles every emitted function and is
an observer stress case, not the recommended everyday mode.

| Metric | Parent median; MAD; range | Candidate median; MAD; range | Delta |
| --- | ---: | ---: | ---: |
| Wall seconds | 59.99; 0.05; 59.94-60.05 | 65.17; 0.01; 65.11-65.18 | +8.63% |
| Retired instructions | 878,719,938,157; 41,164,345; 878,678,773,812-878,809,703,420 | 1,019,915,362,170; 82,424,192; 1,019,786,065,564-1,019,997,786,362 | +16.07% |
| Cycles | 242,880,147,527; 44,043,320; 242,513,976,294-242,924,190,847 | 263,473,550,115; 61,737,314; 263,354,952,539-263,535,287,429 | +8.48% |
| Final checkpoint RSS bytes | 2,775,580,672; 98,304; 2,775,482,368-2,775,973,888 | 2,778,808,320; 49,152; 2,778,382,336-2,778,857,472 | +0.12% |
| Blorp allocator allocations | 330,846,050; 0; fixed | 330,846,050; 0; fixed | 0% |
| Blorp allocator releases | 307,454,914; 0; fixed | 307,454,914; 0; fixed | 0% |
| Blorp allocator current objects | 23,391,136; 0; fixed | 23,391,136; 0; fixed | 0% |
| Blorp allocator bytes | 1,948,647,216; 0; fixed | 1,950,418,464; 0; fixed | +0.09% |
| Phase total ms | 53,332.392; 29.681; 53,250.143-53,362.073 | 57,827.598; 22.485; 57,775.666-57,850.083 | +8.43% |
| Outer total ms | 53,439.788; 28.794; 53,357.038-53,468.582 | 57,935.247; 18.983; 57,884.349-57,954.230 | +8.41% |

Raw parent wall samples were `60.05, 59.99, 59.94` seconds; candidate samples
were `65.11, 65.17, 65.18`. Each candidate run described and selected 12,133
functions, observed 7,284, and completed 973,628,490 exact calls. The parent
described 12,132 functions because the candidate adds the runtime-prelude
helper. Both observed and completed counts were otherwise identical. Candidate
runs grew six stacks to a maximum depth of 563. Every invalid-ID,
unmatched/out-of-order exit, growth-failure, abandonment-by-cause, and recovery
counter was zero. The deterministic instruction and elapsed increases are the
cost of fiber-correct exact attribution, not a compiler speedup.

### Profiling-off compiler control

`logs/profiling-issue-03/compiler-off-runs-final3/` uses the same source/workload with
profiling disabled.

| Metric | Parent median; MAD; range | Candidate median; MAD; range | Delta |
| --- | ---: | ---: | ---: |
| Wall seconds | 36.17; 0.06; 36.11-36.28 | 36.21; 0.03; 36.18-36.38 | +0.11% |
| Retired instructions | 579,856,442,783; 121,052,150; 579,735,390,633-580,160,464,669 | 579,990,442,146; 12,195,159; 579,978,246,987-580,044,113,363 | +0.02% |
| Cycles | 146,018,914,308; 207,470,820; 145,811,443,488-146,510,052,217 | 146,089,137,482; 3,763,643; 146,085,373,839-146,669,801,349 | +0.05% |
| Final checkpoint RSS bytes | 2,778,005,504; 16,384; 2,777,415,680-2,778,021,888 | 2,778,595,328; 81,920; 2,778,513,408-2,778,923,008 | +0.02% |
| Blorp allocator allocations | 330,846,050; 0; fixed | 330,846,050; 0; fixed | 0% |
| Blorp allocator releases | 307,454,914; 0; fixed | 307,454,914; 0; fixed | 0% |
| Blorp allocator current objects | 23,391,136; 0; fixed | 23,391,136; 0; fixed | 0% |
| Blorp allocator bytes | 1,950,170,768; 0; fixed | 1,950,090,640; 0; fixed | -0.004% |
| Phase total ms | 33,600.518; 57.487; 33,543.031-33,715.323 | 33,633.900; 25.419; 33,608.481-33,803.103 | +0.10% |
| Outer total ms | 33,721.228; 60.807; 33,660.421-33,834.145 | 33,753.621; 24.896; 33,728.725-33,925.728 | +0.10% |

Raw parent wall samples were `36.28, 36.11, 36.17` seconds; candidate samples
were `36.18, 36.21, 36.38`. Output hashes and allocator object counts were
identical. The +0.02% retired-instruction and +0.11% wall medians are below
noise and show no material ordinary compiler regression.

### Focused costs and complexity

The five-million-call leaf probe in
`logs/profiling-issue-03/leaf-runs-final2/` increased median retired
instructions from 2,874,898,627 to 3,600,142,174 (+25.23%) and probe-loop
elapsed time from 206.123 ms to 231.880 ms (+12.50%). Parent elapsed samples
were `205.244, 208.198, 206.123` ms (MAD 0.879 ms); candidate samples were
`231.880, 231.322, 232.864` ms (MAD 0.558 ms). It performed 10,000,001 runtime
clock reads, completed 5,000,000 calls, grew one stack once, and lost no frames.
This is the direct per-call cost of the fiber-safe frame gate plus inclusive
and self attribution.

The five-million resume/suspend depth probe in
`logs/profiling-issue-03/scheduler-depth-runs-final2/` had overlapping elapsed
ranges: 1.637-2.778 ms at depth 1 and 1.588-2.351 ms at depth 5,000. Median
retired instructions were 33,428,459 and 33,805,653. The 377,194-instruction
fixed difference is the one-time initialization of 4,999 additional frames;
resume/suspend itself does not inspect the stack and is O(1).

A deliberately extreme 500,000-yield probe in
`logs/profiling-issue-03/fiber-yield-runs-final2/` confirms that ordinary and
calls artifacts compile exact scheduler hooks out. Off-mode median retired
instructions fell from 19,578,511,095 to 17,463,262,488 (-10.80%); calls mode
fell from 21,341,816,284 to 18,897,963,817 (-11.45%). Median wall time moved
from 1.56 to 1.39 seconds in off mode and from 1.70 to 1.49 seconds in calls
mode. Both candidate modes reported zero exact stack depth/growth and identical
calls-mode observations. This stress result does not establish a compiler-wide
speedup; the production compiler control above is the representative no-
regression result.

Final verification used `scripts/compiler-check --changed` (7 production
sources, 10 suites, 2 special checks), the native profile suite (12/12), the
serial compiler/runtime/leak/CLI gate (9,846/9,846), the Core sanitizer gate
(1,866/1,866), and `make quality`. Static analysis retained five pre-existing
`core.StackAddressEscape` warnings in the I/O cancellation cleanup path; no new
warning class was introduced.

Apple's ASan runtime rejects `detect_leaks=1`. On macOS, the native lifecycle
fixture therefore verifies stack-buffer release and registry removal directly;
on platforms with LeakSanitizer support it additionally runs with leak detection
enabled. The repository's Blorp leak gate also passes, but does not account for
these profiler-owned `malloc` allocations.

Selective exact profiling remains the normal recommendation. Shared atomic
aggregate updates and legacy flame-text output remain Issue 4 work. Root/native
scheduled-active time remains wall time and therefore includes time when its OS
thread is preempted. A caller using the low-level `--no-embed-runtime` compile
form must pair an exact-profile artifact with an exact-specialized runtime
object; Blorp's owned run/runtime-cache path does this automatically.

## Acceptance Criteria

- [x] Each Blorp fiber owns an independent exact-profile execution state.
- [x] Non-fiber execution has an explicitly separate root state.
- [x] Off and count-only modes allocate no exact-profile stack storage and pay
      no exact resume/suspend clock cost.
- [x] Fiber suspension time and other-fiber execution are excluded from
      scheduled-active function time.
- [x] Resume/suspend cost is O(1), not O(active stack depth).
- [x] `BLORP_PROFILE_MAX_STACK` and the fixed TLS stack are removed.
- [x] Stack growth failure is explicit and memory-safe.
- [x] Exact results include clearly labeled inclusive and self scheduled-active
      milliseconds backed by nanosecond counters.
- [x] Percentages use self time or another partitioning value, never summed
      inclusive time.
- [x] Normal exits are strict O(1) top-frame matches.
- [x] Cancellation, nonlocal unwind, window crossing, and dead fibers account
      for abandoned frames explicitly.
- [x] Deterministic one-worker interleaving tests prove stacks cannot mix.
- [x] Fiber recycle/shutdown paths pass leak and sanitizer checks.
- [x] Existing signal lifecycle behavior remains intact.
- [x] Measurement confirms no per-depth scheduler work was introduced.

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
