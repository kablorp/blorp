# Discovery M4: opaque conversions (2026-10-07)

The tree expression parser now constructs `into_opaque Type(value)` and
`from_opaque Type(value)` using the existing syntax variants. Written-type
children finish first, value children next, and the conversion expression last.
The value uses its own first-token layout anchor. The iterative legacy
projection translates type names before value names and preserves the frozen
AST and source spans.

The ordinary written-type parser remains responsible for types. If it adds a
diagnostic, the conversion is rejected rather than accepting recovery syntax.
Unsupported trials restore the entire saved entry; rejected expressions retain
diagnostics and spellings while restoring mint authority. Each conversion
counts one nesting level, and written types retain their existing levels.
No recipe, replay, new stop reason or general rejection recovery is introduced.
The historical opaque-conversion stop label remains for later cleanup.

This slice covers existing grammar on the test-only tree path. It corrects the
formal grammar's narrower conversion-type production to match the frozen
parser's ordinary type reader; semantic restrictions on the target remain in
typechecking. The owning design and remaining milestone criteria are in
[`DISCOVERY_REDESIGN.md`](../../docs/DISCOVERY_REDESIGN.md), sections 3.14,
3.16 and 8. No performance claim is made, and no existing shared parsing helper
is refactored for this increment.

## Baseline and evidence scope

The baseline is clean commit `9be48e8fafb6d07a9e2e1239a688bb3c4bc1ff0b`.
Repository `bin/blorp` is `FRESH`; these tree-path sources are compiled into
tests and do not change the executable's production inputs. All 3,603 live
corpus paths and byte hashes exactly match the committed tuple slice's
candidate manifests, so its census is reused with an explicit
[baseline binding](discovery_opaque_conversions_2026-10-07/baseline-provenance.json).
The census's embedded earlier base label is preserved. It has 346 stops:
301 function bodies, 26 global initializers and 19 implementations; 128 first
stop at opaque conversions.

Complete baseline paths/content hashes and raw census remain in
`/tmp/blorp-m4-opaque-baseline/`. The committed
[tuple evidence packet](discovery_tuple_destructuring_2026-10-07/MANIFEST.json)
retains the exact reused source manifests and census. This packet keeps the
comparison and changed-source provenance rather than duplicating those full
manifests.

Four stopped benchmark dependency inputs sit outside the enumerated corpus
root paths. Their exact bytes are separately recovered from the baseline
commit and compared with the candidate; all four remain identical. The
[source provenance](discovery_opaque_conversions_2026-10-07/source-provenance.json)
records those hashes so the stop comparison covers the complete record
population as well as the 3,603 root inputs.

## Focused regressions

Before implementation, the expression suite passes 41/44 checks and the
projection suite 23/24: the new conversion acceptance, direct-ID/rollback and
projection regressions fail while the existing cases pass. The [red log](discovery_opaque_conversions_2026-10-07/tdd-red.log) is retained
in the compact packet.

The final focused checks pin both directions, type-before-value name-use IDs,
post-order expression IDs, exact owner/type spans, generic and qualified
names, grouped/tuple/function/void/dimension/array written types, nested
conversions, ordinary operators/postfix composition and bracket-joined values.
These broader type forms match the frozen parser's AST; their acceptance as
syntax does not assert that typechecking permits them as opaque targets.

Multiline lambda, `if` and `match` values use their own token anchor and leave
the following owner intact. Global, function, trait and implementation bodies,
interpolation holes and tuple-destructuring RHS values project in agreement
with the frozen parser. A chain of 127 simple conversions reaches nesting
level 128 through its final written type and passes parsing, dump, census and
legacy projection; 128 conversions exceed the combined limit and are rejected.
The language's existing limit remains 128.

Unsupported inner builtin/unexpected-token trials restore the exact entry.
Missing conversion delimiters retain their existing rendered message, help and
span while discarding trial IDs. A malformed type that produces recovery
syntax must yield `RejectedExpression` with the exact `expected type` message,
help and empty comma-position span, with trial definition and ID authority
restored to the entry.
The older unread-body tests now use builtin bodies to preserve their header and
rollback assertions. The lexer-priority fixture retains its exact bytes and
diagnostic offsets and is renamed to describe the now-supported conversion.

Independent importing validation initially passes 454 checks and fails 21,
all in the adapter suite. Each failing test calls the same `unread_value`
helper, which previously used a now-supported opaque conversion as its stop.
The helper is migrated to `builtin + Count(inner)`: the frozen parser still
reads the actual body-only names and inner expression, while the tree stops
before them at the unread builtin. Name-exclusion, boundary, span, header and
rollback assertions remain meaningful. The [classification](discovery_opaque_conversions_2026-10-07/adapter-fixture-classification.txt)
accounts for all 21 failures. The direct successful conversion
fixture stays unchanged, and a separate completed-global conversion case
checks full AST and source-order name-table equality. This is a test fixture
migration; no parser or projection change follows the initial freeze.

The final independent focused/importing union passes **476/476**: 124 adapter
checks after the fixture migration and 352 checks in the thirteen other
suites. Reuse of those green suites follows exact byte-hash verification that
only the adapter test changes after their run; parser and projection source
hashes stay frozen. The initial 21 failures remain recorded separately from
final green results.

## Independent gates and coverage

| Gate | Passed | Failed |
| --- | ---: | ---: |
| Focused and importing suites | 476 | 0 |
| `compiler-new` | 1,031 | 0 |
| `compiler-new-parity` | 3,619 | 0 |

Full corpus parity assembles and compares 3,236 of 3,460 accepted modules,
versus 3,114 at baseline, with zero mismatched files. The 224 remaining unread
modules stop in 185 function bodies, 20 global initializers and 19
implementations. The completed prefix now contains 45,992 declarations,
including 35,098 functions, 124 traits and 381 implementations; baseline
prefix totals are 40,074 declarations and 30,207 functions. These results
retain the gate's existing rejected-module allowances and do not close M4's
rejected-module subset criterion.

The parity gate takes 676.6 seconds in this validation run. Covered work
differs from the prior slice; this unpaired validation latency is retained in
the command records and is not used as a performance comparison. The full
stop census takes 348.1 seconds, also recorded only as validation latency. No profiler,
allocation probe or timeout workaround is added for this coverage increment.

## Matched stop census and final provenance

The [comparison](discovery_opaque_conversions_2026-10-07/census-comparison.json)
retains 3,603 root paths: 3,590 byte-identical inputs and thirteen edited
source/test inputs, with no additions or deletions. All 128 former opaque-first
stops advance. Of these, 122 modules no longer stop, all in unchanged inputs:
118 enumerated roots and four benchmark dependencies. Six unchanged inputs reach later
reasons: three soft keyword names, one soft keyword field, one builtin body and
one operator after a block. The opaque-conversion reason count is zero.

All 218 prior non-opaque owner/reason mappings remain unchanged. The only
unrelated location shift is in the edited adapter test, from line 2,510 to
2,529. The six later stops move forward in their unchanged inputs; every
other unchanged-input location matches baseline. No unrelated mapping changes,
new stopped modules, source mutation or path-set mutation occur. The comparison lists
individual transitions and the candidate raw census hash. Complete root
manifests and raw census remain under `/tmp/blorp-m4-opaque-gates/`.

The [final provenance](discovery_opaque_conversions_2026-10-07/final-provenance.json)
records all thirteen changed-source hashes, the four dependency hashes,
compiler/toolchain/target identity and `FRESH` status before and after validation.
The installed compiler SHA256 remains
`e7967dadb21329dce55ef8b99a7d7baa5528323f71c040b965cd9eacc70ee049`;
its embedded production label `5fed50a38bf0` is distinguished from the frozen
parser baseline `9be48e8fa`. The tree sources are compiled into the tests and
comparison tools using that unchanged repository executable.

The exact [gate commands](discovery_opaque_conversions_2026-10-07/gate-commands.json)
record argv, working directories, environment, timeouts, durations, log paths
and exit statuses, including the initial stale-fixture failure. The
[gate results](discovery_opaque_conversions_2026-10-07/gate-results.json) and
[passing-suite reuse](discovery_opaque_conversions_2026-10-07/passing-suite-reuse.json)
keep final green outcomes separate from the initial failure and bind reused
checks to unchanged source bytes. The actual import plan is tree-only;
`compiler-blorp` and an executable rebuild are not required. No premerge/default
switch claim is made.

Repository [hygiene and artifact checks](discovery_opaque_conversions_2026-10-07/static-checks.txt)
and whitespace checks pass. Source/test review reports zero findings. M4 remains open for builtin and other grammar,
rejected-header recovery/layout ownership, rejected-module subset parity and
final outcome unification. The remaining largest stop reason is builtin body
(64 modules); this increment does not implement it.
