# Target List update names — validation, 2026-10-18

**Historical API names:** the target-only rename below was subsequently reversed
to preserve the shared host/target bootstrap interface. The checked implementation
and approved limits remain. See the [restoration report](blorp_2_list_bootstrap_names_2026-10-18.md)
and [deferred coordinated rename](https://github.com/kablorp/blorp/blob/2ebbebf83c08b45cdf0c807453f89e12fb4b4ac9/blorp_2/LIBRARY_PARITY.md#deferred-list-update-naming).

The requested target-only API
is implemented: `set(List[T], Int, T) -> Option[List[T]]` returns Some(updated)
or None; `set_or_keep(List[T], Int, T) -> List[T]` returns the updated value or
an unchanged value for an invalid index. Both eagerly evaluate replacement
arguments. Host `standard_library/src`, compiler sources and runtime are
unchanged. The checked wrapper is an ordinary get/match function; the existing
`list.set` intrinsic remains the no-op-on-invalid operation.

The library implementation is 7 ADD / 2 DEL (+5 production lines). Tests are
86 ADD / 22 DEL (+64), including the 53-line new native fixture, three
mechanically renamed fixtures, owner registration and allocation-limit comments.
Target references document the intentional difference from host set_index/set.
Compiler-source migration is outside this change. The actual self-compilation
frontier therefore remains the missing `list.set_index` import in own/own.brp.

## Correctness

The before-implementation finalized fixture rejects the old return type with
`expression does not match the expected type` and help to use
`Option[List[String]]`; no successful-artifact B denominator is claimed for it.
An earlier fixture setup mistake using unsupported String concat was corrected
to add and preserved separately; it is not a semantic RED.

The original [full native inventory](/Users/keithphilpott/CLionProjects/blorp/build/bootstrap-evidence/list-set-names-2026-10-18/independent-full-native01/RECEIPT.json),
SHA e1744e4b1cac6b484a0cf32fc81c59a0637a3cda5fd253f532f7df25d9d99cdb,
completed once with unchanged ceilings: 484 direct PASS / 9 direct FAIL,
599 nested native PASS and a failing umbrella. Flat totals are 1,083 PASS /
10 FAIL; all nine direct failures are allocation ceilings, with no semantic,
setup, native-output or instruction-limit failures. All 1,610 pins were stable.
The new checked fixture passes bounds, first/last updates, Void presence,
once-only eager replacement effects, original/replacement aliases, and mortal
String escape with UTF-8/NUL. Strict zero accounting, required instruction
counters, O0 strict C11 and ASan/UBSan remain enabled. Its canonical-path cost is
43,312 allocations and 138,015,676 diagnostic instructions under 45,000/200M.

Two [restored branch faults](/Users/keithphilpott/CLionProjects/blorp/build/bootstrap-evidence/list-set-names-2026-10-18/checked-only-execution/RECEIPT.json),
SHA 3dbcf4584bc1963119d1bf2074d988b52b2e9ffc63c6d5ba14c95754f91edb1a,
replace valid Some with None and invalid None with Some separately. Each reaches
normal native execution and fails exact stdout within unchanged caps; each exact
restoration passes the same one-case owner. All 693 byte/mode/size pins restore.
The ignored adapter selects the existing named callback, requires a singleton,
and uses its ordinary harness and real main.

The [root C review](/Users/keithphilpott/CLionProjects/blorp/build/bootstrap-evidence/list-set-names-2026-10-18/ROOT_C_REVIEW.json)
inspects retained immutable C SHA
a6b3c48971ffafd5050f3d40f27e20a1ccd99e5d06502f1e4fc000fb77d8f227.
Int/Void/String instances call get once, update once only on the present edge,
and return ordinary Some/None. The String result acquires its outgoing List
occurrence before retiring temporary List and lookup Option owners. Consumer
escape and existing per-occurrence String lifetime use ordinary ownership.
No generated C is edited or normalized.

## Matched construction costs

Fixed B is bc6168b483a6680628a2d915ff18f22bd314ab69. The
[freeze](/Users/keithphilpott/CLionProjects/blorp/build/bootstrap-evidence/list-set-names-2026-10-18/matched-costs/FREEZE.json)
SHA 4f07ca7b3535db3ff424d6db6a89a07c5e53b4dfc47f3734dd96ad8357ff1b9b
pins both 11-file library sets and exact inputs. Three old fixture imports/calls
change set to set_or_keep; the other five input bytes agree. Both roles use the
same physical active source, library and output paths. The unchanged producer
pair is diagnostic 90fe6d25 / normal 834d1431 from exact C 77548285, matching all 41
compiler sources; the FRESH host 97479 and STD91 drive native TestSuites separately.
No compiler generation/relink, host self-compile proxy, baseline roll or retry
was needed. This measures target-compiler construction, not list runtime speed
or target self-compilation.

The [68 original calls](/Users/keithphilpott/CLionProjects/blorp/build/bootstrap-evidence/list-set-names-2026-10-18/matched-costs/RECEIPT.json)
retain argv, cwd, environment, strict diagnostic counters, time-l instruction
samples and C. Each B/C input gets one balanced strict diagnostic plus three
normal samples in order B1,C1,C2,B2,B3,C3. Both roles emit identical C across
all eight samples for every old root. The new checked root has identical C
across its four emissions, no B denominator, 43,315 allocations and 81,186,933
normal min3 instructions under 45,000/200M. Its copied-path count differs from
the native owner's canonical-path 43,312 and is not substituted for that sample.

| Equivalent input | Allocations B → C | Normal min3 instructions B → C |
| --- | ---: | ---: |
| list/set_int.brp | 21,582 → 22,920 (+6.199611%) | 52,602,188 → 54,324,131 (+3.273520%) |
| list/set_entries.brp | 21,791 → 23,133 (+6.158506%) | 52,974,466 → 54,668,810 (+3.198416%) |
| list/set_points.brp | 22,243 → 23,581 (+6.015376%) | 53,293,414 → 55,087,839 (+3.367067%) |
| return/zero.brp | 9,055 → 10,393 (+14.776367%) | 35,615,075 → 37,536,379 (+5.394637%) |
| list/entries.brp | 18,912 → 20,250 (+7.074873%) | 49,427,039 → 51,170,387 (+3.527114%) |
| list/mortal_entry.brp | 16,523 → 17,861 (+8.097803%) | 46,724,806 → 48,453,317 (+3.699343%) |
| list/empty_string.brp | 13,354 → 14,692 (+10.019470%) | 42,521,263 → 44,189,286 (+3.922797%) |
| list/append_int.brp | 18,630 → 19,969 (+7.187332%) | 49,083,585 → 50,755,920 (+3.407117%) |

All eight allocation +5% targets are missed. Return-zero and empty-String also
exceed the original +10% allocation hard ceiling. Return-zero misses the +5%
instruction target; every input passes the +10% instruction hard ceiling.
Old absolute allocation failures remain independent of relative gates. The
prelude loads List for every program and Check validates loaded function bodies
before specialization, so unused checked set adds compilation work without C.
The per-phase allocation split was not separately instrumented.

## Approved bounded revision

The [reviewed resource revision](/Users/keithphilpott/CLionProjects/blorp/build/bootstrap-evidence/list-set-names-2026-10-18/RESOURCE_REVISION_PROPOSAL.md)
was explicitly approved by the user on 2026-10-18. The proposal packet retains its
preapproval labels; the approval record below owns the decision. The revision is to allow +15% allocations only for this increment
against that fixed B/eight-input set, retaining all +5% target misses and the
unchanged instruction rules. Raise six existing allocation constants by 1,500:
syntax LIMITS 11500→13000, String UNREACHED_LONG_LIMITS 10100→11600,
List ENTRY 20000→21500, MORTAL 17500→19000, PRESENCE 14000→15500 and
APPEND_INT 19800→21300. Shared constants affect nine failing and three passing
positive callbacks, preserving old allocation headroom plus 161–162. All other
allocation ceilings, all instruction ceilings and the new 45,000/200M bounds
stay unchanged. The applied six-number patch is c203fdd658d733ca8fff905f6123fd5e289aabe5b81de5e865fe61a6ef15b3cd; adjacent comments explain the measured cost.

The [approval record](/Users/keithphilpott/CLionProjects/blorp/build/bootstrap-evidence/list-set-names-2026-10-18/USER_APPROVAL.json)
preserves the user's exact approval and scope. The
[approved-contract receipt](/Users/keithphilpott/CLionProjects/blorp/build/bootstrap-evidence/list-set-names-2026-10-18/APPROVED_CONTRACT_RECEIPT.json)
reuses all original samples without new measurement: all eight inputs pass the
approved allocation and unchanged instruction hard bounds. The original
+5% target misses and +10% allocation failures remain reported. This does not
change the fixed baseline or grant a future List allowance.

After that approval, the [fresh old-base gate](/Users/keithphilpott/CLionProjects/blorp/build/bootstrap-evidence/list-set-names-2026-10-18/independent-full-native02-approved/RECEIPT.json),
SHA a868de140b37bc18129331aa1a85a840eb05f22cadf65287b828b688170fff49,
cleared every allocation limit but failed one unchanged instruction ceiling:
syntax/pipe_string used 66,259,519 against 65,000,000. Its earlier observation
of 64,795,772 is not selected to replace that failure. Counts are 492 direct PASS /
1 resource FAIL, 599 nested native PASS and a failing umbrella. All 1,611 pins
were stable; no semantic/setup/native-output failure occurred. This remains a
failed gate and authorizes no instruction-cap change or retry.

## Current-main integration

While review was in progress, main advanced to
355d050a8fcab68508c48ec3d596ad922c9d8280, the independently accepted removal of
unused call-contract payloads. The feature patch and staged Git tree were saved,
reversed exactly, the branch fast-forwarded, and the feature reapplied by
three-way merge. All feature postimages are unchanged except README, which
preserves both sets of documentation edits. No compiler or host-source change
belongs to this feature; the guarded [composition receipt](/Users/keithphilpott/CLionProjects/blorp/build/bootstrap-evidence/list-set-names-2026-10-18/COMPOSITION.json)
retains the snapshot, patch and postimages.

For this composition the existing accepted-main diagnostic compiler is
b3e845439a17fea297d7d9cf1e3fa2f72a9ddebef38473b6e77804711e3ab91b, paired with
normal a197b6a6c16ecbedfa882115099f49f645bdb711e8188ab53d141f73d685a34c,
from unmodified C 0bff8c8110267df2c1fcf15eec7c4d7aea0e061f110ff2818dbdef8e9a9fa477.
All 41 source hashes match accepted main and the composed worktree; the
[producer receipt](/Users/keithphilpott/CLionProjects/blorp/build/bootstrap-evidence/list-set-names-2026-10-18/CURRENT_MAIN_PRODUCER.json)
checks the actual retained artifacts. No compiler regeneration/relink is needed.
The fixed-bc6168 feature measurements above remain unchanged; this new source/
producer role is separate current-base integration validation, not a baseline
roll or relabeling of the old failed run. All instruction ceilings remain unchanged.

The [current-main full native gate](/Users/keithphilpott/CLionProjects/blorp/build/bootstrap-evidence/list-set-names-2026-10-18/independent-current-main-full-native03/RECEIPT.json),
SHA efa9ce5687fae96cc6aa262f9e7b9859f83225c32aa5cde68ba47e8b42a172bd,
passes once in 258.27 seconds: 493 fixture callbacks, 599 nested native checks
and the umbrella pass (1,093 flat PASS / 0 FAIL). All 401 compiler cost rows
pass the approved allocation and unchanged instruction limits. Stderr is empty;
all 1,624 pins are stable. The syntax pipe-String case uses 12,523 / 13,000
allocations and 64,460,440 / 65,000,000 instructions. The new checked-set case
uses 42,827 / 45,000 allocations and 137,087,147 / 200,000,000 diagnostic
instructions. Required instruction counters, strict zero accounting, real main,
O0 C11 and ASan/UBSan remain enabled. No rebuild, relink or retry was made.

This integration pass covers the composed target library and current accepted
compiler. Full component suites were not repeated for this library-only change;
the accepted current-main compiler owns its component validation. The old-base
instruction failure and original matched costs remain separate evidence.

The final code-reviewer and test-runner reviews must both approve the exact
staged change and receipts before commit. Their final review records are
retained with this evidence packet.

Raw samples and receipts remain under ignored build/bootstrap-evidence/
list-set-names-2026-10-18/. No complete source checking or M8 proof is claimed.
