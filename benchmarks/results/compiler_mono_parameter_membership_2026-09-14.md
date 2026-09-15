# Monomorphization Type-Parameter Membership Probe

## Decision

Do not add a membership index at the public single-type query boundary based on
this experiment. The retained probe demonstrates that an already-built index
can reduce modeled string comparisons on a wide no-hit workload, but it does
not isolate the cost of building that index per production query. No production
compiler change was retained.

A future experiment should begin only after production width/call-site data
shows that an existing caller can amortize one index across several queries.
The concrete boundaries to inspect are `is_concrete_substitution` and
`substitution_closes_parameters` in
`blorp/src/compiler/stage_09_core/mono.brp`. This is a new admission question,
not unfinished work from Issue 107.

## Provenance and command

- Base repository revision: `9ecb72e934c42f730fe15b5f3f05ee62a76db5f6`
- Benchmark implementation commit: `a343d888`
- Benchmark main SHA-256:
  `57f374e31b880351e695ae405159146de1226f6e3517002076a2d34e4ad802ae`
- Fixture SHA-256:
  `078fa9ab1089bf093049bc5ef27b62146892f9f3a0924f00f7ba64d80f6ad11c`
- Focused test SHA-256:
  `8e3139d9cf8c2e176b971cfbf5b35f7c47120d08e19a85bcd5a8e86b5ad8551c`
- Raw output: `/tmp/blorp-issue107-retained.out`
- Raw output SHA-256:
  `5f674f22c0a6cd84af0682646b2e815022134ed812bf122d233d26b1b76e76be`

```bash
bin/blorp run --release --no-format \
  blorp/benchmark/compiler/compiler_mono_parameter_profile.brp -- \
  32 128 8 -1 > /tmp/blorp-issue107-retained.out
```

The probe builds one `Set[String]` outside all modeled indexed queries, then
runs the linear model, indexed model, and current production implementation in
one measured window. Its elapsed and aggregate memory counters therefore
describe the whole harness and must not be attributed to either strategy.

## Retained result

The workload covers named types, functions, stack and boxed results, tensors
and dimensions, tuples, `SelfType`, and terminal variants. Checksums and true
counts match across the linear model, indexed model, and production query.

| Metric | Linear model | Prebuilt-index model |
| --- | ---: | ---: |
| Top-level queries | 1,152 | 1,152 |
| Type nodes visited | 10,624 | 10,624 |
| Parameter leaves | 1,408 | 1,408 |
| Name comparisons / membership probes | 45,056 | 1,408 |
| One-time index build names | 0 | 32 |

The combined harness performed 7,888 allocations and 7,888 releases with zero
retained objects. That number establishes leak balance only; it is not evidence
that either representation reduces allocations. Retired instructions were not
available on the measurement host.

The discarded production-index and self-compile attempts did not preserve
enough provenance or separated measurements to support a performance claim.
They are intentionally excluded from this retained result.
