# Move Exact Counters To Local Shards And Define Structured Output

**Status:** Ready after Issue 3

**Roadmap dependencies:** Dense IDs, count/selective modes, and fiber-correct
exact timing

**Unblocks:** Issue 6

## Issue Summary

Remove shared atomic counter updates from hot function probes, merge
worker/thread-local shards at a quiescent snapshot boundary, and replace the
stderr-only ad hoc report with a versioned machine-readable profile stream.

The human table remains useful, but it becomes a derived view of one snapshot.
It is not the data interchange format.

## Current Behavior

Each completed exact call currently performs atomic additions to global
`total_ns` and `call_count`. After self time lands, that would become three
shared atomic read-modify-write operations per completed call. Frequently
called compiler helpers execute tens of millions of times, so atomics can
become a measurable profiler artifact even when threads rarely update the same
function simultaneously.

The report copies the fixed registry to a stack array, sorts by inclusive time,
sums overlapping inclusive values into `TOTAL`, prints a human table, and then
prints one `FLAME:name value` row per function. Consumers scrape stderr with
`rg` and `sed`. The rows contain no schema version, clock identity, artifact
identity, loss diagnostics, source metadata, or real stack hierarchy.

## Goals

- Remove shared atomic read-modify-write operations from normal count and exact
  probes.
- Allocate counter storage in proportion to functions actually touched by an
  execution context, not eagerly as `all functions * all workers`.
- Merge a consistent snapshot only after recording is paused.
- Emit versioned, parseable records with units and clock semantics.
- Preserve a concise human top-functions report as a derived output.
- Sort snapshots without mutating dense-ID storage.
- Report all loss, mismatch, and output failures.
- Make profiles joinable with compiler revision, binary hash, and symbol
  metadata.

## Non-Goals

- Do not build the native sampling adapter or top-level profile command.
- Do not emit protobuf directly from the C runtime.
- Do not retain full per-call traces or call stacks in this issue.
- Do not allocate a dense counter array for every possible native thread.
- Do not make reports from a signal handler.
- Do not let a reporting failure change ordinary program semantics without an
  explicit profile-command contract.

## Counter-Shard Design

Dense IDs make local arrays possible. Use a registered shard per runtime worker
or native thread that performs probes:

```c
typedef struct {
    uint64_t calls;
    uint64_t inclusive_ns;
    uint64_t self_ns;
} blorp_ProfileCounters;

typedef struct {
    size_t page_index;
    blorp_ProfileCounters counters[BLORP_PROFILE_COUNTERS_PER_PAGE];
} blorp_ProfileCounterPage;

typedef struct blorp_ProfileCounterShard {
    blorp_ProfileCounterPage **pages;
    size_t page_slots;
    struct blorp_ProfileCounterShard *next_registered;
} blorp_ProfileCounterShard;
```

Use a named page size chosen from measurement, not a bare literal repeated
through the implementation. A page contains consecutive dense IDs. The page
pointer table may be dense and small enough for the artifact, or itself grow
with the highest touched page. Allocate a page on first touch.

Registration may take a mutex once when a thread first creates its shard.
Page allocation may take the allocator on first touch. Runtime workers should
own their shards directly when possible; foreign/native threads use TLS shard
registration.

The steady-state counter update uses plain owner-local loads and stores, but
the reporter must have a C-memory-model synchronization proof before reading
them. Use a per-shard atomic write sequence:

```c
typedef struct blorp_ProfileCounterShard {
    _Atomic uint64_t write_sequence; /* even=quiescent, odd=owner committing */
    _Atomic bool owner_exited;
    /* owner-local page pointers and counters */
} blorp_ProfileCounterShard;
```

Each shard has exactly one writer. Before touching plain page/counter storage,
the owner sequentially-consistently publishes an odd `write_sequence`, then
sequentially-consistently loads the global recording-enabled state. If
recording is disabled it publishes the next even sequence without touching
counters. Otherwise it performs the local update and release-publishes the next
even sequence.

The reporter sequentially-consistently disables recording, captures the
registered shard list under its ownership mutex, then
sequentially-consistently loads every shard sequence until it is even. The
sequentially consistent control operations give only two valid orders: a
writer publishes odd and observes enabled before the reporter disables, in
which case the reporter's later sequence load must see odd or a later even
publication; or the reporter disables first, in which case a later writer must
observe disabled and touch no counters. When the reporter observes the final
release-published even value, its sequentially consistent load also supplies
the acquire edge that makes preceding plain counter writes visible. State these
exact memory orders in a comment beside the implementation and cover
adversarial interleavings in a native test.

This retains zero shared atomic read-modify-write operations in the normal
probe path. Per-shard atomic stores are permitted and are part of the measured
cost. If implementation evidence shows an atomic exchange is required for the
sequence, revise the performance claim rather than using plain unsynchronized
flags.

A registered shard remains owned by the profile manager until recording is
stopped and the final snapshot is complete. A foreign/native thread destructor
release-marks `owner_exited` but does not free or unlink storage that a reporter
may inspect. Runtime-worker shards follow the same lifetime even when their
worker exits. Final profiler teardown frees registered shards after all owners
are quiescent. This trades bounded-by-created-profile-thread retention for an
unambiguous no-use-after-free contract.

Do not attach aggregate counters to fibers. A fiber can update the current
carrier's shard because all shards are merged and counter ownership does not
affect call-stack identity. If the scheduler later allows migration, counts
remain correct. The fiber retains only its exact timing stack and logical active
clock from Issue 3.

### Snapshot protocol

Use the existing recording pause/epoch mechanism as the quiescence boundary:

1. acquire the profile snapshot/window mutex;
2. disable new recording;
3. sequentially-consistently observe every registered shard at an even write
   sequence, including count-only entry updates and exact end updates;
4. merge every registered shard into one dense snapshot;
5. collect diagnostics and metadata;
6. optionally reset shard pages and advance the epoch;
7. release the mutex; and
8. format/write the immutable snapshot outside hot execution.

Specify whether snapshot formatting can occur concurrently with resumed
recording. If yes, the immutable merged snapshot owns everything it references.
If no, document the bounded pause. Do not hold the registry mutex while doing
filesystem I/O.

For window reset, zero only allocated pages. Do not loop over an arbitrary
maximum or allocate untouched pages merely to clear them.

## Structured Output

Use newline-delimited JSON for the first native format. It is straightforward
to emit incrementally in C, inspect manually, parse in Python, and evolve by
adding fields. Every line has `kind` and `schema_version`.

Header example:

```json
{"kind":"profile_header","schema_version":1,"mode":"exact","clock":"scheduled_active_monotonic_ns","functions_described":12048,"functions_selected":412,"started_unix_ns":1789000000000000000,"duration_ns":4812000000,"build_id":"..."}
```

Function example:

```json
{"kind":"function","schema_version":1,"id":137,"logical_name":"scope_add_symbol","c_symbol":"brp_3i9","module_path":"compiler/stage_05_types/env","definition_id":418,"calls":1028721,"inclusive_ns":904120000,"self_ns":712330000}
```

Diagnostics example:

```json
{"kind":"profile_diagnostics","schema_version":1,"functions_observed":287,"calls_observed":0,"calls_completed":12004419,"unmatched_ends":0,"abandoned_frames":0,"stack_growth_failures":0,"records_lost":0,"output_failures":0}
```

Footer example:

```json
{"kind":"profile_end","schema_version":1,"records_written":289,"complete":true}
```

`calls_observed` is the count-only entry total. `calls_completed` is the exact
mode's valid completed-frame total. The exact field names may be refined once
tests own them, but the following are
normative:

- integer nanoseconds remain integers, not locale-formatted floats;
- every duration states its clock in the header;
- absent source identity is represented explicitly, not with a magic negative
  ID or empty path that could also be valid;
- JSON strings use one correct escaping helper;
- unknown future record kinds can be skipped by version-1 readers;
- a truncated stream lacks a complete footer and is not accepted as complete;
- loss/error counts are present even when zero; and
- sorting is a presentation concern, not the storage identity.

### Human report

Derive a table from the same immutable snapshot:

```text
Function                 Self ms  Self %  Inclusive ms    Calls  Self/call us
scope_add_symbol          712.33   14.2       904.12    1028721       0.692
```

The total and percentage denominator are the sum of self time. Label inclusive
time as overlapping. Calls mode prints calls and percentages of calls but no
fabricated timing columns.

Remove `FLAME:` output in this issue. Exact aggregate entries do not contain a
call hierarchy and must not claim to be collapsed stacks. Issue 5 provides real
sampled stacks.

## Output Destination And Failure

Define a low-level runtime output configuration that Issue 6 can expose:

```c
typedef struct {
    FILE *machine_stream;
    FILE *human_stream;
    bool close_machine_stream;
    bool close_human_stream;
} blorp_ProfileOutput;
```

Avoid opening arbitrary paths in a signal handler or at late `atexit` if the
high-level command can open destinations during initialization. Standalone
instrumented programs may continue to default the human report to stderr and
may opt into a machine path through an explicit generated configuration or
documented runtime API.

Check every write and flush. Set `complete=false` or omit the footer on failure,
increment `output_failures`, and return a profiler status to the owning command.
Do not append malformed JSON diagnostics after a partial JSON token.

## Implementation Steps

1. Add a native contention benchmark that exposes current atomic updates.
2. Define shard/page storage and ownership independently of report formatting.
3. Register one shard per worker/thread and update count-only probes locally.
4. Update exact completion to write local inclusive/self/call counters.
5. Implement quiescent merge/reset and test concurrent workers.
6. Add foreign-thread exit and final profiler-teardown coverage.
7. Delete global per-call atomic counters.
8. Define version-1 NDJSON records and a strict test parser.
9. Produce human and machine reports from one immutable snapshot.
10. Delete the flat `FLAME:` rows and overlapping inclusive `TOTAL`.
11. Add output-error seams and truncated-stream tests.
12. Measure local-page allocation, probe overhead, snapshot pause, and total
    report time separately.

## Tests

### Shard correctness

Cover:

- one root thread and zero workers;
- one worker, many calls;
- many workers updating the same function ID;
- fibers moving among call sites while using carrier-local shards;
- first-touch page allocation at page boundaries;
- untouched functions allocate no page;
- repeated window reset;
- snapshot while workers are approaching the pause boundary; and
- shard registration/teardown during runtime shutdown;
- a writer that publishes odd immediately before recording is disabled;
- a writer that begins after recording is disabled; and
- a foreign thread that exits before the final report.

Use deterministic expected call totals. Run the race/concurrency fixture often
enough to exercise the boundary, but do not use timing sleeps as synchronization.

### Format tests

Parse every emitted line and assert:

- exact schema version and record kind;
- stable metadata identity;
- integer units;
- `0 <= self_ns <= inclusive_ns`;
- self total equals the reported denominator;
- duplicate logical names remain separate IDs;
- zero-valued loss fields are present;
- calls mode has no timing interpretation;
- invalid UTF-8 policy is explicit if arbitrary source bytes can reach names;
- every complete stream has exactly one header, diagnostics record, and footer;
  and
- simulated short write/flush failure does not claim completeness.

### Lifecycle tests

Preserve ordinary exit, explicit report, profile-window end, SIGINT, SIGTERM,
and writer-failure behavior. A second report must not duplicate counters unless
the API explicitly requests another snapshot.

## Fast Feedback Loop

Build and run a standalone native shard test first. It should not compile Blorp
source. Then:

```bash
scripts/test runtime
bin/blorp test blorp/test/compiler/stage_10_backend/test_core_emit.brp
blorp/test/cli/test_cli.sh --smoke --timeout 30
scripts/test leak
```

Use a short Python parser in the owning test to validate NDJSON; do not validate
JSON with regular expressions. Inspect one report manually with:

```bash
python3 -m json.tool <first-record.json
```

Before review:

```bash
make
scripts/test compiler-blorp runtime leak cli
scripts/test compiler-core-sanitize
make quality
```

Then run the shared alternating measurement protocol.

## Measurement Plan

For off, calls, and exact modes, record:

- wall time and retired instructions;
- completed calls;
- shared atomic read-modify-write count in the parent and candidate;
- shard registrations and page allocations;
- bytes allocated for all shards;
- snapshot pause duration;
- merge duration;
- serialization duration; and
- output size.

Steady-state candidate probes must perform zero shared atomic
read-modify-write operations. The local-shard candidate must outperform the
atomic parent on the multi-worker hot-function benchmark and must not regress a
single-worker compiler profile materially. If page allocation dominates a
short workload, report it separately rather than hiding it inside probe time.

## Acceptance Criteria

- [ ] Count and exact probes update only local steady-state counter storage.
- [ ] No shared atomic read-modify-write remains per completed function call.
- [ ] Per-shard write sequencing gives the reporter a sequentially consistent
      control order and acquire/release happens-before edge before it reads
      plain counters.
- [ ] A shard from an exited native thread remains valid until final profiler
      teardown.
- [ ] Storage is lazy and does not eagerly allocate `functions * threads`
      counters.
- [ ] Snapshot/reset has an explicit quiescence protocol and deterministic
      totals.
- [ ] All allocated shards and pages have covered shutdown ownership.
- [ ] Version-1 NDJSON states mode, clock, units, build identity, function
      metadata, counters, and loss diagnostics.
- [ ] A complete stream is mechanically distinguishable from a truncated one.
- [ ] Human output is derived from the same snapshot and uses self time for its
      percentage denominator.
- [ ] Calls mode does not print timing values.
- [ ] Misleading flat `FLAME:` rows and inclusive `TOTAL` are removed.
- [ ] Writer failures are observable and do not deadlock exit or signal paths.
- [ ] Single- and multi-worker overhead plus snapshot cost are measured.
- [ ] Focused, runtime, leak, sanitizer, CLI, compiler, and quality owners pass.

## Pitfalls And Review Questions

- Does a first call on every ID allocate independently rather than by page?
- Is shard registration accidentally repeated after every fiber resume?
- Can the reporter merge a shard while its owner is writing?
- Does resetting counters allocate untouched pages?
- Is the sort performed on pointers/snapshots rather than the ID-indexed source?
- Are 64-bit totals allowed to wrap silently on long-running processes?
- Can JSON escaping allocate recursively or call profiled functions?
- Does reporting itself get instrumented and contaminate the snapshot?
- Are output failures written through the same failed stream?
- Is an `atexit` report trying to use destroyed worker/shard storage?

This issue is incomplete if atomics are merely relaxed or batched while a
shared counter remains on every normal exit.
