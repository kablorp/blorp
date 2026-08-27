# Native LSP Stage

The production LSP is a serialized actor around immutable workspace snapshots.
`server/server_actor.brp` owns lifecycle admission, document revisions, analysis
coalescing, and stale-completion rejection. `server/native_server.brp`
interprets the actor's effects and is the only process composition root: the
reader, analysis worker, and writer communicate with the actor through typed
channels.

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
definitions and references in closed dependencies remain unavailable until
dependency indexing is added. A query returns JSON `null` when its position has
no indexed compiler identity or when the required snapshot coverage is
incomplete; an empty list is reserved for a complete query with no matching
occurrences. Document symbols and the current semantic projection support
top-level functions, globals, types, constructors, and fields; locals,
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

The analysis worker currently rejects stale work at publication time. The pure
compiler frontend is not cooperatively interruptible, so cancellation effects
must not be described as stopping a running compiler call until shared compiler
checkpoints exist.

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
does not retain speculative queues or tokens for document effects.
