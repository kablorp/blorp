# Generic automatic equality

T4b derives conditional equality for generic named records and unions from
actual fields and payloads. Phantom parameters add no unnecessary bounds but
remain semantic specialization arguments. Authored families take precedence,
including their actual non-equality conditions. Ordinary construction is not
constrained by equality availability. The production library is unchanged;
canonical equality is selected from the configured prelude. T5 rollout remains
separate.

One completed actual-member summary supplies ordinary family bounds and the
genuine aggregate-owned template. Check replaces the signed trait-depth
approximation with constructor-path push/pop analysis, preserving constructor
slots and default Self guards. All pumping derivations contribute to candidate
classification; unavailable children propagate through every automatic parent.
Final Check inspects constants, all bodies and callable creations before sealing
its result, without replaying earlier name/type/member/bound checks. Together
with the existing callable/layout finiteness boundary, this proves finite
specialization keys conservatively, not runtime termination. No trait state
reaches ownership or emission.

## Correctness

The candidate is composed onto `554f61f36e036b1589f70ac85e0300d3a55d653b`,
preserving the independent String reuse change. Qualification used ordinary
entrypoints and unmodified emitted C:

| Boundary | Actual result |
| --- | --- |
| Changed focused owners | 38 PASS |
| Maintained fixpoint | A/B/C emitted C identical (`d7a6e56f...`); 583 ordinary fixture pairs |
| Maintained native behavior | 606 outer cases PASS; nested PASS rows are not added to this count |
| Components | 4,619 hosted + 188 target callbacks; 27 positive balanced strict reports |
| Required native owner | 12 inner cases + one outer bridge PASS, instructions required and limits enforced |
| Default-library whole-source strict | 31,773,230 allocations/releases; zero leaks/bytes |
| Explicit canonical-active prototype, ASan/UBSan + strict | 31,918,631 allocations/releases; zero leaks/bytes and no sanitizer diagnostics |
| Isolated actual A/B CLI | 54 calls: 13 accepted and 14 rejected cases per role; exact status/streams, accepted C parity, absent/sentinel preservation |

The new generic native main retains 25 exact answers, `left`/`right` effect
order, exit 23, sanitizer checks and 24 positive balanced target allocations.
Its compiler used 114,940 allocations and 359,251,304 instructions under the
new 150,000/400,000,000 ceilings. All four existing derived fixture ceilings
also passed. The finite phantom/default instance-key cycle is checked only by
phase oracles: its source loops at runtime and is never executed natively.

The three ordinary-input oracle mutations ran on the retained aa87 predecessor:
each produced 11 PASS and one named generic wrong-main failure, plus the outer
failure. The owner and generic input remain byte-identical in this composition;
the fresh B twelve-case control supplies current-runtime acceptance. The
historical mutations are not claimed as fresh B executions.

Fullproof recorded 119 allocation-debt rows with broad instructions disabled:
118 prior rows and one new concrete scalar case at 7,039 against 7,000. The
unchanged four-case owner reproduced the exact allocation-only failure, with
31,816,995 instructions below 55M. A measured allocation ceiling of 7,500 and
its factual comment then passed all four cases (31,809,107 instructions). The
instruction ceiling is unchanged. No phase-causality claim is made for the
743-allocation parent difference. This closes the additional debt by an explicit
measured amendment; the 118 inherited rows remain visible. The earlier fullproof
is composed with this later two-line test-only correction, not rerun or relabeled.

## Matched costs

The prospectively frozen epoch used the same Original02b source/library, private
environment, CWD, physical output path and C toolchain for three genuine roles.
Parent and candidate normal/diagnostic binaries were linked at -O0 from their
actual self-built B C, so the parent comparison includes the String runtime.
Three strict samples ran Original/Parent/Candidate, followed by exactly:

`OriginalP1 ParentP1 C1 C2 OriginalP2 ParentP2 OriginalP3 ParentP3 C3`

Both comparisons project P1 C1 C2 P2 P3 C3. The same three candidate observations
are shared transparently, with no selection, repeats or discarded samples.
All 283 guarded inputs remained unchanged. Every strict report was positive and balanced
with zero leaked bytes; normal streams were quiet and actual retired counters
were present.

| Role | Allocations | Minimum of three instructions |
| --- | ---: | ---: |
| Original02b | 30,981,091 | 911,724,124,563 (P2) |
| Parent554 B | 27,912,089 | 916,400,440,477 (P2) |
| Candidate B | 27,920,941 | 916,503,082,289 (C2) |

Candidate growth against the parent is **+0.031714% allocations / +0.011201%
instructions**, below the 2% investigation trigger and 5% ceilings. Against
Original it is **−9.877477% allocations / +0.524167% instructions**, within the
unchanged cumulative 5% ceilings. The cumulative allocation reduction includes
String-runtime changes and is not attributed to T4b. C3 elapsed 69.889 seconds
and was retained; all individual RSS observations remain raw evidence without
a separate RSS ceiling.

Compiler lineage is explicit: the seed-emitted A producer C is `6115eb9f...`;
current-source A/B/C emitted output is `d7a6e56f...`. Parent B producer C is
`044ce4ce...`, candidate B producer C is `d7a6e56f...`. Frozen old-input output
is Original `276cdc48...` and parent/candidate `b65c9748...`. Cross-version C
identity is not required; each observed role-specific output was frozen before
measurement. Both whole-source memory outputs match the actual fixpoint C.
The prototype library was supplied explicitly, never activated by default.

## Retained limits and evidence

The compact 32-to-64 phase probe grew 3.873x in allocations and 10.939x in
retired instructions, triggering investigation. Separate observing copies
actually executed six instrumented calls and traced intermediate-capacity
clustering in the existing integer map: queries grew 7.758x and probe steps
12.765x. Those IO counts are attribution, not instruction samples. No hash,
capacity or observer change was added to production. Reverse pumping work was
not exercised by that bounded probe. The scaling limitation remains visible;
passing whole-workload measurements do not erase it.

The older aa87 epoch retained a valid strict pair, then stopped on an unrelated
Root README guard change during its first normal sample. It supplies no normal
qualification. The independent String change required fresh composition and the
complete new twelve-call epoch. Earlier seed-binder and hosted TestSuite setup
failures remain retained, with no semantic/resource credit. No emitted C or
native entrypoint was rewritten.

The compiler delta is **943 ADD / 317 DEL / +626 net**; tests and fixture sources
are **1,159 ADD / 82 DEL / +1,077 net**. Fixture library code is unchanged.
The recursion replacement is +308 and its path-analysis module +203, within the
reviewed +650 investigation / +900 compiler ceiling. Publication prose is
counted separately in the final packet. Existing callable/layout checks remain
necessary; the path proof is conservative outside the required positive controls.

Raw evidence is retained under Root
`build/traits-implementation-2026-10-22/T0-qualification/T4b-composed554-*`
and `T4b-qualification/three-role-cost554`, plus the author worktree's
`build/traits-T4b-build554`. Final reference/report edits follow the completed
compiled epochs with compiler, tests and library bytes unchanged. Exact packet,
independent review and publication receipts are retained with that qualification.
