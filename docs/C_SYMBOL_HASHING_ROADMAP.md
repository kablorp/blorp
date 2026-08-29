# Internal C Symbol Hashing Roadmap

## Status

Slices 0-2 and the callable measurement work in Slice 4 are implemented.
Artifact-local user and closure bodies now receive deterministic short symbols
at the final Core-to-C boundary. Type, constructor, global, field, and local
names remain unchanged until their ABI status can be represented completely.

The tactical goal is smaller generated C and a faster host C compilation step.
It is not a replacement for stable module/entity IDs in semantic compiler IR.
Semantic names must remain available throughout the compiler for diagnostics,
profiling, Core dumps, and future incremental compilation.

The retained bounded measurement is in
[`benchmarks/results/compiler_c_symbol_projection_2026-08-23.md`](../benchmarks/results/compiler_c_symbol_projection_2026-08-23.md).
It reduced generated C by 38.17%, callable identifier bytes by 83.46%, `-O0`
object bytes by 23.78%, and `-O2` object bytes by 50.96%. Compile-to-C changed
by -0.17% in order-alternated runs, inside the 2% stop condition. Host-C timing
was flat/noisy on this small fixture and is not treated as a speedup claim.

## Decision Summary

Implement hashing in a new Stage 10 projection immediately after the compiler
unwraps the final `PreparedCoreProgram` and immediately before `emit_decls` in
`compiler/src/stage_10_backend/emit.brp`.

The first slice will:

1. Treat `UserFunction` and `ClosureBodyFunction` bodies as artifact-local.
2. Emit those definitions and forward declarations with `static` linkage.
3. Build one deterministic callable C-symbol plan from final Core declarations.
4. Rewrite a private copy of final Core so definitions and every compatible
   callable reference use the same short symbol.
5. Preserve `main`, foreign C names, builtin/runtime names, types, constructors,
   tags, globals, fields, locals, diagnostics, profile labels, and Core dumps.
6. Validate collisions before rendering any C and report original names in an
   internal compiler error instead of risking a miscompile.

The intended spelling is a three-character Blorp-owned prefix followed by a
fixed ten-character encoded hash payload, for example `bh_4g8k2m0q1z`.
The payload is the "10-byte hash" in this roadmap; the complete C identifier is
13 ASCII bytes. Keep both lengths as named constants so moving to an
11-character payload for all 64 hash bits is a local policy change.

## Why This Boundary

The current semantic identity is created much earlier by
`core_module_member_name` in
`compiler/src/stage_08_core_lower/identity.brp`. Hashing there would push
opaque names through every Core pass, contaminate dumps and diagnostics, and
interact with late passes that still compare semantic strings.

The final production emission boundary is
`try_emit_prepared_core_program_c_artifact_with_profile` in
`compiler/src/stage_10_backend/emit.brp`. At that point:

- typechecking, lowering, specialization, DCE, Perceus, reuse, closure
  conversion, resource handling, preparation, and invariant checks are done;
- no later compiler pass needs semantic callable names;
- the complete emitted declaration inventory is available for collision checks;
- `BuildArtifact` can still derive foreign metadata from the original Core
  program through `compiler/src/pipeline.brp`;
- `--dump-core-after` and `--stop-after` remain readable because projection is
  not a Core pipeline stage.

Do not implement this by changing `c_identifier`. That helper also renders
locals, fields, runtime ABI names, and foreign names and has no information with
which to classify them. Do not perform textual replacement over emitted C:
identical tokens may name a local, field, typedef, macro, or external symbol in
different C scopes. Do not use module/name prefixes as an ABI heuristic.

## Proposed Stage 10 Model

Add `compiler/src/stage_10_backend/c_symbol_projection.brp` with phase-
specific types similar to:

```blorp
enum CProjectedCallableKind:
	ProjectedUserFunction
	ProjectedClosureBody

record CCallableSymbolCandidate {
	kind: CProjectedCallableKind,
	identity: CoreDefinitionIdentity,
	original_name: String,
	original_c_spelling: String
}

record CCallableSymbol {
	original_name: String,
	projected_name: String
}

record CCallableSymbolPlan {
	by_qualified_name_then_def_id: Dict[String, Dict[Int, CCallableSymbol]],
	by_original_c_spelling: Dict[String, CCallableSymbol],
	by_projected_name: Dict[String, String]
}

opaque type CProjectedProgram = ...

union CSymbolProjectionError:
	DuplicateCallableCName(String)
	ProjectedSymbolCollision(String, String, String)
	ProjectedSymbolConflictsWithPreservedName(String, String)
	MissingProjectedCallable(String)
	AmbiguousCallbackTarget(String)
	UnsupportedPreparedCallKind(String)
```

Exact record shapes may follow local ownership needs, but preserve these
invariants:

- Only the projection module constructs `CProjectedProgram`.
- The production renderer accepts `CProjectedProgram`, not arbitrary
  `CoreProgram`.
- The plan is built once per artifact and hashes each unique candidate once.
- Typed references use exact `CoreDefinitionIdentity` lookup: qualified name
  plus module-local `def_id`. Closure/task references additionally validate that
  their redundant `function_name`, `def_id`, and `c_name` fields agree with the
  inventoried declaration. String-only callbacks use a separate unique-C-name
  resolver and fail on missing or ambiguous targets.
- No prefix, length, path, or spelling heuristic determines eligibility.
- The reverse map exists only for errors and profile labels. It is not emitted
  into the executable.
- Projection is single-pass after inventory construction. Avoid repeated scans
  and repeated hash computation.

Use the nested `Dict[String, Dict[Int, ...]]` shown above for structured
identity. `CoreDefinitionIdentity` does not currently implement the equality
and hash traits required for a direct `Dict` key, and adding those semantic
traits solely for this backend table would widen the change unnecessarily.

The current 290-test renderer suite needs an intentional unprojected test
boundary. Rename its helper API explicitly, for example
`emit_unprojected_core_program_c_artifact_for_tests`, and mechanically update
`compiler/tests/test_compiler_core_emit.brp` to call it. That helper tests
the C renderer with readable synthetic Core names. Production CLI code must use
only the projected entry point. The ownership manifest and a repository search
must enforce that the unprojected helper has no non-test caller.

## Hash Contract

Put the hash and encoding implementation in the projection module or a smaller
`c_symbol_hash.brp` owned solely by it.

Use a compiler-owned, deterministic FNV-1a 64-bit implementation with named
offset-basis and prime constants. First apply the existing `c_identifier`
reserved-word escaping, then hash the UTF-8 bytes of that final unprojected C
spelling with a named schema prefix such as
`blorp-internal-c-callable-v1\0`. The encoding contract must be byte-based, not
Unicode-codepoint-based. Hashing also gives non-ASCII source identifiers a
portable C spelling; include a fixed non-ASCII vector even though current
module-qualified compiler names are predominantly ASCII.

Do not use `std/hash.hash`. Although its documentation describes deterministic
FNV-1a, the production `blorp_hash` implementation in
`compiler/lib/runtime.c` mixes in the process-randomized
`__blorp_hash_seed`. Symbol spelling must be reproducible across processes,
hosts, source order, and hash-table iteration order.

Encode a fixed ten-character payload from an identifier-safe alphabet. The
Blorp-owned `bh_` prefix is not reserved by C and separates these names from
existing `__blorp_*`, `__sc_*`, and `__init_*` helpers. All output characters
must be portable C identifier characters. Leading zero digits must be retained
so the length is fixed. Collision validation, rather than a C-reserved prefix,
protects the namespace. Add a focused test proving projected names do not match
C's reserved-identifier forms; the broader generated C still has pre-existing
double-underscore helpers outside this slice.

Use the literal alphabet
`0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ`. Repeatedly divide
the unsigned 64-bit FNV result by 62, write least-significant digits from right
to left, and zero-pad to ten characters. This intentionally encodes
`hash mod 62^10`; the collision validator makes the truncation safe. Hash
arithmetic must use wrapping `UInt64` operations, not signed overflow or host-
dependent integer width. Later entity classes receive distinct schema prefixes,
not ad hoc spelling prefixes.

Ten base-62 payload characters retain roughly 59 bits. That is not enough to
justify unchecked probabilistic identity. Before projection:

1. Inventory every candidate original name.
2. Compute every projected name.
3. Reject two distinct candidates with the same projected name.
4. Reject a projected name that conflicts with a preserved top-level C name.
5. Make collision diagnostics deterministic by sorting original names before
   rendering the error.

The preserved-name inventory must use C's ordinary-identifier collision domain,
not only function declarations. It must contain:

- `main`, every foreign `c_name`, builtin C name, and emitted runtime callback;
- every unprojected function and closure C name;
- every emitted global name;
- aggregate typedef names, enum values, union constructor names, and tag macros;
- emitter-derived top-level helpers, including enum formatters, record makers
  and reuse helpers, union destructors and reuse helpers, static closure objects,
  generated stack-option typedefs, static aggregate instances/initializers, and
  global init/drop helpers;
- every preserved or pre-existing generated top-level name beginning with
  `bh_`, so a projected token cannot silently capture an existing Blorp-owned or
  source-owned spelling.

Do not duplicate private naming formulas between the projection and emitter.
Move top-level derived-name construction into a small shared Stage 10 helper as
each category enters the inventory. For the callable-only slice this helper
must at least own callable names, static closure names, and the fixed global
helpers; later type/global slices extend it alongside their projection.

Included foreign headers can introduce declarations or macros the Core program
does not inventory. The distinctive `bh_` plus ten-character payload makes an
accidental match remote, but cannot prove it impossible. Host C compilation is
the final conflict check and must fail the build if a header captures a
projected token. Do not claim that the in-compiler inventory covers arbitrary
header contents.

The production algorithm must never resolve a collision by source-order
suffixing. A deterministic compilation error is safe and testable. A later
version may fall back to original names for a colliding group, but that requires
the plan to carry the fallback consistently and provides little practical value
for the initial slice.

Tests should exercise collision handling through a pure validator that accepts
precomputed `(original_name, projected_name)` pairs. Do not add an environment
variable or production hash override solely to force collisions in tests.

## ABI Classification

### First-Slice Classification

| Entity | First-slice action | Reason |
| --- | --- | --- |
| `ProgramEntrypointFunction` | Preserve as `main` | Process ABI entry point. |
| `ForeignFunction.c_name` and `ForeignCall` | Preserve | Owned by included C ABI. |
| `BuiltinFunction`, `BuiltinCall`, `DirectRuntimeCall`, intrinsic and bridge runtime names | Preserve | Compiler/runtime ABI. |
| `UserFunction` with a body | Mark `static`; project | Blorp has no supported C export facility. |
| `ClosureBodyFunction` with a body | Mark `static`; project its closure ABI C name | Artifact-local compiler-generated callable. |
| `UserCall` | Rewrite by exact callable-plan lookup | Typed internal direct call. |
| `ListToStringCall` callback | Rewrite only when it resolves uniquely to the callable plan | Callback currently lacks definition identity. |
| Custom Dict/Set hash and equality callbacks | Rewrite only when each resolves uniquely to the callable plan | `CoreHashContainerConstructor` carries these as raw strings outside `CoreCallKind`. |
| `CoreClosureCreate.c_name` and `CoreTaskClosure.c_name` | Rewrite from the closure callable plan | Function pointer must match closure body. |
| Static closure object name | Derive from the projected closure body name | Avoid independently hashing two linked names. |
| `UnresolvedBuiltinFunction` and unresolved/selected call forms | Preserve declaration, but reject if an emitted body still depends on an unresolved call | These should not survive preparation as renderable calls. |
| Profile labels, source locations, comments, diagnostics | Preserve original | User/developer-facing text is not a C symbol. |

`CoreFunction.source_module`, source visibility (`private` versus public), and
qualified-name spelling are not C ABI indicators. Public Blorp declarations are
public to Blorp imports, not exported C symbols. Conversely, a foreign C name is
ABI-visible even when its Blorp declaration is private.

Ordinary user and closure functions currently have external C linkage even
though no language feature exports them. Make their artifact-local status
concrete by emitting `static` before shortening them. Do not rely on the claim
that they are "effectively internal" while leaving the C linkage contradictory.

### Entities Explicitly Deferred

Do not hash these in the callable slice:

- `CoreGlobal` names or recursively derived static storage names;
- enum, union, value-record, heap-record, or alias names;
- enum values, union constructor functions, tag macros, record makers, reuse
  helpers, destructors, generated stack-option types, or enum formatting helpers;
- struct/union fields;
- locals, parameters, compiler temporaries, labels, or cleanup frames;
- free-form `c_name`, `runtime_c_name`, `runtime_result_c_type`, or inline-struct
  strings not tied to an inventoried internal declaration.

`DeclaredAbiType` in
`compiler/src/stage_05_types/language_surface_manifest.brp` protects known
runtime-owned source types, but it is not a complete C ABI exposure model.
`classify_c_record_layouts` in
`compiler/src/stage_10_backend/emit_record_layout.brp` also discovers
records transitively reachable from foreign signatures. Its current registry
does not expose all foreign-reachable enums, unions, aliases, fields, variants,
tags, constructors, and generated helpers. Therefore `abi_type == None` is not
sufficient evidence that an aggregate C name can be shortened.

### Current C-Name Carrier Ledger

The first implementation review must account for every current Core field that
already carries C spelling. This is the disposition for the callable slice:

| Core carrier | Callable-slice disposition |
| --- | --- |
| `CoreFunction.name` | Project only final `UserFunction` definitions. |
| `CoreForeignFunction.c_name` | Preserve. |
| `UserCall.name` | Project by exact callable-plan lookup. |
| `ListToStringCall` callback | Project by unique exact callable-plan lookup. |
| `CustomHashContainerConstructor` hash/equality strings | Project by unique exact callable-plan lookup. |
| `ForeignCall`, `BuiltinCall`, `DirectRuntimeCall`, `TensorParallelCall`, `IntrinsicCall` names | Preserve. |
| `CoreOperationResultBridge.runtime_c_name/runtime_result_c_type` | Preserve. |
| `CoreFallibleStreamTerminalBridge.runtime_c_name/runtime_result_c_type` | Preserve. |
| Operation/fallible-stream constructor C names | Preserve pending complete type ABI exposure. |
| `CoreClosureAbi.c_name` | Project for final closure bodies. |
| `CoreClosureCreate.c_name/static_name` | Project/derive from the same closure plan. |
| `CoreTaskClosure.c_name/static_name` | Project/derive from the same closure plan. |
| `CoreEnumVariant.c_name` | Defer. |
| `CoreUnionVariant.c_name/tag_c_name` | Defer. |
| `CoreUnionConstruct` and `CoreUnionReuseConstruct` C names | Defer. |
| Constructor-match C names and C type strings | Defer. |
| Inline-struct, boxed-struct, tuple-struct, list-layout, tensor-layout C type strings | Preserve. |
| `CoreGlobal.name` | Defer. |
| Named `CoreType` values and declaration names | Defer. |

This ledger is deliberately based on typed variants/fields, not token prefixes.
Update it and the projection completeness tests whenever a new C-name-bearing
field is added to final Core.

## Exact Callable Projection Coverage

The projection must update definitions and references as one atomic operation.
The inventory root is every final `FunctionDecl` with one of these kinds:

- `UserFunction` with `body = Some(...)`, keyed by
  `CoreDefinitionIdentity(CoreFunction.name, CoreFunction.def_id)` and carrying
  the escaped final C spelling of `CoreFunction.name`;
- `ClosureBodyFunction(abi)` with `body = Some(...)`, keyed by
  `CoreDefinitionIdentity(CoreFunction.name, CoreFunction.def_id)` and carrying
  the escaped final C spelling of `abi.c_name`.

For `UserFunction`, rewrite `CoreFunction.name` in the projected copy and retain
the original in the reverse/profile map. For `ClosureBodyFunction`, retain the
semantic `CoreFunction.name` and rewrite only `CoreClosureAbi.c_name`; the
emitter uses the latter for the C signature.

Implement a dedicated Stage 10 `project_callable_expr` tree walk. It may use
`map_core_expr_children_and_types_with_context` from
`compiler/src/stage_09_core/traverse.brp` to rebuild children first, but
that helper only maps child expressions and types: it does not rewrite closure,
task, call-kind, or collection-constructor C-name fields. The Stage 10 projector
must therefore inspect each rebuilt node and explicitly rewrite these forms:

- `CallExpr(UserCall(name, Some(def_id), consumed_args), ...)`, resolving
  `CoreDefinitionIdentity(name, def_id)`; a renderable `UserCall` without a
  definition ID is a projection error, not a name-only fallback;
- `CallExpr(ListToStringCall(callback_name), ...)` when uniquely inventoried;
- every `CustomHashContainerConstructor(hash_fn, equals_fn, ...)` embedded in
  `DictConstructExpr`, `SetAllocExpr`, `DictWithCapacityCall`, or another final
  collection form, resolving both callback names against the callable plan;
- `ClosureCreateExpr`, updating `CoreClosureCreate.c_name` and deriving its
  `static_name` from the projected C name while preserving `function_name`;
- `DetachExpr`, `CoreConcurrentlyLoop.task`, and every
  `CoreConcurrentBinding.task`, updating `CoreTaskClosure.c_name` and its
  derived `static_name` while preserving `function_name`.

The implementation must audit every `CoreExpr` variant that embeds a
`CoreTaskClosure`; relying only on `DetachExpr` would miss concurrent blocks and
loops. Add a projection completeness test whenever `CoreExpr`, `CoreCallKind`,
`CoreClosureCreate`, or `CoreTaskClosure` gains another C-name-bearing field.

For every closure/task reference, look up
`CoreDefinitionIdentity(function_name, def_id)`, verify that its original C
spelling equals escaped `c_name`, then derive both projected `c_name` and
`static_name` from that entry. A mismatch is a stale-Core invariant failure and
must report all three original fields.

Do not rewrite `VarExpr` merely because its text matches a function name. Local
and global `CoreVar` values share the same shape, and module-local `def_id`
values are not globally unique by themselves. Final closure conversion should
have removed callable values into explicit closure forms. If a function-valued
`VarExpr` survives, fail the projection completeness check and model it
explicitly rather than guessing.

`ListToStringCall` is a known weak boundary because it carries only a string.
The first slice may resolve it against a unique callable-plan entry and fail on
ambiguity. A follow-up should replace its string with structured callable
identity so future symbol policies do not depend on uniqueness of spelling.

## Production API Changes

1. `compiler/src/stage_10_backend/c_naming.brp` owns C reserved-word
   escaping currently implemented by private `c_identifier` in `emit.brp`, plus
   shared construction of top-level derived names. Both projection and emitter
   call the same helper, so the hash input is exactly the spelling emission
   would otherwise use.
2. `compiler/src/stage_10_backend/c_symbol_projection.brp`
   owns hashing, inventory, collision validation, projection, reverse names,
   and the opaque projected-program type.
3. `compiler/src/stage_10_backend/emit.brp` projects inside
   `try_emit_prepared_core_program_c_artifact_with_profile` before `emit_decls`.
   Split out an explicitly unprojected renderer only for focused renderer tests.
4. `compiler/src/stage_10_backend/emit.brp` emits `static` on internal user
   and closure function declarations and definitions.
5. `compiler/src/stage_10_backend/emit.brp` receives original profile
   display names at the top-level function renderer. Do not thread name maps
   through expression rendering.
6. `compiler/src/stage_10_backend/emit.brp` keeps the renderer-local
   `CoreEmitError` and adds `CoreCArtifactError` with separate render and symbol-
   projection variants. The production `try_emit_*` APIs return the containing
   error, and `core_c_artifact_error_message` renders projection failures with
   both original colliding names. The raw renderer test helper may continue to
   return `CoreEmitError`.
7. `compiler/src/pipeline.brp` continues to build
   foreign/link metadata from `prepared_core_program_value(prepared_core)` and
   uses only the projected production emitter for C text.
8. `compiler/benchmarks/compiler_backend_bridge.brp` also uses the
   projected Core-program emitter. It directly calls the current raw
   `try_emit_core_program_c_artifact_with_profile` and must not become an
   accidental production bypass.
9. `compiler/tests/compiler_test_ownership.json` assigns the new modules to
   a focused backend suite and also keeps the full emitter suite as coverage.

No Stage 08 or Stage 09 semantic data type needs to change for the first slice.
No CLI option or environment variable is required. Do not add a migration mode,
dual production route, hash-disable switch, or serialized symbol map.

## Test Plan

### Focused Projection Suite

Add `compiler/tests/test_compiler_c_symbol_projection.brp` first. Cover:

1. A fixed input/hash/output vector and exact payload length/alphabet.
2. Same input produces the same symbol across repeated and reordered inventory.
3. Similar long names produce different symbols.
4. Repeated observations of one declaration identity are coalesced; two
   distinct declaration identities with one original C name are rejected.
5. Injected projected-name collision reports both original names.
6. Injected conflict with a preserved name is rejected.
7. `main`, foreign C names, builtin/runtime names, and unresolved builtins remain
   absent from the candidate inventory.
8. User function definition, forward declaration, and `UserCall` agree.
9. `ListToStringCall` agrees with its callback definition and ambiguous/missing
   callback behavior is explicit.
10. Custom Dict/Set hash and equality callbacks agree with their definitions.
11. Capturing and noncapturing closures agree across body, function pointer, and
    static closure object.
12. Detached and structured-concurrency task closures agree with their body.
13. Profile-enabled C retains the original source-facing profile label while
    using a projected C identifier.
14. Projection errors render original names, never only hashes.
15. Projection cannot be applied twice because the projected wrapper is opaque.
16. A prepared callable reference not represented in the inventory is rejected
    before C rendering.

### Existing Renderer Tests

`compiler/tests/test_compiler_core_emit.brp` has 290 tests and 290 emitter
invocations: 282 default, three profile-enabled, and five fallible prepared-
emitter calls. Preserve their readable exact-string
assertions by mechanically moving them to the explicitly unprojected test
helper. Do not update hundreds of assertions to opaque hashes; those tests are
primarily proving renderer behavior, not production naming policy.

Add a small production-emission section to that suite, or keep it in the new
projection suite, which asserts stable projected spellings and compiles the
resulting C. A repository check should allow the unprojected helper only in the
renderer test file.

### Generated-C and Runtime Coverage

Audit every `-- EXPECT-C:` assertion under
`tests/test_compiler/codegen_audit/`. Update only assertions that intentionally
name an internal function. Runtime `blorp_*`, `BLORP_*`, FFI names, local
variables, type layouts, and field expectations should remain unchanged in the
first slice.

The pre-implementation audit found 202 fixtures with `EXPECT-C` or
`EXPECT-NOT-C`. These 23 fixtures explicitly lock module-qualified C spelling
and require individual classification:

```text
blorp_backend_imported_scalar_global
blorp_backend_primitive_runtime_builtin
blorp_backend_print_int
compile_time_intrinsic_specs_materialized
function_ref_uses_selected_import_def_id
generic_union_concrete_layout_identity
global_constant_generic_record_lifecycle
global_constant_generic_union_lifecycle
imported_main_function_symbol
list_contains_direct_loop
option_expression_fusion
option_nullable_stream
program_entrypoint_exit_status_message
string_pipeline_reverse_materialization_fusion
string_pipeline_window_materialization_fusion
tcp_chunks_stream_terminal
tcp_lines_stream_terminal
tcp_resource_read_cancellation_cleanup
tensor_alloc_typed_storage
tensor_get_or_callsite_inline
tensor_loop_views_direct
tls_chunks_stream_terminal
udp_datagram_stream_terminal
```

Ten additional fixtures lock generated constructor/closure spellings such as
`__def_` or `__sc_`; classify them even when their module-qualified spelling is
not visible in the expectation. The principal cases include
`blorp_backend_default_final_core_subset`, `blorp_backend_union_construct`,
`compile_time_erases_heap_builders`, the `option_nullable_*` cases, global
union/graph lifecycle cases, string-pipeline materialization cases, and tuple-
return SROA. `compiler_record_layout.brp` has 59 exact C expectations and must
remain byte-for-byte unchanged during callable-only projection.

Use this assertion-level disposition. “Project” means replace the named
callable fragment with its exact deterministic `bh_...` token in both positive
and negative assertions. “Preserve” means the assertion must not change.
“Structural” means replace a name-dependent assertion with an assertion for the
optimization artifact it was intended to prove.

| Fixture | Project | Preserve / structural action |
| --- | --- | --- |
| `blorp_backend_imported_scalar_global` | `ExitStatusAble_resolve_exit_status_Int` | Preserve imported global and compiler-local main-result spellings. |
| `blorp_backend_primitive_runtime_builtin` | `std_system__now_microseconds`, `std_time__to_year`, exit-status resolver | Preserve `blorp_*` runtime calls and compiler locals. |
| `blorp_backend_print_int` | `std_io____print_string`, `Stringable_to_string_Int`, `std_io__print__mono_Int` | Preserve `blorp_to_string`, `blorp_print`, and locals. |
| `compile_time_intrinsic_specs_materialized` | Positive `parse_intrinsic`; negative `intrinsic_spec` and all six `specs_to_*_dict` helper functions | Preserve `ALL_INTRINSICS`/`INTRINSIC_SPECS` globals. Move absent legacy names `all_intrinsic_specs`, `specs_from_intrinsics`, `intrinsics_from_specs`, `same_intrinsic`, and `intrinsic_name_from_specs` to a source-level absence check because emitted-name hashing makes a C-text negative incapable of detecting their return. |
| `function_ref_uses_selected_import_def_id` | `std_float__sqrt` | Preserve negative runtime `blorp_vector_sqrt`; it proves selected identity. |
| `generic_union_concrete_layout_identity` | None | Preserve all type, field, constructor, and local assertions. |
| `global_constant_generic_record_lifecycle` | None | Preserve types, globals, record makers, runtime calls, and static-storage negatives. |
| `global_constant_generic_union_lifecycle` | None | Preserve types, globals, constructors, `__def_` locals, and runtime calls. |
| `imported_main_function_symbol` | `main_as_function_module__main` | Preserve root C `main`. |
| `list_contains_direct_loop` | `std_list__contains__mono_String`, negative `std_list__any__mono_String` | Preserve loop/body structural assertions. |
| `option_expression_fusion` | All four negative `std_option__*` callables | Keep each negative check pinned to its projected token. |
| `option_nullable_stream` | None initially | Preserve `blorp_stream_*`; replace `__def_*` negatives with structural absence checks for unspecialized closure/call construction after inspecting generated C. |
| `program_entrypoint_exit_status_message` | exit-status resolver and `std_io__print_error__mono_String` | Preserve C `main` and its return-type negative. |
| `string_pipeline_reverse_materialization_fusion` | Negative `std_string__reverse` callable | Preserve pipeline locals; retain the call-shape suffix with the projected token. |
| `string_pipeline_window_materialization_fusion` | Negative `std_string__take_right` callable | Preserve pipeline locals/memcpy; retain the call-shape suffix with the projected token. |
| `tcp_chunks_stream_terminal`, `tcp_lines_stream_terminal` | None | Preserve runtime calls, runtime macros, and deferred error types. |
| `tcp_resource_read_cancellation_cleanup` | `std_net_tcp__read_chunk` | Preserve runtime cleanup/read calls and locals. |
| `tensor_alloc_typed_storage` | None | Preserve global, runtime, and local assertions. |
| `tensor_get_or_callsite_inline` | Negative `std_tensor__get_or__mono_Int` | Preserve negative runtime call assertion separately. |
| `tensor_loop_views_direct` | Four negative `std_tensor__*` callables | Preserve runtime calls and local/view assertions. |
| `tls_chunks_stream_terminal`, `udp_datagram_stream_terminal` | None | Preserve runtime calls, macros, and deferred error types. |
| `option_nullable_managed` | None | Preserve constructor/type/local structural negatives; constructors are deferred. |
| `tuple_return_call_sroa` | Negative `swap`, `pair_expr`, `pair_locals`, and `choose_pair` calls | Preserve local `__def_`, tuple-allocation, and return-shape structural negatives. |

For every projected positive or negative expectation, keep the original
semantic name in an adjacent explanatory source comment. Do not leave an old
semantic callable `EXPECT-NOT-C` line in place, and do not weaken it to absence
of all `bh_` callables. Hash fixed-vector tests are the source of truth for
pinned tokens.

At minimum add or adapt fixtures for:

- forward internal calls;
- imported internal calls;
- trait-selected user implementations after resolution;
- function values and closures with and without captures;
- list-to-string callbacks;
- custom Dict/Set hash and equality callbacks;
- detached and structured-concurrency task bodies;
- an imported function named `main`, proving only the root entry point is
  emitted as C `main`;
- a foreign C name that resembles the generated hash namespace;
- profile-enabled compilation;
- two modules with long, similar qualified function names.

Compile generated C with both the default host compiler path and the codegen
audit warning sweep. Execute representative closure, callback, trait, import,
and concurrency fixtures so matching declarations alone cannot hide a broken
reference.

### Required Gates Per Merge Point

Fast loop while editing:

```bash
make
./blorp test --timeout 180 compiler/tests/test_compiler_c_symbol_projection.brp

tmp=$(mktemp "${TMPDIR:-/tmp}/blorp-symbol.XXXXXX.c")
trap 'rm -f "$tmp"' EXIT
./blorp compile --no-format --no-embed-runtime -o "$tmp" \
  tests/test_compiler/codegen_audit/should_pass/function_ref_uses_selected_import_def_id.brp
cc -fsyntax-only -include compiler/lib/runtime_decl.c "$tmp"

benchmarks/compiler_c_symbol_projection --samples 1
```

This loop builds once. Do not include `scripts/compiler-check --changed` in the
per-edit loop because that command builds again and selects the broad Stage 10
audit. A future `--case FILE` option on `run_codegen_audit.sh` would be useful,
but the direct compile/C-syntax command above is the initial single-case path.

Before each callable merge point:

```bash
scripts/compiler-check --changed
scripts/test --no-build runtime cli
```

Stage 10 ownership must map the changed naming/projection modules to the focused
projection and full emitter suites plus the generated-C audit, so
`compiler-check --changed` is the single compiler-owned pre-commit route. Do
not rerun `compiler-blorp` or the codegen audit separately after it succeeds.

Before claiming the optimization complete, also run the normal preview gates
listed in `AGENTS.md`. Sanitizer coverage is required for the new callable and
closure fixtures because a mismatched function pointer may compile but still be
undefined behavior.

Run these focused generated-program checks before the closure/task merge point:

```bash
./blorp test --sanitize --timeout 180 tests/test_blorp/functions/test_function_ref_escape.brp
./blorp test --sanitize --timeout 180 tests/test_blorp/functions/test_static_closures.brp
./blorp test --sanitize --timeout 180 tests/test_blorp/functions/test_closure_conversion.brp
./blorp test --sanitize --timeout 180 tests/test_blorp/concurrency/test_detach_zero_capture.brp
./blorp test --sanitize --timeout 180 tests/test_blorp/collections/test_custom_hash_callbacks.brp
./blorp test --leak-check --suite --timeout 180 \
  compiler/tests/test_compiler_c_symbol_projection.brp
```

The custom callback fixture is a required new file; use its final path in the
commands and ownership manifest if the collections directory names it
differently.

## Measurement Plan

Extend the existing `benchmarks/compiler_backend_memory` replay harness with a
captured symbol-heavy production request rather than creating a second backend
measurement framework. Add a small
`benchmarks/compiler_c_symbol_projection` driver only for generated-C census
and host-C compilation, plus a bounded fixture directory under
`benchmarks/fixtures/compiler_c_symbol_projection/`. The driver must be
self-contained, deterministic, clean temporary files, and record:

- compiler executable hash and repository revision;
- host C compiler executable, version text, and complete flags;
- fixture-content hash;
- generated C bytes and line count;
- count, total bytes, mean length, and maximum length of top-level callable
  identifiers;
- end-to-end Blorp compile-to-C elapsed time and peak RSS;
- host C `-O0` compile elapsed time and peak RSS;
- object-file bytes;
- at least one optimized host C compile measurement as characterization, not as
  the fast loop.

Use two workloads:

1. A fast synthetic multi-module fixture with many long qualified functions,
   cross-module calls, callbacks, and closures. It should complete in seconds
   and is the per-edit feedback loop.
2. A representative compiler-owned workload with enough emitted functions to
   expose C frontend cost, captured through `compiler_backend_memory`. Use the
   full self-hosted compiler build only for retained before/after evidence, not
   for every edit; a previous attempt to compile the full self-host artifact
   exceeded ten minutes locally.

Take alternating baseline/candidate runs from separate compiler executables.
Use at least one warmup and ten measured pairs for a speedup claim. Report raw
samples, medians, and median absolute deviation. The initial merge may proceed
on a clear generated-C size win with runtime parity even if host-C timing is
noisy, but it must not regress end-to-end compile time by more than 2% on the
bounded workload. Do not count cache effects as the optimization.

Capture one request and replay that exact file from both worktrees:

```bash
capture=$(mktemp "${TMPDIR:-/tmp}/blorp-emit-core.XXXXXX.json")
BLORP_COMPILER_CAPTURE_EMIT_CORE_REQUEST="$capture" \
  ./blorp test --timeout 30 compiler/tests/test_compiler_infer.brp
# Expected: capture exits nonzero after reporting the saved request.

(cd "$baseline_root" && \
  benchmarks/compiler_backend_memory "$capture" --timeout 60 --json)
(cd "$candidate_root" && \
  benchmarks/compiler_backend_memory "$capture" --timeout 60 --json)
```

The comparison driver must alternate those worktree-local workers, retain their
worker hashes, and reject a changed request hash. Backend replay includes JSON
decode/encode and bridge overhead; treat it as backend-route evidence, not a
projection-only timer.

For the host compiler comparison, emit without the runtime and use identical C
flags:

```bash
./blorp compile --no-format --no-embed-runtime -o generated.c fixture.brp
/usr/bin/time -l cc -O0 -fwrapv -pipe -w \
  -include compiler/lib/runtime_decl.c -c generated.c -o generated.o
wc -c generated.c generated.o
size generated.o
```

Use `/usr/bin/time -v` instead of `-l` on Linux. Run the same command at `-O2`
as secondary characterization. Record raw object bytes and section sizes from
`size`; do not compare only stripped executable size.

Run runtime parity outside the timed samples and compare all three observable
channels. The synthetic fixture must print one exact checksum line and return a
nonzero code on an internal mismatch:

```bash
(cd "$baseline_root" && ./blorp run --no-format \
  benchmarks/fixtures/compiler_c_symbol_projection/main.brp \
  >"$tmpdir/baseline.stdout" 2>"$tmpdir/baseline.stderr")
baseline_status=$?
(cd "$candidate_root" && ./blorp run --no-format \
  benchmarks/fixtures/compiler_c_symbol_projection/main.brp \
  >"$tmpdir/candidate.stdout" 2>"$tmpdir/candidate.stderr")
candidate_status=$?
test "$baseline_status" -eq "$candidate_status"
cmp "$tmpdir/baseline.stdout" "$tmpdir/candidate.stdout"
cmp "$tmpdir/baseline.stderr" "$tmpdir/candidate.stderr"
```

The comparison driver owns status capture without shell `errexit` aborting
early and also validates the exact expected checksum output, so identical wrong
outputs do not count as parity.

Initial success criteria:

- no ABI-visible identifier changes in the callable slice;
- no semantic Core or diagnostic spelling changes;
- internal callable identifier bytes reduced by at least 60% on the synthetic
  fixture;
- generated C is smaller;
- inventory hashes each declaration once and projection visits each Core node
  once, with no nested declaration/reference scans;
- bounded end-to-end compile time does not regress by more than 2%;
- host C compile time and peak RSS are recorded before broader rollout.

## Ordered Implementation Slices

### 0. Freeze the Contract

1. Add the benchmark fixture/script and capture a baseline.
2. Add focused characterization tests proving current `main`, foreign,
   builtin/runtime, user, and closure spellings.
3. Add tests proving profile labels and diagnostics currently use semantic
   names.
4. Catalogue generated-C expectations that name internal callables.
5. Record explicitly that Blorp has no supported C export feature.

**Merge point:** measurement and tests only; no production behavior changes.

### 1. Land and Test the Complete Callable Plan

1. Extract `c_identifier` and callable/static-closure derived naming into the
   shared `c_naming.brp`; prove the existing unprojected renderer is unchanged.
2. Add deterministic hashing and encoding with fixed vectors.
3. Add structured callable identity, callable inventory, and preserved-name
   inventory.
4. Add duplicate, stale-identity, collision, and conflict validation.
5. Implement the dedicated exhaustive Stage 10 expression projector for user
   calls, callbacks, closures, tasks, and custom collection callbacks.
6. Keep the projected value as an ordinary test result in this slice; do not yet
   introduce an opaque production wrapper or change linkage/emission.
7. Add pure tests, including injected collisions and stale closure triples.
8. Register module/test ownership.

**Merge point:** the complete callable projection and its validators are tested,
but production C spelling and linkage are unchanged.

### 2. Cut Over All Internal Callables Atomically

1. Add a named internal/external callable-linkage decision based on
   `CoreFunctionKind`.
2. Rename the existing renderer helper as explicitly unprojected-for-tests.
3. Introduce `CProjectedProgram` only now, wrapping a program in which all user,
   closure, task, list-to-string, and custom collection callback references have
   been projected successfully.
4. Project `UserFunction` definitions and every structured `UserCall`.
5. Project `CoreClosureAbi.c_name`, closure-create names, and all task-closure
   names from the same plan; derive static closure objects from body symbols.
6. Resolve string-only callbacks uniquely and fail on missing or ambiguous
   targets.
7. Emit projected user and closure definitions/forward declarations with
   `static` linkage in the same change as renaming, avoiding conflicts with an
   included external declaration that happened to share the old long name.
8. Preserve original profile labels and emission errors.
9. Switch both `compiler/src/pipeline.brp` and
   `compiler/benchmarks/compiler_backend_bridge.brp` to the projected
   production API. The benchmark bridge is production-route measurement, not a
   sanctioned raw-emission bypass.
10. Update the exact positive and negative production naming expectations.
11. Run direct-call, recursion, callback, closure, task, sanitizer, runtime, and
    benchmark gates.

**Merge point:** all artifact-local callable bodies have short C names and
honest internal linkage. Types, constructors, globals, fields, and locals remain
unchanged. There is no partially projected production wrapper.

### 3. Remove String-Only Callable Boundaries

1. Replace `ListToStringCall(String)` and custom collection callback strings
   with structured callable identity.
2. Update lowering, Core JSON, clone/traversal, and prepared-Core tests for the
   new structured variants; this is a representation cleanup, not a naming
   policy change.
3. Add a completeness validator for callable-bearing final Core forms.
4. Remove any transitional unique-name lookup made unnecessary by structured
   identity.

**Merge point:** callable hashing is mechanically complete and no longer relies
on a string-only callback boundary.

### 4. Consolidate and Measure the Callable Cutover

1. Remove any temporary projection inspection helper from Slice 1.
2. Keep the raw renderer test helper only if it remains the clearest unit-test
   boundary; otherwise move renderer tests below projection and delete it.
3. Record retained paired benchmark results and generated-C byte census under
   `benchmarks/results/`.
4. Update this document with measured results and the remaining symbol-byte
   census before broadening eligibility.

### 5. Build Complete ABI Exposure Before Type Hashing

1. Generalize `CRecordLayoutRegistry` into a `CAbiExposureRegistry` or add a
   neighboring registry with one responsibility.
2. Seed it from `DeclaredAbiType`, all foreign function parameter/return types,
   and explicit runtime bridge types.
3. Traverse aliases, value/heap record fields, union payloads, enum ownership,
   and nested generic/layout types to a fixed point.
4. Represent exposure for declaration names, field labels, variant names,
   constructor C names, tag macros, and generated helper/type names.
5. Add foreign headers that inspect records, nested unions/enums, aliases,
   fields, variants, and macros.
6. Only after this registry is complete, extend the projection plan to internal
   aggregate types and their derived helpers as one atomic slice.

**Merge point:** ABI exposure modeling only, followed by separate type-name
projection merge points. Do not combine the registry and type hashing in one
change.

### 6. Consider Globals; Stop Before Locals

1. Inventory `CoreGlobal` declarations, which are already emitted `static`.
2. Project global declarations, exact global references, cleanup references,
   and recursively derived static initializer storage names together.
3. Measure incremental benefit before keeping the change.
4. Leave fields and locals unchanged unless a later census demonstrates a
   meaningful generated-C or host-C cost and scope-aware identity is available.

## Expected Downstream Effects

For callable-only projection, downstream compiler changes should be limited to
Stage 10 emission and Stage 12 error plumbing. Stage 08/09 IR serialization,
Core dumps, DCE roots, specialization, Perceus, reuse, closure conversion, CLI
stage controls, package metadata, and semantic diagnostics should not change.

Generated C snapshots that mention user functions will change. Host C symbol
tables and debugger function names will become opaque for internal callables;
profile labels remain readable by design. Stack traces from native debuggers
will show hashes until a future optional symbol map or debug build policy is
added. Do not add that policy in the initial optimization.

Changing internal functions to `static` may expose duplicate or unused-function
warnings that external linkage previously suppressed. Treat new warnings as
real and update DCE or emission only when the generated function is genuinely
unnecessary. Do not globally suppress them.

Hash spelling is compiler output, not a supported ABI. It may change when the
schema constant changes. Package hashes and runtime caches already include
compiler identity at their own boundaries; do not make this tactical C symbol
schema a package compatibility contract.

## Stop Conditions

Stop and reassess before production projection if any of these occurs:

- a surviving callable reference cannot be tied to an inventoried declaration
  without a name-shape heuristic;
- profiling or error reporting cannot recover the original name locally;
- projection requires changes before final `PreparedCoreProgram`;
- the bounded benchmark shows more than 2% end-to-end regression;
- collision validation cannot include preserved top-level C names;
- generated C differs in a type, field, runtime, foreign, or entry-point name in
  the callable-only slice;
- sanitizer execution reveals a function-pointer signature mismatch.

The response to a stop condition is to improve the representation or narrow the
slice, not to add a prefix heuristic, compatibility environment variable, or
unchecked fallback.
