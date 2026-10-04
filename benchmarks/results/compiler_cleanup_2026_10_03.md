# Compiler cleanup guard — 2026-10-03

Paired normal/diagnostic stage-2 compilers, Apple Clang 21.0.0, CLI/runtime
`-O2`, three uninstrumented samples. Input was frozen at
`684f5e58647f1d76891fca1d6aea8a27c194ceb0`; `small.brp` was unchanged.
The candidate contains the six reviewed cleanup patches, not an isolated
optimization. Both builds used bootstrap `dev-0322140767b0` for this comparison.
Separate Linux ARM validation used main's `dev-8228a8fa12e3` pin.

| Workload / metric | Parent | Candidate |
| --- | ---: | ---: |
| Self-compile allocations | 213,831,374 | 213,831,349 |
| Self-compile instructions, minimum | 204,103,685,858 | 203,979,717,481 |
| Small-program allocations | 1,499,308 | 1,499,283 |
| Small-program instructions, minimum | 1,461,783,959 | 1,462,306,125 |

Instruction differences (−0.06%, +0.04%) are noise-sized; no speedup is claimed.
The 25 fewer allocations comprise 24 before discovery and one during the typed
frontend. All subsequent phase allocation counts are identical.

Generated C is byte-identical: self-compile 79,846,266 bytes, SHA-256
`fa8f429f5646a1e0c27668e67cd1f227806928df21668277e7cebc3fd5452c07`;
small program 39,575 bytes, SHA-256
`3f4e7cf0fbabc5459ba7802a4fc5cb69a20d0699e4c19991f19dcf374cce4abe`.
Reproduce with the paired commands in
[the measurement protocol](../README.md#self-compile-measurement-protocol), using
that frozen input revision.

The source census went from 18 probable dead declarations to zero, and 19
legacy foreign identity shims were replaced by the standard-library primitive.
The combined compiler source diff removes 329 lines net.

Focused validation: 911/911 tests and all 22 newly enabled diagnostic fixtures
pass. Two live aliases removed outside the approved list were restored.
Whole-import removal was excluded because `ModuleId` also supplies implicit
trait visibility; all 25 whole-import findings remain. Static absence of a
name is not proof that its import is unnecessary.

Linux ARM validation passed all 17,428 ordinary checks and the 228-case codegen
audit via `scripts/docker-gate --platform linux/arm64 --premerge-gate --
--quick --no-quality`. An earlier `make quality` passed; the final run repeated
hygiene, tooling, and artifact checks successfully. `--quick` intentionally
omits sanitizers, preview smoke, and example smoke runs. Separate current-pin macOS
checks passed CLI-deep/LSP 213/213 and package 49/49.

The additional 59-root Linux ARM Core sanitizer run fails on both this batch
and clean main at `02c0786a609f6ef7b65f5fd6eba243af8fbd66bf`: four identical
UBSan function-pointer mismatch locations and an ASan stack overflow in
`blorp_retain`. Neither run completed its suite count. This is evidence of a
pre-existing failure family, not a sanitizer pass or a waiver.
