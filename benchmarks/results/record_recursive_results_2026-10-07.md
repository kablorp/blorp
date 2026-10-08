# Recursive managed record result baseline

Measured on 2026-10-07 at `dfa5e2ad89740675a57201a8a619d800a8037638` with only benchmark
preparation changes. No optimizer or compiler source changed. The repository
compiler is FRESH, linked at O2 by the pinned bootstrap; its build metadata
reports `fd576db791a0-dirty`. This is a runtime allocation baseline, not a
compiler-performance measurement or accepted-storage validation.

The private `mono_data` rewrite pair motivates the probe: managed record
results cross mutually recursive named calls and callers immediately read
fields. The probe uses two List fields, a shared child, an unused fresh child,
and a mixed fresh/forwarded root-identity control.

| Workload | N=256 allocations/releases | N=512 allocations/releases | Future target |
| --- | ---: | ---: | --- |
| Recursive shared children | 257 | 513 | 1 shared child; no containers |
| Recursive discarded child | 513 | 1,025 | N+1 children; no containers |
| Mixed result identity control | 130 | 258 | Keep 2+N/2 |

Normal and AddressSanitizer/UBSan runs pass all 24 value/ownership rows, with
zero live-object delta. The original 18 rows exactly match retained R1 evidence.
Both process leak reports show 5,920 allocations/releases, zero leaked objects
and zero leaked bytes.

Depth three executes four producers, but does not allocate four wrappers.
Core after reuse contains one base ProductExpr and one recursive RecordReuseExpr
in each producer. Generated C allocates at the base and uses the existing
record reuse helper after recursive calls, with unique field takes/shared field
retains. Thus existing reuse leaves N containers to eliminate, not 4N.

`--require-result-groups` exits 1 with
`recursive_shared_children (256 rounds): result-group allocation target 1, observed 257`.
It retains the complete report. This pins the optimization gap without failing
the default baseline correctness probe.

Reproduce serially after confirming FRESH:

```bash
benchmarks/record_scalar_prepare --output /tmp/record-results-normal.json
benchmarks/record_scalar_prepare --sanitize --output /tmp/record-results-sanitize.json
benchmarks/record_scalar_prepare --require-result-groups --output /tmp/record-results-target.json
```

The last command is expected to fail before owned result transport exists.
Probe SHA-256: `1a479b3a41896de570f0d6910497f9f67ff05f40807605e62c8c532761b41ac4`.
Runner SHA-256: `7f02de371d65e911d9f1d00f21c02d6bd4d685413296f3e8e92cfa02997b66e3`.
Compiler SHA-256: `03bb776395b8156b16ba0be45044c4a15254b9c3cac4705ca4a8f77b68fb25b0`.
Raw reports, generated C and Core excerpts remain in the coordinating session's
temporary packet. Code-reviewer and independent
test-runner reviews pass with no remaining findings. The probes do not cover
cancellation or effectful field ordering; those need their own regressions when
the result boundary is implemented. Committed typed storage plus refreshed R1
acceptance remain prerequisites.
