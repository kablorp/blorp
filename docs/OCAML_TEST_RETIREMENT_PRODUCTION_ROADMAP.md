# OCaml Test Retirement Production Roadmap

Status: OCaml test execution retired; historical sources archived

Audit date: 2026-08-09

Policy completed: 2026-08-11

The production `blorp test` command and all maintained compiler test gates are
Blorp-owned. The OCaml test runner, fixture runner, Dune stanzas, shell routes,
Make/CMake targets, Alcotest dependency closure, and CI test-dependency install
mode have been removed. `compiler/test/test_*.ml` remains as a 47-file,
non-executable historical archive documented by `compiler/test/FROZEN.md` and
`docs/OCAML_TEST_COVERAGE_LEDGER.tsv`.
The public formatter and purify fixtures remain active through the non-OCaml
`compiler-tools` gate.

The private production OCaml host is outside this retirement boundary and still
builds while package and LSP commands depend on it. New or replacement coverage
belongs in Blorp-owned TestSuites or public command fixtures.

## Historical Roadmap (Superseded)

The audit, checkpoints, command transcripts, and counts below record the path to
the completed retirement. They describe earlier repository states and are not
current commands or supported test entry points.

## Pre-Fix Default-Suite Audit

The audited command was the actual default flow before Slice 0, including its
normal build:

```bash
scripts/test --log-dir "$log_dir"
```

No gate names and no `--no-build` flag were supplied. The result was:

| Gate | Result | Passed | Failed | Tests | Time |
|---|---:|---:|---:|---:|---:|
| Compiler | PASS | 1504 | 0 | 1504 | 1m17s |
| Runtime | FAIL | 4479 | 1 | 4480 | 1m48s |
| Leak | FAIL | 121 | 1 | 122 | 1m03s |
| Doctest | PASS | 1053 | 0 | 1053 | 21s |
| CLI | PASS | 79 | 0 | 79 | 1m30s |
| Total | FAIL | 7236 | 2 | 7238 | 5m59s gate sum |

The two failed gate records have one shared root cause. There are also two
error-like output classes that do not fail a gate.

### Real failure: leading-dot continuation consumes a statement boundary

Both `runtime` and `leak` include
`tests/test_std/list/test_list_pipeline_fusion.brp`. Four functions in that file
fail:

- `test_filter_map_collect_ufcs`
- `test_float_filter_map_collect_ufcs`
- `test_string_filter_map_collect_ufcs`
- `test_string_filter_map_hof_map_collect_shared_source`

Each function has a more-indented leading-dot method chain followed by a
same-indent parenthesized Boolean expression. The parser consumes the chain's
`DEDENT`, then incorrectly continues postfix parsing and treats the `(` as a
call on the resulting `List`.

The grammar says that `NEWLINE` separates statements and that leading-dot
method chains continue only on more-indented lines. The implementation around
`parse_postfix_expr` in
`compiler/blorp/src/stage_03_parse/language_parser.brp` consumes the continuation
dedent without preserving the statement boundary before checking for a call.
This is therefore a parser continuation defect, not evidence that list
pipeline fusion itself is broken.

The four root diagnostics are:

```text
Cannot call non-function type: List[Int]
Cannot call non-function type: List[Float]
Cannot call non-function type: List[String]
Cannot call non-function type: List[String]
```

Each root error produces three cascading diagnostics:

- the declared `List[...]` binding receives `Void`;
- the function body returns `Void` instead of `Bool`; and
- the typed call lacks resolved-call metadata.

That is 16 diagnostics from four parse associations. A direct isolated run of
the file reproduces the same behavior, so batching, suite isolation, and leak
instrumentation are not causes.

The failure appears twice because `scripts/test` includes all of `tests/test_std`
in `runtime` and explicitly includes this file in `leak`.

Required fix:

1. Add a minimal parser `should_pass` regression contrasting a single-line
   initializer with a more-indented leading-dot initializer, both followed by
   a same-indent parenthesized expression.
2. Stop postfix parsing when the leading-dot continuation indent closes.
3. Verify the AST has two statements before relying on typecheck behavior.
4. Run the focused parser fixture and list suite, then `runtime` and `leak`.
5. Consider separately suppressing resolved-call invariant cascades after an
   earlier expression error. That diagnostic cleanup is not required to fix
   the parser defect.

### Non-failing noise: leak-report broken pipe

`tests/test_leak_report.sh` prints:

```text
echo: write error: Broken pipe
```

The script stores a large verbose leak report, pipes `echo` into `grep -q`, and
`grep` exits as soon as it finds a match. The shell builtin then receives
`EPIPE`. The pipeline still evaluates as successful because the script does
not enable `pipefail`, so all five leak-report assertions pass.

Replace the pipeline with a here-string or another bounded match that does not
write into an early-closing pipe. Verify `tests/test_leak_report.sh` directly
and through `scripts/test leak`.

### Expected nested failure text

The runtime log contains:

```text
FAIL: x < 50 - smallest counterexample: ...
```

This is output from `std/property.brp` while
`test_shrink_finds_minimal` deliberately checks that a false property is found.
The surrounding TestSuite case passes, and it does not contribute to the gate
failure count. It may be relabeled as an expected counterexample later to make
logs easier to scan, but it is not a correctness blocker.

### Other error-like matches

Doctest names containing `Error` or `DecodeError` are passing test names. The
compiler, doctest, and CLI logs contain valid structured PASS summaries and no
unexplained failure records.

The runtime log also contains one intentional `ERROR: error message` line from
the logging-level test. Its enclosing suite passes. Together with the expected
property counterexample above, these are the only failure-looking runtime lines
that remain after Slice 0.

## Post-Fix Default Verification

The exact default dispatcher, including its normal build/install check, was
rerun after a clean `make install` and Slices 0-2:

```bash
scripts/test --log-dir /tmp/blorp-checkpoint-a-clean-default
```

| Gate | Result | Passed | Failed | Tests | Time |
|---|---:|---:|---:|---:|---:|
| Compiler-unit | PASS | 550 | 0 | 550 | 1m21s |
| Compiler | PASS | 1504 | 0 | 1504 | 1m23s |
| Runtime | PASS | 4875 | 0 | 4875 | 1m58s |
| Leak | PASS | 445 | 0 | 445 | 1m06s |
| Doctest | PASS | 1053 | 0 | 1053 | 21s |
| CLI | PASS | 79 | 0 | 79 | 1m29s |
| Total | PASS | 8506 | 0 | 8506 | 6m13s elapsed |

No real diagnostic, timeout, broken pipe, or unexplained shell error appears in
the retained logs. `make quality`, the stage-two no-host route, the full Darwin
UBSan runtime sweep, and the focused Core ASan+UBSan gate also pass. Premerge,
the broader compiler sanitizer, and Docker parity remain explicit matrix items
rather than being inferred from these results.

## Current Test Architecture

### Production test route

`./blorp test` owns discovery, TestSuite/doctest harness generation, combined
artifacts, compilation, execution, timeout handling, leak/profile policy, and
aggregate reporting. CLI tests already prove that representative test shapes
succeed while `BLORP_OCAML_HOST_BIN` names a missing executable. Session
counters describe the retained source graph and generated test artifacts.

This is the part of the migration that is complete.

### Compiler fixture route

`scripts/test compiler` still builds and invokes:

```text
tests/test_compiler/run_compiler_tests.sh
  -> compiler/test/runner/compiler_fixture_runner.exe
  -> compiler/test/runner/compiler_test_runner.ml
```

Its current routing is:

| Corpus | Cases | Production Blorp | OCaml compatibility |
|---|---:|---:|---:|
| Parser | 222 | 0 direct | 222 through the OCaml wrapper/parser bridge |
| Infer | 488 | 0 | 488 |
| Typecheck | 794 | 19 | 775 |
| Total | 1504 | 19 | 1485 |

The 19 production cases contain `-- RUN-BLORP-CHECK`. The other 1263
infer/typecheck cases call the OCaml typecheck pipeline directly. Eighty-five
fixtures have Blorp-specific expectation annotations, demonstrating that the
two frontends still have known semantic or diagnostic differences.

Passing the `compiler` gate therefore does not prove that the production Blorp
frontend accepts or rejects most of this corpus.

### Corrected internal test boundary

The over-broad deletion was not retained. `run_tests.ml`, its Dune stanza,
Alcotest dependencies, and every active or unclassified suite are restored.
Only `test_test_runner.ml` and `test_doctest_remap.ml` are deleted with the
production-dead implementation they exercised. The retained runner now covers
550 default and 259 deep cases. Relative to the earlier 260-case deep suite,
two private `Test_runner` cases were removed and one active process-status
regression was added.

## OCaml-Test Inventory

### CI and gate wiring

| Location | Current role | Required disposition |
|---|---|---|
| `.github/workflows/ci.yml`, `.github/workflows/ci-platform.yml` | Invokes one isolated build/test/package graph per platform; Ubuntu splits retained compiler, compiler-Blorp, and product gates against one exact candidate; other OSes run `runtime leak cli lsp` | Implemented; retain OCaml setup while active host/runner remains |
| `.github/workflows/premerge.yml` | Manual/weekly only; invokes the full premerge script | Do not treat this as PR replacement coverage |
| `.github/workflows/release.yml` | Builds and packages the private OCaml host | Keep until package and LSP production routes are ported |
| `scripts/premerge-gate` | Runs retained unit gates plus compiler, Blorp, std, runtime, CLI, LSP, and package coverage | Implemented for Checkpoint A |
| `scripts/test` | Default gate dispatcher; invokes the OCaml compiler fixture runner for `compiler` | Implemented: retain both OCaml unit scopes while active code still depends on their coverage |
| `CMakeLists.txt` | Exposes both retained unit scopes plus compiler, compiler-Blorp, runtime, leak, doctest, CLI, LSP, and package gates | Implemented for Checkpoint A; keep aligned with named script gates |
| `Makefile` | Exposes `test`, both retained unit scopes, compiler-Blorp, LSP, package, quality, sanitizer, and Docker entry points | Implemented for Checkpoint A; retain host build targets |

Normal pull requests now run the 153 files under `compiler/blorp/tests` through
the explicit `compiler-blorp` gate. `compiler-deep` retains the same aggregate
for premerge compatibility until its codegen/tool components are split further.

### Test implementation and dependencies

| Location | Current role | Required disposition |
|---|---|---|
| `compiler/lib/test_runner.ml/.mli` | Deleted production-dead test implementation | Implemented at Checkpoint A; inventory checks forbid reintroduction |
| `compiler/test/test_test_runner.ml` | Deleted implementation-only suite | Implemented at Checkpoint A with the retired implementation |
| `compiler/test/test_doctest_remap.ml` | Deleted implementation-only remapping suite | Implemented after case review and public doctest verification |
| `compiler/test/run_tests.ml` | Aggregates 46 active default/deep suite groups | Restored for Checkpoint A with only proven-dead suites removed |
| `compiler/test/test_lsp_*.ml` | Focused tests for active OCaml LSP | Retain until public JSON-RPC coverage reaches parity |
| `compiler/test/test_package_*.ml` | Focused tests for active OCaml package commands | Retain until public package boundary tests cover all contractual cases |
| Other `compiler/test/test_*.ml` | Types, env, inference, layout, session, pipeline, bridge, ABI, and runner invariants | Assign a coverage-ledger disposition before deletion |
| `compiler/test/runner/*.ml` | Active OCaml compatibility fixture runner and process helper | Retain through Checkpoint A; remove only after all 1504 cases use production Blorp and orchestration is no longer OCaml |
| `compiler/test/runner/dune` | Builds the compatibility runner | Same lifetime as the runner |
| `tests/test_compiler/test_runner_process.sh` | Covers deadlines, inherited-group cleanup, sustained output, and capture overflow with and without deadlines | Keep while the compatibility process helper exists |
| `compiler/blorp.opam*`, `compiler/dune-project` | Supply Alcotest and Dune dependencies for the retained internal suites | Retain through Checkpoint A; remove mechanically at Checkpoint B |
| `.github/actions/setup-cached-ocaml/action.yml`, `scripts/docker/Dockerfile` | Install with test dependencies | Retain while Alcotest remains; remove `--with-test` only when Dune has no maintained tests |

The retained `test_compiler_test_runner.ml` suite continues to cover expectation
fallback, frontend-specific override precedence, codegen summary accounting,
and infrastructure-status classification. Those behaviors need black-box
replacement tests before that suite is deleted at Checkpoint B.

### Public replacement surfaces

| Surface | Current evidence | Gap |
|---|---|---|
| Blorp `test` command | CLI no-host cases, stage-two no-host gate, 4875 runtime cases, 1053 doctests | Strong after the parser defect is fixed |
| Compiler implementation | 152 Blorp TestSuite files with 3001 registered cases | Required PR gate exists; sanitizer/codegen coverage remains premerge |
| LSP | `tests/lsp/run_lsp_fixtures.py` with 12 specs and 36 requests plus delegated-host cleanup coverage; audited runs pass | Required PR gate exists; diagnostics, malformed protocol, and document lifecycle still need parity review |
| Package manifest/hash/inventory | Blorp package TestSuites and parity fixtures | Required PR compiler-Blorp gate exists; hostile-input parity remains incomplete |
| Package lifecycle | Focused public pack/fetch/cache/vendor checks | Required PR package gate exists; tamper and hostile-input parity remains incomplete |
| Compiler surface | 1504 parser/infer/typecheck fixtures | 1485 still use compatibility routing |
| Codegen/ownership/ABI | Blorp Core suites, codegen audit, runtime and leak tests | Static builtin/runtime ABI and layout invariants need explicit ledger mapping |

The audited LSP fixture command passed all 12 specs and 36 requests:

```bash
python3 tests/lsp/run_lsp_fixtures.py ./blorp tests/lsp/fixtures
```

This is now a required CI foundation; public parity must still expand before
the retained LSP suites can be deleted.

### Scripts and self-tests

The following files enforce or describe test topology and must change in the
same slice as the topology:

- `tests/test_scripts_test_harness.sh`
- `tests/test_build_configuration.sh`
- `tests/test_compiler/run_compiler_tests.sh`
- `scripts/check-compiler-port-inventory`
- `scripts/README.md`
- `tests/README.md`
- `AGENTS.md`

The port-inventory script is now narrowed to the named retired files and
forbids reintroduction of the production `Test_runner` route. Expand the guard
again only as each active test group is retired with recorded replacement
evidence.

### Benchmark policy

The test-session benchmark previously required and fingerprinted an
`ocaml_host` route dependency in:

- `benchmarks/blorp_test_session_policy.json`
- `scripts/bench-blorp-test-session`
- `tests/test_blorp_test_session_benchmark.py`
- `benchmarks/README.md`

That automatic dependency was removed because the measured production test
route no longer invokes the host. Comparisons against a historical route that
really uses a host must pass that host through `--baseline-input` or
`--candidate-input`; the driver fingerprints explicit route inputs without
making the current production route depend on one.

### Documentation

Update these as current-state documents:

- `compiler/README.md`: remove claims that `test` delegates to OCaml and remove
  references to obsolete gate names only after their actual retirement.
- `docs/BLORP_TEST_SESSION_ROADMAP.md`: state that the production route is
  retired while active OCaml component tests remain transitional.
- `docs/BLORP_COMPILER_PORT_ROADMAP.md`: distinguish production command
  ownership from test implementation ownership.
- `docs/ARCHITECTURE.md`: retain package/LSP host boundaries and document the
  compatibility fixture runner accurately.
- `tests/README.md`, `scripts/README.md`, and `AGENTS.md`: list the gates that
  actually run and disclose compatibility routing counts.
- `CMakeLists.txt`: remove the assertion that Dune is authoritative for test
  gates only after Dune tests are genuinely gone.

Preserve historical compiler-unit counts in `docs/TYPECHECKING_ROADMAP.md` and
dated benchmark result files. They are evidence, not active instructions.

### OCaml references that must not be removed here

The following are active production-host concerns, not stale test references:

- `compiler/bin/blorp_ocaml_host.ml` and its Dune stanza;
- OCaml compiler libraries used by package and LSP commands;
- `scripts/package-release`, `scripts/install-dev`, and release archive checks;
- CI and release setup for the pinned OCaml toolchain;
- `BLORP_OCAML_HOST_BIN` tests that prove already-ported commands bypass the
  host; and
- language-comparison implementations under `benchmarks/ocaml`.

Removing these before package and LSP cutover would break production releases.

## Coverage Ledger

Every deleted suite group needs one of three explicit dispositions:

- `RETAIN`: active OCaml behavior still lacks public replacement coverage.
- `REPLACE`: named Blorp/public tests cover the same contract and run in CI.
- `RETIRE`: the behavior is unreachable or was an implementation detail of
  deleted code.

Current subsystem summary (the authoritative row-by-row table is
`docs/OCAML_TEST_COVERAGE_LEDGER.tsv`):

| Area | Initial disposition | Required proof before deletion |
|---|---|---|
| OCaml `Test_runner` | REPLACE | No production dispatch; no-host CLI and stage-two tests; runtime/doctest gates; retained compatibility process helper has separate coverage |
| Doctest remapping | RETIRE | Cases asserted only the deleted generator's private source-map representation; public doctest behavior remains gated |
| LSP completion/definition/hover/signature/state/protocol/RPC/diagnostics | RETAIN | Public JSON-RPC fixture parity, CI wiring, lifecycle and malformed-input cases |
| Package manifest/hash | RETAIN | Blorp unit parity plus public command cases exist, but hosted-command and hostile-input parity review is incomplete |
| Package artifact/config/cache/check | RETAIN | Unsafe paths, corruption, length limits, duplicate entries, config selection, tamper and lifecycle coverage |
| Types/env/infer/typecheck/refinement/widening/dim solver | REVIEW | Map contractual invariants to Blorp tests and surface fixtures; retain tests for still-reachable OCaml behavior |
| Session/pipeline/bridge | REVIEW | Public route/cache/reset proofs and Blorp bridge tests in CI |
| Builtin consistency, operation metadata, FFI and layouts | REVIEW | Static ABI audit or Blorp tests plus codegen/runtime evidence |
| Compatibility fixture runner | RETAIN | Expectation precedence, filtering, summary accounting, timeout cleanup, then complete production routing |

Store the case-by-case ledger as a checked-in table before deleting more suite
groups. It should name the old suite, disposition, replacement file or command,
CI gate, and reviewer conclusion. File-name similarity alone is not proof.

## Execution Plan

### Slice 0: make the branch diagnostically green

1. Add the leading-dot statement-boundary parser regression first.
2. Fix `parse_postfix_expr` so closing a continuation indent ends cross-line
   postfix parsing unless a new valid continuation is explicitly present.
3. Verify the four list functions without rewriting away the syntax under test.
4. Remove the leak-report `EPIPE` noise.
5. Re-run the exact default suite with retained logs and confirm every
   error-like line is classified.

Fast loop:

```bash
tests/test_compiler/run_compiler_tests.sh --filter <new-fixture>
./blorp test tests/test_std/list/test_list_pipeline_fusion.brp
tests/test_leak_report.sh
scripts/test --no-build runtime leak
```

Exit condition: default `scripts/test` is green; no real diagnostic or shell
error is hidden by a passing aggregate.

### Slice 1: narrow the deletion to the proven-dead test subsystem

1. Restore `run_tests.ml`, its Dune stanza, Alcotest dependencies, and internal
   suites for active or unclassified OCaml code.
2. Remove the `Test_runner` implementation and its dedicated suite.
3. Remove doctest-remap tests only if the case-by-case review proves they are
   exclusive to the retired implementation.
4. Keep the split `process_runner` helper if the compatibility runner needs it.
5. Restore `compiler-unit` and `compiler-unit-deep` gates for the retained
   suites. Names may change, but CI-visible coverage must exist before old names
   disappear.
6. Narrow the port-inventory guard to the exact retired files.
7. Update docs to describe this checkpoint without claiming all OCaml tests are
   gone.

Fast loop:

```bash
cd compiler && dune build
scripts/test compiler-unit
scripts/test compiler-unit-deep
tests/test_compiler/test_runner_process.sh
scripts/check-compiler-port-inventory
```

Exit condition: active OCaml production code has at least its pre-change
focused coverage, while the obsolete test command cannot be restored silently.

### Slice 2: put replacement coverage on every pull request

1. Split compiler-owned Blorp TestSuites out of the expensive codegen-heavy
   `compiler-deep` aggregate into a named `compiler-blorp` gate.
2. Run `compiler-blorp` on Ubuntu pull requests. Keep codegen audit and
   sanitizers in premerge.
3. Wire `tests/lsp/run_lsp_fixtures.py` into a structured gate and run it on
   Ubuntu pull requests. Run it on all release platforms before release.
4. Add a focused package integration selection that covers package contracts
   without paying for all of `cli-deep`; run it on Ubuntu pull requests.
5. Keep main CI under its timeout by running independent gates as separate jobs
   or measured waves rather than dropping coverage.
6. Add build-configuration and script-harness tests for every new gate.

Exit condition: a pull request cannot change compiler-owned Blorp code, active
LSP behavior, or active package behavior without executing the corresponding
replacement tests.

### Slice 3: retire active-host Alcotest suites by subsystem

Use separate, reviewable changes for each group.

LSP:

- map all deleted LSP suite cases to the 12 existing fixture specs;
- add missing document open/change/close, parse-cache invalidation,
  diagnostics, malformed JSON-RPC, cancellation/error, and cross-document
  state cases;
- verify completion, hover, definition, references, signature help, symbols,
  positions, and protocol framing through the public process boundary; and
- delete LSP Alcotest files only after the ledger is complete and the CI gate
  is required.

Package:

- retain the existing Blorp manifest/hash/inventory parity suites;
- expose a focused CLI package test selection for pack, fetch, cache, vendor,
  check, and tamper behavior;
- port unsafe artifact path, duplicate entry, oversized/truncated payload,
  corrupt cache, trailing config content, and nearest-config cases; and
- delete package Alcotest files only after the public command remains fully
  covered while still hosted by OCaml.

Compiler host and ABI:

- move builtin/runtime declaration consistency into a static quality audit;
- map result/type layout, FFI ownership, and operation-result metadata to named
  Blorp Core and generated-C tests;
- map session reset, cache identity, module origin, and bridge protocol cases
  to public or Blorp-owned tests; and
- retire representation-only assertions rather than porting obsolete data
  structure details.

Exit condition: each deleted group has `REPLACE` or `RETIRE` status with a
specific CI command.

### Slice 4: migrate the 1504 compiler fixtures

1. Add a machine-readable route summary to the fixture gate. CI should assert
   the exact production and compatibility counts so fallback cannot grow.
2. Resolve the 85 Blorp-specific expectation files first; they identify known
   diagnostic divergence.
3. Migrate bounded batches in this order:
   - parser should-pass and should-fail;
   - infer should-pass;
   - typecheck should-pass;
   - infer should-fail; and
   - typecheck should-fail.
4. For parser-only fixtures, use an explicit production parse mode or
   phase-specific API. Do not infer parser success from a later typecheck
   failure.
5. For negative fixtures, preserve exact normalized diagnostics and forbidden
   diagnostics, not only the exit code.
6. Decrease the compatibility count in every migration change and forbid
   unmarked fallback.
7. Once all 1504 cases use production Blorp, replace OCaml discovery and
   orchestration with a Blorp-owned or simple script runner and delete dual
   frontend expectations.

Fast loop:

```bash
tests/test_compiler/run_compiler_tests.sh --filter <fixture-or-directory>
scripts/test --no-build compiler
```

Exit condition: production count is 1504, compatibility count is zero, and the
gate does not build or load OCaml compiler libraries.

### Slice 5: delete the remaining OCaml test tooling

After Slices 2-4:

1. Delete `compiler/test/runner/*.ml` and its Dune stanza.
2. Delete the final retained Alcotest suites and aggregator.
3. Remove Alcotest from opam and lock files.
4. Remove obsolete `@runtest {with-test}`, `--with-test`, Make, CMake, script,
   and CI wiring.
5. Replace the temporary inventory guard with assertions that no OCaml test
   executable or Alcotest dependency exists.
6. Keep the production OCaml host build/release wiring until package and LSP
   themselves are ported.
7. Update all current-state docs in the same change; preserve historical logs.

Exit condition: no maintained test command compiles or executes OCaml test
code, while package and LSP may still use the explicitly packaged production
host.

## Fast Feedback Matrix

| Change | First command | Subsystem gate |
|---|---|---|
| Parser continuation | Filtered parser fixture | Direct list suite, then `runtime leak` |
| Leak script | `tests/test_leak_report.sh` | `scripts/test --no-build leak` |
| Blorp compiler test | `./blorp test compiler/blorp/tests/<file>.brp` | `scripts/test --no-build compiler-blorp` |
| LSP | `python3 tests/lsp/run_lsp_fixtures.py ./blorp tests/lsp/fixtures/<area>` | Structured LSP gate |
| Package | Focused package CLI selection or one Blorp package suite | Package gate, then `cli-deep` |
| Fixture migration | `run_compiler_tests.sh --filter <name>` | `scripts/test --no-build compiler` |
| Test topology | `tests/test_scripts_test_harness.sh` | `tests/test_build_configuration.sh`, quality |
| Test-session benchmark | Python benchmark unit tests | One smoke benchmark with missing OCaml host |

All manual compiler invocations must clean generated `.c` files from the
working tree. Use `git status --short` after every slice.

## Production Verification Matrix

Checkpoint A requires a clean-worktree-equivalent run of:

```bash
make clean
make install
make quality
scripts/test --serial compiler-unit compiler-unit-deep compiler runtime leak doctest cli
scripts/test --serial compiler-blorp compiler-deep std-check cli-deep lsp package
tests/test_cli_stage_two.sh --timeout 30
make test-asan
scripts/premerge-gate --no-clean --no-docker
scripts/docker-gate --premerge-gate --platform linux/amd64
scripts/docker-gate --premerge-gate --platform linux/arm64
git diff --check
git status --short
```

Checkpoint B uses the same matrix with `compiler-unit` gates replaced by the
required `compiler-blorp`, LSP, package, and production fixture gates. It must
also prove:

```bash
! rg -n "alcotest|run_tests\.exe|compiler-unit" \
  .github Makefile CMakeLists.txt compiler scripts tests docs/ARCHITECTURE.md \
  docs/BLORP_COMPILER_PORT_ROADMAP.md docs/BLORP_TEST_SESSION_ROADMAP.md
```

Intentional historical documents and explicit retirement guards must be
excluded or classified rather than erased.

Release verification must continue to assert that archives contain
`blorp-ocaml-host` until package and LSP no longer delegate to it.

## Commit Sequence

Keep the execution reviewable and bisectable:

1. Fix the parser continuation boundary and leak-report shell noise.
2. Narrow the current deletion to the dead `Test_runner` subsystem; restore
   active internal coverage and its gates.
3. Add PR-visible `compiler-blorp` and LSP gates.
4. Add focused package PR coverage and correct benchmark route dependencies.
5. Retire LSP, package, host/ABI, and compiler-internal Alcotest groups one
   subsystem at a time from the coverage ledger.
6. Migrate compiler fixtures in count-decreasing batches.
7. Delete the final OCaml test runner/dependencies and perform the documentation
   cleanup.

Checkpoint A can merge after commits 1-4 and the production matrix. Commits
5-7 complete Checkpoint B and should not be compressed into the first merge if
doing so weakens active production coverage.

## Final Acceptance Criteria

- `./blorp test`, default `scripts/test`, and stage-two test execution never
  invoke the OCaml host.
- The default suite is green with no unexplained `error`, `FAIL`, broken-pipe,
  timeout, or leaked-process output.
- No test for active production OCaml code is deleted without a named public or
  Blorp-owned replacement running in required CI.
- Pull-request CI runs compiler-owned Blorp tests and public LSP/package
  behavior, not only smoke commands.
- The compiler fixture route reports 1504 production cases and zero
  compatibility cases before its OCaml runner is deleted.
- Test-session benchmarks do not require or fingerprint an OCaml host.
- Inventory guards describe proven retirement boundaries rather than forbidding
  tests for still-active code.
- Documentation distinguishes the Blorp-owned test command from the remaining
  package/LSP production host and transitional compiler fixture runner.
- Release tooling retains the private host until its actual production users
  are ported.
