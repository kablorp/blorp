# Preserve verifier projection facts

Status: final source reviewed twice; functional qualification complete.
This is an ordinary source cleanup, not a seed publication or resource/M8 pass.

## Result and scope

Projection validation now returns the place and immediate borrow it proves.
Operation validation passes those facts into one checked `KnownValue`
constructor. Publication no longer reconstructs them through `immediate_parent`,
`definition_parent` or `definition_place`; all three helpers and their
lookup-error-to-absence fallbacks are deleted.

The producer is projection validation. A private transient `ProjectionParent`
has a nonoptional proven place and a legitimately optional borrow. A local
`KnownValue` candidate lives until the existing stored-payload discharge,
result-ownership and next-owner checks finish; only then is it appended to
`VerificationFacts.values`. Subsequent borrowing and nested projection consume
those published facts. There is no additional persistent catalogue or public API.

Selected roots retain the explicit selection argument, including an owner
acquired after definition. Descendants retain the immediate source borrow.
Ordinary values and fresh suffixes keep absent provenance; record reads keep
their validated explicit borrow. All legitimate Option combinations remain.
Independent raw-IR, layout, argument, guard, liveness and ownership checks remain.
The order remains ordinal, membership, operation checks, final type comparison,
stored-payload discharge, result/owner validation and publication. Call-specific
result errors still precede the generic definition-type error.

Production is **110 ADD / 116 DEL, net -6 handwritten lines**; tests are
**48 ADD / 0 DEL**. These are separate physical line counts, without compressed
formatting or deleted coverage. Three reconstruction helpers disappear; the new
checked constructor replaces final assembly, rather than adding another product.

## Prospective acceptance and provenance

Before editing, the limits were set to a net production-line reduction;
reassessment for repeated allocation or retired-instruction increases above
0.5%; and investigation for RSS increases above 2%. RSS was an investigation
trigger, not an automatic hard ceiling. The user's overall-direction guidance
does not require every metric to improve. Existing fixture caps stay unchanged.

The cost baseline is `5d0d4cc892404f1b7ca2f2a05776bf522541dcfd`. The branch
fast-forwarded to `91d67685f` before final qualification; that commit changes the
bootstrap build route but no compiler, target-library or fixture source.
The final verifier SHA-256 is
`5834e427c3fea88b98f2eab1802539f6727263220b35e4284989cde8ca88f082`;
the direct test SHA-256 is
`0d2ed3287d510425cf250ecb5f646d36153f26ba7a8eda849da83e787f78c6e6`.

All 612 frozen compiler/library/fixture files match baseline Git blobs. Every
cost sample checks those input hashes before and after execution, using the
same physical input, library, working directory and output path. The normal
and diagnostic compilers link separately at **-O0**, diagnostics 0/1, with
Apple Clang 21 and `-lm -lpthread`, matching the maintained target link policy.
Both actual self-built compiler images are generated through fresh legacy-built
A compilers; the pinned-seed route independently reproduces the candidate C.
The repository host is FRESH from immutable `dev-07bc7629a132`, CLI O0/runtime O2.

The unchanged baseline normal/diagnostic hashes are `d9e991b4...88c40` and
`dde240fd...31753a`; final normal/diagnostic hashes are `6b196ce5...3fcb34`
and `4568c148...e404af`. Complete hashes, commands, flags, input inventories,
streams and raw counters remain in the local evidence packet.

## Final matched costs

Diagnostic samples provide allocations; normal samples provide instructions and
RSS via `/usr/bin/time -l`. A fresh final batch runs B1,C1,C2,B2,B3,C3, with all
samples retained. The earlier candidate's batch remains separate. Background
machine activity is uncontrolled; the compatibility measurement `lock` command
is a passthrough, not a machine lock. No elapsed-speedup claim is made.

| Actual self-built compiler, frozen self-compile | Baseline | Final candidate | Change |
| --- | ---: | ---: | ---: |
| Allocations | 27,373,460 | 27,312,950 | -60,510 (-0.2211%) |
| Minimum retired instructions, 3 normal runs | 739,938,399,045 | 739,899,956,130 | -0.0052% |
| Median peak RSS, 3 normal runs | 261,357,568 B | 267,812,864 B | +6,455,296 B (+2.4699%) |

Instructions are effectively flat. RSS is **6.16 MiB higher**; this is a real
reported tradeoff, not a claimed footprint improvement. Both diagnostic runs
have equal allocations/releases, zero tracked leaks and zero outstanding bytes.
Both diagnostic and all six normal samples emit exactly 17,129,617 bytes,
SHA-256 `3d0def0d00f6c6ec003923d7acb2f8854fa506a6cf6b7c04611322a47b7b7f8b`.

A separate ignored Blorp probe prepares one full ownership program before
resetting memory statistics, calls public production `verify` 100 times and
requires 100 successes. Setup is outside the allocation epoch; counters are
read before setup data is released. Allocations/releases fall from
**276,909,500 to 271,716,600 (-1.8753%)**. This uses the legacy host's
representation, not the target allocator. Its whole-process instructions include
setup and are not presented as phase-only instructions. It is a measurement
harness, not an alternate fixture entrypoint.

Final target-generated compiler C is 17,134,812 bytes: **5,195 bytes larger
(+0.0303%)** than baseline. Its SHA-256 is
`98f5b33457b44e79f504bc11aa01b76e78e6f77a76ccfe4acec66b14aae8d42b`.
Legacy-built A and the self-built candidate produce those exact changed-source
bytes; both changed-source runs have empty stdout and exact balanced strict
reports. This proves
source/C self-reproduction, without claiming complete M8 acceptance.

## RSS investigation and the first candidate

The first candidate retained an operation-inferred type where baseline retained
`definition.value_type`. Two independent reviews confirmed that fresh record,
union-construction and suffix type wrappers could consequently survive comparison
inside verification facts alongside the still-live declared types. The final
checked constructor compares the inferred type, then retains the declared type
and proven metadata in one construction. Child places use that declared type too.
No intermediate KnownValue record update or new tracing mechanism is needed.

That lifetime correction is established by the source; its contribution to RSS
is **not** established. The first candidate saved 46,993 self-compile allocations
(-0.1717%), had effectively flat instructions (-0.0131%), and increased median
RSS by 5,554,176 B (+2.1198%). Its raw samples, source image and gates remain saved;
none are relabelled as final-candidate evidence.

One fixed 12-process contrast batch used the first candidate and baseline on
`integer/maximum.brp` and `pattern/moderate_nested.brp` (32 nested payloads),
three runs each in alternating order. Output C matched within each fixture.
Median RSS deltas were +409,600 B for the projection-light input and +147,456 B
for the nested-pattern input. This does not localize the full-source increase
to projections or to a compiler phase. The final batch still shows higher RSS.
No retry was used to make that result disappear, and no retained-memory or
allocator-cause claim is made.

The assessment is a bounded mixed tradeoff: fewer source lines and allocations,
flat instructions, and higher whole-process peak RSS. The private proof carrier
is not free—legacy-generated C allocates it and releases its place/borrow fields.
Its cost is included. The simpler producer-to-consumer contract is retained under
the user's overall-direction guidance; there is no independent hard RSS ceiling
being waived. All functional, counter-validity and accounting gates remain binding.

## Correctness and gate boundaries

Three baseline-compatible direct tests strengthen unmanaged nested List/union
places and exact guard-before-type-before-ownership error precedence. Their
owning suite passes **23/23 on baseline**; the final candidate passes **727/727**
across 40 verifier suites. This is a representation cleanup, not a semantic bug
with a baseline RED. Early unsupported nested propagation and missing local type
annotations were corrected within the bootstrap subset; failed attempts are saved.

Two final mutations remove an element place or payload parent. They trigger
8/23 and 30/727 failing callbacks respectively, including the new unmanaged case
and existing acquired-root lifetime checks. Exact restoration returns the source
to its approved hash and the focused suite to 23/23. The payload mutation initially
survived the smaller structural suite; the complete verifier suites supply its oracle.

The final unchanged `make -C blorp_2 test` exits 2. It passes all **4,178**
hosted component/runtime/grammar checks and all **781** nested native checks.
Its native group result is **92 PASS / 467 FAIL**; every failure is a compiler
budget (**112 allocation, 355 instruction overruns**), with no semantic, setup,
sanitizer or accounting error. The failing umbrella adds one raw FAIL, giving
5,051 raw PASS / 468 FAIL across the full command.

The documented `test-e2e` override with the exact-base self-built compiler
reproduces the same failure sequence, categories and caps, in order. Before
reusing that saved reproduction, the independent runner checked all 1,031
relevant harness, fixture, library and host pins unchanged. All **1,079** final
qualification pins remain unchanged. The first candidate's separate gate logs
and all 1,077 guarded pins also remain saved. Strict-local remains **FAIL with
baseline-reproduced resource debt**, not a green strict-local gate.

Ordinary source qualification uses the existing maintained CI policy in
`.github/workflows/ci-platform.yml:242–260` and `blorp_2/README.md:428–434`:
CI e2e disables instruction measurement and records allocation debt. It preserves
allocation FAIL records and all behavior, counter-validity, accounting and
sanitizer checks. CI instructions remain **unmeasured**, not PASS. This source
policy is distinct from the C-hash-bound seed-publication exception; this change
does not publish a seed or modify its pin. No cap or policy implementation changes.
The older scripts README's statement that CI enforces allocation caps is stale;
the maintained workflow and specific reference own the current route.

The final maintained CI-policy equivalent is:

```sh
BLORP_2_INSTRUCTION_CHECK=disabled \
BLORP_2_RESOURCE_POLICY=record-allocation-debt \
make -C blorp_2 test-e2e
```

It exits **0** with **559/559 logical groups** and **781/781 nested native checks**
passing (1,341 raw PASS including the umbrella; zero FAIL callbacks, empty stderr).
All **112** actual `BLORP2_ALLOCATION_RESULT status=FAIL` records remain in stdout,
each with instructions unmeasured; all 471 cost rows mark instructions disabled.
All behavioral, counter-validity, strict-accounting and sanitizer checks pass.
The strict and CI-policy runs use the same compiler C and executable throughout;
retained copies are SHA-256 `98f5b334...aae8d42b` and `d8315207...8305473f`.
This is successful ordinary-source qualification under the existing CI policy,
not fixture allocation-budget, instruction-budget or full M8 acceptance.

Two independent exact-diff code reviews approve the final source. Both cost
reviews accept the explicitly mixed RSS tradeoff under the prospective limits.
The independent test runner and final evidence reviews retain the strict debt
and CI-policy distinction above; no cap or policy is changed for this cleanup.

The full raw local evidence packet is preserved in the primary checkout at
`build/verified-projection-facts-2026-10-20/`. It includes immutable input and
source snapshots, old/new compiler C and paired executables, full raw counter
reports, mutations, both candidate attempts, gate commands/logs, reviewed hashes
and review receipts. The implementation worktree's original packet is
`build/verified-projection-facts/`; historical filenames and manifests retain
their original provenance rather than being relabelled as final evidence.
