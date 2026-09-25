# Reuse the emission layout type index

The candidate passes the existing `CoreSpecializeLayout` to C record
classification. This removes the second `build_layout_type_index(program)`
inside emission without changing the classifier's policy. The focused
`test_core_c_type_layout.brp` suite passed 21/21 with a fresh local build.

The -2,727 allocation result below is an isolated pre-rebase comparison
against `f0ea407c`. The rebased branch atop `71876d39` was not remeasured
against that current parent. This report makes no matched current-parent
performance claim.

## Provenance and comparison boundary

- Source base and frozen input: `f0ea407c9eefcaa1a884a990b4b2b867ac98d6b8`.
  Candidate source was the uncommitted diff from that base; its
  `git diff --binary | shasum -a 256` was
  `c40e280a258e59b95b7c72a2335c2c73ade9a63027cc3392eb2ea2b9b8a45d78`.
- Both executables were stage-2 compilers built with
  `BLORP_CLI_C_OPTIMIZATION=-O2`, using Apple clang 21.0.0 and the same
  bootstrap pin. The clean baseline stage-2 SHA-256 was
  `7605683a943b78808bdc601667a7ca12c6cbc12a136f7143a06eee63467eeb8e`
  (built by stage-1 SHA `a41fde22463ae48ab645aa26d57799cb1d840c6ea1699196777cc4e7b64aa47d`).
  The candidate stage-2 SHA-256 was
  `caac70c8670afda00cc626c6e7fea08e0658b7118e6a97a7585b7913f3698303`
  (built by fresh stage-1 SHA `487a92cb21acc2bb08519e18f980d8bb22824f71c93f4bc73124c4c5b762d81b`).
- The final small comparison used one copy of
  `benchmarks/self_compile_measure` and one working directory (the candidate
  checkout) for both compiler paths. Each command set
  `BLORP_CLI_C_OPTIMIZATION=-O2`, `--input-rev f0ea407c9eefcaa1a884a990b4b2b867ac98d6b8`,
  `--program small --samples 3 --skip-build-check`, and an absolute
  `--compiler` path; the candidate command added `--baseline` and
  `--require-identical`. The self baseline was repeated from that same
  working directory against the same frozen input before comparison with
  the candidate self run. The self runs have two instruction samples each.
  The harness labels an explicit `--compiler` invocation as stage 1 in
  the small JSON, even though the executable path, SHA, and `compiled_by:
  self-f0ea407c9eef` identify the prebuilt stage-2 compiler.

The corrected small commands ran with `pwd -P` =
`/Users/keithphilpott/.codex/worktrees/emitter-layout-index-reuse`.
That checkout's `benchmarks/self_compile_measure` SHA-256 was
`4f430b7105c338040b1e8c9e75b294f8d9081745760381ad620c722c572e56b9`;
its `benchmarks/self_compile/small.brp` SHA-256 was
`6a67158fb09aac383ec40e77e5c5b1d64fd068b19edf6e2596a6f25060d9cc93`.
From that working directory, the exact invocations were:

```bash
BLORP_CLI_C_OPTIMIZATION=-O2 benchmarks/self_compile_measure --compiler /private/tmp/blorp-layout-index-baseline.iNvb7z/repo/bin/blorp-stage2 --skip-build-check --program small --samples 3 --input-rev f0ea407c9eefcaa1a884a990b4b2b867ac98d6b8 --label emitter-layout-base-small-one-harness --output /tmp/blorp-emitter-layout-index-reuse.eN1Zbx/base-small-one-harness.json --keep-output /tmp/blorp-emitter-layout-index-reuse.eN1Zbx/base-small-one-harness.c
BLORP_CLI_C_OPTIMIZATION=-O2 benchmarks/self_compile_measure --compiler /Users/keithphilpott/.codex/worktrees/emitter-layout-index-reuse/bin/blorp-stage2 --skip-build-check --program small --samples 3 --input-rev f0ea407c9eefcaa1a884a990b4b2b867ac98d6b8 --label emitter-layout-candidate-small-one-harness --baseline /tmp/blorp-emitter-layout-index-reuse.eN1Zbx/base-small-one-harness.json --output /tmp/blorp-emitter-layout-index-reuse.eN1Zbx/candidate-small-one-harness.json --keep-output /tmp/blorp-emitter-layout-index-reuse.eN1Zbx/candidate-small-one-harness.c --require-identical
```

| Workload and metric | Baseline | Candidate | Difference |
| --- | ---: | ---: | ---: |
| Small source discovery allocations | 178,622 | 178,622 | 0 |
| Small backend emission allocations | 12,976 | 12,966 | -10 |
| Small total allocations | 1,616,573 | 1,616,563 | -10 |
| Small retired instructions, minimum | 1,300,127,541 | 1,299,497,159 | -630,382 (-0.05%) |
| Small peak RSS, bytes | 35,766,272 | 35,569,664 | -196,608 |
| Self source discovery allocations | 8,485,647 | 8,485,647 | 0 |
| Self backend emission allocations | 19,422,826 | 19,420,099 | -2,727 |
| Self total allocations | 212,654,418 | 212,651,691 | -2,727 |
| Self retired instructions, minimum | 166,030,985,546 | 166,084,321,422 | +53,335,876 (+0.03%) |
| Self peak RSS, bytes | 2,130,526,208 | 2,136,621,056 | +6,094,848 |

All pre-backend allocation checkpoints matched in the corrected comparisons.
Generated C was byte-identical: the small program was 42,475 bytes with
SHA-256 `b14e002cf83bd89ace4c862a0cf0137f36b21cde683a993671641f0c2e3b096a`;
self was 83,566,156 bytes with SHA-256
`ee5e02f563a5b272fb9076ff0fccd2084e14a2dc2683556178dc11895735871f`.
The retired-instruction sample ranges overlap (small baseline
1,300,127,541–1,306,057,471, candidate 1,299,497,159–1,300,181,083;
self baseline 166,030,985,546–166,185,838,783, candidate
166,084,321,422–166,100,219,808), so these samples do not establish an
instruction improvement. RSS is a noisy secondary signal. No wall-time
claim is made.

An initial cross-checkout comparison showed extra source-discovery allocations
in the candidate, but it changed the harness working directory and, for
`--program small`, the absolute source path. The controlled comparisons
above removed those differences; the earlier totals are not acceptance
evidence. The harness JSON does not record cwd, so the command boundary is
documented here.

Raw measurements:

- [small baseline](emitter_layout_index_reuse_2026-09-25_base_small.json) and
  [small candidate](emitter_layout_index_reuse_2026-09-25_candidate_small.json)
- [self baseline](emitter_layout_index_reuse_2026-09-25_base_self.json) and
  [self candidate](emitter_layout_index_reuse_2026-09-25_candidate_self.json)

The exact generated C copies are retained for this review at
`/tmp/blorp-emitter-layout-index-reuse.eN1Zbx/` as
`base-small-one-harness.c`, `candidate-small-one-harness.c`,
`base-self.c`, and `candidate-self.c`; the hashes above and the JSONs
remain the durable identity record if those temporary copies are removed.
