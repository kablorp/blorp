# Implementation-Method Parameter Admission

Issue 118 now admits every discovered method type-parameter batch directly in
`effective_method_type_parameters`. The ordered result and membership
dictionary stay in one owning frame; the former aggregate candidate list is no
longer constructed.

## Decision

Accept. The wide production implementation-header workload reduced retired
instructions by 31.65% and median elapsed time by 42.82%. The one-parameter
control improved retired instructions by 1.71%, remaining within the 3%
guardrail. Ordered parameter names, header counts, constraint counts, and
checksums were identical.

The repeated admission predicate intentionally remains inline. A measured
attempt to extract it into a per-candidate helper retained managed graph owners
at the call boundary and made the phase several times slower. No state-threaded
helper or cache was retained.

## Boundary And Provenance

The fixture constructs the indexed, bound, declaration, alias, parameter,
type-header, trait-topology, and callable-header graphs before the measured
window. The window repeatedly calls production
`implementation_header_graph_build`. Warmup and ordered-header observation are
outside that window.

- Base revision: `b35710eb1fe72aeb97b4616f4abc52b2fd4cf1df`.
- Platform: Darwin 25.6.0 arm64, Apple M4.
- Baseline optimized binary SHA-256:
  `981265ec1c174991822d783b166b685c3955640d8ecadf7d4cb2374967e08c1e`.
- Candidate optimized binary SHA-256:
  `3db4ef9e93eb6b7c844f40b791f290f82eccfabc959471449031a95f75ab6fca`.
- Baseline exact-profile binary SHA-256:
  `c4c949fe851cf4bdf39ff2c37cc4644fb5bbb49a43d6e4cc7c8e753872c5bee3`.
- Candidate exact-profile binary SHA-256:
  `a4c3aecb5fddb7f8cf9451e9bc5618c103481096f244713b8568953b0a821b0d`.
- Baseline `implementation_headers.brp` SHA-256:
  `21cb7013342040d949f7f52b095cba990ec9df2b9a4c55358453930f473399b4`.
- Candidate `implementation_headers.brp` SHA-256:
  `03102e4d5eddd35e16b37d22d3c7697ffd6a2f45e12b013d4aa38afd7b18212b`.
- Benchmark driver SHA-256:
  `9125382915d689ac562b4f646525d34425288b9461de9f3780e6255176cd62e1`.
- Benchmark fixture SHA-256:
  `2b92227932ac2a43d088b4b0feb9a246d68c4f06e4c6c03ee9537917713c92fc`.

The baseline and candidate used byte-identical benchmark sources. All paired
runs alternated execution order and required identical ordered-header and
warmup checksums.

## Results

The headline workload used 50 iterations of one implementation containing a
1,024-parameter extra method, one implicit occurrence per parameter, one return
occurrence, no constraints, and 99% duplicate candidates.

| Workload | Metric | Baseline median | Candidate median | Change |
| --- | --- | ---: | ---: | ---: |
| Wide method | retired instructions | 3,301,535,788 | 2,256,616,199 | -31.65% |
| Wide method | elapsed | 167,680 us | 95,879 us | -42.82% |
| Wide method | allocations | 1,546,300 | 1,494,950 | -3.32% |
| Constraint-heavy | elapsed | 96,093 us | 53,402 us | -44.43% |
| One-parameter control | retired instructions | 2,440,666,693 | 2,398,871,710 | -1.71% |
| One-parameter control | elapsed | 118,302 us | 116,699 us | -1.36% |

The constraint-heavy workload used 30 iterations, 512 parameters, one return
occurrence, 256 constraints, and 99% duplicates. It retained all 256 resolved
constraints and the same ordered checksum.

The control used 10,000 iterations of one parameter, no return annotation, no
constraints, and no duplicates. Allocations fell from 1,580,000 to 1,550,000;
retained objects and allocator bytes were unchanged.

## Exact Mechanism Evidence

One exact-profile iteration of the wide workload reported:

| Counter | Baseline | Candidate |
| --- | ---: | ---: |
| `effective_method_type_parameters` calls | 2 | 2 |
| `discover_implicit_type_parameters_in_type` calls | 1,030 | 1,030 |
| `List[ParsedTypeParamDecl].concat` calls | 2,055 | 1,028 |
| dictionary copies | 0 | 0 |
| dictionary entries copied | 0 | 0 |
| list copies | 28 | 28 |
| list entries copied | 1,057 | 1,057 |

The 1,027 removed concat calls equal the wide profile method's 1,025 aggregate
discovery batches plus the required method's two batches. Recursive discovery
concats remain, so the candidate count of 1,028 is expected. Discovery calls
are unchanged, proving the work was not moved upstream. Both profile runs had
clean stack/call diagnostics and the same four window-exit abandonments.

## Reproduction

```bash
benchmarks/compiler_implementation_method_parameter_profile plain 50 1024 1 1 0 99
benchmarks/compiler_implementation_method_parameter_profile plain 10000 1 1 0 0 0
benchmarks/compiler_implementation_method_parameter_profile plain 30 512 1 1 256 99
```

Use `benchmarks/compiler_pass_compare` with
`IMPLEMENTATION_METHOD_PARAMETER_PROFILE`, `elapsed_microseconds`,
`ordered_header_checksum`, and `warmup_checksum`. External instruction samples
used `/usr/bin/time -lp` in five alternating pairs. Raw paired observations are
retained beside this report.
