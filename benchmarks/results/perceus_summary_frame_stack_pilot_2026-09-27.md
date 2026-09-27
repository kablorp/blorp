# Perceus ownership-summary frame-stack pilot (2026-09-27)

The linear ownership-summary walk used a recursive union for pending frames.
Every push allocated a union node. The earlier self-compile attribution counted
4,339,854 such pushes, 6.92% of Perceus-pass allocations on that revision
(`perceus_engine_attribution_2026-09-22.md`). That was an upper bound, not a
predicted net saving.

This pilot changes only the private stack in `perceus/uses.brp`. A locally
owned `List[PerceusOwnershipSummaryFrame]` stores scalar `struct` frames
inline, reusing popped slots; a separate list holds the deferred `CoreExpr`
values needed by let-RHS and sequence-first frames. The public
`OwnershipUseSummary` and ownership decisions are unchanged. Generated C
shows `BLORP_LIST_STORAGE_INLINE` for the frame list and a direct local push
without retaining the list. The narrow Perceus suite passes 391/391, including
a mixed nested let/sequence case that reuses popped slots.

## Frozen self-compile comparison

- Input revision: `18d682384d125209582d3a5ed78f19fb7ae7b3bb`.
- Baseline: main `99b4eedf9682`; candidate: `661fa4cc9015` after rebasing
  onto that main. Both compiler builds were FRESH `-O2`, bootstrap
  `dev-35040738956f`, Apple clang 21.0.0, eight-way C split.
- Command: `BLORP_CLI_C_OPTIMIZATION=-O2 benchmarks/self_compile_measure`
  with `--input-rev 18d682384d12 --samples 3`; candidate used
  `--baseline /private/tmp/blorp-summary-main99b-self.json --require-identical`.
- Raw JSON: `/private/tmp/blorp-summary-main99b-self.json` and
  `/private/tmp/blorp-summary-candidate99b-self.json`.

| Measure | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Fused ownership/Perceus allocations | 43,439,983 | 40,437,215 | -3,002,768 (-6.91%) |
| Whole-compile allocations | 190,861,824 | 187,894,776 | -2,967,048 (-1.55%) |
| Retired instructions, minimum of three | 148,578,576,392 | 148,242,177,989 | -0.23% |
| Sampled peak RSS, bytes | 2,031,321,088 | 2,030,223,360 | -0.05% |

All three candidate instruction samples were below all three baseline
samples. Generated C was byte-identical: 78,694,485 bytes, SHA-256
`8408a30be0025931c05b78f56d29fafc1133d42e3166ed31d4343752a923e81a`.
The candidate incurred 35,720 more source-discovery allocations, so the net
whole-compile saving is smaller than the Perceus saving. Wall time is not used
as acceptance evidence. The harness warns that the frozen input predates a
backend change on both arms; this stage-1 comparison makes no claim about that
backend change. The candidate differs from main only in the Perceus walk, its
test, and this report.

The small-program guard used the same main/candidate pair, bootstrap,
optimization level, and frozen input. It emitted byte-identical C (40,918
bytes, SHA-256
`6f2a9556f4ff0baaf899211a2b4cb197b27958885e89016df0131287607551ae`).
Its ownership/Perceus allocations fell from 17,349 to 16,953; whole-compile
allocations fell from 1,340,748 to 1,340,569. Minimum retired instructions
changed from 1,081,799,777 to 1,082,525,562 (+0.07%), so there is no
small-program speed claim. Raw JSON is at
`/private/tmp/blorp-summary-{main,candidate}99b-small.json`.

The recovery-equipped candidate passed the focused Perceus suite (391/391),
`scripts/compiler-check --changed --base main` (2,569/2,569), full
`compiler-blorp` (5,173/5,173), `leak` (977/977), explicit Core ASan+UBSan
(2,178/2,178), and the direct codegen audit (221/221). The serialized gate
logs are in `/private/tmp/blorp-summary-final.VaKhBL/`.

## Review boundary

The typed frame list and deferred-expression list have coupled cursors. The
walk increments a cursor only after a successful push and pops frames in LIFO
order. Their indexed reads are therefore in bounds under the local invariant.
If an impossible `List.get` failure does occur, the walk discards its partial
result and recomputes from the original expression with the former iterative
union-stack algorithm. The recovery function is byte-for-byte the former
binding walk after renaming. It is private and cold, preserving the pure
summary API without reporting potentially unsafe partial ownership facts.
This duplicates a small, correctness-sensitive algorithm; it should remain
only until the language offers a checked local stack operation or an explicit
internal-error channel at this boundary.
