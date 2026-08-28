# Exact Non-Member Completion

**Status:** Blocked on a compiler-owned completion-hole visibility projection

## Context

The LSP has an analysis-completion lifecycle, but no protocol completion
capability. `SemanticIndexSnapshot` contains exact definitions and occurrences;
it does not assert that every indexed definition is visible at a source
position. Selective imports, qualification, privacy, prelude injection, lexical
shadowing, and incomplete source are compiler-owned rules.

This issue is deliberately limited to non-member completion. A dot after an
expression requires the receiver's resolved type plus field, method, trait, and
UFCS candidate facts and belongs to Issue 05.

## Goal

Add `textDocument/completion` for keywords and exactly visible non-member
symbols that can be projected from existing compiler facts without changing the
compiler. Supported semantic categories may include modules, types,
constructors, functions, and globals only after the visibility audit proves
each category.

Omit a category rather than approximating it. Completion during incomplete or
erroneous source must be deterministic and must not reuse a stale snapshot as
if it were current.

## Mandatory Visibility Audit

Before production edits, document every existing compiler/LSP fact used to
answer:

- which module owns the candidate;
- whether it is public or private at the request site;
- whether an import is bare, selective, aliased, or qualified;
- whether prelude or lexical scope introduces the name;
- whether a same-name declaration shadows it; and
- whether the current source position changes the visible set.

If these cannot be established exactly from retained compiler outputs, stop and
consult the coordinator. Do not parse imports again, infer visibility from
names, enumerate all index definitions as candidates, or change compiler
representations within this issue.

## Visibility Audit Result

The audit found that exact semantic non-member completion is not available from
the retained LSP snapshot. The compiler temporarily owns some relevant
module-level facts in `TypecheckedGraph`, but the LSP semantic projection keeps
only definitions, references, and capability metadata. Neither retained
product maps an arbitrary source position to the active lexical bindings or
the binding that wins compiler lookup.

| Candidate category | Authoritative facts that exist | Exact visibility and precedence rules | Exact from the retained snapshot? | Missing compiler fact |
| --- | --- | --- | --- | --- |
| Module aliases | Parsed imports distinguish bare, selective, and aliased forms. Accepted typed modules retain qualified module bindings from local alias to canonical module path. Frontend import edges retain requested path to canonical module resolution. | A non-selective import registers its explicit alias or default final path component. A selective import registers no module alias unless one is explicit. Module aliases conflict with local top-level names and selective names during module-view construction, then lexical bindings can shadow the accepted alias at the request site. | No. The semantic snapshot retains only the resolved dependency edge, not the accepted import binding, and neither product retains request-site lexical precedence. | Active bindings at the completion hole, including the winning local name, binding kind, source extent, and canonical module identity. |
| Functions | Module surfaces distinguish exported and private functions. Semantic occurrences carry stable exported or artifact-local identities. Accepted selective import bindings retain local alias, module path, and source name. | Current-module declarations and accepted selective imports are module-visible. Private dependency functions are rejected. Lexical scopes are searched from innermost to outermost, and later same-scope definitions take precedence. | No. Enumerating module surfaces or indexed definitions would include shadowed or otherwise unavailable candidates and could report the wrong kind for a duplicate label. | The active lexical function/value bindings and exact duplicate-label winner at the request position. |
| Globals | Module surfaces, semantic occurrences, and accepted selective bindings provide the same module-level facts as functions. | Privacy, selective import, module conflict, and lexical shadowing rules are the same value-namespace constraints that govern lookup. | No. Module-level acceptance does not prove visibility at an arbitrary request position. | The active lexical value bindings and exact duplicate-label winner at the request position. |
| Types, records, aliases, and traits | Module surfaces distinguish exported and private type-like names. Typed type definitions and semantic occurrences carry compiler identities. Accepted selective bindings and module-view type facts prove module-level import acceptance. | Private dependency declarations are unavailable. Local declarations, lexical type parameters, explicit imports, implicit prelude types, and compiler intrinsic fallback affect lookup and precedence. | No. The retained semantic index has no request-site type namespace or active type-parameter projection. | Active value/type namespaces at the completion hole, including type parameters, prelude/intrinsic provenance, and the exact shadow winner. |
| Constructors | Semantic occurrences carry constructor definitions and identities. The compiler's module view owns imported-constructor bindings while union projection applies constructor precedence. | Explicitly selected constructors take precedence over constructors exposed through an imported union. Privacy, selection, aliasing, and lexical shadowing still apply. | No. Accepted `TypecheckedModule.import_bindings` does not project imported-constructor bindings, and the LSP snapshot does not retain them. | Explicit visible constructor bindings, parent union provenance, precedence, and request-site lexical visibility. |
| Prelude names | Prelude injection is compiler-owned. It filters imports against local top-level names, merges them with user imports, and contributes accepted module bindings during typechecking. | Local top-level declarations suppress conflicting prelude imports. User imports can merge with prelude imports. Some prelude and intrinsic types also use compiler-known fallback rules. | No. The retained snapshot does not identify which prelude bindings survived injection or whether a lexical binding shadows them at the request position. | Active prelude and intrinsic bindings in the completion-hole projection, with provenance and precedence already resolved. |
| Keywords | Lexer tokens and the formal grammar are authoritative for the language vocabulary. | Which keyword is valid depends on parser state and token context. The completed parser artifact and diagnostics do not retain parser state at an arbitrary source offset. | Only a context-free list is possible. That is not exact contextual completion. | A parser-owned completion context at the request offset, or another exact grammar-context projection. |

Incomplete or erroneous source cannot reuse the last successful typed graph:
workspace invalidation marks the semantic index stale, and failed analysis may
leave it unavailable. A completion query must therefore receive a current
projection for the edited source or return an honest empty/unavailable result.
It must never recover names from the stale index.

### Rejected Keyword-Only Endpoint

A protocol-complete endpoint returning a small unconditional keyword subset
was considered and rejected. It would advertise completion while returning a
context-free, arbitrary subset, suggest invalid tokens in many positions,
duplicate the grammar vocabulary in the LSP, and add protocol and actor surface
without advancing exact semantic completion. Keyword support should be added
only when compiler-owned parser context can establish useful candidates.

### Smallest Compiler Contract That Unblocks This Issue

The compiler must expose one immutable completion-hole projection keyed by the
current source identity and compiler source offset. The LSP can map its UTF-16
request position to that offset from the same current source snapshot. The
projection must:

- prove that it was produced from the current source/configuration snapshot;
- carry the active local, module, imported, prelude, and intrinsic bindings;
- retain stable symbol identity, completion kind, insertion label, and owning
  module for every candidate;
- resolve private declarations, bare/selective/aliased/qualified imports,
  constructor selection, and duplicate-label precedence before projection;
- include source extents or an equivalent compiler proof for lexical scope and
  shadowing; and
- state whether the candidate set is complete, unavailable, or incomplete
  because the edited source could not be analyzed.

The LSP can then sort and encode this compiler-owned candidate set without
reconstructing compiler policy. The contract need not expose private `Env` or
`Scope` representation, and it must not require the LSP to parse imports or
scan every indexed definition.

This contract covers non-member names only. Completion after a dot still needs
the receiver's resolved type plus field, method, trait, and UFCS candidates and
remains separately blocked under Issue 05.

## Required Behavior Once Unblocked

- Keyword candidates are grammar-owned and context filtered by an exact
  parser/token projection for the request position.
- Semantic candidates carry stable kind, label, insertion text, and an explicit
  deterministic sort key.
- Duplicate labels follow compiler lookup/visibility precedence exactly.
- Private, qualified-only, and unselected imports do not leak into bare-name
  completion.
- Stale snapshots return an honest empty/unavailable response, never old names.
- No completion item requires resolving private `Env` or `Scope` state in LSP.

## Future TDD Contract

Establish failing tests for keywords; local module public/private declarations;
bare, selective, aliased, and qualified imports; prelude names; duplicate and
shadowed names; incomplete source; stale analysis; deterministic ordering; and
UTF-16 request positions. Every supported category needs a positive and a
negative visibility case.

Keep the implementation organized as a completion capability/query pair and a
small visibility projection only if the audit establishes one. Do not mix dot
completion into the protocol handler.

## Validation And Handoff

Run focused analysis/capability/protocol/actor suites,
`scripts/compiler-check --changed`, and `scripts/test lsp`. Report the exact
supported category set and every omitted category with its missing compiler
fact. Do not merge, push, or begin typed member completion.
