# Dictionary getter reader: review record

Review owner: `/root/resolution_design_review`. This record preserves bounded
source/caller proof and independent resource-controller review. It is not a
measurement result or final acceptance record.

## Source boundary

Base: `2ee201fb5cb74e8a7b4f3d068a143d8d71dd2bad`.
Ordered source/test/allowlist patch SHA256:
`309c7f9089401bdf5b503d6546412893aeee37f5dc21f5312c64d0c3998824db`.

Scope is one production module, its owning collection suite, and one deleted
magic-spelling allowlist row. The private `CollectionErasedSlots` policy is
classified once, then consumed by both the boxing guard and slot loop. All six
boxing callers supply the policy: generic dictionary getter, set add, dictionary
insert, shared fold branch, fallible-stream fold, and general fallback. The
fallback requires two arguments and exact admission by the existing Option
runtime-name selector; it preserves pre-specialized nullable-key boxing. There
is no new IR schema, duplicated getter registry, or spelling decoder in the loop.
Fresh-key map-before-box / release-after-lookup logic and the generic producer's
existing allocation condition remain unchanged.

The detailed implementation/caller proof and exact candidate diff are retained
in `/tmp/blorp-dict-get-reader-implementation/HANDOFF.md`, `candidate.patch`, and
`CANDIDATE_READY.json`. This worker implemented the source change; its source
proof is a self-audit, not an independent approval. Independent code review was
performed by `/root/resolution_semantics_audit`, which reported **APPROVE, zero
findings** for the exact patch above, including six callers, slot-index authority,
shared Option admission, fourteen primitive getter names, aliases, and fresh-key
ownership. Root received that verdict directly.

Corrected independent fail-before evidence is 35 total, 32 pass and 3 intended
failures; the nullable/pre-specialized boxing and allocating Int128 ownership
controls pass at the base. The initial Float ownership test used an incorrect
premise and is preserved separately; FloatBox does not allocate. After TDD,
only the new ownership test's binder comparisons were strengthened to existing
`core_var_equal` (name and id). Test-runner candidate and resource evidence are
separate authorities.

Cost remains measured rather than inferred: the existing Option selector can
construct the nullable name even for non-Option two-argument fallback calls.
Known historical OptionVoid selector/runtime uncertainty remains outside this
cut, with its producer behavior preserved.

## Independent resource-controller verdict

**READY / APPROVE: 0 blockers, 0 should-fix, 0 nits** for these frozen files:

- `/tmp/blorp-dict-get-reader-resource/compare_resources.py` SHA256
  `b4af2609415b87f1a39e357c6393f395f199c16d9f6b43dfb30e4e3ae6b8b7bd`.
- `/tmp/blorp-dict-get-reader-resource/candidate.json` SHA256
  `f3e2bd9831420df4f5807eab7fd93bea85b48267cef5c861c8c0f23c0dcbf09d`.

The first template (`071e36c2...`) had one should-fix: newly validated measurement
JSON/C could change during later commands without a final metric reconciliation.
The controller owner repaired it without editing raw measured data. Validation
now hashes the exact parsed JSON bytes and saved C; immediate pinning rejects
the validation-to-pin gap; every later command checks all earlier pins; final
acceptance rereads all four records/C outputs and recomputes output identity and
both budgets from the still-pinned bytes before sealing the packet.

Read-only commands run by this reviewer:

```sh
python3 /tmp/blorp-dict-get-reader-resource/compare_resources.py --check-template
```

Exit 0: sealed baseline and canonical frozen-input authority validated. An
additional `python3 -B` import invoked `verify_baseline()` and `verify_state()`
with the exact controller/configuration hashes above; exit 0 verified all 18
sealed baseline payloads, approved boundary patch `309c7f...`, current generator
`a17a6ed3cdfcac11df20e459bea1b7235a57768194d73551a78c0a76964513ab`, generated
inputs, full tracked patch, and untracked document/test pins. At that check,
the comparison output directory did not exist.

Baseline authority is the immutable pre-edit source archive, construction proof,
captured generator/body object and normal/diagnostic pair. It does not assume
the edited live tree still has baseline freshness. Canonical input paths,
positive integer metrics, three normal samples, paired diagnostic allocation
accounting, matched O2 toolchains, whole-C identity and exact integer +0.5%
ceilings remain enforced through the standard harness. Outside-repository raw
stage/freshness metadata is retained unchanged and disclosed; captured source
and binary construction establish actual stage2 authority. Background work is
logged under repository minimum-of-runs policy; there is no quiet-window,
wall-time or speed claim.

No native commands, repository edits, harness edits, or raw metric edits were
performed by this reviewer. Candidate gates, native slot release, coordinator
GO, actual measurements and final acceptance remain separate requirements.
