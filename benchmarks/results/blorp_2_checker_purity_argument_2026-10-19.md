# Unread checker purity argument — 2026-10-19

Status: **accept** after independent code-reviewer and test-runner approval. The independently reviewed
[plan](https://github.com/kablorp/blorp/blob/b1dd8fda7d5f6c3451f6dd492c54cd8d876fdd2b/blorp_2/PHASE_BOUNDARY_CLEANUPS_PLAN.md) was committed before
implementation as `e89eb0cd4`. Fixed B is the immediate accepted F3 main,
`e706b393d51038ba49af720999d308fd95ce4ea9`; this is not a cumulative F2 comparison.

Only `check/expressions.brp` changes: **10 ADD / 11 DEL, net −1 production
line**. Tests and fixtures: **0 ADD / 0 DEL**. Five private helpers lose their
unread purity parameter and six calls lose the forwarded argument. Public
interfaces, caller context, callback purity guard, imports and scheduling stay
intact. Existing caller and accepted-signature authorities enforce the real rule.
No replacement carrier, context abstraction or enforcement change.

Production patch SHA256:
`24e50dbcc627a7d5b9a73191888c38a4d22da04233ebbdc5f5f2143af0d499a6`.
Candidate expressions source SHA256:
`d1e1f16d7760ed2fa575073332e1138f0ee027eac111b4c981fed90ead722ed3`.

## Correctness

Five existing checker suites pass **144/144** before and after the change,
covering direct/transitive/UFCS purity, named callbacks, nested arguments,
contextual inference, and exact diagnostic order/content/spans. No new test
mirrors unused parameter plumbing. Disabling the actual named-callback purity
guard causes **142 PASS / 2 FAIL**, including the signature-compatible impure
callback and impurity-before-compatibility cases. Byte-exact restoration gives
**144/144 PASS**, empty stderr and all **906** workspace pins restored.

All **496** frozen CLI pairs match exactly: **400 successes / 96 diagnostics**,
including status, stdout, stderr, output presence and successful C bytes.
Full unit/runtime/grammar components pass **3,517/3,517**; tooling passes
**7/7**, both with empty stderr and all **1,008** gate pins unchanged.
The sole native umbrella passes **1,095/1,095**: 494 fixture/group checks,
600 nested checks and one umbrella. All gates exit zero with empty stderr
and all **1,008** pins unchanged. All 402 native allocation/launcher-wrapped
instruction rows are positive and within unchanged caps; strict zero-live
accounting and existing C11/O0 ASan/UBSan checks pass.
Focused/mutation counts overlap full gates and must not be summed as unique
coverage. No syntax or language-reference change is involved.

## Matched resource evidence

Fresh matched B/C source-construction proxy and six controls use one diagnostic
sample and normal order B1,C1,C2,B2,B3,C3. All 56 samples succeed; original raw
samples are retained. Instructions use normal min3; RSS uses normal median3.

| Construction proxy | F3 B | F4 C | Change |
| --- | ---: | ---: | ---: |
| Diagnostic allocations | 25,515,124 | 25,513,365 | −1,759 / −0.006894% |
| Normal retired instructions | 46,718,397,955 | 46,712,882,885 | −5,515,070 / −0.011805% |
| Normal peak RSS, bytes | 250,789,888 | 250,527,744 | −262,144 / −0.104527% |

| Direct target control | Allocations | Instructions | Median RSS |
| --- | ---: | ---: | ---: |
| `pure/calls.brp` | unchanged | +0.207426% | +16 KiB |
| `ufcs/chain_64.brp` | unchanged | −0.025228% | +16 KiB |
| `generic/named/identity.brp` | unchanged | +0.059939% | +16 KiB |
| `generic/named/ordered.brp` | unchanged | −0.021090% | +16 KiB |
| `generic/named/managed.brp` | unchanged | +0.033049% | +16 KiB |
| `return/zero.brp` | unchanged | −0.070307% | unchanged |

All increases remain below the predeclared attention and hard limits. Positive
construction direction and smaller private interfaces support acceptance;
individual control fluctuations do not establish a general target speedup.
Strict target diagnostic accounting is balanced and positive with zero live
objects/bytes. Within-role normal/diagnostic output hashes match for every
workload, and all six controls have byte-identical B/C output.

At the host artifact checkpoint, live objects fall 1,432,366→1,432,245 and
allocator bytes 120,528,448→120,520,576. These are diagnostic construction
observations, not target lifetime evidence.
The host source-to-C proxy omits linking, target self-compilation and unavailable
target lifetime measurements. Narrower helper interfaces do not establish earlier
physical retirement or an elapsed-speedup claim.

The existing native harness puts `/usr/bin/env` inside its timed command. Its
unchanged instruction checks remain compatibility gates, with launcher-boundary
attribution unresolved in a separate task; they do not establish compiler-only
budgets across the corpus. This slice's matched target controls time the normal
compiler binary directly, with environment passed by the process API. Allocation,
output and sanitizer gates have separate oracles.

## Provenance and C inspection

All 41 B compiler sources match accepted F3 main and its saved C-source freeze;
source-matched normal `674260e1` / diagnostic `99d874b2` are reused as B after
artifact checks. The host/target libraries, tools and 496 fixture roots are
frozen. The borrowed repository host remains FRESH, SHA `97479b34`.

Candidate normal `96ac23e5` / diagnostic `bf46ef59` each link once from the same
unmodified C, SHA `82e64d69`, at O0 with diagnostics=0/1 and `-lm -lpthread`.
Both links preserve 90 inherited warnings in the same three classes.
Generated compiler C has exactly five common function prototypes losing one
parameter each, matching the private helper changes. Actual purity enforcement
is protected by the unchanged source authorities and mutation-checked tests.

Raw evidence stays under ignored `build/checker-purity-argument-2026-10-19/`:
baseline/source freezes, all commands and raw samples, compiler images, prototype
excerpts, focused/mutation results and independent reviews. Test-runner final
receipt SHA256: `fbd864ae0c21a32d25f6454be742f066d137025e4d3ea5d5dcd53487fb5ee3c7`.
No failures remain. Preserve and verify
the complete packet in the primary checkout before archival or borrowing images.
