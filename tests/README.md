# blorp Test Suite

## Running Tests

```bash
# Run Blorp compiler, runtime, leak, doctest, and CLI gates
scripts/test

# Run specific gates
scripts/test compiler-blorp     # Blorp TestSuites + marked production check fixtures
scripts/test compiler-tools     # Formatter and purify public CLI fixtures
scripts/test std-check          # Broad std/ typecheck sweep
scripts/test runtime            # Runtime language, std, and pkg tests
scripts/test leak               # Ownership suites, leak baselines, and diagnostics
scripts/test doctest            # Doctests (std/ library)
scripts/test cli                # CLI and LSP smoke/exit-code checks
scripts/test cli-deep           # Full CLI package and formatter integration checks
scripts/test lsp                # Public LSP protocol fixtures
scripts/test package            # Focused public package lifecycle integration
scripts/test compiler-blorp runtime  # Multiple gates
scripts/test --timings          # Print generated TestSuite phase timings
scripts/test --verbose          # Print pass-by-pass child-runner output
scripts/test --log-dir logs     # Save complete gate logs with compact console output

# Run individual test files directly
./blorp test tests/test_blorp/types/test_struct.brp
scripts/test runtime
./blorp test --doc std/string.brp
```

`scripts/test` is the test entrypoint.

Its default compiler coverage is the production-owned `compiler-blorp` suite.
New compiler implementation coverage belongs under `compiler/tests/`.
Leak-owned runtime sources execute only under leak instrumentation. Other
runtime roots execute in bounded groups and report one validated aggregate.

`scripts/test` is quiet by default: successful runs print gate headers
and the final summary, while failures print the failing cases and a short
excerpt. Use `--verbose` when debugging runner behavior or when you need the old
pass-by-pass stream.
Use `--timings` to report generated TestSuite frontend, typecheck, Core, host-C,
and execution phase totals. Raw timing records are retained in logs saved with
`--log-dir`.

`scripts/test` also holds a per-worktree build lock for the duration of the
gate. This keeps concurrent local invocations from racing on generated build state,
coverage artifacts, or the root `./blorp` executable.

Gate runners that are consumed by `scripts/test` should emit one structured
summary line:

```text
BLORP_GATE_RESULT gate=<gate> status=<PASS|FAIL> passed=<n> failed=<n> tests=<n>
```

Human output can change, but this line is the stable contract used by the
top-level gate summary. `./blorp test` emits the line only when
`BLORP_GATE_RESULT=<gate>` is set by the parent runner. Generated TestSuite and
doctest artifacts report exact case counts through an internal machine record;
a direct leak-baseline program counts as one case.

## Terminology

- A **gate** is a top-level validation entry such as `compiler-blorp`,
  `compiler-tools`, `std-check`, `runtime`, `leak`, `doctest`, `cli`,
  `cli-deep`, `lsp`, or `package`.
- A **suite** is an organized group inside a gate, such as
  `typecheck/should_fail`, `codegen_audit`, or one `.brp` file containing a
  `tests: TestSuite` value.
- A **case** is the smallest checked behavior: one compiler fixture, one
  `TestSuite` entry, or one doctest example.

Prefer these terms in runner output, docs, and new scripts. Avoid using
"suite" for both the top-level gate and the individual checks inside it.

## Test Organization

```
scripts/test              # Main local test gate
scripts/premerge-gate     # Full local pre-merge validation gate
scripts/docker-gate       # Docker-backed validation gate
scripts/with-build-lock   # Shared lock wrapper for build/test gates
compiler/tests/       # Production compiler implementation TestSuites
tests/
├── test_blorp/            # Language feature tests (TestSuite-based)
│   ├── types/             # Type system, pattern matching, control flow
│   ├── text/              # String interpolation, raw strings, slicing
│   ├── collections/       # Cross-cutting collection syntax/import behavior
│   ├── numeric/           # Safe arithmetic, bounds checking, dims
│   ├── functions/         # Closures, generics, monomorphization, HOF
│   ├── sys/               # CLI args, runtime safety
│   ├── memory/            # ARC, COW, leak detection tests
│   ├── concurrency/       # Concurrent blocks, channels, fibers
│   ├── tools/             # Tooling/runtime helper tests
│   └── simd/              # SIMD compatibility and runtime tests
├── test_std/              # Runtime tests for std/, mirroring std/ where practical
│   ├── list/ dict/ set/   # Core collection tests
│   ├── cache/ deque/ heap/ sorted_map/
│   ├── io/                # I/O module tests
│   └── stream/            # Stream tests
├── test_pkg/              # Optional runtime tests for pkg/, created when pkg tests exist
├── test_cli.sh            # CLI smoke and exit-code checks used by scripts/test
├── test_leak_report.sh    # Leak-report diagnostic smoke used by scripts/test leak
├── lsp/                   # Marker-based LSP integration fixtures
└── test_compiler/         # Compiler behavior tests
    ├── parser/            # Parser/lexer tests
    │   ├── should_pass/   # Valid syntax that must parse
    │   └── should_fail/   # Invalid syntax that must be rejected
    ├── infer/             # Type inference tests
    │   ├── should_pass/   # Valid programs
    │   └── should_fail/   # Expected type errors
    ├── typecheck/         # Type checking tests
    │   ├── should_pass/   # Valid programs
    │   └── should_fail/   # Expected type errors
    ├── codegen_audit/     # Generated-C audits and warning regressions
    ├── format/            # Public formatter fixtures run by compiler-tools
    ├── purify/            # Public purify fixtures run by compiler-tools
    └── run_compiler_tool_fixtures.py
```

## Writing Tests

### Compiler Implementation Tests

Put production compiler implementation tests under `compiler/tests/` and
run them with `scripts/test compiler-blorp`. Public parser, typechecking,
code-generation, formatter, purify, and lint fixtures live under
`tests/test_compiler/`.

### Runtime Tests (TestSuite)

```blorp
import:
    test: TestSuite

func test_feature() -> Bool:
    actual == expected

tests: TestSuite = {
    description = "Feature Tests",
    tests = [("feature works", test_feature)]
}
```

Run with: `./blorp test path/to/test.brp`

### Frozen Compatibility Fixtures

The parser, inference, and typecheck `should_pass`/`should_fail` corpus under
`tests/test_compiler/` records compatibility-frontend behavior and is frozen.
Do not add new cases there. The 35 existing files marked `RUN-BLORP-CHECK` are
the exception to dormant execution: `run_blorp_check_fixtures.py` invokes
production `blorp check` and validates their `EXPECT-BLORP` diagnostics as part
of `compiler-blorp`. Unmarked parser, inference, and typecheck fixtures are not
executed.

New compiler behavior and diagnostics belong in `compiler/tests/`. Add a
marked public-boundary fixture only when its CLI diagnostic contract cannot be
expressed there, and update the runner's expected fixture count in the same
change.

## Adding Tests

1. Choose the right location:
   - Compiler internals → `compiler/tests/`
   - New syntax, inference, and type checking behavior → `compiler/tests/`
   - Language features → `test_blorp/` (appropriate subdirectory)
   - Standard library modules → `test_std/` mirroring `std/`; test files should start with `test_`
   - Optional packages/native bindings → `test_pkg/` mirroring `pkg/`; test files should start with `test_`
   - Runtime behavior → `test_blorp/` or `test_std/`; do not rely on a `TestSuite` inside `test_compiler/*/should_pass/`
   - CLI smoke behavior → `tests/test_cli.sh --smoke`
   - Focused package lifecycle behavior → `tests/test_cli.sh --package`
   - Full CLI package/formatter integration behavior → `tests/test_cli.sh --all`
   - Native LSP lifecycle, document-sync, and diagnostics behavior →
     `tests/lsp/test_lsp_native_baseline.py`
   - Deferred LSP capability fixtures → `tests/lsp/fixtures/`, using `-- ^name`
     marker comments and a neighboring JSON spec; wire each group into the gate
     only when the native server advertises that capability
   - Standard library examples → doctests in `std/`
2. Add positive and negative compiler cases when both sides describe meaningful
   behavior. Do not add mirrored fixtures just to satisfy ceremony.
3. Use descriptive file names: `test_feature_name.brp`

### LSP Feature Fixtures

`tests/lsp/test_lsp_native_baseline.py` owns the production process contract.
It verifies initialization, full document synchronization, current diagnostics,
shutdown, and exit through `blorp lsp`. The semantic corpus is intentionally
preserved for capabilities added after the native cutover.

`tests/lsp/run_lsp_fixtures.py` opens those deferred fixtures and checks the
requests listed in each neighboring JSON spec. Marker comment lines are removed
before the document is sent to the server, and the caret column points at the
previous emitted source line:

The `scripts/test lsp` gate first runs
`tests/lsp/test_lsp_fixture_process.py`, which verifies that failed shutdown
terminates the public server process group.

```blorp
func add(a: Int, b: Int) -> Int:
-- ^add_decl
    a + b

func main(args: List[String]) -> Int:
    add(1, 2)
--  ^add_use
```

Run just the fixture suite with:

```bash
scripts/test lsp
```

### VS Code Extension E2E

The VS Code extension has a slower end-to-end harness under `editor/vscode/`.
The production baseline may use it to verify that the extension starts
`./blorp lsp` and receives diagnostics. Hover, definition, completion, and
references remain deferred capability fixtures; do not require those assertions
until the native server advertises the corresponding provider.

```bash
cd editor/vscode
npm install
npm run test:e2e
```

This gate downloads a VS Code test build into `editor/vscode/.vscode-test/` on
first run, so it is intentionally separate from the default local `scripts/test`
gates.
