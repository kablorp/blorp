# Ordinary List[String].join — 2026-10-20

Resource amendment approved on 2026-10-20; final components/native gates PASS.
The ordinary String-specific implementation has no compiler/runtime/builtin change.
Current Join is 22 ADD/1 DEL versus accepted Option a5e5; the original slice was 23/1.
Balanced recursion preserves order, separators, UTF-8/NUL and managed aliases.
Temporary cost is O(n+B*log(n+1)) copies/work and O(log(n+1)) stack, not host parity.

Fixed B is a656f5ce1de963c8e9c162460e181d696b39c1d5. Original 02ec/ef936/shared C9ab
roles and env88e19 stay fixed; no B sample was repeated or replaced. The current
library includes separately accepted Contains and AppendInt: the whole measured
increase must not be labeled Join-only runtime or algorithm cost. Original
Join-only Load+1782/Check+2606 allocation intervals explain 4388; later phases 0.
These intervals do not decompose whole-process instructions or combined cost.

Four current controls reuse original B and exact consumed input/library bytes.
Option/Result additions are unreachable from these four actual import closures;
loader queue/read authorities and per-file hashes bind reuse without 16 replays.
Instructions below are normal min3; all individual raw samples remain retained.

| Control | B→original Join→combined allocations | B→original Join→combined instructions |
| --- | ---: | ---: |
| return/zero |14515→18903→22813|43275346→48911283→53956932|
| concat |18055→22443→26355|48311873→54047173→59200677|
| managed/basic |17722→22110→26020|47702869→53451481→58574012|
| empty String |18780→23168→27078|49513992→55321763→60419817|

Every original/current 5% target and 10% hard miss stays FAIL. Combined allocation
increases are 44.185–57.168%; normal instructions 22.026–24.683%. All 16 compile
statuses/streams/strictzero/positive counters/C bytes/modes and guards closed.
Empty String also misses old 18900/80M absolutes; strict instructions 89949821.

Approved current-only allocation hard is min(floor(1.58B), B+8400); normal min3
hard min(floor(1.25B), B+11M). Effective allocation caps in table order are
22915/26455/26122/27180, leaving 102/100/102/102 allocations above observations.
Effective normal instruction caps are 54094182/59311873/58702869/60513992,
leaving 137250/111196/128857/94175. These are small measured margins, not future
composition headroom. Empty control-only absolutes become 27300/91M; no other
control absolute changes. Its native shared PRESENCE instruction cap stays 88M.

Original corrected native was 441 PASS/57 FAIL; preOption current 448 PASS/60 FAIL.
Current native uses accepted CWD9b22 and host498/STD91 (env01b8), source41 unchanged.
These functional roles are not compared to old B normal-cost samples.
Final accepted Option+Join on Root8fdb completed 449 PASS/60 FAIL outer cases,
645 semantic-child PASS and one umbrella FAIL: 1155 exact ordered markers.
All 418 positive cost rows have strictbalancedzero/required instructions and
maintained generated C/native sanitizer checks; only 60 allocation limits fail.
All 418 instruction fields PASS. Inner temporary C/reports are not separate dumps.
Accepted Option adds its 67284/150k fixture and changes an existing helper's
allocation 49425→53050/150k; neither creates another resource failure.

The approved amendment changes 49 CURRENT allocation fields across 10 owners, covering
62 shared users including two fully passing namespace cases. Each fixed value is
max(currentcap,ceil((maximum_shared_observed+100)/100)*100), leaving 102–195 counts.
No native instruction or unlisted field changes; no prior allowance is stacked.
Largest present excess is 4096 at record/update/aliases 29096/25000; proposed 29200.
The exact 49-field patch and all users/current values/headroom are retained below.

Feature tests 293 ADD remain; 49 numeric replacements yield 342 ADD/49 DEL under
the approved test-only bound 345 instead of 295. Production 40/+40, fixture 60,
API 25 and plan 100 bounds stay fixed; no callback/coverage deletion or compression.
Phase8, original 64-byte native and current three genuine semantic fault/restores
remain credited. Wrong outputs 38/64/54 bytes each restore to the same 64-byte main.
Current preOption components 3643 PASS; accepted Option components 3644 PASS.
Identity passed 505 pairs/1010 calls (409 emitted-C pairs, 96 matching rejections).
Final components passed 3652; native passed 1155 markers/418 rows, CLI0/stderr0.
Native had 509 outer/645 child/one umbrella PASS; no selfcompile/fixpoint claim.

Evidence: build/bootstrap-evidence/list-string-join-2026-10-19/ contains original
first8, characterization, strict-remaining and native-timeout records; current
functional first20 and publication-observation/execution01 receipt2c2461c7;
accepted-option-composition01/final-native-readiness01/execution01 receiptcce54073;
Final gates: [receipt9b71ad78](/Users/keithphilpott/.codex/worktrees/join-approved-main/blorp/build/join-approved-main/execution01/RECEIPT.json).
All old/current failures, timeout and collector corrections remain immutable.
