# Blorp Developer Guide

This guide is the practical entry point for developing Blorp itself. It covers
the language toolchain, the self-hosted compiler, tests, diagnostics, generated
artifacts, memory checks, and performance measurement. It is written for both
human developers and automated coding agents.

Commands in this guide run from the repository root unless stated otherwise.
Use the repository's `./blorp` executable, not a separately installed release,
when validating a source checkout.

## Sources Of Truth

Start with the narrowest relevant source:

- [`AGENTS.md`](../AGENTS.md) defines repository-wide engineering rules and
  language principles.
- [`compiler/README.md`](../compiler/README.md) explains the compiler stages,
  build, and source layout.
- [`docs/ARCHITECTURE.md`](ARCHITECTURE.md) defines phase ownership and the
  exact Core pipeline.
- [`tests/README.md`](../tests/README.md) defines test locations, gate
  terminology, and fixture conventions.
- [`scripts/README.md`](../scripts/README.md) documents test and validation
  scripts.
- [`benchmarks/README.md`](../benchmarks/README.md) documents benchmark
  harnesses and their controls.
- `./blorp <command> --help` is authoritative for public CLI flags.

When documentation, tests, and implementation disagree, verify the current
implementation and tests first, then update stale documentation in the same
change.

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

The build downloads the compiler version pinned in `compiler/bootstrap.env`.
No globally installed Blorp compiler is required.

Pinned bootstrap assets currently support Darwin arm64 and Linux x86_64 or
arm64. Darwin x86_64 and other host platforms cannot resolve the pinned
bootstrap directly; use a supported host or the documented Docker workflow.

## First Build

```bash
git clone https://github.com/kablorp/blorp.git
cd blorp
make
./blorp --version
./blorp test --warmup-only
```

`make` performs a self-hosted build:

1. Resolve the pinned bootstrap compiler.
2. Build the deterministic source generator in `compiler/tools/`.
3. Generate build metadata, embedded standard-library source, and embedded
   runtime C.
4. Compile the current compiler sources to C.
5. Compile and install the resulting executable as `./blorp`.

Use these build targets during development:

```bash
make                    # Build and install ./blorp
make build-blorp-cli    # Build the compiler CLI artifact
make warm               # Build and warm the formatter cache
make clean              # Remove generated build products
make                    # Clean rebuild after make clean
```

Run `make` after changing compiler source before using `./blorp` to validate
self-host behavior. A source file can pass with an older executable while the
new compiler fails to build itself, so the executable timestamp and build
status matter.

## Repository Map

The primary development areas are:

```text
compiler/src/          Self-hosted compiler, split into numbered stages
compiler/tests/        Focused compiler implementation TestSuites
compiler/benchmarks/   Compiler-specific benchmark fixtures and workers
compiler/lib/          C runtime and native declarations
compiler/tools/        Deterministic build-time source generators
std/                   Portable standard library
pkg/                   Optional native-backed packages
tests/test_compiler/   Public compiler and tooling boundary fixtures
tests/test_blorp/      Language and runtime TestSuites
tests/test_std/        Standard-library runtime TestSuites
tests/lsp/             Native LSP process and protocol tests
scripts/               Build, test, CI, hygiene, and release helpers
benchmarks/            Benchmark runners, documentation, and results
docs/                  Maintained language and implementation references
```

The high-level compiler flow is:

```text
lex -> parse -> module load -> infer/typecheck -> Core lower -> Core passes
    -> ownership/closure/resource preparation -> C emission -> host C compiler
```

Do not move validation into a later phase merely because that phase has the
data at hand. Use [`docs/ARCHITECTURE.md`](ARCHITECTURE.md) to identify the
owner of a new rule or transformation.

## Daily Development Loop

A reliable narrow loop is:

1. Read the implementation, nearby tests, and local precedent.
2. Add or identify a test that fails for the intended reason.
3. Make one coherent change.
4. Format and typecheck the changed source.
5. Run the smallest behavior test that proves the change.
6. Inspect generated Core or C when the change crosses those boundaries.
7. Run manifest-owned compiler checks or the relevant broad gate.
8. Get a code review and a test-evidence review.
9. Record rough edges and measured performance claims.

Typical commands:

```bash
./blorp format --check --diff path/to/changed.brp
./blorp check --no-format path/to/changed.brp
./blorp test --timeout 180 compiler/tests/test_relevant_behavior.brp
scripts/compiler-check --changed
git diff --check
```

Use `--no-format` in diagnostic and performance commands after a separate
format check. This keeps formatting work out of the behavior or timing window.

## Running Blorp Programs

Given this file:

```blorp
func main(args: List[String]) -> Int:
	print("hello from blorp")
	0
```

the common workflows are:

```bash
./blorp check --no-format /tmp/hello.brp
./blorp run --no-format /tmp/hello.brp
./blorp run --release --no-format /tmp/hello.brp
./blorp run --timeout 10 --no-format /tmp/hello.brp -- first second
./blorp compile --no-format -o /tmp/hello.c /tmp/hello.brp
```

`run --release` compiles generated C with `-O2`. Development runs use the
normal non-release host-C configuration so failures remain easier to inspect.
Use `blorp run` for executable behavior; a raw `cc` command must reproduce the
platform, feature, wrapping-integer, include, and link flags selected by the
compiler and is therefore not a portable substitute.

Useful environment controls include:

```bash
BLORP_STD=std ./blorp check --no-format program.brp
BLORP_TIMEOUT=30 ./blorp run --no-format program.brp
BLORP_THREADS=4 ./blorp run --no-format program.brp
BLORP_NO_FORMAT=1 ./blorp check program.brp
```

Run `./blorp --help` for the complete current environment-variable list.

## Formatting, Purity, And Lint

```bash
./blorp format path/to/file.brp
./blorp format --check path/to/file.brp
./blorp format --check --diff compiler/src/stage_06_typecheck/

./blorp purify --dry-run path/to/file.brp
./blorp purify --verbose path/to/file.brp

./blorp lint path/to/file.brp
./blorp lint --format json path/to/file.brp
./blorp lint --fail-on-findings compiler/src/
./blorp lint --disable RULE_ID path/to/file.brp
```

`lint` typechecks the complete import graph but reports findings only for the
selected files. It never rewrites source.

## Test Placement

Put a test at the boundary whose behavior it proves:

| Change | Test location |
| --- | --- |
| Compiler implementation, internal data structure, or pass | `compiler/tests/` |
| Public parser/typechecker/codegen/tool CLI contract | `tests/test_compiler/` |
| Language or runtime behavior | `tests/test_blorp/` |
| Standard-library runtime behavior | `tests/test_std/` |
| Standard-library example | doctest in `std/` |
| LSP process/protocol behavior | `tests/lsp/` |
| Package lifecycle | package fixtures and `scripts/test package` |

New compiler implementation suites must be registered in
`compiler/tests/compiler_test_ownership.json`. Map each suite to the production
source it covers so `scripts/compiler-check --changed` can select it.

The old parser/inference/typecheck compatibility corpus under
`tests/test_compiler/*/should_pass` and `should_fail` is mostly frozen. Follow
[`tests/README.md`](../tests/README.md) before adding public fixtures there.

## Focused Tests

Run one or more Blorp TestSuite files directly:

```bash
./blorp test --timeout 180 compiler/tests/test_compiler_env.brp
./blorp test --timeout 180 \
  compiler/tests/test_compiler_typecheck_state.brp \
  compiler/tests/test_compiler_typecheck_decl.brp
./blorp test --repeat 3 tests/test_blorp/types/test_struct.brp
```

Run a doctest or a directory suite:

```bash
./blorp test --doc std/string.brp
./blorp test --suite --timeout 240 tests/test_std/list/
```

Exercise instrumentation at the smallest relevant boundary:

```bash
./blorp test --leak-check --timeout 180 compiler/tests/test_compiler_core_perceus.brp
./blorp test --sanitize --timeout 180 compiler/tests/test_compiler_core_emit.brp
./blorp test --sanitize=undefined --timeout 180 path/to/fiber_test.brp
./blorp test --profile --timeout 180 path/to/test.brp
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
scripts/compiler-check compiler/tests/test_compiler_env.brp
scripts/compiler-check --validate-manifest
```

Use `--changed` during iteration and the relevant stage before integrating a
cross-module compiler change. The command complements broad integration gates;
it does not replace them.

## Repository Test Gates

The main test entrypoint is `scripts/test`:

```bash
scripts/test                    # Default local gate set
scripts/test compiler-blorp     # Compiler .brp suites and public check fixtures
scripts/test compiler-tools     # Formatter, purify, and lint fixtures
scripts/test std-check          # Broad std/ typecheck sweep
scripts/test runtime            # Language, std, and package runtime tests
scripts/test leak               # Ownership and leak checks
scripts/test doctest            # Standard-library doctests
scripts/test cli                # CLI smoke and exit-code checks
scripts/test lsp                # Native LSP protocol tests
scripts/test package            # Package lifecycle tests
scripts/test compiler-blorp runtime
```

Control execution and output with:

```bash
scripts/test --serial
scripts/test --no-build compiler-blorp
scripts/test --timings runtime
scripts/test --verbose compiler-blorp
scripts/test --log-dir logs compiler-blorp runtime
```

The runner is intentionally quiet on success. `--log-dir` is generally more
useful than `--verbose` for a long gate because it preserves complete output
without flooding the terminal.

Every gate reports a machine-readable summary:

```text
BLORP_GATE_RESULT gate=<gate> status=<PASS|FAIL> passed=<n> failed=<n> tests=<n>
```

If a parent runner reports an invalid structured result, find the earlier child
failure first. The invalid summary is usually a consequence, not the root
cause.

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
./blorp test --timeout 240 source_a.brp source_b.brp source_c.brp
```

Grouped tests can expose import-name, module-alias, constructor, generated-name,
and initialization-order collisions that isolated files do not.

## Compiler Diagnostics

### Parsed And Typed Source

```bash
./blorp check --dump-ast --no-format program.brp
./blorp check --dump-typed-ast --no-format program.brp
./blorp compile --dump-ast --no-format program.brp
./blorp compile --dump-typed-ast --no-format program.brp
```

These are summaries, not complete expression-tree dumps.

### Core Pipeline Snapshots

```bash
./blorp compile --dump-core --no-format program.brp
./blorp compile --dump-core-after=lower,mono,closure --no-format program.brp
./blorp compile --stop-after=resolve --no-format program.brp
./blorp compile --check-invariants --dump-core-after=match --no-format program.brp
./blorp compile --dump-core-after=perceus \
  --dump-core-file=/tmp/program.core.txt --no-format program.brp
```

Supported snapshot names are printed by `./blorp compile --help`. Use the last
valid snapshot and the first invalid snapshot to localize a pass regression.
`--check-invariants` is especially useful after transformations that rewrite
identities, ownership, calls, or control flow.

### Generated C

Write generated C to a temporary path and inspect it directly:

```bash
tmpc=$(mktemp "${TMPDIR:-/tmp}/blorp-codegen.XXXXXX.c")
./blorp compile --no-format -o "$tmpc" program.brp
cc -fsyntax-only "$tmpc"
rg 'Blorp backend could not|unsupported function' "$tmpc"
rm -f "$tmpc"
```

For backend changes, inspect the relevant function body, retain/release order,
closure capture layout, and generated declarations rather than relying only on
successful host-C compilation. The broad warning contract lives in:

```bash
tests/test_compiler/codegen_audit/run_codegen_audit.sh ./blorp
```

That audit detects the host compiler and applies the repository's accepted
Clang or GCC warning policy. Do not copy Clang-only warning names into a generic
`cc` command.

### Diagnostic Fixtures

Expected public diagnostics use the marker conventions documented in
[`tests/README.md`](../tests/README.md). A negative fixture must verify the
message, not merely a nonzero exit status. For an ad hoc check:

```bash
set +e
output=$(./blorp check --no-format /tmp/invalid.brp 2>&1)
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
./blorp check --no-format --capture-typecheck-request "$capture" \
  compiler/src/stage_12_cli/main.brp
```

Captures contain source text and local paths. Keep them local and delete them
when the investigation is complete.

## Timing Compiler Phases

Use phase timing for a fast end-to-end orientation:

```bash
./blorp compile --time-phases --no-format program.brp
./blorp compile --time-phases --no-format \
  compiler/src/stage_12_cli/main.brp
```

Phase timing identifies the broad region to investigate. It is not enough to
attribute cost to a helper or accept an optimization.

Use `scripts/test --timings` when compilation of test artifacts is the concern:

```bash
scripts/test --timings --log-dir logs runtime
```

The timing record separates frontend, typecheck, Core, host-C, and execution
time for generated test artifacts.

## Function Profiling And Flame Graphs

Profile a Blorp program or compiler benchmark:

```bash
./blorp run --profile --no-format program.brp 2>/tmp/blorp-profile.txt
benchmarks/compiler_typecheck_profile 2 2 64 128 \
  2>/tmp/compiler-typecheck-profile.txt
```

The profile includes function rows and `FLAME:` rows. Function times are
inclusive: parent and child cumulative times overlap and must not be added.
Compare the same function, call count, and workload across revisions.

The current runtime profile registry stores at most 1,024 functions and
silently omits later registrations. A compiler-sized profile can therefore be
incomplete. Confirm that every function under investigation appears, and use a
focused benchmark or phase-specific profile when the whole-compiler registry is
saturated.

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

A tall function may be expensive because of its own work or because it contains
expensive descendants. Use call counts, source inspection, and a bounded
microbenchmark to distinguish self cost, cumulative cost, and scaling.

## Compiler Benchmarks

Compiler benchmark wrappers live in `benchmarks/`; fixtures and workers live in
`compiler/benchmarks/`. Read the corresponding section of
[`benchmarks/README.md`](../benchmarks/README.md) before running one because the
positional controls and measurement windows differ.

Representative commands include:

```bash
benchmarks/compiler_typecheck_profile 2 2 64 128
benchmarks/compiler_typecheck_phase_profile headers 20 8 32 64 4
benchmarks/compiler_import_graph_profile 3 30 32 20 fallback
benchmarks/compiler_module_binding_profile 100 64 16
benchmarks/compiler_core_flatten_profile aliases 10 128 4
benchmarks/compiler_scope_construction_profile 20 256 64
```

Most wrappers build a content-addressed benchmark executable. When the
workspace compiler is already current, the documented skip-build control can
shorten repeated runs:

```bash
BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 \
  benchmarks/compiler_core_flatten_profile aliases 10 128 4
```

Do not use skip-build controls unless the executable and all imported sources
are known to match the source revision being measured.

## Production Typecheck Replay

Use the captured replay harness to measure compiler-on-compiler typechecking:

```bash
capture=$(mktemp "${TMPDIR:-/tmp}/blorp-typecheck-graph.XXXXXX.json")
./blorp check --no-format --capture-typecheck-request "$capture" \
  compiler/src/stage_12_cli/main.brp

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

A microbenchmark can prove a mechanism and expose an exponent. It cannot by
itself prove that compiling the compiler became faster. Use production replay
or a CI-shaped gate before accepting a broad optimization.

Store durable raw performance evidence under `benchmarks/results/` and state
the host, commands, source revisions, input hash, run order, sample count, and
known caveats.

## Memory And Ownership Diagnostics

Use the narrowest relevant instrumentation:

```bash
./blorp run --leak-check --timeout 30 --no-format program.brp
./blorp run --sanitize --timeout 30 --no-format program.brp
./blorp run --sanitize=undefined --timeout 30 --no-format program.brp
./blorp test --leak-check --timeout 180 compiler/tests/test_relevant.brp
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

## Working By Compiler Area

### Parser, Syntax, And Formatting

- Update parser tests first.
- Keep `docs/GRAMMAR.md`, `docs/GUIDE.md`, and formatter behavior synchronized.
- Test both accepted and rejected syntax when both are meaningful.
- Run `scripts/test compiler-tools` for formatter or purify changes.

### Inference And Typechecking

- Start with focused suites in `compiler/tests/`.
- Use `--dump-typed-ast` for source-level shape and captured replay for graph
  performance.
- Preserve diagnostic order, ambiguity behavior, identity, and recovery paths.
- Profile call counts and scaling before adding caches or indexes.

### Core Passes

- Read `compiler/src/stage_09_core/pipeline.brp` and
  `pipeline_stage.brp` before changing pass order or ownership.
- Dump Core immediately before and after the affected pass.
- Use `--check-invariants` and the stage's focused tests.
- Run `scripts/test compiler-core-sanitize` for broad ownership-sensitive
  changes.

### Backend And Runtime

- Add a focused emitter/runtime regression first.
- Compile a public fixture and inspect generated C.
- Run host-C syntax/warning checks.
- Run leak and sanitizer modes.
- Use the codegen audit for warning and unsupported-emission regressions.

### CLI And LSP

- Preserve exit codes, structured output, and process cleanup.
- Use `scripts/test cli`, `scripts/test lsp`, and the focused Python tests under
  `tests/lsp/`.
- Keep temporary directories independent of a pre-existing repository-local
  `scratch/` directory.
- Verify shutdown kills child process groups and leaves no background server.

## Generated Files And Cleanup

`./blorp test` and `./blorp run` use system temporary directories and clean up
automatically. `./blorp compile file.brp` can write generated C beside the
source when no temporary output path is supplied.

Prefer explicit temporary output:

```bash
tmpc=$(mktemp "${TMPDIR:-/tmp}/blorp-output.XXXXXX.c")
trap 'rm -f "$tmpc"' EXIT
./blorp compile --no-format -o "$tmpc" program.brp
```

Before committing, check for generated artifacts and unrelated changes:

```bash
git status --short
git diff --check
rg -l '^/\* Generated by blorp compiler \*/' \
  --glob '*.c' compiler std tests examples
```

Do not delete or revert changes you did not create. Worktrees may be dirty; read
the status first and use a separate worktree when isolation matters.

## Troubleshooting

### The Source Checks But The Compiler Build Fails

The current `./blorp` may be stale. Run `make`, then rerun the focused test with
the newly built executable. Self-hosting failures often appear in C emission or
host-C compilation rather than source typechecking.

### `scripts/compiler-check` Reports An Unowned Module

Update `compiler/tests/compiler_test_ownership.json` with the production source,
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

## Before Committing

Use a checklist proportional to the change:

```bash
./blorp format --check --diff <changed .brp files>
./blorp check --no-format <changed production .brp files>
./blorp test --timeout 180 <focused suites>
scripts/compiler-check --changed
git diff --check
git status --short
```

Also confirm:

- The regression failed before the implementation and passes after it.
- Error-message tests check the expected text.
- Generated Core/C was inspected when applicable.
- Performance claims have baseline/candidate evidence.
- Documentation reflects user-visible or architectural changes.
- A code reviewer and test-evidence reviewer found no unresolved issue.
- No generated artifact or unrelated edit is included.
- Rough edges and deferred follow-ups are recorded explicitly.

Run the broader gate required by the blast radius before merging. For a preview
release, follow the complete gate list in [`AGENTS.md`](../AGENTS.md).

## Command Reference

The shortest useful command map is:

```bash
make                                      # Build ./blorp
./blorp --help                            # List public commands
./blorp <command> --help                  # Current flags
./blorp check --no-format file.brp        # Frontend/typecheck only
./blorp compile --no-format file.brp      # Generate C
./blorp run --no-format file.brp          # Compile and execute
./blorp test file.brp                     # Run a TestSuite
./blorp format --check --diff file.brp    # Check formatting
./blorp lint --fail-on-findings file.brp  # Typed lint gate
scripts/compiler-check --changed          # Focused compiler ownership gate
scripts/test --log-dir logs               # Default repository gates
scripts/test --timings runtime            # CI-shaped phase timing
./blorp compile --time-phases file.brp    # Compiler phase timing
./blorp run --profile file.brp            # Function profile
```

Use the linked subsystem documents for deeper contracts, but use this guide to
choose the first command and the evidence needed to finish a change.
