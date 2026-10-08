# Discovery value layout, concurrent loops and control continuations

Three bounded M4 increments extend the frozen tree grammar: next-line assignment
values, concurrent-for statements, and binary continuation after completed
`if`/`match` operands. They start from the reviewed, uncommitted keyword-name
slice over `a4a0c020e`; that baseline has 94 corpus first stops. The three
workers used `gpt-6.1-sol` with medium reasoning in isolated managed worktrees.
Implementation and static review ran in parallel; all compiled execution was
serialized. No language-design decision is changed, and M4 remains open.

## Boundaries

Next-line assignment/global values consume the frozen lexer-owned layout:
`NEWLINE INDENT expression NEWLINE* DEDENT`. The value's first token owns its
expression anchor. `tree_value_layout.brp` shares opening/closing token tests
between body and global readers. Pipe strings end their own line, so they
arrive directly at the closing dedent; ordinary values leave a newline.
The closing layout must belong to this value. A malformed second expression
line safely declines rather than reproducing the legacy parser's recovery.
`with` acquisitions and control headers retain their separate entry rules.

Concurrent-for completes the existing `ConcurrentForLoop` form and projects it
to the frozen AST. `limit` remains required and a checked positive integer
literal; optional `timeout` is a value expression. An explicit parameter owner
separates the loop's `limit` from a concurrent block's `max_threads` without
accepting unknown, repeated or missing names. Its binder is `BindingTarget`,
representing both a name and legacy-accepted `_`; tuple binders still decline.
The dump, ID census and syntax sample consume that precise form. This shared
syntax schema is a production build input, so the final gates include a fresh
rebuild and `compiler-blorp` as well as tree parser validation.

Control continuation reuses the existing iterative binary operator loop from
actual completed expressions. A right control operand resumes at its caller's
minimum precedence, while a statement control retains its enclosing loop
context. No accepted tokens are replayed. The frozen entry distinctions matter:

| Entry | Leading `if`/`match` binary continuation |
| --- | --- |
| Same-line assignment value | Bypasses the operator loop; a following minus can start the next statement |
| Next-line assignment value | Enters the operator loop within the value's own indent |
| Call argument, list element, subscript index | Uses the direct header-anchored control entry |
| Grouping/tuple, record/update field, dictionary/vector item | Uses the expression operator entry |
| Binary right operand | Resumes at the caller's minimum precedence |

A separate anchored-item reader implements the call/list/subscript boundary;
other aggregate owners retain their operator entry. Block-lambda tails, other
block constructs, and `as`/`=` rejection paths retain their existing scope.
There are no recipes, token-index replay, new stop reasons, source-formatting
heuristics or new position queries. Unsupported trials retain their saved
cursor, spelling and minting authorities.

## Regression proof and review

Each worker added failing behavioral tests before implementation. Values:
body 50/51 and projection 48/49 on the baseline, then focused 171/171 green.
Loops: body 51/52 and projection 48/50 red, then 263/263 focused green,
including dump, census, 100 nested loops and at-limit/one-past-limit checks.
Operators: projection 48/49 and body 52/53 red, then 304/304 focused green,
including a 256-term control chain. Full-AST projections pin authored names,
spans, postorder IDs, following
statements and sibling owners. Invalid headers and unsupported subexpressions
pin exact rollback. Existing keyword-name assertions remain intact.

Stale unread next-line and concurrent-loop negatives move to genuine remaining
boundaries; they retain their rollback checks. The pipe-string helper now tests
the completed global route rather than manually skipping tokens into an unread
initializer. No whitespace padding or offset-oracle weakening is used.

Focused operator validation found an overacceptance in call arguments when
control continuation was enabled. The existing negative fixture was preserved
and the anchored-item boundary was corrected, with additional rejected
call/list/subscript and accepted aggregate differential cases. Static review
also identified the combined next-line control entry: it must use the expression
operator entry even though same-line assignment values bypass it. A separate
combined full-AST regression covers both controls across nine assignment forms,
three binary operators and global values. It fails before the integration
correction (54/55) and passes afterward (55/55).

The independent importing-suite run initially passed 1,423 tests and failed 12
assertions. Ten adapter assertions used next-line values or concurrent loops as
deliberately unread forms; two stop assertions expected a binary continuation
after a same-line assignment's completed control. These were stale fixture
expectations, not production parser failures. Adapter negatives now contain a
legacy-accepted lambda in an interpolation hole and explicitly assert
`LambdaInInterpolationHole`. All 21 original header/name/mutation/offset
assertions remain unchanged. Newly supported adapter inputs compare full ASTs,
authored spellings and spans against the legacy parser. The two stop assertions
now expect `OperatorWithoutLeftOperand`, and an ascription case retains
`OperatorAfterBlock` coverage. No production source changed in this follow-up.

The independent affected rerun passes 130/130 (125 adapter tests and five stop
tests). Combined with the unchanged 1,305 passing tests, the final result is
1,435/1,435 across 79 unique importing or owning suites. The first failed run,
its source freeze and the affected rerun are retained separately.

## Final validation

| Check | Result |
| --- | --- |
| Independent importing/owning suites | 1,435/1,435 across 79 unique suites |
| Full `compiler-new` | 1,050/1,050 |
| Full `compiler-new-parity` | 3,621/3,621, zero AST mismatches |
| Full `compiler-blorp` | 6,848/6,848 |
| Three broad gates combined | 11,519/11,519 |

Full parity also completely assembles the compiler root (474 modules), test
root (103), native package (39) and source packages (41), including embedded
standard-library routes. For every corpus file as a root, 3,449 of 3,462
legacy-accepted modules assemble and compare in full, leaving 13 unread
modules (11 function bodies and two globals), versus 3,367/3,461 and 94 unread
modules on the keyword baseline. The new accepted module is the shared
value-layout helper. The parity gate's 3,621 cases include package/root inputs;
they are distinct from the tracked corpus census's path count.

The actual changed-file plan selects broad validation because of the shared
syntax schema. After a proper `make` and a FRESH build-status check, the normal
gate command is `scripts/test --no-build --serial --log-dir
/tmp/blorp-m4-parallel-2026-10-07/final-gates/broad compiler-new
compiler-new-parity compiler-blorp`. No gate settings, timeouts or environment
overrides are introduced. Runtime durations in the receipts describe gate
execution, not parser performance measurements.

## Matched corpus census

The normal command is `scripts/compiler-new-parity --stop-census --census-file
/tmp/blorp-m4-parallel-2026-10-07/final-gates/final-stop-census.txt`, with a new
output file rather than reusing the baseline census. It examines 3,605 corpus
paths and records 13 first stops:

| Remaining reason | Modules |
| --- | ---: |
| `token-after-expression` | 5 |
| `indented-continuation` | 4 |
| `lambda-in-interpolation-hole` | 1 |
| `loop-exit-outside-loop` | 1 |
| `match-without-block` | 1 |
| `nested-block-in-case-line` | 1 |

All 82 baseline target inputs have unchanged content:

| Baseline first stop | Baseline modules | Complete now | Later first stop |
| --- | ---: | ---: | --- |
| `value-on-next-line` | 31 | 31 | None |
| `concurrently-loop` | 29 | 29 | None |
| `operator-after-block` | 22 | 21 | One `match-without-block` |

Thus 81 formerly unread modules now complete without source edits. The remaining
operator input is `blorp/test/test_compiler/test_stage_06_typecheck/test_infer.brp`:
its function stop advances from `operator-after-block` at line 3,651 to
`match-without-block` at line 4,400. The other 12 baseline first-stop records
retain identical path, owner kind, reason, line and content. No new path stops
and no corpus path is removed; the shared helper is the sole added path.

The matched corpus retains all 3,604 baseline paths: 3,589 existing inputs are
byte-identical, 15 source/test inputs are edited, and the helper adds one path.
None of the 94 baseline stopped inputs is edited. Four imported benchmark
dependencies outside the corpus also retain their baseline hashes.

## Provenance and retained evidence

The source, compiler and benchmark snapshots are identical before and after
final validation, and build status remains FRESH. The compiler SHA256 is
`454663c4ed845bd1e96277431ac6745f6206e7268db3dc9ce51ebf5d4137bbbf`, with
embedded label `a4a0c020e2d8-dirty`, target `aarch64-apple-darwin`, Apple clang
21.0.0, eight-way split, CLI `-O0` and runtime `-O2`. The prior production
binary is preserved in scratch with its own receipt; it is not candidate
provenance. The first failed source freeze differs from the final freeze only
in the two corrected test files. Production code and compiler bytes did not
change during that follow-up.

The adjacent [packet manifest](discovery_body_coverage_2026-10-07/MANIFEST.json)
pins the durable payloads. It includes the worker TDD logs, integration
regression, separate first-failed and corrected importing-suite runs, exact
command receipts, all broad logs, candidate stop census, per-input transition
comparison and compact final provenance. Retained patches use lossless JSON
wrappers: decode their `content` field to a patch file and verify `raw_sha256`
before applying it. Freshness logs omit trailing empty lines in the durable
copies; their original terminal output remains in scratch.
`keyword-baseline.patch.json` reconstructs the baseline
over `a4a0c020e`; `candidate-from-head.patch.json` independently reconstructs
the final source/tests over that same HEAD. The full source-hash
snapshots and generated validation artifacts stay under
`/tmp/blorp-m4-parallel-2026-10-07/`; their identities and changed-input hashes
are retained in the compact provenance. Temporary worker worktrees are
archived as recoverable snapshots.

Static source and fixture review is complete; final evidence review and static
check results are recorded in the packet. No matched performance, allocation
or sanitizer probe was run for these parser increments, and no cost improvement
is claimed. M4's remaining coverage, rejected-module subset differential,
outcome cleanup and other exit criteria remain open.
