# Infer Session Reconstruction Profile

Date: 2026-08-26

## Candidate

`fresh_body_infer_session` in `compiler/src/stage_06_typecheck/decl.brp`
constructs the fresh body-local `TypecheckState` directly from
`BodyInferSessionSeed`. The baseline constructed an `InferSession` with the same
fields and immediately converted it back to `TypecheckState`.

The change is private to body checking. It does not change `Env`,
`TypecheckState`, `InferModuleFacts`, shared representations, indexes, caches, or
public constructors.

## Focused Fixture

`benchmarks/compiler_infer_session_reconstruction_profile` compares the baseline
session round trip with direct state construction using allocator reset/stats.
The seed intentionally contains preserved facts and stale body-local state. The
equivalence regression verifies that every current visible `TypecheckState`
field is preserved or cleared as required, with opaque values checked through
existing accessors.

Smoke command:

```bash
/Users/keithphilpott/CLionProjects/blorp/blorp run --timeout 30 --no-format \
  blorp/benchmark/compiler/compiler_infer_session_reconstruction_profile.brp -- 100
```

Smoke result:

| Path | Allocations | Releases | Retained | Checksum |
| --- | ---: | ---: | ---: | ---: |
| Baseline session round trip | 700 | 700 | 0 | 200 |
| Direct state construction | 600 | 600 | 0 | 200 |

This fixture is only candidate evidence. Production replay decides acceptance.

## Production Replay

Capture:

```bash
/Users/keithphilpott/CLionProjects/blorp/blorp check --no-format \
  --capture-typecheck-request /tmp/blorp_rr_NDqPjM/compiler_cli_typecheck_request.json \
  compiler/src/stage_12_cli/main.brp
```

Capture SHA-256:
`e486fb6d93a1ee54b6c29a148f3d8b1511c1970b785663966bf89566df0cd712`.

Baseline and candidate workers were built serially from the same source state,
differing only by the `fresh_body_infer_session` production implementation.
Benchmark/test additions were present in both temp trees and were not imported
by worker behavior.

| Item | SHA-256 |
| --- | --- |
| Central compiler | `978632dae992b4212a0beb572f585da0d0276a1f0a2e33491c4c702e511b9b6f` |
| Baseline worker | `fc135eb90d12c20f574a0262f810192727b69e8e80fed815bc17665abf90a4b2` |
| Candidate worker | `32ebe00f863496cce61d504d438ee502645a25e9a2f2ec15c2c227682dff09d2` |

Command shape for each run:

```bash
benchmarks/compiler_typecheck_replay /tmp/blorp_rr_NDqPjM/compiler_cli_typecheck_request.json \
  --bridge WORKER \
  --target-only \
  --timeout 180 \
  --memory-limit 4G \
  --allocator-stats \
  --no-inventory \
  --json
```

One warmup per worker was excluded. Measured order was baseline/candidate,
candidate/baseline, baseline/candidate.

All measured rows returned `verified=true` with response bytes `2030425` and
response SHA-256
`7c408163856c63ec8f7e820c959d483fc63e14bb64c8b25e9df6b1cedd50d664`.

| Pair | Variant | Elapsed s | Typecheck checkpoints us | Allocations | Releases | Current objects | Allocator bytes | Peak RSS bytes |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | Baseline | 47.520561583 | 25,926,697 | 306,191,443 | 297,311,223 | 8,880,220 | 685,212,912 | 1,034,928,128 |
| 1 | Candidate | 48.862787084 | 25,891,717 | 306,180,329 | 297,300,109 | 8,880,220 | 685,212,912 | 1,034,911,744 |
| 2 | Candidate | 47.026344875 | 25,199,415 | 306,180,329 | 297,300,109 | 8,880,220 | 685,212,912 | 1,034,829,824 |
| 2 | Baseline | 46.058951084 | 25,068,207 | 306,191,443 | 297,311,223 | 8,880,220 | 685,212,912 | 1,034,944,512 |
| 3 | Baseline | 47.494847041 | 25,946,086 | 306,191,443 | 297,311,223 | 8,880,220 | 685,212,912 | 1,034,911,744 |
| 3 | Candidate | 45.994840375 | 24,895,777 | 306,180,329 | 297,300,109 | 8,880,220 | 685,212,912 | 1,034,846,208 |

## Medians

| Metric | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Elapsed seconds | 47.494847041 | 47.026344875 | -0.99% |
| Named typecheck checkpoint sum us | 25,926,697 | 25,199,415 | -2.81% |
| Allocations | 306,191,443 | 306,180,329 | -11,114 |
| Releases | 297,311,223 | 297,300,109 | -11,114 |
| Current objects | 8,880,220 | 8,880,220 | 0 |
| Allocator bytes | 685,212,912 | 685,212,912 | 0 |
| Peak RSS bytes | 1,034,928,128 | 1,034,846,208 | -0.008% |

## Decision

Accept. Production replay returned exact output identity in every row:
`2030425` response bytes and SHA-256
`7c408163856c63ec8f7e820c959d483fc63e14bb64c8b25e9df6b1cedd50d664`.
Allocation and release counts decreased deterministically by `11,114` in every
measured pair, matching one fewer intermediate session record per body-state
creation at production scale.

Allocator bytes and current objects were unchanged, and median peak RSS changed
by only `-0.008%`. Elapsed median was `-0.99%` and named typecheck checkpoint
median was `-2.81%`, but timing is inconclusive/noisy: pair elapsed deltas were
`+2.82%`, `+2.10%`, and `-3.16%`. This does not claim a compiler speedup. The
accepted claim is simpler direct construction with the allocation/release
reduction above and no production semantic or memory regression.

## Review And Checks

No production diagnostics, counters, public APIs, shared mutation, speculative
caches, broad indexes, or shared representation changes were added. The focused
fixture uses allocator reset/stats around a small body-state reconstruction
workload and verifies exact baseline/direct state equivalence, including fresh
context, cleared errors/diagnostics, cleared type-shape memo fields, preserved
module facts, and an observable module-scope callable ID.

Focused local checks after acceptance:

```bash
/Users/keithphilpott/CLionProjects/blorp/blorp format \
  compiler/src/stage_06_typecheck/decl.brp \
  blorp/benchmark/compiler/compiler_infer_session_reconstruction_profile.brp \
  compiler/tests/test_compiler_infer_session_reconstruction_profile_benchmark.brp
jq empty compiler/tests/compiler_test_ownership.json
git diff --check
test -x benchmarks/compiler_infer_session_reconstruction_profile
/Users/keithphilpott/CLionProjects/blorp/blorp check --no-format \
  compiler/src/stage_06_typecheck/decl.brp
/Users/keithphilpott/CLionProjects/blorp/blorp check --no-format \
  blorp/benchmark/compiler/compiler_infer_session_reconstruction_profile.brp
/Users/keithphilpott/CLionProjects/blorp/blorp check --no-format \
  compiler/tests/test_compiler_infer_session_reconstruction_profile_benchmark.brp
/Users/keithphilpott/CLionProjects/blorp/blorp test --timeout 30 \
  compiler/tests/test_compiler_infer_session_reconstruction_profile_benchmark.brp
/Users/keithphilpott/CLionProjects/blorp/blorp run --timeout 30 --no-format \
  blorp/benchmark/compiler/compiler_infer_session_reconstruction_profile.brp -- 100
```

Broad gates, `make`, sanitizers, and additional production timing were not run
after acceptance because the build lane was reserved for another worker.
