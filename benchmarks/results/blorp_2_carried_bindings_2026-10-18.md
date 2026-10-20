# Carried bindings at structured joins

Measured 2026-10-18 against accepted unary main
`db8abb15af4250eba1ad4c6d3efc8171cf35adaf` (B). The measured candidate (C) is
that exact base plus feature patch
`b67726f0943af21afbf4dfdb71462a241c315c5b15f9c5d25e9133a7e6622778`.
Later documentation-only main advances do not move this comparison.

Statement and bound matches now carry the selected versions of reassigned outer
mutable bindings into their continuation. Managed outgoing occurrences acquire
independent obligations before terminal-live arm-local owners retire; enclosing
owners and old aliases remain available. This implements the complete
checker-to-emitter feature, separately from the accepted unary preparation.

All **3,976 serial cost calls passed** in one frozen epoch: eight original SOURCE
observations, 992 strict pilot observations, and 2,976 normal pilot observations.
There were no cost retries, refreezes, cap changes, skipped inputs or extra setup
generations. Every applicable absolute ceiling and every shared-input hard +3%
allocation/instruction gate passed independently.

| Boundary | Allocations B / C | Change | Normal min3 instructions B / C | Change |
| --- | ---: | ---: | ---: | ---: |
| Worst shared allocation and instruction state: `i0185-absent`, `join/deep.brp` | 25,349 / 25,626 | +1.093% | 61,568,413 / 61,978,675 | +0.666% |
| Original SOURCE construction checkpoint | 23,722,433 / 24,240,232 | +2.183% | 21,118,481,983 / 21,573,808,952 | +2.156% |

Acceptance uses the exact integer tests `100*C <= 103*B`, rather than rounded
percentages or averages. The feature's
[own approved policy](https://github.com/kablorp/blorp/blob/b1dd8fda7d5f6c3451f6dd492c54cd8d876fdd2b/blorp_2/CARRIED_BINDINGS_PLAN.md#prospective-m2-carried-feature-approval)
supersedes its historical +5%/+10% proposal. No library FEATURE TOTAL exception
or unary-preparation allowance transfers to this feature.

The current corpus has **501 invocation states**: 491 unchanged shared states
and ten candidate-only accepted-feature states; 470 start with absent output and
31 with preserved sentinels. It covers 476 physical fixture files, 150 generated
dependency files and their directory geometry. All 491 shared states retain exact
complete C, exit status, stdout, diagnostics and output-state bytes. Nothing is
normalized. Each strict observation has one positive balanced allocation/release
report and zero leaked objects and bytes. Expected compiler rejection statuses
remain expected outcomes, rather than being counted as failed observations.

The retired staged rejection `i0411-absent`, its source and its exact diagnostic
are preserved literally in the packet. Its replacement `carried_existing.brp`
changes the leading comment and path as well as acceptance; it is not asserted
to be a byte-identical rename. All ten accepted feature states are measured
separately, without ratios between old rejected and new accepted compilations.

| Accepted feature fixture | C allocations | C normal min3 instructions | Allocation / instruction ceilings |
| --- | ---: | ---: | ---: |
| `carried_int` | 12,727 | 40,995,824 | 30,000 / 150,000,000 |
| `carried_string_alias` | 15,209 | 44,394,883 | 30,000 / 150,000,000 |
| `carried_existing` | 10,526 | 37,409,920 | 30,000 / 150,000,000 |
| `carried_order` | 15,200 | 44,250,844 | 30,000 / 150,000,000 |
| `carried_rhs` | 12,833 | 41,088,235 | 30,000 / 150,000,000 |
| `carried_nested` | 25,005 | 65,416,044 | 60,000 / 300,000,000 |
| `carried_duplicate` | 15,289 | 44,487,460 | 30,000 / 150,000,000 |
| `carried_projected` | 16,324 | 45,879,429 | 30,000 / 150,000,000 |
| `carried_swap` | 15,584 | 44,908,287 | 30,000 / 150,000,000 |
| `carried_unused` | 13,293 | 41,885,842 | 30,000 / 150,000,000 |

These counts belong to the frozen canonical invocations, not the separate
functional calls with different working/output paths. The first scalar/String
limits remain 30,000/150,000,000; only the prospectively approved 46-line managed
nesting fixture uses 60,000/300,000,000. No existing ceiling was widened.

SOURCE ran first and passed both gates before the target collectors started.
Normal samples use B1,C1,C2,B2,B3,C3, with memory modes unset. Candidate-only
states use C1,C2,C3. SOURCE allocations retain the original schema1
`phase=artifact_construction_complete total_allocations` checkpoint, exactly one
positive occurrence with `BLORP_MEMORY_STATS=1`, leak mode unset, exit 0 and exact
Generated stdout. Exit-time totals and FEATURE TOTAL are not substitutes.

The original producer and normal SOURCE proxy is
`host-utf8-file-admission/blorp/bin/blorp-stage2`, SHA256
`34ac1a913c79fc14130c77fe4339f24885a2fa65f1d25fc4b873b627e10e1f33`.
The diagnostic SOURCE proxy is `blorp-stage2-diagnostic`, SHA256
`be31a5a3a070deef54707d8676a7c6157042484f40d0424dd5fb46835c09ff93`.
Both use the explicit original host's `standard_library/src`. All 598 original
host/source/library pins pass before and after collection. Normal calls unset
`BLORP_CC`, `BLORP_LEAK_CHECK` and `BLORP_MEMORY_STATS`; strict pilot calls set
`BLORP_LEAK_CHECK=strict` with the other two unset.

Exactly two setup C generations and four `/usr/bin/clang -O0` links built the
pilots, with `BLORP_MEMORY_DIAGNOSTICS=0/1` and `-lm -lpthread`. Target normal instruction
calls use the diagnostics-0 pilots and `/usr/bin/time -l`. Apple Clang 21.0.0 and
the time executable are pinned. Both variants have 40 compiler source BRP files
and eight target-library BRP files: 48 compiled BRP inputs. Full source/target
membership is 49, including the target README in both nine-member library
manifests and fixed-member installers. The three existing collectors and four
installers are byte-identical to the accepted authority; only case data, constant
configuration and owned paths were adapted.

| Artifact | B SHA256 | C SHA256 |
| --- | --- | --- |
| Compiler C | `db9e43a44ad2231570f38c32a646fe567ca7d2fc846a6768c8fe7bf24da4182c` | `3d3a5f75896062d02e67ce8497eafda23bd7b048d2404629f4dd0bbc43a8c6bf` |
| Normal pilot | `0e8a6a9321b102ad5a1cac95ad00d5ef7424e2c549b04cfc7d26954409695daf` | `b630128a34d1a8670d01a21b2fbe9ba7511660c89d062607c2f85e8cb28ee820` |
| Diagnostic pilot | `8238e6ebe92a960ed4ebc80879e4b845397c0c89f1d666ce9d63dbaa2bb87f53` | `2ad4de1b4a9353d472b628f71c57533692c9ba07e1b29cf16e4212c0b9a325c9` |

The compiler C intentionally changes from 8,022,627 to 8,148,088 bytes. Its full
raw delta and all warning messages were independently reviewed. Each B link has
88 warnings (3 qualifier, 57 parentheses-equality, 28 pointer/integer); each C
link has 90 (3/59/28), with zero errors. The two additional equality warnings are
the generated `leave_join` terminal-use check at C line 106036 and
`verify_join_arm` carried-arity check at line 129160. This host-generated compiler
C review is distinct from exact shared fixture-C identity.

The separately identified c04 host, SHA256
`c04f68ba64ac06f6cd3f924cdb4d87ce6b3d40d0f8fba2ef89b20e324b21ca57`,
and explicit ROOT standard library supplied functional validation: **168 focused**,
**3,313 unit/runtime/grammar** callbacks and **476 e2e cases** pass. The frozen ROOT
functional host remained FRESH against its own build inputs before and after;
this worktree borrows that verified host. This role is not the SOURCE producer
or a SOURCE metric substitute.
E2e runs unmodified emitted C through ordinary fixture mains with
C11/Wall/Wextra/Werror/pedantic/O0, ASan and UBSan. Its instruction checks were
disabled; strict leak checks and allocation caps remained active.

The unchanged current `carried_existing` input first failed against the accepted
unary functional pilot `7c3810d6838ff1828d569b5c053b85974a4ac7d4a553f451abb6c238ff3ece4a`:
compiler exit 1, empty stdout, absent C, location 6:4 and target span [144,149).
Its exact diagnostic is retained:

```text
blorp_2/test/e2e/fixtures/join/carried_existing.brp:6:4: error: reassigning a variable declared outside this match arm is not supported yet
help: bind the match's value with name = match ... instead; reassignment inside an arm arrives with joins that carry reassigned variables
```

Candidate compilation succeeds; that fixture's ordinary main intentionally exits
1 with empty streams. Compiler rejection status 1 is not conflated with that
successful program result.

The disposable scaling probe generated **24 programs and 48 check/verify endpoint
rows**, and all 24 ordinary mains passed the same strict native flags at default
limits. Its six 16/32/64/128 axes cover sequential join count, carrier width,
entry bindings, arm owners, nested join depth and nested carrier width. The entry
axis has exactly N bindings, four joins and two carriers. Nested join C brace
depths are 33/65/129/257; all compile without a depth override. Nested carrier
cases hold depth four (C depth 9). The retained managed16 fixture has C depth 33
and output `7\n1\n1\n1\n`. These are public-phase proxies: ManagedBytes is a
LIVE endpoint difference, not cumulative allocation/copy bytes. No isolated
phase instruction or copied-byte result is claimed. Binding-map snapshot and
`List.set` copy traffic remain a bounded follow-up; no index or cache is added.

The first disposable nested-probe draft failed host parsing on an invalid `or`
pattern before generating inputs. That failed source/log and stop receipt remain
preserved. Reviewed `|` corrections and a stop-first guard preceded the separate
successful phase run; this was probe setup, not a semantic failure or a cost
sample. No compiler implementation repair was made during the cost campaign.

All **16 deliberate mutants** produced their required named semantic failures,
then exact source restoration and an owning GREEN run before the next mutant.
These are the 13 historical behavior mutations plus three raw-borrow field
mutations. The latter each fail only their intended callback and restore to
14/14 own-join passes. The local replacement uses a defined enclosing String;
the parameter value/source replacements use a defined Choice parameter, so they
are scope-valid but type-wrong. No same-type second-String-parameter claim is made.
Finally, the actual original-producer diagnostic pilot passed three ordinary-main
smokes (`carried_rhs`, `carried_duplicate`, `carried_nested`) under the same native
sanitizers, with positive balanced zero-leak compiler reports. This separately
checks the producer difference from the c04 functional pilot.

Physical production delta is **533 added / 156 deleted / +377 net**, within
900/+450. Non-fixture test code totals **1,257 / 51 / +1,206**, within
1,600/+1,300: unit/runtime test code contributes 1,167/47/+1,120, and e2e
registration contributes 90/4/+86. The ten language fixtures occupy **217 physical
lines**, within ten/300. No coverage or formatting was compressed to meet a cap.

The [known supporting-host limitation](../../blorp_2/HOST_BOOTSTRAP_LIMITATIONS.md)
remains unresolved. Its historical strict proxy exited **99**, with 23,224,178
allocations, 22,711,214 releases, 512,964 live objects and 34,890,725 retained bytes.
That failed result is not green; no leaked allocations are subtracted. Its narrow
scope does not waive pilot/native strict zero, any threshold, or the original
SOURCE metric. Historical original-R0 cumulative compliance remains UNVERIFIED;
the preparation-only cumulative rule is not an additional feature ratio or a
transferred feature waiver.

Frozen epoch SHA256 is
`ae13be56560f1f300c11dc1a0ded3354b4136d5c3ff52d24df55b4d053b912d5`.
Raw commands, all observations, C, binaries and individual verdicts are retained
under `bootstrap-carried-current/blorp/build/carried-current-port/cost-01/`;
`cost-preparation/` holds the complete case, role, mode and protocol maps.
The canonical path is that epoch's `canonical/`, identical for B and C. Final
checks pass for all 3,167 immutable input pins, 39 protocol pins, 598 original
host pins, six artifacts and tool executables. All 906 functional inputs passed
again before the post-run plan-status and roadmap-link updates. After those
documentation outputs, only those two documents differ from the historical map;
the remaining 904 mapped files stay byte-exact. The measured production diff
SHA256 remains
`a97c8decee6b68a40752c7c5df26e0d079a1c8140f085e693133bef89e49e47b`.

These are matched compiler-input and original-host source-to-C proxies, **not
actual Blorp 2 self-compilation**. This report and the two status/link updates are
post-collection documentation OUTPUTS excluded from the immutable build inputs.
The frozen b677 input patch is retained separately from the final landing patch.
Code/corpus/protocol bytes remain those measured;
final report review, integration onto current main and publication are
coordinator-owned.

## Evidence availability after publication

After publication as `7acd6df25`, archiving the completed chat also archived its
managed worktrees and removed ignored build files. Managed restoration recovered
the exact committed source at `0274df53fc6fa9a02a0e5915aff4c247c0199cb0`, but did
not recover `cost-01/`, its 3,976-call raw dataset and pilot artifacts, or the
functional-first outputs. The retention statements above describe collection
time; those raw artifacts are now unavailable. The recorded observations and
criteria remain historical results, not newly reproduced measurements.

The committed report and the actual destination's 274 passing checks survive;
their streams remain in the main checkout's `build/blorp2-carried-landing-01/`.
The original 598-member input manifest was recovered from the separately retained
unary evidence with its exact recorded SHA256
`bea8dc2fc442fcbeff9c3935de3935cde2237588c08bb7de6920f3850b8a85c2`;
all 598 existing inputs were verified again. This recovers input provenance,
not the lost observations. Future validation must retain new results under an
explicitly reviewed setup; no missing measurement is reconstructed or relabeled
as historical evidence, and no cost ceiling or SOURCE policy changes here.
