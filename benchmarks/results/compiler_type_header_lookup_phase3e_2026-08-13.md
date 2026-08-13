# Phase 3E Type-Header Lookup

Date: 2026-08-13

## Workload

The retained `compiler_typecheck_profile` fixture ran one typecheck iteration
over eight modules, 64 chained record types per module, and 128 typed function
bodies per module:

```bash
BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 \
  benchmarks/compiler_typecheck_profile 1 8 64 128 retained
```

Every run reported nine artifacts, 1,537 source declarations, 1,537 typed
declarations, zero errors, `workload_valid=True`, and checksum `3083`.

The pre-table artifact was built from `b0319bd9` with the preceding keyed
known-type-index diff applied. The candidate artifact differed only in the
type-header table and its exact-identity collision regression. Cold artifact
builds were excluded. Seven cached profile runs were collected for each.

## Result

| Measurement | Pre-table median | Indexed-table median | Change |
|---|---:|---:|---:|
| Whole typecheck | 1,423,419 us | 1,349,466 us | 5.2% faster |
| `compiler_type_header_graph_build` | 68.924 ms | 32.744 ms | 52.5% faster |
| `complete_resource_containment` | 46.372 ms | 2.980 ms | 93.6% faster |

Before the change, the profile reported 504 calls to the linear
`header_index`, one for each declared-type edge reached during containment.
The indexed table instead narrows by source name and then checks exact
`CompilerTypeId` equality. The candidate reported 1,008 table lookups across
containment and ordinary graph consumers; those lookups took 1.4 ms in the
first candidate profile.

The whole-workload improvement and unchanged checksum justify retaining the
slice. The optimization also removes duplicate index construction and makes
the header inventory/index coherence a private structural invariant.

## Validation

- `compiler-blorp`: 3,401/3,401 passed after rebuilding the compiler;
- `std-check`: passed;
- focused type-header sanitizer: 25/25 passed; and
- typecheck declaration and benchmark suites: 99/99 and 4/4 passed.

The generated-C audit reported 14 stale expectation failures in unrelated
global-constant, stream, tensor, parallel, and WebSocket fixtures. The clean
current `main` compiler reproduced sampled failures from each major category,
including global-constant, parallel, stream, and tensor expectations. This
slice does not change Core or emission; the audit state is recorded as an
independent existing gate issue rather than attributed to header indexing.
