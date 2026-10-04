# Record caller census (2026-10-03)

Integration base: `d29b264e1a74d73a1c0c02f437437947660c3ff3`.
The brace-anchored declaration census contains **147 products: 127 under
`blorp/src`, 20 under `standard_library/src`, none under `pkg`**. These
are source declarations, not a dynamic allocation estimate. This document
records the read-only classification before the semantic cut.

```sh
rg -n '^\s*(private\s+)?struct\s+[A-Za-z_][A-Za-z_0-9]*\s*\{' \
  blorp/src standard_library/src pkg -g '*.brp'
rg -n '^\s*foreign\b' blorp/src standard_library/src -g '*.brp' -g '!embedded_std.brp'
```

All 147 declaration bodies contain scalars, fieldless enums, scalar-backed
opaque identities, or nested structs. There is no generic production
struct. A coordinated conversion makes the nested products managed fields
of ordinary records; field accesses, record literals, functional updates,
opaque accessors, collection types and function signatures retain their
logical APIs. No wrapper should be deleted merely because it is small:
`TraitMethodIdRep` encodes owner plus ordinal, and
`AcceptedUnionConstructorLocator` encodes union, variant and visibility.

The following tables include every declaration, grouped by source owner.
Paths in the compiler tables are relative to `blorp/src`; named test suites
are relative to `blorp/test`. `Managed` means no identified ABI obligation,
not an assertion that the allocation cost is small. `Inline` means current
table, token, frame or hot scalar placement is deliberate. Both groups
converge to ordinary record semantics; inline placement becomes S5 work.

## Discovery: 61 declarations

The 42 declarations in `compiler_new/stage_01_discovery/tables/rows.brp`
are:

| Declarations | Retained sink |
| --- | --- |
| RowRange | Nested range fields throughout row and builder products |
| SourceRow, PackageRow, ModuleRow, ModulePackageRow | Source/package/module tables |
| ImportRow, ImportItemRow, ImportItemVariantRow, ImportTargetRow, ImportAliasRow, ImportItemAliasRow | Import tables |
| DefinitionRow, ImplRow, MemberRow, DocumentationRow, ModuleDocumentationRow | Definition/documentation tables |
| InterpolationPartRow, PendingAnnotationRow, AnnotationRow | Literal/annotation tables |
| TypeParameterRow, BoundRow, BoundQualifierRow, SupertraitRow, SupertraitQualifierRow | Type-parameter and trait tables |
| SignatureRow, ParameterRow, BinderNameRow, ParameterTypeRow, DefinitionTypeRow, VariantPayloadRow, DimensionConstraintRow | Signature/type-node tables |
| ImportBlockRow, ForeignBlockRow, ForeignArgumentRow, ForeignBindingRow, ForeignCNameRow, ResourceCleanupRow | Declaration metadata tables; these describe foreign source syntax, not C ABI values |
| BodyRow, NodeRow, DimensionNameRow, NodeNameSpanRow, ElseKeywordRow | Body/node/name-span tables |

Classification: Inline. The authoritative `DiscoveryTables`/`FrontendTables`
and threaded `DiscoveryBuilder` retain these rows in `List` tables. `Span`
and table ids are opaque `Int`s, not native mirrors. Exact owners are
`compiler_new/stage_01_discovery/tables/test_allocation_budget.brp`, table
invariant suites and `parse/test_parser_fixtures.brp`. The allocation budget
currently forbids one allocation per repeated row; S4 must replace its
no-per-row assumption with measured family counts while retaining a sharp
guard against copying the builder or entire table on every append.

The other 19 discovery declarations are:

| Source under compiler_new/stage_01_discovery | Declarations | Class and sink | Test owner |
| --- | --- | --- | --- |
| tables/token.brp | Token | Inline `DiscoveryBuilder.tokens: List[Token]` | lex/test_lexer.brp; tables/test_allocation_budget.brp |
| tables/source_position.brp | LineColumn | Managed position projection result | source-position/table suites |
| tables/row_kinds.brp | NodeSchema | Managed payload/arity/name-span descriptor | table invariant/node schema suites |
| tables/invariants/violation.brp | TableInvariantViolation | Managed diagnostic collection/result | tables/invariants suites |
| tables/builder.brp | ModuleOpeningFields, ImportOpeningFields, ImportItemOpeningFields, OwnedRows, WrittenTypeParameter, ForeignBlockOpeningFields | Managed parser/builder handoff, nested row/range fields | tables and parser suites; allocation budget |
| lex/string_literals.brp | PipeLineScan | Managed scalar scan result | lex suites |
| lex/lexer.brp | NumberScan, SymbolMatch, LexRange | Managed hot scan result/range | lex/test_lexer.brp |
| lex/layout.brp | LineStartPlan | Managed scalar layout plan | lex layout suites |
| parse/definition_openings.brp | OpeningFields | Managed nested declaration/owned-row handoff | parse/test_parser_fixtures.brp |
| parse/declaration_header.brp | DeclarationHeader | Managed parser header handoff | parse/test_parser_fixtures.brp |
| parse/body_scope.brp | BodyScope | Managed body-scope context | parse/test_parser_fixtures.brp |
| parse/trait_reference_parser.brp | WrittenQualifier | Managed qualified trait scan result | parse/test_parser_fixtures.brp |

## Existing compiler: 55 declarations

| Source under compiler | Declarations | Class and sink | Test owner |
| --- | --- | --- | --- |
| discovery_adapter.brp | NodeView | Managed row-to-legacy-AST projection | compiler-new parity; discovery adapter suites |
| stage_02_lex/token.brp | Token, TaggedPayload | Inline token `List`; tag/payload projection | stage_02_lex/test_token.brp and test_lexer.brp |
| stage_02_lex/lexer.brp | LambdaBodyLevel, LineSpacesScan, PipeMarkerScan, RawPipeStartMarkerScan, SymbolMatch, NumberScan | Inline lambda-level `List`; managed hot scalar scan handoffs with nested source Cursor | stage_02_lex/test_lexer.brp |
| stage_03_parse/language_parser.brp | ParserStep, ParsePostfixContinuationStep, ParseSymbolStep, ParsedInfixInfo, TokenRange | Managed hot parser handoffs; nested token-range fields | stage_03_parse/test_parser.brp |
| stage_06_typecheck/infer.brp | ResourceCapabilityPresence | Managed scalar type-capability result | typecheck/infer resource suites |
| stage_06_typecheck/decl.brp | GlobalHeaderCompletionMetrics, FrontendDeclarationPreparationObservation | Managed graph metrics field and benchmark observations | pipeline/test_global_header_completion.brp; frontend preparation profile suites |
| stage_06_typecheck/headers/callable_headers.brp | CallableHeaderModuleRange | Inline `Dict[Int, CallableHeaderModuleRange]` plus current `Option` range | callable-header suites |
| stage_06_typecheck/headers/type_header_graph.brp | TypeContainmentFacts, InlineLayoutFrame | Managed containment facts; inline iterative DFS `List` | pipeline/test_type_header_graph.brp |
| stage_06_typecheck/headers/trait_headers.brp | TraitVisitFrame | Inline iterative DFS `List` | trait-header suites |
| stage_06_typecheck/headers/global_header_completion.brp | GlobalDependencyDfsFrame | Inline iterative dependency DFS `List` | pipeline/test_global_header_completion.brp |
| stage_06_typecheck/headers/declaration_skeleton.brp | TraitMethodIdRep | Managed opaque identity backing; owner plus ordinal must remain coupled | stage_06_typecheck/test_declaration_skeleton_graph.brp |
| stage_06_typecheck/bridge.brp | CtfeMaterializationMetrics, TypecheckedProgramOwnership, CtfeAttemptedBodyChecks | Managed metric/ownership observation and attempted-check handoff | stage_06_typecheck/test_typecheck_bridge.brp; CTFE pipeline suites |
| stage_06_typecheck/modules/module_view.brp | BoundAcceptedLocalCandidateRow, BoundRejectedLocalCandidateRow, BoundRejectedImportRow, BoundImportedNamePayload, BoundConstructorPayload | Inline candidate `List`s; nested imported-name/constructor payloads | stage_06_typecheck/test_module_view.brp |
| stage_06_typecheck/type_system/semantic_type.brp | CanonicalModuleTypeNameSplit, QualifiedTypeNameSplit | Managed scalar string-index scan results | semantic-type suites |
| stage_06_typecheck/type_system/accepted_union_authority.brp | AcceptedUnionConstructorLocator | Inline nested `List[Dict[String,List[...]]]`, builtin/visible constructor maps | stage_06_typecheck/test_accepted_union_authority.brp |
| stage_06_typecheck/type_system/refinement.brp | IndexSpan | Managed scalar interval result | refinement suites |
| stage_06_typecheck/type_system/accepted_callable_authority.brp | AcceptedCallableModuleRange | Inline per-module `List`; `Option` lookup result | accepted-callable authority suites |
| stage_06_typecheck/type_system/env.brp | TypeContainmentSummary, AcceptedTypeContainmentFacts, ImplMethodTarget | Managed nested containment facts and method-target result | type environment and accepted semantic catalog suites |
| stage_07_ctfe/body_worklist.brp | CtfeBodyWorklistMetrics | Managed worklist metric field | CTFE worklist/pipeline suites |
| stage_09_core/work_profile.brp | CoreProgramWorkStats, CoreDeclarationLookupWork, CoreExprWorkStats | Managed work counter results | Core work-profile/complexity benchmark suites |
| stage_09_core/parallel_tensor_pipeline.brp | CoreParallelStdCall | Managed scalar call-classification result | parallel tensor pipeline suites |
| stage_09_core/resolve.brp | CoreCallResolveEnvObservation | Managed benchmark observation result | Core call-resolve profile suites |
| stage_09_core/specialize_tensor_dispatch.brp | StaticMatrixDimensions, StaticMatrixMultiplyDimensions | Managed scalar specialization plans | stage_09_core/test_core_specialize_tensor_dispatch.brp |
| stage_09_core/ir.brp | CoreSourceLocRow | Inline compact source-location row storage | Core lower/source-location and JSON suites |
| stage_09_core/perceus/uses.brp | PerceusOwnershipSummaryFrame | Inline reusable summary `List` frame stack | stage_09_core/test_core_perceus.brp; ownership sanitizer |
| stage_09_core/perceus/borrowed.brp | BorrowedOwnerOrigin, BorrowedChildMode | Managed nested owner entry and traversal mode | Core Perceus/borrowed-owner suites |
| stage_09_core/tailrec.brp | ListSpreadPlan | Managed scalar binding/offset plan | Core tailrec suites |
| stage_09_core/allocation_analysis.brp | DfsFrame | Inline iterative dependency DFS `List` | stage_09_core/test_core_allocation_analysis.brp |
| stage_10_backend/profile_renderer.brp | ProfileFunctionId | Managed `Option` profiling selector/metadata value; not native profiler ABI | backend profile renderer suites |
| stage_10_backend/emit.brp | PositiveBinaryFloat | Managed scalar float literal decomposition | stage_10_backend/test_core_emit.brp |

## Tools/library support: 11 declarations

| Source under blorp/src | Declarations | Class and sink | Test owner |
| --- | --- | --- | --- |
| lib/source.brp | Cursor, SourceLineColumnSpan | Managed nested lexer cursor and source-span result | lib/test_source.brp; lexer/parser suites |
| lib/frontend_validation.brp | FrontendValidationOptions | Managed frontend validation configuration | frontend validation/CLI suites |
| lib/build_artifact.brp | BuildCompatibility | Managed build configuration comparison | lib/test_build_artifact.brp; stage_10_backend/test_build_artifact.brp |
| lsp/protocol/frame_codec.brp | FrameLimitsRep | Managed opaque decoder-limit backing | LSP frame-codec suites |
| lsp/protocol/position.brp | ProtocolPosition, ProtocolRange, PositionScan | Managed nested protocol positions and UTF-16 scan result; JSON boundary, not C ABI | LSP protocol-position suites |
| test/session_counter.brp | TestSessionCounters | Managed discovery/session metrics | test/test_session_counter.brp |
| test/discovery.brp | CliTestSourceFeatures | Managed scalar discovery result | test/test_discovery.brp |
| test/artifact_result.brp | CliTestArtifactResult | Managed parsed artifact result | test/test_artifact_result.brp |

## Standard library: 20 declarations

| Source under standard_library/src | Declarations | Class and sink | Test owner and S4 action |
| --- | --- | --- | --- |
| memory.brp | MemStats | Native C return-by-value builtin mirror, 16 `Int` fields | Runtime memory/allocation oracles; S3 explicit snapshot adapter plus nonperturbing interval API required |
| instrumentation.brp | SchedulerStats | Native C return-by-value builtin mirror, 30 `Int` fields | Scheduler/concurrency instrumentation tests; S3 explicit native snapshot adapter |
| range.brp | Range | Special Core/runtime range representation | Range/loop/stack-option suites and value_record_range codegen audit; S3/S4 intrinsic plan required |
| time.brp | Instant | Managed opaque logical timestamp wrapper; builtins consume/expose raw `Int`, not Instant by value | runtime/sys/test_time.brp; update stack-placement documentation |
| json.brp | JsonScanner | Managed hot parser state | runtime/text/test_json_parser.brp |
| parser.brp | Cursor, Span | Managed nested parser state, closure/return/record fields | runtime/text/test_parser_combinators.brp; parser span/closure runtime regressions |
| geographic.brp | Projected | Managed numeric result | Geographic doctests/runtime checks |
| dsp.brp | BiquadCoeffs, BiquadState, AdsrState | Managed hot DSP coefficient/state values | runtime/numeric/test_dsp.brp; measured temporary cost |
| geometry.brp | Vec2, Vec3, AABB2, Circle2, Ray, AABB3, Hit, Camera, Camera2D | Managed hot geometry values; Ray/AABB3/Hit/Camera/Camera2D own nested vectors | runtime/numeric/test_geometry.brp; measured temporary cost |

## Foreign boundary proof and limitations

Every actual production foreign block was inspected (30 blocks under
`blorp/src`, none in portable `standard_library/src`). Their parameter/result
types are scalars, String/Bytes, existing managed opaque table/graph values,
CoreExpr/CoreType/TypedProgram and lists. **None uses any of the 147 structs
directly by value.** Quoted embedded standard-library source was excluded
from this audit. Range and both stats types reach native code through
builtins, and therefore remain actual exceptions despite the absence of a
`foreign:` declaration.

This closes the production caller census, not external user FFI coverage.
Foreign by-value record fixtures, nested/Option ABI cases and their generated
signatures belong to S3. No native adapter or global semantic change was
implemented by this census. Dynamic allocation counts and generated-C
ownership remain unverified until the coordinator grants a serial compile
slot.

## Source-facing test migration

- Four inference managed-field negatives (`struct_string_field`,
  `struct_list_field`, `struct_option_field`, `struct_record_field`) become
  constructive passing fixtures.
- Typecheck `fixed_record_managed_field`, `fixed_record_heap_record_field`
  and `fixed_record_empty` become passing fixtures.
- Discovery `struct_generic_params`, `fixed_record_type_parameters`,
  `fixed_record_dimension_parameters`, and `fixed_record_empty_parameters`
  become passing fixtures. Ordinary records already accept empty `[]`.
- Mandatory direct/mutual product cycles remain rejected using ordinary
  record diagnostics. Option/Result/list/sum recursion follows existing
  record admission, not former inline-size checks.
- Runtime allocation identity becomes managed for struct/fixed aliases;
  scalar allocation identity stays false. Managed child sharing and COW
  preserve value semantics.
- Runtime fixed-layout and vector tests retain logical/ownership behavior;
  their numeric allocation oracles wait for admitted stats observation
  semantics and measured constructor costs. Vector fill must still share a
  single record rather than allocate once per slot.
- Codegen audits `fixed_record_matches_struct_layout`,
  `blorp_backend_value_record_construct`, `blorp_backend_cross_module_struct_field`,
  `vector_struct_get_or_inline_storage`, `compiler_record_layout`,
  `union_struct_enum_payload_typed`, and `erased_union_boxed_payload_ownership`
  replace inline product expectations with owned pointer-field evidence.
  Scalar stack Option/list storage expectations remain intact.
- Manual Core suites change together with their IR/API definitions. The
  coordinator subsequently assigned clone/resolve/mono/closure/flatten/
  trait-resolve/DCE/fairness suites and their passes to S2; S4 owns the
  remaining policy/ownership/backend/lowering suites. Formatter retains source
  form only for formatting, with ordinary semantic ownership.

No numeric allocation oracle has been loosened or removed. Outstanding inline
optimization opportunities are a separate S5 investigation, not an S4
prerequisite.

## Retained discovery measurement loop

`benchmarks/blorp/compiler_discovery_record_allocations.brp` runs the same
23 parse families with the owning test module's 2,000-repeat input builder.
Inputs precede the reset. The parser helper retains its builder, checks no
diagnostics and the expected token population, checks both active gates, then
reads `ManagedAllocations`; reporting follows the read. A rejected family or
inactive gate makes the probe fail instead of producing a zero count.

After the coordinator admits a fresh candidate with the native scalar API:

```sh
bin/blorp run --memory-stats benchmarks/blorp/compiler_discovery_record_allocations.brp
# For a single family's repeatability loop, pass its printed family name:
bin/blorp run --memory-stats benchmarks/blorp/compiler_discovery_record_allocations.brp -- expression_statements
```

Run serially and retain each output. Check current `run --help` argument
syntax before invoking the single-family form. New pins must use the repeated
measured count per family, with the existing sharp tolerance protecting
builder/table copies. Do not raise one shared ceiling. The direct row-append
case remains in the owning suite and needs its own measured scalar count.
Neither probe nor changed numeric oracles has been run at this checkpoint.

## Disjoint deletion and oracle checkpoint

S2 removed obsolete value-product arms/imports from flatten, clone, resolve,
mono, mono_data, mono_instance, mono_substitute, mono_specialize, closure,
trait_resolve, DCE, and fairness. The value-product mono template and its
collection/materialization/rewrite helpers are deleted, not converted at
runtime. Matching closure, flatten, and DCE direct tests use existing managed
product paths; DCE field release policies derive from the ordinary type-policy
function. Tuple, sum, scalar Option, and bounded Range branches are untouched.

Exact differential fixtures now read scalar allocation endpoints with active
gates: all consume-owned families, tuple flatten, map allocation oracle, and
String split/replace intervals. Logical workloads and all numeric limits remain
unchanged. General snapshot APIs remain honestly allocating; no subtraction or
observer-traffic hiding was introduced. These changes await shared-IR compiled
acceptance, and codegen expectations still await actual candidate C.

The subsequent type/layout-analysis batch removes nominal value-product arms
from c_type_layout, result_layout, operation_metadata, runtime_projection,
backend_projection, type_policy, unmanaged_type, allocation_analysis, and
allocation_contracts. The unsupported owned-inline index/kind/error boundary
is deleted entirely; S4 owns its pipeline and emitter validation callers.
Native snapshot records retain ordinary managed layout, with their native
projection confined to the dedicated snapshot adapter. Synthetic foreign
classification tests retain pointer-boundary collection coverage rather than
by-value C layout expectations.

The four direct layout/policy/projection/allocation-contract suites now use
managed products. Remaining struct-box allocation witnesses use actual scalar
Option[Int] values; typed-versus-erased payload tests use supported Int128,
and nullable pointer tests use String. Scalar Option stack/list/tuple storage,
wide integers, Result, enums, and bounded Range remain supported. This batch
is source-inspected and diff-clean, not compiled or measured yet.

The collection/synthesis batch removes nominal inline-product branches from
list_layout, collection_policy/pipeline, synth_context/list/hash_collections,
and specialize_collection/layout. The synthesis value-product name column and
layout variant disappear. Direct tests retain declaration/alias coverage with
managed pointers, nullable managed Options, ARC element metadata, and borrowed
managed fold initialization. Nested Option[Int] keeps the genuine boxed-option
fallback covered; scalar stack Option storage and fresh-box release remain.

Remaining mono-substitute/data, hash-key-callback, and value-specialization
fixtures now use ordinary records. Mono equality expectations pin scalar,
String, and nested-record release policies. The adapter mismatch regression
keeps exact impl identity but deliberately supplies a stale scalar Option slot,
so it still rejects an actual slot-layout mismatch. The FFI consumer no longer
accepts nominal products as scalar-by-value arguments; bounded Range and scalar
sum paths remain.

Four retained benchmark fixtures migrate their dead Core/header shapes. The
typecheck-phase header fingerprint schema now hashes the record tag, field
count/identities/types, parameters, and containment without a deleted layout
category. Mono-parameter coverage retains separate logical Product and
HeapRecord samples. None of these updated workloads has been compiled or run.

The authoritative range witness module is registered under typecheck with
accepted-record-authority, inference, and Core-lower suites. Read-only manifest
validation succeeds with 366 production modules, 263 suites, and 9 checks;
the changed-base selector selects real gates. This is manifest evidence only,
not execution evidence.

## Bounded consumer cleanup audit

The S2-family read-only audit found 0 P0/P1 issues, 1 P2 coverage issue, and
P3 cleanup remnants. The duplicate-template mono test had become two identical
managed templates and no longer distinguished first-wins behavior. The approved
correction makes the second same-name declaration's field Int while the first
substitutes String, preserving exact String ownership in the expected result.
Approved P3 corrections remove the unused value-record hash tag and retired
type-policy-suite imports, and update misleading hash-layout comments and mono
test labels. These corrections are diff-clean but await compiled validation.

The zero-producer first-class Core RangeExpr consumer is removed from flatten,
DCE, closure, allocation_contracts, std_inline, SSA, traverse, and
cancellation_plan. Precise-word searches found no direct constructors in the
matching S2 suites. Core RangeType bounded integers, ForRangeExpr loops, and
TypedRangeExpr source/typed syntax remain; S4 owns IR/emission removal.

The first integrated compile exposed a mechanical deletion error: a suffix
match removed ForRangeExpr alternatives, and a leading removed-variant arm
also swallowed surviving alternatives. Repairs restore five loop alternatives,
LiteralMatchExpr/IfExpr allocation classification, and RangeType's ordinary
Option-layout classification. The corrected check compares every baseline
ForRangeExpr alternative byte-for-byte, with exact-symbol counts unchanged in
all eight walker files, and checks all 30 mixed CoreType alternatives against
baseline (the nested TypeSubstitution case was verified separately). This
failure invalidates the earlier name-absence-only preservation claim; corrected
source still requires a successful integrated build and focused tests.
