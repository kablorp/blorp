# Ownership-contract collection fast-path pilot (2026-09-27)

Contract graph construction allocated 2,941,302 objects in the preceding
direct profile. Source discovery retains module identities and declaration
surfaces, but not the post-specialization Core ownership flows this graph
needs; the same profile measured `build_env` at only 70,859 allocations.
This pilot therefore targeted per-expression collection bookkeeping, not a
cross-stage fact transfer.

The production change handles variable, inert leaf, and call tasks directly
in `collect_function_contract_equation`, leaving the existing
`ContractCollectionStep` path for other expressions.

## Frozen comparison

- Source base: `99d074858788722249130aba89a4c1ef8082c1f7`; pilot branch
  `codex/perceus-call-cost-pilot` after the measurement-only report commit.
- Input revision: `5a1219af7f9167de08c56df3f2232fc7b15fa743` (`self`).
- Both compilers: FRESH `-O2`, bootstrap `dev-2f1a59c43baa`, Apple clang
  21.0.0. Candidate binary SHA-256:
  `b77bb1f828e3fa1e139ee7364ffb63c03be87b19f2c99672a82e50770c9e9b5c`.
- Baseline: `/tmp/blorp-perceus-pilots-main-self.json`; corrected candidate:
  `/tmp/blorp-perceus-contract-handled-final.json`. Each has three retired-
  instruction samples. Candidate generated C:
  `/tmp/blorp-perceus-contract-handled-final.c`.

| Measure | Baseline | Corrected candidate |
| --- | ---: | ---: |
| Fused ownership/Perceus allocations | 44,108,636 | 43,522,746 |
| Whole-compile allocations | 192,886,046 | 192,325,160 |
| Retired instructions, minimum of three | 149,430,495,211 | 149,146,051,310 |
| Fused checkpoint live objects | 19,982,063 | 19,982,063 |
| Fused checkpoint allocator bytes | 1,740,004,704 | 1,740,004,704 |
| Generated C bytes | 78,679,647 | 78,679,647 |

The emitted C is byte-identical (SHA-256
`2be89ae0e9eed650e84c36937ed8edb30f98975c682bd11ba7199b70fa029485`).
The fused span saves **585,890 allocations (1.33%)**. Total allocations fall
by 560,886; a separate 25,004-allocation rise in the discovery checkpoint
between the comparison binaries is not attributed to this Core-only change.
Instructions improve by 284,443,901 (0.19%) using the minimum samples; that
is supporting evidence, not a wall-time claim. Live objects and allocator
bytes also match the baseline at artifact construction.

An earlier version used `continue` inside a nested match. Its generated C
skipped outer `expr`/`demand` releases, and the fused checkpoint retained
546,893 extra live objects despite fewer allocations. That version was
rejected; its raw result is
`/tmp/blorp-perceus-contract-call-fastpath.json`. The corrected code uses a
handled flag so all paths reach common cleanup; generated-C inspection and
identical live-object counts check this ownership boundary.

The corrected source passed the focused Perceus suite (390/390),
`scripts/compiler-check --changed --base main` including Core sanitizer
(2,566/2,566), and the codegen audit (221/221). Gate summaries are retained
at `/tmp/blorp-perceus-final-focused.log`,
`/tmp/blorp-perceus-final-check.1qG8b6`, and
`/tmp/blorp-perceus-final-codegen.OwuGTG`. This is a pilot branch result;
it has not been merged or pushed.
