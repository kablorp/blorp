# Emitter failures preserve their identities and occurrences

Emitter invariant failures now distinguish their actual cause instead of
always reporting an invalid union identity. Twelve precise failure variants
carry existing instance/value/owner IDs or explicitly labelled catalog indices.
The emitter passes available definition, acquire and drop spans; type/layout
products without an occurrence retain the honest compiler-origin span.

The narrow renderer lives in `src/emit/diagnostics.brp`. VerifiedProgram's
construction boundary, language acceptance, ownership insertion, layouts,
runtime and ordinary fixture entrypoints are unchanged. Seven eager error
arguments become direct Some/None matches without a second lookup or callback.
The separate `stored_by_value` missing-layout ambiguity remains out of scope.

Production is **174 added/89 removed, +85 net**, below the pre-set +160 net
ceiling; tests add 209 lines. Root and an independent compiler expert reviewed
the integration, including its five adaptations to previously accepted local
names. The original author did not count as an independent reviewer.

## Frozen boundary and tests

The baseline is published main `7c5a1d8166e0acf41b25c114590ce5c57b3d3a3b`.
Immutable Git contents verify all 43 baseline source/library files against the
retained equality pilot before reuse. Candidate manifests independently cover
44 files, including the new diagnostics module; no input is silently omitted.

| Artifact | SHA256 |
| --- | --- |
| Frozen normal host | `899e0a92cfe1bc91f992bd3ccdd0755448903eb91d91780ac4870bd13d8cfa17` |
| Frozen diagnostic host | `86ba69ffea8200080157edb25cbc49825654a14d2c09a6161dec447ab0e648be` |
| Baseline O0 pilot | `67c22292e9031c2ff5d5ac0e8553117aae8d8dd700201c2dcadc7904553e60cf` |
| Baseline compiler C | `531e6c240e020f7885a5c3bb61d062dd2ad6767fec5611ad5b9c3d214b68b362` |
| Candidate O0 pilot | `5c97ab90a2747802f61c33bf2fa0098e31c26389e25c2c89ba97ab20884b06d2` |
| Candidate compiler C | `7a88e4c053afc592c9bdcb8f56a65d7fb2103e3eb760ecd4891f931bb63368b8` |
| Integrated feature patch | `9b1c875ab30638de5b980b2cde664763d2c086fd4cda7f851766c292111d252c` |

The existing host stays FRESH and frozen: CLI-O0/runtime-O2/split8,
bootstrap dev-0e1598ed616e, Apple Clang 21, macOS arm64. Exactly one candidate
generation/link uses O0 with memory diagnostics; its 83 generated-C warnings
are retained, with no errors or existing-compiler rebuild.

The integrated renderer passes **15/15** callbacks; broader emit/verifier suites
pass **718** checks across 39 suites, including that renderer coverage. Tests
derive identities from ordinary producers and assert exact messages, help,
full spans and absent notes. They do not construct a VerifiedProgram bypass.
Current complete source snapshots kill the old-record-message mutation
(one failure/14 controls) and lost-source-origin mutation (13 failures/two
controls); both execute all 15 callbacks and exit 1 for the intended assertions.
The working candidate stays unchanged. Earlier TDD/setup evidence is retained
separately under the old source boundary, not counted as a current execution.

Generated C is inspected at the guarded argument/owner-error branches and
ordinary main. Failure construction stays in the missing-value branch; passing
an available span does not copy a phase product. No whole-emitter or whole-
compiler allocation-free claim follows.

## Complete input identity and costs

All **445** fixture inputs retain exact outcomes and full diagnostics:
349 accept and 96 reject on both variants. All shared successes emit identical
C; every one of 890 strict invocations has positive, balanced counters and
zero leaked objects or bytes. Allocations decrease on 207 accepted inputs and
are equal on 142; none grows.

| Boundary | Baseline | Candidate | Change | Ceiling |
| --- | ---: | ---: | ---: | ---: |
| Shared-349 strict allocations | 4,571,861 | 4,570,686 | -0.025701% | No growth |
| Sum of per-input min3 normal instructions | 14,480,956,225 | 14,471,911,606 | -0.062459% | +0.5% |
| Canonical host-build checkpoint allocations | 22,771,461 | 22,892,696 | +0.532399% | +1% |
| Canonical host-build min3 normal instructions | 41,942,811,947 | 42,202,535,582 | +0.619233% | +1% |

Return-zero and the three complete pinned UFCS provider trees retain identical
C, zero leaks and exactly unchanged allocations (8,229; 23,180; 140,959;
288,402). Their normal instruction changes are -0.135569%, -0.042806%,
-0.020108% and +0.003042%, all below +0.5%. These are emitter non-regression
controls, not acceptance of the pending UFCS semantic feature.

The corpus has 2,094 normal samples, three serial alternating pairs per legal
input; each sample has empty streams, a positive counter and C matching its
strict output. Both memory variables are unset outside `/usr/bin/time -l`.
Strict allocation measurements are separate. The table sums independent
per-input minima, not the minimum complete-corpus total.

The host proxy uses independently complete 43/44-file immutable snapshots at
the same physical source/result paths. Only its owned temporary source copy
is cleared between variants, outside timing, preventing stale module files.
Six normal runs measure instructions; two diagnostic runs use the existing
single `artifact_construction_complete` checkpoint. Normal/diagnostic C matches
within each variant. These are independently matched host-build proxies,
not self-compilation or comparisons with earlier differently located samples.

## Destination gate and retained evidence

The literal actual-main `make -C blorp_2 test` passes in 251.28 seconds:
2,814 component checks (2,648 host callbacks and 166 nested native checks),
445 e2e checks, 351 native links and 522 native runs. All 351 positive compiler
counter rows pass their allocation/instruction ceilings; ASan/UBSan and strict
leak checks pass. The native run uses unmodified fixture C and ordinary mains.

The dynamic frontier passes in 19.83 seconds: **34/36** source modules parse,
including the new diagnostics module. The two existing gaps remain Char at
byte 7,438 of lex and the function-type `pure` at byte 11,650 of specialize.
This is parsing evidence, not self-compilation; no stage B was produced.
Destination O0 binary SHA256 is
`fc00b959bd14089ac282c9a6aada0a625439bc01ad116491613a215468561a6e`;
frontier O2 stage A is
`039483979e6f98802bbc7e05b41782bd30a13496b3aac4c95221b787a16560b8`.
Both have the candidate C hash above. The destination's normal host
`390bdd0dd10d2f916c2d795462a278ed6bfa88b4c47928f9807ede748d331c7a`
stays FRESH; it is not substituted into the independently matched cost rows.
All 4,629 tracked/nonignored inputs, HEAD, index and source patch stay frozen
through the gate. Prior equality artifacts and their complete receipt remain
unchanged under `blorp_2/build/equality-landing/`.

No isolated full Make/e2e duplicate is claimed.
Raw commands, source/index/artifact manifests, every sample/C/diagnostic,
mutation controls and generated-C excerpts remain under
`quality-emitter-integrated/blorp/build/quality-emitter-integrated/gates/`.
The destination receipt is `blorp_2/build/emitter-landing/REPORT.md` in the
normal main checkout. No performance-latency, fixpoint or old-compiler release
claim is made.
