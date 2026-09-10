# Build A Bounded Event Recorder And Standard-Format Exporters

**Status:** Long-term strategy; do not start before Issues 1–6 establish the
normal profiling workflow

**Roadmap dependencies:** Fiber-aware execution identity, local aggregation,
symbol maps, and the unified profile command

## Issue Summary

Add a bounded, selectively configured runtime event recorder for questions
that CPU samples and aggregate function counters cannot answer: phase
transitions, fiber scheduling, blocking latency, cancellation, allocation,
reference-count traffic, and other time-ordered behavior.

The recorder uses fixed-capacity thread/worker-local buffers, compact numeric
event IDs, explicit loss accounting, and offline conversion. It is inspired by
Java Flight Recorder and .NET EventPipe, but remains a small Blorp-owned system
suited to ahead-of-time native programs and the existing runtime.

This is not a prerequisite for removing the 1,024-function limit or making
ordinary compiler profiles useful. It is the architectural destination after
the near-term roadmap proves the data model and workflow.

## Why Aggregate Profiles Are Not Enough

A function profile can establish that a channel receive accumulated time, but
cannot distinguish:

- actively scanning a queue;
- parked waiting for data;
- delayed because no worker was available;
- awakened repeatedly without progress;
- cancelled after an external event; or
- waiting behind a contended runtime lock.

Likewise, a total allocation counter cannot show which compiler phase produced
a burst, whether releases lagged into a later phase, or whether one fiber's
work caused another's latency.

These are temporal questions. Encoding them as more function counters would
create misleading answers and permanent hot-path overhead.

## Goals

- Record selected runtime/compiler events with timestamps and logical context.
- Keep recorder memory bounded by explicit configuration.
- Perform no global locking or filesystem I/O on the normal event hot path.
- Represent event types and payloads with numeric IDs and a metadata table.
- Preserve worker, native thread, fiber/task, compiler phase, and module labels
  where available.
- Report lost events by buffer and event category.
- Allow duration thresholds and sampling rates for high-frequency events.
- Dump on normal completion, explicit request, or a safe deferred signal path.
- Convert offline to Chrome Trace Event JSON or Speedscope for timelines and to
  pprof for applicable stack/count profiles.
- Keep default continuous configuration at acceptably low measured overhead.

## Non-Goals

- Do not record every retain/release or allocation by default.
- Do not make the recorder an always-on production telemetry uploader.
- Do not allocate on every event.
- Do not serialize JSON/protobuf in the application hot path.
- Do not call symbolizers from signal handlers or workers recording an event.
- Do not make event ordering across independent threads appear stronger than
  the monotonic timestamps and synchronization facts support.
- Do not replace leak checking, exact function counts, or native CPU sampling.
- Do not add arbitrary user payload strings in the first slice.

## Event Configuration Model

Use explicit event groups and thresholds:

```blorp
union ProfileEventGroup:
    ProfileCompilerPhases
    ProfileScheduler
    ProfileBlocking
    ProfileAllocationSamples
    ProfileArcCounters
    ProfileCancellation
    ProfileUserSpans

struct ProfileEventConfig {
    groups: Set[ProfileEventGroup],
    buffer_bytes_per_worker: Int,
    blocking_threshold_ns: Int,
    allocation_sample_bytes: Int,
}
```

The runtime C representation may be bitsets and integer thresholds, but parse
into a precise Blorp model first. Give every default a named constant and
document its measurement source.

Provide at least two named configurations:

```text
default     compiler phases, scheduler lifecycle, long blocking events
detailed    adds shorter waits and sampled allocation/ARC information
```

`default` is suitable for repeated compiler investigation. `detailed` is an
explicit higher-overhead diagnostic. Users can further select groups. Do not
add a boolean per event that permits contradictory or unsupported combinations.

## Event Schema

Use a compact fixed header and event-specific fixed payloads where possible:

```c
typedef struct {
    uint64_t timestamp_ns;
    uint32_t event_id;
    uint32_t payload_bytes;
    uint32_t worker_id;
    uint32_t thread_id;
    uint64_t fiber_id;
} blorp_ProfileEventHeader;
```

The sketch is not a mandated ABI. Measure alignment and use explicit versioned
encoding. Avoid native struct dumping when padding, endianness, or word size
would make files nonportable.

Event metadata defines:

```text
event_id
name
category
version
payload field names and units
```

First event families:

```text
compiler_phase_begin/end       phase_id, compilation_id
fiber_created/completed        fiber_id, parent_id
fiber_resumed/suspended        fiber_id, worker_id, reason
wait_begin/end                 wait_id, owner_kind, wake_cause
cancellation_requested/seen    task_id, cause
allocation_sample              type_id, bytes, function_id
arc_interval_counters          retains, releases, arc_only_releases
profile_window_begin/end       epoch, configuration_id
lost_events                    category, count
```

Pair begin/end events with explicit correlation IDs. Do not match them offline
using names, timestamps, or “nearest event” heuristics. Reuse existing exact
wait-operation IDs and task/fiber identities where they are authoritative.

## Buffering Architecture

Each worker or registered native thread owns a bounded ring/chunk buffer. A
normal event append:

1. checks one cached enabled-category bit;
2. verifies payload capacity;
3. writes a compact header and payload into local memory; and
4. advances the local cursor.

It does not acquire a global lock, allocate, symbolize, or write a file.

When a buffer fills, choose and document one policy per configuration:

- continuous/ring mode overwrites the oldest complete records and increments a
  lost count; or
- finite/stop mode disables that buffer and increments a dropped count.

Do not block the application waiting for an exporter. Never overwrite a partial
record. Use sequence numbers or committed cursors so the snapshotter can detect
torn records.

At an explicit snapshot boundary, pause or handshake with writers, copy/flush
complete chunks, merge metadata and loss counters, and resume. For a continuous
recording, an optional background drain thread may move complete chunks to a
global bounded queue, but only after measurement proves simple end-of-run
snapshotting insufficient.

## High-Frequency Event Policy

### Allocation

Record sampled allocation bytes rather than every object by default. A simple
per-worker byte budget can trigger a sample after approximately N allocated
bytes. Preserve the sampled weight so offline reports estimate total allocation
space. Exact allocation/object counts remain available from existing allocator
statistics in dedicated diagnostic runs.

### ARC

Do not write one event for every retain/release. Maintain local counters by
profile window, function, or coarse phase and periodically emit a counter event.
A detailed debug mode may trace a bounded selected type/function, but must use
explicit selection and loss reporting.

### Blocking

Create a correlation record at wait begin only in local state. Emit the complete
wait interval at end when its duration crosses the configured threshold, or
when cancellation/error makes the wait semantically important. This avoids
recording vast numbers of short successful waits in the default configuration.

### Compiler phases and user spans

These are low frequency and may be recorded exactly. Nested spans carry IDs and
parent IDs, not a global implicit stack shared among fibers.

## Time And Ordering

Use one monotonic clock domain per process and record its identity in the file
header. A timestamp orders events observed by that clock but does not by itself
prove a happens-before relationship across threads.

For fiber activity, record both resume/suspend events and the exact profiler's
scheduled-active counters. Offline tools may derive:

- wall span duration;
- scheduled-active duration;
- parked duration;
- runnable-but-not-running delay; and
- carrier worker changes.

Do not subtract durations based on missing events when loss counters are
nonzero. Mark derived intervals incomplete.

## Raw Format And Exporters

Write a compact versioned binary stream for runtime events, plus a small JSON
manifest. The format contains:

- magic and schema version;
- endianness/word-size-independent integer encoding;
- clock and start-time metadata;
- event and function/type metadata tables;
- one or more worker/thread event chunks;
- per-chunk sequence/loss fields; and
- a completion footer/checksum.

Keep encoding simple enough for a strict standalone parser. Fuzz or property
test malformed lengths, unknown event versions, truncated chunks, and checksum
failure.

Offline exporters produce:

- Chrome Trace Event JSON for phase/fiber/wait timelines;
- Speedscope evented profiles where the data describes nested spans;
- pprof for CPU/allocation/count samples with appropriate units and labels;
- TSV summaries for compiler phase, blocking cause, allocation type, and worker
  utilization; and
- a concise human report.

Do not force temporal events into pprof when a timeline is the correct model.
Conversely, do not expand aggregate samples into fabricated timestamped events.

## Signal And Failure Behavior

SIGINT/SIGTERM handlers set an atomic dump/termination request only. A safe
runtime checkpoint performs the snapshot and then restores termination
semantics. Fatal signals for which runtime continuation is unsafe may leave an
incomplete last chunk; earlier committed chunks and the missing completion
footer make the partial status explicit.

Output open/write/full-disk failures disable further draining, increment
diagnostics, and preserve program cleanup. The `blorp profile` command reports
collector failure separately from target exit, following Issue 6.

## Implementation Tranches

### Tranche A: format and low-frequency compiler phases

- Define event IDs, raw file header/chunks/footer, and strict parser.
- Record exact compiler phase begin/end and profile-window events.
- Add Chrome Trace export and manifest integration.
- Establish overhead and corruption tests.

This tranche must merge independently and should have negligible event volume.

### Tranche B: scheduler and fiber lifecycle

- Record create, resume, suspend, park, wake, completion, and cancellation.
- Use existing fiber/task/wait-operation IDs.
- Derive active, parked, and runnable-delay summaries.
- Validate single- and multi-worker ordering.

### Tranche C: thresholded blocking

- Add exact wait correlation.
- Emit only intervals crossing a configured threshold or significant terminal
  cause.
- Summarize by wait owner and wake cause.

### Tranche D: sampled allocation and coarse ARC counters

- Add weighted allocation sampling with type/function identity.
- Add interval ARC counters rather than per-operation events.
- Export applicable profiles to pprof and verify weights/units.

Do not combine the tranches into one review. Reprofile overhead after each and
stop if the next family does not provide decision-quality information.

## Tests

### Buffer and format

Cover:

- exact fit, wrap, and one-byte-short records;
- overwrite and finite-stop policies;
- concurrent independent buffers;
- committed versus partial records;
- sequence gaps and loss counts;
- unknown event/category versions;
- truncated header, payload, chunk, and footer;
- checksum mismatch;
- output failure; and
- deterministic metadata ordering.

### Scheduler semantics

Use deterministic channels/barriers to produce known event sequences for one
and multiple workers. Assert IDs and causal pairs, not exact timestamp gaps.
Cover fiber recycling, timeout, cancellation, join, channel, I/O, and shutdown.

### Exporters

Parse exported JSON/profile formats with their standard validators where
available. Assert units, sample weights, labels, stack order, and incomplete
markers. Round-trip a small raw fixture and compare its semantic event list.

### Profiling interaction

Run phase timing, CPU sampling, count-only, exact timing, and event recording in
supported combinations. Either define combined behavior or reject it clearly.
Ensure exact fiber stacks and event correlation use the same logical fiber
identity.

## Fast Feedback Loop

Build the raw buffer/format as a standalone native unit first. A single event
round-trip should not rebuild the compiler. Then add one low-frequency compiler
phase event and run:

```bash
bin/blorp compile --no-format --time-phases \
  -o "$temporary_c" blorp/test/runtime/types/test_bool.brp
scripts/test runtime
scripts/test leak
```

For scheduler tranches, use the narrow runtime concurrency fixtures before the
full runtime gate. For export tranches, use checked-in tiny raw fixtures and
pure offline conversion tests.

Before each tranche review:

```bash
make
scripts/test compiler-blorp runtime leak cli
scripts/test compiler-core-sanitize
make quality
```

Run the shared alternating compiler self-compilation protocol only after the
tranche's local counters and output invariants pass.

## Measurement Plan

For every tranche compare recorder off, default configuration, and the new
detailed group. Record:

- wall time and retired instructions;
- target and recorder CPU time where separable;
- event attempts, committed events, bytes, wraps, and losses;
- events and bytes by category;
- buffer allocation and retained bytes per worker;
- maximum snapshot pause and total serialization time;
- output bytes and compression ratio if compression is introduced; and
- semantic output hash.

The default low-frequency configuration must target no more than 2% median
compiler self-compilation overhead. Detailed configurations report measured
cost without pretending to be continuous-low-overhead modes. Reject a default
event family that exceeds the target unless reducing frequency/thresholds
restores it without destroying usefulness.

## Acceptance Criteria

- [ ] Event types, configuration, units, and payloads are versioned and
      explicit.
- [ ] Runtime event buffers are bounded and local to workers/threads.
- [ ] The normal event append performs no global lock, allocation, filesystem
      I/O, or symbolization.
- [ ] Buffer exhaustion and every other loss mode are counted and exported.
- [ ] Compiler phases and scheduler/wait identities use exact IDs rather than
      name/timestamp matching.
- [ ] Default configuration records only low-frequency or thresholded events.
- [ ] Allocation events are weighted samples; ARC defaults to counters rather
      than per-operation traces.
- [ ] Signals request a safe deferred dump rather than serializing in a handler.
- [ ] Raw files expose truncation and completeness unambiguously.
- [ ] Chrome Trace/Speedscope and pprof are used only for data that fits their
      semantics.
- [ ] The unified profile bundle records configuration, losses, and exporter
      status.
- [ ] Default overhead is measured at no more than the accepted 2% target.
- [ ] Each tranche independently passes runtime, leak, sanitizer, CLI, quality,
      and semantic-output checks.

## Pitfalls And Review Questions

- Did “bounded” become a silent fixed cap with no lost-event record?
- Does every event take a global atomic increment or mutex despite local
  buffers?
- Are variable strings copied into hot buffers rather than represented by IDs?
- Can a partial record be mistaken for a valid next header after wrap?
- Does the exporter invent causal pairing from nearest timestamps?
- Are high-frequency retains/releases enabled in the default configuration?
- Does allocation sampling omit the weight needed to estimate bytes/counts?
- Can a signal interrupt a writer and expose an uncommitted cursor?
- Is a large buffer multiplied by every potential function and worker?
- Are temporal events forced into a flat profile, or aggregate samples into a
  fake timeline?

This issue succeeds only if the recorder provides information that changes a
performance decision while remaining bounded, explicit about loss, and cheap
enough for its named configuration.
