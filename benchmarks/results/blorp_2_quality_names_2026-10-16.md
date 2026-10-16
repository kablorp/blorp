# Binding and pattern authority

The naming slice enforces the approved no-shadowing rule, imported pattern
constructors and `_` as the only whole-arm catch-all. It replaces
`BindingCase`, rather than retaining a compatibility path. `check/scope.brp`
alone constructs opaque accepted local bindings; namespace projections carry
the actual declaration or import occurrence. Constructor visibility is checked
once by `find_variant`. Binding initializers are accepted before publishing a
new binding; existing assignment-classification errors keep their priority.

The source review by the coordinator and independent compiler reviewers found
no remaining blocking issues. A separate test-runner owns the acceptance
receipts. The implementation uses local builders and frozen results; it adds
no cache, index or alternate execution path. List lookup remains a linear
scope operation, with no performance improvement claimed for that lookup.

## Provenance

The tested integration base is `3972cc15ec3d502b7058fe59d7331a701e80c3d0`;
the naming-only staged patch before this evidence/document checkpoint is
`f262fdd2c8a3ca99faa9cab50baa387f54bd159a1881ba7df6ff6a034f9a22cc`.
The preserved baseline comes from `40ec02759b27054e53691f0d8270a0d6f8f6dd14`.
All measurements are serial on macOS arm64, Apple Clang 21, with the same
physical input/output paths and frozen source/library snapshots.

| Artifact | SHA256 |
| --- | --- |
| Frozen normal host, FRESH | `899e0a92cfe1bc91f992bd3ccdd0755448903eb91d91780ac4870bd13d8cfa17` |
| Diagnostic host sibling | `86ba69ffea8200080157edb25cbc49825654a14d2c09a6161dec447ab0e648be` |
| Baseline pilot | `81abd521bd1a40a02ad3974b13e3ca57c10b64effddfe3022c81ab5fde4595f4` |
| Baseline C | `60904c799a352f0076cda45429ed155ca7838ac2e42f8df728c275dc9602e600` |
| Candidate pilot | `6a90da1df36ef30d5d043188116cf06bdabf731b7c7cf1a72db748277e03eb56` |
| Candidate C | `1090d73cfd350dd31425d18f69074ffb58a4c6a364a77ace9ed58ba8ef96382b` |

The host is unchanged: CLI `-O0`, runtime `-O2`, split8, bootstrap
`dev-0e1598ed616e`. Pilots are linked at `-O0` with memory diagnostics.
Normal instruction samples unset both diagnostic variables **outside**
`/usr/bin/time -l`; strict allocation/leak runs are separate. Earlier samples
that timed an env launcher retain their wider-boundary label and are not the
acceptance numbers. No wrapper overhead is subtracted.

## Tests and semantic comparison

| Check | Result |
| --- | --- |
| Exact Makefile component recipe | 2,775 checks: 2,609 host callbacks and 166 nested C native cases; 201 suite summaries |
| `make -C blorp_2 test-e2e` | 439 checks; 351 C links and 522 native executions; 205.09 seconds |
| Final 439-file strict matrix | 878 baseline/candidate runs; balanced positive counts and zero leaked objects/bytes in every run |
| Final shared successful inputs | 349; emitted C identical in strict and all normal runs |
| Normal instruction corpus | 2,094 compiler-only samples, three alternating pairs per shared input |
| Original 431-file matrix | 862 runs; 331 shared successes emit identical C; exactly 18 intentional new policy rejections |
| `scripts/blorp2-fixpoint --frontier` | 33/35 files parse; remaining Char and function-type gaps unchanged |

Final inputs give 355 baseline successes and 349 candidate successes. The six
baseline-only successes are new policy fixtures: function/local collision,
function/parameter collision, parameter shadowing, a misspelled arm head, and
unimported constructors in whole/nested patterns. The original archive is a
separate comparison: its 18 newly rejected files are exactly the 18 existing
fixtures migrated to the approved rules. One already-rejected duplicate
capture now receives the explicit no-shadowing diagnostic at the same span,
with the previous-declaration note. This is not an unchanged-acceptance claim.

Focused suites cover scope construction, typed errors, exact diagnostics and
identity preservation. Semantic mutations and the unrelated-error mutation
fail the intended oracles. A growing `locals.concat(scope)` path discovered
during review became a local field-scope builder. A fail-open error helper was
corrected and independently mutation-tested.

The first component run exposed six stale callbacks in five files; their
reviewed corrections preserve the tested phase facts. The first full e2e run
had four failures: two sibling fixtures shadowed `Empty`, and two diagnostic
expectations omitted the existing absolute imported-source path. Only those
three test assets changed; values 17/3 and complete diagnostic equality remain
asserted. Both failed runs are retained, followed by green focused/full runs.

## Costs

Ceilings were set before implementation. The corpus uses the sum of each
input's minimum of three normal retired-instruction samples, rather than
instrumented execution counts.

| Metric | Baseline | Candidate | Change | Ceiling |
| --- | ---: | ---: | ---: | ---: |
| Shared-corpus allocations | 4,626,991 | 4,609,098 | -0.386709% | +0.5% |
| Shared-corpus normal instructions | 14,510,008,685 | 14,478,689,653 | -0.215844% | +0.5% |
| Canonical host-build allocations | 22,690,198 | 22,765,355 | +0.331231% | +1% |
| Canonical host-build normal instructions | 42,031,796,016 | 42,173,877,780 | +0.338034% | +1% |

The four individual workloads also pass their +1% ceilings. Normal instruction
deltas for return-zero, projection, access and chain-64 are respectively
+0.052141%, +0.021146%, -0.173613% and -0.110470%; allocation deltas are
-0.494631%, -0.110470%, -0.091800% and -0.205771%.

Host-build samples use the same canonical source/output path, three alternating
normal pairs, and one diagnostic run per variant. Allocations come from the
single `artifact_construction_complete` checkpoint. All normal/diagnostic C
outputs match within each variant. The initial helper incorrectly expected
pilot-style empty stdout from the host, which actually succeeded and printed
`Generated <path>`. Its setup failure is preserved; a separate fresh complete
series checks that exact host contract. These are **host-build proxies**, not
pilot self-compilation results.

Physical source deltas against the integration base, before this evidence and
roadmap checkpoint: production +616/-645 = **-29** (ceiling +21); test code
+1,019/-210 = **+809**; fixture programs +82/-30 = **+52**; docs/grammar
+75/-41 = **+34**. The collision inventory was refreshed to 110 source sites
across 14 files; the older handoff's 107-site census is historical.

## Evidence and limits

Raw commands, complete stdout/stderr, source/input manifests, C, mutations,
sample summaries and the 18-file outcome enumeration remain under ignored
`blorp_2/build/quality-patterns/`. The final independent receipt is
`acceptance-rerun-20261016/REPORT.md`; `evidence.sha256` fingerprints 18,820
retained files. Original failures remain under `acceptance-20261016/` and
component corrections under `preflight-rerun/` and `COMPONENT-TEST-FIXES.md`.
The standalone acceptance executes the exact component recipe, one candidate
build and the exact e2e target; the coordinator owns the literal full Makefile
gate on the destination tree before publication. Timing is descriptive, not a
latency claim. The frontier is not a bootstrap or fixpoint proof. Private-type,
UFCS, keyword, emitter and Boolean proposals are excluded from this candidate.

The actual destination subsequently passed the literal `make -C blorp_2 test`
at main base `972ad0b12`: 2,775 component checks and 439 e2e checks, 351 native
links/522 executions, in 250.88 seconds. It generated and linked the pilot once.
The destination's FRESH host SHA256 is
`390bdd0dd10d2f916c2d795462a278ed6bfa88b4c47928f9807ede748d331c7a`;
generated C is exactly candidate C `1090d73c` above. All 4,613 tracked input
hashes, staged blobs and host hashes stayed stable through the gate. Raw receipt:
`blorp_2/build/naming-landing/`. Existing Clang qualifier warnings are retained;
the gate has no failures. This destination run is separate from the matched
frozen-host cost measurements.
