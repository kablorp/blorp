# Resolved Module Interfaces Roadmap

Status: proposed

Scope: Blorp-owned frontend and typechecker only. This roadmap does not add an
OCaml implementation, a persistent cache, or a new source-language feature.

## Executive Decision

Replace repeated parsed-declaration registration with a required typecheck
phase product: a graph of resolved module interfaces.

Each public declaration must be semantically resolved once for its defining
module. Importing modules should install or reference that resolved export,
while retaining their own import aliases, selective bindings, visibility, and
diagnostics. Private values and callables remain local to the defining module.
Private types may still be non-nameable semantic dependencies of a public
signature if the language permits abstract values of that shape; visibility
must not be confused with semantic reachability.

The first production migration is public functions and foreign functions. It
has the clearest measured payoff and the smallest semantic surface. Globals,
types, traits, and implementations follow only after the callable slice proves
the architecture and performance.

This is not caching. A resolved interface is a mandatory, immutable output of
the current compilation's header-resolution phase. There are no cache keys,
stale values, or invalidation rules.

## Current Evidence

The import-heavy benchmark in
`compiler/blorp/benchmarks/compiler_import_graph_profile.brp` constructs a
30-module graph with 32 functions per module and import fan-out 20. One graph
contains:

- 420 resolved import edges;
- 960 module functions;
- 13,440 imported-function registration opportunities; and
- qualified calls that require every imported function to be usable.

The function profile for one retained-program iteration reported these
inclusive costs:

| Function | Time | Calls |
| --- | ---: | ---: |
| graph typecheck workload | 3,671 ms | 1 |
| register import modules | 2,635 ms | 31 |
| register direct import declarations | 2,562 ms | 420 |
| register imported signature declarations | 2,477 ms | 420 |
| register imported function declaration | 2,370 ms | 13,440 |
| register function from semantic types | 1,492 ms | 13,440 |
| resolve imported function annotation | 695 ms | 26,880 |
| project and resolve imported parameter types | 621 ms | 13,440 |

Function-profile rows are inclusive and must not be added together. They show
that work beneath imported function registration dominates this fixture.

The first attempted optimization only classified parsed declarations ahead of
time and wrapped the module representation in an opaque type. An
apples-to-apples eight-sample comparison measured a median of 1.888 seconds
against a 1.833-second baseline, approximately 3% slower. That representation
is not an accepted optimization. Slice 0 must restore a neutral baseline before
the resolved-interface switch is evaluated.

An orthogonal environment-lookup optimization produced a strong preliminary
result on 2026-08-01.
`compiler_env_find_func_by_def_id` previously rebuilt every scope's symbols in
reverse lookup order before scanning for one callable. A direct reverse scan
reduced the seven-run retained-program median from 1.415 seconds to 1.130
seconds. Adding an exact callable-ID-to-symbol-index map to the private scope
construction/update boundary reduced the median again to 1.042 seconds, with
identical workload counts and checksum. This is approximately 26% below the
pre-change measurement and removes a repeated linear search. These seven-run
measurements guided local implementation; the candidate still requires the
full nine-sample acceptance protocol below before its result is considered
final. It does not change the import-registration architecture or replace
Slice 0.

A direct traversal of `symbols_by_name` in qualified UFCS lookup was measured
and rejected. Its seven-run median was 1.076 seconds versus 1.039 seconds for
the helper-based candidate, approximately 3.5% slower. The source change was
reverted; do not assume fewer apparent list operations are faster without a
new measurement after the underlying list representation changes.

## Goals

1. Resolve each exported callable signature once per defining module.
2. Preserve all current import, visibility, type, trait, resource, purity, and
   diagnostic behavior.
3. Make phase ordering explicit in types. Body typechecking must not accept a
   graph whose required interfaces have not been resolved.
4. Preserve one deterministic graph-wide definition-ID plan.
5. Keep cyclic function imports valid. Callable interface construction must not
   require imported callable bodies or a topological callable order.
6. Reduce expensive work from approximately `import edges * exports` to
   `exports + cheap import installations`.
7. Leave the Typed AST and Core contracts unchanged.

## Non-Goals

- Persistent or cross-invocation interface caching.
- Incremental compilation or invalidation.
- Parallel module typechecking.
- Redesigning source import syntax.
- Replacing every list-backed typechecker index in the same workstream.
- Canonical trait identities in the initial callable slice.
- A serialized public interface format.
- Changes to Core lowering, ownership IR, codegen, or runtime behavior.

## Terminology

**Prepared module**: finalized parsed source plus module identity, origin,
surface, and resolved source-graph edges. This is the existing
`PreparedTypecheckModule` concept.

**Type header context**: graph-owned semantic type declarations needed to
resolve signatures. It contains canonical public type names and definitions,
not function bodies.

**Resolved callable export**: the defining module's canonical, validated
function metadata, including callable ID, semantic function type, generic
bounds, parameter names, purity, origin, resource policy, dimension
constraints, loop-producer metadata, debug-only status, and module identity.

**Resolved module interface**: immutable public exports for exactly one module,
plus its identity and surface. It contains no private declaration.

**Resolved interface graph**: interfaces for all modules and targets in the
current graph, indexed by canonical module path and built from the same
definition plan.

**Import installation**: adding an already-resolved export to a module's
typecheck environment, or eventually binding directly to it. Installation must
not parse annotations, qualify types, infer bounds, or recompute resource
policy.

## Required Invariants

### Phase Invariants

1. `PreparedTypecheckGraph` contains parsed modules and a definition plan, but
   no resolved interfaces.
2. `CompilerResolvedInterfaceGraph` can be constructed only from a prepared
   graph and its exact definition plan.
3. Body typechecking accepts a resolved graph or a module typecheck context
   derived from one. It must not accept an optional interface graph.
4. The pipeline uses separate records for prepared and resolved phases. Do not
   add `interfaces: Option[...]` or a `has_resolved_interfaces: Bool` flag.
5. Every callable ID in an interface comes from the graph definition plan.
   Interface construction must not mint replacement IDs.

### Interface Invariants

1. An interface belongs to one canonical module path and one explicit module
   origin.
2. Every callable export's `module_path` is that interface's module path.
3. Public user functions and public foreign functions are distinct variants or
   are created by distinct smart constructors. A Boolean `is_foreign` flag is
   not acceptable.
4. Private functions, private foreign functions, and private globals cannot be
   inserted through the public-interface constructor. Private type and trait
   identities may appear only as non-nameable semantic dependencies when a
   supported public signature requires them.
5. Export lookup keys are derived from the module surface and validated against
   the resolved declarations. Surface and interface disagreement is a compiler
   invariant failure covered by tests, not a fallback lookup heuristic.
6. Interface access in hot loops is bulk-oriented. Do not repeatedly unwrap an
   opaque module once per field or once per export.

### Semantic Invariants

1. Signature resolution uses the defining module's origin and import bindings,
   not the importing module's origin.
2. Imported aliases and qualified names resolve exactly as they do today.
3. Generic parameter shadowing occurs before module/type alias qualification.
4. Resource argument and result policies are computed once from canonical
   semantic types and then preserved unchanged in every importer.
5. Debug-only and loop-producer metadata are properties of the declaration,
   not the import edge.
6. Imported call resolution retains the original source alias for diagnostics
   and Typed AST metadata while targeting the canonical callable ID.
7. Invalid defining-module declarations produce diagnostics owned by that
   module. They are not duplicated once for every importer.

### Visibility Invariants

1. Module surfaces remain authoritative for public/private name checks.
2. Qualified imports expose only public interface entries.
3. Selective imports bind only the requested public export.
4. A graph-wide export table must not make unrelated modules visible as bare
   names. Visibility continues to require a local declaration, current-module
   ownership, a valid import binding, or builtin status.
5. A private declaration remains usable inside its defining module and
   unavailable by name everywhere else, including qualified lookup. An
   inferred value may retain a private semantic type identity when the language
   deliberately supports that abstraction.

### Ownership Invariants

1. Interfaces are immutable values and may be shared across module typecheck
   contexts.
2. Installing an export must not mutate interface-owned data.
3. Copying an interface should retain its backing graph, not recursively rebuild
   every semantic type.
4. No optimization may depend on COW uniqueness. Correctness must be identical
   for shared and unique interface values.
5. Sanitizer and leak gates must cover interface construction, installation,
   diagnostics, and release.

## Target Pipeline

Current relevant pipeline:

```text
parse/finalize graph
  -> reserve graph definition IDs
  -> build parsed importable modules
  -> prepare CTFE dependencies
  -> for every output module:
       register reachable imported types from parsed declarations
       register direct imported callables from parsed declarations
       register imported traits/impls from parsed declarations
       register local declarations
       typecheck bodies
```

Target pipeline after the callable checkpoint:

```text
parse/finalize graph
  -> reserve graph definition IDs
  -> build authoritative module surfaces and import bindings
  -> build one graph type-header context
  -> resolve one callable interface per module
  -> prepare CTFE dependencies using the same interfaces
  -> for every output module:
       derive module-local import visibility
       install resolved public callables for direct imports
       install the module's own resolved public callables
       resolve private/local-only declarations
       retain legacy trait/impl registration temporarily
       typecheck bodies
```

Longer-term target:

```text
PreparedTypecheckGraph
  -> CompilerGraphDefinitionPlan
  -> CompilerResolvedHeaderGraph
       types
       callables
       globals
       traits
       impls
  -> module-local visibility/binding views
  -> TypedModuleGraph
```

The header graph is a semantic phase product, not a cache and not a second AST.

## Proposed Data Model

Names are illustrative and should be adjusted only when nearby compiler naming
makes a clearer distinction.

```blorp
union CompilerResolvedCallableKind:
    CompilerResolvedUserCallable
    CompilerResolvedForeignCallable


private record CompilerResolvedCallableExportRep {
    source_name: String,
    kind: CompilerResolvedCallableKind,
    symbol: CompilerFuncSymbol
}


opaque type CompilerResolvedCallableExport = CompilerResolvedCallableExportRep


private record CompilerResolvedModuleInterfaceRep {
    module_path: String,
    origin: CompilerModuleOrigin,
    surface: ModuleSurface,
    callables: List[CompilerResolvedCallableExport]
}


opaque type CompilerResolvedModuleInterface = CompilerResolvedModuleInterfaceRep


record CompilerResolvedModuleHeader {
    interface: CompilerResolvedModuleInterface,
    diagnostics: List[String]
}


private record CompilerResolvedInterfaceGraph {
    modules: List[CompilerResolvedModuleHeader],
    modules_by_path: Dict[String, Int],
    definition_plan: CompilerGraphDefinitionPlan
}
```

`CompilerGraphDefinitionPlan` is currently private to
`compiler_typecheck_bridge.brp`. Before another module owns the resolved graph,
move the plan and its reservation operations to a shared stage-06 module. Do
not expose its mutable representation merely to satisfy this sketch. The graph
wrapper may remain private to the bridge until that extraction is justified.

The callable kind must not duplicate a contradictory `CompilerFuncSymbol.origin`.
Prefer separate smart constructors that set both consistently, or replace the
two representations with one precise origin union. The opaque export should be
consumed through operations such as bulk installation and exact lookup so hot
code does not call several ownership-heavy accessors.

Do not put parsed declarations in the resolved callable export. Source spans,
parameter binders, and declaration bodies remain in the prepared module for
body materialization. The resolved export contains only reusable semantic
header information.

If interface construction needs error recovery, represent that explicitly as
`CompilerResolvedModuleHeader {interface, diagnostics}`. Do not label a
diagnostic-bearing header as validated, and do not withhold all recoverable
exports because one sibling declaration is invalid.

## Header Resolution Design

Callable signatures depend on:

- graph-wide reserved definition IDs;
- canonical builtin and user type declarations;
- the defining module's local type names;
- its qualified and selective type-import bindings;
- type aliases and opaque aliases;
- relevant trait declarations for generic bounds;
- module origin for builtin/foreign policy; and
- declaration annotations used for resource, debug, and loop metadata.

They do not depend on imported function bodies. Therefore, callable interfaces
can be resolved for the entire graph without topologically sorting callables.

The first implementation should reuse current, tested type declaration
registration to construct one graph type-header context. It must not duplicate
the type-resolution algorithms in the bridge. Once callable reuse is proven,
the type-header context can receive its own precise representation.

Factor current function registration into two operations:

```text
resolve_function_signature(state, declaration, owner)
  -> state-with-diagnostics + resolved signature

register_resolved_function(state, source name, resolved signature)
  -> state with CompilerFuncSymbol
```

Local declarations and interface construction must call the same resolver.
There must not be separate semantic implementations for local, imported, and
interface functions.

## Cyclic Imports

Do not introduce a topological-order requirement for callable interfaces.
Mutually importing modules can resolve callable headers after the graph's type
and trait headers are available because no callable body is needed.

The graph header builder must have explicit visitation states if it performs
recursive work:

```blorp
enum CompilerHeaderVisitState:
    CompilerHeaderUnvisited
    CompilerHeaderResolving
    CompilerHeaderResolved
```

However, a graph-wide multi-pass builder is preferred over recursive callable
resolution:

1. reserve all IDs;
2. register all public type headers;
3. establish module import/type-resolution contexts;
4. register needed trait headers;
5. resolve all callable headers; and
6. typecheck bodies.

Tests must cover two modules that import and call each other, mutually
referenced public types, recursive aliases, and a cycle with one invalid
signature. If current behavior for any cycle is intentionally unsupported,
add a deliberate early diagnostic before relying on that restriction.

## Diagnostics And Recovery

Interface diagnostics belong to the declaration's defining module. Moving
signature validation earlier must preserve message text, source span, and help
text.

Required behavior:

- The defining module reports an invalid resource boundary once.
- Importers may report a use-site mismatch, but must not repeat the defining
  declaration diagnostic for every edge.
- Unknown imported types identify the defining declaration and unresolved name.
- Private import diagnostics continue to come from surface/import validation,
  before interface lookup.
- Interface/surface mismatch is an internal invariant diagnostic in debug and
  test builds.
- Definition IDs remain reserved even when a declaration has an error, so later
  artifacts and diagnostics are deterministic.

Before changing diagnostic ownership, add graph tests that assert exact error
counts and text for one invalid module imported by several modules.

## File And Ownership Boundaries

Use these intended responsibilities:

| File | Responsibility |
| --- | --- |
| `compiler_imports.brp` | Source import syntax, surfaces, aliases, selective bindings, reachability |
| `compiler_typecheck_types.brp` | Parsed type-expression projection only |
| `compiler_typecheck_header.brp` (new) | Shared type/signature header resolution and resolved interface construction |
| `compiler_typecheck_interface.brp` (new) | Phase-specific interface data and bulk interface operations |
| `compiler_typecheck_decl.brp` | Local declaration orchestration and body materialization |
| `compiler_typecheck_state.brp` | Module-local visibility, bindings, diagnostics, and typecheck state |
| `compiler_env.brp` | Symbol storage and exact/bulk symbol installation |
| `compiler_typecheck_bridge.brp` | Graph phase orchestration, tracing, inventory, CTFE handoff, artifact emission |

Do not move type resolution into stage 04 module loading. Surfaces remain
syntactic; resolved interfaces belong to stage 06.

Do not let `compiler_typecheck_bridge.brp` accumulate declaration matching or
semantic type construction. It should orchestrate typed phase products.

## Incremental Execution Plan

### Slice 0: Restore And Lock The Baseline

Purpose: ensure later numbers compare against a passing implementation without
the measured 3% classifier/accessor regression.

Work:

1. Retain the import-graph benchmark, shared benchmark runner, replay analyzer,
   trace timestamps, and their tests.
2. Remove or replace the parsed-interface representation changes that do not
   independently improve performance.
3. Preserve the private foreign-function visibility fix and its regression test
   if it is separable from the representation experiment.
4. Run alternating baseline/candidate samples from binaries built with the same
   bootstrap compiler, C compiler, flags, prepared bridges, and fixture.
5. Record baseline samples and machine/toolchain details under `results/`.

Tests first:

- exact private foreign export exclusion;
- import benchmark counter/checksum assertions;
- benchmark runner shell tests;
- replay schema and cross-module checkpoint tests.

Exit criteria:

- all existing tests pass;
- benchmark workload has zero diagnostics and exercises every import edge;
- candidate median is within 2% of the clean baseline before semantic work;
- no incomplete source-type projection helpers remain.

### Slice 1: Split Signature Resolution From Environment Mutation

Purpose: establish one semantic implementation used by local and future
interface paths.

Work:

1. Introduce a precise `CompilerResolvedFunctionSignature` phase type.
2. Extract semantic type resolution, effective generic bounds, dimension
   constraints, resource policy, loop producer, and debug metadata from
   `compiler_register_function_signature_with_semantic_types`.
3. Return updated diagnostics state and the resolved signature together.
4. Make existing local and imported registration call the extracted resolver
   and a common registration function.
5. Keep graph behavior unchanged in this slice.

Tests first:

- local and imported versions of the same declaration produce equivalent
  semantic function types;
- generic bound and type-parameter shadowing;
- qualified, selective, and aliased parameter/return types;
- dimension constraints and return-only generics;
- resource argument/result policies;
- pure/impure, debug-only, and loop-producer metadata;
- user versus foreign origin;
- invalid signatures preserve exact diagnostics.

Exit criteria:

- no duplicated signature-construction algorithm remains;
- Typed AST callable IDs and metadata are unchanged;
- benchmark does not regress by more than 2%; and
- the broader compiler test gate passes.

### Slice 2: Introduce Resolved Callable Export Types

Purpose: model reusable public callable headers without changing production
import registration.

Work:

1. Add `compiler_typecheck_interface.brp` with opaque callable export and module
   interface representations.
2. Add smart constructors for public user and public foreign callables.
3. Make module identity and origin constructor inputs, not caller-editable
   fields.
4. Add exact export lookup and one bulk fold/install operation.
5. Build an interface for a focused module in tests, but do not consume it in
   the production graph yet.

Tests first:

- public user and foreign exports retain every `CompilerFuncSymbol` field;
- private user and foreign declarations cannot enter the interface;
- overloads with one source name retain distinct callable IDs;
- duplicate callable IDs or mismatched owner paths are rejected or impossible;
- interface lookup agrees exactly with `ModuleSurface.exports`;
- shared interface values remain unchanged after installation into two states.

Exit criteria:

- no public record constructor can create a contradictory export;
- hot operations unwrap each interface once;
- sanitizer/leak tests pass; and
- production behavior remains unchanged.

### Slice 3: Build One Graph Type-Header Context

Purpose: give every interface resolver the same canonical type universe without
re-registering callable dependencies.

Work:

1. Extract the tested public type-declaration registration portion of
   `compiler_typecheck_register_import_modules` into a graph-header builder.
2. Build canonical public type definitions once for all graph modules.
3. Preserve module-specific import aliases in a separate resolution context;
   do not add all aliases to a shared global namespace.
4. Keep private local types available while resolving their defining module.
   First characterize whether Blorp permits public signatures with non-nameable
   private result or parameter types. Preserve legal abstract-value behavior by
   carrying hidden semantic dependencies without exporting their names; add an
   early diagnostic only if the language rule deliberately rejects the shape.
5. Represent the completed type context as a distinct phase value, not a raw
   partially initialized `CompilerTypecheckState`.

Tests first:

- records, unions, constructors, builtin/resource types, transparent aliases,
  and opaque aliases;
- qualified/selective/aliased imported types;
- same type name in unrelated modules;
- mutually referenced types across a module cycle;
- recursive and cyclic alias termination;
- resource containment and cleanup metadata;
- package/std origin restrictions;
- public signatures involving private types, preserving either deliberate
  abstract-value behavior or the current explicit diagnostic.

Exit criteria:

- each public type declaration is resolved once in benchmark inventory;
- module alias resolution remains module-local;
- no unrelated canonical type becomes available under a bare name; and
- typecheck declaration, bridge, inference, resource, and sanitizer suites pass.

### Slice 4: Build The Resolved Callable Interface Graph

Purpose: resolve every public callable once before body typechecking.

Work:

1. Add a resolved graph phase after definition planning and type-header
   construction.
2. If the resolved graph moves outside the bridge, first move the definition
   plan to a dedicated stage-06 owner without changing ID assignment order.
3. For each module, derive its import-resolution context from parsed import
   declarations and authoritative surfaces.
4. Resolve every public function and public foreign function through the Slice
   1 resolver.
5. Store module-owned diagnostics beside the interface.
6. Add graph indexes by canonical module path. Preserve deterministic source
   order in the primary list for diagnostics and artifacts.
7. Emit trace markers and inventory counts for interface construction.

Required inventory:

```text
resolved_interface_modules
resolved_callable_exports
resolved_callable_signature_resolutions
resolved_callable_diagnostics
```

Tests first:

- graph interface count and exact exported names;
- deterministic IDs across repeated runs and module input permutations already
  considered equivalent by the current contract;
- two cyclically importing function modules;
- one invalid module imported by several modules reports one owner diagnostic;
- unselected dependencies still receive interfaces when required;
- prelude and ambient module handling;
- no parsed declaration or body is retained solely by the callable export.

Exit criteria:

- signature-resolution count equals public callable count, independent of edge
  count;
- graph preparation has an explicit resolved-interface phase type;
- CTFE planning can receive the interface graph without behavior changes; and
- production import registration still uses the legacy path until Slice 5.

### Slice 5: Switch Imported Public Callables To Resolved Exports

Purpose: remove the measured `edges * callables` semantic reconstruction.

Work:

1. Change direct imported callable registration to install exports from the
   resolved interface.
2. Keep source import bindings and visibility in `CompilerTypecheckState`.
3. Preserve alias source names in Typed AST call metadata.
4. Continue legacy parsed registration for globals, traits, and impls in this
   slice.
5. Delete the old imported function and foreign-function semantic resolution
   path in the same change. Do not retain a feature flag or compatibility path.
6. Count cheap installations separately from semantic resolutions.

Required inventory:

```text
resolved_callable_import_installations
legacy_imported_callable_resolutions = 0
```

Tests first:

- qualified, selective, aliased, and combined imports;
- same function name from several modules;
- overload and UFCS selection;
- return-only generics and inferred type parameters;
- resource cleanup and resource-result policy;
- debug-only behavior;
- foreign origin and package restrictions;
- private qualified lookup rejection;
- cyclic function calls across modules;
- exact callable IDs and module paths in Typed AST.

Performance gate:

- import-heavy median improves by at least 10% over the locked Slice 0 baseline;
- target improvement is 20% or more;
- imported dependency signature resolution count is 960 rather than 13,440 for
  the default fixture; the target's 31 callables are counted separately;
- low-import and representative end-to-end workloads do not regress by more
  than 3%; and
- setup plus typecheck total improves, not only one reported phase.

If the count reduction is correct but wall time does not improve, profile
export installation and ownership before proceeding. Do not add caching.

### Slice 6: Reuse Own Public Callable Exports And CTFE Interfaces

Purpose: ensure a public callable is not resolved once for its interface and
again for its own body environment.

Work:

1. Install the defining module's public callable exports into its body context.
2. Resolve/register only private and recovery-only local callables from parsed
   declarations.
3. Use the same interface graph in CTFE dependency typechecking.
4. Preserve the module's local-name precedence over imports and builtins.
5. Remove duplicated CTFE callable header registration.

Tests first:

- public function body recursion and mutual recursion;
- private helper calling public function and inverse;
- local function shadowing imported and builtin names;
- CTFE globals calling qualified, selective, and transitive functions;
- CTFE failure does not mutate or consume interface data;
- ownership inventory remains unique where previously guaranteed.

Exit criteria:

- every public callable signature is resolved exactly once per graph;
- private callables are resolved exactly once per defining module;
- CTFE and normal typecheck target identical callable IDs; and
- leak, sanitizer, compiler, and compiler-deep gates pass.

### Slice 7: Resolved Global Value Exports

Purpose: remove repeated imported global annotation resolution while preserving
CTFE value ownership and mutability rules.

Work:

1. Add a distinct resolved global export variant containing canonical type,
   source type, mutability, module path, and refinement policy.
2. Keep initializer expressions and CTFE values outside the interface.
3. Install global exports through the same module interface boundary.
4. Delete parsed imported-global registration after the switch.

Tests first:

- immutable and mutable globals;
- explicit and inferred annotations;
- qualified/selective/aliased access;
- CTFE constants and imported CTFE values;
- resources and forbidden resource escapes;
- private globals and duplicate names;
- sanitizer/leak coverage for managed global types.

Exit criteria:

- imported global annotation resolution count is declaration-based, not
  edge-based;
- CTFE behavior and artifacts are unchanged; and
- benchmark improvement is retained.

### Slice 8: Resolved Trait And Implementation Headers

Purpose: remove remaining parsed semantic registration while preserving trait
visibility, UFCS, coherence, and ambient impl behavior.

This is intentionally later because current trait identity is partly
string-based and trait collections are module-context-sensitive.

Work:

1. Introduce a canonical trait identity tied to definition ID and owner module.
2. Resolve supertraits and method signatures once.
3. Represent public and private impl visibility explicitly.
4. Preserve orphan checks, conflict checks, default methods, method callable
   IDs, resource policies, and ambient tuple impl injection.
5. Make module-local trait method scope a binding view over resolved traits,
   not a graph-global bare-name table.
6. Delete parsed imported trait/impl registration after parity is proven.

Tests first:

- qualified and selective traits;
- same trait/method names in unrelated modules;
- supertraits and default methods;
- UFCS overload selection;
- generic impls and bounds;
- orphan/conflicting/private impl diagnostics;
- resource trait methods;
- ambient tuple impl behavior;
- cyclic supertrait termination or deliberate diagnostics.

Exit criteria:

- trait and impl identity is no longer inferred from a bare string where module
  ownership matters;
- all trait/impl registration is interface-based; and
- no visibility leak is possible through a shared graph table.

### Slice 9: Complete Resolved Type Exports And Bulk Environments

Purpose: replace the temporary graph type-header state with a precise reusable
type interface and reduce remaining symbol-installation ownership traffic.

Work:

1. Add resolved type export variants for records, unions, builtins/resources,
   transparent aliases, opaque aliases, and constructors.
2. Preserve containment summaries and cleanup metadata in the resolved export.
3. Replace per-module canonical imported type reconstruction.
4. Add `compiler_env_add_symbols` or a shared immutable export scope only if a
   profile shows per-symbol installation remains material.
5. Keep module-local visibility as an explicit binding view even if symbol
   storage becomes graph-shared.

Tests first:

- exact type/constructor identities and homes;
- recursive data types and aliases;
- resources, function carriers, and one-shot stream summaries;
- private and opaque visibility;
- COW shared/unique equivalence;
- bulk installation has the same lookup order and shadowing as individual
  installation.

Exit criteria:

- parsed importable declarations are no longer needed by semantic consumers;
- bulk installation is measurably faster before it is retained; and
- no environment lookup behavior changes.

### Slice 10: Delete Transitional Representations

Purpose: leave one coherent frontend architecture.

Work:

1. Delete `CompilerImportableTypeDecl`,
   `CompilerImportableSignatureDecl`, and parsed semantic registration helpers
   once their last consumer is gone.
2. Narrow or rename `CompilerImportableModule` to a syntactic source/surface
   concept if CTFE or tooling still needs parsed declarations.
3. Remove bridge inventory fields that describe obsolete parsed-interface work.
4. Update `docs/ARCHITECTURE.md` and `docs/COMPILER_ROADMAP.md` with the final
   phase boundary.
5. Scan for dead accessors, fallback paths, feature flags, and stale comments.

Exit criteria:

- one resolver constructs each semantic export kind;
- one resolved interface graph feeds typechecking and CTFE;
- no semantic consumer reconstructs imported declarations from parsed syntax;
- docs, traces, metrics, and names describe the implemented architecture; and
- broad premerge gates pass.

## Correctness Test Matrix

Every production switch must cover these dimensions, using existing tests where
they already assert the exact behavior:

| Dimension | Required cases |
| --- | --- |
| Import form | qualified, selective, aliased, combined alias/selective, default alias |
| Visibility | public, private, private foreign, private type exposure |
| Identity | duplicate source names, overloads, stable callable/constructor/trait IDs |
| Types | records, unions, aliases, opaque aliases, generics, ranges, tensor dimensions |
| Traits | bounds, supertraits, UFCS, defaults, impl coherence, ambient impls |
| Effects | purity, debug-only, foreign/builtin origin, resource policies |
| Graph | transitive dependencies, unselected dependencies, prelude, cycles |
| CTFE | imported constants, function calls, failure recovery, reused artifacts |
| Diagnostics | exact message, owner module, count, source span, deterministic order |
| Ownership | shared interfaces, repeated installation, sanitizer, leak check |

Add focused tests before changing a production path. Do not rely only on the
synthetic performance fixture.

## Benchmark Protocol

Use the existing runner so baseline and candidate compile with the same pinned
compiler, prepared bridges, C toolchain, and flags.

Primary command:

```bash
BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 \
  benchmarks/compiler_import_graph_profile 3 30 32 20 retained
```

Profile command:

```bash
BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 \
BLORP_IMPORT_GRAPH_PROFILE_FUNCTIONS=1 \
  benchmarks/compiler_import_graph_profile 1 30 32 20 retained
```

For each performance switch:

1. Build baseline and candidate executables once.
2. Alternate baseline/candidate order to reduce thermal and load bias.
3. Collect at least nine valid samples from each executable.
4. Compare medians and retain raw samples.
5. Verify identical semantic counters, zero errors, and checksum.
6. Run one low-import control and at least two representative end-to-end
   programs.
7. Record compiler revision, bootstrap compiler hash, C compiler/version,
   platform, arguments, and environment.

Add scaling controls:

- fixed function count while increasing fan-out;
- fixed fan-out while increasing functions per module;
- generic/alias-heavy signatures rather than only `Int -> Int`; and
- a low-import graph to expose setup overhead.

The key algorithmic assertion is stronger than timing:

```text
resolved_callable_signature_resolutions == public callable declarations
```

It must not grow when only import fan-out increases.

## Validation Gates

Run focused gates after each slice and broad gates at every production switch:

```bash
make
./blorp test --no-format compiler/blorp/tests/test_compiler_imports.brp
./blorp test --no-format compiler/blorp/tests/test_compiler_typecheck_decl.brp
./blorp test --no-format compiler/blorp/tests/test_compiler_typecheck_bridge.brp
./blorp test --no-format compiler/blorp/tests/test_compiler_typecheck_resource_decl.brp
./blorp test --no-format compiler/blorp/tests/test_compiler_import_graph_profile_benchmark.brp
python3 tests/test_compiler_typecheck_replay.py
scripts/test compiler-unit
scripts/test compiler
scripts/test compiler-deep
scripts/test compiler-blorp-sanitize
scripts/test leak
make fmt-check
git diff --check
```

Use `scripts/test --no-build` only when the compiler artifact is known to match
the source under test. Clean generated C artifacts after manual compilation.

## Review Checkpoints

Request a focused review before each production switch:

1. after the signature resolver is split;
2. after interface invariants and ownership are modeled;
3. before legacy callable import registration is deleted;
4. before CTFE begins consuming interfaces;
5. before trait/impl identity changes; and
6. before transitional parsed interfaces are deleted.

Review questions:

- Can any constructor produce an export owned by the wrong module?
- Can a private symbol reach qualified or selective lookup?
- Can body typechecking run without the resolved phase product?
- Is any semantic work still proportional to import edges unnecessarily?
- Are diagnostics owned and ordered exactly once?
- Are IDs deterministic and shared across typecheck, CTFE, Typed AST, and Core?
- Is a claimed speedup supported by balanced measurements?

## Stop And Rollback Rules

Stop a slice and revert its production switch when any of these holds:

- semantic resolution counts still scale with import fan-out;
- the import-heavy median improves less than 10% after the callable switch;
- a representative low-import workload regresses more than 3%;
- visibility requires a name/path heuristic not represented in state;
- cyclic imports become order-dependent;
- diagnostics are duplicated or move to the wrong module;
- interface sharing depends on COW uniqueness; or
- both parsed and resolved semantic paths must remain indefinitely.

Benchmark, trace, inventory, and test improvements may be retained separately
when they are independently correct. A failed representation experiment should
not remain merely because later work might amortize it.

## Definition Of Done

The roadmap is complete when:

1. Every supported public semantic declaration is resolved once per defining
   module into a required interface graph.
2. Import edges contain visibility/binding work but no parser-to-semantic type
   reconstruction.
3. Public and private visibility is guaranteed by interface construction and
   module-local binding views.
4. Cyclic imports are either supported deterministically or rejected early by
   an explicit tested language rule.
5. Definition IDs are identical across interface resolution, body typecheck,
   CTFE, Typed AST, and Core.
6. Parsed semantic import registration and transitional fallback paths are
   deleted.
7. The import-heavy benchmark shows a clear retained end-to-end improvement,
   and low-import representative programs do not regress materially.
8. Compiler, deep, sanitizer, leak, format, and quality gates pass.
9. Architecture documentation matches the final phase products and file
   ownership.
