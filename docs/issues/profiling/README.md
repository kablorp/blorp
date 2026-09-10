# Profiling Capability Roadmap

**Status:** Ready for incremental implementation

**Created:** 2026-09-09

**Repository baseline inspected:** `6082deaa2ed685485b470d024e61c6bc101f6016`

## Objective

Make profiling a routine, trustworthy part of Blorp development while reducing
the observer effect of the profiler itself.

The intended result is not one profiler mode that attempts to answer every
question. Blorp should provide a small profiling ladder:

| Question | Primary mechanism | Intended cost |
| --- | --- | ---: |
| Which code consumes CPU? | Statistical stack sampling | Low |
| How often is a function called? | Count-only function probes | Low |
| How does active time divide between parents and children? | Selective exact function timing | Moderate |
| Where are fibers blocked, scheduled, allocating, or retaining? | Bounded event recording | Low when selectively configured |

Phase timing remains the cheapest first step. Sampling becomes the normal way
to rank CPU work. Exact probes remain available when call counts, a narrow
measurement window, or a focused parent/child decomposition is required.

## Why This Roadmap Exists

The current function profiler is useful for small focused benchmarks, but its
representation does not scale to the compiler itself:

- `BLORP_PROFILE_MAX_FUNCS` fixes the registry at 1,024 entries;
- later function registrations are silently discarded;
- a 128-slot thread-local cache maps name pointers to entries;
- a cache miss takes a global mutex and performs a linear `strcmp` scan;
- each completed function call performs two clock reads and shared atomic
  counter updates;
- the active call stack has a separate silent 4,096-frame ceiling;
- names, rather than emitted function identity, are the registry key;
- reported percentages sum overlapping inclusive times; and
- `FLAME:` rows contain a single function rather than a sampled call stack.

The implementation is in
`blorp/src/lib/runtime/native/runtime.c`, under `Function Profiling`. Probe
emission is in `blorp/src/compiler/stage_10_backend/emit.brp`, beginning at
`emit_profile_runtime_setup` and `emit_profile_start`.

The limit is already below normal compiler scale. The retained
`logs/compiler-self-profile-current/profile-map/symbols.tsv` capture contains
11,090 mapped source functions, and its exact-count join contains 6,422 source
functions with nonzero calls. Those artifacts are historical selection
evidence, not a current acceptance baseline, but they establish that a fixed
1,024-entry registry cannot represent a whole-compiler profile.

The current interface is also ambiguous:

```text
blorp compile --profile input.brp
```

instruments the program being produced. It does not profile the compiler that
is compiling `input.brp`. Compiler phase timing uses `--time-phases`, while a
complete compiler CPU profile currently requires locally assembled scripts,
native sampling, a separately generated instrumented artifact, symbol scraping,
and post-processing.

## External Design Guidance

This roadmap adapts concepts rather than copying an implementation:

- [LLVM XRay](https://llvm.org/docs/XRay.html) separates compiler-emitted
  function IDs and instrumentation points from runtime activation, and supports
  selecting which functions are instrumented. Blorp should adopt dense IDs and
  selection, without making XRay or Clang a required runtime dependency.
- [PEP 669](https://peps.python.org/pep-0669/) makes monitoring events
  selectable globally or per code object and explicitly recommends statistical
  profiling unless exact event counts are needed. Blorp should not pay exact
  entry/exit cost to answer an ordinary CPU-hotspot question.
- [Go `runtime/pprof`](https://pkg.go.dev/runtime/pprof) makes CPU profiling a
  bounded, buffered sampling operation and propagates labels with logical
  execution contexts. Its runtime records lost samples instead of silently
  presenting an incomplete profile.
- [Java Flight Recorder](https://docs.oracle.com/en/java/javase/24/jfapi/flight-recorder-configurations.html)
  uses selectable event configurations and bounded local buffering for a
  low-overhead continuous mode.
- The [pprof profile schema](https://github.com/google/pprof/blob/main/proto/profile.proto)
  demonstrates a durable separation between samples, locations, functions,
  mappings, labels, units, periods, and human-readable names.

## Intended End State

```text
cheap phase timings
        |
        +--> optimized native CPU sampling
        |      compact C symbol -> Blorp identity sidecar
        |      real stacks, flat and cumulative views
        |
        +--> count-only probes
        |      one dense-ID increment per selected call
        |
        +--> exact selected timing
        |      fiber-local stack
        |      scheduled-active inclusive and self time
        |      worker-local counter shards
        |
        +--> bounded event recorder
               phases, scheduling, waits, allocations, ARC counters
               explicit lost-event accounting

all modes
        |
        v
versioned artifact bundle + human summary + standard-format conversion
```

No normal non-profiled program contains a probe, metadata table, counter
allocation, or runtime branch solely for profiling.

## Issues

1. [Replace name registration with dense profile function IDs](01-dense-profile-function-ids.md)
2. [Introduce explicit count, exact, and selective instrumentation modes](02-profile-modes-and-selection.md)
3. [Make exact timing fiber-correct and report self time](03-fiber-correct-exact-timing.md)
4. [Move exact counters to local shards and define structured output](04-local-aggregation-and-output.md)
5. [Make optimized native sampling and symbolization first-class](05-native-sampling-and-symbol-maps.md)
6. [Add one coherent profiling command and reproducible artifact bundle](06-unified-profile-command.md)
7. [Build a bounded event recorder and standard-format exporters](07-bounded-event-recorder.md)

Issues 1–6 are near-term work. Issue 7 is the longer-term direction and must
not delay the first six.

## Dependency And Integration Order

```text
Issue 1: dense IDs
      |
      +--> Issue 2: modes/selection ---+
      |                                +--> Issue 4: local shards/output --+
      +--> Issue 3: fiber/self time ---+                                  |
                                                                          +--> Issue 6
Issue 5: native sampling/symbol maps -------------------------------------+       |
                                                                                  v
                                                                    Issue 7: event recorder
```

Issue 5 may begin independently. Its final symbol-sidecar integration can
rebase over Issue 1 so both exact and sampled profiles use one metadata model.
After Issue 1 establishes the runtime ABI, Issues 2 and 3 can proceed in
parallel if their owners agree on that ABI before editing. Issue 4 follows both:
it merges count-only counters from Issue 2 and exact counters from Issue 3.
Issue 6 integrates the stable mechanisms. Issue 7 begins only after the normal
user workflow is established.

Do not implement this roadmap as one branch. Every issue has an independent
correctness boundary, measurement result, review, and rollback point.

## Final Semantic Contract And Transitional Obligations

The completed roadmap preserves these rules. An earlier issue that has not yet
implemented the final mechanism must still expose every retained limit or loss
condition it can observe. It may use a transitional text diagnostic before the
structured schema lands, but it may not print a fabricated zero or silently
discard data.

1. Profiling is observational. Except for elapsed time and scheduling effects,
   it must not change program output, diagnostics, exit status, ownership, or
   cleanup behavior.
2. Function identity is compiler-provided identity. Runtime string spelling,
   compact C names, source names, and display names are metadata, not keys.
3. No profiler resource limit fails silently. Every dropped sample, event,
   frame, registration, or output record is counted and reported.
4. A profile states its clock and semantics. Scheduled-active time, process CPU
   time, thread CPU time, and wall time must never share an unlabeled `time`
   column.
5. Inclusive values may overlap. Only self values or samples that explicitly
   partition work may be used as a percentage denominator.
6. Function profiles and timeline traces are distinct products. Blocking wall
   latency must not masquerade as CPU self time.
7. Beginning or ending a profile window has defined behavior for calls crossing
   the boundary. Epoch changes cannot leak stale frames into a new window.
8. Signals and cancellation remain safe. A signal handler requests a report or
   termination; it does not allocate, lock, symbolize, or serialize.
9. Source order and final emitted-function order remain deterministic. A hash
   table must not choose profile IDs or output order.
10. Normal builds have zero profiling runtime overhead and do not carry profile
    metadata unless an explicit symbol-map or profiling option requests it.

## Shared Measurement Contract

### Build authority

Measure the compiler implementation with a compiler executable built from the
candidate source. Merely compiling candidate source using an unchanged
`bin/blorp` does not measure the candidate compiler.

For baseline and candidate:

- record the Git revision and dirty status;
- record the Blorp executable SHA-256;
- record the pinned bootstrap version;
- record the host C compiler and exact optimization/debug flags;
- use the same source tree, standard library, worker count, and environment;
- retain the workload's exit status and output SHA-256; and
- keep generated C and profile artifacts outside the repository unless a
  checked-in fixture explicitly owns them.

### Workloads

Every profiling-runtime change uses all three levels:

1. A native microbenchmark that calls an empty instrumented leaf often enough
   to expose probe cost.
2. A nested/recursive/concurrent Blorp fixture that establishes semantic
   correctness.
3. Optimized compiler self-compilation through C emission:

```bash
<compiler> compile --no-format --no-embed-runtime --time-phases \
  -o "$temporary_output" blorp/src/main.brp
```

When an issue concerns only the frontend, use the maintained Stage 06 workload
as an additional diagnostic, not as a replacement for the whole-compiler run.

### Timing protocol

- Run one explicit warmup that is not included in the result.
- Run at least seven alternating baseline/candidate pairs.
- Use ten pairs when the median change is below 2%.
- Report every raw wall-time sample, median, median absolute deviation, and
  range.
- When available on the host, record retired instructions and CPU cycles.
- Report profiler overhead as `(profiled - plain) / plain` using identically
  optimized binaries.
- Do not compare an `-O0` exact profile with an `-O2` unprofiled executable and
  attribute the whole difference to instrumentation.

Memory is diagnostic rather than the primary acceptance gate, but retained
bytes must still be reported when a design changes storage proportional to
`functions * workers`, stack depth, or event-buffer capacity.

### Stable counters

As their owning issues land, the structured profile reports at least:

```text
functions_described
functions_selected
functions_observed
calls_observed
calls_completed
unmatched_ends
abandoned_frames
stack_growth_failures
records_lost
output_failures
```

`calls_observed` means count-only entry observations; `calls_completed` means
exact frames that reached a valid end. A mode may report zero for an
inapplicable field, but may not omit a loss field whose value is unknown. Before
Issue 4 introduces the structured stream, Issues 1–3 expose newly observable
loss through a transitional parseable diagnostic. Tests parse these fields
rather than relying only on a human-readable table.

The delivery sequence is:

| Issue | Minimum new completeness evidence |
| --- | --- |
| 1 | described/observed functions, invalid IDs, and retained fixed-stack overflow |
| 2 | selected functions, count-mode entries, and count-mode signal delivery |
| 3 | dynamic-stack growth failure, unmatched ends, and abandoned frames |
| 4 | complete versioned schema containing every common diagnostic |
| 5 | sampled, truncated, lost, and unmapped native records |

## Shared Fast-Feedback Loop

Use this order during each issue:

1. Run the narrow native runtime or backend emitter test that demonstrates the
   missing behavior.
2. Implement only the representation/API slice necessary for that test.
3. Run the focused backend suite:

```bash
bin/blorp test blorp/test/compiler/stage_10_backend/test_core_emit.brp
```

4. Run the CLI profile fixtures that own generated-C and lifecycle behavior:

```bash
blorp/test/cli/test_cli.sh --smoke --timeout 30
```

5. Run one small profiled program and inspect its generated C and structured
   result directly.
6. Run the issue-owned overhead microbenchmark.
7. Build the candidate compiler and perform one self-compilation smoke run.
8. Only after the design is stable, run the alternating measurement protocol.
9. Before review, run the compiler, runtime, leak, CLI, and quality owners that
   the issue names. Do not use the broad gate as the inner development loop.

If a command name changes while the roadmap is being implemented, use the
current owning test or Make target and update the issue document in the same
change.

## Roadmap-Level Acceptance

The near-term roadmap is complete when:

- there is no fixed maximum number of profiled functions;
- a whole-compiler exact profile reports every observed function or an explicit
  failure, never a silent partial result;
- ordinary hotspot discovery uses optimized statistical sampling;
- exact profiles distinguish self and inclusive scheduled-active time;
- concurrent fibers cannot corrupt one another's profile stacks;
- count-only mode avoids exit probes and clock reads;
- hot exact counter updates require no shared atomic read-modify-write;
- one command produces a reproducible compiler profile bundle on supported
  macOS and Linux hosts;
- profile artifacts use versioned machine-readable records and include loss
  diagnostics; and
- the existing misleading flat `FLAME:` output has been removed or replaced by
  real stacks.

After those conditions hold, capture a new optimized whole-compiler profile.
That new profile—not historical exact-probe rankings—becomes the baseline for
compiler latency work.
