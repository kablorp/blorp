# Qualified type-name census (family F12), 2026-09-29

Base: `origin/main` c47e62f23. Docs only; nothing was built or measured.
Supersedes the F12 paragraph of `magic_spelling_census_2026-09-28.md` for
planning; the slice plan is the "Qualified type names" section of
`docs/IDENTITY_ROADMAP.md`.

Method: `grep -rnE '"[a-z_]+(::|__)[A-Z][A-Za-z]*"'` over `blorp/src` gives 95
literal lines (the older census said 98 by also matching `net/tcp::` forms
with a slash; those are counted below under `operation_metadata.brp`).
Each line was assigned to its enclosing function. Callers of the
`type_name_metadata` predicates and the two `"units", "Duration"` readers
were added by hand. Bare spellings with no qualified twin (`name ==
"Channel"`, `"TcpListener"`, ...) are not in the 95; a targeted grep finds
about 40 more lines in the same files. They are the same fact and convert
with the same enum (see "Gaps in the census").

## 1. Readers by what they ask

### 1a. Vocabulary: "is this the stdlib type T" (95 literal lines, about 24 call sites)

| File | Function | Lines | Types spelled |
| --- | --- | --- | --- |
| `stage_06_typecheck/type_system/type_name_metadata.brp` | `is_stream_type_name`, `is_fallible_stream_type_name`, `is_resource_source_type_name`, `is_runtime_erased_union_payload_type_name` | 8 | `Stream`, `FallibleStream`, `ResourceSource`, `RecvAttempt` in `M::T` and `M__T` (bare in a match arm each) |
| `stage_09_core/operation_metadata.brp` | `error_spec` | 9 | `IOError`, `ProcessError`, `DnsError`, `TcpError`, `TlsError`, `UdpError`, plus `blorp/src/lsp/lsp_stdio_transport::CompilerStdioError` (compiler-private, not stdlib) |
| | `operation_spec` | 29 | `TcpListener`, `TcpStream`, `TlsSession`, `UdpSocket`, `WebSocketSession`, `CompilerStdinRawOutcome`, ...; `resource_success([...])` and `ExactSuccessType([...])` take a three-spelling list each (24 lists) |
| `stage_09_core/c_type_layout.brp` | `c_type_name` | 10 | `Stream`, `FallibleStream`, `net_tcp__Port`, `TcpListener`, `TcpStream`, `TlsSession`, `WebSocketSession`, `UdpSocket` (the `net_*__` ones are flat-only) |
| | `boxed_value_needs_release_type` | 3 | `Stream`, `FallibleStream` |
| `stage_09_core/unmanaged_type.brp` | `named_type_is_known_unmanaged` | 13 | `FileReader`, `FileWriter`, `FileAppender`, `FileReadWriter`, `FileReadAppender`, `Directory`, `UdpSocket` |
| `stage_09_core/type_policy.brp` | `nullable_managed_option_payload_release_policy` | 8 | `Stream`, `FallibleStream`, `net_tcp__TcpListener`, `net_tcp__TcpStream`, `net_tls__TlsSession`, `net_websocket__WebSocketSession`, `net_udp__UdpSocket` |
| | `cleanup_release_policy_for_type` | 3 | `Stream`, `FallibleStream` |
| `stage_09_core/prepare.brp` | `pointer_box_storage_needs_release_type` | 6 | `ResourceSource`, `Stream`, `FallibleStream` (with arity checks) |
| `stage_09_core/desugar.brp` | `core_type_is_string` | 2 | `string::String`, `string__String` |
| `stage_08_core_lower/lower.brp` | constants `CANONICAL_PARALLEL_VECTOR_TYPE_NAME`, `CANONICAL_PARALLEL_MATRIX_TYPE_NAME` (read at `:1448`, `:1460` in `core_lower_type_with_prefixes_impl`) | 2 | `vector::ParallelVector`, `matrix::ParallelMatrix` |
| `stage_09_core/specialize_collection.brp` | `stream_element_type` | 1 | `Stream` |
| `stage_09_core/late_invariants.brp` | `is_resource_source_name` | 1 | `ResourceSource` |
| **Literal lines** | | **95** | |

Callers of the `type_name_metadata` predicates (no literal, but each is
one of the readers that must move): `infer.brp` 13 (`:12410, :12769,
:12805, :19200, :19217, :19355, :19366, :19397, :19607, :21928` and the
import block), `decl.brp` 2 (`:758, :2169`), `env.brp` 1 (`:1148`),
`lower.brp` 4 (`:3437, :3450, :4420`, `:6323` via `CoreTypePolicy`),
`type_policy.brp` 5 (`:155-160` delegators, `:224, :336, :411`),
`mono_data.brp:866`, `c_type_layout.brp:350, :518`, `late_invariants.brp:625`.

Constructed-spelling readers (compare against
`canonical_module_type_name("units", "Duration")`): `infer.brp:21782`,
`lower.brp:2967` (`core_timeout_is_duration`). Two sites, same fact.

Special cases that are not stdlib vocabulary:

- `operation_metadata.brp` names two compiler-private LSP types
  (`CompilerStdioError`, `CompilerStdinRawOutcome`; 6 of the 38 lines) by
  a path that is a source-checkout path (`blorp/src/lsp/...`,
  sanitized to `blorp_src_lsp_lsp_stdio_transport__...`). Their identity is
  "declared in the module with this canonical path", not a stdlib pin.
- `net_tcp__*`, `net_tls__*`, `net_websocket__*`, `net_udp__*` readers
  (`type_policy`, `c_type_layout`, `unmanaged_type`) spell only the flat
  form because they only run on Core. These are `pkg/net/*` types
  (`pkg/` owns them per AGENTS.md), so a pinned "stdlib" enum would put
  package types in the compiler's vocabulary; see risk R6.

### 1b. Qualification: "which module declared this type" (producers, 14 sites)

`canonical_module_type_name(module_path, name)` is the one spelling
constructor (`semantic_type.brp:390`): it returns the bare name when
`is_std_module_name(path) and is_global_abi_type_name(name)` (a 60-name
list), otherwise `path::name`. Callers:

| Site | What it has at hand |
| --- | --- |
| `type_header_install.brp:195, :201` (`resolved_declared_type_name`) | `TypeHeader` with `id: TypeId`, `owner_module_id: ModuleId`, `source_name`. Local installation returns the bare `source_name`; imported returns the canonical name |
| `type_header_install.brp:353` (`PreludeTypeShape`) | the `PreludeType` enum value |
| `type_header_install.brp:612` (`installed_header_name`) | source name and module path only |
| `accepted_record_graph.brp:190, :263`, `accepted_union_graph.brp:164`, `accepted_alias_graph.brp:110` | `id: TypeId` (`type_id_definition_id`) beside the name |
| `accepted_record_authority.brp:170`, `accepted_alias_authority.brp:213` | a row with the name; ids one call away |
| `type_resolution.brp` (headers) `:113, :130` | `DeclaredTypeShape` resolution, TypeId at hand |
| `type_resolution.brp` (type_system) `:123` | alias-qualified `alias.Type` resolved to a module path String; no id |
| `semantic_type.brp:628` (`qualify_module_local_types`) | module path plus `local_type_names: List[String]`; no ids |
| `types.brp:92` (`type_from_parsed_type_expr`, `ParsedQualifiedNamedType`) | parse tree with qualifier and name separately; builds `alias.Name` |
| `infer.brp:21782`, `lower.brp:2967` | literal module path plus name (readers, see 1a) |

Also owned here: `should_qualify_module_local_type`, `owner_local_type_name`
(`semantic_type.brp:700`, the inverse used by `localize_module_types`),
`is_global_abi_type_name` (the 60-name bare-spelling list).

### 1c. Parsing: "split a qualified spelling" (4 parsers)

| Parser | Separator | Readers |
| --- | --- | --- |
| `split_canonical_module_type_name` (`semantic_type.brp:413`, private) | `::` | `owner_local_type_name` (`:701`), `display_type_name` (`:810`) |
| `split_qualified_type_name` (`semantic_type.brp:451`) | `.` | `resolve_qualified_type_name_if_changed` (`type_resolution.brp:112`) |
| `flatten_canonical_core_type_name_with_prefixes` (`identity.brp:160`, `raw_index_of("::")`) | `::` to `__` | `core_lower_type_with_prefixes_impl` (`lower.brp:1429`), the only caller of the prefix form; `flatten.brp:2352` documents that Core names arrive flattened |
| `normalize_type_name` (`semantic_type.brp:283`) | folds `Vector`/`Matrix` to `Tensor` | 19 call sites; a vocabulary alias, not a parser, listed because it is a fourth "one type, several spellings" fold |

### 1d. Display: "render for a message" (3 sites, must stay as text)

`display_type_name` (`semantic_type.brp:809`, turns `M::T` into `M.T`),
its callers `type_to_string` (`:842, :846`) and `core_type_to_string`
(`type_policy.brp:284, :285, :305`; the `:285` reader compares the display
string with `"Tuple"`, which is a vocabulary read hiding in a display
function). 860 diagnostic fixtures pin this text, and `type_name` is
user-visible.

### Totals

| Group | Literal lines | Other sites |
| --- | --- | --- |
| Vocabulary | 95 | about 24 predicate callers, 2 constructed `Duration` readers |
| Qualification | 0 | 14 producers, 3 helpers |
| Parsing | 0 | 4 parsers (`::` twice, `.` once, `__` join once) |
| Display | 0 | 3 sites |

## 2. Identity available per phase

| Phase | Type reference | Identity carried | Where the String is produced, and does the producer have the id |
| --- | --- | --- | --- |
| Header resolution (`headers/`) | `ResolvedTypeShape`: `DeclaredTypeShape(TypeId, args)`, `IntrinsicTypeShape(IntrinsicType, args)`, `PreludeTypeShape(PreludeType, args)` | Full. `TypeId` is a `DefinitionId` (`type_id_definition_id`); `TypeHeader` holds `owner_module_id: ModuleId` and `source_name` | Not a String phase |
| Typecheck | `SemanticNamedType(String, List[SemanticType])` (`semantic_type.brp:30`); 255 source and 457 test occurrences, 21 source files | String only. No `DefinitionId`, `ModuleId` or `NameId` on the variant | Header install (`type_header_install.brp:195-201, :353, :612`, accepted graphs) turns `DeclaredTypeShape` into a String with the `TypeHeader` and its `TypeId` in hand: the id is dropped there, one statement before the String is built. Annotation-derived types (`types.brp:92`, `type_from_parsed_type_expr`) start as `alias.Name` or a bare identifier, and `type_resolution.brp` and `qualify_module_local_types` rewrite them by String lookup with only a module path; there the id is not at hand and is one env lookup away |
| Core lowering | `NamedType(String, List[CoreType])` (`ir.brp:1234`); 465 source and 1000 test occurrences, 72 source files; also `EnumType`, `ValueRecordType`, `HeapRecordType`, `UnionType` (all `String`), `TensorType`, `TupleType` | String only | `core_lower_type_with_prefixes_impl` (`lower.brp:1424`) reads the semantic String, applies `normalize_type_name`, then `flatten_canonical_core_type_name_with_prefixes`. It never sees an id because `SemanticNamedType` has none. Core declarations (`CoreEnumDecl`, `CoreUnionDecl`, record decls) carry `name: String` and no `TypeId` (`ir.brp:3306-3338`); `CoreDefinitionIdentity { name, def_id }` exists only for variables and functions |
| Core passes | same `CoreType` | String only. `flatten.brp` re-points names through a rewrite table keyed by String (`rewritten_type_name`); `mono.brp:1324` `mangle_generic_data_name` builds instance names from `sanitize_core_mono_name(source_name)` | Instances are named data types built from the source name plus encoded arguments, so a mono-specialized record has no spelling equal to any stdlib literal (the readers all test unspecialized stdlib types with zero or fixed arity) |
| Backend | `CoreType` | String only. `c_type_symbol_projection` (landed 2026-09-24) already maps type String to C symbol through `Dict[String, String]` | Not a producer |

Conclusions:

1. The identity exists at exactly one place in the pipeline that matters:
   the typecheck header install. Everything after it carries the String.
2. No phase carries `DefinitionId` or `ModuleId` on a type reference, so
   "compare pinned type identities" needs a representation change first
   (slices Q3 and Q4), and that change is the named-types family of
   `docs/IDENTITY_ROADMAP.md` ("Nominal types and members", named types: `TypeId`).
3. Pinned identities are not `DefinitionId` literals: `DefinitionId` is an
   artifact-local number. The pin is `(std module origin, NameId)`
   resolved to a `KnownStdlibType` once per declaration (a per-declaration
   fact like `BuiltinTypeLayout`, stored on `TypeHeader`), never per
   occurrence.

## 3. Why one type has three spellings

Traced through the producers above, for `Stream` and `ResourceSource`:

| Spelling | Produced when | Seen by |
| --- | --- | --- |
| `Stream` (bare) | (a) Inside module `stream` itself (`LocalTypeHeaderInstallation` returns `source_name`). (b) In any importer for names in the 60-name `is_global_abi_type_name` list, when the module is in `STD_MODULE_NAMES` (`stream` is; `Stream`, `FallibleStream`, `FileReader`, `Directory`, `TcpListener`, ... are on the list) | Typecheck, then Core (flatten leaves a name without `::` alone) |
| `stream::ResourceSource` | Importer of a std type not on the ABI list (`ResourceSource`, `RecvAttempt`, `IOError`, `ProcessError`, `net/tcp::TcpError`, ...): `canonical_module_type_name` joins path and name with `::` | Typecheck only |
| `stream__ResourceSource` | `flatten_canonical_core_type_name_with_prefixes` at `lower.brp:1429`, applying `sanitize_core_module_name` (so `net/tcp::TcpError` becomes `net_tcp__TcpError`) | Core passes and backend |

So the triple is: local-or-ABI-bare, imported-qualified (typecheck), flat
(Core). Two facts follow.

- The `::` arms in Core readers (`type_policy`, `c_type_layout`,
  `unmanaged_type`, `prepare`, `late_invariants`, `desugar`,
  `specialize_collection`) and the `__` arms in typecheck-only readers are
  expected to be dead: `lower.brp:1429` is the only producer of Core
  `NamedType` from a semantic name, and `flatten.brp:2352` states that
  names arrive flattened. This is a reading of the source, not a
  measurement; slice Q0 proves it per arm before Q1 deletes it.
  Exceptions to check: `NamedType("Int", ...)` style constants in
  `entrypoint.brp`, `list_layout.brp`, `synth_list.brp` and `emit.brp` build
  bare names, which are always ABI-bare and safe.
- `type_name_metadata.brp` is the exception that explains why it lists all
  three: it is shared by pre-flatten readers (`infer.brp`, `decl.brp`,
  `env.brp`, `lower.brp:3437` on `SemanticNamedType` names) and by
  post-flatten readers (`CoreTypePolicy` delegators, `mono_data.brp:866`,
  `lower.brp:6323`). It cannot drop an arm until it is split by phase.

Would collapsing to one spelling early be byte-identical? Yes, provided
every dropped arm is proven not taken: readers only classify, nothing
they read is emitted, and the C type symbol comes from the name that the
producers still build. It is not free of risk in two places: (a) bare
spellings are ambiguous, since a user type named `Stream` declared in a user
module is bare inside its own module and the current readers cannot tell it
from the stdlib type (a latent bug the identity fix removes; add a fixture
first); (b) the `net_*__` arms are the only spelling their readers accept,
so they cannot be collapsed, only re-expressed.

## 4. Gaps in the census

- Bare-only readers (`name == "Channel"`, `"TcpListener"`, `"Stream"` outside a triple) are not counted; about 40 lines in the same files plus
  `infer.brp`/`env.brp`. `scripts/check-magic-spellings` should get a
  `known_type_name` role so the allowlist counts them.
- `Duration` (2 sites) and `normalize_type_name`'s `Vector`/`Matrix` fold (19
  sites) are counted under vocabulary and parsing respectively.
- `TYPE_NAME_*` constants for `Int`, `Float`, `Bool`, `Char`, `String`,
  `Void` (`lower.brp:1436-1444`) are prelude vocabulary owned by A2's
  `intrinsic_type`, not this family.
