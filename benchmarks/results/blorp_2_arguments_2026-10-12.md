# Pilot arguments, pure calculators and numeric tail recursion

Validated 2026-10-12 in worktree `b630`, based on
`45f59148cf3671faa7ed65f09a41c56f45f87b80`. Changes remain uncommitted.
The [design](../../blorp_2/ARGUMENTS_PLAN.md) owns scope and acceptance criteria.
One local evidence entrypoint is `blorp_2/build/argv/README.md`.

## Behavior and authoritative facts

Input now arrives through ordinary `main(args: List[String])`; index zero is
the executable name. Existing nullary main programs still work. Calculator
decoding, numeric parsing and arithmetic are pure functions returning ordinary
Result values; reporting and process-status selection form the impure boundary.
The superseded read_line intrinsic and its active runtime code are removed.

The input prelude owns the unary List builtin identity. Checking publishes
structural List types and a typed entrypoint convention; specialization translates
its function identity. Lowering and ownership carry the convention, independent
verification checks it, and emission consumes it. Concrete storage is currently
List[String]; unsupported elements are rejected explicitly. No general list
literals, append, mutation, COW or new registry were introduced.

The argv wrapper owns one list root and its copied String children, lends that
root to target main, saves the result, releases the root, and returns the saved
status. Successful get retains one child and returns an independently owned
Option. Stage tests cover aliases, transfers, generic wrappers, Option[List]
destruction and malformed ownership IR separately from native execution.

The ordinary Int library now exposes equals through explicitly bound Bool
constructor roles. Emitted C compares signed int64_t values directly. Bool
remains an ordinary union. The new numeric accumulator checks every iteration
with equality and decrements/increments integer state.

## Validation

All commands use the fresh repository host, CLI -O0/runtime -O2, Apple Clang
21.0.0 on aarch64-apple-darwin. The pilot and native fixtures use -O0.
Host SHA256: `e6b05f8452c2c30d57999734619417ab89f49e6b5202168d584ecfc03201dea1`.
Every recorder packet reports unchanged source during its command. Unit/grammar
preceded the final e2e ceiling calibration; only e2e budgets changed afterward.
The final documentation edits followed all compiled gates.

| Boundary | Result | Local recorder packet |
| --- | --- | --- |
| Strict unit and grammar | 1,494/1,494, 98 suites | `build/argv/unit-grammar-final` |
| Strict sanitized harness | 16/16 | `blorp_2/build/argv/independent-harness-strict` |
| Strict sanitized e2e | 208/208 group checks; 308 native executions, 183 fixture binaries | `blorp_2/build/argv/independent-e2e-strict` |
| String C runtime | 35/35 components, wrapper 1/1 | `blorp_2/build/argv/independent-runtime-tooling-strict` |
| Tooling | 7/7 | same packet |
| Source/unit correspondence | 22 host modules, no missing suites | `blorp_2/build/argv/independent-source-suite-coverage` |

Exact commands, initial failures, counts and fingerprints are in
`blorp_2/build/argv/independent-test-report.md`. E2e builds the pilot once,
compiles and links each unmodified fixture once, then runs its real main for
each argument case with strict C11 warnings, ASan and UBSan. No fixture input or
generated C was rewritten, and no internal generated entrypoint was called.

Three deliberately broken production/test-source experiments prove their
oracles. Exact original source bytes were restored afterward:

- Omitting harness argument forwarding fails 3/16 harness cases; restored code
  passes 16/16 (`harness-red`, `harness-green`).
- Omitting get's successful child retain fails the escaped-string fixture with
  explicit ASan heap-use-after-free, exit 134. Restored code prints exactly
  `kept é🙂\n`, exit zero and empty stderr (`list-get-oracle`). Pilot C/binary and
  fixture bytes are also restored exactly. This observes the child reference
  imbalance during cleanup; the wrapper root remains alive until main returns.
- Replacing accepted tail-loop selection with ordinary recursive calls preserves
  exact 0, 1 and 17 controls, but the unchanged million-iteration fixture fails
  with explicit ASan stack-overflow (`tail-control`, `tail-mutation`).

The unchanged accumulator also ran one billion iterations with the normal
compiler and strict C11 -O0 native build: stdout `1000000000\n`, exit zero,
empty stderr, 10.598 seconds in this single manual run. It is supplemental to
the regular million-iteration ASan/UBSan case, not a timing benchmark. Generated
C contains a while loop with both next values computed before parameter
assignment and continue (`billion-compile`, `billion-link`, `billion-run`,
`accumulator.c`). Manual iteration counts have a nonnegative precondition.

The frozen baseline compiler rejects the unchanged Int equality fixture through
the new library declaration with the exact unknown-builtin diagnostic at
int.brp:12:13 (`int-equals-before`); the current e2e fixture prints `7\n`, covering
signed limits, negative values and a distinction above 32 bits.

## Matched compilation costs

`measure.zsh` builds the prior pilot source from the frozen HEAD archive with
the same host toolchain and pairs it with the candidate. Both compile the same
166 frozen prior fixtures and prior target-library files, using their respective
explicit preludes. Sixteen roots directly importing the replaced IO adapter are
excluded explicitly; no adaptation or rewritten workload is used. Three samples
alternate baseline/candidate order, with no overlapping compiled commands.

| Aggregate over 498 compilations per compiler | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Allocations | 2,585,139 | 2,627,901 | +1.6541% |
| Retired instructions | 21,924,280,383 | 22,014,034,801 | +0.4094% |

Both remain below the preset +10% ceilings. All 498 paired generated C files
are byte-identical; strict compiler ARC counters balance on every sample.
This is an owned-input compilation proxy, not self-compilation, nor a comparison
of the new calculators with the removed stdin workloads. Raw paired counters,
C, timings and binary/archive hashes are retained in `costs.tsv`, `samples/`,
`provenance.sha256` and the `matched-cost` recorder packet.

The current-library e2e ceiling changes are separate from this same-input
compiler comparison. Enabling Int equality adds an explicit Bool module and
checked declaration to Int-importing workloads. Eight addition fixtures now
allocate 22,079-22,448 objects (ceiling 22,000 → 25,000); the String tail-arm
fixture allocates 23,628 (22,000 → 26,000). The new source-NUL fixture combines
regressions OS arguments cannot carry: 68,969 allocations and about 190.6M
instructions, with calibrated ceilings 76,000 and 210M. Existing instruction
ceilings are unchanged. The initial red gate is retained in
`independent-e2e-strict-before`.

Handwritten Blorp production changes: +489/-226, net +263 lines. Tests and
fixtures, including approved C runtime tests: +1,652/-654, net +998 lines.
Documentation is counted separately. The production increment is below the
design's 1,200-line target. Compiler-expert implementation, independent
compiler-expert/code review and independent test-runner review found no
remaining source issues; final evidence was reviewed separately.

## Limits

Strict ARC counters prove compiler-process managed allocations balance. macOS
ASan/UBSan native success does not establish native LeakSanitizer coverage.
String C components independently observe their allocation/free invariants;
no new direct C List test was added. Source/unit correspondence is an inventory,
not line or branch coverage. Full existing-compiler/release gates and publication
are outside this pilot-only increment. Import cycles, base-module organization,
prelude reexports and traits remain discussion topics, not changes in this slice.
