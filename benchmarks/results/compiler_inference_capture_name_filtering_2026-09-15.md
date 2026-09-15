# Inference Capture-Name Filtering

Issue 115 removes a second, redundant uniqueness check from five inference
capture/resource filters. The recursive free-reference and typed-resource
dependency collectors already preserve the first occurrence of every name.
An allocation-free private opaque type now carries that contract only between
those proven producers and their consumers.

## Decision

Accept. On the 512-name production `infer_expr` lambda path, median retired
instructions fell 22.90% and median measurement-window time fell 30.58%. The
two-name control changed by -0.01% in retired instructions, inside the 2%
guardrail. Allocations, releases, retained objects, and retained bytes were
identical for baseline and candidate on both workloads.

The candidate preserves exact ordered diagnostics. It does not move
deduplication upstream: the existing recursive collectors are unchanged. No
cache or invalidation state is introduced.

## Workloads and results

Seven managed-counter pairs followed one warmup pair and alternated execution
order. Five separate `/usr/bin/time -lp` pairs also alternated order. Fixture
construction, warmup, and exact diagnostic observation were outside the
measurement window.

| Workload | Arguments | Metric | Baseline median | Candidate median | Change |
| --- | --- | --- | ---: | ---: | ---: |
| 512 captured mutable names | `50 512 100` | retired instructions | 1,859,131,895 | 1,433,429,169 | -22.90% |
| 512 captured mutable names | `50 512 100` | elapsed | 242,038 us | 168,017 us | -30.58% |
| two-name control | `10000 2 100` | retired instructions | 1,241,068,145 | 1,240,938,096 | -0.01% |
| two-name control | `10000 2 100` | elapsed | 86,252 us | 82,612 us | -4.22% |

Every sample reported `workload_valid=True`, exact baseline/candidate output
checksums, and the expected typed body size. The heavy checksum was
`-3938950058073114209`; the control checksum was `3790026139315403270`.
Raw samples are retained in
`compiler_inference_capture_name_filtering_2026-09-15.tsv`.

## Mechanism evidence

One exact-profile iteration with 512 unique captured names called
`name_list_add_unique` 1,024 times in the baseline and 512 times in the
candidate. The unchanged producer accounts for the remaining 512 calls.
`List[String].contains` calls fell from 2,048 to 1,536, while
`free_var_refs_in_expr` remained at 514 calls. Thus the candidate removed the
512 consumer admissions without changing producer traversal.

Both profiles reported zero invalid IDs, unmatched or out-of-order ends,
metadata or stack-growth failures, cancellation/signal/nonlocal abandonment,
or recovered nonlocal exits. Each had five identical profile-window boundary
abandonments. Exact rows are retained in
`compiler_inference_capture_name_filtering_exact_2026-09-15.tsv`.

## Correctness

The producer contract was audited across every private production caller.
Parsed free references start from empty/singleton leaves and every multi-child
composition uses stable first-seen deduplication. Typed resource dependencies
have empty/singleton production leaves and use the same stable merge shape.

Regression coverage requires:

- exact first-seen mutable-capture order across repeated syntax paths;
- one dependency name when two typed paths reach the same scoped resource;
- one aliased stream name across repeated references;
- accepted imported globals and aliases to remain non-captures;
- existing parameter/local shadowing and empty-capture behavior; and
- one name to remain independently eligible for both resource capability
  result lists.

## Provenance

The baseline source revision was
`341d9443db6542a9b54722e120652d7f5ee4e387`. Baseline and candidate
`infer.brp` SHA-256 values were
`91e80f849f4754179215682d15fe5d9c66d8f728e4d7a261c9f632329b65fa8f`
and
`92a3bfd707b1189c8e9dafa8b2c23efbbe6a0d5814766aef1e3b9d9c74b1921e`.
The benchmark driver and fixture SHA-256 values were
`b2db97cc389d78b56ac3e83486367dfd98a15048dc1400895369118380c95a9a`
and
`8dd836bb4a00421d9b4e8812b08d0bc887eef758fa1209370510eb574f5f69c1`.

The optimized baseline and candidate binary SHA-256 values were
`d0d3dac7ed00fd18b88019e40182a50820d5d527812db28af32f21ee669e2a0e`
and
`ca4be040ee32e8d42e0f7999fd668e6b9999beb317eae3135a2c777d7d91ec62`.
The baseline and candidate compilers emitted byte-identical C for the current
compiler source, SHA-256
`e98d04a2d5c4bcbfbfa856e3b2e959f3add984fd3982631fd42dc74d8a96f265`.
Measurements ran on Darwin 25.6.0 arm64.

## Reproduction

Use underscore-only temporary checkout names because absolute module paths
are currently projected into generated C identifiers.

```bash
benchmarks/compiler_inference_capture_name_profile plain 50 512 100
benchmarks/compiler_inference_capture_name_profile plain 10000 2 100
benchmarks/compiler_inference_capture_name_profile profile 1 512 100 \
  2>/tmp/compiler-inference-capture-name-profile.txt
```

Compile the same benchmark sources at the baseline and candidate revisions,
then use `benchmarks/compiler_pass_compare` for seven alternating pairs. Run
five additional alternating pairs under `/usr/bin/time -lp` and compare the
`instructions retired` field. The benchmark checksum and stable workload
fields must match before comparing performance.
