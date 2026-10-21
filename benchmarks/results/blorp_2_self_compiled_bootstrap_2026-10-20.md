# Blorp 2 self-compilation and bootstrap cost

The integrated compiler compiles all 43 of its own source modules. Its emitted C
links without warnings, and the resulting compiler emits byte-identical C for
that same source and the same 12 target-library modules. This establishes a
working self-compilation; full regression and publication acceptance are tracked
separately.

## Matched compiler builds

Both candidates implement Source15 (source receipt SHA-256
`bf04fa5c70d17bbd297a65d78609533108ab7ca76aa892467304cbfdb9c4d715`)
and link with Apple Clang 21 at `-O0`, with memory diagnostics disabled.

- **A, legacy-built:** the freshly built repository host generated the compiler.
  Executable SHA-256: `ebd656f4a7f555ffc1569a9fbe7d4267df2a7ec8fb1c9a80af965fb5b56da12b`.
- **B, self-built:** Blorp 2 generated the compiler. Executable SHA-256:
  `bc85ddaeee58f65b2d47379b4ed51d076b32ce47772f458247b777665885662e`.

A's host was FRESH, built from the immutable `dev-07bc7629a132` bootstrap, using
CLI `-O0` and runtime `-O2`. Building A generated C in 3.837 seconds and linked
its normal executable in 3.103 seconds: about 6.94 seconds total. That build
measurement is one observation, separate from the repeated workload below.

## Identical self-compilation workload

The measurement ran serially in order A1, B1, A2, B2, A3, B3, with the same
physical source, library, working directory, output path and isolated environment.
`/usr/bin/time -l` collected retired instructions. No other compiled worker ran.
The successful preliminary self-compilation runs are retained separately; no
additional warmup is included in these six samples.

| Metric | Legacy-built A | Self-built B | B / A |
| --- | ---: | ---: | ---: |
| Median elapsed seconds | 2.371 | 51.437 | 21.70 |
| Minimum elapsed seconds | 2.353 | 51.119 | 21.73 |
| Minimum retired instructions | 34,152,792,849 | 740,166,910,797 | 21.67 |

All six runs exited 0 with empty stdout and stderr and unchanged guarded inputs.
Every output was exactly 17,124,028 bytes, SHA-256
`6a9736a0aadcad200a40f3d13e58989880905f69b3c69704ee4fa8e6c4769165`.
A1 took 3.048 seconds; all samples remain recorded rather than discarding it.

## Sanitized declaration traversal

The original self-built `-O0` ASan/UBSan compiler overflowed the native stack
while compiling its own source. Retained parameter-span identities mapped the
repeated emitted frame to `check_functions`, which recursively checked 1,500
function declarations. A separate source containing 2,048 independent helper
functions reproduced the stack overflow; its normal diagnostic compilation
succeeded. The trace was truncated and does not establish the exact failing
depth or an ownership defect.

The correction replaces that flat traversal with the existing source-loop
construct and removes the single-use recursive helper. Declaration order,
first-error stopping, lambda publication and Void normalization are preserved.
Production changes are 50 added / 66 deleted lines (net -16); tests are
69 added / one deleted (net +68). Both new phase tests and all eight previous
checks in their owner pass.

The revised compiler emits 17,129,617 bytes of C, SHA-256
`3d0def0d00f6c6ec003923d7acb2f8854fa506a6cf6b7c04611322a47b7b7f8b`.
Its linked normal compiler reproduces those exact bytes with empty streams.
The linked sanitizer compiler also reproduces them, with one complete strict
report: 27,373,418 allocations and releases, zero tracked leaked objects and
zero outstanding bytes. Both retain `-O0`; the sanitizer build retains
`-fsanitize=address,undefined -fno-sanitize-recover=all` and memory diagnostics.
The recorded soft stack limit is 8,372,224 bytes, unchanged by the fix. The
2,048-helper sanitizer regression passes with the same emitted C as before
and 532,835 balanced allocations. Original failures remain retained.

A single serial before/after diagnostic pair compiled the same frozen Source15
source and target library, using identical physical inputs, working directory,
output path, flags and environment. Allocations changed from 27,370,625 to
27,370,624; retired instructions changed from 747,847,383,112 to 747,854,788,164
(+0.0009902%). Both emitted the original Source15 C byte-for-byte, with balanced
strict reports and unchanged input guards. These direct observations satisfy
the predeclared 3% allocation and instruction ceilings; they establish no
latency improvement. They are separate from the earlier backend comparison.

## Correctness and resource acceptance

The initial host-backed component run passed 4,155 checks. Resource-policy
coverage raised this to 4,172, and the two declaration-traversal tests raised
the final count to 4,174, including the seven host String slice tests. These
suites use the legacy TestSuite host. In the earlier Source15 qualification,
the legacy-built and self-built normal compilers agreed exactly on all 556 maintained fixture
files: 464 accepted pairs and 92 rejected pairs. Exit status, stdout, stderr and
emitted-C presence and bytes matched. Another linked compiler generation also
emitted the same complete compiler C.

The self-built diagnostic compiler compiled its entire source with strict
accounting: 27,370,589 allocations and releases, zero tracked leaked objects or
outstanding bytes, and identical compiler C. This checks the tracked target
allocator; it is not an entire-process heap measurement.

The original full native gate reported 92 logical passes and 467 failures,
all from existing compiler resource limits. All 781 ordinary native executions
passed. Three final independent file-write state assertions originally followed
a fallible cost check; a reviewed ordering correction and focused rerun proved
those assertions while preserving their three resource failures.

With the explicitly approved initial-bootstrap policy, the maintained full e2e
runner passed all 559 functional callbacks and 781 ordinary native executions.
It retained 468 complete resource FAIL records matching the 471 measured cost
rows. One callback checks two budgets, explaining the additional record versus
the original 467 failed callbacks. All nine accounted pattern fixtures passed
in normal and strict modes, with balanced strict allocation reports. An invalid policy and a deliberately wrong
native expectation still failed; the default policy retained its original
budget failures. The pure strict limit checker and all limits are unchanged.

The user approved those cost-only failures as temporary debt for the initial
bootstrap switch and seed publication. Existing limits and original FAIL results
remain recorded. The exception applies to the qualified source/library and seed
artifacts; identity, behavior, counter validity, leak, sanitizer and platform
failures remain blocking. It does not establish a green resource or complete M8
gate. Normal test commands continue enforcing their limits.

The final revised-source qualification passed all 4,174 host-backed component
checks. Fresh A/B compilers agreed on all 556 maintained fixtures (464 accepted,
92 rejected), including exact streams and emitted C. Their results also match
the preserved Source15 reference for every fixture. The self-built diagnostic
compiler passed all 559 functional callbacks and 781 ordinary native executions
from a fresh working directory. All nine accounted pattern fixtures created
their evidence parents and passed both native modes with balanced strict
reports. A blocked parent produced the exact filesystem error and stopped
before evidence writing, native execution or cost-debt assessment. The final
run retains 468 typed resource FAIL records against unchanged limits; its
1,392 guarded inputs and fixture membership remained unchanged.

## Limits and retained evidence

This compares two backends building the same compiler, not an isolated feature
regression. Background operating-system activity was not controlled, so wall
time remains approximate; retired instructions provide the more stable signal.
No matched allocation comparison between those two backends, optimized-build
comparison or phase profile is claimed, and that backend cost gap has not
been attributed. No resource
ceiling is changed by this report.

Raw commands, all six counter reports, results, exact source/library snapshots
and both executables are retained under the main checkout's ignored directory
`build/bootstrap-evidence/blorp2-selfcompiled-gap-2026-10-20/`. Original commands
and working-directory paths remain in the raw provenance. The initial 2.277 /
51.433-second comparison used an older legacy-built producer and is superseded
by this matched-source comparison.

The revised-source producer, original stack failures, regression, matched-cost,
component, parity and fresh native receipts are additionally retained under
`build/bootstrap-evidence/selfcompile-integration-2026-10-20/`. Source worktree
paths in those raw commands remain unchanged. Seed publication, a real bootstrap
manifest and the default seed-only build switch remain pending; this source
checkpoint continues using the legacy production builder.
