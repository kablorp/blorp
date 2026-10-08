# Concurrently-for tree completion handback

Worktree: <worktree:m4-concurrently-loops>
HEAD: a4a0c020e, with the coordinator's exact keyword-name baseline overlay.
No commits, pushes, branch switches, or full corpus gates. Compiled ownership released.

## Result and design

The ordinary for iterable is read once, then its explicit colon or concurrently token chooses the tail. Concurrent tails require a single BindingTarget, parenthesized options and a checked positive literal limit. Shared parameter readers take a private ConcurrentParameterOwner (block versus for), so the count name is max_threads or limit without guessing from syntax shape. Body context is InsideLoop as in the frozen parser. A concurrently-for loop mints a StatementId, not an extra ExpressionId.

The existing ConcurrentForStatement.binder: Binder schema could not represent frozen-accepted `_`; it now holds BindingTarget. Dump and whole ID census consume that target, and the sample constructor wraps its named binder in BindsName. Legacy projection translates binder, iterable, optional timeout, and block in authored order; checked count is WrittenLimit and mints no expression. New projection tests compare full legacy JSON including spans and pin NameTable order.

Malformed, missing-limit, unknown/repeated parameter, nonliteral count, tuple binder and unsupported-body shapes remain persistent rollback without tree diagnostics. No StopReason added. No syntax/typechecking change, recipes, replay, position queries, or recovery expansion.

## Delta files versus keyword baseline (11)

- blorp/src/compiler/discovery_tree_projection.brp
- blorp/src/compiler_new/stage_01_discovery/parse/tree_body_parser.brp
- blorp/src/compiler_new/stage_01_discovery/syntax/expressions.brp
- blorp/src/compiler_new/stage_01_discovery/syntax/dump.brp
- blorp/src/compiler_new/stage_01_discovery/syntax/id_census.brp
- blorp/test/test_compiler/test_stage_04_modules/test_tree_body_projection.brp
- blorp/test/test_compiler/test_stage_04_modules/test_syntax_nesting_projection.brp
- blorp/test/test_compiler_new/support/syntax_samples.brp
- blorp/test/test_compiler_new/test_stage_01_discovery/test_parse/test_tree_body_parser.brp
- blorp/test/test_compiler_new/test_stage_01_discovery/test_parse/test_syntax_nesting.brp
- blorp/test/test_compiler_new/test_stage_01_discovery/test_parse/test_stop_reasons.brp

## Validation

RED against unchanged implementation after quiet FRESH check:
- bin/blorp test --timeout 180 blorp/test/test_compiler_new/test_stage_01_discovery/test_parse/test_tree_body_parser.brp: 51 passed, 1 failed. /tmp/m4-concurrently-red-body.log
- bin/blorp test --timeout 180 blorp/test/test_compiler/test_stage_04_modules/test_tree_body_projection.brp: 48 passed, 2 failed. /tmp/m4-concurrently-red-projection.log

GREEN preflight first reported STALE: syntax/expressions.brp is a compiler C build input. I accidentally issued the body test despite quiet status failure; it stopped on my new test's multiline boolean syntax at lines 1252-1256 (expected expression), before compiling. Parent was notified. Fixed assertion grouping, ran make successfully under the serial grant, and rechecked FRESH before candidate tests. This setup failure is superseded by the fresh passing runs below. make log: /tmp/m4-concurrently-make.log.

Fresh compiler provenance: a4a0c020e2d8-dirty; target aarch64-apple-darwin; cli=-O0 runtime=-O2; 8-way split; Apple clang 21.0.0; compiled_by dev-dbc23276a2a6. bin/blorp SHA256 ad93bb92bfa7e95c0db827dd2cd3cbb83bedda22049e47ac8521a8b256e80bd3.

All commands use bin/blorp test --timeout 180 <path>, in the worktree above. Final FRESH quiet check passes.

| Path under blorp/test | Passed | Log |
| --- | ---: | --- |
| test_compiler_new/test_stage_01_discovery/test_parse/test_tree_body_parser.brp | 53 | /tmp/m4-concurrently-green-body.log |
| test_compiler/test_stage_04_modules/test_tree_body_projection.brp | 51 | /tmp/m4-concurrently-green-projection.log |
| test_compiler_new/test_stage_01_discovery/test_parse/test_syntax_nesting.brp | 82 | /tmp/m4-concurrently-green-nesting.log |
| test_compiler/test_stage_04_modules/test_syntax_nesting_projection.brp | 43 | /tmp/m4-concurrently-green-nesting-projection.log |
| test_compiler_new/test_stage_01_discovery/test_parse/test_stop_reasons.brp | 5 | /tmp/m4-concurrently-green-stops.log |
| test_compiler_new/test_stage_01_discovery/test_syntax/test_syntax_dump.brp | 19 | /tmp/m4-concurrently-green-dump.log |
| test_compiler_new/test_stage_01_discovery/test_syntax/test_id_census.brp | 10 | /tmp/m4-concurrently-green-census-ids.log |

Total 263 passed, 0 failed. Includes exact ID/span/postorder dump pins, omitted optional timeout and both parameter orders, grouped literal and trailing comma, discard/soft binders, nested break/continue, following owner, invalid-header rollback, NameTable order, 100-deep parse/dump/census/projection walker, at-limit and over-limit nesting.

Targeted census command:

scripts/compiler-new-parity --stop-census --stop-reason concurrently-loop --census-file /tmp/blorp-m4-parallel-2026-10-07/keyword-baseline-candidate-stop-census.txt --keep /tmp/m4-concurrently-target-artifacts

Selected 29 baseline concurrently-loop modules; 0 stopped at any declaration. Log /tmp/m4-concurrently-target-census.log. Retained corpus list, executable, generated C: /tmp/m4-concurrently-target-artifacts/. This is a targeted census, not the full AST corpus parity gate. Initial --keep missing its directory was an argparse setup error (no compiled execution); preserved in /tmp/m4-concurrently-target-census-cli-setup.log, corrected valid command above.

Baseline census input unchanged, SHA256 e2559079459b42b60289c14490163e1708c4bb4fe4b3dd18ff8cc0eca38f5fe9. Candidate output distinct, SHA256 6b2165c582fce0cfe45ad0fadeff310034e4b2e10b01b3acf23414a07edfe306.

git diff --check passes.

## Coordinator docs and remaining gates

No docs/evidence edited in clone. Update ConcurrentForStatement in docs/DISCOVERY_REDESIGN.md to binder: BindingTarget, and its prose to state the single target may be a name or `_`. Existing GRAMMAR concurrency rules say single name; frozen parser accepts discard. Suggested replacement: "takes a single binding target, a name or `_`; tuple binders are rejected". No language change. Record this as a bounded M4 slice and keep rejected-body parity/M4 exit work open.

The schema is a compiler C input, so final integration requires a proper rebuild and the actual changed-file plan, likely broad/compiler-blorp as well as compiler-new/parity. Root owns full gates, code-reviewer/test-runner review, evidence, and integration. No performance claim.
