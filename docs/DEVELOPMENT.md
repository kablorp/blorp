# Blorp Developer Guide

This guide supplies commands and investigation recipes for the self-hosted
compiler. [`AGENTS.md`](../AGENTS.md) owns engineering rules;
[`scripts/README.md`](../scripts/README.md) owns test-gate details.

Commands in this guide run from the repository root unless stated otherwise.
Use the repository's `bin/blorp` executable, not a separately installed release,
when validating a source checkout.

## Sources Of Truth

Start at the task boundary routed by [`AGENTS.md`](../AGENTS.md). For compiler
phase ownership use [Architecture](ARCHITECTURE.md); for test-gate semantics
use [`scripts/README.md`](../scripts/README.md); for benchmark arguments use
[`benchmarks/README.md`](../benchmarks/README.md). CLI help owns current flags.

## Prerequisites

A source build requires:

- Git
- GNU Make
- a C compiler such as Clang or GCC
- `curl` or `wget`
- `shasum` or `sha256sum` for bootstrap verification
- Python 3 for repository scripts and integration tests

Some optional gates need additional tools:

- Docker for Linux and architecture-parity gates
- Node.js and npm for the VS Code extension tests
- `flamegraph.pl` from Brendan Gregg's FlameGraph tools to render SVG flame
  graphs from Blorp's collapsed profile output

The build downloads the compiler version pinned in `blorp/build/bootstrap.env`.
No globally installed Blorp compiler is required.

Pinned bootstrap assets currently support Darwin arm64 and Linux x86_64 or
arm64. Darwin x86_64 and other host platforms cannot resolve the pinned
bootstrap directly; use a supported host or the documented Docker workflow.

## First Build

```bash
git clone https://github.com/kablorp/blorp.git
cd blorp
make
bin/blorp --version
bin/blorp test --warmup-only
```

`make` performs a self-hosted build:

1. Resolve the pinned bootstrap compiler.
2. Build the deterministic source generator in `blorp/tool/`.
3. Generate build metadata, embedded standard-library source, and embedded
   runtime C.
4. Compile the current compiler sources to C.
5. Compile and install the resulting executable as `bin/blorp`.

Useful build targets:

```bash
make                              # Build and install bin/blorp
make generate-blorp-cli-c         # Generate the compiler C with the pinned compiler
make clean                        # Remove generated build products
```

Run `make` after changing compiler source before using `bin/blorp` to validate
self-host behavior. A source file can pass with an older executable while the
new compiler fails to build itself, so the executable timestamp and build
status matter.

## Daily Development Loop

Use the one-boundary loop from [`AGENTS.md`](../AGENTS.md): establish a failing
test or baseline, iterate with the smallest repeatable check, then run the
appropriate ownership and broad gates. For a changed compiler source, a
typical loop is:

```bash
bin/blorp format --check --diff path/to/changed.brp
bin/blorp check --no-format path/to/changed.brp
bin/blorp test --timeout 180 blorp/test/compiler/test_relevant_behavior.brp
scripts/compiler-check --changed
git diff --check
```

Use `--no-format` in diagnostic and performance commands after a separate
format check. This keeps formatting work out of the behavior or timing window.

## Efficient Agent Investigation And Handoff

Use progressive disclosure: start with the task's owning source, one nearby
test, and the relevant contract. Read more when a concrete uncertainty or
failure calls for it. `AGENTS.md` carries binding rules and routes tasks here;
this guide carries detailed commands. An active issue is a next-action handoff,
not a requirement to read every roadmap under `docs/issues/`.

Several compiler files are large. Search for a symbol and read a bounded
region before loading an entire file. Exclude generated embedded inputs when
they are not the subject of the task:

```bash
rg -n '^(private )?(pure )?func |find_clone_target' \
  blorp/src/compiler/stage_09_core/consume_specialize.brp
sed -n '1490,1565p' \
  blorp/src/compiler/stage_09_core/consume_specialize.brp
rg -n 'CoreSemanticMatchTree' blorp/src/compiler \
  -g '*.brp' -g '!**/stage_01_generated_inputs/**'
```

The line range is an example, not a stable API; choose it from the preceding
search result. If a function spans a wider region, expand only that region and
its immediate callers/tests. Do not split a compiler module solely to shorten
tool output; split only when it exposes a real ownership boundary.

Keep full diagnostic artifacts on disk and bring only the relevant excerpt
into the conversation. The default `scripts/test` output is already compact:

```bash
scripts/test --no-build --log-dir /tmp/blorp-gate-logs compiler-blorp
rg -n 'FAIL|error:|BLORP_GATE_RESULT' /tmp/blorp-gate-logs
```

For Core/C changes, write snapshots and generated C to temporary paths, then
compare hashes or search the relevant symbol. Do not paste a whole compiler C
file or Core dump when a targeted function body and artifact path suffice.
Preserve the complete artifact for a reviewer if the identity claim depends
on it. A quiet successful gate saves reading time and tokens; it does **not**
replace focused failure diagnosis or final integration coverage.

When delegating or handing off, give a bounded task brief rather than a copy
of the entire investigation transcript:

```text
Question: Does candidate lookup improve consume_specialize.rewrite_program?
Base: exact Git revision and worktree; identify any dirty inputs.
Read first: consume_specialize.brp, its focused suite, the assigned issue.
Fast loop: one direct-pass fixture; then the named owner suite.
Boundary: candidate identity/order only; no union-index or traversal rewrite.
Return: hypothesis, exact commands, raw sample location, output identity,
        test counts, caveats, and accept/reject recommendation.
```

For reviews, send the diff plus the evidence packet and unresolved questions.
Do not make each reviewer rediscover the same source map. Negative performance
experiments are valuable results: report the measured counterexample instead
of expanding scope until a speedup appears. Do not omit a required contract,
test, or generated-C inspection merely to save context.

To evaluate whether this practice helps, compare tasks by actual token usage
when available; otherwise track repeated file reads, truncated outputs, time
to first relevant result, and reviewer follow-up questions. Use a parser
diagnostic, a Core optimization, and a build change as different pilot tasks.

## Common CLI Operations

```bash
bin/blorp check --no-format program.brp
bin/blorp run --no-format program.brp
bin/blorp compile --no-format -o /tmp/program.c program.brp
bin/blorp format --check --diff program.brp
bin/blorp purify --dry-run program.brp
bin/blorp lint --fail-on-findings program.brp
```

Use `bin/blorp <command> --help` for current flags and environment controls.
`run` uses the compiler's host-C flags; a raw `cc` invocation is not a
portable substitute. `lint` typechecks the import graph but reports only for
selected files and does not rewrite source. See [Lint](LINT.md) for rule IDs.

## Test Placement

Put a test at the boundary whose behavior it proves:

| Change | Test location |
| --- | --- |
| Compiler implementation, internal data structure, or pass | `blorp/test/compiler/` |
| Public parser, inference, typechecker, and codegen contract | registered fixture directories under `blorp/test/compiler/` |
| Format, purify, and lint CLI contract | the matching owner under `blorp/test/` |
| Language or runtime behavior | `blorp/test/runtime/` |
| Standard-library runtime behavior | `standard_library/test/` |
| Standard-library example | doctest in `standard_library/src/` |
| LSP process/protocol behavior | `blorp/test/lsp/` |
| Package lifecycle | package fixtures and `scripts/test package` |

New compiler implementation suites must be registered in
`blorp/test/compiler/compiler_test_ownership.json`. Map each suite to the production
source it covers so `scripts/compiler-check --changed` can select it.

The parser/inference/typecheck compatibility corpus in the registered fixture
directories under `blorp/test/compiler/` is mostly frozen. Follow
the ownership rules above before adding public fixtures there.

## Focused Tests

Run the smallest relevant TestSuite directly:

```bash
bin/blorp test --timeout 180 blorp/test/compiler/stage_06_typecheck/type_system/test_env.brp
bin/blorp test --doc standard_library/src/string.brp
```

Exercise instrumentation at the smallest relevant boundary:

```bash
bin/blorp test --leak-check --timeout 180 blorp/test/compiler/stage_09_core/test_core_perceus.brp
bin/blorp test --sanitize --timeout 180 blorp/test/compiler/stage_10_backend/test_core_emit.brp
```

On Darwin, use `--sanitize=undefined` when AddressSanitizer is incompatible
with a fiber-heavy test. Do not silently omit sanitizer evidence; state which
mode was run and why.

## Compiler-Owned Checks

`scripts/compiler-check` uses the ownership manifest to select focused compiler
suites and checks:

```bash
scripts/compiler-check --changed
scripts/compiler-check --changed --base origin/main
scripts/compiler-check --stage typecheck
scripts/compiler-check blorp/test/compiler/stage_06_typecheck/type_system/test_env.brp
scripts/compiler-check --validate-manifest
```

Use `--changed` during iteration and the relevant stage before integrating a
cross-module compiler change. The command complements broad integration gates;
it does not replace them.

## Repository Test Gates

The main test entrypoint is `scripts/test`. Gate composition, timeouts, and
options are maintained in [`scripts/README.md`](../scripts/README.md):

```bash
scripts/test                    # Default local gate set
scripts/test compiler-blorp     # Compiler .brp suites and public check fixtures
scripts/test runtime            # Language, std, and package runtime tests
scripts/test --no-build --log-dir /tmp/blorp-gates compiler-blorp
```

The runner is quiet on success. `--log-dir` keeps full output off the
conversation; inspect the first child failure when a parent summary is
invalid.

## Reproducing CI

Reproduce the compiler test shard locally with the same environment shape:

```bash
BLORP_COMPILER_TEST_SHARD_INDEX=1 \
BLORP_COMPILER_TEST_SHARD_COUNT=2 \
BLORP_COMPILER_TEST_PROGRESS=1 \
scripts/test --no-build --serial compiler-blorp
```

Run the local premerge gate:

```bash
scripts/premerge-gate --no-docker
```

Use Docker for Linux and architecture parity:

```bash
scripts/docker-gate --premerge-gate --platform linux/amd64
scripts/docker-gate --premerge-gate --platform linux/arm64
scripts/docker-gate --premerge-gate --all-platforms
```

Prefer a focused reproduction before rerunning an entire slow gate. Preserve
the original source grouping when a failure occurs only in a combined artifact:

```bash
bin/blorp test --timeout 240 source_a.brp source_b.brp source_c.brp
```

Grouped tests can expose import-name, module-alias, constructor, generated-name,
and initialization-order collisions that isolated files do not.

## Compiler Diagnostics

### Parsed And Typed Source

```bash
bin/blorp check --dump-ast --no-format program.brp
bin/blorp check --dump-typed-ast --no-format program.brp
bin/blorp compile --dump-ast --no-format program.brp
bin/blorp compile --dump-typed-ast --no-format program.brp
```

These are summaries, not complete expression-tree dumps.

### Core Pipeline Snapshots

```bash
bin/blorp compile --dump-core --no-format program.brp
bin/blorp compile --dump-core-after=lower,mono,closure --no-format program.brp
bin/blorp compile --stop-after=resolve --no-format program.brp
bin/blorp compile --check-invariants --dump-core-after=match --no-format program.brp
bin/blorp compile --dump-core-after=perceus \
  --dump-core-file=/tmp/program.core.txt --no-format program.brp
```

Supported snapshot names are printed by `bin/blorp compile --help`. Use the last
valid snapshot and the first invalid snapshot to localize a pass regression.
`--check-invariants` is especially useful after transformations that rewrite
identities, ownership, calls, or control flow.

### Generated C

Write generated C to a temporary path and inspect it directly:

```bash
tmpc=$(mktemp "${TMPDIR:-/tmp}/blorp-codegen.XXXXXX.c")
bin/blorp compile --no-format -o "$tmpc" program.brp
cc -fsyntax-only "$tmpc"
rg 'Blorp backend could not|unsupported function' "$tmpc"
rm -f "$tmpc"
```

For backend changes, inspect the relevant function body, retain/release order,
closure capture layout, and generated declarations rather than relying only on
successful host-C compilation. The broad warning contract lives in:

```bash
blorp/test/compiler/pipeline/codegen_audit/run_codegen_audit.sh bin/blorp
```

That audit detects the host compiler and applies the repository's accepted
Clang or GCC warning policy. Do not copy Clang-only warning names into a generic
`cc` command.

### Diagnostic Fixtures

Expected public diagnostics use the marker conventions documented in
the test-organization rules above. A negative fixture must verify the
message, not merely a nonzero exit status. For an ad hoc check:

```bash
set +e
output=$(bin/blorp check --no-format /tmp/invalid.brp 2>&1)
status=$?
set -e
printf '%s\n' "$output"
test "$status" -ne 0
printf '%s\n' "$output" | rg 'expected diagnostic text'
```

### Capturing A Typecheck Request

Capture the normal source graph immediately before graph typechecking:

```bash
capture=$(mktemp "${TMPDIR:-/tmp}/blorp-typecheck-graph.XXXXXX.json")
bin/blorp check --no-format --capture-typecheck-request "$capture" \
  blorp/src/main.brp
```

Captures contain source text and local paths. Keep them local and delete them
when the investigation is complete.

## Timing Compiler Phases

Use phase timing for a fast end-to-end orientation:

```bash
bin/blorp compile --time-phases --no-format program.brp
bin/blorp compile --time-phases --no-format \
  blorp/src/main.brp
```

Phase timing identifies the broad region to investigate. It is not enough to
attribute cost to a helper or accept an optimization.

`--time-phases` writes one row for each completed compiler phase in this
order: `typed_frontend`, `core_lowering`, `early_core`,
`runtime_projection`, `late_core`, `backend_emission`, and
`artifact_construction`. A failed or stopped compile includes only phases that
were reached, including the active failed or stopped phase. `phase_total` is
the sum of these phase rows. `outer_total` is measured during the same
invocation around compiler-pipeline execution so scripts can detect timing
gaps; it also includes instrumentation overhead such as memory checkpoint
calls. CLI startup, compile-plan construction, final artifact file publication,
host C compilation, and program execution are outside these compiler phase
totals.

Use `scripts/test --timings` when compilation of test artifacts is the concern:

```bash
scripts/test --timings --log-dir logs runtime
```

The timing record separates frontend, typecheck, Core, host-C, and execution
time for generated test artifacts.

## Function Profiling And Flame Graphs

Profile a Blorp program or compiler benchmark:

```bash
bin/blorp run --profile --no-format program.brp 2>/tmp/blorp-profile.txt
bin/blorp run --profile-mode calls --profile-module compiler/stage_06_typecheck/infer program.brp
bin/blorp run --profile-mode exact --profile-function compiler/stage_06_typecheck/type_system/env::scope_add_symbol program.brp
benchmarks/compiler_typecheck_profile 2 2 64 128 \
  2>/tmp/compiler-typecheck-profile.txt
```

`calls` counts invocations; `exact` records inclusive and self active time.
Module and function selectors may repeat; an empty selector set includes all
eligible functions, and nonempty selectors form a deduplicated union over exact
logical identities (including monomorphized functions). Exact probes cover
body-bearing user functions and the entrypoint, not closure bodies, foreign
functions, or bodyless declarations. The legacy `--profile` spelling selects
exact/all until the unified profile command replaces it.

The report includes function rows and `FLAME:` rows. Inclusive parent and
child times overlap and must not be added; self time partitions active work
and is the appropriate percentage/ranking measure. A call that crosses a
profile-window boundary is accounted only for its time inside that window.
Suspended fiber time is not active time; cancellation and nonlocal unwinding
must balance frames and report any loss. Compare the same function, call
count, and workload across revisions.

The runtime profiler assigns every emitted function a dense artifact-local ID
and reports explicit completeness diagnostics. Check `functions_described`,
`functions_observed`, `calls_completed`, and all loss/corruption counters before
drawing conclusions from a profile.

Render the collapsed rows when `flamegraph.pl` is installed:

```bash
rg '^FLAME:' /tmp/compiler-typecheck-profile.txt \
  | sed 's/^FLAME://' \
  > /tmp/compiler-typecheck.collapsed
flamegraph.pl /tmp/compiler-typecheck.collapsed \
  > /tmp/compiler-typecheck.svg
```

Current `FLAME:` rows contain one function name and inclusive total, not a
semicolon-separated sampled call stack. The resulting SVG is a flat visual
ranking, not a true call-hierarchy flame graph. Use explicit profile parent
rows, focused instrumentation, or an external sampling profiler when call
hierarchy is required.

A tall inclusive function may mostly contain expensive descendants. Use self
time, call counts, source inspection, and a bounded microbenchmark to
distinguish local cost, cumulative cost, and scaling.

For production-pass optimization experiments, prefer a paired benchmark before
making a speed claim. `benchmarks/compiler_pass_compare` alternates two already
executable pass benchmarks, preserves raw pairs, reports binary/source/fixture
provenance, and fails closed when semantic checksums differ. See
[`benchmarks/README.md`](../benchmarks/README.md#paired-production-pass-comparison)
for the Core consume-specialization and typecheck-phase pilot commands.

## Compiler Benchmarks

Compiler benchmark wrappers live in `benchmarks/`; fixtures and workers live in
`blorp/benchmark/compiler/`. Use the exact arguments and measurement window in
[`benchmarks/README.md`](../benchmarks/README.md). Its skip-build controls are
valid only when the executable and all imported sources match the revision
being measured.

## Production Typecheck Replay

Use the captured replay harness to measure compiler-on-compiler typechecking:

```bash
capture=$(mktemp "${TMPDIR:-/tmp}/blorp-typecheck-graph.XXXXXX.json")
bin/blorp check --no-format --capture-typecheck-request "$capture" \
  blorp/src/main.brp

benchmarks/compiler_typecheck_replay "$capture" \
  --target-only --timeout 180 --memory-limit 4G \
  --no-inventory --json

benchmarks/compiler_typecheck_replay "$capture" \
  --timeout 180 --memory-limit 4G --no-inventory --json
```

`--target-only` retains the complete prepared graph but emits only the request
target. It is usually the practical compiler-development feedback loop. Use the
full replay when the change affects graph-wide materialization or output.

Keep headline latency and RSS runs uninstrumented. Run allocation attribution
separately because `--allocator-stats` adds atomic traffic to managed
allocations and includes worker-startup counters:

```bash
benchmarks/compiler_typecheck_replay "$capture" \
  --target-only --timeout 180 --memory-limit 4G \
  --allocator-stats --no-inventory --json
```

The replay harness always samples child RSS. On macOS this invokes `ps` every
20 milliseconds and perturbs elapsed time, so treat macOS latency as diagnostic
or confirm it on Linux before making a headline claim. Use the same platform
and sampling mode for every baseline/candidate pair.

For a baseline/candidate comparison, create one clean checkout or worktree per
revision, run `make` in each, and build an explicitly retained worker from each
checkout:

```bash
cd /tmp/baseline-checkout
make
PYTHONPATH=benchmarks python3 -c \
  'from pathlib import Path; from compiler_typecheck_worker import prepare_typecheck_worker; print(prepare_typecheck_worker(Path.cwd(), Path("/tmp/baseline-worker"), None))'

cd /tmp/candidate-checkout
make
PYTHONPATH=benchmarks python3 -c \
  'from pathlib import Path; from compiler_typecheck_worker import prepare_typecheck_worker; print(prepare_typecheck_worker(Path.cwd(), Path("/tmp/candidate-worker"), None))'
```

Record each checkout commit and worker SHA-256. Then pass the matching worker
to replay from the checkout whose benchmark scripts are being used:

```bash
benchmarks/compiler_typecheck_replay "$capture" \
  --bridge /tmp/candidate-worker/compiler_typecheck_worker \
  --target-only --timeout 180 --memory-limit 4G \
  --no-inventory --json
```

Run the same command separately with
`/tmp/baseline-worker/compiler_typecheck_worker`, alternate execution order,
and use a separate `--allocator-stats` matrix for allocation attribution.

Trustworthy performance evidence requires:

1. The same captured request for baseline and candidate.
2. Workers built from explicitly recorded source revisions.
3. Byte-identical successful responses.
4. Warmup before measured samples.
5. Alternating baseline/candidate order.
6. Multiple samples and medians, with raw samples retained.
7. No unrelated compiler builds, LSP indexing, or benchmark jobs during timing.
8. Latency, allocations/releases, retained objects/bytes, and peak RSS where
   relevant.
9. A scaling matrix when the suspected algorithm depends on modules,
   declarations, imports, type depth, or query count.

Elapsed time is important, but it is often the least stable early signal. Host
load, filesystem state, thermal behavior, sampling, and unrelated work can
move latency without changing the mechanism under investigation. Prefer
direct, repeatable measurements while iterating: allocation and release
counts, allocator bytes, retired instruction counts, deterministic visit or
candidate counters, peak and retained memory, and native stack samples. These
metrics can show whether the intended work disappeared even when wall-clock
results are noisy.

No single proxy proves a user-visible speedup. Use direct counters and samples
to establish causality, then use paired latency measurements on an appropriate
production-shaped workload when the claim is that users wait less. If latency
and direct metrics disagree, investigate the disagreement rather than choosing
the more favorable number.

A microbenchmark can prove a mechanism and expose an exponent. It cannot by
itself prove that compiling the compiler became faster. Use production replay
or a CI-shaped gate before accepting a broad optimization.

Store durable raw performance evidence under `benchmarks/results/` and state
the host, commands, source revisions, input hash, run order, sample count, and
known caveats.

## Memory And Ownership Diagnostics

Use the narrowest relevant instrumentation:

```bash
bin/blorp run --leak-check --timeout 30 --no-format program.brp
bin/blorp run --sanitize --timeout 30 --no-format program.brp
bin/blorp run --sanitize=undefined --timeout 30 --no-format program.brp
bin/blorp test --leak-check --timeout 180 blorp/test/compiler/test_relevant.brp
scripts/test leak
scripts/test compiler-core-sanitize
scripts/test compiler-blorp-sanitize
```

For ownership-sensitive compiler changes:

- Compare allocations and releases.
- Confirm retained objects and retained bytes return to the expected baseline.
- Read generated C around retains, releases, branch exits, closure environments,
  and returned values.
- Exercise success, failure, empty, and early-return paths.
- Run the existing ownership pass tests for the affected Core stage.

Allocation reduction is useful evidence, but lower allocation count does not
guarantee lower latency or RSS. Persistent indexes, larger objects, hashing,
and worse locality can reduce allocation calls while slowing the compiler.

## Generated Files And Cleanup

`bin/blorp test` and `bin/blorp run` use system temporary directories and clean up
automatically. `bin/blorp compile file.brp` can write generated C beside the
source when no temporary output path is supplied.

Prefer explicit temporary output:

```bash
tmpc=$(mktemp "${TMPDIR:-/tmp}/blorp-output.XXXXXX.c")
trap 'rm -f "$tmpc"' EXIT
bin/blorp compile --no-format -o "$tmpc" program.brp
```

Before committing, check for generated artifacts and unrelated changes:

```bash
git status --short
git diff --check
rg -l '^/\* Generated by blorp compiler \*/' \
  --glob '*.c' blorp standard_library pkg examples
```

Do not delete or revert changes you did not create. Worktrees may be dirty; read
the status first and use a separate worktree when isolation matters.

## Troubleshooting

### The Source Checks But The Compiler Build Fails

The current `bin/blorp` may be stale. Run `make`, then rerun the focused test with
the newly built executable. Self-hosting failures often appear in C emission or
host-C compilation rather than source typechecking.

### `scripts/compiler-check` Reports An Unowned Module

Update `blorp/test/compiler/compiler_test_ownership.json` with the production source,
its stage, and focused suite/check ownership. Then run:

```bash
scripts/compiler-check --validate-manifest
```

Do not assign unrelated ownership merely to make validation pass.

### A Test Passes Alone But Fails In A Gate

Reproduce the exact grouped source list from the failure artifact. Look for
module aliases, imported names, generated C symbols, constructors, globals, and
top-level initialization that collide only when sources share one artifact.

### A Gate Is Slow

Use:

```bash
scripts/test --timings --log-dir logs <gate>
```

Separate frontend/typecheck/Core time from host-C and execution time before
optimizing. Do not infer compiler speed from total CI duration without checking
queueing, build duplication, shard composition, cache state, and native C time.

### Generated C Contains An Unsupported-Function Marker

Find the first Core node the emitter could not lower. Dump the final relevant
Core snapshot, inspect the enclosing expression and child node, and add a
focused emitter test reproducing that exact shape. Avoid source-name or fixture-
specific backend exceptions.

### Profiling Results Are Noisy

Stop concurrent builds and language servers, warm the exact artifacts, alternate
run order, increase the bounded workload, retain raw samples, and compare
medians. If pair direction changes repeatedly, treat latency as inconclusive and
use deterministic work counters or allocation changes only as supporting
evidence.

Before committing, follow the review and validation rules in
[`AGENTS.md`](../AGENTS.md). For a preview release, use the separate
[`Preview Validation`](RELEASES.md#preview-validation) gate.
