# Pre-existing late-invariant loop layout prerequisite

This is a test-blocking prerequisite, not an enum-migration or Eq/Hash regression.
The final ee239 eleven-owner harness stopped at native C compilation: five scalar
`uint8_t` arguments were passed where a CoreExpr pointer was required. Zero
assertions executed. Original evidence is in
`/tmp/blorp-migration-final.UzKXlz/narrow/{metadata.json,stderr.log}`.

## Isolation and baseline

The direct late-invariant owner reproduces the same five errors. The pinned
8999 compiler against clean cbff unmigrated staging source and its own Std also
reproduces them. Early-invariants alone passes23; the first-five owner bundle
passes441. No combined-harness-only failure is inferred.

Retained packet: `/tmp/fieldless-override-probes.SHeBht`.
`late-owner.core.json` maps def4583 / projected `brp_1bV` to
`checkpoint_iterable_loop_violations(CoreExpr iterable, CoreExpr body)`.
The original combined `brp_37N` corresponds to def12015; projection uses the
documented base62 definition identity, not guessed source spellings.

The source OR-pattern bound eight different loop record types under one `loop`
name. Emitted branches used the first record's iterable/body positions f1/f2.
Five release-policy records instead store the body at f3; List and Tensor store
iterable/body at f2/f4. A second resource-exit consumer likewise read f1 rather
than f2 for List/Tensor. This could silently select another pointer-shaped field.

An independent tiny `Plain{value:String}` / `Padded{padding:Bool,value:String}`
OR-pattern probe is retained as `or-pattern-record-layout.brp`. Both pinned and
final compilers emit byte-identical incorrect C: the Padded branch reads f0 as
String instead of f1. C SHA
`e1fe18f43bca387417ef573159b0ea2ea6956cab115023ec67d26283a0f41402`.
The unsafe tiny probe was not executed.

## Bounded repair

Only `late_invariants.brp` changes: the two heterogeneous OR-pattern consumers
become sixteen distinct, correctly typed variant arms. Existing helpers and
rules are preserved. Checkpoints inspect iterable and body separately; resource
scope exit detection inspects iterable only, allowing body-local loop exits.
No parser, inference, general pattern, ownership, backend or schema repair.
The broader public OR-pattern field-identity defect remains deferred.

The owning regression explicitly constructs all eight loop records with their
layout/release-policy fields. Three matrix cases cover all eight layouts: body-entry
checkpoints accepted versus iterable checkpoints rejected, iterable resource
exits rejected, and body-local resource exits accepted. Original RED is native
setup failure with zero assertions, not a test assertion failure.

Using ee239 as the source-test host (current-source STALE until rebuilding):
late owner48/48 passes; the exact original eleven-owner bundle716/716 passes,
empty stderr. Its prior713 potential assertions never executed. JSON141 is
included after separately reviewed formatting-only cleanup; no assertion changed.

Corrected retained C now uses f1/f2 for Channel, f2/f4 for List/Tensor, f1/f3 for
the other five checkpoint branches. Resource traversal reads only iterable at
f2 for List/Tensor and f1 elsewhere. C SHA
`89295fb5786e084f7ecfc6c4880541978ac2751c186c6d939b44b4c39ffda29a`;
Core SHA `ff2fc75935047733422ec0edbaf0bfa39faf144776cd50f719d941ee747fc563`.
The temporary root driver was removed after retaining its exact source text.

Frozen two-owner diff `late-consumer-fix.diff` SHA
`556ef82cdae13366cbc84f1f274752b18fee22ab219cf149cc69e12ac294f776`.
Production SHA `5b6209ef3276da5eea58ded2c708633819749463172cf5cbec424a8998273288`;
test SHA `fb2eace9f919484001ab4f73492cd12ac92265cca1803ecbbc15a45e5800da06`.
No staging mutation, release/pin, commit or broader gate acceptance claim.
Independent review and the rebuilt-host gate epoch are recorded by the coordinator.

## Rebuilt-host handoff

Independent review approved the frozen source/test delta with zero blockers or
should-fixes; two optional fixture-style nits were deferred without changing the
reviewed freeze. The authorized O2 make with the same frozen2ebad override
completed successfully, visibly compiling split8 and linking. Build status was
FRESH; compiler/Std manifests were identical before/after, SHA
`951d3ac88ceab1746f954130224b449dbceecf6d58a32893cc1492ee80aeba29`.
Eleven-owner production diff SHA
`c1225c36388ab24d2f9f44182e7557c3e12f0f18729b2bee2894a55f99ac0a6e`.

Actual binary remained byte-identical
`ee23938ff1411e093f1de268b230a202ef6623759b990fb8cf1427750de17823`;
this is not presented as a distinct new executable. Rebuilt CLI C changed to
`dcaf62600a0584249a5a177a611b9c3088a9711744f0c4c6e37932c08b62f422`.
No speculative cause or performance conclusion is assigned to binary equality.
The direct owner Core/C changed as documented above, and source-host48/716
proofs preceded the rebuild. Final independent gates remain a separate epoch.
All worker compiled children ended and the token was released immediately at
this handoff; no further worker jobs, commit or publication.
