# Type-name dead-arm evidence (M5.3 slices Q0 and Q1), 2026-09-29

Base `origin/main` c47e62f23. The plan is
`benchmarks/results/qualified_type_name_census_2026-09-29.md`.

## Q0 probe

A scratch (not committed) change put `probe_type_name(reader, name)` at the top
of every reader in the census. It logged `PROBE|<reader>|<name>` through a
`debug:` block (`dbg.log`), and a compiler built from that source with
`--debug` was run over:

- the self-compile of `blorp/src/main.brp`;
- 120 programs that mention a vocabulary type (`blorp/test/runtime`,
  `blorp/test/compiler/pipeline/codegen_audit/should_pass`, `standard_library`,
  `examples`), compiled to C;
- the same runtime tests through `blorp test` (72 files that import fs,
  stream, net, channel, units or process; this path covers the pkg network
  types, which `compile` skips because test files have no `main`).

`--suite` mode was not usable with the probe binary ("build artifact and host
runtime inputs are incompatible"), so this is the per-file path, not the exact
`scripts/test runtime` artifact. Raw logs are under the session scratchpad;
the probe diff is not kept.

What each reader received, by phase (names in any reader of that phase):

| Type | Typecheck-phase spellings | Core-phase spellings |
| --- | --- | --- |
| `Stream`, `FallibleStream`, `FileReader`, `FileWriter`, `FileAppender`, `FileReadWriter`, `FileReadAppender`, `Directory`, `Port`, `TcpListener`, `TcpStream`, `Channel` | bare | bare |
| `ResourceSource` | `stream::ResourceSource` | `stream__ResourceSource` |
| `RecvAttempt` | `channel::RecvAttempt`, bare | `channel__RecvAttempt` |
| `IOError`, `ProcessError`, `TcpError`, `DnsError`, `TlsError`, `UdpError` | `M::T`, bare | `M__T` (bare only as a declaration name at union lowering) |
| `TlsSession`, `UdpSocket`, `WebSocketSession` | `net/M::T`, bare | `net_M__T`, bare |
| `Duration` | `units::Duration`, bare | `units__Duration` |
| `ParallelVector`, `ParallelMatrix` | bare | not seen |
| compiler-private `CompilerStdioError`, `CompilerStdinRawOutcome` | `blorp/src/lsp/lsp_stdio_transport::T`, bare | `blorp_src_lsp_lsp_stdio_transport__T` |
| `Datagram`, `Message`, `WebSocketError`, `ProcessSession*` (operation results) | not probed | `M__T` (declared types; flat only) |

Zero Core reader (policy, layout, unmanaged, prepare, desugar, specialize,
operation-metadata, delegators) ever received a `module::Type` spelling.
Zero reader of either phase received `stream::Stream`, `stream__Stream`,
`stream::FallibleStream`, `stream__FallibleStream`, any `fs::` or `fs__` file
type, `net/tcp::` or `net_tcp__` `Port`/`TcpListener`/`TcpStream`,
`string::String`, `string__String`, `vector::ParallelVector` or
`matrix::ParallelMatrix`. The structural reason: `canonical_module_type_name`
returns the bare name for a std module plus a name on `is_global_abi_type_name`
(all of the above), so those types have exactly one spelling; and
`flatten_canonical_core_type_name` is the only producer of Core `NamedType`
names from semantic names, so `::` cannot reach Core.

Bare `ResourceSource` was received by no reader in any phase.

## Q1 deletions

| Reader | Removed |
| --- | --- |
| `type_name_metadata.brp` (typecheck side) | `stream__Stream`, `stream::Stream`, `stream__FallibleStream`, `stream::FallibleStream`, `stream__ResourceSource`, bare `ResourceSource`; `is_runtime_erased_union_payload_type_name` moves to Core |
| `type_policy.brp` (Core side, new predicates) | all `stream::` and `stream__` Stream/FallibleStream arms (4 sites); `net/tcp::` and `net_tcp__` TcpListener/TcpStream; `net/tls::`, `net/websocket::`, `net/udp::`; `stream::ResourceSource`, bare `ResourceSource`; `channel::RecvAttempt` |
| `c_type_layout.brp` | the same Stream/FallibleStream arms (4 sites), `net/tcp::` and `net_tcp__` Port/TcpListener/TcpStream, `net/tls::`, `net/websocket::`, `net/udp::` |
| `unmanaged_type.brp` | 10 `fs::`/`fs__` File* arms, `fs::`/`fs__` Directory, `net/udp::UdpSocket` |
| `prepare.brp` | `stream::`/`stream__` Stream and FallibleStream, `stream::ResourceSource`, bare `ResourceSource` |
| `desugar.brp` | `string::String`, `string__String` |
| `late_invariants.brp` | private `is_resource_source_name` (now `CoreTypePolicy.is_resource_source_type_name`) |
| `specialize_collection.brp` | `stream::Stream`, `stream__Stream` |
| `lower.brp` | `CANONICAL_PARALLEL_VECTOR_TYPE_NAME`, `CANONICAL_PARALLEL_MATRIX_TYPE_NAME` |
| `operation_metadata.brp` | every `M::T` entry (24 lists); the bare entry of declared (union or record) result types, whose Core name is always flat; the flat entry of ABI-bare std types (File*, Directory, DirectoryEntry, TcpListener, TcpStream) |

Kept because a spelling was observed or the type is not proven single-form:
bare and flat `TlsSession`, `UdpSocket`, `WebSocketSession`; flat
`stream__ResourceSource` and `channel__RecvAttempt`; bare `RecvAttempt` (read
as a declaration name by union lowering); `units::Duration` readers.

## Behavior change

Byte-identical generated C is required and was gated. One user-visible
semantic side effect: bare `ResourceSource` no longer means the stdlib type, so
a module's own `record ResourceSource[R, E]` type checks (fixture moved to
`typecheck/should_pass`). The same collision remains for the ABI-listed names
(`FallibleStream`, `Stream`, ...): the stdlib type is bare there too, so no
spelling separates them; pinned by
`typecheck/should_fail/user_fallible_stream_named_like_stdlib.brp`.
