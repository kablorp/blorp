# Compiler Parameter Width Cleanup Findings

Status: completed initial mechanical audit

## Context

The static parameter-width triage scanned 294 compiler source files and reported
178 functions whose lexical body selected only one field from a compiler record
or struct with at least six fields. Ten isolated workers then checked concrete
call sites, aliases, visibility, phase boundaries, and ownership implications.

The triage is useful for discovery, but a one-field lexical use is not sufficient
evidence that a parameter is too broad. Passing a record value does not by itself
prove a copy or allocation, and a broad type can be the correct API when it owns a
phase, context, request, or invariant.

## Accepted Pattern

The highest-confidence changes had all or most of these properties:

- The helper is private.
- Its call graph is local and small.
- The selected field is already available at every caller.
- The helper remains meaningful when named after the narrower value.
- Narrowing does not split coupled identity, provenance, ownership, or policy data.
- The change removes a now-unused import, argument, or wrapper.

Examples include private list scanners over type-home tables, UFCS predicates over
function types, parser helpers that need only a source line, and Core helpers that
need only a variant list or function kind.

Private one-line or single-use wrappers were usually better deleted than renamed
around a narrower parameter. This removed wrappers in formatter projection,
tail-recursion entrypoint checks, Core flattening predicates, Perceus consumed
parameter lookup, and related local paths.

## Retained Pattern

Broad parameters were retained when they form a useful domain boundary:

- `Context`, `Env`, and `TypecheckState` public accessors
- CTFE context indexes
- `PerceusEnv` ownership policy and lookup helpers
- Core nodes passed to full transformation or emission steps
- CLI plans and LSP requests at public phase boundaries
- Resolved-call values that couple target identity with source-facing names
- Source spans used as coordinated identity or provenance inputs

Narrowing these APIs would mostly move field projection to callers, expose internal
representation, increase parameter count, or require callers to keep related
values synchronized. That is worse coupling, not less coupling.

One proposed public Perceus API narrowing was reverted during review for this
reason. One proposed LSP diagnostic helper narrowing was also reverted because it
turned two coherent parse/typecheck inputs into four scalar/list parameters and
new imports without reducing work.

## Validation Lessons

Focused source checks and compiler suites were more useful than broad gates for
these mechanical edits. Ownership-sensitive Perceus changes additionally ran
focused leak checks. Backend changes ran build-artifact, type-layout, and Core
emission suites.

No compile-time or runtime performance improvement is claimed for this tranche.
Most accepted changes improve dependency width and readability; they do not prove
that fewer values are copied or allocated. Performance claims require profiling a
production compiler workload.

## Batch Outcomes

| Area | Outcome | Main signal |
| --- | --- | --- |
| Parser, module surface, formatter | Accepted leaf narrowing and two wrapper removals | Source lines, optional bodies, and cleanup names were already available locally. |
| Type context and environment | Accepted 7 of 27 candidates | Private scanners and predicates narrowed cleanly; public lookup APIs remained coherent boundaries. |
| Typecheck state | Accepted 1 private scanner | The other 40 reviewed accessors intentionally encapsulate state internals. |
| Typecheck bridge, declarations, and headers | Accepted private scalar/list inputs and two wrapper removals | Public requests, accepted headers, module views, and definition-index boundaries remained broad. |
| Type inference | Accepted one wrapper removal; rejected one narrowing | Narrowing a captured option exposed a C-emission failure, so behavior-preserving source cleanup stopped there. |
| CTFE and Core lowering | Accepted local body/parameter/option narrowing and two wrapper removals | CTFE contexts, resolved-call provenance, and source spans remained coupled domain values. |
| Core transforms | Accepted variant, function-kind, and trait-target narrowing plus wrapper removal | Full plans, reachability indexes, and exported reuse APIs remained broad. |
| Perceus | Accepted private consumed-parameter narrowing and two inlinings | A proposed public `CoreFunction` boundary change was reverted; ownership policy remains in `PerceusEnv`. |
| Backend | Accepted private emitter/build helper narrowing | Public artifact, layout-registry, Core-node, and program emission boundaries remained unchanged. |
| CLI and LSP | Accepted private mode/source/configuration narrowing | Public plans, requests, workspaces, and diagnostic conversion boundaries remained unchanged. |

The uneven acceptance rate is useful evidence. The static scan is effective at
finding review sites, but most hits in stateful compiler subsystems are deliberate
encapsulation rather than excess data flow.

## Rough Edges Found

### Narrow closure capture fails C emission

In `infer.brp`, changing a private UFCS retry helper from an `OverloadEntry` to its
`Option[String]` module path remained source-type-correct. Capturing that narrower
option in the existing `List.filter` closure then failed during C emission, while
capturing the original record succeeded. A mutable append loop compiled, but was
rejected as unrelated workaround code. The narrowing was therefore not retained.

This should become a minimized compiler regression covering closure capture of an
`Option[String]` in a generic list predicate.

### Formatter projection suppresses interpolation errors

Formatter projection parses interpolation expressions but can replace a failed
projection with literal text. The cleanup added exact source-path provenance
coverage at source-AST finalization, where malformed interpolation diagnostics are
observable. Whether formatter fallback should suppress those errors is a separate
API/behavior question.

### External source checks are not always fast feedback

Checking large compiler modules individually can take minutes and may provide less
signal than focused implementation suites. Future mechanical audits should prefer
small behavior suites, one final integrated self-host build, and only source checks
that validate a boundary not already exercised by those suites.

## Recommended Follow-up

1. Add the minimized narrow closure-capture C-emission regression before retrying
   the rejected infer narrowing.
2. Extend static triage with visibility, call count, and helper body size. Rank
   private single-use one-line functions first.
3. Detect wrappers that only project fields into another call; recommend inlining
   rather than mechanically changing the signature.
4. Add a separate dead-field audit based on constructor writes and field reads.
5. Look for records always constructed and consumed together, duplicated indexes,
   and paired records with identical lifetime before proposing data-model merges.
6. Use profiling and allocation counters to find record reconstruction in hot
   loops. Parameter width alone is not a reliable performance proxy.
7. Preserve explicit allowlists for public phase/domain APIs so future automated
   cleanup does not repeatedly propose representation-leaking changes.

## Automation Guidance

A future fixer should only auto-apply when the function is private, non-recursive,
not a callback, has one local call site, and either becomes an obvious expression
at that site or has a narrower parameter already present there. All other findings
should remain review suggestions. Source typechecking is not enough: generated-C
or focused runtime compilation must still pass.
