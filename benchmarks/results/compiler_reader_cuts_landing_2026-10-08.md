# Compiler reader cuts: current-main landing, 2026-10-08

Current resource comparison and guarded combined validation PASS on `92fe004146773e24372eae44523da10be38e36a7`. The retained host premerge invocation uses explicit `BLORP_TEST_TIMEOUT=60`, including host runtime-wide UBSan. Docker's separate Linux/amd64 full gate retains its recorded settings: per-fixture timeout 30, runtime 60, leak 60 and compiler 360 seconds. The SSH environment does not forward the host timeout setting to Docker. The original full premerge stopped at Docker setup because its Git-excluded volume lacked a commit stamp; that raw STOP remains unchanged (15,226 passed and one CLI setup failure in the Docker gate). A reviewed two-file Docker adapter/test repair supplies supported snapshot provenance in normal volume mode; clean-image mode is outside this repair and remains unverified. The continuation reruns complete required Docker plus gate regressions, exact owner security checks, drift/hygiene and FRESH checks while reusing the unchanged host passes. This is combined validation, not a new original full-premerge PASS. The resource comparison predates and does not measure the Docker adapter repair; compiler/runtime/standard-library/codegen and benchmark inputs and installed CLI remain identical. This merge preserves local main `0b30c30a92d61a8d0c8a9e06c7e717a330400ac9` while incorporating remote main `a1a960740200737dc17ed6c3134805484e3b36ae`. The earlier `0b30` landing attempts and timeout probes remain private historical context; their partial gates are not latest-main acceptance.

The current baseline's default-30-second UBSan run stopped at its artifact timeout. Separate baseline/candidate 60-second runs completed without reported sanitizer/functional errors and matched all 576 ordered source identities and ordered printed coverage events. The log has 577 headers and 5,512 scoped PASS labels, preserving a nested enum-header case rather than inventing one header per source. Source/index/compiler guards stayed unchanged. This establishes completion under the explicit configuration; it does not establish default-30 PASS, a slow-cause diagnosis or a performance claim. Sanitized generated-C retention was unavailable and is not claimed. Default-30 records remain private with original digest in the manifest; the matched coverage proof and 60-second results are public.

| Workload | Base allocations | Candidate allocations | Allocation delta | Base minimum instructions | Candidate minimum instructions | Whole C |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| self | 249438765 | 249454243 | 15478 | 232984569528 | 232673013936 | Identical |
| small | 1722723 | 1722783 | 60 | 1625344906 | 1625844336 | Identical |

Three normal samples per side/workload and paired diagnostic allocations pass unchanged exact +0.5% ceilings `candidate * 200 <= baseline * 201`. Raw samples, timestamps and spreads are retained. Background work is allowed; no quiet-window, latency or speed claim. Raw clean-to-dirty commit/dirty-line metadata is retained, with all other version/effective toolchain fields equal. Raw `compiler_stage=1` from explicit retained compiler arguments is qualified by actual stage2 construction and paired binary hashes.

| Gate | Actual exit | Passed | Failed |
| --- | ---: | ---: | ---: |
| Retained fresh-before | 0 | not recorded | not recorded |
| Retained changed-plan | 0 | not recorded | not recorded |
| Retained gate-scope | 0 | not recorded | not recorded |
| Retained changed | 0 | 3147 | 0 |
| Retained fresh-after-changed | 0 | not recorded | not recorded |
| Retained premerge | 1 | 19274 | 0 |
| Continuation fresh-before | 0 | not recorded | not recorded |
| Continuation gate-syntax | 0 | not recorded | not recorded |
| Continuation gate-regression | 0 | not recorded | not recorded |
| Continuation memory-setup-regression | 0 | not recorded | not recorded |
| Continuation docker | 0 | 15315 | 0 |
| Continuation security | 0 | not recorded | not recorded |
| Continuation diff | 0 | not recorded | not recorded |
| Continuation cached-diff | 0 | not recorded | not recorded |
| Continuation hygiene | 0 | not recorded | not recorded |
| Continuation fresh-after | 0 | not recorded | not recorded |

Counts overlap. Complete retained STOP and new Docker logs, plus the explicit gate-only exception and unchanged continuation source/index/build guards, are in [the current packet](compiler_reader_cuts_landing_2026-10-08/PUBLICATION_MANIFEST.json). Earlier design and feature validation remain in the [first reader cuts](compiler_identity_reader_cuts_2026-10-07.md), [dictionary admission](compiler_dictionary_getter_admission_2026-10-07.md), [ranked getter ABI](compiler_ranked_tensor_getter_abi_2026-10-07.md) and [dimension kind](compiler_dimension_kind_preservation_2026-10-07.md) reports. Independent delivery review is required before application.

This packet is an explicit path-only public projection. Its 29 original selected files are privately archived with digest and inventory. All original numeric values, timestamp fields, source/C/compiler SHA values and acceptance booleans are unchanged. Embedded historical seal/config hashes still identify ORIGINAL bytes; the publication manifest separately verifies published stored and decoded bytes. Longest-prefix role tokens preserve distinct worktrees, home fallback and temp spelling/canonical aliases without resolving paths or collapsing JSON keys. All 8 logs become lossless `.log.gz` after projection, preserving raw whitespace; gzip serialization mtime zero is not a measurement timestamp. Decode with `gzip -dc`; historical `.log` references retain original names. Decoded content is checked against main's exact path and high-confidence secret patterns. Whole C, binaries and the full frozen-input seal remain private with listed original identities; redundant guards are not copied. Measurement dates are the untouched raw timestamps; the heading dates this publication. No native rerun or controller archive expansion belongs to publication.
