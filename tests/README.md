# blorp Test Suite

## Running Tests

```bash
# Run all test suites
scripts/run_tests.sh

# Run specific suites
scripts/run_tests.sh unit               # OCaml unit tests (compiler internals)
scripts/run_tests.sh compiler           # Compiler tests (should_pass/should_fail)
scripts/run_tests.sh runtime            # Runtime language, std, and pkg tests
scripts/run_tests.sh leak               # Focused leak-check baselines
scripts/run_tests.sh doctest            # Doctests (std/ library)
scripts/run_tests.sh cli                # CLI smoke and exit-code checks
scripts/run_tests.sh unit compiler      # Multiple suites
scripts/run_tests.sh --coverage         # Unit tests with coverage report

# Run individual test files directly
./blorp test tests/test_blorp/types/test_struct.brp
scripts/run_tests.sh runtime
./blorp test --doc std/string.brp
```

## Test Organization

```
scripts/run_tests.sh      # Master test runner (all suites)
compiler/test/               # OCaml unit tests (Alcotest)
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
│   └── simd/              # SIMD tests (skipped by default)
├── test_std/              # Runtime tests for std/, mirroring std/ where practical
│   ├── list/ dict/ set/   # Core collection tests
│   ├── cache/ deque/ heap/ sorted_map/ graph/
│   ├── io/                # I/O module tests
│   └── stream/            # Stream tests
├── test_pkg/              # Optional runtime tests for pkg/, created when pkg tests exist
├── test_cli.sh            # CLI smoke and exit-code checks
├── stages/                # Golden lexer/parser/typecheck snapshots
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

### OCaml Unit Tests

Add tests in `compiler/test/test_*.ml`. See `test_types.ml` for examples. Run with `make unit-test`.

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
- `should_fail/`: Files must produce a compile error. Add `-- EXPECT: <substring>` annotations to verify error messages.

The test runner (`tests/test_compiler/run_compiler_tests.sh`) validates both directions automatically.

## Adding Tests

1. Choose the right location:
   - Compiler internals → `compiler/test/` (OCaml unit tests)
   - New syntax → `test_compiler/parser/`
   - Type inference behavior → `test_compiler/infer/`
   - Type checking rules → `test_compiler/typecheck/`
   - Language features → `test_blorp/` (appropriate subdirectory)
   - Standard library modules → `test_std/` mirroring `std/`; test files should start with `test_`
   - Optional packages/native bindings → `test_pkg/` mirroring `pkg/`; test files should start with `test_`
   - CLI behavior → `tests/test_cli.sh`
   - Standard library examples → doctests in `std/`
2. Always add both `should_pass` and `should_fail` cases for compiler tests
3. Use descriptive file names: `test_feature_name.brp`
