# Ordinary opaque types — validation, 2026-10-18

Nongeneric opaque types preserve nominal identity and defining-module conversion
permissions during checking, then erase to their accepted underlying types in
Specialize. Equal representations can share generic instances and layouts.
Resolved ordinary declaration IDs and ordered named callback choices remain
unchanged. Lower, Own, Verify, Emit and the runtime have no production changes.
The separately published [plan](https://github.com/kablorp/blorp/blob/b1dd8fda7d5f6c3451f6dd492c54cd8d876fdd2b/blorp_2/OPAQUE_TYPES_PLAN.md), commit
`2a7fcf65e26171fee366b6be33d9dd0010513e32`, withdrew the earlier SemanticRef/key
preparation proposal before implementation. No new erasure pass, context carrier,
wrapper allocation, ABI, registry or cache was introduced.

Assembly issues OpaqueId through its existing declaration inventory. Namespace
publishes declaration kind and visibility; Check seals the underlying TypeUse,
rejects cross-module conversion before checking its operand, and checks opaque
representation cycles. Independently recursive aggregates remain supported.
Specialize projects the closed nongeneric representation with an empty
substitution, evaluates conversion operands once, and preserves occurrence and
callee spans. Generic opaque declarations, opaque constants, inherited methods,
new recursive layout families, lambdas and captures remain outside this slice.

The complete production patch is SHA
`aadf17884d82c6e84e7d4b09c081f7258bc528dd4b59db6729ea438744b33d44`:
**561 ADD / 170 DEL / +391 net** across 16 existing modules, below the prospective
750 ADD / +500 net ceilings and 650 ADD / +450 assessment thresholds. Test owners
are separate: **1,751 ADD / 44 DEL / +1,707 net** across 15 paths, plus **236
fixture lines** across nine paths. The combined test/fixture diff is **1,987 ADD /
44 DEL / +1,943 net** across 24 paths. The separately budgeted owners and fixtures
remain below 1,900 added owner lines and 250 fixture lines;
root and test review explicitly assessed and approved continuation through 1,850
added lines for the remaining required oracles after reaching the 1,750 assessment
point. The functional packet's assembled test patch SHA is
`d01ec251bf64406249e7c36f120dc3261a250c2dc5974e7075cb5e6102e79175`.
The complete staged Git test/fixture diff SHA is
`310c515d9e5f7f5fcc0cb0802eee780900b872b0fd527cbccca60c2685065e48`;
these are different patch assembly formats over the same validated postimages.

## Functional and identity evidence

The independent [functional receipt](/Users/keithphilpott/CLionProjects/blorp/build/bootstrap-evidence/opaque-current-2026-10-18/final-functional02-2026-10-18/RECEIPT.json),
SHA `e5f239c6eccbf1e1614a1c92460f9292c0a667566b3400170d67032242539d6a`,
records **3,513 component PASS / 0 FAIL** and **1,091 native gate PASS / 0 FAIL**.
The native total is 492 direct fixture/group callbacks, 598 nested native checks
and one umbrella callback; focused counts overlap and must not be added.
Commands exited zero with empty stderr. All 400 reported compiler cost rows meet
unchanged caps. Instructions are required, strict memory accounting requires
positive balanced allocations and zero live objects, and ordinary native mains
use existing strict C11 flags with `-O0`, ASan and UBSan. All 1,608 source, library,
fixture, tool and artifact pins remained stable.

Tests cover exact nominal IDs inside scalar/List/Box types, public opaque/private
underlying types, permission/error ordering, diagnostic text/help/source/span,
conversion evaluation and spans, representation cycles, shared erased layouts,
distinct resolved callbacks, ownership acquisition/transfer and malformed public
ownership IR. Seven ordinary native roots cover Int, shared generic keys,
Float/Void effects, inline aggregates, mortal String/UTF-8/NUL aliases, Lists with
repeated children, and wrappers over independently recursive aggregates.

The [exhaustive old-corpus comparison](/Users/keithphilpott/CLionProjects/blorp/build/bootstrap-evidence/opaque-current-2026-10-18/root-cost-01/corpus-identity/RECEIPT.json)
ran 970 normal CLI calls over all 485 frozen pre-feature fixture inputs, including
support modules as roots. Status, stdout, stderr, C presence and C bytes agree for
480 pairs. Exactly five planned transitions occur without changing fixture bytes:

- `unsupported/opaque_type.brp` and `unsupported/opaque_import/main.brp` now succeed.
- `unsupported/into_opaque.brp` and `unsupported/from_opaque.brp` now report
  `unknown opaque type` at 3:14, with help to import or declare one.
- `unsupported/opaque_import/m.brp` as a root now reports existing MissingMain at
  2:1: `expected a main function`, with help `declare func main() -> Int: as the entrypoint`.

The [root C inspection](/Users/keithphilpott/CLionProjects/blorp/build/bootstrap-evidence/opaque-current-2026-10-18/root-cost-01/ROOT_C_REVIEW.json)
reads retained ordinary CLI emissions for all seven new roots, with exact hashes
and line anchors. It confirms shared Int/Box specialization, distinct callback
targets, ordinary scalar/aggregate storage, once-only effects, and existing
retains/transfers/drops with no opaque runtime form. These are immutable separate
emissions, not edits to or claims about the harness's deleted temporary C.
The full component gate also passes the existing 100,000-deep boxed-chain release
on a 512 KiB stack. The new shallow recursive opaque fixture proves behavior and
alias lifetime only; it adds no new stack-margin or compiler-product-depth claim.

## Matched resource contract

Fixed accepted B is `dcd8beb0af83f156ad0c482b2fd3235ba72bb8dc`; the intervening
plan commit changes no compiler input. The [freeze](/Users/keithphilpott/CLionProjects/blorp/build/bootstrap-evidence/opaque-current-2026-10-18/root-cost-01/FREEZE.json)
SHA is `80a43eee63b51c650197cb9f146d648d022b60ccaa3ac9522638173913bf7bcc`.
It pins both 41-source variants, the same physical active input path, host
standard-library 91-file set, target library 11-file set, tools, flags and corpus.
The normal/diagnostic host pair is respectively SHA `6852e1c6...` / `a362b0df...`.
Allocation is the unique schema-1 cumulative `artifact_construction_complete`
checkpoint, not whole-process strict totals. Instructions are the minimum of
three original normal samples, run serially in order B1,C1,C2,B2,B3,C3.

| Host source-to-C construction proxy | B | C | Change | Independent ceiling |
| --- | ---: | ---: | ---: | ---: |
| Allocations | 25,166,149 | 25,645,350 | +1.904149% | 25,921,133 (+3%) |
| Normal min3 retired instructions | 46,356,814,498 | 47,245,859,907 | +1.917831% | 47,747,518,932 (+3%) |

Both pass. The [proxy receipt](/Users/keithphilpott/CLionProjects/blorp/build/bootstrap-evidence/opaque-current-2026-10-18/root-cost-01/PROXY_RECEIPT.json)
retains all original samples, command files, phase checkpoints and C hashes.
CLI arguments are `compile --no-format --no-embed-runtime --time-phases --std-dir
<root standard_library/src> -o <proxy.c> <active/blorp_2/src/main.brp>`; normal
samples run under `/usr/bin/time -l`, diagnostic allocation uses
`BLORP_MEMORY_STATS=1`. Full argv/cwd/environment are in the neighboring
`B-alloc.command.json` and `B1.command.json`. All four emissions per role have
identical C bytes; changed compiler-source output is expected between roles.
This is a host construction proxy, not target self-compilation. The separate
named/lambda 8% cumulative exception does not apply here.

All [12 matched FEATURE controls](/Users/keithphilpott/CLionProjects/blorp/build/bootstrap-evidence/opaque-current-2026-10-18/root-cost-01/feature-controls/RECEIPT.json)
pass both independent +5% targets and +10% hard limits, all tighter absolute
caps, balanced strict accounting and exact B/C C identity. They retain exactly
the set named in the plan, with three original normal samples per producer.
Allocation deltas are zero for every control. Small negative instruction deltas
are not claimed as a speedup.

Newly accepted inputs have no successful B denominator. Their [prospective
absolute checks](/Users/keithphilpott/CLionProjects/blorp/build/bootstrap-evidence/opaque-current-2026-10-18/root-cost-01/accepted-root-costs02/RECEIPT.json)
use one strict diagnostic sample plus three original normal samples per root,
with identical C across each root's four emissions:

| Root | Allocations | Normal min3 instructions | Allocation / instruction caps |
| --- | ---: | ---: | ---: |
| Int | 10,463 | 37,808,346 | 35,000 / 140,000,000 |
| Generic keys | 19,410 | 50,257,386 | 35,000 / 140,000,000 |
| Scalar/Void | 12,611 | 41,018,681 | 35,000 / 140,000,000 |
| Inline aggregates | 17,116 | 47,779,258 | 45,000 / 180,000,000 |
| Managed String | 26,625 | 59,816,546 | 55,000 / 220,000,000 |
| List | 20,158 | 51,015,575 | 60,000 / 240,000,000 |
| Recursive aggregate | 23,908 | 55,744,104 | 75,000 / 300,000,000 |
| Old opaque declaration root | 9,106 | 35,497,732 | 35,000 / 140,000,000 |
| Old opaque import root | 9,274 | 35,934,762 | 35,000 / 140,000,000 |

All pass. These normal compiler measurements are separate from the diagnostic
native harness's cost rows, include no extra native executions, and do not
replace native output/sanitizer evidence.

## Provenance, corrections and limits

Functional tests use the FRESH repository host SHA `97479b34...` and the once-built
current-source diagnostic compiler SHA
`90fe6d256d7ea73e74a1def70698640da4fbfaf049d73992d4acb2d6e2c6463a`, generated
from C SHA `775482852ac0be65995f402b6955eb7e059a3c06bf84184ca7bdc41269952ba5`.
The normal target compiler SHA
`834d14317c0eb9b8569349ae5d2e441bf87770ef74417b5ac9d209bd934a2be4` was linked
from that same unmodified C with `-O0 -DBLORP_MEMORY_DIAGNOSTICS=0 -lm -lpthread`.
Both compiler links have the same 89 inherited warnings and no added warning
class; generated fixture C passes the harness's strict C11 compilation. Full
functional validation reused the compiler without regeneration or relinking.

Historical setup failures remain preserved: an oversized test tuple, unsupported
`Box {...}` fixture spelling, and a test accessing nonexistent/private
`ConcreteRecord.key.arguments`. They were corrected through ordinary nested
tuples, contextual record literals/generic `box` helpers, and the public `fields`
observer. None counts as semantic RED, a mutation kill or a resource failure.
The first partial absolute-cost packet remains historical; `accepted-root-costs02`
is the complete corrected fixture epoch. No cap, baseline or production code was
changed to obtain its results. Old SemanticRef preparation measurements remain
historical and are not relabeled as accepted.

The [restored-mutation receipt](/Users/keithphilpott/CLionProjects/blorp/build/bootstrap-evidence/opaque-current-2026-10-18/worker/mutations-2026-10-18/RECEIPT.json),
SHA `a436237f1b702e9bc5cd1f981499759de4a06c9685140ebdab1dd0139dfad5bc`,
records six effective probes across five published fault families, applied one
at a time: equal opaque IDs, missing construction-module permission, dropped
conversion operand, duplicated operand call, missing ownership acquisition, and
duplicate release. Required exact named callbacks failed for every probe.
The two effect faults reached real native execution with missing/repeated stdout;
the release fault reached native execution and the required managed fixture
failed with signal 6. The existing harness discards child sanitizer stderr on
process-status mismatch, so no retained ASan stack-text claim is made.

All three disposable mutant compilers generated and linked once successfully,
and all 21 native fixture compiler cost rows stayed within unchanged caps.
No setup failure counted as a kill, and there were no retries or host builds.
After each exact restoration, the same unit owners passed 32, 26 and 14 callbacks;
each of the three restored native groups passed seven fixture callbacks, seven
nested native checks and one ignored forwarding-adapter callback. Source bytes,
modes, all 1,608 pins, HEAD, branch, index and tracked patch were restored exactly.
No fault edit to Lower, Own or Emit remains in the accepted production patch.

The ordinary [current-source CLI probe](/Users/keithphilpott/CLionProjects/blorp/build/bootstrap-evidence/opaque-current-2026-10-18/root-cost-01/actual-source-probe/RECEIPT.json)
now stops at `src/own/own.brp:3:16`: `module list declares no public function or
type set_index`, with the public-export help. It exits 1 without C. This moves
past the old unsupported-opaque gate but does not establish that all source
opaque declarations pass checking: this namespace error occurs first. Target
library/source API alignment is a separate next slice. Complete source checking,
a target-built compiler, compiler-product destruction depth and the A/B/C M8
fixpoint remain unproved. The four callback Option/Result helpers, lambdas and
captures also remain outstanding.

The implementation, tests, generated C and evidence receive independent
architecture/code-reviewer and test-runner review before commit. Final review
uses these same production/test postimages; the status/report updates do not
change compiler inputs and require no repeated compiled gates. Raw commands,
streams, counter samples, pin manifests and review receipts stay under the
ignored `build/bootstrap-evidence/opaque-current-2026-10-18/` directory.
