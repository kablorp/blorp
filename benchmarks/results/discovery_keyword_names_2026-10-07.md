# Discovery keyword-name contexts

This bounded M4 slice starts at `a4a0c020e2d8cb6146292def9bc23d3eb895c383`
and extends coverage in the frozen parser's keyword-name contexts. It changes the tree
parser's name role and selectors, with no production parser, lexer,
formatter, typechecking or language-design change. M4 remains open.

## Context boundary

| Context | Frozen rule retained by the tree parser |
| --- | --- |
| Primary value | `after`, `sealed`, `from`; `debug` only before an immediate dot |
| Other keyword primaries | `on` and `concurrently` have no value-name arm; `select`, `with` and `concurrent` enter their constructs |
| Ordinary binding and field names | All eight soft keywords; `from` remains reserved |
| Statement dispatcher | A named binding tail takes precedence over a keyword block |
| Initial record-literal field | An ordinary name followed immediately by `=` |
| `select` receive binder | Ordinary names, preserving the special `sealed` and `_ after` arm precedence |
| Tuple-destructuring lookahead | Its existing exclusion of soft-keyword heads remains |

`ExpressionName` represents the exceptional primary-name role of reserved
`from`. Only the explicitly selected primary arms use it; ordinary-name
rules are unchanged. Existing name consumers mint `NameUse` records and
intern the keyword spelling rather than guessing from source text. Soft
fields now use the ordinary record-literal/update path, including duplicate
field checking. Existing member access already consumes ordinary names.
The AST forms and legacy projection remain unchanged.

The statement dispatcher checks soft named binding tails first and then
routes through existing assignment, compound, question and typed binding
readers. Typed binding selection scans tokens with delimiter depth until a
top-level `=` or `?=`, matching the frozen parser. A line boundary, top-level
comma/colon or unmatched closer stops that lookahead. Var, loop, local-function
and with selectors admit the same ordinary soft names. This adds no source
position query, recipe, token replay, stop reason or expanded error recovery.
Rejected and unsupported trials retain their existing authority boundaries.
One pre-existing inline-case restriction remains: the match-arm guard declines
`_: debug: Int = 1` (and analogous select/concurrent typed bindings) as
`NestedBlockInCaseLine` before the statement dispatcher can read the binding.
This increment does not change that case-line guard or complete all keyword
construct coverage.

## Regression and fixture scope

The new context tests fail on the committed baseline: expression **50/51**,
expression projection **25/26**, and body projection **46/47**, with only
the new tests failing. The
[red log](discovery_keyword_names_2026-10-07/tdd-red.log) retains that evidence.
Tests cover accepted primary names and disallowed contexts, full legacy AST
JSON for all eight ordinary soft names, record literals/updates, binding
tails, var and loop binders, with binders, local functions and select arms.
They also pin name-use order, exact spans, dump/ID census, following owners,
reserved `from` roles, and unchanged tuple/block disambiguation.

The shared unread-value fixture previously used `after + Count(inner)`.
Its replacement is a one-line expression shaped as
`Count("${inner + Count(func(): 1)}")`. This keeps the real inner expression
and `Count` names, introduces no distinct binder/name, and reaches the
existing `LambdaInInterpolationHole` refusal. A narrow reproduction proves
the legacy parser accepts both a function and global containing it; a tree
test proves exact cursor, spelling and mint-authority rollback. No whitespace
padding is used. Stale declaration-owner unread fixtures use that same
boundary; newly supported dotted-debug and receive-binder cases get positive
coverage as their former negative fixtures move to remaining refusal paths.

## Final validation

| Validation | Result |
| --- | --- |
| Expert-focused suite union | 347/347 |
| Independent importing/owning union (14 suites) | 493/493 |
| Full `compiler-new` | 1,041/1,041 |
| Full `compiler-new-parity` | 3,620/3,620, zero AST mismatches |
| Code review | Zero findings; bounded slice approved |
| Hygiene, artifact scan and whitespace | Pass |

The independent union includes all seven importing suites selected by the
actual tree-only hand-back plan, the changed parser owners, and syntax-nesting
coverage. The installed compiler is FRESH before and after validation. The
normal serial gate invocation uses `scripts/test --no-build --serial
--log-dir /tmp/blorp-m4-soft-names-gates/final compiler-new compiler-new-parity`;
the census uses `scripts/compiler-new-parity --stop-census --census-file
/tmp/blorp-m4-soft-names-gates/candidate-stop-census.txt`. No configuration or
timeout override was needed. The [command records](discovery_keyword_names_2026-10-07/gate-commands.json)
retain the exact argv, working directory, environment, limits, logs and results;
[gate results](discovery_keyword_names_2026-10-07/gate-results.json) retain suite
counts and all parity summaries. The [static log](discovery_keyword_names_2026-10-07/static-checks.txt)
retains the hygiene/artifact checks. Production parser/build inputs did not
change, so the actual plan did not require `compiler-blorp` or a rebuild.
Tree sources are compiled into the test and parity artifacts.

Full-corpus parity compares 3,461 accepted modules, with 3,367 now assembled
and compared in full (baseline 3,299). Its prefix comparison covers 48,839
completed declarations: 37,483 functions, 131 traits and 658 implementations
with bodies. The 94 unread modules stop at 75 functions and 19 globals, with
no trait/implementation, rejected-owner or without-progress stops in this
accepted-module union. These are coverage/correctness counts, not claims
about rejected-module recovery parity or M4 completion.

## Matched census

The baseline is the clean committed builtin slice `a4a0c020e`. Its census was
reused only after checking exact identity of all 3,604 corpus paths/contents
and the four stopped benchmark dependencies against that committed tree.
The reused raw census retains its original embedded `42e9ed27a` label;
[baseline provenance](discovery_keyword_names_2026-10-07/baseline-provenance.json)
explicitly binds those identical inputs to `a4a0c020e` without rewriting the
historical label. [Baseline commands](discovery_keyword_names_2026-10-07/baseline-commands.json)
record the read-only build identity check. The candidate keeps the same path set: 3,591
inputs are byte-identical and thirteen source/test inputs are edited. The
four benchmark dependencies remain identical and Git-recoverable. No source
or path mutation occurred during validation.

| Baseline first stop | Baseline | Candidate transition |
| --- | --- | --- |
| `SoftKeywordName` | 47 | All 47 complete |
| `SoftKeywordFieldName` | 23 | 21 complete, two reach later `ValueOnNextLine` |
| Other owner/reason/location records | 92 | All 92 exactly unchanged |
| Total unread modules | 162 | 94 |

All seventy targeted first stops advance. Of the 68 newly complete modules,
67 have identical input bytes; one edited adapter fixture source completes.
The latter is recorded separately rather than attributed to parser-only
coverage. Both later-stop inputs are unchanged:
`blorp/test/test_cli/test_main.brp` moves from soft field at line 180 to
value-on-next-line at line 1,586; `blorp/test/test_lib/test_program_runner.brp`
moves from line 35 to line 226. There are no new stops, unrelated owner/reason
changes, unrelated location changes or line-only shifts. The
[comparison](discovery_keyword_names_2026-10-07/census-comparison.json) records
all seventy transitions, edited-input flags and exact non-target checks.
The [baseline census](discovery_keyword_names_2026-10-07/baseline-census.json)
and [candidate census](discovery_keyword_names_2026-10-07/candidate-census.json)
retain normalized records; both raw stop dumps are included in the packet.

The remaining first stops are `ValueOnNextLine` (31), `ConcurrentlyLoop` (29),
`OperatorAfterBlock` (22), `TokenAfterExpression` (5), `IndentedContinuation`
(4), and one each for `NestedBlockInCaseLine`, `LambdaInInterpolationHole`
and `LoopExitOutsideLoop`. The separately documented inline typed-soft
match-arm guard also remains. Grammar coverage, rejected-header/layout
recovery, rejected-module subset parity and unified outcomes keep M4 open.

## Provenance and retained evidence

[Source provenance](discovery_keyword_names_2026-10-07/source-provenance.json)
records each edited source/test baseline and candidate SHA-256.
[Final provenance](discovery_keyword_names_2026-10-07/final-provenance.json)
records unchanged inputs, compiler identity and the FRESH checks. The installed
production compiler's embedded label is `5fed50a38bf0`, distinct from the
frozen tree-parser baseline `a4a0c020e`; its unchanged SHA-256 is
`e7967dadb21329dce55ef8b99a7d7baa5528323f71c040b965cd9eacc70ee049`.
Toolchain: Apple clang 21, aarch64 macOS, eight-way split, CLI `-O0`, runtime
`-O2`. Edited tree sources are compiled afresh into validation artifacts.

The [packet manifest](discovery_keyword_names_2026-10-07/MANIFEST.json) hashes
the retained compact evidence. Complete gate logs and corpus manifests remain
under `/tmp/blorp-m4-soft-names-gates/`; committed baseline inputs are
recoverable from Git. Ordinary parity duration was 299.9 seconds and census
duration 162.5 seconds, retained only as validation execution records.
No matched performance/allocation probe was run and no cost improvement is
claimed.
