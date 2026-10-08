# Discovery corpus with no unread declarations

This M4 coverage slice starts from `8890d61ae23d00b04b08e5a054e1601ef62e50f6`,
after the reviewed block-lambda boundary slice was committed. Its baseline
contains nine first stops across 3,605 tracked corpus files. Three are parser
coverage gaps on unchanged source; six require source corrections. Zero corpus
stops is a coverage milestone, not completion of M4's exit criteria.

## Parser contract

Expression-bodied lambdas now parse in interpolation holes through the existing
lambda reader. The hole still holds one expression, has its own token cursor,
and shares the module's spelling and ID authority. The outer cursor remains
parked while the hole is read. Lambda bodies begin outside any enclosing loop.

A same-line match case beginning with `if` or `match` uses the case pattern as
its block anchor, as the frozen parser does. The directly parsed control is
wrapped as one expression statement; binary followers remain for the enclosing
match reader. Other case-line block forms keep their existing rules and
unsupported boundaries.

The explicit `BodyContext` now passes through expression recursion, arguments,
aggregate items, headers, interpolation holes and operator continuations.
Statement controls in expression operands can therefore see the enclosing
loop. Functions, lambdas and concurrent tasks start `OutsideLoop` again.
No position query, recipe, token replay or new stop reason is introduced;
the obsolete `LambdaInInterpolationHole` reason and label are deleted.

The runtime ownership regression retains its exact source. It exercises exits
inside a call argument, where forwarding a temporary into the assigned variable
would lose the old value. This follows M4's frozen current behavior. The intended
restriction on exits in value-position `if`/`match` remains explicitly pending
in `GRAMMAR.md` section 5.3; this slice does not enact that language change.

## Corrected corpus inputs

| Input | Correction and retained oracle |
| --- | --- |
| `std_net_websocket_resource_surface.brp` | Parenthesized multiline condition; resource/import/typecheck behavior retained. |
| `tls_dependent_resource_surface.brp` | Parenthesized multiline condition; resource/import/typecheck behavior retained. |
| `test_stage_06_typecheck/test_infer.brp` | Bound the `TypedMissingExpr` match before the method chain; retained the error count, exact message and missing-expression checks. |
| `into_is_an_ordinary_name.brp` | Used the ordinary name `into` directly; retained exact unbound-value diagnostic and discovery-acceptance pins. |
| Formatter `should_fail/block_header_expression_multiline.brp` | Parenthesized match/for/while headers; retained unformatted valid source and unchanged exact formatter golden. |
| Formatter `should_fail/if_condition_chain_multiline.brp` | Parenthesized if headers; retained unformatted valid source and unchanged exact formatter golden. |

The unchanged parser targets are formatter `comment_if_else.brp`, formatter
`string_interpolation_flat.brp` and runtime
`test_loop_temporary_leaving_early.brp`. Formatter `should_fail` means formatting
must change, not syntax rejection. Those regressions are preserved.

## Regression evidence

The baseline focused body run fails the three new behavior tests (3/60), retained
in `parser-worker/red-body.log`. The implementation's focused runs pass body 62,
expression 55, trait 12, implementation 12, stop reasons 5 and body projection 58.
A final mechanical cleanup of the projection matrix is covered by the independent
hand-back run below. Full legacy AST JSON, names, spans and ID census pin accepted
behavior. Boundary tests pin exact cursor/spelling/ID/diagnostic rollback, including
loop-context resets across functions, lambdas and tasks.

Five previously unsupported valid specimens move from rollback lists into
positive coverage. The adapter's temporary unread helpers now exercise the real
remaining gap of a binary operator following a block lambda. They preserve the
original authored identifier vocabulary and all header, offset, name, ID and
mutation assertions. Grouping on its own line gives the helper an explicit anchor
independent of header width. The adapter's narrow check passes 125/125.
Exact legacy probes use `compile --no-format --ast`; default `compile --ast`
formats its input and cannot prove acceptance of the original source bytes.

Review caught and corrected a false acceptance: inline case controls initially
resumed binary operators, unlike the frozen direct entry. The new full legacy
oracle fails before the fix (1/59 projection tests) and rejects both `if` and
`match` cases with either `+` or `-` tails afterwards. Independent focused gates
also found three stale migration expectations. The global and assembly rollback
oracles move to the real block-lambda gap; original valid lambda-hole globals gain
full AST/name/span/ID positives. The fuzzer's nested-loop `?=` known defect becomes
an ordinary rejection regression because explicit context propagation fixes it.

## Independent validation and corpus census

The independent importing/owning check passes 984/984 assertions across 24
unique suites. Both resource fixtures pass `check --no-format`; the isolated
formatter oracle passes 4/4 against the unchanged goldens. Parser fixtures check
170 diagnostic text pins, and all four runtime ownership regressions pass.
`make`, build freshness, hygiene, artifact scan and diff checks pass.

| Required broad gate | Result |
| --- | --- |
| `compiler-new` | 1,058/1,058 |
| Full `compiler-new-parity` | 3,621/3,621, zero AST mismatches |
| `compiler-blorp` | 6,853/6,853 |
| Broad gates combined | 11,532/11,532 |

Full parity assembles all 3,462 accepted corpus modules, compared with 3,453 on
the baseline, and compares 51,988 completed declarations. The independent raw
census verifies **nine to zero first stops** on the same 3,605 paths. Every
baseline stop completes; no later or newly stopped path appears. Exactly six
stopped inputs are edited and three retain identical bytes. Across the whole
corpus, 20 parser/source/test files change and 3,585 remain byte-identical.

The final before/after source and compiler snapshots are identical. Post-gate
build status is FRESH; the final compiler SHA256 is
`363cdcabde6c85753d1832a228d59fc507d65ed4bae15cf3a91c8a2c02ffb12a`.
The baseline compiler's older metadata and the worker's local source-state
limitations are recorded separately; no cross-binary cost comparison is made.

## Retained evidence and review

The adjacent packet retains the original nine-stop census unchanged, the final
zero-stop census, target attribution, TDD failures and corrected runs, exact
commands, broad logs, source review, and the final runner's report. The
[packet manifest](discovery_zero_stops_2026-10-07/MANIFEST.json) pins every
payload. Full source-hash snapshots and generated validation artifacts remain
under `/tmp/blorp-m4-zero-stops-2026-10-07/`; compact freeze digests are durable.
Terminal copies omit trailing empty lines. Two failed-input transcripts use
lossless JSON wrappers to retain their internal whitespace; decode `content`
and check `raw_sha256`. The source delta is likewise a lossless JSON patch
against the stated baseline commit.

Independent source, documentation and final evidence reviews approve with
zero blockers, should-fixes or nits.

No matched performance, allocation or sanitizer claim is made. The preserved
runtime test is outside the leak gate because its existing early-exit path has
a documented leak on main. Rejected-body diagnostic subset parity, parse-outcome
unification and deletion of the remaining recovery machinery still keep M4 open.
