# Native LSP Stage

The production LSP is a serialized actor around immutable workspace snapshots.
`server_actor.brp` owns lifecycle admission, document revisions, analysis
coalescing, and stale-completion rejection. `native_server.brp` interprets the
actor's effects and is the only process composition root: the reader, analysis
worker, and writer communicate with the actor through typed channels.

`architecture.brp` contains only data contracts shared by those live paths:
workspace transitions, analysis plans and requests, target outcomes, and the
completion commit boundary. Protocol wire types stay in their protocol modules;
the definition, document-symbol, document-highlight, references, and hover query models are kept beside
their wire codecs and resolve only compiler-issued semantic identities from an
immutable workspace snapshot. `query_dispatch.brp` is the shared typed
admission boundary for those codecs; unhandled envelopes are handed back to
document dispatch without a second method-name check. Document symbols are
local to the requested module and remain available when dependency projection
is incomplete;
definitions and references in closed dependencies remain unavailable until
dependency indexing is added. A query returns JSON `null` when its position has
no indexed compiler identity or when the required snapshot coverage is
incomplete; an empty list is reserved for a complete query with no matching
occurrences. Document symbols and the current semantic projection support
top-level functions, globals, types, constructors, and fields; locals,
parameters, methods, and foreign declarations remain unavailable for
definition/reference identity queries until their compiler identities are
projected explicitly.

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

The actor creates one `SemanticQueryWork` value for each accepted query. That
value owns a monotonic token and the current semantic-index, workspace-revision,
and configuration snapshot before passing it to the definition, document-symbol,
and references/hover/highlight implementations. Query code therefore cannot read a mutable
actor workspace in pieces; the same owned work value can be handed to a worker
when query execution becomes asynchronous. Execution is still synchronous, so
there is no cancellable pending-query completion path yet.

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

Semantic queries are currently interpreted synchronously by the actor. The
typed request boundary is deliberately independent of execution, so pending
query ownership can move to an analysis worker later without changing the
wire codecs or query result contracts.

Document filesystem effects are currently interpreted synchronously by the
native composition root. The actor still queues document notifications behind
an outstanding open/save effect so the reducer remains correct if effect
interpretation becomes interleavable; the queue and transient `ServerBusy`
response are therefore covered at the reducer boundary today.
