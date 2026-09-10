# Introduce Explicit Count, Exact, And Selective Instrumentation Modes

**Status:** Ready after Issue 1

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

## Proposed Configuration Types

Use variants at the CLI boundary and preserve them through the compile plan:

```blorp
union FunctionProfileMode:
    FunctionProfileOff
    FunctionProfileCalls
    FunctionProfileExact

union FunctionProfileSelector:
    ProfileAllFunctions
    ProfileModule(module_path: String)
    ProfileFunction(module_path: String, function_name: String)

struct FunctionProfileConfig {
    mode: FunctionProfileMode,
    selectors: List[FunctionProfileSelector],
}
```

If current parser conventions favor enum-like nullary cases, follow them. Do
not encode modes as strings or as booleans such as `profile`, `profile_calls`,
and `profile_exact` that admit contradictory states.

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

## Acceptance Criteria

- [ ] Profile mode is a variant, not a Boolean or stringly internal state.
- [ ] Calls mode emits only one entry counter probe per selected function call.
- [ ] Calls mode performs no clock read or profile stack operation.
- [ ] Exact mode emits balanced timing probes only for selected functions.
- [ ] Selection uses compiler-owned module/function identity, never compact C
      spelling or rendered-text scanning.
- [ ] Unknown and ambiguous selectors fail before C emission with actionable
      diagnostics.
- [ ] Metadata states mode, described count, and selected count.
- [ ] Count mode preserves SIGINT/SIGTERM delivery for CPU-bound programs.
- [ ] Unselected functions carry zero profiling runtime overhead.
- [ ] Non-profiled C remains byte-identical to the immediate parent.
- [ ] All production Boolean profile routes and any temporary compatibility
      alias are removed by Issue 6.
- [ ] Mode overhead, call totals, and generated-C size are measured and
      reported.
- [ ] Focused, compiler, runtime, leak, CLI, and quality owners pass.

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
