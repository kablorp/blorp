# Accepted Trait-Method Identity — Step 2e

**Date:** 2026-09-11

**Baseline:** `1c00b5a7` (`Preserve exact unqualified UFCS identity`)

**Candidate:** working tree for Issue 87

## Result

Accepted trait-method visibility now targets `TraitMethodId`, and inference
uses that ID to select the canonical signature and declaring trait before the
existing string-backed typed-call compatibility boundary.

The focused 32-call probe adds 480 transient allocations and releases
(+0.0450%), with no retained-object or retained-byte growth. The changed-path
bridge profile remains within +0.17% retired instructions, +0.40% cycles, and
+0.26% peak footprint. Its maximum-RSS observation is 4.08% higher, but this is
not corroborated by retained memory or the build-level resource screen. The
checked-bodies screen remains within 0.10% on all native and memory counters,
with neutral retained objects and allocated bytes. Compiler size grows
0.0856%.

Wall time is recorded only as a one-shot observation. It is not used as a
latency claim.

## Commands

Focused allocation probe:

```bash
bin/blorp run \
  blorp/test/compiler/stage_06_typecheck/accepted_trait_method_identity_probe.brp
```

The temporary probe reset `MemStats`, invoked
`test_typecheck_source_uses_imported_trait_method_as_ufcs` 32 times, retained
only the result, and was removed after measurement.

Changed-path bridge profile:

```bash
/usr/bin/time -lp <compiler> test \
  --profile-mode exact \
  --profile-module blorp/src/compiler/stage_06_typecheck/type_system/accepted_trait_implementation_authority \
  --profile-module blorp/src/compiler/stage_06_typecheck/infer \
  blorp/test/compiler/stage_06_typecheck/test_typecheck_bridge.brp
```

Build-level resource screen:

```bash
/usr/bin/time -lp <compiler> test --profile-mode exact \
  benchmarks/compiler_typecheck_phase_profile.brp -- \
  bodies 1 32 4 16 16 memory
```

## Focused Allocation Probe

| Metric | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Allocations | 1,065,632 | 1,066,112 | +0.0450% |
| Releases | 1,065,600 | 1,066,080 | +0.0450% |
| Retained objects | 32 | 32 | neutral |
| Retained bytes | 2,048 | 2,048 | neutral |

The delta is 15 transient allocation/release pairs per exercised lookup. It is
consistent with retaining a structured method-ID value in the accepted
dictionary/query path. An optional ID on every callee and a new inference
wrapper union were both removed because neither had a downstream exact-ID
consumer and neither improved this allocation shape.

## Changed-Path Bridge Profile

Both runs passed all 117 bridge tests.

| Metric | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Retired instructions | 174,217,787,115 | 174,498,604,370 | +0.1612% |
| Cycles | 45,102,523,921 | 45,279,195,818 | +0.3917% |
| Maximum RSS | 765,280,256 | 796,475,392 | +4.0763% |
| Peak footprint | 588,661,528 | 590,152,472 | +0.2533% |
| Wall seconds | 14.36 | 14.49 | observation only |

The RSS result is treated as noise rather than hidden: the platform
peak-footprint counter stays within 0.26%, the focused probe retains no
additional memory, and the build-level screen below keeps both RSS and peak
within 0.10%. No performance claim depends on elapsed time or RSS from this one
pair.

## Checked-Bodies Build Guard

Both runs produced semantic checksum `2057305071532051463`, constructor
checksum `-2142865109331864226`, 34 primary work items, and zero secondary work
items.

| Metric | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Allocations | 17,232 | 17,244 | +0.0696% |
| Releases | 12,924 | 12,936 | +0.0929% |
| Retained objects | 4,308 | 4,308 | neutral |
| Allocated bytes | 350,408 | 350,408 | neutral |
| Retired instructions | 6,275,021,261 | 6,280,666,388 | +0.0900% |
| Cycles | 1,738,301,765 | 1,732,531,368 | -0.3320% |
| Maximum RSS | 25,001,984 | 24,985,600 | -0.0655% |
| Peak footprint | 17,695,056 | 17,711,440 | +0.0926% |
| Setup microseconds | 411,261 | 406,707 | observation only |
| Window microseconds | 16,379 | 16,357 | observation only |

## Compiler Size

| Metric | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Executable bytes | 19,425,808 | 19,442,432 | +0.0856% |

The new `Dict[String, TraitMethodId]` specialization is the likely source of
the small binary growth. The increase stays below 0.1% and removes a semantic
string target, so it is accepted for this packet.
