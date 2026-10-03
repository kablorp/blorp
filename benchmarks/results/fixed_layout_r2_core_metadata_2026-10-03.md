# R2 Core value-record metadata checkpoint (2026-10-03)

This behavior-preserving prerequisite carries `LegacyStruct` versus
`FixedRecord` into Core and marks each currently accepted inline field as
trivial. It does **not** admit managed fields or change backend/Perceus behavior.
The measured result supports correctness and generated-C identity, not a
compiler speedup.

## Provenance and method

- Baseline source: main `e855d3a6f12ac1cfba4fd67e2dbf001ef8e77282`;
  its compiler/standard-library trees match the candidate base
  `8a69383e347874506bce2bf85f752f3193a3471f` (intervening R0 changes
  were benchmark diagnostics/results and a test). Candidate: dirty
  `8a69383e3478` with production diff
  SHA-256 `3f798bd7e256e2556d13a540f8ddfa48dba8fd6d27b2feaecfdacdd9def671f3`.
- Both existing self-built compiler/diagnostic pairs used Apple clang 21 and
  `cli=-O2 runtime=-O2`. Normal binary SHA-256: baseline
  `39e843fd22b6f451800c19af56991758399cd31fd45be05b691f0c8389e5c432`,
  candidate `01df841178349872709b0bb0904ced9d26a16a0e706abc140fb1b7de89a2b0f6`.
  Diagnostic binary SHA-256: baseline
  `14749e00e3a8c16fbdeb0c8abb489f4fe4e5c93fa8c4ec740c70d8262ebe921a`,
  candidate `77aa8e0897fc4dba3d9047efa7f8860043950fe9d9b7a150a5752234c4c0f6c7`.
- Both compile the same frozen `8a69383e347874506bce2bf85f752f3193a3471f`
  input snapshot. The controlled pair ran strictly sequentially from the
  **same candidate-worktree cwd**, with explicit binary paths,
  `--input-dir`, `--samples 5`, `--skip-build-check`, and
  `--require-identical` for the candidate. Raw records are
  [baseline](fixed_layout_r2_core_metadata_2026-10-03_baseline.json) and
  [candidate](fixed_layout_r2_core_metadata_2026-10-03_candidate.json); raw
  logs and emitted C are retained at
  `/tmp/blorp-r2-prep-common-cwd-perf-qHveIY/`.

## Measurement result

The first paired measurement used different working directories (main for
baseline, candidate worktree for candidate). It reported 213,921,411 versus
213,927,711 allocations, a candidate increase of 6,300, all within source
discovery. That comparison is **cwd-confounded**: source discovery consults
the working directory even with absolute source and standard-library paths.
The first pair's generated C nevertheless matched byte-for-byte at
79,826,333 bytes, SHA-256
`d28382ecd9eafbd21dd7bc05b51acd013a9f3e2f6d0f653ec7ce6efbc5c18fd0`.
Raw first-pair records remain at `/tmp/blorp-r2-prep-perf-LGa2r7/`; its
instruction minimums were 203,611,738,672 and 204,039,572,216, but are not
used for attribution.

The controlled common-cwd pair reports **214,097,076 allocations for each
compiler**, with equal allocation deltas at every phase checkpoint. A separate
same-cwd diagnostic replay also matched at discovery start (667 allocations,
23 releases, 644 live objects) and discovery complete (7,926,591 allocations,
5,756,107 releases, 2,170,484 live objects). This removes the apparent
allocation regression. Both controlled outputs are byte-identical at
79,970,995 bytes, SHA-256
`3635dd8223093db52be88afd50effc2d20f883f02696297ddb8ccc633b91ac60`.
The harness canonicalized the frozen input path to `/private/var/...` in the
second pair; cross-pair C hashes/sizes are therefore not an identity oracle.
Identity holds *within* each pair.

| Retired instructions, five samples | Baseline | Candidate |
| --- | ---: | ---: |
| 1 | 204,214,385,747 | 204,488,682,158 |
| 2 | 204,262,635,467 | 204,745,714,011 |
| 3 | 204,291,257,586 | 204,846,385,293 |
| 4 | 204,236,204,719 | 204,578,135,337 |
| 5 | 204,769,017,971 | 204,779,411,075 |
| Minimum | 204,214,385,747 | 204,488,682,158 |

The candidate minimum is 0.13% higher, but the sample ranges overlap. This
small upward trend is an inconclusive potential compiler-execution cost, not
a speed claim or demonstrated slowdown. No latency claim is made from wall
time. Generated-C identity, exact allocation parity, Core tests, codegen
audit, sanitizer-selected compiler check, and stage-2/3 C fixpoint are the
acceptance evidence for this metadata-only slice.
