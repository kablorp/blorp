# Unread concrete record field span — 2026-10-19

Status: **accept** following independent code and test-runner review. The independently reviewed
[plan](https://github.com/kablorp/blorp/blob/b1dd8fda7d5f6c3451f6dd492c54cd8d876fdd2b/blorp_2/PHASE_BOUNDARY_CLEANUPS_PLAN.md) was committed before
implementation as `e89eb0cd4`. Fixed B is accepted F4 main,
`eca1f723cab0ef87c498b81f124edf51546765fc`; this is an incremental comparison.

Production: **2 ADD / 3 DEL, net −1**, solely in `specialize/specialize.brp`.
Tests: **7 ADD / 8 DEL, net −1**, solely in the existing record-update suite.
Fixtures: **0 ADD / 0 DEL**. Remove `ConcreteRecordField.span` and its sole
constructor assignment. Keep checked-field spans through field-identity
validation, child expression spans, and update-base spans for inherited
projection diagnostics. Lower already consumes only the field identity and
child expression. No new type, helper, phase or replacement carrier.

Production patch SHA256:
`0e228eb9ad71c5adfb63a8534d77009035abe0432b35d9b22dc12b13ba82e581`.
Candidate Specialize source SHA256:
`4053abd20894b7ed3be27209782744a7d3700b10dc5dddfbc45e5333ae2da899`.

## Correctness

The migrated assertions pass **20/20** on unchanged F4 production, then
**20/20** after the field removal. Exact child source/start/end, replacement
order, MIN/MAX values, types, ordinals and nominal owners remain covered.
Only the duplicate equality between two copies of the same span and its
unused import disappear.

Shifting both translated child-span endpoints by one causes **19 PASS / 1 FAIL**,
exactly the written-replacement order/value/type/span callback. Byte-exact
restoration returns **20/20 PASS**, empty stderr and all **906** workspace
pins restored. Focused counts overlap broader gates and are not unique totals.
All **496** frozen CLI pairs match exactly: **400 successes / 96 diagnostics**,
including status, stdout, stderr, output presence and successful C bytes.
Full unit/runtime/grammar components pass **3,517/3,517**; tooling passes
**7/7**, both with empty stderr and all **1,008** pins unchanged.
The sole native umbrella passes **1,095/1,095**: 494 fixture/group checks,
600 nested checks and one umbrella. Every gate exits zero with empty stderr
and all **1,008** pins unchanged. Strict zero-live accounting and the existing
C11/O0 ASan/UBSan checks pass. All 402 native allocation/launcher-wrapped
instruction rows are positive and within unchanged numeric caps.

## Matched resource evidence

Fresh matched construction-proxy and six record controls use one diagnostic
sample and normal order B1,C1,C2,B2,B3,C3. All **56** samples succeed; originals
are retained. Instructions use normal min3; RSS uses normal median3.

| Construction proxy | F4 B | F5 C | Change |
| --- | ---: | ---: | ---: |
| Diagnostic allocations | 25,529,788 | 25,529,201 | −587 / −0.002299% |
| Normal retired instructions | 46,746,345,225 | 46,744,264,072 | −2,081,153 / −0.004452% |
| Normal peak RSS, bytes | 249,790,464 | 249,823,232 | +32,768 / +0.013118% |

| Direct target control | Allocations | Instructions | Median RSS |
| --- | ---: | ---: | ---: |
| `record/wide.brp` | unchanged | +0.069695% | unchanged |
| `record/generic/phantom_arguments.brp` | unchanged | −0.086065% | unchanged |
| `record/update/order.brp` | unchanged | −0.081803% | unchanged |
| `record/update/managed_reorder.brp` | unchanged | +0.062333% | unchanged |
| `record/update/escaped_children.brp` | unchanged | +0.004574% | +16 KiB |
| `return/zero.brp` | unchanged | +0.173630% | −16 KiB |

All increases remain below predeclared attention, hard and material-RSS
thresholds. Removing unused data with lower observed construction allocations
and instructions supports acceptance under the overall-direction policy; these
small variations do not establish a general speedup. No repeat or waiver is
needed. Strict target accounting is balanced and positive with zero live
objects/bytes. Within-role normal/diagnostic C hashes match for all workloads;
all six target controls have byte-identical B/C output.

At the diagnostic artifact checkpoint, live objects fall 1,432,245→1,432,203
and allocator bytes 120,557,856→120,555,024. These observations cover host
construction only. Physical input/library/output paths are fixed within each
comparison; the fresh denominators here are not cumulative F3/F4 measurements.

The host source-to-C construction proxy omits linking, target self-compilation
and unavailable target lifetime measurements. Removing the unused field does
not establish early physical retirement or an elapsed-speedup claim.

The unchanged native harness puts `/usr/bin/env` inside its timed command.
Its instruction rows are launcher-wrapped compatibility gates; compiler-only
attribution remains a separate task. Resource acceptance uses direct B/C binary
measurements with parent-supplied environments and three normal samples.
Allocation accounting, output identity and sanitizer checks have separate
oracles. No corpus-wide compiler-only instruction-budget claim is made.

## Provenance

All 41 B compiler sources and the paired images match accepted F4 after
hash-verifying its preserved packet. Host/target libraries and all 496 fixture
roots match frozen inputs. Baseline has **645** pins; candidate freeze has
**687** artifact/source pins and **906** workspace pins. The borrowed repository
host remains FRESH, SHA `97479b34`.

Candidate normal `0b8fbcdb` / diagnostic `12cc9cd5` each link once from the same
unmodified C, SHA `facdd41c`, at O0 with diagnostics=0/1 and `-lm -lpthread`.
Generated compiler C loses the concrete field record's inline span member
and third constructor argument, retaining its child pointer and release.
`C_REVIEW_FRONTEND.json` preserves exact B/C type, constructor and translation
call anchors and artifact hashes for this observation.
Independent source, oracle, C and resource reviews approve; full gates pass.
The final staged report also requires both independent publication approvals.

Raw evidence stays under ignored `build/concrete-record-field-span-2026-10-19/`:
baseline/source freezes, all commands and samples, compiler images,
focused/mutation results and independent reviews. Test-runner final receipt
SHA256: `f63c5eab9bd216f626103b93b946b3c828496725429aab470b1eda0c405b7fa1`.
No failures remain. Preserve and hash-verify
the complete packet in the primary checkout before archival or borrowing images.
