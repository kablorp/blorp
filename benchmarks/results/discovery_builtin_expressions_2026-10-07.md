# Discovery builtin-expression coverage

This bounded M4 slice starts at `42e9ed27a851a805e248dd918b512b082f8a4c15`
and reads the existing `builtin` and `builtin("name")` expression forms.
The production parser, lexer, formatter and typechecker are unchanged.
M4 remains open.

## Construction and compatibility boundary

The expression parser directly mints the existing
`CompilerBuiltin(Option[String])` leaf. Bare `builtin` carries `None`; an
empty marker carries `Some("")`. A marker is token metadata, so its
parentheses add no expression nesting level, child expression, name use or
hole ID. The span runs from the keyword through the closing parenthesis,
or covers only the keyword for the bare form. Normal postfix and operator
composition follow the leaf. The iterative legacy expression walk projects
it directly to `ParsedBuiltinExpr`, leaving the name table unchanged.

The frozen parser accepts quoted, raw, pipe and raw-pipe string markers.
It also accepts interpolated quoted and pipe tokens as static text: it
does not parse or evaluate their holes. For example, a marker written
`"start ${value} end"` is stored as `"start {value} end"`. Quoted prefixes
and tails have distinct escape handling in the old lexer; rebuilding the
marker from decoded interpolation pieces alone would lose that distinction.
The 79-line parse-owned `builtin_marker_text.brp` helper reconstructs the
frozen text from immutable source evidence. A narrow current-token accessor
in `ParseState` supplies that text. Pipe markers reuse the existing segment
and line-joining rules. This adds no lexer metadata or algorithm change,
hole parsing, recipe or replay by token index.

Docstrings are excluded by token kind. Malformed markers use the existing
`ExpectedBuiltinNameDiagnostic` and `RightParenInBuiltinName` diagnostics,
including soft-boundary recovery and first-diagnostic order. Rejected public
expressions retain diagnostics and discard trial mint authority; unsupported
trials restore the exact saved entry. No stop reason is added. The historical
`BuiltinBody` enum/label remains until M4 outcome cleanup, but the expression
start classifier now admits builtin atoms.

## Regression and fixture scope

The initial tests fail against the committed parser: expression **45/46**
and expression projection **24/25**, with only the new builtin tests failing.
The [red log](discovery_builtin_expressions_2026-10-07/tdd-red.log) retains
that behavioral evidence. The final expert-focused union passes **413/413**.

Tests pin leaf IDs, empty versus absent markers, exact spans and full legacy
AST JSON for all marker forms. Interpolated payload cases include UTF-8,
prefix/tail escapes, Unicode escape spelling, literal braces, later holes,
nested holes and quotes, and pipe joining with doubled pipe markers. They
also cover globals, expression/block bodies, traits, implementations,
postfix composition and interpolation-hole context. Marker error tests check
message, help and empty diagnostic span, with no trial IDs. Builtins under
128 grouping levels survive parsing, dumping, ID census and projection;
129 levels reject. Marker parentheses spend no extra nesting level.

The adapter's unread-value fixture previously used `builtin + Count(inner)`.
It now uses the frozen soft-keyword name `after + Count(inner)`, retaining
the real `Count` and inner expression tokens. The two-byte prefix reduction
requires no assertion, snapshot or literal-offset edits: all 21 existing
boundary/name assertions still pass. Other stale unread builtin fixtures
use `after("raw")`; the successful builtin fixtures remain. A new positive
adapter case checks full AST equality and exclusion of marker-only text
from the name table. These temporary unread fixtures still need replacement
as later M4 coverage reaches their grammar.

## Final validation

| Independent check | Passed | Failed |
| --- | ---: | ---: |
| Focused/importing union, 14 suites | 486 | 0 |
| Full `compiler-new` | 1,037 | 0 |
| Full `compiler-new-parity` | 3,620 | 0 |

Full parity reports zero mismatched files. Accepted corpus modules assembled
and compared in full rise from **3,236/3,460 to 3,299/3,461**; unread modules
fall from **224 to 162**. The extra accepted input is the new marker helper;
the other 62 newly complete modules are existing inputs. The final remaining
owners are 141 functions and 21 global initializers, with no implementation
first stops. Completed prefix declarations rise from 45,992 to 47,592,
including 36,312 functions, 131 traits and 658 implementations with bodies.
These are coverage counts, not performance evidence. Existing rejected-module
allowances remain; this gate does not close M4's rejected-module subset check.

The actual import plan is tree-only. The repository executable is `FRESH`;
tree code is compiled into the test and comparison artifacts rather than the
installed executable. Neither `make` nor `compiler-blorp` is required by this
hand-back plan. No premerge/default-switch claim is made. Normal full parity
takes 443.6 seconds and the serial broad-gate invocation 512.8 seconds;
these are unpaired validation durations with changed coverage. No speed,
allocation or retained-byte claim is made.

Repository hygiene, artifact scan and whitespace checks pass.
Source/test and GUIDE/GRAMMAR review reports zero findings. The
[static-check log](discovery_builtin_expressions_2026-10-07/static-checks.txt)
retains the hygiene and artifact results.

## Matched census and provenance

The baseline census is bound to committed `42e9ed27a` only after proving
exact input identity against the prior opaque slice's final snapshot. Its
original embedded label `9be48e8fa` is retained in the
[baseline census](discovery_builtin_expressions_2026-10-07/baseline-stop-census.txt);
the [baseline provenance](discovery_builtin_expressions_2026-10-07/baseline-provenance.json)
records the explicit binding. The baseline has 3,603 enumerated paths and
224 stops. The final corpus has 3,604 paths: 3,589 byte-identical surviving
inputs, fourteen edited inputs, and one new helper. There are no deletions.
Four prior benchmark dependencies outside that root enumeration are checked
separately against baseline Git bytes and remain identical.

The full [candidate census](discovery_builtin_expressions_2026-10-07/candidate-stop-census.txt)
and [per-module comparison](discovery_builtin_expressions_2026-10-07/census-comparison.json)
show that all **64** former builtin-first stops advance. **62** unchanged
existing inputs no longer stop; two unchanged inputs reach later grammar:

| Input | Baseline stop | Later stop |
| --- | --- | --- |
| `blorp/src/test/command.brp` | function/builtin-body, line 86 | global initializer/soft-keyword-field-name, line 181 |
| `standard_library/src/memory.brp` | function/builtin-body, line 124 | function/soft-keyword-name, line 258 |

All **160** prior non-builtin owner/reason/location records remain exactly
unchanged, including the edited inputs. No new stopped modules, unrelated
mapping or location changes, source mutation or path-set mutation occur.
The new helper has no first stop. Final census duration is 436.3 seconds,
recorded only as normal validation latency.

Remaining ranked reasons are soft-keyword-name **47**, concurrently-loop
**29**, value-on-next-line **29**, soft-keyword-field-name **23**,
operator-after-block **22**, token-after-expression **5**,
indented-continuation **4**, and one each for nested-block-in-case-line,
lambda-in-interpolation-hole and loop-exit-outside-loop. Builtin-body is zero.
Soft-keyword names and field names are the next coherent grammar boundary;
recovery and outcome cleanup remain separate required M4 work.

The [source provenance](discovery_builtin_expressions_2026-10-07/source-provenance.json)
and [final provenance](discovery_builtin_expressions_2026-10-07/final-provenance.json)
bind all fifteen changed/new Blorp files to validation, along with corpus and
dependency hashes. The repository compiler is `FRESH` before and after, and
its SHA256 stays
`e7967dadb21329dce55ef8b99a7d7baa5528323f71c040b965cd9eacc70ee049`.
Its embedded production build label `5fed50a38bf0` is distinct from the
frozen tree-parser baseline `42e9ed27a`. Toolchain: Apple clang 21.0.0,
`aarch64-apple-darwin`, CLI `-O0`, runtime `-O2`, eight-way split.

The [gate results](discovery_builtin_expressions_2026-10-07/gate-results.json),
[gate commands](discovery_builtin_expressions_2026-10-07/gate-commands.json)
and [baseline commands](discovery_builtin_expressions_2026-10-07/baseline-commands.json)
retain exact argv, working directories, environment, timeouts, durations,
log paths and return statuses. All final compiled checks run serially with
normal limits. The shortest loop is the expression parser and expression
projection suites; hand-back adds every importing/changed owning suite and
`scripts/test --no-build --serial compiler-new compiler-new-parity`, followed
by `scripts/compiler-new-parity --stop-census`. Full logs and corpus manifests
remain under `/tmp/blorp-m4-builtin-gates`; normalized/raw stop censuses are
also retained in this compact packet. The
[manifest](discovery_builtin_expressions_2026-10-07/MANIFEST.json) hashes all
thirteen payloads. No runtime performance or allocation probe is claimed.
