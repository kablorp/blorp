# Measure the target compiler directly — 2026-10-19

The e2e contract measures one compiler execution. The previous required-mode
command timed `/usr/bin/env`, which then launched the compiler. The harness now
uses the existing typed `ProcessCommand.environment` to set strict leak checking
and unset memory statistics before `/usr/bin/time` starts the compiler directly.
Disabled mode runs that same compiler and argument list without time.
`ProcessResult` supplies the actual status and output; no new process mechanism,
private output constructor or numerical limit is introduced.

These file-only requests explicitly use null stdin and no child deadline,
replacing the legacy inherited stdin and implicit 30-second/environment deadline.
TestSuite's artifact timeout is separate. Existing capture-limit configuration
and process-group policy remain. README and eleven named tests pin these choices,
including exact spawn/status/signal/timeout errors and accounting bytes.

The genuine RED had three intended failures and two passing policy controls;
the earlier test setup failures remain separate. Independent GREEN passes
47 tests: eleven new command/result callbacks and 36 existing cost/native-policy
callbacks. Source is 67 ADD / 35 DEL, tests 124 ADD, README 11 ADD; compiler,
runtime and library production code are unchanged.

The [two-call boundary comparison](/Users/keithphilpott/CLionProjects/blorp/build/bootstrap-evidence/compiler-cost-command-2026-10-19/boundary-comparison-preparation/execution01/RECEIPT.json)
has receipt SHA `7666872f58616b0dd9c60e96e7db005493be4711ad26ca11ac75a35ed5e1ad5f`.
Using the frozen eb7 diagnostic producer and identical copied physical paths,
the old timed argv reports 71,908,254 instructions; the direct compiler reports
54,672,008. Both have 12,520 allocations/releases, zero leaks and byte-identical
C. Both use null stdin/no child deadline: this compares timed argv only,
not every legacy process default. All 105 pins agree. It establishes neither
a compiler speedup nor an absolute fixture-budget pass; no retry or minimum
selection was used.

The [final combined-tree gate](/Users/keithphilpott/CLionProjects/blorp/build/bootstrap-evidence/bootstrap-library-land-2026-10-19/test-runner/execute01/RECEIPT.json)
has SHA `992cbb964dd1ab4900f644d6c962c20a5cef424f1617a347930350bd59cfe6e4`.
It tests accepted `cc46927dd` plus this correction and the separately committed
List naming correction, using the
source-matched accepted F5 producer. It passes 47 focused checks, four B/C C
identity pairs, 3,528 component/runtime/grammar checks and all 1,095 native checks.
All 402 allocation/instruction rows pass their unchanged limits. Strict zero,
required counters, real fixture main, C11/O0 and ASan/UBSan remain enabled.
All 1,016 source/tool/library/test pins and Git state agree; no compiler rebuild
or retry occurred. This full gate covers the final combined tree, with no
standalone full-gate claim for the intermediate measurement-only commit.

The earlier eb7 naming gate remains failed at 66,572,995 / 65,000,000
instructions. Its unapproved waiver request is superseded without approval
because the newly declared corrected gate passes. The new gate is not a
retroactive verdict or a matched causal attribution. The remaining ordinary
self-compilation frontier is missing `list.contains`; no target-built compiler
or fixpoint is claimed.
