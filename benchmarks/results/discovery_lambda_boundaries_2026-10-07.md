# Discovery completed block-lambda boundaries

This bounded M4 slice starts from `48c47a8e0`, with 13 corpus first stops.
Four `token-after-expression` records involve a completed block lambda followed
by a statement or declaration: two detached lambdas in function bodies and two
global initializers. The frozen grammar accepts those boundaries. This slice
uses the parser's existing ending evidence to complete them; it changes no
language-design decision and leaves M4 open.

## Boundary and scope

`ExpressionValue.tail` already distinguishes `BlockLambdaOperand`. Prefix and
binary parents preserve the last operand's tail, while grouping resets it to
`PlainOperand`. The old root inspection could recognize only a direct lambda;
it lost the authored ending through `detach`, `not`, negation or a binary
parent. Global initializer and expression-statement boundaries additionally
omitted block lambdas.

The new `ends_in_block_lambda` predicate reads that explicit tail. A shared
token-only `block_expression_ends` predicate retains the existing exclusions
for binary operators, `as` and `=`. Assignment values, expression statements,
resumed control statements and global initializer boundaries now consume the
same ending evidence. Moving the prior body-local follower predicate changes
no behavior for other block forms. No schema, stop reason, position query,
recipe, replay or broader recovery is introduced.

Binary continuation after block lambdas remains unsupported by this tree
reader, though the frozen parser accepts it. `as` and assignment expressions
are removed forms. All three followers retain exact unsupported rollback here.
An expression-bodied outer lambda returning a block lambda still has its
existing `PlainOperand` classification; extending that evidence is separate
coverage work. The fifth `token-after-expression` record (`into` followed by
another expression on the same line) also remains outside this slice.

## Regression and source review

Two new behavioral tests fail on the unchanged baseline: the completed-value
boundary cursor test and the full legacy-AST projection matrix. The final
focused result is 168 passing tests: 55 expression-parser, 56 body-projection
and 57 unchanged body-parser tests.

The projection matrix compares full ASTs, authored names, spans and ID census
for direct and prefixed block lambdas as statements, bindings and globals;
nested bodies and multiple dedents; following declarations; binary right
operands; and resumed control expressions whose right operand is a lambda.
Direct boundary tests pin the following token and value span. Unsupported
followers pin exact entry-state rollback, and existing negatives remain intact.

An expanded test run initially failed one new classification input because its
lambda body was not indented past its frozen expression anchor. Correcting that
test's indentation made the expression suite pass; implementation code did not
change. The failed run and corrected rerun are retained separately.

Independent source review approves with zero blockers, should-fixes or nits.
The actual changed-file plan selects tree parser gates: no changed path is a
production compiler build input, so a repeat of `compiler-blorp` is not required.
All compiled execution is serialized.

## Final validation

Independent importing/owning suites pass 603/603 assertions across 21 unique
suite files. The required `make` completes with production C and objects already
up to date; linking refreshes the embedded commit metadata to `48c47a8e0f0f-dirty`.
The worker's FRESH binary is SHA256
`454663c4ed845bd1e96277431ac6745f6206e7268db3dc9ce51ebf5d4137bbbf`; final
validation freezes the refreshed binary at
`26718a6fa6f558dc6b8900a3563ab0ecb6ca0b6b5e4b57cc88958fee16294633`.
These distinct identities are recorded separately.

| Check | Result |
| --- | --- |
| Independent importing/owning suites | 603/603 across 21 unique suites |
| Full `compiler-new` | 1,052/1,052 |
| Full `compiler-new-parity` | 3,621/3,621, zero AST mismatches |
| Two broad gates combined | 4,673/4,673 |

Full parity assembles and compares 3,453 of 3,462 accepted corpus modules,
versus 3,449/3,462 on the baseline. The nine remaining unread modules all stop
in function bodies; none stops in a global initializer. Compiler, test and
package-root checks also pass. These are coverage results, not performance
measurements.

## Matched corpus census

The independent normal census records nine first stops across 3,605 paths,
down from 13. All four targeted modules now complete. The largest remaining
group is `indented-continuation` (four modules); `lambda-in-interpolation-hole`,
`loop-exit-outside-loop`, `match-without-block`, `nested-block-in-case-line`
and `token-after-expression` each account for one module.

The completed inputs are `file_resource_detach_capture.brp` (function, line 11),
`global_initializer_lambda_mutable_assignment.brp` (global, line 6),
`mutability_detach_pattern_shadow_outer.brp` (function, line 9) and
`standard_library/src/validation.brp` (global, line 579). All four retain their
baseline bytes. The other nine first-stop records retain identical path, owner
kind, reason, line and content. No input reaches a later stop, no newly stopped
path appears, and no corpus path is added or removed.
Of the 3,605 existing inputs, 3,601 retain identical content and four tree-parser
source/test files change. None of the 13 baseline stopped inputs is edited.

## Provenance and retained evidence

The final before/after source and compiler snapshots are identical, and build
status remains FRESH with the refreshed compiler identity recorded above.
Exact commands, working directories, environment, timings and exit codes are
retained alongside the per-input census comparison and compact provenance.
The full source-hash snapshots and generated validation artifacts stay under
`/tmp/blorp-m4-lambda-boundaries-2026-10-07/`.

The adjacent packet retains the baseline census, worker TDD and failed-input
correction logs, final gate receipts and logs, source review and final evidence
review. Terminal transcripts omit trailing empty lines in the durable copies;
original output remains in scratch. The source/test delta is a lossless JSON
patch wrapper: decode `content` and verify `raw_sha256` before applying it over
`48c47a8e0`. The
[packet manifest](discovery_lambda_boundaries_2026-10-07/MANIFEST.json) pins every
durable payload. Hygiene, artifact and diff checks pass.

No matched performance, allocation or sanitizer probe was run, and no cost
improvement is claimed. Rejected-module subset parity, parse-outcome cleanup
and the other M4 exit criteria remain open.
