# Fixed-union declaration cut: final local validation

This is a pre-commit validation snapshot: the independently reviewed declaration
cut is validated and ready for commit; at this snapshot the commit has not yet
been made. Maintained declarations/generators use union
spellings. Enum machinery deletion follows separately; checked fixed/no-box
guarantees, general heterogeneous OR-pattern field identity and broader
caller-selected trait closure remain deferred. No publication or release claim.

## Provenance

Root `/Users/keithphilpott/.codex/worktrees/43a9/blorp`, HEAD
`cbffad8a3b2cc62cf0194e13c97b44bc775ace4d`, dirty reviewed candidate.
Compiled gates validated pre-final-docs staged tree
`80375eff8b349a55e24fabd14ca3dd7c4f55017e`; numeric-only hygiene closure validated
`36e6b8c82f1a54a30bc7f9b3b40e6474d58aa761`. Neither is a commit or the final
post-documentation tree; root separately checks that tree before commit.

| Artifact | SHA256 |
| --- | --- |
| Actual root binary | `2f44843a7237816c10cdcb5269ada8b0e19152f7119027e90f31343edeafaa6e` |
| Compiler C / all fixpoint C | `40a1005cb4dd150ca672edf69085a050bb548b6e7359d4211f42fc7e4cf20e2c` |
| Compiler/Std manifest | `422dcb4ac1c86d23969fdc7829fcf72721a941b2a4b26621c609be1507d3cf22` |
| Test/probe manifest | `0f340cd2dcf44f158d3132cf17801531ab075ef928da534c483661523b07fb6e` |
| Frozen bridge binary | `2ebad178e2fae23d1062ab25f628762891a650a474152ac6df6dea4a78479014` |
| Actual retained stage2 binary | `ebbd309a63347b5069abe20417afc6e0ae21ee1c7eb22ddf74893bfcb7f540eb` |

FRESH before/after only with the explicit bridge override and O2; CLI/runtime O2,
split8, Apple clang21, self-cbffad8a3b2c. Compiler/Std files and frozen bridge/pin
were unchanged. See [bootstrap recipe](README.md); default immutable-pin closure
is not verified. Reproduce the build from root with:

```sh
BLORP_BOOTSTRAP_COMPILER_BIN=/absolute/path/union-bridge/bin/blorp BLORP_CLI_C_OPTIMIZATION=-O2 make
BLORP_BOOTSTRAP_COMPILER_BIN=/absolute/path/union-bridge/bin/blorp BLORP_CLI_C_OPTIMIZATION=-O2 scripts/compiler-build-status
```

## Final-host results and separate epochs

Independent local raw packet `/tmp/blorp-channel-final.tbXdUz` retains exact argv,
UTC times, exit statuses, output hashes and unchanged source fingerprints per
command in `metadata.json`. It is local evidence, not a repository-retained log.

| Final 2f448 owner/gate | Actual result |
| --- | --- |
| Emitter / strict scalar bridge | 366/366; 8/8 |
| Ordinary/fixed dynamic channel probes | native exit0 each; 12 allocations/12 releases/0 leaked objects/0 bytes each |
| String failed-send / receive controls | 1/1 each, strict leak |
| Runtime / compiler-blorp | 4701/4701; 6672/6672 (includes 839 public fixtures) |
| Leak / doctest | 1174/1174; 1057/1057 |
| CLI / CLI-deep / LSP / package | 146/146; 177/177; 36/36; 49/49 |
| Core sanitizer / codegen audit jobs1 | 2413/2413; 229/229 |
| O2 fixpoint | exit0; stage1/2/3 C each 76,574,654 bytes and identical SHA above; actual stage2/stage3 cmp exit0 |
| Retained stage2 strict runtime / audit jobs1 | 29/29; 229/229 |
| Separate final hygiene / census Python | exit0; 3419 identity rows, 506 allowlisted magic findings/0 stale; 32/32 |

Counts overlap; no aggregate sum. Stage2 strict runtime is bridge8+packed19+String
send1+receive1. Stage2 is not the frozen bootstrap bridge. All jobs ran serially;
no timeout overrides or gate waivers. Typical gate command was
`scripts/test --no-build --serial --log-dir <packet>/<gate>-logs <gate>`; raw
metadata records the exact command for each gate. Audit used `--jobs 1`; focused
tests used explicit own `--std-dir /Users/keithphilpott/.codex/worktrees/43a9/blorp/standard_library/src`.

The original independent compiled report is frozen at
`/tmp/blorp-channel-final.tbXdUz/REPORT.md`, SHA
`ce2528e15530139670c75bf49586e5a96374d4aa2b8f2e2a62415e2577e75f56`, including its
genuine hygiene RED. [Final hygiene closure](final-hygiene-closure.md), independently
recorded SHA `13d95ea872839cabd6f5dc6ef0cb75d09f287cf394dc04c4e554ec3694fddddc`,
closes that stop without changing compiler source/bin or relabeling the RED.

Earlier f271 frontend proofs in `/tmp/blorp-migration-finalhost.V0Y0HB` remain
pre-channel: repair64, eleven716, std1, tools241, new838, full parity3565 and
compiler6669; its runtime setup RED is retained. Earlier 8a/e90/ee239 source-owner
30/341 and runtime/Core187, five-error/five-help negative, and late owner48/bundle716
remain their distinct epochs. The final compiler/runtime gates above supersede
the blockers, not their historical evidence.

## Reviewed hygiene reconciliation

Only seven existing heuristic `member_read_candidate.max_count` values changed:

| Directory/member | Old cap | Exact observed/new cap |
| --- | ---: | ---: |
| Core/def_id | 291 | 293 |
| Backend/def_id | 42 | 43 |
| Type-system/id | 126 | 130 |
| Typecheck/name | 242 | 246 |
| Type-system/name | 77 | 79 |
| Core/name | 488 | 490 |
| Backend/name | 141 | 143 |

Net caps +17 = six inherited + eleven current-cut, with no spare headroom. Actual
inventory +18 includes one inherited read consuming existing headroom. Current
reads are runtime callback function/method IDs and names (origin/type-key selected,
projection identity oracle); accepted layout lookup and fail-closed diagnostic
name/span reads (header/issued-identity controls); and backend declaration/status
names plus issued variant IDs (strict constructor-symbol/release/fail-closed
oracles). Inherited reads validate accepted issuer/trait/implementation identities
and canonical builtin registry/member mappings. A moved Env bound-name read nets
zero. No exact-site keys, capabilities, allowlists, baseline revision, schema,
scanner or production changes. Full reviewed attribution is local
`/tmp/blorp-identity-audit.nL1FJL/BUDGET_REVIEW.md`, SHA
`b888b92c6e680c154914051256050a86a4f7d7f00ba62cf4fbd4ce89cac10bf5`, and `member-delta.txt`.

## Preserved repairs, failures and scope

[Eq/Hash repair](fieldless-override-repair.md) retains default tag Eq/Hash while
potential custom Eq requires explicit Hash; authored callbacks and CTFE equality
are respected. [Late traversal prerequisite](late-invariant-layout-prerequisite.md)
retains the pinned8999/clean-cbff reproduction and the bounded two-consumer,
sixteen-arm fix; the general OR-pattern defect is not fixed.
[Channel repair](channel-representation-repair.md) retains RED364/365 and the f271
runtime setup failure, then actual scalar constructor-symbol handling with the
managed lane unchanged. [Ordinary](channel-ordinary.fixture.txt) and
[fixed](channel-fixed.fixture.txt) probes are inert evidence; the report provides
unique scratch `.brp` replay recipes. A scratch `fixed.brp` name collision remains
recorded separately from the corrected unchanged-content invocation.

Historical executable benchmarks were migrated and no longer recreate old source
hashes; frozen measurements/manifests remain historical. Legacy formatter JSON
and enum lexer/parser/protocol internals remain for cut2. No family deletion,
checked allocation/layout guarantee, all-platform release, performance claim,
bootstrap-pin rotation, merge or push is established here.
