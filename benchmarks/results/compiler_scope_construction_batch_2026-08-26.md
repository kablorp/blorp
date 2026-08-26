# Batched scope construction

Date: 2026-08-26

## Contract

`compiler_scope_construction_profile` constructs one union type with a
configurable number of constructors from an empty `Env`, repeated for the
requested iteration count. Constructor names repeat at a configurable ratio so
the profile verifies both same-name history and ordinary constructor lookup.
Fixture construction and output formatting are outside the measured interval.

The workload is valid only when `Ctor0` resolves to the latest expected tag and
its complete constructor history has the expected size. Allocation counters are
captured immediately after the measured interval, before formatting its result.

## Before and after

These are single warm runs from the same macOS machine and benchmark source.
The baseline was built from the branch base in an isolated worktree; the
candidate used the working tree with batched type-and-constructor insertion.
They are focused construction measurements, not a claim about total compiler
latency.

| Constructors | Distinct names | Iterations | Baseline elapsed | Candidate elapsed | Change | Baseline allocations | Candidate allocations | Change |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 1 | 1,000 | 4,283 us | 4,065 us | -5.1% | 30,000 | 30,000 | 0.0% |
| 256 | 64 | 20 | 8,348 us | 2,779 us | -66.7% | 72,000 | 46,640 | -35.2% |
| 1,024 | 256 | 20 | 79,462 us | 11,778 us | -85.2% | 287,040 | 184,920 | -35.6% |

Both candidate workloads preserved their checksum and `current_objects` count:
843 at 256 constructors and 3,339 at 1,024 constructors. Bytes allocated also
fell from 51,984 to 49,944 at 256 constructors and from 205,584 to 197,400 at
1,024 constructors.

## Reproduction

```bash
benchmarks/compiler_scope_construction_profile 20 16 4
benchmarks/compiler_scope_construction_profile 20 64 16
benchmarks/compiler_scope_construction_profile 20 256 64
benchmarks/compiler_scope_construction_profile 20 1024 256
```

The arguments are iterations, constructors per union, and distinct constructor
names. Set the last argument equal to the constructor count for unique names;
smaller values add controlled duplicate-name pressure.

## Production graph comparison

`compiler_typecheck_memory` now has a union-header mode that sends a real
`typecheck_graph` request to isolated candidate and baseline workers. The
fixture has one module containing one record, one probe function, and one
accepted union with alternating empty and `Int` constructors. Each comparison
uses two warmups and six measured runs, alternates worker order, and rejects
non-identical typed artifacts.

| Constructors | Baseline median | Candidate median | Paired time change | Peak RSS change |
| ---: | ---: | ---: | ---: | ---: |
| 64 | 26.680 ms | 23.903 ms | -8.2% | -0.3% |
| 256 | 58.458 ms | 54.578 ms | -6.0% | -0.2% |
| 1,024 | 352.509 ms | 307.836 ms | -12.9% | -0.3% |

The candidate and baseline produced byte-identical responses for every run.
The smaller end-to-end percentage is expected because parsing, header graph
construction, artifact serialization, and the rest of typechecking remain in
the interval. These measurements establish the frontend effect for this
specific union-header path; they are not a self-compilation number. The
repository now also provides `check --capture-typecheck-request` for a matching
self-hosted replay; its first captured result is recorded separately in
`compiler_typecheck_capture_2026-08-26.md`.
