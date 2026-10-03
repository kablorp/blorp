# R2 inline-ownership policy checkpoint (2026-10-03)

This prerequisite adds declaration-derived Core ownership classification and
rejects owned-inline Core before production Perceus or any direct, prepared,
or split C-emitter entry. It does not admit managed fixed-record fields in
source, implement field-wise ownership, or change Perceus/backend release
semantics. This is a correctness checkpoint, not a speed claim.

## Provenance and method

- Baseline: clean main `831195b12c18ce06573f194c93dbad904985cd76` at
  `/Users/keithphilpott/CLionProjects/blorp`; candidate: dirty branch at the
  same HEAD. Both stage-1 `bin/blorp` binaries reported `FRESH` before their
  respective stage-2 builds. The measured six-file source/test diff (before
  this documentation) has SHA-256
  `d306752025ea012ff5d8b41cdfb1be7b4f75a2c9739b592aede6b269b8b6ad92`.
- Both stage-2 normal/diagnostic pairs were built sequentially with Apple
  clang 21 and `BLORP_CLI_C_OPTIMIZATION=-O2`; their binary fingerprints say
  `cli=-O2 runtime=-O2`. Baseline normal/diagnostic SHA-256:
  `42b5005ffe33b2889a3edfd34d9704ed946d2ce4526aea6d975b52f09e98cf25` /
  `61018d26d08d8fa32eaa1c2a73a1edaa634684594269212942fe19c45addf156`.
  Candidate normal/diagnostic SHA-256:
  `beb6332adb88de9bf6ec0931c1ed86801a470d4cd5607e059983cc8d1ef7d361` /
  `276f12234e5117b57565e331c432972e12b809f27ccef742d1d98116774ad162`.
- Both measurements ran sequentially from the **same cwd**,
  `/Users/keithphilpott/CLionProjects/blorp`, with explicit binary paths,
  `--input-dir`, `--skip-build-check`, and five samples. The input was one
  frozen snapshot of `831195b12c18ce06573f194c93dbad904985cd76` at
  `/var/folders/m7/zszgqft538nfx_qr1kmc7dlc0000gn/T/blorp-perf-input/831195b12c18ce06573f194c93dbad904985cd76`.
  Candidate comparison used `--require-identical`.
- Raw records: [baseline](fixed_layout_r2_inline_policy_2026-10-03_baseline.json)
  and [candidate](fixed_layout_r2_inline_policy_2026-10-03_candidate.json).
  Build and measurement logs, generated stage-1 C, and binaries remain under
  `/tmp/blorp-r2-owned-pilot-perf/{base,candidate}/`; the -O2 fixpoint log
  and stage outputs remain under `/tmp/blorp-r2-owned-pilot-fixpoint*`.
  The harness JSON says `compiler_rev: unknown` and
  `compiler_build_status: skipped` because binaries are in `/tmp`; commit,
  dirty state, FRESH stage-1 checks, binary hashes, and build logs provide
  provenance. Its `c_optimization: -O0 (default)` is ambient harness metadata,
  not the stage-2 binary optimization setting; the binary fingerprints and
  explicit build environment are -O2. Raw JSON is preserved unchanged.

## Result

The frozen self-compile emitted **byte-identical C**: 79,977,645 bytes,
SHA-256 `7759f5334e651dad0fd413eccbdc05cdba05240dc8f704322b774becaca9b05e`.
Candidate stage-1 compiler C differs from baseline as expected for compiler
source changes; candidate stage-1, stage-2, and stage-3 emissions reached a
fixpoint at SHA-256
`4b4df1bec2047ee4dfb39bc7ad1995bfee6c9ba0089b3d36b0a4ad64bc28c6ec`.

Diagnostic total allocations were **214,111,637 baseline** and
**214,111,641 candidate** (+4). The only phase deltas were +2 at
`pass_ownership_perceus_fused_complete` and +2 at
`backend_emission_complete`, the two new validation boundaries. Empty-index
validation is a plausible explanation, not a proved allocation attribution.
The +4 was accepted as negligible for this correctness-only prerequisite.

| Retired instructions, five samples | Baseline | Candidate |
| --- | ---: | ---: |
| 1 | 204,386,376,119 | 204,509,630,162 |
| 2 | 204,513,570,625 | 204,825,401,866 |
| 3 | 204,372,534,820 | 204,376,078,123 |
| 4 | 204,159,730,110 | 204,807,262,549 |
| 5 | 204,108,886,558 | 204,840,534,439 |
| Minimum | 204,108,886,558 | 204,376,078,123 |

The instruction ranges overlap. The candidate trends upward in this pair,
but it does not establish a latency effect or justify a speed claim.
Correctness gates: `compiler-check --changed` 3,032/3,032 including the
selected sanitizer and generated-C audit; compiler-blorp 6,345/6,345;
compiler-new 343/343; parity 3,389/3,389; hygiene; and stage-2/3 C
fixpoint. Retained gate transcripts are at
`/tmp/blorp-r2-owned-pilot-{compiler-check,broad,hygiene,fixpoint}.log`.
