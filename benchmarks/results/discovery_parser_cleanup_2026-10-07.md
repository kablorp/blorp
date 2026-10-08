# Discovery parser cleanup

Six bounded, semantics-preserving changes on `codex/discovery-parser-cleanup`, based on `295cb1441d6a3c3f53e85df57c5c14cd26c31b30`. Grammar and diagnostic policy stay at their existing boundaries. This cleanup does not complete the remaining M4 diagnostic/outcome/deletion work.

## Changes and boundaries

1. Expression and statement readers share a narrow ending predicate taking the ending, operand tail and follower token. Their expression/statement boundary checks and rollback remain with each caller. The now-unused control-ending accessor was removed.
2. Function and implementation-method headers share the callable syntax sequence: name, generic parameters, signature, rejected authored return and dimension constraints. Declaration owners retain colon/body requirements, diagnostic acceptance and rejected-body recovery; traits retain their distinct policy.
3. Match/select finishing passes the original nonempty case/arm list into syntax, avoiding destructure/reconstruction. Their different operator-follower checks remain explicit.
4. Block parsing establishes nonemptiness by parsing its first statement, then accumulates leading/last/start directly inside that successful branch. No second list traversal or per-statement wrapper is needed. Empty/unclosed/unsupported paths restore the original entry, and the block ID is issued after the closing dedent.
5. Expression duplicate fields use a module-local dictionary keyed by SpellingId, retaining the first occurrence's span. Declaration fields keep their existing scan and first-hit break, comparing interned IDs directly instead of resolving spelling text. Type-before-duplicate diagnostic ordering and first field IDs are preserved.
6. Successful declaration previews distinguish unfinished function heads from completed ModuleItem values. The module scan forwards completed items directly; declined/rejected results, prefix ownership and deferred function completion retain their existing behavior.

Each topic had a dedicated Sol 6.1 medium worker using the [handoff structure](../../docs/HANDOFF_SPEC.md). Briefs/dialogue and raw logs are retained externally under `/tmp/blorp-parser-cleanup-20261007/`; workers did not commit. Shared source sections were assigned explicitly and compiled work was serialized. An independent code reviewer approved the final source and evidence with zero blockers or required fixes.

## Measurements and rejected designs

[Duplicate fields](discovery_duplicate_fields_2026-10-07/README.md): the accepted expression index reduced retired instructions by 6.4–7.9% on 256-field probes, with tiny guards within +0.83%. Declaration ID comparisons reduced 256-field instruction counts by 28.0–43.7%, with unchanged allocations. A declaration dictionary was rejected because empty/small records gained a managed allocation and regressed roughly 2–8%.

[Single-pass blocks](discovery_single_pass_blocks_2026-10-07/README.md): the accepted direct accumulator reduced retired instructions by 0.92–2.79% across 1/2/8/64/256 statement probes and reduced managed allocations throughout. A record/Option accumulator was rejected: at 256 statements it increased allocations 5.51% and retired instructions 15.83%.

All measured baseline/candidate output oracles agree; live-object deltas are zero. Measurements use isolated parser changes, pre-lexed input, matching compiler/toolchain hashes and five alternating instruction samples. They cover direct parser workloads; whole-compiler speed and RSS were not measured. The repository measurement-lock command is a pass-through, so machine-wide quiet was unverified. Other clarity refactors have semantic validation and no separate speedup claim. Exact isolated source patches, probe/runner text, samples and provenance are retained in the linked packets; patches are JSON-wrapped to preserve exact diff context while satisfying whitespace checks.

## Final independent validation

| Check | Result |
| --- | --- |
| Compiler build status before/after | FRESH |
| Nine focused owner suites | 203/203 |
| Seven projection/differential suites selected by the plan | 280/280 |
| compiler-new | 1064/1064 across 64 suites |
| compiler-new-parity | 3635/3635 checks, 3619 corpus files, zero mismatches |
| Accepted corpus-traversed modules | 3477/3477 fully assembled; 189 legacy-rejected modules |
| Independent full stop census | 3619 files, zero stops |
| git diff --check | Pass |
| Source/script/binary invariance during gates | All 3965 paths identical |

The parity total includes 16 root/adapter checks in addition to the corpus paths. The new callable-header module accounts for the corpus increase from 3618 to 3619; receipt text is not a corpus root. Invariance manifest SHA-256: `fe6297c518ce1df9e05e09c7a3e8678c982235a6d872ac169598d9006dc71d81`. Compiler SHA-256: `3f7a5ae841d0ed96ea7bd97f9fb11a15cb3dc4f41f384b3ee9959c60e3027f69`.

Commands: `scripts/compiler-build-status --quiet`; `scripts/compiler-check --changed --plan`; owner and plan-listed suite batches through `bin/blorp test --timeout 180`; `scripts/test --no-build --log-dir /tmp/blorp-parser-cleanup-20261007/final-gates compiler-new compiler-new-parity`; `scripts/compiler-new-parity --stop-census --census-file /tmp/blorp-parser-cleanup-20261007/final-gates/stop-census.txt`. Full command/log/report artifacts remain in that final-gates directory. No source edits or gate overrides were used during validation. Tree-only handback did not require compiler-blorp; Docker premerge remains a later landing gate.
