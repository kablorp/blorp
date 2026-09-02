# Compiler Compatibility Ledger

**Audit date:** 2026-08-31

**Audited revision:** `55f272ca`

**Scope:** `blorp/src/compiler/`, excluding generated `stage_01_generated_inputs/embedded_std.brp`

This ledger distinguishes code that preserves an older accepted behavior from
ordinary correctness fallbacks, portability code, version checks, and
in-progress architecture. Blorp is pre-0.1, so a compatibility path is not a
reason to preserve old behavior indefinitely. Each retained path needs either
a current semantic purpose or a concrete removal prerequisite.

## Summary

| Class | Count | Assessment |
| --- | ---: | --- |
| User-facing source compatibility | 0 accepted forms; 1 diagnostic-only path | Legacy opaque-conversion spellings were rejected on 2026-08-31 |
| Bootstrap-only implementation bridges | 4 clusters | Likely removable, but each needs a focused two-generation self-host check |
| Internal test/client compatibility | 5 clusters | Mostly small; remove after tightening construction boundaries |
| Transitional representation adapters | 1 cluster | Still required by the current upstream representation |
| Legacy compiler architecture | 1 large program | Known and roadmap-owned; not safe for piecemeal deletion |
| Reviewed false positives | 9 families | Retain; these are not legacy compatibility |

The directly identifiable active compatibility helpers are modest: roughly 220-300
production lines across Core ownership, CTFE, and explicit bootstrap-shaped
code. That number excludes the type-containment side-table representation and
understates migration cost. The resolved source-syntax migration touched
hundreds of call sites; the remaining accepted-declaration `Env` architecture
spans many readers and writers and does not yet have a responsible line-count
estimate.

## Resolved Entries

### COMPAT-001: Legacy opaque-conversion spellings

| Field | Finding |
| --- | --- |
| Category | Removed user-facing acceptance; diagnostic-only migration tail retained |
| Old behavior | Accept `into Type(value)` and `from Type(value)` as opaque conversions |
| Current behavior | `into_opaque Type(value)` and `from_opaque Type(value)` |
| Introduced | `11942daf` on 2026-08-21, explicitly for one bootstrap transition |
| Resolved | 2026-08-31: migrated repository sources and fixtures, made the formatter preserve explicit keywords, removed the accepting parser/completion branches and obsolete editor highlighting, and updated GUIDE and GRAMMAR |
| Retained code | `starts_removed_opaque_conversion` and `reject_removed_opaque_conversion` recognize only enough of the old shape to reject it with `into_opaque`/`from_opaque` replacement help |
| Diagnostic removal prerequisite | Remove the diagnostic-only lookahead after one preview/bootstrap migration cycle; keep the rejection regression by asserting the ordinary parser error instead |
| Verification | Pinned-bootstrap build, parser regression, formatter/CLI, compiler, standard-library, runtime, sanitizer, leak, generated-C, and LSP checks passed in the implementing change |
| Recommendation | **Keep the syntax rejected; retire the diagnostic after one migration cycle** |
| Confidence | High |

The immutable bootstrap `dev-12f30feecf23` postdated the bridge and successfully
accepted the explicit syntax used to build the migrated compiler.

## Active Compatibility And Migration Entries

### COMPAT-002: Resource-rewrite evaluation-order bootstrap bridges

| Field | Finding |
| --- | --- |
| Category | Bootstrap-only implementation bridge |
| Locations | `stage_09_core/resource_management.brp:846-871`, `:1576-1589`, `:1606-1631` |
| Preserved behavior | Sequences rewritten fields and match operands in locals before constructing records or union payloads |
| Reason | Older emitters could evaluate record fields out of order, inline union payload arguments, or release a cleanup owner while a sibling computation still borrowed it |
| Introduced | `f2e0f72b` on 2026-08-12 |
| Size | Roughly 35-45 sequencing lines; the surrounding rewrite functions remain necessary |
| Removal prerequisite | Inline each of the three shapes independently, inspect the generated C for evaluation order and ownership, run focused ownership/leak tests, and compile the compiler twice using the pinned bootstrap and the newly built compiler |
| Recommendation | **Test and remove now** |
| Confidence | Medium-high |

The current bootstrap pin postdates this workaround. There is no public
language behavior to preserve. Treat the constructor-length record, literal
match, and constructor match as three independent experiments: one passing
shape does not prove the others safe.

### COMPAT-003: Pre-contract Core call-ownership fallback

| Field | Finding |
| --- | --- |
| Category | Internal fixture compatibility / incomplete invariant |
| Location | `stage_09_core/match_projection.brp:1086-1102`, consumed near `:1137` |
| Preserved behavior | Guesses whether calls lacking a complete ownership contract return owned values |
| Current production invariant | Final Core invariants reject unresolved calls before emission |
| Reason retained | Match projection cannot currently report the invalid pre-contract state, and tests construct it |
| Size | 17-line helper plus one call site |
| Removal prerequisite | Make ownership contracts mandatory at the projection boundary, or return a typed projection error; update fixtures to construct legal phase-specific Core |
| Recommendation | **Remove through a narrow invariant-tightening issue** |
| Confidence | High |

This is not a source-language compatibility promise. It is exactly the kind of
test-only invalid-state support that should disappear once the phase boundary
can reject it explicitly.

### COMPAT-004: Duplicate imported-module CTFE merge

| Field | Finding |
| --- | --- |
| Category | Internal API historical behavior |
| Locations | `stage_07_ctfe/context.brp:597-627`, `:669`, `:740-750` |
| Preserved behavior | `ctfe_context_from_program` merges repeated manually supplied modules with the same canonical path |
| Current production invariant | Prepared CTFE dependencies are deduplicated by canonical module path |
| Test consumer | `test_ctfe_context.brp`, “context merges duplicate imported module groups” |
| Introduced | `29013174` on 2026-08-09 |
| Size | Approximately 40 production lines and one focused test |
| Removal prerequisite | Make the constructor consume a deduplicated imported-program type, validate uniqueness at construction, or make the raw constructor private to the production preparation path |
| Recommendation | **Remove after strengthening the constructor boundary** |
| Confidence | High |

Deleting only the merge would make duplicate inputs silently produce duplicate
groups. The replacement should make duplicate module paths unrepresentable or
return a clear construction error.

### COMPAT-005: CTFE function-reference type fallback

| Field | Finding |
| --- | --- |
| Category | Invalid internal-state compatibility |
| Location | `stage_07_ctfe/materialize.brp:399-412` |
| Preserved behavior | Materializes a `CtfeFunctionReferenceValue` whose semantic type is not a function by substituting `[] -> Void` |
| Current invariant | The variant should always carry `SemanticFunctionType` |
| Introduced | `26aafc8f` on 2026-08-06 |
| Size | Four fallback lines inside an otherwise required branch |
| Removal prerequisite | Put function parameters and return type in the variant payload, or introduce a smart constructor/phase-specific type that can only accept a function type; reject malformed values at construction |
| Recommendation | **Make the invariant structural, then delete the fallback** |
| Confidence | High |

This fallback can turn an internal compiler defect into incorrect generated
call metadata. It should not remain merely because no production path is
expected to reach it.

### COMPAT-006: Legacy single-letter semantic type parameters

| Field | Finding |
| --- | --- |
| Category | Internal representation compatibility |
| Locations | `stage_06_typecheck/type_system/semantic_type.brp:272-281`, `:1317-1321`; `stage_06_typecheck/infer.brp:7296-7304` |
| Preserved behavior | Treats bare `SemanticNamedType("T", [])`-style uppercase single-letter names as type variables |
| Current representation | `SemanticTypeVar(name)` explicitly represents a type variable |
| Current consumers | Two production compatibility consumers remain; 21 exact single-letter constructions occur in 7 test files, while dynamic production producers still need inventory |
| Size | Roughly 15 explicit production lines, with a broader producer/test migration surface |
| Removal prerequisite | Inventory and convert all semantic-type constructors that encode type variables as bare named types; add a negative invariant preventing new occurrences |
| Recommendation | **Create a focused representation-normalization issue** |
| Confidence | High |

This is distinct from allowing source-level type parameters named `T`. The
source spelling remains valid; only the compiler's semantic representation
should stop guessing from a one-letter name. `is_type_param_name` has no
production callers and can be removed with its three direct unit assertions;
the live production compatibility behavior is in `collect_type_vars` and
`type_contains_type_var`.

### COMPAT-007: Perceus duplicate-identity precedence

| Field | Finding |
| --- | --- |
| Category | Malformed Core compatibility / missing ingress validation |
| Locations | `stage_09_core/perceus.brp:720-745`, `:848-869`; `stage_09_core/dce.brp:1371-1404` |
| Preserved behavior | Perceus keeps the first duplicate global with the same exact identity and the last matching unscoped constructor contract; DCE independently keeps the first global declaration by name |
| Current intended invariant | Exact definition identities should be unique and conflicting metadata should be rejected before ownership analysis |
| Size | Approximately 20-30 conditional/lookup lines inside required indexes |
| Removal prerequisite | Validate exact global and constructor identities at Core ingress, then simplify both the Perceus and DCE indexes to unique typed entries |
| Recommendation | **Add ingress validation before simplifying** |
| Confidence | Medium-high |

The current deterministic precedence prevents nondeterminism, but it also lets
an illegal duplicate state proceed. This is internal compatibility, not a
language guarantee. A Perceus-only cleanup would be incomplete because DCE
recreates the same first-global precedence independently.

### COMPAT-008: Foreign linker argument-group splitting

| Field | Finding |
| --- | --- |
| Category | Transitional representation adapter, not yet removable compatibility |
| Location | `stage_10_backend/build_artifact_builder.brp:25-52`, with callers near `:86` and `:163` |
| Input representation | Core and generated C artifacts still carry one string that may contain several linker argv items |
| Output representation | `BuildArtifact` carries one typed `BuildLinkArgument` per argv item |
| Introduced | `e1f215a0` on 2026-07-20 |
| Size | Approximately 30-40 production lines plus tests |
| Removal prerequisite | Change typechecking/Core/C-artifact producers to carry `List[BuildLinkArgument]` or an equivalent itemized representation from their construction boundary |
| Recommendation | **Retain until the upstream representation changes; do not call it backwards compatibility in new code** |
| Confidence | High |

The comment calls the input a “temporary legacy group,” but the current
production data model still produces groups such as `-framework Cocoa`.
Removing the splitter today would change or break valid foreign-link metadata.

### COMPAT-009: Accepted-declaration `Env` architecture

| Field | Finding |
| --- | --- |
| Category | Large internal legacy architecture, not public backwards compatibility |
| Primary locations | `stage_06_typecheck/type_system/env.brp`; `stage_06_typecheck/decl.brp`; `infer.brp`; header and module-view modules |
| Remaining categories | Graph-owned aliases, types, constructors, fields, globals, functions, overloads, traits, trait methods, implementations, implementation methods, and UFCS candidates; each roadmap issue must verify its current readers/writers before cutover |
| Current replacement | Accepted declaration catalog plus per-module visibility views |
| Current status | The catalog exists as an isolated test/benchmark product but is not yet retained as complete production authority; the environment-reuse roadmap sequences production retention and category cutovers |
| Lower-bound size signal | At least 27 public `env_add`/`env_get`/`env_find` entry points concern variables, functions, traits, implementations, or overloads; lexical uses must be separated from graph-declaration uses before counting removable lines |
| Removal prerequisite | Complete `docs/issues/compiler-performance/ENVIRONMENT_REUSE_ROADMAP.md` through Issue 43, including each issue's reader/writer inventory and deletion criteria |
| Recommendation | **Proceed through the isolated roadmap issues; do not remove individual reads outside their authority cutover** |
| Confidence | High that the architecture is legacy; intentionally not estimated in lines yet |

`docs/ARCHITECTURE.md` explicitly says callables, globals, traits, and
implementations still use the legacy accepted-environment path. A precise LOC
number before the roadmap's category-specific query inventories would be misleading because the
same `Env` APIs also own valid lexical variables, refinements, type parameters,
and provisional header state.

The “legacy Env spelling” adapters in
`stage_06_typecheck/headers/type_header_install.brp:526-554` belong to this
entry. They preserve owner-local versus importer-local naming during header
installation and currently have production callers. They are not an
independent compatibility shim that can be deleted first.

### COMPAT-010: Expanded match-pattern bootstrap bridge

| Field | Finding |
| --- | --- |
| Category | Bootstrap-only source-shape bridge |
| Location | `stage_09_core/match_projection.brp:1196-1275` |
| Preserved behavior | Spells three releasing-match cases as separate nested matches instead of one equivalent overlapping-pattern match |
| Reason | Older bootstraps miscompiled the compact overlapping patterns |
| Introduced | `846216c8` on 2026-08-12 |
| Size | About 80 lines, most of which are three deliberately expanded copies of the same control-flow shape |
| Removal prerequisite | Write the compact equivalent, compare generated C and focused match-ownership behavior, then run a two-generation self-host plus sanitizer and leak gates |
| Recommendation | **Test as an isolated simplification** |
| Confidence | High |

The materialization behavior itself is required: a managed non-variable
scrutinee must be bound before applying a releasing match policy. Only the
duplicated source spelling is compatibility code.

### COMPAT-011: Global-resolution owning-context bootstrap shell

| Field | Finding |
| --- | --- |
| Category | Bootstrap-only ownership bridge |
| Locations | `stage_09_core/resolve.brp:243-246`, `:826-842`, `:1537-1541`, `:1750-1754` |
| Preserved behavior | Carries `resolutions` and `scope` through an owning `CoreGlobalValueResolveContext` shell at recursive edges |
| Reason | The bootstrap could pass the managed fields as borrows and release an extended scope while a sibling still used it |
| Introduced | Context shell dates to `7e9f8dd6` on 2026-07-20; the explicit ownership explanation and dispatcher split were completed in `1930ff25` on 2026-08-13 |
| Size | A small record and its construction/projection sites; approximately 15-25 compatibility-shaped lines |
| Removal prerequisite | Remove only the context shell, inspect generated C ownership, run resolve/ownership/leak tests, and prove two-generation self-hosting |
| Recommendation | **Test and remove independently of dispatcher flattening** |
| Confidence | High |

The iterative cast, logical-expression, and right-associated-sequence
dispatch remains necessary for generated-C frame-depth safety. It is not part
of this removal candidate.

### COMPAT-012: Type-containment side-table bootstrap representation

| Field | Finding |
| --- | --- |
| Category | Bootstrap-only representation bridge |
| Locations | `stage_06_typecheck/type_system/env.brp:147-159`, fields at `:375-376`, and readers/writers of `accepted_type_containment` and `type_containment_scope_snapshots` |
| Preserved behavior | Stores graph-owned containment facts beside symbols in `Env` side tables rather than embedding the cache fields in foundational symbol payloads |
| Reason | The bootstrap corrupted recursive type projections when those fields were embedded in symbol payloads |
| Introduced | `e3616e35` on 2026-08-16 |
| Size | Representation-wide; intentionally excluded from the direct-helper line estimate until the alternative payload shape is prototyped |
| Removal prerequisite | Prototype the embedded representation with the current bootstrap, verify recursive-type projection and containment tests, measure build impact, and prove two-generation self-hosting |
| Recommendation | **Evaluate before the remaining `Env` cutover; fold into that project if it is not independently simpler** |
| Confidence | High that the side-table shape is bootstrap-driven; medium that embedding remains the preferred current design |

This entry overlaps the broader accepted-declaration `Env` architecture but
has a distinct removal test. If an environment-reuse roadmap issue changes the
owning representation first, close this entry by documenting that the
compatibility shape was subsumed rather than attempting a separate rewrite.

## Reviewed Non-Candidates

These matches should not be included in a compatibility-code total:

| Match | Classification | Decision |
| --- | --- | --- |
| Package manifest `[compat].std` and `COMPILER_PACKAGE_CURRENT_STD_COMPAT` | Intentional package/version contract; it rejects mismatches rather than emulating old behavior | Retain |
| `BuildCompatibility` | Build/run configuration for debug, profile, optimization, sanitizers, and leak checking | Retain; consider a clearer name separately |
| `importable_module_request_aliases` and `prepared_module_import_identity_index` first-wins handling in `stage_06_typecheck/bridge.brp:1478-1502` | Canonical module identity normalization plus the current deterministic resolution contract for ambiguous aliases | Retain unless those representations are unified and ambiguity is rejected or given a new explicit rule |
| `Int`/`Void` main-return intrinsic fallback | Current language rule and robustness for graph clients without source-level std evidence | Retain pending a separate semantic decision |
| Bridge schema version checks | Strict protocol validation; no old schema is accepted | Retain |
| Tensor, collection, CTFE, match, and lookup “fallback” variables | Correctness paths, optimization fallbacks, or data-structure fallback storage | Retain |
| Perceus `balance_let_body_legacy` and legacy-count adapters | Active ownership-balancing algorithms and conservative correctness fallbacks, not support for older input | Retain; rename or replace only with complete ownership evidence |
| CTFE environment representation accessors | Encapsulation debt caused by missing module-private collaborators, not legacy behavior | Track as architecture cleanup, not compatibility |
| Callable-header profiling through `blorp_black_box_int` | Bootstrap-conscious profiling implementation with active runtime consumers | Retain until profiling has a typed intrinsic replacement |

## Recommended Removal Order

1. **Resource rewrite sequencing:** test the record, literal-match, and
   constructor-match shapes independently, with generated-C inspection and
   two-generation self-hosting.
2. **Expanded match patterns:** compact the three duplicated branches only if
   ownership tests and two-generation self-hosting prove the current bootstrap
   handles the overlapping pattern correctly.
3. **Global-resolution context shell:** remove only the ownership shell; retain
   the depth-safe iterative dispatch.
4. **Type-containment side table:** prototype embedded symbol facts before the
   remaining `Env` cutover, or explicitly subsume it into that project.
5. **CTFE malformed-value fallback:** make function-reference types structural.
6. **Legacy semantic type variables:** remove the dead helper, migrate fixtures
   and any dynamically discovered producers to
   `SemanticTypeVar` and enforce the representation.
7. **CTFE duplicate-module behavior:** make canonical-path uniqueness a
   constructor invariant, then remove the merge and its compatibility test.
8. **Pre-contract Core fallback:** establish a typed projection error or a
   phase-specific input type, then delete invalid fixtures.
9. **Perceus duplicate identities:** reject malformed Core at ingress before
   simplifying precedence behavior.
10. **Typechecker declaration authority:** execute
   `docs/issues/compiler-performance/ENVIRONMENT_REUSE_ROADMAP.md` as its own
   measured architectural project.
11. **Foreign link groups:** address only as part of a typed foreign-metadata
   representation change.

Most entries are candidates for focused cleanup issues. The type-containment
prototype and declaration-authority work are explicitly not quick compatibility
purges: they change representation or authority throughout Stage 06's type-system
and typechecking layers and need the evidence specified above and in their roadmap.

## Audit Queries

The initial inventory used explicit markers and then classified every result:

```bash
rg -n -i '\b(legacy|deprecated|obsolete|compatibility|historical|pre-contract)\b' \
  blorp/src/compiler --glob '*.brp' --glob '*.c' --glob '*.h' \
  --glob '!**/embedded_std.brp'

rg -n -i '(remove .* (after|when|once)|temporary|transition|migration|bridge)' \
  blorp/src/compiler --glob '*.brp' --glob '!**/embedded_std.brp'

rg -n -i 'bootstrap' \
  blorp/src/compiler --glob '*.brp' --glob '!**/embedded_std.brp'

rg -n '\b(into|from) [A-Z][A-Za-z0-9_]*(\[[^]]+\])?\(' \
  blorp/src standard_library/src blorp/test standard_library/test \
  --glob '*.brp' --glob '!**/embedded_std.brp'
```

For each candidate, `git log -S`, `git blame`, production callers, tests, and
current architecture/issue documentation were inspected. Counts in this file
are search-based migration estimates, not claimed deletion diffstats. Each
removal issue should report its actual production-versus-test diffstat after
implementation.

## Maintenance Rule

New temporary compatibility code should include a searchable marker of the
form `COMPAT-<issue>:`, its removal prerequisite, and an owning test. Update
this ledger when the path is added or removed. Avoid using “fallback” as a
compatibility marker because that word already names many ordinary semantic
and optimization paths.
