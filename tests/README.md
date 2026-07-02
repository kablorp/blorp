# blorp Test Suite

## Running Tests

```bash
# Run default local test gates
scripts/test

# Run specific gates
scripts/test compiler-unit      # Compiler-internal OCaml/Alcotest tests
scripts/test compiler           # Fast compiler surface tests
scripts/test compiler-deep      # Generated-C audit, format/purify, compiler/blorp
scripts/test runtime            # Runtime language, std, and pkg tests
scripts/test leak               # Focused leak-check baselines
scripts/test doctest            # Doctests (std/ library)
scripts/test cli                # CLI, REPL, and LSP smoke/exit-code checks
scripts/test compiler-unit compiler  # Multiple gates
scripts/test --coverage         # Compiler-unit coverage report
scripts/test --verbose          # Print pass-by-pass child-runner output
scripts/test --log-dir logs     # Save complete gate logs with compact console output

# Run individual test files directly
./blorp test tests/test_blorp/types/test_struct.brp
scripts/test runtime
./blorp test --doc std/string.brp
```

`scripts/test` is the test entrypoint.

`scripts/test` is quiet by default: successful runs print gate headers
and the final summary, while failures print the failing cases and a short
excerpt. Use `--verbose` when debugging runner behavior or when you need the old
pass-by-pass stream.

`scripts/test` also holds a per-worktree build lock for the duration of the
gate. This keeps concurrent local invocations from racing on Dune build state,
coverage artifacts, or the root `./blorp` executable.

Gate runners that are consumed by `scripts/test` should emit one structured
summary line:

```text
BLORP_GATE_RESULT gate=<gate> status=<PASS|FAIL> passed=<n> failed=<n> tests=<n>
```

Human output can change, but this line is the stable contract used by the
top-level gate summary. `./blorp test` emits the line only when
`BLORP_GATE_RESULT=<gate>` is set by the parent runner.

## Terminology

- A **gate** is a top-level validation entry such as `compiler-unit`, `compiler`,
  `compiler-deep`, `runtime`, `leak`, `doctest`, or `cli`.
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
compiler/test/               # Compiler-internal OCaml/Alcotest tests
  run_tests.ml            # Test runner
  test_types.ml           # Types module tests
  test_env.ml             # Env module tests
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
    ├── format/            # Formatter tests
    └── purify/            # Purity analysis tests
```

## Writing Tests

### Compiler Unit Tests

Add tests in `compiler/test/test_*.ml`. See `test_types.ml` for examples. Run with `make compiler-unit-test`.

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

### Compiler Tests (should_pass / should_fail)

- `should_pass/`: Files must compile without errors (`./blorp check`)
- `should_fail/`: Files must produce a compile error. Add `-- EXPECT: <diagnostic line>` annotations to verify error messages. `EXPECT` exact-matches a normalized diagnostic line without file paths, line numbers, or source underlines. Use `-- EXPECT-CONTAINS: <substring>` only when a test deliberately needs to match raw output text.
- Runtime `TestSuite` assertions in compiler-test files are not executed by the compiler-test runner.

The test runner (`tests/test_compiler/run_compiler_tests.sh`) validates both directions automatically.

## Adding Tests

1. Choose the right location:
   - Compiler internals → `compiler/test/` (compiler-unit tests)
   - New syntax → `test_compiler/parser/`
   - Type inference behavior → `test_compiler/infer/`
   - Type checking rules → `test_compiler/typecheck/`
   - Language features → `test_blorp/` (appropriate subdirectory)
   - Standard library modules → `test_std/` mirroring `std/`; test files should start with `test_`
   - Optional packages/native bindings → `test_pkg/` mirroring `pkg/`; test files should start with `test_`
   - Runtime behavior → `test_blorp/` or `test_std/`; do not rely on a `TestSuite` inside `test_compiler/*/should_pass/`
   - CLI, REPL, and LSP smoke behavior → `tests/test_cli.sh`
   - LSP feature fixtures → `tests/lsp/fixtures/`, using `-- ^name`
     marker comments and a neighboring JSON spec
   - Standard library examples → doctests in `std/`
2. Add positive and negative compiler cases when both sides describe meaningful
   behavior. Do not add mirrored fixtures just to satisfy ceremony.
3. Use descriptive file names: `test_feature_name.brp`

### LSP Feature Fixtures

`tests/lsp/run_lsp_fixtures.py` starts `blorp lsp`, opens each fixture through
the Language Server Protocol, and checks the requests listed in the fixture's
JSON spec. Marker comment lines are removed before the document is sent to the
server, and the caret column points at the previous emitted source line:

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
python3 tests/lsp/run_lsp_fixtures.py ./blorp tests/lsp/fixtures
```

### VS Code Extension E2E

The VS Code extension has a slower end-to-end harness under `editor/vscode/`.
It launches a real VS Code extension host with the local extension installed,
opens `.brp` files, and verifies that the extension starts `./blorp lsp` and
routes diagnostics, hover, definition, completion, and references through VS
Code commands.

```bash
cd editor/vscode
npm install
npm run test:e2e
```

This gate downloads a VS Code test build into `editor/vscode/.vscode-test/` on
first run, so it is intentionally separate from the default local `scripts/test`
gates.
