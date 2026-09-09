# Expose The Seven Compiler Phase Timings

**Status:** Ready

**Kind:** Measurement infrastructure; no intended compiler-latency change

**Parallel owner boundary:**

- `blorp/src/lib/compile_plan_execute.brp`
- `blorp/src/lib/compilation.brp`
- `blorp/src/lib/compilation_timing.brp`
- compiler orchestration products in `blorp/src/compiler/pipeline.brp`
- `blorp/src/compiler/output.brp`
- `blorp/src/compiler/command.brp`
- CLI timing tests and documentation

Do not edit individual Stage 06, Stage 09 pass, Stage 10 emitter, or native
runtime implementations in this issue.

## Objective

Make `--time-phases` report the seven phase identities already declared by the
compiler:

1. typed frontend;
2. Core lowering;
3. early Core;
4. runtime projection;
5. late Core;
6. backend C emission; and
7. artifact construction.

The normal and timed compiler must execute the same transformations. Timing
disabled must avoid clock calls and must not maintain a second compilation
path.

## Why This Issue Exists

`CompilerPhase` and `COMPILER_PHASE_ORDER` already express the desired
architecture in `blorp/src/compiler/pipeline.brp`:

```blorp
enum CompilerPhase:
	TypedFrontendPhase
	CoreLoweringPhase
	EarlyCorePhase
	RuntimeProjectionPhase
	LateCorePhase
	BackendEmissionPhase
	ArtifactConstructionPhase
```

Production timing currently wraps only two large calls:

```blorp
prepare_compile_plan(plan)                 -- "frontend"
finish_prepared_compile_execution(prepared) -- "backend"
```

Consequently, a 22-second `backend` result cannot distinguish Perceus and
other late-Core passes from callable projection, C rendering, or artifact
assembly. The `frontend` label similarly includes work after typechecking.

Using `--stop-after` is not a valid workaround. It renders the selected Core
snapshot as JSON. On compiler self-compilation those dumps were 200–318 MB and
raised peak RSS from approximately 2.16 GB to 4–5 GB, materially perturbing the
measurement.

## Required Design

Preserve purity of compiler transformations. Do not call `now_microseconds()`
from a function declared `pure`, and do not disguise timing as a pure foreign
operation.

Expose typed phase products at orchestration boundaries, then let the existing
impure execution owner sample the clock between calls. Illustrative product
names are:

```blorp
opaque type TypedFrontendCompilation = ...
opaque type LoweredCoreCompilation = ...
opaque type EarlyCoreCompilation = ...
opaque type RuntimeProjectedCompilation = ...
opaque type PreparedCoreProgram = ...
```

Names should follow the final implementation, but illegal phase transitions
must not become representable. Do not use one record plus boolean completion
flags.

The orchestration shape should be conceptually:

```blorp
typed = run_typed_frontend(input)
lowered = lower_typed_graph(typed)
early = run_early_core(lowered)
projected = project_runtime(early)
prepared = run_late_core(projected)
emission = emit_prepared_core(prepared)
artifact = construct_artifact(emission)
```

Each operation remains pure. `execute_compile_plan_timed` conditionally records
the timestamp before and after each operation.

Do not duplicate pass lists. The existing early- and late-Core pipeline owners
remain authoritative. This issue exposes their existing boundaries; it does
not reorder transformations.

## Timing Record

Use `CompilerPhase` as the internal identity rather than free-form labels.
Convert to stable CLI labels only when rendering:

```text
typed_frontend
core_lowering
early_core
runtime_projection
late_core
backend_emission
artifact_construction
```

Retain the existing `CompileTiming` wire shape only if it can carry the typed
identity without parallel string authority. Otherwise replace it with a typed
record and render strings at the CLI boundary.

The successful result must contain exactly one row per phase in
`COMPILER_PHASE_ORDER`. A failed or stopped compilation reports completed
phases plus the elapsed failing/stopped phase. It must never fabricate zero
rows for phases that did not run.

Record one outer compilation duration in the same invocation. The seven phase
rows are validated against that contemporaneous outer measurement, not against
a historical `frontend + backend` run collected under different load.

## Memory Checkpoints

Align `BLORP_COMPILER_MEMORY_PROFILE=1` checkpoints with the same phase labels:

```text
typed_frontend_start
typed_frontend_complete
core_lowering_complete
early_core_complete
runtime_projection_complete
late_core_complete
backend_emission_complete
artifact_construction_complete
```

One start checkpoint followed by completion checkpoints is sufficient. Do not
retain the ambiguous `frontend_complete` and `backend_complete` labels after
all consumers and documentation are migrated.

Failure and stop exits also emit a terminal checkpoint derived from the active
phase identity:

```text
typed_frontend_failed
early_core_stopped
late_core_stopped
backend_emission_failed
artifact_construction_failed
```

The examples are representative. Use one exhaustive phase-plus-terminal-state
renderer rather than assembling strings at call sites. A stopped or failed
compile must never leave memory profiling with only a phase-start marker; its
last checkpoint identifies the phase and whether execution failed or stopped.
These labels replace, rather than remove, the diagnostic value of the existing
`frontend_failed` and `frontend_stopped` observations.

Checkpoint calls stay in the impure executor. The normal transformation APIs
must remain usable by pure unit tests and benchmarks.

## Test-First Plan

Before restructuring orchestration, add protocol-level timing tests for:

1. successful compile reports all seven labels exactly once and in order;
2. a type error reports a typed-frontend row and no later rows;
3. early `--stop-after` reports phases through the selected early phase;
4. late `--stop-after` reports phases through the selected late phase;
5. backend emission failure includes backend emission but not artifact
   construction;
6. artifact construction failure includes all seven phases;
7. timing-disabled output contains no phase rows; and
8. enabling timing does not change the produced C bytes.

Test phase labels and ordering, not elapsed values. Durations need only be
nonnegative because virtualized CI clocks can have coarse resolution.

Add a focused test for the `CompilerPhase` rendering function so adding a new
enum case requires updating the CLI mapping at compile time.

## Incremental Implementation

1. Add typed phase-label rendering and its exhaustive test.
2. Split typed frontend from Core lowering while preserving the current
   `compile_frontend_graph_with_typed_validation` behavior through composition.
3. Expose the early-Core and runtime-projection products separately.
4. Expose late Core, backend emission, and artifact construction separately.
5. Route both timed and untimed compilation through the new single executor.
6. Add the seven timing rows.
7. Align memory checkpoint labels.
8. Delete the two-bucket timing and any compatibility-only helpers.
9. Update `docs/DEVELOPMENT.md` with the exact output contract.

After each split, compare the generated C SHA-256 before adding the next
boundary. This turns pipeline drift into a local failure.

## Fast Feedback Loop

Use one minimal program for CLI behavior:

```bash
phase_tmp=$(mktemp -d "${TMPDIR:-/tmp}/blorp-phase-timing.XXXXXX")
tmp_source="$phase_tmp/main.brp"
tmp_c="$phase_tmp/main.c"
trap 'rm -rf "$phase_tmp"' EXIT
printf 'func main(args: List[String]) -> Int:\n\t0\n' >"$tmp_source"
bin/blorp compile --no-format --no-embed-runtime --time-phases \
  -o "$tmp_c" "$tmp_source"
```

Use the established CLI fixture owner for committed tests rather than leaving
the temporary source in the repository.

After each orchestration boundary:

```bash
bin/blorp test --timeout 180 \
  blorp/test/compiler/stage_09_core/test_core_pipeline.brp

bin/blorp test --timeout 180 \
  blorp/test/compiler/test_output.brp

blorp/test/cli/test_rebuilt_cli.sh --timeout 30
```

Use whichever focused pipeline test owns the affected public API if the exact
filename differs; do not create a duplicate broad suite.

Before review:

```bash
scripts/compiler-check --changed
scripts/test cli
scripts/test compiler-blorp
```

Then collect three compiler self-compilation rows with
`--no-embed-runtime --time-phases` and confirm the phase sum tracks the existing
instrumented total.

## Acceptance Criteria

- [ ] All seven `CompilerPhase` variants are used by production timing.
- [ ] Successful compile output contains exactly seven stable labels in
      `COMPILER_PHASE_ORDER`.
- [ ] Failed and stopped compilation reports only reached phases, including the
      failing phase.
- [ ] Timing and memory checkpoints share one phase-label authority.
- [ ] Every failure and stop path emits a terminal memory checkpoint carrying
      the active phase plus `failed` or `stopped` state.
- [ ] Timed and untimed execution use the same transformation path.
- [ ] No clock or memory-checkpoint operation is called from pure compiler
      transformation code.
- [ ] No pass order, stop behavior, observation behavior, diagnostic, Core
      snapshot, or generated-C byte changes.
- [ ] Across five alternating runs, timing-disabled compile-to-C does not show
      a repeatable regression outside the paired noise envelope; a median
      regression greater than 2% is a failure.
- [ ] In each successful invocation, the sum of phase durations is within 2%
      of an outer compilation duration captured during that same invocation.
      CLI startup and final file publication may remain outside the phase sum
      and must be documented.
- [ ] The legacy `frontend` and `backend` phase labels are deleted from source,
      tests, and current documentation.
- [ ] No generated artifacts are committed.

## Pitfalls

### A second compiler pipeline

Do not retain the current nested path for normal builds and add a second staged
path only for timing. They will drift. One executor must own both modes.

### Timing inside pure code

Making a clock foreign function appear pure weakens the language's purity
model and could invalidate optimization assumptions. Split orchestration
instead.

### Observation rendering in measured regions

Normal compilation should not render Core snapshots. Timing a `--stop-after`
or `--dump-core-after` invocation measures requested diagnostic work as well as
the phase. The baseline workload must use neither option.

### Phase products with boolean flags

Do not introduce `is_lowered`, `is_projected`, or equivalent flags. Use opaque
phase-specific products so later stages cannot receive an earlier form.

### Unstable labels

CLI labels are consumed by scripts and retained benchmark records. Keep one
exhaustive mapping and avoid embedding user-facing strings throughout the
pipeline.

## Non-Goals

- Per-pass Stage 09 timing.
- Changing any compiler transformation.
- Capturing or serializing full Core programs.
- Timing host C compilation or program execution.
- Adding a general tracing framework.
- Optimizing compilation in the same change.
