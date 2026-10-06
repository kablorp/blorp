# Discovery M4 stop-reason census (2026-10-06)

Why the tree path of discovery stops, per module, over the parity corpus
(`blorp/src`, `standard_library/src`, `blorp/test`). Each rollback in the tree
parsers carries a `StopReason` (`stop_reason.brp`), chosen where the parser
declines and held in the `Unsupported...` result, so the table below is counted
from those values and nothing is read back from text.

## Provenance and command

Main `44068a8af` (lambdas and local functions landed) plus the census change,
repository `bin/blorp` `FRESH` after `make`, Apple Silicon. One serial run of
the adapter differential in `files` mode over the tracked corpus files:

```bash
scripts/compiler-new-parity --stop-census
```

The census reads only test-only state: the scan records each declined
declaration in `ModuleDeclarationPreviewScan.declined`, and `--stop-census` is a
separate mode of the parity script that checks nothing. The tree parsers have
no production caller (only the legacy adapter's projection, used by tools and
tests, consumes the scan), so the added `StopPoint` allocation on a rollback
costs the compiler nothing; it was not separately measured for that reason.

## Result

Corpus files: 3554. Modules whose tree scan left a declaration unread: 1851 (function 1474, global-initializer 349, implementation 28); declarations left unread in all: 17449.

| Rank | Reason | First-stop modules | Share | All unread declarations | Example |
| ---: | --- | ---: | ---: | ---: | --- |
| 1 | multiline-braced-opening | 711 | 38.4% | 4578 | blorp/src/check/capture.brp:10 |
| 2 | multiline-call-arguments | 295 | 15.9% | 6015 | blorp/src/check/command.brp:32 |
| 3 | multiline-grouping | 175 | 9.5% | 1765 | blorp/src/compiler/pipeline.brp:208 |
| 4 | with-block | 96 | 5.2% | 333 | blorp/test/compiler/pipeline/codegen_audit/should_pass/http_resource_server_response_cleanup.brp:23 |
| 5 | indented-method-chain | 90 | 4.9% | 760 | blorp/src/compiler/output.brp:25 |
| 6 | opaque-conversion | 85 | 4.6% | 775 | blorp/src/compiler/stage_02_lex/name_table.brp:44 |
| 7 | tuple-destructuring | 76 | 4.1% | 672 | blorp/src/compiler_new/stage_01_discovery/parse/tree_alias_parser.brp:33 |
| 8 | multiline-list-literal | 74 | 4.0% | 814 | blorp/src/compiler/stage_04_modules/module_surface_json.brp:27 |
| 9 | builtin-body | 61 | 3.3% | 692 | blorp/src/compiler/runtime_source_provider.brp:10 |
| 10 | concurrent-block | 48 | 2.6% | 147 | blorp/test/compiler/pipeline/codegen_audit/should_pass/concurrent_block_channel_record_tail_cleanup.brp:46 |
| 11 | value-on-next-line | 18 | 1.0% | 143 | blorp/src/compiler/stage_10_backend/emit.brp:646 |
| 12 | multiline-record-update | 17 | 0.9% | 285 | blorp/src/compiler/stage_07_ctfe/body_dependencies.brp:43 |
| 13 | debug-block | 17 | 0.9% | 69 | blorp/src/compiler/stage_06_typecheck/graph/source_name_table.brp:67 |
| 14 | concurrently-loop | 15 | 0.8% | 19 | blorp/test/compiler/pipeline/codegen_audit/should_pass/concurrently_loop_limit_bounds_active_tasks.brp:25 |
| 15 | operator-operand-on-next-line | 13 | 0.7% | 154 | blorp/src/compiler_new/stage_01_discovery/parse/token_cursor.brp:73 |
| 16 | select-block | 13 | 0.7% | 27 | blorp/test/compiler/pipeline/codegen_audit/should_pass/select_channel_timer_wait.brp:16 |
| 17 | detach-expression | 10 | 0.5% | 28 | blorp/test/compiler/stage_06_typecheck/fixtures/typecheck/should_fail/detach_in_pure.brp:6 |
| 18 | match-expression-operand | 9 | 0.5% | 33 | blorp/test/compiler/stage_06_typecheck/fixtures/typecheck/should_pass/compile_time_match_constructors.brp:24 |
| 19 | bodyless-function | 6 | 0.3% | 48 | blorp/test/compiler_new/stage_01_discovery/parse/fixtures/should_pass/forward_declarations.brp:4 |
| 20 | malformed-lambda-header | 5 | 0.3% | 28 | blorp/test/runtime/concurrency/test_concurrent_edge_cases.brp:13 |
| 21 | header-without-colon | 4 | 0.2% | 7 | blorp/test/compiler/stage_06_typecheck/fixtures/typecheck/should_pass/std_net_websocket_resource_surface.brp:13 |
| 22 | if-expression-operand | 4 | 0.2% | 5 | blorp/test/compiler/pipeline/codegen_audit/should_pass/global_constant_float16_ctfe_rounding.brp:6 |
| 23 | soft-keyword-name | 3 | 0.2% | 37 | blorp/test/compiler/pipeline/codegen_audit/should_pass/builtin_return_cast.brp:15 |
| 24 | token-after-expression | 3 | 0.2% | 3 | blorp/test/compiler/stage_06_typecheck/fixtures/typecheck/should_fail/global_initializer_lambda_mutable_assignment.brp:6 |
| 25 | lambda-in-interpolation-hole | 1 | 0.1% | 6 | blorp/test/format/should_pass/string_interpolation_flat.brp:9 |
| 26 | soft-keyword-field-name | 1 | 0.1% | 2 | blorp/test/compiler/stage_06_typecheck/fixtures/typecheck/helpers/leaky_types_mod.brp:6 |
| 27 | nested-block-in-case-line | 1 | 0.1% | 1 | blorp/test/format/should_fail/comment_if_else.brp:6 |
| 28 | multiline-subscript | 0 | 0.0% | 2 | - |
| 29 | multiline-record-literal | 0 | 0.0% | 1 | - |

A module counts once, under the reason of its first unread declaration: that
is where the tree path stops (the module's first function, trait,
implementation or global initializer the body policy could not complete). The
last column counts every declaration the scan tried and declined, including
later ones in the same module, so it weighs a reason by how many bodies it
blocks rather than by how many modules it ends.

## Reading it

- Bracket layout dominates. `multiline-braced-opening`, `multiline-call-arguments`,
  `multiline-grouping` and `multiline-list-literal` are 68% of first stops
  (1,255 of 1,851 modules), and `multiline-call-arguments` alone blocks 6,015
  declarations. The lexer emits no newline token inside brackets, so a reader
  that accepts a bracketed form whose items start on later lines clears most of
  them in one slice. Records opened on their own line (`{` then fields) are the
  largest single shape.
- Words the grammar gives meaning to at the start of an expression follow:
  `with-block` 96, `opaque-conversion` 85, `builtin-body` 61, `concurrent-block`
  48. `debug`, `select`, `concurrent` and `with` count as a block only when the
  tokens after them have the block's shape; any other use is `soft-keyword-name`.
- `indented-method-chain` (90) and `tuple-destructuring` (76) are the next
  statement and expression shapes.
- A module's first reason hides the ones behind it. Clearing the top reason
  moves its modules to their next stop, so the ranking orders slices; it does
  not predict how many modules a slice completes. Re-run the census after each
  slice.
- `bodyless-function` (6 first stops, 48 declarations) is the forward
  declaration the body slice keeps deferred by design.
