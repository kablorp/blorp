# Template Production-Pass Performance Experiments

**Status:** Proposed

**Owner:** `blorp/benchmark/compiler/`, `benchmarks/`, and benchmark guidance

**Current state:** Pass-specific runners and fixtures exist, but there is no
small shared comparison contract for new production-pass experiments.
**Next action:** Test paired-driver failure modes with fake binaries, then
pilot the template on one Core and one typecheck pass without production edits.
**Read first:** `benchmarks/compiler_consume_candidate_index_profile`, its
`.brp` fixture, and the Developer Guide's profiling section.
**Fast loop:** One fake-binary pair and one existing consume-runner sample;
build full pilot binaries only after output checks pass.
**Decision:** Accept only same-input production-pass timings with raw pairs
and semantic identity; reject silent fixture overlay or setup in the timer.

## Objective

Make a small, reproducible baseline/candidate experiment the default first
step for a compiler optimization. Provide a reusable fixture/harness pattern
and paired-run protocol, not a universal profiler or another production pass
mode. Pilot one late-Core pass and one frontend/typecheck boundary.

## Why

`--time-phases` locates a broad region; native samples rank functions; neither
proves that one proposed data-structure change helps its production pass.
During the September 2026 six-function round, removing modeled scans did not
always improve elapsed time, and immutable collection construction sometimes
increased allocations. Direct production-pass calls on stable inputs allowed
those ideas to be rejected quickly.

Existing precedents include
`benchmarks/compiler_consume_candidate_index_profile` and its `.brp` fixture,
the inference performance harness, and `scripts/bench-blorp-test-session`.
Reuse their useful checks; do not replace all existing benchmarks. Audit the
consume runner's fixture-overlay behavior before copying it: a comparison
driver must never silently overwrite sources in a dirty baseline worktree.

## Experiment Contract

Each new pass benchmark should separate four operations:

```text
fixture construction and validation (untimed)
→ production pass invocation on the original immutable input (timed)
→ complete result retention and semantic fingerprint (untimed)
→ reporting and paired comparison (untimed)
```

Every iteration must receive the *same original input*, not the prior output.
The timed call must be the production public/private pass boundary used by the
compiler, without benchmark-only branches in that pass. When outputs are
large, retain the complete result until after the timed window, then compute
the fingerprint. Record enough fixture shape to distinguish zero-query,
representative, and worst-case axes.

The common comparison driver may accept two already built benchmark binaries
and one argument vector. It should not compile them inside timed samples:

```bash
# Illustration of the intended interface, not an existing command.
benchmarks/compiler_pass_compare \
  --baseline-bin /tmp/blorp-base/consume-pass-bench \
  --candidate-bin /tmp/blorp-new/consume-pass-bench \
  --pairs 7 --warmup-pairs 1 \
  --results /tmp/consume-pairs.json \
  -- 1 512 8 512 25 none
```

The result should include raw alternating samples, median and paired deltas,
the exact binary SHA-256s, source revision/worktree dirty state, fixture hash,
arguments, platform, compiler/optimization configuration, semantic checksum,
and per-sample time. Optional allocation/release/retained/RSS and deterministic
work counters must name their measurement mode. Never mix profiled and plain
binaries in one latency comparison.

### A new pass harness example

The existing consume harness uses this actual production-boundary shape:

```blorp
program: CoreProgram = compiler_consume_candidate_index_profile_program(config)
warm_rewritten: CoreProgram = rewrite_program(program)
var rewritten: CoreProgram = warm_rewritten
var iteration: Int = 0

reset_mem_stats()
begin_function_profile_window()
started: Int = now_microseconds()
while iteration < config.iterations:
	rewritten = rewrite_program(program)  -- always the original input
	iteration += 1
elapsed_microseconds: Int = now_microseconds() - started
end_function_profile_window()
stats = get_mem_stats()
result = compiler_consume_candidate_index_profile_result_for_rewrite(
	config,
	rewritten,
)  -- complete result inspected after the timed window
```

The imports and output printing are omitted here; see the retained `.brp`
fixture for executable source. The new template should use the same existing
`instrumentation`, `memory`, and `system` APIs, and a test must confirm the
production pass is actually invoked. For very small operations, batch only
enough iterations to exceed timer noise and measure the loop/retention control.

## Source And Output Integrity

- Baseline and candidate must receive byte-identical fixture source and input
  data. If a benchmark file is missing in the baseline checkout, stage an
  explicit temporary copy or fail with instructions; do not overwrite an
  existing different file without opt-in and a before/after hash check.
- Hash both benchmark inputs and production-pass source provenance. Report
  dirty state rather than relying on a commit SHA alone.
- Compare complete semantic output, not just a convenient count or one field.
  For codegen-facing work also compare generated Core JSON or C bytes where
  applicable; native compilation of the *target* C is outside a C-emission
  latency claim.
- Warm both variants, alternate order, preserve raw samples, bound runtime and
  memory, and avoid concurrent heavy builds while timing.
- Fail closed on mismatched checksum, fixture, or unsupported counter mode.

## Test-First Plan And Pilot

1. Add a tiny fake binary that emits deterministic machine-readable sample
   records. Test paired ordering, malformed output, checksum disagreement,
   timeouts, and nonzero child exits before implementing the driver.
2. Extract only shared comparison/provenance logic from one existing runner or
   implement a small shared helper; preserve that runner's current CLI.
3. Pilot the consume-specialization benchmark in zero, sparse, and 512-
   candidate modes, reproducing its semantic checksum and expected direction.
4. Pilot one typecheck/inference boundary with an independently prepared input
   context. Keep phase setup outside the timed call.
5. Compare driver overhead on a near-zero fake operation; if it dominates,
   batch iterations inside the benchmark binary and time the batch.
6. Document a copyable recipe in `benchmarks/README.md` and link it from the
   Developer Guide's profiling section.

## Fast Feedback Loop

```bash
python3 blorp/test/compiler/benchmark/test_compiler_pass_compare.py
benchmarks/compiler_consume_candidate_index_profile \
  plain 1 256 8 256 25 none --samples 3 --json
```

The Python test is proposed; the consume command is existing precedent.
While developing a pass fixture, run one timed iteration and its semantic
check before collecting seven pairs. Once stable, inspect any generated C
needed for output identity, run focused compiler benchmark tests, and obtain
test-runner/code-reviewer review. Do not run whole-compiler self-emission after
every harness edit.

## Acceptance / Rejection

- [ ] Two pilot passes use the same paired protocol without production changes.
- [ ] Setup, source copying, compilation, semantic hashing, and printing are
      outside timed samples; every sample invokes the original fixture input.
- [ ] Raw samples/provenance can reproduce the reported median and decision.
- [ ] Mismatched semantic output or input source fails before a speed claim.
- [ ] Dirty baseline sources are never silently overwritten.
- [ ] Zero-query and representative controls make fixed setup cost visible.
- [ ] A reviewer can run one documented command per pilot and identify the
      exact production function measured.
- [ ] If a generic driver obscures pass ownership or adds substantial overhead,
      keep only the tested fixture/template conventions and reject the driver.

## Non-Goals

- Optimizing either pilot pass or changing language semantics.
- Converting the entire benchmark inventory.
- Treating synthetic pass speed as proof of whole-compiler speed.
- Compiling emitted target C inside a C-emission timing window.
