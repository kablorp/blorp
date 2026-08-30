# Native LSP Stage

The production LSP is a serialized actor around immutable workspace snapshots.
`server/server_actor.brp` owns lifecycle admission, document revisions, analysis
coalescing, and stale-completion rejection. `server/native_server.brp`
interprets the actor's effects and is the only process composition root: the
reader, two purpose-specific analysis workers, and writer communicate with the
actor through typed channels. Workspace-index work retains the complete
declared target set on a background lane. Interactive-document work roots only
the current open module on a separate lane, so its diagnostics and local index
do not queue behind the non-cooperative workspace compiler call when the runtime
has at least two carrier threads. With `BLORP_THREADS=1` or only one available
carrier, both fibers necessarily share that carrier and interactive latency is
not isolated. Purpose is an explicit part of plan, request, token schedule,
completion identity, and commit admission; target count never selects a lane.

`analysis/architecture.brp` contains only data contracts shared by those live
paths: workspace transitions, analysis plans and requests, target outcomes, and
the completion commit boundary. Protocol wire types stay in `protocol/`; the
definition, document-symbol, document-highlight, references, and hover query
models are kept in `capabilities/` beside their wire codecs and resolve only
compiler-issued semantic identities from an immutable workspace snapshot.
`capabilities/query_dispatch.brp` is the shared typed admission boundary for
those codecs; unhandled envelopes are handed back to document dispatch without
a second method-name check. Document symbols are local to the requested module
and remain available when dependency projection is incomplete;
workspace references include closed declared user modules only when the
workspace holds a snapshot-scoped completeness proof. A query returns JSON
`null` when its position has no indexed compiler identity or when that proof or
the required capability coverage is unavailable; an empty list is reserved for
a complete query with no matching occurrences. Definitions use the same exact
identity across selective imports and can return an unopened provider file for
top-level functions, globals, types, constructors, and fields. Document symbols
and the current semantic projection support those same categories; locals,
parameters, methods, and foreign declarations remain unavailable for
definition/reference identity queries until their compiler identities are
projected explicitly.

`lsp_stdio_transport.brp` remains at the stage root even though it is interpreted
by `server/native_server.brp`: the bootstrap compiler binds its native stdio
operations by path-derived module identity.

Document highlights use the same exact identity and occurrence index, but remain
local to the requested module and the currently projected top-level symbols:
functions, globals, types, constructors, and fields. Local variables, parameters,
type parameters, methods, and foreign declarations remain future compiler
projection work. Highlights return sorted ranges without a read/write kind because
occurrence classification is not yet a compiler-owned fact.

Hover currently resolves the exact indexed symbol and returns the compiler-owned
typed declaration display as plaintext markup with the declaration selection
range. The typecheck stage produces that display from resolved semantic types;
the LSP does not reconstruct or guess an inferred type. Function hovers expose
the resolved callable type; globals and fields expose their resolved value type;
constructors include their parent and resolved payload types. Nominal type
hovers currently provide the compiler-owned type label, while generic bounds,
full record/union/alias bodies, and foreign declarations remain later display
extensions rather than being synthesized by the LSP.

The actor executes each accepted semantic query synchronously from exactly one
local immutable workspace snapshot. It extracts the semantic index once before
dispatching to the definition, document-symbol, references, hover, or highlight
implementation, so query code cannot read actor-owned workspace state in pieces.

## Shared semantic query contract

`analysis/semantic_query.brp` is the capability-independent read boundary for
semantic editor features. Definition, references, hover, document highlights,
and document symbols use it rather than matching index lifecycle and coverage
states independently.

A `SemanticQuerySession` proves that one semantic index is current and contains
the requested document. It retains only the immutable index snapshot and target
module index; it does not expose compiler `Env`, `Scope`, or typed-graph state.
Reference queries select one explicit extent:

- `TargetDocumentSemanticQuery` permits exact target-local facts even when
  dependency projection is partial.
- `IndexedDocumentsSemanticQuery` requires complete capability coverage across
  the index producer's declared document set.

`WorkspaceSemanticQueryAdmission` is the distinct workspace-exhaustive path.
The workspace can derive it only from `WorkspaceSnapshotSemanticCompleteness`,
whose sole constructor re-derives the deterministic declared target set from
the immutable compiler source store and validates every final indexed, partial,
or explicitly missing outcome. Missing or partial outcomes remain accounted
for but block exhaustive references; ordinary indexed-document semantics are
unchanged.

Contract results distinguish unavailable, stale, unindexed-document,
unsupported-capability, and incomplete-coverage states.
`semantic_query_definition_or_absence` names its asymmetric guarantee
explicitly: an exact definition already present in the snapshot may be returned
under partial coverage, while an absent result is returned only when indexed
coverage for that symbol category is complete. Exhaustive reference results
also require complete coverage for their requested extent.

The contract exposes exact definitions for the target document to support
document symbols. It does not enumerate workspace candidates or describe
definitions as visible at a source position: selective imports and other
compiler-owned visibility facts are not retained in the semantic snapshot.
Completion must consume a separate exact visibility projection.

The two analysis workers reject stale work independently at publication time.
Only a workspace-index completion can originate snapshot completeness;
interactive completion may preserve an already proved immutable revision but
cannot fabricate its proof. The pure compiler frontend is not cooperatively
interruptible, so cancellation effects retire actor tokens but do not stop a
running compiler call. The shutdown request retires both actor schedules; the
later process exit seals both request lanes and does not join their detached
workers.

The native process treats clean stdin EOF before `initialize` as a successful
shutdown. EOF after a partial frame, or after protocol work has begun without a
valid shutdown, remains a failure so transport and lifecycle errors are visible.

Graph-wide analysis failures can occur before target-level diagnostics exist.
The workspace commit boundary returns an empty, current-revision publication
for each target in that case, and the actor publishes those replacements rather
than leaving diagnostics from an older revision visible. The same replacement
rule applies when planning or completion validation fails. No source range is
invented for a failure that has no defensible source location.

Document filesystem effects are currently interpreted synchronously by the
native composition root. Open resolution and saved-source refresh completion
events are applied before the process returns to the event loop, so the actor
does not retain speculative queues or tokens for document effects. The native
process has no filesystem watcher: completeness describes the last explicitly
loaded or refreshed immutable source snapshot, not live-disk freshness.
