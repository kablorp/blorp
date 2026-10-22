# Blorp 2 flat union representation readers

Eight Emit readers now share one private `union_is_boxed` query over the
representation already published by Specialize. This removes seven duplicate
physical classifications. The two ownership-specific readers remain separate; RecordRepresentation, raw verification, storage policy and
existing flat loops are unchanged. No retained carrier, cache or traversal was
introduced.

## Matched self-compilation

The fixed original is `cdfa1bc6009da61415f26b9f812f1dfbf23a6ebc`;
the immediate parent includes reviewed String interpolation on `d9c7471a6`.
Original, parent and candidate were qualified against their producer inputs,
seed, actual Clang and normal/diagnostic roles. The candidate used the pinned
Make route, with one emitted C linked at `-O0`, diagnostics disabled/enabled.
Every role compiled the same frozen original main/library from the same working
directory to the same output path, using one captured environment.

| Metric | Original | Parent | Candidate |
| --- | ---: | ---: | ---: |
| Allocations | 30,998,075 | 30,689,853 | 30,689,853 |
| Minimum retired instructions | 899,473,376,829 | 899,329,922,644 | 899,357,194,721 |

One strict run per role preceded the fixed normal schedule O/P/C/C/P/O/O/P/C.
All strict reports were positive, balanced and leak-free. All twelve actual C
outputs were byte-identical, SHA-256
`f8309136d4a0f53625d2ca4062579874b314adf1e2f649f82074f4fe2b80785a`.
All per-call and batch source/tool/role guards matched; no samples were replaced.

Candidate allocations are unchanged from Parent. Minimum instructions rose 0.00303%, within
overlapping sample ranges; this is effectively flat, with no speedup claim.
Maximum observed RSS rose 1.84% (298,942,464 to 304,431,104 bytes), a supplementary
noisy observation rather than evidence of a retained-memory change. Independent
+3% original allocation and instruction guards passed; earlier gains against
that original are not attributed to this change.

The independent benefit is a small real reduction: production +31/-34, net -3
lines, including the helper and spacing. Tests add/delete zero lines; all
existing assertions remain. Generated C shows a scalar predicate, eight calls
and no new allocation, ARC operation or loop. The query reads a published fact
rather than reconstructing it.

## Validation

Parent and candidate focused Emit suites each passed 25 checks with identical
stdout; the complete candidate Emit selection passed 258 checks. A source-valid
fault that classified boxed unions as inline failed seven named output checks,
while the independent verifier check passed. Restoring the original candidate
bytes returned all eight checks to PASS.

The unchanged authoritative fixpoint passed with byte-identical seed/A/B/C C,
581 fixture contracts preserved (486 successes and 95 expected rejections),
and all 584 e2e cases passing. The composed C SHA-256 is
`18de404e94f2f10be33031ddcd246b1b867296fead0942d2755fc124781988d9`.
All 4,535 component checks passed. Ordinary and ASan/UBSan strict self-compiles
each balanced 31,123,880 allocations/releases with zero leaked bytes and emitted
that same C; the sanitized run had no sanitizer diagnostics. Complete source,
index, environment, tool and role guards remained unchanged throughout.

Broad e2e uses the accepted `record-allocation-debt` policy with instruction
checks disabled: all 117 original debt markers are retained and broad
instructions are unmeasured. The matched allocation/instruction samples above
use actual counters independently of that broad policy.

Commands, exact source/tool/role hashes, original and parent snapshots, initial
rejected proposal, literal source delta, mutation results, generated-C review and
all raw samples are retained under ignored `build/layout-m2-2026-10-21/`.
The matched counter results are in `measurement/SUMMARY.json`; composed landing
gates are under `build/string-integration-2026-10-21/`. The whole-source landing
proof includes both this change and String interpolation; isolated matched M2
measurements above are separate from that integration proof.
