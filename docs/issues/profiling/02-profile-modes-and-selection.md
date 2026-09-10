# Introduce Explicit Count, Exact, And Selective Instrumentation Modes

**Status:** Implemented

**Roadmap dependency:** Dense profile function IDs

**Can proceed in parallel with:** Issue 3 after the dense-ID ABI is fixed

## Issue Summary

Replace the Boolean `profile` option with an explicit instrumentation model and
allow developers to select functions using compiler-owned module and function
identity.

The first production modes are:

```text
off
calls
exact
```

`calls` emits one entry probe and no exit probe, clock read, or call-stack
operation. `exact` emits balanced entry/exit probes and is intended primarily
for selected functions or focused benchmarks. Statistical CPU sampling is
integrated in Issues 5 and 6; it is not an emitted-C function mode.

## Motivation

The current Boolean reaches compile, run, test, the pipeline, and the backend.
It instruments every supported function in the artifact. This couples three
independent choices:

1. whether instrumentation exists;
2. what measurement is collected; and
3. which functions pay the cost.

Exact call counts do not need a timer or exit probe. A Stage 06 investigation
does not need exact instrumentation in the standard library, runtime wrappers,
formatter, CLI, and all Core passes. Making those choices explicit is the
largest near-term reduction in exact-profiler observer effect after dense IDs.

Selective monitoring is established practice. PEP 669 exposes events per code
object and advises tools to enable the least frequent event set that answers
the question. LLVM XRay supports always/never function selection independently
of its runtime logging modes. Blorp can provide the same property with a much
simpler ahead-of-time compiler-owned plan.

## Goals

- Represent profiling mode as a precise variant rather than a Boolean.
- Make count-only probes substantially cheaper than exact timing.
- Select modules and exact functions before C text rendering.
- Report the described, selected, and actually observed inventories.
- Give invalid or ambiguous selectors an actionable compile error.
- Keep selection independent of compact C symbol spelling.
- Preserve deterministic metadata and probe placement.
- Make the generated artifact state its profile mode.

## Non-Goals

- Do not implement native sampling in this issue.
- Do not add source-line instrumentation, branch coverage, or arbitrary regular
  expressions.
- Do not infer likely hot functions from body size or names.
- Do not introduce a magic instruction-count threshold.
- Do not implement runtime patching or a permanent branch in every normal
  function.
- Do not add per-call argument or return-value logging.
- Do not retain the Boolean option as a second production path.

## Implemented Configuration Types

Use variants at the CLI boundary and preserve them through the compile plan:

```blorp
enum FunctionProfileMode:
	FunctionProfileOffMode
	FunctionProfileCallsMode
	FunctionProfileExactMode

union FunctionProfileSelector:
	ProfileModule(module_path: String)
	ProfileFunction(module_path: String, function_name: String)

union FunctionProfileConfiguration:
	FunctionProfileOff
	FunctionProfileCalls(List[FunctionProfileSelector])
	FunctionProfileExact(List[FunctionProfileSelector])
```

The configuration union makes selectors impossible in off mode. An empty
selector list means all eligible emitted functions, so a separate all-functions
selector is unnecessary. The benchmark JSON bridge retains its existing
Boolean wire field and immediately converts it to exact-all or off; no
production compile, pipeline, artifact, or backend API retains Boolean profile
state.

The profile emission plan from Issue 1 becomes:

```blorp
struct ProfileEmissionPlan {
    mode: FunctionProfileMode,
    described_functions: List[ProfileFunctionMetadata],
    selected_functions: List[ProfileFunctionMetadata],
}
```

The selector resolves against logical module identity and the source/logical
function name carried by the projected program. It must not match compact C
symbols such as `brp_3i9`, nor search raw rendered C.

### Selector syntax

Start with structured repeatable flags:

```text
--profile-mode calls
--profile-mode exact
--profile-module compiler/stage_06_typecheck/infer
--profile-function compiler/stage_05_types/env::scope_add_symbol
```

An empty selector list means all eligible functions for backward-equivalent
explicit instrumentation. Once any selector is present, selection is the union
of those selectors. Exact duplicate selectors are harmless and coalesced by
function identity.

Do not begin with an unrestricted regex engine. A later convenience glob can
compile to the same structured selector result, but exact module/function
selection is sufficient to establish semantics and avoids platform-dependent
matching.

### Existing `--profile`

Blorp is pre-0.1 and should prefer a coherent interface over a permanent alias.
Issue 6 owns the final public `blorp profile` command. During this issue,
production compile/run/test call sites may temporarily accept `--profile` as
the spelling for `exact + all` only if that is necessary to keep the branch
bisectable. The alias must be removed when Issue 6 lands; do not add a warning,
environment switch, or indefinite compatibility layer.

## Generated C Semantics

Off:

```c
/* no profile metadata, setup, probe, or branch */
```

Calls:

```c
blorp_profile_count_id(137);
/* body */
```

Exact:

```c
blorp_profile_start_id(137);
/* body */
blorp_profile_end_id(137);
```

The count-only runtime operation must not:

- read a clock;
- push or pop a profile frame;
- install an exit probe;
- compare IDs against a stack; or
- update an inclusive/self-time field.

It must retain the profiler's safe deferred-termination polling contract. Today
`blorp_profile_enable` installs SIGINT/SIGTERM handlers and
`blorp_profile_start`/`blorp_profile_end` call
`blorp_profile_maybe_terminate`. Therefore `blorp_profile_count_id` must call
that safe poll unless the change moves termination polling to a separately
named runtime checkpoint that is guaranteed and tested for CPU-bound
count-profiled programs. A cheaper counter probe may not consume SIGINT or
SIGTERM indefinitely.

Initially it may use the same atomic entry counter established in Issue 1.
Issue 4 moves it to local shards.

The metadata table contains only selected instrumented functions for the
function profile. A broader native symbol sidecar may contain unselected
functions, but it is a separate product with explicit counts.

## Error Semantics

Reject before C emission:

- an unknown profile mode;
- a function selector without a module owner;
- an unknown module;
- an unknown function in a known module;
- an ambiguous spelling when overload/specialization identity cannot be
  selected precisely; and
- selectors supplied while mode is `off`.

Every error should state the rejected selector and show the accepted spelling.
For overloads or specializations, either select every emitted specialization of
the source definition and say so explicitly, or extend the selector grammar
with a stable compiler-owned specialization discriminator. Do not choose one by
list position or compact C suffix.

Generated helpers without source-level names may be selected through an
explicit category in a later slice. They must not accidentally match a user
function selector.

## Implementation Steps

1. Add parser tests for the mode and exact selector forms, including all error
   cases.
2. Replace Boolean profile fields in `CliCompileArgs`, `CliRunArgs`,
   `CliTestArgs`, compile options, and backend APIs with the configuration type.
3. Add selection resolution beside profile-plan construction, after projected
   identities are known and before rendering.
4. Add the count-only runtime ABI and generated entry probe.
5. Make the top-level function renderer choose one of exactly three probe
   shapes.
6. Update runtime setup so reports name their mode and do not print meaningless
   time columns for calls mode.
7. Update compile/run/test fixtures and help text.
8. Delete Boolean conditionals and transitional aliases once all production
   callers use the precise mode.
9. Add count-mode SIGINT/SIGTERM lifecycle coverage before deleting the old
   start/end probes.
10. Inspect off, calls, selected exact, and all exact generated C.
11. Measure each mode separately.

## Tests

### CLI parsing

Cover:

- each accepted mode;
- missing and invalid mode values;
- repeated module and function selectors;
- selectors without a mode;
- selectors before and after ordinary compile flags;
- run/test argument forwarding after `--`;
- unknown modules and functions; and
- help text that clearly distinguishes profiling the produced program from
  profiling the compiler process.

### Backend emission

For a program containing selected and unselected leaf, recursive, closure, and
entrypoint functions, assert:

- off contains no profile strings or calls;
- calls has one count probe and zero timing probes per selected body;
- exact has balanced numeric start/end probes per selected normal return;
- unselected functions contain no profile branch;
- selector order does not change assigned identity or output order;
- duplicate selectors do not duplicate metadata or probes; and
- metadata reports exact described/selected counts.

### Runtime behavior

Use deterministic call shapes to assert exact count totals, including direct
recursion, repeated calls, zero-call selected functions, and calls from more
than one worker. Calls mode should report no time values rather than fabricated
zero-duration rankings. Run a CPU-bound count-profiled fixture under SIGINT and
SIGTERM and prove it terminates with the current signal contract.

## Fast Feedback Loop

```bash
bin/blorp test blorp/test/lib/test_cli_args.brp
bin/blorp test blorp/test/cli/test_main.brp
bin/blorp test blorp/test/compiler/stage_10_backend/test_core_emit.brp
blorp/test/cli/test_cli.sh --smoke --timeout 30
```

For each mode, compile one tiny source to a temporary C file and inspect the
probe census:

```bash
rg -c 'blorp_profile_count_id' "$temporary_c"
rg -c 'blorp_profile_start_id' "$temporary_c"
rg -c 'blorp_profile_end_id' "$temporary_c"
```

Then run one focused typechecker benchmark selected to its owning module.
Self-compile only after parser, plan, and generated-C assertions are stable.

Before review:

```bash
make
scripts/test compiler-blorp runtime cli
scripts/test leak
make quality
```

## Measurement Plan

Use identical optimized artifacts and report overhead relative to off for:

1. all-functions calls mode;
2. all-functions exact mode;
3. one-module calls mode;
4. one-module exact mode; and
5. a hot single-function exact selection.

Also report:

- selected function count;
- completed call count;
- emitted probe count;
- generated-C bytes and lines;
- clock reads, using a temporary native counter in the focused test build; and
- stack operations.

Calls mode must perform zero clock reads and zero stack operations. On the
empty-leaf microbenchmark it must be materially cheaper than exact mode. On the
compiler workload, selected exact mode must reduce instrumentation work in
proportion to excluded completed calls; if it does not, investigate residual
global work before accepting the slice.

## Implementation Result

The implementation preserves one typed `FunctionProfileConfiguration` from CLI
parsing through artifact construction and backend emission. The backend first
describes eligible emitted functions, validates selectors, filters that list,
and only then renders metadata and probes. Selected functions retain final
emission order and receive dense IDs in that order. Emission consumes that
ordered selection with a single cursor, so each function does not rescan the
selected metadata list. Selector validation and filtering first build exact
module and collision-free length-prefixed composite-function dictionaries,
then walk selectors and described functions once; repeatable selectors
therefore do not create a functions-by-selectors scan or nested COW updates.

Module selectors use exact workspace-relative `CoreFunction.source_module`
paths. Function selectors use the exact emitted logical function identity. A
monomorphized function therefore requires its specialization discriminator,
for example `module::function__mono_Int`; the implementation does not guess a
source-definition grouping that is no longer retained at this pipeline stage.
Unknown modules, unknown functions, and duplicate exact emitted identities fail
before C emission.

Calls mode has a separate `calls_observed` total and emits only
`blorp_profile_count_id(id)`. Exact mode retains `calls_completed` and balanced
start/end probes. This naming is deliberate: a count-only entry is observed
without claiming that the call returned. Both modes retain deferred signal
polling. Runtime diagnostics distinguish described, selected, and nonzero
observed function inventories and report all existing loss counters. The
calls total is derived from the selected per-function counters when reporting;
the hot path does not also update a contended global total.

### Measurement identity and method

- Parent revision: `13e391b29cb3ffeba3275ed4c79de748acac96be`
- Final rebuilt compiler SHA-256: `02be0557261cb11ddc24f35d1388243f6421e458ea3359cb34718d2b4dc9e1bb`
- Runtime-matrix artifact producer SHA-256:
  `4932f90a8b71f776f784b669807df9769f58c03fdfbc2d83361668e43d74812c`
- Parent Issue 1 compiler SHA-256: `dd59905781d4f28bd8e0f97d91fb093d1de40bef0e31b8699bb2f072c6146597`
- Bootstrap version: `0.0.1`
- Native compiler: Apple clang 21.0.0 (`clang-2100.1.1.101`), `-O2 -fwrapv -pipe -w`
- Workload: each generated compiler compiled `blorp/src/main.brp` through C
  emission with `--no-format --no-embed-runtime --time-phases` and compiler
  allocator checkpoints enabled.
- Protocol: one warmup, then three serialized samples in alternating orders.
  `/usr/bin/time -l` supplied wall, instructions, cycles, and peak RSS.
- Runtime-matrix validity: every measured mode produced byte-identical output C
  from the measured source tree with SHA-256
  `276fac8dfb6eb2998d79c50e28a446cdb961dd5916eecb1e7869ffb098747d86`.
  The off output is also byte-identical to output from the retained parent
  compiler.
- Raw and machine-readable summary data are retained in ignored
  `logs/profiling-issue-02/`.

Wall time had visible external-host outliers, so retired instructions are the
primary overhead signal. The table still reports every wall sample and its
median, median absolute deviation, and range rather than filtering results.
After this matrix, review replaced a nested COW selector index with the final
flat length-prefixed composite index. Generated C confirms the nested index is
absent. That correction is confined to constructing a profiled artifact; it
does not run in the measured compiler workload or alter runtime probes. It does
change the emitted compiler target because the compiler source itself changed.
An untimed final-source regeneration through each of the six retained mode
artifacts produced byte-identical output C with SHA-256
`ef6c46ecac4a96656e1172e5d16ace34acdb657373a2e4ed8867806572a67582`;
the final rebuilt compiler produced the same hash in off mode. The runtime
matrix was not repeated for this cold-path-only representation fix.

| Mode | Raw wall samples (s) | Wall median / MAD / range (s) | Retired instructions median | Delta vs off | Phase median (ms) |
| --- | --- | ---: | ---: | ---: | ---: |
| off | 41.14, 29.13, 28.74 | 29.13 / 0.39 / 28.74-41.14 | 334,142,438,253 | baseline | 26,945 |
| calls, all | 48.86, 31.14, 31.72 | 31.72 / 0.58 / 31.14-48.86 | 372,346,034,138 | +11.43% | 29,102 |
| exact, all | 82.19, 65.68, 66.50 | 66.50 / 0.82 / 65.68-82.19 | 870,070,088,892 | +160.39% | 59,189 |
| calls, infer module | 29.42, 31.06, 28.67 | 29.42 / 0.75 / 28.67-31.06 | 335,829,200,508 | +0.50% | 27,369 |
| exact, infer module | 29.62, 32.50, 31.01 | 31.01 / 1.39 / 29.62-32.50 | 360,904,735,366 | +8.01% | 28,888 |
| exact, `infer_expr` | 31.11, 31.08, 29.37 | 31.08 / 0.03 / 29.37-31.11 | 334,368,771,330 | +0.07% | 29,066 |

The first off, calls-all, and exact-all samples show a common cold-host wall
outlier. Retired instructions are stable and remain the primary comparison;
wall time is reported without filtering.

| Mode | Selected / described | Observed | Count entries / completed calls | Generated C bytes | Probe census (count/start/end) |
| --- | ---: | ---: | ---: | ---: | ---: |
| off | 0 / 0 | 0 | 0 / 0 | 90,593,928 | 0 / 0 / 0 |
| calls, all | 12,100 / 12,100 | 7,252 | 965,229,643 / 0 | 93,192,229 | 12,100 / 0 / 0 |
| exact, all | 12,100 / 12,100 | 7,252 | 0 / 965,229,643 | 94,483,971 | 0 / 12,100 / 12,100 |
| calls, infer module | 759 / 12,100 | 573 | 48,035,042 / 0 | 90,754,681 | 759 / 0 / 0 |
| exact, infer module | 759 / 12,100 | 573 | 0 / 48,035,042 | 90,841,529 | 0 / 759 / 759 |
| exact, `infer_expr` | 1 / 12,100 | 1 | 0 / 566,776 | 90,594,551 | 0 / 1 / 1 |

All six modes reported the same Blorp allocator object counts at artifact
completion: 330,323,976 allocations, 306,952,977 releases, and 23,370,999
retained objects. Median allocator bytes were 1,946,910,960 off;
1,947,107,600 for either all-function mode; 1,946,923,280 for either infer
mode; and 1,946,911,008 for one exact function. Median peak RSS ranged from
2,773,565,440 to 2,776,121,344 bytes, within 0.10% of off. Runtime C profiler
storage is allocated by native `calloc` and is therefore represented in RSS,
not the Blorp allocator counters.

### Isolated probe cost

A native leaf probe performed 5,000,000 calls per sample with one warmup and
seven alternating samples:

| Mode | Median / MAD / range (ms) | Instructions median | Clock reads | Final stack depth |
| --- | ---: | ---: | ---: | ---: |
| off | 3.739 / 0.017 / 3.716-4.303 | 43,297,932 | 0 | 0 |
| calls | 22.057 / 0.256 / 21.426-23.385 | 279,085,176 | 0 | 0 |
| exact | 215.564 / 0.381 / 215.183-271.391 | 2,875,944,776 | 10,000,000 | 0 |

Count-only probes were 89.77% cheaper than exact probes by elapsed median and
performed zero clock reads and zero stack operations. The focused runtime suite
also covers recursive calls, repeated calls, a selected zero-call function,
multiple native threads, signal delivery, invalid operations, profile-window
boundaries, and the prior 1,024-function ceiling.

### Limitations and follow-on ownership

- Calls and exact modes still update shared atomic counters. Issue 4 owns local
  shards and structured output.
- Exact timing still uses the fixed thread-local stack and is not fiber-aware.
  Issue 3 owns fiber-local stacks and self time.
- The backend retains emitted module/function identity but not a durable
  source-definition-to-specializations relation. Selectors therefore require
  exact emitted logical specialization names.
- Optimized-away functions are not eligible selector targets because selection
  applies to final emitted functions.
- `--profile` remains a temporary exact-all alias so the branch stays
  bisectable. Issue 6 must remove it when the unified profile command lands.
- The benchmark bridge Boolean is a compatibility field of its existing JSON
  protocol, not a second compiler profiling model.

## Acceptance Criteria

- [x] Profile mode is a variant, not a Boolean or stringly internal state.
- [x] Calls mode emits only one entry counter probe per selected function call.
- [x] Calls mode performs no clock read or profile stack operation.
- [x] Exact mode emits balanced timing probes only for selected functions.
- [x] Selection uses compiler-owned module/function identity, never compact C
      spelling or rendered-text scanning.
- [x] Unknown and ambiguous selectors fail before C emission with actionable
      diagnostics.
- [x] Metadata states mode, described count, and selected count.
- [x] Count mode preserves SIGINT/SIGTERM delivery for CPU-bound programs.
- [x] Unselected functions carry zero profiling runtime overhead.
- [x] Non-profiled C remains byte-identical to the immediate parent.
- [x] All production Boolean profile routes and any temporary compatibility
      alias are removed by Issue 6.
- [x] Mode overhead, call totals, and generated-C size are measured and
      reported.
- [x] Focused, compiler, runtime, leak, CLI, and quality owners pass.

## Pitfalls And Review Questions

- Did the implementation add several booleans that still admit contradictory
  modes?
- Does a source function selector accidentally select every same-named function
  in other modules?
- Are monomorphized instances handled explicitly?
- Is selection performed before final projection, then invalidated by later
  generated functions?
- Does calls mode still force a common return temporary solely for a nonexistent
  exit probe?
- Does enabling one exact function still allocate or initialize counters for
  every described function?
- Can selector order change output or IDs?
- Are profiler flags accidentally forwarded to the executed Blorp program?

The issue is incomplete if modes exist only at the CLI while the backend still
receives a Boolean and instruments every function.
