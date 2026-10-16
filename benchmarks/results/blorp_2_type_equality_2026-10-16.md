# Direct accepted-type equality

The existing equality authority compares primitive constructors and bare nominal
identities directly, instead of building two namespace TypeHeads first. List,
applied-type and rigid-parameter comparisons are unchanged. Bare and applied
forms remain distinct even when the applied argument list is empty. No new
matcher, cache, carrier or normalization is introduced.

This is the separately validated preparation from
[TYPE_EQUALITY_PLAN.md](../../blorp_2/TYPE_EQUALITY_PLAN.md), not implementation
or acceptance of UFCS clash checking. Production changes are 23 added/14 removed
lines, **+9 net** (ceiling +20); tests add six lines. Root and an independent
compiler expert reviewed the integrated source with zero findings, and an
independent runner owns the evidence below.

## Frozen boundary

The production baseline is published private-type main
`6f8543de8063cc73ae3f14ee1f388c3660f6c7df`. The subsequent `74de8510a` UFCS
plan publication changes documentation only. The runner verified all 43
production/library files against immutable Git contents and the retained
private pilot manifest before reusing that binary.

| Artifact | SHA256 |
| --- | --- |
| Frozen normal host | `899e0a92cfe1bc91f992bd3ccdd0755448903eb91d91780ac4870bd13d8cfa17` |
| Frozen diagnostic host | `86ba69ffea8200080157edb25cbc49825654a14d2c09a6161dec447ab0e648be` |
| Baseline O0 pilot | `ba622531f88df9ce67f0272ff3eedbe999a736e264e9779a3dbbab3968d10ea9` |
| Baseline compiler C | `34911054fd4df47a04dd608b4adaf7e6f124492becd881bd6fe92138674e576e` |
| Candidate O0 pilot | `67c22292e9031c2ff5d5ac0e8553117aae8d8dd700201c2dcadc7904553e60cf` |
| Candidate compiler C | `531e6c240e020f7885a5c3bb61d062dd2ad6767fec5611ad5b9c3d214b68b362` |
| Integrated feature patch | `7f19577022c1a2c6e830173cce2ee04e18fc4f27dbec3dff5b453b281d7496c2` |

The host remains FRESH and unchanged: CLI-O0/runtime-O2/split8, immutable
bootstrap dev-0e1598ed616e, Apple Clang 21, macOS arm64. Exactly one candidate
pilot generation/link uses O0 and memory diagnostics; 83 host-generated C
warnings are retained, with no build errors. No existing compiler rebuild,
host override, source rewrite or alternate fixture entrypoint is used.

## Correctness and measured work

Integrated model/callables/inference suites pass **29/29** callbacks. The model
matrix compares 30 unique structural representatives in all 900 ordered pairs,
with separate vector and parameter-identity controls. The earlier focused
five-callback run and eleven killed semantic mutants are retained under the
older `648cf95f1` boundary, followed by a restored green run; they are not
mislabeled as integrated mutant executions. The current source changes only
the same six leaf cases and retains those test bytes.

All **445** fixture inputs have exactly matching outcomes and diagnostics:
349 accept and 96 reject on both variants. All shared successes emit identical
C. Every one of the 890 strict runs reports positive, balanced allocation and
release counts with zero leaked objects or bytes. All 349 accepted inputs
reduce allocations; none grows. The complete provider trees from
[UFCS_OVERLAP_PLAN.md](../../blorp_2/UFCS_OVERLAP_PLAN.md), including all provider
bytes, are independently hash-verified before stress measurements.

| Boundary | Baseline allocations | Candidate allocations | Normal min3 instruction change |
| --- | ---: | ---: | ---: |
| Return zero | 8,403 | 8,229 | -0.383095% |
| 32 providers, one function each | 23,610 | 23,180 | -0.386842% |
| 32 providers, 16 functions each | 145,229 | 140,959 | -1.303044% |
| 128 providers, eight functions each | 296,768 | 288,402 | -1.050001% |

Every preflight preserves C and zero leaks. These measurements validate the
preparation alone; they do not establish any full-UFCS absolute allocation cap.

| Aggregate boundary | Baseline | Candidate | Change | Ceiling |
| --- | ---: | ---: | ---: | ---: |
| Shared-349 strict allocations | 4,669,137 | 4,571,861 | -2.083383% | No growth |
| Sum of per-input min3 normal instructions | 14,547,603,567 | 14,480,391,087 | -0.462018% | +0.5% |
| Canonical host-build checkpoint allocations | 22,775,937 | 22,779,154 | +0.014125% | +1% |
| Canonical host-build min3 normal instructions | 42,032,983,242 | 42,029,036,112 | -0.009391% | +1% |

Normal compiler-only timing unsets both BLORP_LEAK_CHECK and BLORP_MEMORY_STATS
**outside** `/usr/bin/time -l`; strict allocations are measured separately.
The corpus has exactly 2,094 normal samples, three alternating pairs per legal
input, with positive counters and C matching each variant's strict output.
The table sums independent per-input minima, not a minimum complete-corpus run.

The host proxy freezes immutable baseline and candidate source/library snapshots
at the same physical source and result paths. Six normal runs measure
instructions; two diagnostic runs use the existing single
`artifact_construction_complete` checkpoint;
normal and diagnostic C match within each variant. These independently matched
host-build measurements are proxies, not self-compilation and not a comparison
with a differently located earlier host sample.

## Destination gate and evidence

The literal destination `make -C blorp_2 test` passes in 251.67 seconds:
2,799 component checks (2,633 host callbacks and 166 nested native runtime
checks), 445 e2e checks, 351 native C links and 522 fixture executions, with
zero failures. All 351 strict cost reports are positive, balanced and leak-free;
required instruction counters and every fixture cap pass. The destination
host remains FRESH (`390bdd0d`), and all 4,626 tracked input hashes, staged
blobs and HEAD stay unchanged during validation. Its separately linked O0
pilot is `77873318`; its C exactly matches the reviewed `531e6c24` candidate.

The actual destination `scripts/blorp2-fixpoint --frontier` passes in 20.32
seconds, measuring 33/35 modules parsed. Char at lex offset 7438 and reserved
`pure` at specialize offset 11650 remain the two stops. The host emits the
same compiler C to build separate O2 stage A (`e2872877`); stage B is not
reached. O0 and prior private/fixpoint artifacts are preserved. The actual
destination receipt is `blorp_2/build/equality-landing/REPORT.md` in the main
checkout. No self-compilation, fixpoint or matched latency claim follows.

Raw commands, source/binary/input manifests, every C output,
sample and strict diagnostic are retained under
`quality-type-equality-integrated/blorp/build/quality-type-equality-integrated/gates/`.
The independent receipt distinguishes the old focused mutant boundary from
the integrated 29-callback, complete-corpus and host-proxy evidence.
