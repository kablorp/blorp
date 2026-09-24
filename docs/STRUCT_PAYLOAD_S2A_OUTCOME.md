# Managed source-union payload S2a outcome (historical report)

This is the S2a experimental report from the isolated worker branch. Its
comparison uses the older `2bb45f3f` base and candidate, so it is historical
evidence and must not be presented as a measurement against current `main`.

## Decision summary

S2a is a correctness-validated enabling candidate, not a measured speedup. On
the same frozen self-compile input, total allocations decreased by 14,254
(0.0061%) and emitted C decreased by 73,920 bytes (0.0495%), while retired
instructions increased by 0.12% at the minimum sample and 0.23% at the
median. Per root review, preserve this as a dependency for a separately
measured S2b probe; do not merge it to `main` or claim the roadmap's full S2
performance target from S2a alone.

S2a admits compiler-known concrete managed payload types through the explicit
constructor ABI fact. Unknown user nominal types, opaque wrappers, generic or
wrong-arity forms, unresolved types, and runtime-erased `RecvAttempt` remain
erased. The runtime-erased channel ABI and moved-payload ownership paths are
covered independently.

## Measurement provenance and reproduction

Both samples used the exact frozen input revision
`d5fe8d9d8288165e6dbe55868c11e060d62b6db4`, `program=self`, three uninstrumented
timing samples, stage 2, and `-O2` C compilation.

Baseline source revision: clean `2bb45f3f5196a2cf3d30716f67919b5fde3ee2a0`.
Baseline stage-2 compiler SHA-256:
`e05c51f6f228131ba849349252cef0db2bc0e3b3cbad0e7defcc993a9cab50e9`. The
baseline stage-2 compiler was built by bootstrap `bin/blorp` SHA-256
`f17f07d2f2e1b9f92b4e481279a8db733b17adc5a1be822a5fdf5fee030c6b4e`.

Candidate source revision: branch `codex/struct-payload-s2a`, HEAD
`2bb45f3f5196a2cf3d30716f67919b5fde3ee2a0`, with the S2a worktree edits
present (`compiler_dirty=true`). Candidate stage-2 compiler SHA-256:
`1a524b366cbc2c49eda2658719e5dde9d890239ad668debeb0632235fa23704e`. It was
built by candidate bootstrap `bin/blorp` SHA-256
`6c4a0358febe31b179f170c76e15cd489056458b4b11c67d8ed4a06b4913c0b1`.
Both compiler fingerprints report Apple clang 21.0.0
(`clang-2100.3.34.2`) and `cli=-O2 runtime=-O2`. The stage-2 JSON records
`compiler_build_status=skipped` for both runs because the stage-2 executable is
built by the measurement script; the recorded stage-2 and bootstrap SHA-256
values above are the provenance authority. The later hygiene target left the
installed bootstrap compiler FRESH at `cli=-O0`, so that later status is not
evidence for the O2 stage-2 sample.

The candidate command, run from the S2a worktree, was:

```sh
BLORP_CLI_C_OPTIMIZATION=-O2 benchmarks/self_compile_measure measure \
  --input-dir /var/folders/m7/zszgqft538nfx_qr1kmc7dlc0000gn/T/blorp-perf-input/d5fe8d9d8288165e6dbe55868c11e060d62b6db4 \
  --program self --samples 3 --stage2 \
  --baseline /tmp/blorp-struct-integrated-pre-s2a-stage2-O2.json \
  --output /tmp/blorp-struct-s2a-stage2-O2-final.json \
  --keep-output /tmp/blorp-struct-s2a-stage2-O2-final.c
```

The baseline JSON and C are `/tmp/blorp-struct-integrated-pre-s2a-stage2-O2.json`
and `/tmp/blorp-struct-integrated-pre-s2a-stage2-O2.c`; the candidate artifacts
are `/tmp/blorp-struct-s2a-stage2-O2-final.json` and
`/tmp/blorp-struct-s2a-stage2-O2-final.c`. macOS canonicalized the input path
in JSON to `/private/var/folders/...`; `input_rev` remains the exact frozen
revision above. Candidate JSON records `compiler_stage=2`, `samples=3`,
`c_optimization=-O2`, `compiler_rev=2bb45f3f5196a2cf3d30716f67919b5fde3ee2a0`,
and `compiler_dirty=true`.

One earlier invocation put measurement flags before the `measure` subcommand.
Argparse let subcommand defaults override them; its JSON recorded stage 1, two
samples, and the wrong frozen input. That run is explicitly discarded and
excluded from all comparisons; its files are
`/tmp/blorp-struct-s2a-stage2-O2.json` and
`/tmp/blorp-struct-s2a-stage2-O2.c`.

## Results

Allocation phase windows are derived from the matching Core phase checkpoints
in the two JSON artifacts. The phase windows omit the same 547
setup/transition allocations in each run; the total row includes all
allocations.

| Phase | Baseline allocations | S2a allocations | Delta |
| --- | ---: | ---: | ---: |
| Source discovery | 8,449,533 | 8,449,533 | 0 |
| Typed frontend | 34,638,282 | 34,638,282 | 0 |
| Core lowering | 19,253,211 | 19,255,876 | +2,665 |
| Early Core | 52,247,348 | 52,247,296 | -52 |
| Runtime projection | 8,397,565 | 8,397,565 | 0 |
| Late Core | 89,769,444 | 89,767,743 | -1,701 |
| Backend emission | 19,845,426 | 19,830,260 | -15,166 |
| Artifact construction | 98 | 98 | 0 |
| **Total** | **232,601,454** | **232,587,200** | **-14,254 (-0.0061%)** |

| Metric | Baseline | S2a | Delta |
| --- | ---: | ---: | ---: |
| Retired instructions, minimum | 182,389,409,069 | 182,616,568,555 | +0.12% |
| Retired instructions, median | 182,400,099,065 | 182,815,252,611 | +0.23% |
| Generated C bytes | 149,440,928 | 149,367,008 | -73,920 (-0.0495%) |
| Generated C SHA-256 | `d819f2a8d7ba2655a0828f9be450160fb2a0a142f59f1f08ed60f70b8fca0709` | `7b55ac381f28b55b78ba3b994f9af1bd1b884bb0e7ff13274dd717696e9fd635` | intentionally different |
| `blorp_box_struct` mentions | 271 (242 lines) | 271 (242 lines) | 0 |

Wall time and RSS are reported only as diagnostics: baseline minimum/median
wall time was 17.48/19.38 seconds versus 15.08/15.78 seconds for S2a, and peak
RSS was 2,581,856,256 versus 2,561,343,488 bytes. Host contention makes these
measurements unsuitable as acceptance evidence.

## Validation

All commands ran serially on the macOS host. The stage-2 comparison above is
separate from the correctness gates.

| Gate | Result | Evidence |
| --- | --- | --- |
| `test_core_lower.brp` | 150/150 | `/tmp/blorp-s2a-core-lower-final.log` |
| `test_core_type_policy.brp` | 2/2 | `/tmp/blorp-s2a-core-type-policy-final.log` |
| `test_core_backend_projection.brp` | 46/46 | `/tmp/blorp-s2a-core-backend-projection-final.log` |
| `test_core_json.brp` | 117/117 | `/tmp/blorp-s2a-core-json-final.log` |
| `test_core_emit.brp` | 345/345 | `/tmp/blorp-s2a-core-emit-final.log` |
| Generated-C audit | 225/225 | `/tmp/blorp-s2a-codegen-audit-final.log` |
| Managed String transfer: normal, leak, sanitizer | 1/1 each; leak 3 allocs / 3 releases / 0 leaked | `/tmp/blorp-s2a-managed-string-{normal,leak,sanitize}.log` |
| Runtime-erased `RecvAttempt[Point]`: normal, leak, sanitizer | 1/1 each; leak 3 / 3 / 0 | `/tmp/blorp-s2a-recvattempt-{normal,leak,sanitize}.log` |
| Wide erased payload: normal, leak, sanitizer | all passed; leak 8 / 8 / 0 | `/tmp/blorp-s2a-wide-{normal,leak,sanitize}.log` |
| Closure mixed struct/String capture: normal, leak, sanitizer | 1/1 each; leak 3 / 3 / 0 | `/tmp/blorp-s2a-closure-capture-{normal,leak,sanitize}.log` |
| Changed-source compiler check (`origin/main`) | 10 sources, 31 suites, 7 checks; 3,718/3,718 | `/tmp/blorp-s2a-compiler-check-final.log` |
| Broad compiler Blorp suites | 5,085/5,085 | `/tmp/blorp-s2a-broad-compiler/compiler-blorp.log` |
| Broad runtime suites | 4,500/4,500 | `/tmp/blorp-s2a-broad-runtime/runtime.log` |
| Broad leak suites | 976/976 | `/tmp/blorp-s2a-broad-leak/leak.log` |
| Compiler Core ASan/UBSan | 2,119/2,119 | `/tmp/blorp-s2a-final-core-sanitize/compiler-core-sanitize.log` |
| Compiler Blorp ASan/UBSan | 4,355/4,355 | `/tmp/blorp-s2a-final-compiler-blorp-sanitize/compiler-blorp-sanitize.log` |
| `make hygiene-check` | Exit 0; split translation units 5/5 | `/tmp/blorp-s2a-make-hygiene-exitcheck.log` |
| `git diff --check` | Clean | rerun after all edits |

The changed-source compiler check included the compiler-tools special check.
This checkout's `scripts/test --help` does not expose a `runtime-tsan` gate.
The first changed-source batch initially exposed a pre-existing two-argument
`core_graph_modules` call in the callable-name-registry benchmark fixture; the
call was confirmed unchanged on the integrated parent, then given an explicit
empty catalog. Its owner suite passes 4/4 in
`/tmp/blorp-s2a-callable-name-registry-profile-fixture-fix.log`; the final
changed-source batch passes with the compatibility correction.
