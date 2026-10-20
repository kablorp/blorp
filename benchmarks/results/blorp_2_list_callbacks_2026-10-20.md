# Ordinary List callback helpers

Status: combined components 3,661/native 1,180/421 rows passed; original FAILs retained.

The target library adds generic any/map/filter and three private range helpers.
Named/forwarded pure callbacks use accepted checking and specialization; no
compiler, runtime, prelude, callback ABI, lambda or capture change is included.
Balanced map/filter copy O(n log n) slots with O(log n) C stack through existing
concat. The any helper stops after a True left range. These bounds promise no speedup
or constant-stack claim; replace it after an accepted efficient builder/loop path.

The fixed cost B remains 1d02a670027ee05c2e18e0d19cbd22ac64ad23e4.
Original normal0 min3 and strict full EXIT allocation comparisons are retained:

| Control | B/C allocations | delta | B/C normal min3 instructions | delta |
| --- | ---: | ---: | ---: | ---: |
| return/zero | 10393/24740 | +138.044838% | 37691985/56251998 | +49.241272% |
| list/zero | 13305/27652 | +107.831642% | 41620197/60343517 | +44.986140% |
| literal_int | 16366/30712 | +87.657338% | 46054838/64756382 | +40.607121% |
| literal_empty | 16454/30800 | +87.188526% | 46420590/65095314 | +40.229398% |
| append_int | 19828/34105 | +72.004236% | 50478578/68984993 | +36.661918% |
| set_int | 22709/36986 | +62.869347% | 54087529/72527079 | +34.092055% |
| concat_int | 21342/35688 | +67.219567% | 52238029/70935921 | +35.793640% |
| entries | 20166/34441 | +70.787464% | 51105902/69651490 | +36.288545% |

All 16 original relative fields failed the general 5% target/10% hard; seven List
controls also failed both old absolute fields. Those 16+14 failures stay recorded.
No samples were repeated and all original B/C emitted-C identities were retained.

The standalone helper native 6232be6d epoch completed 430 outer passes/79 allocation failures,
645 semantic child passes and one umbrella failure, with 418 positive cost rows and no
instruction miss or overlap. All numeric diagnostics and terminals reconcile.
The new fixture passed exact 87-byte output and its 150k/600M limits at 116201
allocations/193880449 instructions (single timed diagnostic1, not normal min3).
Original fixture evidence: 108242 allocations/285896255 diagnostic instructions,
with normal min3 169366570. These measurement roles are distinct.
Standalone components passed 3651 named tests, including seven loaded-library checks.
All three target-only faults compiled/linked and produced exact wrong native output:
empty-any 86 bytes, map-order 87 bytes, filter-selection 83 bytes. Each fresh restored
main reproduced the 87-byte golden; source/mode/Git and prior evidence closed.

On 2026-10-20 the human approved exactly resource-proposal04, manifest
824b854abd95e136dba10018dd3798bc13b944f950322f9d74e6d28c70224627:
the eight recorded comparison exceptions, 64 allocation/seven instruction fields,
and this slice's 317 nonfixture gross ADD. General 5%/10%, HOST3%, fixed B and all
other limits remain. Approval does not relabel any historical failed receipt.

The approved standalone patch changed 71 tokens on 64 lines in 15 e2e files.
Its values came from retained maxima with one rounding to 1000 allocations/1M
instructions; those facts remain historical and are not combined-cost evidence.
Its full 418 rows and 142 governors/users remain in frozen resource-proposal04.

The current09bdd5fb projection keeps published Join and Option/Result intact.
The initial projection used each helper postimage only if main equaled original-before;
otherwise retain published main. This applies 22 tokens (15 allocation/seven instruction)
and retained 49 published allocation governors without summing or stacking.
CAP_OVERLAP.json records every original/main/helper-approved/composed tuple.
New fixture150k/600M remains unchanged. Combined costs have not been accepted.

Production85ADD/0DEL/+85, unit246 lines, the 76-line fixture and seven-line owner
registration are unchanged. The exact composed physical ledger is retained with
library-integration/preparation01; numeric replacements are charged as ADD and DEL.
The standalone317ADD allowance and original failures remain their separate epoch.
Plan140 lines and this report retain their original140/80 separate ceilings.

The combined gate used accepted CWD diagnostic9b22b4ac, host4980336e, STD91 and
private01b8. Components passed all 3,661; native semantics passed all 667. The full
native gate failed 85 allocation rows; 13 instruction misses overlapped. All 421
positive rows and failed original governors remain in receipt 45cd57e8.
Root and an independent reviewer approved only 71 allocation/nine instruction
fields, using shared-user maxima + 200 rounded up to 1,000 and maxima + 1M rounded up
to 1M. Other 208 fields, source, fixtures, predicates and original epochs are exact.
Offsets in the retained token table count decoded Unicode characters, not bytes.
The next run had one instruction miss of 40,558; all allocations/semantics passed.
Its receipt 6546d564 remains FAIL. Four reviewed current-run near-limit instruction
fields use both-run maxima with the same +1M, rounded up to 1M rule; final gate passed.
Receipt d4891b9f: native 1,180/0, 421 positive rows within limits, CLI0/stderr0.
Evidence: build/bootstrap-evidence/list-callback-helpers-2026-10-19 and
library-integration/{preparation01,execution01,execution02,execution03}.
