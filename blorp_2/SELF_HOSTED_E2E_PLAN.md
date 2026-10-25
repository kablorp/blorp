# First self-hosted e2e tests

Status: implemented after three design approvals; independent qualification
passed. See the [results](../benchmarks/results/blorp_2_self_hosted_e2e_2026-10-24.md).
Base: `40a58a45b` on main (equivalent isolated
routing change `ab1895a1a`). The implementation is in this change; no new bootstrap pin is required.
This is a small executable slice, not a port of the complete deferred harness.

## Problem and first witness

At the base revision, `make -C blorp_2 test-e2e` exited 2 with an explicit DEFERRED message.
The old driver imports unavailable `process`, `fs` and `bytes` APIs and uses
unsupported source forms. Existing read/write operations and ordinary TestSuites
are already sufficient for text assertions; starting child processes is missing.

First acceptance: a Blorp 2 compiled TestSuite driver uses Blorp 2 to compile
`test/e2e/fixtures/return/zero.brp`, invokes the configured C compiler, runs the
unmodified fixture's real main, and checks exit 0 and exact empty output.
No legacy compiler participates in building or running any of these stages.
First red command, before edits:

```sh
make -C blorp_2 test-e2e
# Expected: exit 2 and the existing explicit DEFERRED diagnostic.
```

Read applicable AGENTS and [HANDOFF_SPEC](../docs/HANDOFF_SPEC.md). The current
boundaries are `test/e2e/harness.brp`, `standard_library/system.brp`,
`standard_library/test.brp`, `src/namespace/builtins.brp` and `Makefile`.
The deferred harness and fixtures remain intact for later migration.

## One narrow runtime capability

Add a separate, explicitly imported `standard_library/process.brp`:

```blorp
import:
    _base: Int, String, List, Result

-- program is an explicit executable path, not a PATH lookup or shell command.
-- arguments excludes argv[0]; runtime supplies program as argv[0].
func run_to_files(
    program: String, arguments: List[String],
    stdout_path: String, stderr_path: String, timeout_ms: Int,
) -> Result[Int, String]:
    builtin("process.run_to_files")
```

Contract:

- Return `Ok(status)` for an ordinary exit, including nonzero and 127. Return
  `Err(message)` for setup/exec failure, signal termination, timeout or cleanup
  failure. Never encode signals/timeouts as negative or magic exit codes.
- Validate positive finite timeout, executable path, arguments and capture paths
  before creating files. Reject embedded NULs. Preserve empty, spaced, Unicode
  and metacharacter arguments literally; use no shell, quoting parser or PATH
  search. Make resolves compiler/tool paths explicitly.
- Create **two new regular capture files exclusively**. Existing paths are
  errors, including existing symlinks/FIFOs; no truncation, append or path-string
  alias guessing. Same destination and aliases cannot both be exclusively
  created. On Err, newly created partial files may remain for Make cleanup;
  existing files must remain unchanged. Check file kind before spawning.
- Stdin reads EOF from `/dev/null`. Inherit cwd and environment. First tests use
  the repository root; configurable cwd, stdin and environment APIs are deferred.
  Ordinary explicit `/usr/bin/env` argv may set/unset leak variables for a child.
- Use a monotonic deadline covering the exec handshake and child wait. Own a
  child process group and attempt SIGKILL on completion/error/timeout before
  reaping its leader. Guarantee direct-child termination/reaping; process-group
  signaling is best effort, as approved by the user on 2026-10-24. macOS returns
  EPERM for a zombie-only group as well as some permission failures, so treating
  every group error as fatal rejects successful commands. Direct-child signal
  and wait errors still fail. Do not promise reaping
  grandchildren, supervising detached daemons or supporting background writers.
  Compiler, C compiler and first fixtures wait for their own work to finish.
  The deadline initiates forced cleanup; it is not a hard bound on OS cleanup
  latency. Use overflow-safe deadline arithmetic and report unexpected kill/wait
  failures for the direct child and descriptors. Never claim stable captures for commands leaving background writers.

Native implementation has one bounded fork/execve path. Prebuild argv/storage
before fork; child setup uses async-signal-safe operations only. A private
close-on-exec errno pipe distinguishes exec failure from legitimate exit 127;
its parent read must be polled/nonblocking within the same deadline. This is
internal native error reporting, not a public protocol or process framework.
Do not substitute stat/access preflight: it cannot prove successful exec.

Normalize private descriptors above 0/1/2; close every acquired descriptor and
free temporary argv storage on every path. Observe exit before reaping (existing
`waitid(...WNOWAIT)` precedent in the legacy native runtime), attempt owned
process-group cleanup, then reap the direct child. No process-global chdir, signal-handler
framework, PID registry, output pipes or retained process handles.

Native precedents: existing `blorp/src/lib/runtime/native/runtime.c` process
startup (~39416) documents the spawn/127 ambiguity and exit observation (~39955)
uses WNOWAIT. Primary contracts: [POSIX posix_spawn](https://pubs.opengroup.org/onlinepubs/9799919799/functions/posix_spawn.html)
and [waitid declarations](https://man7.org/linux/man-pages/man2/waitid.2.html).
Reuse established ideas, not the entire legacy process implementation.

## Compiler boundary and representation

Use the existing closed builtin path; add one parsed label/operation and impure
runtime operation, with no syntax, general FFI, checked process-expression node,
new pass or registry. `RuntimeContract` remains the signature authority.

Existing `RuntimeResult.ResultResult` expresses `Result[Int, String]`; follow
`append_write_file` for the native success/out-value/owned-error adapter and
packing the designated Result constructors. Do not introduce a record-result ABI
or teach native code the library's record names/variant ordinals.

One actual gap: `RuntimeType.ListRuntimeType(Element)` cannot express a fixed
String element while remaining generic over phase-specific Element. Add one
closed `StringListRuntimeType` arm and map it through the existing check and
specialization projections to each phase's List[String]. Do not add redundant
String type identities to every operation or refactor RuntimeType recursively.

Emit the process-required POSIX feature-test prelude **before** MEMORY_RUNTIME
or any system header; C11 Linux waitid needs the appropriate POSIX declarations.
Do not depend on extra caller -D flags, late feature macros or handwritten libc
prototypes. Gate this through existing runtime requirements so unused programs
remain unchanged. The native helper reads the concrete String-list layout. Emit it **after** the
existing aggregate/list helper declarations, using existing typed layout facts
and inventory traversal. Do not recover layout from C type-name spellings.
The runtime operation, ordinary calls, ownership preparation and verifier retain
their existing responsibilities. Errors are owned Strings; inputs stay borrowed.

## A small Blorp TestSuite driver

The generated `--test-suite` entry calls a zero-argument suite and cannot receive
Make's configuration. Use an **ordinary explicit main(args)** for this e2e
orchestration program, constructing actual TestSuite callbacks and delegating
exit status to the existing `test.run_suite`. This is the narrow driver-entry
choice to approve; fixtures retain their own unchanged mains, and no alternate
assertion program in C/Python is introduced. Constant unit suites keep their
existing `--test-suite` route unchanged.

```blorp
-- Proposed driver shape; make_suite supplies ordinary TestSuite callbacks.
func main(arguments: List[String]) -> Int:
    match arguments:
        [_, compiler, c_compiler, work_directory]:
            run_suite(make_suite(compiler, c_compiler, work_directory))
        _:
            -- print actionable usage and return failure
            2
```

Make owns mktemp/trap cleanup, fixes cwd to the repo root, resolves executable
paths, and passes compiler/CC/work-directory as argv. Runtime code does not
create temp directories, enumerate files, read environment configuration or
mutate parent cwd/environment. Use a distinct capture/output basename for every
case and compile/link/run phase. Leave no opportunity to accept stale C/binaries.

Compile fixture -> require success/expected compiler stderr -> read emitted C ->
link C11/-O0 with ASan/UBSan -> require successful link -> run real main -> check
exact exit/stdout/stderr. Link a separate native executable from the same
unmodified C with -DBLORP_MEMORY_DIAGNOSTICS=1 and the same sanitizer flags,
then invoke it with BLORP_LEAK_CHECK=strict. Require exactly its expected
balanced report (zero is valid for zero-allocation
fixtures, and at least the text case must exercise a positive allocation). Keep
driver, compiler and target accounting in separate captures; do not strip arbitrary stderr
or let a strict check replace the normal stderr assertion. Compiler invocations
that succeed use strict diagnostics and require one positive balanced report.
The rejection case instead unsets BLORP_LEAK_CHECK and BLORP_MEMORY_STATS through
explicit /usr/bin/env argv and compares the entire diagnostic/help stderr; it
claims no rejection-path accounting coverage. Normal C-compiler/native commands
also unset those variables; strict invocations explicitly set the required mode.
The driver's own accounting remains separate from every child's captures.

Do not import `cost.brp`. A test-local strict-report reader can parse one decimal
counter with existing byte_at/slice/parse_int and compare the entire stderr to
`blorp: leak check: N allocs, N releases, 0 leaked, 0 bytes\n`. It must reject
missing, duplicate, malformed, extra and leaking reports. This needs no split,
trim, Bytes, new library API or allocation/instruction budget checker.

Enable exactly four named cases first:

1. Return zero, empty stdout/stderr.
2. A fixture returning 23, proving nonzero successful program exits are preserved.
3. A text-output fixture with exact output, including its newline.
4. A rejected compilation with exact exit 1/diagnostic/help and an existing
   output sentinel unchanged (existing write_file/read_file suffice).

Select existing simple fixtures; add one only if none exposes the required
behavior. Repair source spelling with supported String.add/interpolation and
Boolean calls; no language feature work. Explicitly defer remaining old cases,
binary stdin/output, custom cwd, file-absence assertions, resource budgets and
full legacy-process APIs. Deferred cases get no PASS credit.

## Bootstrap and rollout

Keep process.brp **outside prelude and compiler/library dependencies used to
build the compiler**. The loader follows imports; it does not scan every library
file. Do not put this unsupported declaration into existing imported system.brp.

The current pinned seed can compile the updated compiler implementation because
the new operation there is ordinary enum/data/C-string code. Updated A/B then
compile the harness importing process.brp. No mandatory release/pin roundtrip is
needed to enable these tests. Prove this with a cold existing-pin build and no
legacy executable; do not assume it. A capable pin becomes necessary before the
compiler/prelude import graph itself uses the new builtin.

One mergeable vertical slice includes runtime wiring, self-hosted phase/runtime
checks, four-case driver, Make/CI integration and README/GUIDE/GRAMMAR updates.
Default `make -C blorp_2 test` builds once, runs the existing component selection
and the four new e2e cases with that explicit compiler. `test-e2e` uses the built
compiler; missing compiler/config is an actionable failure, never a seed/legacy
fallback. Use the same route in independent CI and seed qualification, labeling
four-case native coverage separately from deferred full native coverage. No
change to existing C identity, fixture parity, asset digest or pin locks.

## Acceptance, measurements and handback

Start with red TestSuite/runtime cases and the current explicit DEFERRED target.
Required coverage before integration:

- Builtin exact signature/arity/impurity, String-list and designated Result
  publication, ordinary lowering and argv/error ownership, including failures.
- Successful/nonzero/127 children, missing executable and invalid executable,
  literal argv, stdin EOF, distinct captures, existing/duplicate/symlink/FIFO
  capture rejection, second-create failure and closed-stdio descriptor collision.
- Monotonic timeout during startup/wait, direct-child reaping and group cleanup
  attempts on normal exit/signal/timeout. Use explicit small child executables with real
  mains and readiness handshakes, not timing-only sleeps or fixture rewriting.
  Assertions stay in Blorp TestSuites. Actual native-helper unit probes under
  test/runtime may use the existing AGENTS runtime-C exception, not a new runner.
- Missing/malformed driver argv fails with actionable usage before child execution.
- Compile/link/run failure cannot continue to later phases or accept stale output.
  One callback forced False must fail the driver's exit; mutate one real fixture
  answer/output to show the ordinary main oracle catches it, then restore.
- Active component suite remains green; four e2e cases pass exact outcomes and
  strict/SAN checks with no legacy compiler installed. Rejections pin text/help/span.

Runnable handback sequence (new e2e target becomes available in this slice):

```sh
bash blorp/test/test_build/test_blorp2_bootstrap.sh
make -C blorp_2 test
make -C blorp_2 test-compiler test-e2e
```

Serialize compiled jobs. Also run source fixpoint/fixture parity at final freeze;
retain source/library/compiler/toolchain/flags hashes and every test result.
Measure matched parent/candidate actual self-built self-compilation allocations
and normal retired instructions, plus the unchanged return-zero control. The new
process fixture has candidate-only observations: the parent lacks this builtin,
so never invent a parent fallback or label that fixture a matched comparison.
Freeze identical owned inputs/output path for shared workloads and keep all raw
samples.
Investigate >3% whole-source growth; stop/rescope repeatable >10%. Forecast is
now roughly 425 readable native-C lines (the original 220--330 estimate was
too small), 60--100 compiler wiring lines plus small wrappers
and driver. Report gross/net compiler/native-C/library/driver/tests separately;
investigate >500 net non-test lines, rescope >750. No test-line caps or trivial
budget-approval loops; unexplained complexity or significant regressions block.

Require independent compiler/API and runtime-safety/test approvals on exact final
diff and evidence before commit. Return branch/base, phase boundary changes,
commands/counts, real-main and fault results, lifecycle/strict/SAN evidence,
matched metrics/LOC, bootstrap import-closure proof and explicit deferred list.
Stop for a new public mechanism, unsupported ABI, hidden fallback or required
language expansion; report the concrete problem instead of working around it.
