# Selected Accepted Trait-Call Identity — Step 2e

**Date:** 2026-09-11

**Baseline:** `d4fb53fc` (`Preserve exact accepted trait method identity`)

**Candidate:** working tree for Issue 88

## Result

Graph-backed unqualified accepted trait calls now retain `TraitId + CallableId`
instead of `trait name String + CallableId`. CTFE consumes the callable ID;
typed JSON and Core validate both IDs before table-backed projection. Inference
retains three explicit ID-to-name semantic compatibility consumers for
elementwise, self-bound, and resource policy.

The focused probe adds three transient allocation/release pairs per call
(+0.0090%) and no retained objects or bytes. The build-level guard is
allocation-neutral and remains within 0.66% for retired instructions, cycles,
RSS, and peak footprint. Compiler size is effectively neutral at +0.0038%.

One changed-path pair observes +0.1720% retired instructions and +0.6591%
cycles, with a 3.4476% RSS improvement and peak footprint within 0.1249%. Wall
time and one-shot cycles are observations rather than latency claims.

## Rejected Representation

The first candidate retained the complete structured `TraitMethodId` in the
typed target. The same focused probe produced:

| Metric | Baseline | Full method ID | Change |
| --- | ---: | ---: | ---: |
| Allocations | 1,066,112 | 1,066,272 | +0.0150% |
| Releases | 1,066,080 | 1,066,176 | +0.0090% |
| Retained objects | 32 | 96 | +64 objects |
| Retained bytes | 2,048 | 4,096 | +2,048 bytes |

Once concrete implementation selection has occurred, `TraitId + CallableId`
is the smaller exact dispatch identity: the trait identifies the accepted
contract and the callable identifies the executable implementation method. The
full-method-ID candidate was removed completely.

## Commands

Focused allocation probe:

```bash
bin/blorp run \
  blorp/test/compiler/stage_06_typecheck/accepted_trait_call_identity_probe.brp
```

The temporary probe reset `MemStats`, invoked
`test_typecheck_source_uses_imported_trait_method_as_ufcs` 32 times, retained
only the result, and was removed after measurement.

Changed-path bridge profile:

```bash
/usr/bin/time -lp bin/blorp test \
  --profile-mode exact \
  --profile-module blorp/src/compiler/stage_06_typecheck/type_system/accepted_trait_implementation_authority \
  --profile-module blorp/src/compiler/stage_06_typecheck/infer \
  blorp/test/compiler/stage_06_typecheck/test_typecheck_bridge.brp
```

Build-level resource screen:

```bash
/usr/bin/time -lp benchmarks/compiler_typecheck_phase_profile \
  bodies 1 32 4 16 16 memory
```

## Focused Allocation Probe

| Metric | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Allocations | 1,066,112 | 1,066,208 | +0.0090% |
| Releases | 1,066,080 | 1,066,176 | +0.0090% |
| Retained objects | 32 | 32 | neutral |
| Retained bytes | 2,048 | 2,048 | neutral |

## Changed-Path Bridge Profile

Both runs passed all 117 bridge tests.

| Metric | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Retired instructions | 174,498,604,370 | 174,798,755,752 | +0.1720% |
| Cycles | 45,279,195,818 | 45,577,618,124 | +0.6591% |
| Maximum RSS | 796,475,392 | 769,015,808 | -3.4476% |
| Peak footprint | 590,152,472 | 590,889,776 | +0.1249% |
| Wall seconds | 14.49 | 14.88 | observation only |

## Checked-Bodies Build Guard

Both runs produced semantic checksum `2057305071532051463`, constructor
checksum `-2142865109331864226`, 34 primary work items, and zero secondary work
items.

| Metric | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Allocations | 17,244 | 17,244 | neutral |
| Releases | 12,936 | 12,936 | neutral |
| Retained objects | 4,308 | 4,308 | neutral |
| Allocated bytes | 350,408 | 350,408 | neutral |
| Retired instructions | 6,280,666,388 | 6,281,338,017 | +0.0107% |
| Cycles | 1,732,531,368 | 1,732,046,543 | -0.0280% |
| Maximum RSS | 24,985,600 | 25,149,440 | +0.6557% |
| Peak footprint | 17,711,440 | 17,760,568 | +0.2774% |
| Setup microseconds | 406,707 | 405,097 | observation only |
| Window microseconds | 16,357 | 16,360 | observation only |

## Compiler Size

| Metric | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Executable bytes | 19,442,432 | 19,443,168 | +0.0038% |
