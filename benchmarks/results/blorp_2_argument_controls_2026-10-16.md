# Lift control blocks out of compiler call arguments

Move 16 argument matches into explicitly typed preceding bindings at the same
execution point. Earlier String prefixes still evaluate before their match;
branches, contextual types, identities and ownership decisions are unchanged.
The reserved compiler_source() call remains in its original error branch.
This removes a compiler-source dependency on general expression-child control;
it adds no input-language feature or compiler phase.

Production: **110 added / 132 deleted / -22 net**, four modules, within 250 added /
+60 net. Tests, fixtures and libraries are unchanged. Combined with construction
migration: **368 added / 332 deleted / +36 net** from reset. Root and an
independent compiler expert approve current patch `27a2690a`; earlier independent
reviews cover identical changed lines before the constructor-base reapplication.

Fresh current-base characterization passes **1,091 callbacks across 69 artifacts**;
its log matches the earlier green. Four original-base semantic mutations killed
boxed-pointer, managed-join owner, inline-record and exit-suffix faults; all were
restored. This historical mutation evidence is reused explicitly, not presented
as a new current-base run. Source-to-C inspection confirms existing carriers and
constructors, with no new List copy. The no-helper String path gains a balanced
retain/release pair, which remains subject to the measured cost limits.

One canonical absolute input/source/output boundary measures three frozen
variants: R = reset `78bc406d6`, B = accepted constructor `89f600c08`, C = B plus
the four-file patch. Later main changes through `e6785c22f` are docs-only.
All 38 source modules, eight library files and 452 fixtures are pinned; the
fixture/library bytes match in every variant. Frozen host `899e0a92` builds each
pilot once; Apple Clang 21 links at O0 with memory diagnostics. Strict counts
and normal instructions are separate, with normal memory variables unset.

| Boundary | R reset | B previous | C candidate |
| --- | ---: | ---: | ---: |
| Fixture allocations | 5,442,709 | 5,432,765 | 5,432,765 |
| Sum of per-input min3 instructions | 18,670,521,319 | 18,657,349,156 | 18,655,947,707 |
| Host source-to-C allocation checkpoint | 23,686,252 | 23,284,857 | 23,285,474 |
| Host source-to-C min3 instructions | 44,114,622,383 | 43,124,867,969 | 43,114,036,875 |

All **1,356 strict calls** balance allocations/releases with zero leaks. All
356 accepted C outputs, 96 rejected diagnostics, statuses and stdout match.
All **4,068 normal samples**, in RBC/CBR/RBC order, reproduce those oracles.
Every input passes both local C<=1.03B and cumulative C<=1.03R ceilings for
allocations and min3 instructions. Allocations match B exactly and are 22 below
R on every input. Largest instruction growth: **+0.373143% local**
(`unsupported/list_pattern.brp`), **+0.280567% cumulative**
(`string_literal/long_unreached.brp`). These small differences establish bounded
cost, not a general speedup claim.

All 12 host-proxy calls completed; checkpoint allocations and normal min3
instruction comparisons pass both local and cumulative caps. Locally, checkpoint
allocations rise 617 (+0.002650%) and instructions change -0.025116%; cumulative changes are
-1.692028% and -2.268149%. The diagnostic host `86ba69ff` supplies the established
artifact_construction_complete checkpoint. It is neither a strict-program leak
count nor self-compilation. Within each variant normal/checkpoint/native-build
C agrees. Source, binary, toolchain and raw/semantic Git endpoints show no drift.

Canonical cost C hashes R/B/C are `56d45849` / `5daaf638` / `cbe3591c`; binaries
are `71d025e3` / `0fcf1da3` / `7cd647e8`. Absolute worker-path inspection C is
`cc045834`, a separate boundary. Actual-main Make uses relative source spelling
and produces `529d516d`; a separate frozen-host invocation with the same relative
spelling produces byte-identical C. Host-qualified type/debug/reuse names explain
the path-dependent outputs. No C normalization or cross-boundary hash equivalence
is used. Absolute counts from earlier packets likewise are not matched samples.

Actual-main `make -C blorp_2 test`, with instruction checks required, exits 0:
**2,903 component checks** (2,737 host callbacks and 166 nested runtime C checks)
and all **452 e2e cases** across 39 groups pass. Its FRESH host `390bdd0d` is
distinct from the cost host; exact source patch and host/pilot endpoints are retained. The
source-tree frontier remains 36/38 at Char/function-type syntax stops; self-compilation
is still pending. Link warnings remain 84 locally (reset had 83), in the existing
categories. Fixture C/diagnostics remain identical on all three cost variants.

Raw evidence is in worktree `1a80/blorp` under
`build/bootstrap-argument-controls-89f600c08/`: HANDOFF.md, C_REVIEW.md and cost/
with recipes, all **5,436 measured calls**, manifests and receipts. Root's
independent raw-oracle/count/min3 audit is in its integration worktree's
`blorp_2/build/argument-controls-landing/root-cost-audit.json`. Current-main gate,
exit, endpoint and unmodified path-comparison artifacts are in the primary
checkout's `blorp_2/build/argument-controls-landing/`. No retry, sample exclusion,
cap change, rewritten input/C, persistent cache or host copy occurred.
