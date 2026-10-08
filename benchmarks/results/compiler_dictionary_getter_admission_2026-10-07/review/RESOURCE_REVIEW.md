# Independent dictionary resource acceptance review

**PASS / APPROVE: 0 blockers, 0 should-fix, 0 nits.** Acceptance is limited to
matched self/small enabling cost and whole-output identity. Source correctness,
test-runner gates and final documentation are separate reviewed evidence.

Reviewer: `/root/resolution_design_review`. This was read-only verification of
completed records and actual retained bytes; no native jobs, repository changes,
harness/controller changes, or raw metric edits were performed.

## Reviewed authority and actual-byte checks

Packet: `/tmp/blorp-dict-get-reader-resource`.
Base/input revision: `2ee201fb5cb74e8a7b4f3d068a143d8d71dd2bad`.
Approved ordered source/test/allowlist patch:
`309c7f9089401bdf5b503d6546412893aeee37f5dc21f5312c64d0c3998824db`.

- Controller SHA256
  `b4af2609415b87f1a39e357c6393f395f199c16d9f6b43dfb30e4e3ae6b8b7bd`.
- Candidate configuration SHA256
  `f3e2bd9831420df4f5807eab7fd93bea85b48267cef5c861c8c0f23c0dcbf09d`.
- Baseline capture proof SHA256
  `39d6592b85309ce79101be6ce5082c38d0f920f859b58aeab8183ef818381e61`.
- Final `comparison/COMPARISON_COMPLETE.json` SHA256
  `9ceca5793b737e484b4bec628a5211e3b78f6e7c375525a47c739931bb3d6553`.

Independent Python checks recomputed all 18 sealed baseline and 27 final
comparison file hashes against actual bytes. They checked the four raw JSON/C
measurement pins and `measurement-pins.json`, not just the summaries. The source
archive SHA `60b8b9bd76706c590c5143f44e54e7259de53a171b96dfcb2bee423f250a2834`
matches both retained `production.tar` and immutable committed Git objects.
Frozen archive/tree authority was revalidated, with canonical paths and all
3,871 tracked files. The same local small source retains SHA
`6a67158fb09aac383ec40e77e5c5b1d64fd068b19edf6e2596a6f25060d9cc93`.
Current candidate full tracked/untracked/source/generated-input pins match the
configuration, including FRESH stage1 generator
`a17a6ed3cdfcac11df20e459bea1b7235a57768194d73551a78c0a76964513ab`.
Retained candidate FRESH-before/FRESH-after logs and sealed baseline construction
FRESH authority are present; no live pre-edit baseline freshness was assumed.

Actual stage2 binary pairs match their construction proofs and every raw record:

| Pair | SHA256 |
| --- | --- |
| Baseline normal | `c528f18fb491099061ca398436c4b0720a7583723ccdbc19067cab03670249e0` |
| Baseline diagnostic | `3ad79116cf014e21a780c116fa68ff34a8d380d583a0f20d59bfd7416ce5186b` |
| Candidate normal | `0de63d8215e2600a6c4123fc97b554189f066a64a0918b8e0fe6a2db6d361cd2` |
| Candidate diagnostic | `5950a64a26fd267486193e331445e2704f9c02599104b762b908460aa8fd1a62` |

Normal/diagnostic modes are 0/1; both use CLI/runtime O2, Apple clang 21.0.0
(`clang-2100.3.34.2`), aarch64-apple-darwin, split 8 and matching version fields.
Outside-repository raw records still report unknown checkout freshness and
incidental `compiler_stage: 1`; retained body/object/generator and pair
construction prove actual stage2. Those raw metadata fields were not rewritten.

## Independent metric and identity recomputation

Exactly three positive normal instruction samples and paired diagnostic
allocation totals were verified for each workload/compiler. Raw totals also
match the final diagnostic checkpoint. Each summary was recomputed from the raw
records. Every ceiling passed exact integer arithmetic `after * 200 <= before * 201`.

| Workload/metric | Baseline | Candidate | Absolute delta | Percent delta |
| --- | ---: | ---: | ---: | ---: |
| Self allocations | 245,063,861 | 245,078,157 | +14,296 | +0.005833581% |
| Self minimum instructions | 229,266,550,292 | 229,384,176,098 | +117,625,806 | +0.051305263% |
| Small allocations | 1,689,044 | 1,689,099 | +55 | +0.003256280% |
| Small minimum instructions | 1,598,242,714 | 1,597,713,063 | -529,651 | -0.033139585% |

Self raw samples:

- Baseline: `[229358443838, 229266550292, 229513175201]`; spread 0.107571257% of minimum.
- Candidate: `[229514439444, 230119776695, 229384176098]`; spread 0.320684979% of minimum.

Small raw samples:

- Baseline: `[1628757591, 1598242714, 1610811785]`; spread 1.909276778% of minimum.
- Candidate: `[1601355205, 1597713063, 1598468789]`; spread 0.227959706% of minimum.

Retained whole-C files match raw sizes/hashes and each other:

- Self: 83,981,861 bytes; SHA256
  `9f304f4b6c1b0911ff95bc9df3cbc3c6346bb6811b6cf69cae742861bd352e0c`.
- Small: 40,512 bytes; SHA256
  `8316ceeb6e78c5e7d6431c33d1a22b0b9ff9bb59b2ecd603fbc38b8a5b618abb`.

All nine retained controller commands exited 0. The four measurements use the
standard harness, three samples and the same frozen input; both candidate
commands include `--baseline` and `--require-identical`. No threshold/toolchain
override appears. The final proof confirms all four raw records/saved C were
reread after later native commands and budgets recomputed from pinned bytes.

## Caveats and verdict

Observed external native PIDs were 137/87 for baseline/candidate self and 5/7 for
baseline/candidate small. Repository minimum-of-runs policy governs acceptance;
background activity is disclosed rather than rejected. In particular, the small
baseline spread is larger than the candidate delta. No speed improvement,
quiet-window or wall-time claim follows from these records. The selector's
additional allocation cost is real and remains below the unchanged ceiling.

The coordinator reports batch exit 0, slot released and no owned jobs remaining.
This reviewer started no native jobs. Recommend accepting the dictionary reader
cut within the recorded resource/identity scope. Do not extend this verdict to
unmeasured workloads, historical OptionVoid behavior, the proposed next cut, or
the wider runtime/carrier architecture.
