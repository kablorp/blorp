# Trait identity census

Date: 2026-09-29. Lane A step A2b (the retired identity plan, see Git history). Read-only census at
`origin/main` `fe8069579`; the Core `CoreImplMethodRole` facts come from the
unlanded branch `core/m2-3-trait-method-readers-by-origin` (`177aae3a3`). No
compiler source changed.

## Method

Counts are lines of `blorp/src` (generated inputs excluded) matching the field
names below, classed by keyword: **compare** (`==`/`!=`), **dict key** (`.get`,
`.set`, `.contains`, `Dict`), **render** (string concatenation or
interpolation), **signature/field** (a `trait_name: String` parameter or
record field), **pass-through** (everything else: forwarding, construction).
Literal compares count lines containing a builtin trait spelling
(`"Equatable"`, ...; the 29 names of `builtin_trait_name`) outside
`builtins.brp`. Counts are estimates: a line that both compares and renders is
classed once.

## The identity that already exists

`TraitId` (`headers/declaration_skeleton.brp`) is an opaque `Int`: a graph trait
is its non-negative `DefinitionId`; a compiler builtin is `-(registry_id + 1)`
(`builtin_trait_id_name`, `trait_id_is_compiler_builtin`,
`trait_id_definition_id`, `trait_id_module_id`, `trait_id_name(table, id)`).
The header graph (`callable_headers`, `trait_headers`, `type_parameter_headers`,
`implementation_headers`, `type_header_graph`) already holds `TraitId`
(`bounds: List[TraitId]`, `ImplementationHeader.trait_id`, `owner: TraitId`,
`TraitMethodId = (owner: TraitId, index)`). `BoundTraitIdentity { owner,
definition_id, name, span }` carries it into `BoundTypeParam.bound_identities`
and `ResolvedCallInfo.trait_identity`. The String layer below is the legacy
`Env` and everything that consumes it.

## (1) Every holder of a trait's identity as a String

| Phase | Holder | Kind |
| --- | --- | --- |
| typecheck env | `TraitDef.name`, `TraitDef.supertraits: List[String]`, `TraitDef.def_id` (Int, graph id or a builtin `100+` slot, not the registry `TraitId`) | record |
| typecheck env | `ImplInstance.trait_name`, `ImplInstance.bounds: List[BoundTypeParam]` | record |
| typecheck env | `TraitObligation.trait_name` | record |
| typecheck env | `Env.trait_functions: List[(String, String)]` (function name, trait), `scoped_trait_functions` on the state and module facts | record field |
| typecheck generic params | `type alias TraitRef = String`; `BoundTypeParam.bounds: List[TraitRef]` (beside `bound_identities`); `BoundTraitIdentity.name` | alias, record |
| typecheck infer | `TraitMethodCallee.trait_name`; `ResolvedSelectedTraitMethodCall(String, CallableId)`, `ResolvedUnindexedSelectedTraitMethodCall(String, Int)`, `ResolvedUnresolvedTraitMethodCall(String)` | record, union |
| accepted authority | `trait_indices_by_semantic_name: Dict[String, Int]`, `implementation_indices_by_trait_name: Dict[String, List[Int]]`, `AcceptedQualifiedTraitMethodInfoRep.trait_name`, `AcceptedTraitMethodMatch.declaring_trait_name` | dict keys, records |
| definition index | `TraitDefaultMethods.trait_name`, `ImportedTraitReference.trait_name`, `ExportedCallableSignature.type_parameter_bounds: List[List[String]]` | records |
| module surface | `ModuleSurface.private_traits: List[String]` | record |
| Core IR | `CoreTraitDecl.name`/`supertraits`, `CoreTypeParam.bounds: List[String]`, `CoreImplDecl.trait_name`, `DeferredTraitCall(String, String)`, `SelectedTraitCall(String, String, String, Int)` | IR |
| Core passes | `CoreTraitMethodIdentity.trait_name` (`trait_dispatch.brp`), `CoreGenericBuiltinTarget.trait_name`, `CoreTraitMissingImplDiagnostic.trait_name`, `CoreTraitSelectedTargetDiagnostic.trait_name`, `FunctionTraitTarget(String)`, `DceTraitReference.trait_name`, `DceReachabilityIndex.impl_method_ids_by_trait_method: Dict[String, ...]`, `runtime_projection` name `<Trait>_<method>_<Type>` | records, keys, spelling |
| Core origin (M2.3 branch) | `ImplMethod(trait NameId, method NameId, CoreImplMethodRole)`; `RuntimeCallbackMethod(role)` | union |
| Parser (source of the spellings) | `ParsedImplDecl.trait_name: ParsedIdentifier`, trait `supertraits` and type-parameter `bounds` as `ParsedIdentifier` | AST, carries `NameId` |

### Readers, by phase

| Phase | Lines | Pass-through | Signature or field | Compare | Dict key | Render |
| --- | --- | --- | --- | --- | --- | --- |
| typecheck (stage_06) | 284 | 166 | 60 | 34 | 11 | 13 |
| lowering (stage_08) | 14 | 14 | 0 | 0 | 0 | 0 |
| Core (stage_09) | 166 | 112 | 24 | 17 | 4 | 9 |
| backend (stage_10) | 0 | | | | | |

`trait_name` (and `declaring_trait_name`, `impl_trait_name`) only. Add about 30
reads of `BoundTypeParam.bounds` outside the header layer (`env.brp` 10,
`accepted_trait_implementation_authority.brp` 2, `infer.brp`, `lower.brp`,
`mono_impl.brp`, `ir.brp`, `emit.brp` 3, `format/projection.brp` 2, JSON dumps).
Top files: `env.brp` 105 lines of any trait token, `infer.brp` 84, `decl.brp` 67,
`trait_resolve.brp` 56, `accepted_trait_implementation_authority.brp` 55,
`ir.brp` 43, `synth_scalar_operator.brp` 31.

### Literal compares against builtin trait spellings

68 lines: `infer.brp` 23, `trait_dispatch.brp` 13, `synth_scalar_operator.brp` 12,
`env.brp` 10 (the Equatable / HasLength / Stringable obligation arms at
~3096 to 3146), `lint/command.brp` 4, `trait_resolve.brp` 3,
`accepted_trait_implementation_authority.brp` 2, `format/engine/expression_documents.brp` 1.
Typecheck 35, Core 28.

## (2) Where an id is available at each producer

- **Source traits and impls.** The declaration skeleton and headers hold `TraitId`
  for every trait and `ImplementationHeader.trait_id`. The parsed
  `ParsedIdentifier` also carries a `NameId`. `TypedTraitInfo` and
  `TypedImplInfo` carry only the parsed declaration (no id): a gap A2b closes,
  and the same gap M1.1 recorded for `ImplMethod`.
- **`TraitDef` / `ImplInstance` construction** (`decl.brp` 3586, 4492, 4544):
  the graph `DefinitionTable` is reachable from the state, so `TraitId` can be
  looked up by declaration; builtins are built in `builtins.brp` from
  `BuiltinTrait` kinds, whose registry id gives the `TraitId` directly.
- **`TraitObligation` producers:** `trait_obligations_for_bound_type_param`
  (has `bound_identities` when the param came from headers; not for
  `make_bound_type_param(name, bounds)`, used at 7 source and 48 test sites),
  `decl.brp` 5001 (`"ExitStatusAble"` literal) and 5587 (supertrait
  name), `infer.brp` 1333 (`"Equatable"` literal) and ~9692, the accepted
  authority (~3271).
- **Resolved call targets:** `ResolvedAcceptedTraitMethodCall(TraitId, CallableId)`
  already carries the id; the `Selected`/`Unindexed`/`Unresolved` variants carry
  a String because the legacy path selects by name.
- **Core lowering:** `lower_typed_impl` and `lower_typed_trait` see only the parsed
  declaration; the `TraitId` must come from typed info once it carries one.
  `DeferredTraitCall`/`SelectedTraitCall` are built from the resolved call target.

## (3) NameId or TraitId

`TraitId`. A `NameId` is a spelling identity (`name_table.brp`: two bindings with
one spelling share one id), and traits are module-scoped, so two modules may
declare `trait Renderable`. The accepted headers already retain
`(owner module, definition_id)` because same-named traits "cannot be interchanged
during obligation checking" (`generic_params.brp`); the legacy `Env` layer keys
on the name and does not have that protection. `TraitId` also covers builtins
with one scalar (negative registry ids), so a single type serves the literal
vocabulary and user traits. It needs a `DefinitionTable` to print a name; Core has
`names` (NameTable) but not the definition table, so Core needs either the table
or a small `trait id -> NameId` catalog for diagnostics and the `<Trait>_<method>_<Type>`
symbol (see (6)).

## (4) Smallest first slice

There is no one-field flip at the `Env` layer: every obligation, impl and
supertrait comparison must change type together, and `env.brp` cannot print or
look up a name from a `TraitId` without a definition table. The smallest
coherent, byte-identical start follows the roadmap's own add-beside pattern:

**A2b.1, pin the builtin trait ids and put the id beside the name on the three
Env records.**
- Add `TraitId` constants for the 29 builtin traits (from the registry) and a test
  that each equals `builtin_trait_registry_id(name)` and round-trips
  `builtin_trait_id_name`.
- Add `trait: TraitId` beside `TraitDef.name`, `ImplInstance.trait_name` and
  `TraitObligation.trait_name`, written at every producer (builtins from the
  registry; source traits from the definition table; obligations from
  `bound_identities` or the pinned constants). An invariant test (in the style of
  `origin_name_agreement`) checks the id and the name agree on the self-compile.
  Interim row: "trait name String beside `TraitId` on `TraitDef`, `ImplInstance`,
  `TraitObligation`".
- Files: `env.brp`, `builtins.brp`, `decl.brp`, `infer.brp` (obligation producers),
  `accepted_trait_implementation_authority.brp` (producer at ~3271), a new
  `trait_identity.brp` for the constants; tests `test_typecheck_env`-style suite
  and `test_typecheck_builtins`. No reader moves; no String deleted.

The first slice that deletes a String field is **A2b.2**: move the obligation
readers (`env.brp` arms, `infer.brp` 23 literal lines, the two authority lines,
`decl.brp`) to pinned-id compares and delete `TraitObligation.trait_name`. It is
the ~90-line core of the Equatable/Hashable/Orderable checks and stays
byte-identical because the compared facts do not change.

## (5) Order of the remaining slices

| Slice | What | Files | Gate |
| --- | --- | --- | --- |
| A2b.1 | pinned builtin `TraitId`s; id beside name on `TraitDef`, `ImplInstance`, `TraitObligation`; agreement test | `env.brp`, `builtins.brp`, `decl.brp`, `infer.brp`, authority, new `trait_identity.brp` | `compiler-check --stage typecheck`; identical C |
| A2b.2 | obligation readers by id; delete `TraitObligation.trait_name`; the 10+23 literal compares gone | `env.brp`, `infer.brp`, `decl.brp`, authority | the 860 `should_fail` messages unchanged; identical C |
| A2b.3 | `impl_trait_satisfies_trait` and supertrait walks by `TraitId`; delete `TraitDef.supertraits` Strings and `ImplInstance.trait_name`; dict keys in the authority (`trait_indices_by_semantic_name`, `implementation_indices_by_trait_name`) become `TraitId` keys | `env.brp`, authority, `decl.brp` | typecheck stage, sanitize |
| A2b.4 | `BoundTypeParam.bounds` becomes derived from `bound_identities`; `make_bound_type_param` takes identities; delete `TraitRef`; about 30 readers and 48 test sites | `generic_params.brp`, `env.brp`, `types.brp`, `builtins.brp`, tests | typecheck stage; formatter idempotence (`projection.brp` reads bounds) |
| A2b.5 | resolved call targets and `TraitMethodCallee` by `TraitId`; `Env.trait_functions` and `scoped_trait_functions` keyed by id | `infer.brp`, `state.brp`, `decl.brp` | typecheck stage |
| A2b.6 | typed info carries `TraitId` (`TypedTraitInfo.id`, `TypedImplInfo.trait_id`) so lowering can read it | `decl.brp`, `lower.brp` | Core suites |
| A2b.7 | Core: `CoreImplDecl.trait`, `CoreTraitDecl`, `DeferredTraitCall`/`SelectedTraitCall`, `CoreTraitMethodIdentity`, `CoreTypeParam.bounds`, DCE keys, `trait_resolve` diagnostics, `synth_scalar_operator` (12 literals) and `trait_dispatch` (13) compare pinned ids; JSON codec; a trait catalog for display | `ir.brp`, `trait_dispatch.brp`, `trait_resolve.brp`, `synth_scalar_operator.brp`, `mono_impl.brp`, `dce.brp`, `resolve.brp`, `lower.brp`, `runtime_projection.brp` | `compiler-core-sanitize`, backend identity, leak |

Each slice is one commit, gates as above plus `compiler-check --changed`,
`make hygiene-check` and `--require-identical` stage-2 measurement. Slices 1 to 5
are typecheck-owned; 6 crosses into lowering; 7 is Core-owned and blocks on M2.3
landing (it retires its role enum).

## (6) What reaches Core and how M2.3's role enum retires

Core receives trait identity in six places: `CoreImplDecl.trait_name`,
`CoreTraitDecl` (name, supertraits), `CoreTypeParam.bounds`,
`DeferredTraitCall`/`SelectedTraitCall`, and, on the M2.3 branch,
`CoreFunctionOrigin.ImplMethod(trait NameId, method NameId, CoreImplMethodRole)`.
After A2b.6 lowering can write a `TraitId` at each of them.

M2.3's `CoreImplMethodRole` (`RuntimeCallbackMethod(role) | OrdinaryImplMethod`)
exists only because a Core function cannot say "this is `Stringable.to_string`"
without a trait identity: the role is a pinned pair of builtin spellings
(`StringableToString`, `HashableHash`, `EquatableEquals`). Once `ImplMethod`
carries `(trait: TraitId, method: NameId)`, the three callback roles become the
pinned pairs `(TRAIT_ID_STRINGABLE, name to_string)`,
`(TRAIT_ID_HASHABLE, name hash)`, `(TRAIT_ID_EQUATABLE, name equals)`, and
`runtime_callbacks.brp` matches those constants; `CoreImplMethodRole` and
`CoreRuntimeCallbackRole` delete in A2b.7 with no reader losing information.
Core needs display spellings for diagnostics (`trait_resolve` messages) and the
`<Trait>_<method>_<Type>` C symbol; the recommended source is a per-program
`trait id -> NameId` catalog built at lowering from the definition table, so Core
keeps `TraitId` payloads (an `Int`) and never a trait String.

## Risks

- Builtin `TraitDef.def_id` values (`100+`) are not the registry `TraitId`
  (`-(registry_id + 1)`); A2b.1 must not conflate them (an agreement test pins
  the mapping).
- `make_bound_type_param(name, bounds)` (7 source, 48 test sites) creates params
  with no identities; A2b.4 needs a builder for them.
- Standalone graphs (see the A4a interim row) build headers with private tables:
  a trait's `TraitId` is still a `DefinitionId` there, so trait identity does not
  depend on that precondition, but the display spelling does.
