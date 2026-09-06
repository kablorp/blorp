# Stage 6 Dense Module-Index Migration Roadmap

**Status:** Measured and rejected at the cumulative production gate

**Relationship to prior work:** This roadmap follows Issues 45-50 and 55. It
does not revive Issue 45's rejected broad `GraphModuleId` representation.
Issue 46 retained the existing private prepared-scope table slot for the
TypeHeader product, Issue 50 retained index-local ordinal import adjacency,
and Issue 55 retained Stage 04 module/reference tables through the direct
Stage 06 handoff. Issues 48 and 49 and the isolated global/callable extensions
in Issue 46 were measured and rejected as standalone production changes.

Those results establish two constraints for this roadmap:

1. dense list addressing is substantially cheaper in focused windows; and
2. adding conversion, provenance, or projection work for one lightly used
   product can erase that saving at whole-compiler scale.

## Measured Implementation Result

The first cumulative candidate was implemented and measured from baseline
commit `56ecd5e7`. Its source patch SHA-256 was
`32585345cc35bc980f0d662dce781fd99ab371c41984e2c82e0d163cfeb9a7ca`.
The candidate:

- removed the record-valued map from `ImportableModuleIndex` and projected
  modules through the existing path-to-ordinal map;
- changed `BoundModuleGraph`'s canonical-path dictionary values from
  `BoundModule` records to target-first integer positions;
- replaced the temporary global-header completion outer module dictionary
  with prepared-scope-indexed module buckets; and
- hoisted each existing type-header installation value out of its declaration
  loop, without changing that value's representation or semantics.

The accepted global/callable authority migration was excluded after the
dependency-boundary audit recorded below. A temporary prepared-scope carrier
was also removed before final timing because exact function instrumentation
showed that it retired none of the production lookup calls it was intended to
remove.

### Identities and raw evidence

- baseline compiler SHA-256:
  `e479bc27f4f59f29759aa37d1c6e6bb12e10e4490001935ad26d282e75ffa191`;
- candidate compiler SHA-256:
  `83f41c18df6578f5e0e0d6fe6255db8a9159f4ca6e1393e645ac5d76a634df92`;
- production request SHA-256:
  `44fc4314518f3e18bd720da4077dbeb2323e2cc73569aa1e6a684d480c46c2b5`
  (`11,661,656` bytes);
- replay request SHA-256:
  `fa8ceee4b71c3767521ac70853eb6f4d146dc0c872c4a8dce5434fc89a5d9f82`;
- response SHA-256:
  `5b7dbfd8d0e9df52c8f9114a1563cb913c30a0dc0c4f1847743a78c798dd1da9`
  (`1,755,080` bytes);
- baseline replay worker SHA-256:
  `d016d8d53eb5ba7d92a53cfc331fb7bfd9dee3d27fcf6379e663136f88eac5ff`;
- candidate replay worker SHA-256:
  `9a93f4b8a70df693c98ed9b1186852fc90ddda4e1f060aae6158c99c10d43f06`;
  and
- ignored raw logs:
  `logs/stage6-dense-module-index/`.

The compiler hashes were recorded contemporaneously after serial matched
builds with the same bootstrap compiler. The baseline artifact was
`/private/tmp/blorp-stage6-dense-baseline-56ecd5e7/bin/blorp`; the candidate
artifact was this worktree's `bin/blorp`. The replay worker paths were
`/private/tmp/blorp-stage6-dense-baseline-worker-56ecd5e7/compiler_typecheck_worker`
and `/private/tmp/blorp-stage6-dense-candidate-worker-final/compiler_typecheck_worker`.
Those temporary paths are provenance for this experiment, not durable build
artifacts.

### Synthetic accepted-graph matrix

The final source was measured with three alternating baseline/candidate pairs
per row. Every pair produced the same stage, dimensions, output counts,
checksum, retained-object count, and cumulative allocated-byte count. Exact
median results were:

| Modules | Shapes/module | Fan-out | Allocations baseline | Allocations candidate | Allocation delta | Focused elapsed delta |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 1 | 1 | 11,345 | 11,339 | -0.053% | +2.484% |
| 8 | 1 | 4 | 72,650 | 72,532 | -0.162% | +7.339% |
| 8 | 16 | 4 | 190,312 | 188,874 | -0.756% | +3.014% |
| 8 | 64 | 4 | 857,383 | 851,721 | -0.660% | -6.947% |
| 32 | 16 | 1 | 834,450 | 816,404 | -2.163% | +15.867% |
| 32 | 16 | 4 | 875,829 | 857,783 | -2.060% | +15.463% |
| 32 | 16 | 31 | 1,055,188 | 1,037,142 | -1.710% | +16.576% |
| 128 | 16 | 4 | 5,202,283 | 4,933,485 | -5.167% | +37.861% |

Release counts fell by the same deterministic work pattern, from `0.078%` at
the singleton through `6.658%` at 128 modules. The function-profile runner
also emitted high-volume instrumentation data on stderr outside the one-line
captured summaries. Even with that caveat, the candidate's repeated focused
latency regressions at 32 and 128 modules are material negative evidence, not
noise to discard.

This was a reduced sentinel matrix varying module count, declaration shape
count, and import fan-out with accepted graphs and `type_bearing_percent=100`.
The broader predeclared topology, declaration-mix, duplicate-name, selection,
and recoverable-state matrix below was not run after the candidate failed both
the focused latency signal and the cumulative production gate. The reduction
is an explicit stop condition, not evidence that those dimensions passed.

### Production replay and whole-compiler result

One warmup and three alternating pairs were run both with and without
allocator collection. All measured runs were verified, remained below the
memory limit, had allocator data when requested, and produced byte-identical
request, replay-request, and response identities. Each worker's bridge hash
was stable across its own runs; baseline and candidate bridge hashes differed
as expected because they identify different worker binaries.

Production replay medians changed as follows:

| Metric | Baseline | Candidate | Delta |
| --- | ---: | ---: | ---: |
| Elapsed | 8.593 s | 8.573 s | -0.236% |
| Peak RSS | 508,166,144 | 508,166,144 | 0.000% |
| Total allocations | 65,853,177 | 65,801,389 | -51,788 (-0.0786%) |
| Total releases | 60,612,226 | 60,560,440 | -51,786 (-0.0854%) |
| Current objects | 5,240,951 | 5,240,949 | -2 |
| Allocated bytes | 473,489,776 | 473,455,728 | -34,048 (-0.0072%) |

The graph-preparation interval accounts for the complete allocation delta:
`56,407,041` to `56,355,253` allocations (`-0.0918%`). Typecheck-complete
checkpoint time improved by `1.557%`; graph-importables improved by `1.879%`;
other sub-millisecond or noisy checkpoint deltas were mixed.

Three alternating whole-compiler checks produced byte-identical stdout.
Median retired instructions changed from `116,337,208,463` to
`116,300,567,501`, a reduction of `36,640,962` (`-0.0315%`). Median elapsed
changed from `8.15 s` to `8.13 s`, sampled RSS fell by `655,360` bytes
(`-0.0791%`), peak footprint fell by `589,848` bytes (`-0.0717%`), and cycles
fell by `0.346%`. Those effects are directionally positive but well below the
predeclared `1%` cumulative retired-instruction gate.

### Generated-C finding and decision

Generated C confirmed that the candidate used unboxed integer dictionary
values followed by list reads, stored `String -> Int` in `BoundModuleGraph`,
used a dense list of per-module global-header dictionaries, and constructed
one type-header installation value outside each category loop. It also showed
the expected ARC/list access around managed module products. In addition, the
dense global-header builder's `get_or(module_index, {})` eagerly allocated and
released an empty dictionary for every lookup even when the dense index was
valid. That concrete implementation cost qualifies the allocation result and
likely contributes to the focused latency regression. Integer outer
addressing did not remove the dominant semantic conversion and graph
preparation work.

The cumulative candidate was therefore rejected and its production and test
changes were restored. No acceptance threshold was weakened after seeing the
result. The measurements support continuing normalization only at boundaries
that retire a materially represented repeated operation, rather than adding
dense addressing to lightly used products. In particular, the remaining
`type_header_graph_owner_provides_prelude_type` work occurs inside recursive
semantic-type conversion; changing that path is not a mechanical outer-index
migration and requires a separately scoped issue and measurement contract.

## Long-Term Direction

The broader direction is a normalized set of immutable tables for compilation
entities. Modules, declarations, functions, globals, types, traits,
implementations, paths, and other compiler-owned entities should increasingly
have one authoritative table entry and a compact invocation-local ID. Products
that describe relationships between those entities should primarily carry IDs
rather than duplicate descriptive records and strings.

Conceptually, the compiler moves toward data shaped like:

```text
module table:       ModuleId       -> module metadata and source product
declaration table:  DeclarationId  -> declaration facts
type table:         TypeId         -> type facts
callable table:     CallableId     -> callable facts
relationships:      compact IDs    -> compact IDs or dense ID-indexed buckets
```

This normalization has two connected benefits:

1. repeated hashing, string comparison, record copying, ARC traffic, and
   descriptive reconstruction can become integer comparison and list access;
   and
2. compiler relationships become directly explorable. Questions such as
	"which declarations belong to this module?", "which callables reference
	this type?", "which modules import this module?", and "which semantic
	entities are visible here?" can be answered by traversing explicit table
	relationships instead of rediscovering associations from nested records.

That relational shape is useful for compilation, diagnostics, profiling, and
language tooling. It can support faster graph algorithms and indexes while
also making ownership and phase boundaries easier to inspect. It is not a
request to add a general database, mutable global interner, or cross-run cache.
The tables remain immutable compiler phase products, and their compact IDs are
meaningful only with the table that issued them.

Modules are the first meaningful step because module resolution already
creates a validated, complete table and because module identity is copied into
nearly every later entity family. Establishing module IDs as the normal
internal relationship key gives later declaration, type, callable, trait, and
implementation tables a stable dimension to build on. It also lets us measure
the end-to-end value of normalization before expanding it to more semantically
sensitive entity families.

The work below was therefore evaluated as one cumulative migration tranche.
Each step must remain mechanically reviewable and behaviorally exact, but an
intermediate step does not need to clear an independent whole-compiler
performance gate. The complete tranche must demonstrate a significant,
repeatable reduction before merge.

The remaining sections preserve the predeclared plan and gate for audit. They
are historical requirements, not an active implementation instruction after
the rejection recorded above.

## Objective

After Stage 04 has resolved and validated a module graph, use the graph's
existing dense module ordering as the default addressing mechanism for
graph-owned Stage 06 products. Keep string and descriptive-identity
dictionaries only at boundaries that genuinely receive source paths,
unresolved import requests, durable semantic identities, or graphless values.

The target flow is:

```text
source path or durable ModuleIdentity
    -> one validated boundary lookup
    -> graph-owned module ordinal
    -> list-indexed Stage 06 work
    -> descriptive identity projected only for diagnostics/artifacts/LSP
```

This is invocation-local data reuse, not caching or interning. It must not add
process-global state, serialize graph-local ordinals, or make an integer from
one graph meaningful in another graph.

## Existing Substrate

The compiler already has three relevant integer domains:

- `FrontendModuleId` and `FrontendModuleReferenceId` in the accepted Stage 04
  `FrontendGraph`;
- the private target-first `module_index` in `PreparedModuleScope`; and
- index-local module ordinals in `ImportableModuleIndex`.

The retained TypeHeader implementation is the precedent for dense category
storage. A TypeHeader table owns its graph provenance, accepts a
`PreparedModuleScope`, validates compatibility, and uses the resulting slot
immediately. It does not expose a freely pairable integer or change durable
`TypeId` identity.

This roadmap should reuse those domains and patterns. It should not add a
second public module-ID abstraction merely to make APIs look uniform.

## Shared Invariants

Every step must preserve:

1. canonical-path and module-origin identity semantics;
2. duplicate, missing-module, ambiguity, privacy, and visibility diagnostics,
   including source spans, help text, and order;
3. target-first graph order and source declaration order;
4. definition, callable, type-variable, trait, and implementation identity
   allocation order;
5. newest-first name history and overload ordering;
6. accepted and recoverable graph behavior;
7. direct-program, anonymous, compiler-surface, prelude, stdlib,
   source-package, native-package, and user-module distinctions;
8. byte-identical typecheck and compiler responses;
9. durable semantic identities at CTFE, artifact, diagnostic, and LSP
   boundaries; and
10. exact fail-closed behavior for missing, incompatible, sparse, or partially
    prepared module products.

An integer module slot is an address, not semantic identity. Numeric equality
must never replace `ModuleIdentity` equality outside one proven graph owner.

## What Remains Dictionary-Indexed

The following lookups are intentional and are not migration targets:

- unresolved source import path and alias selection;
- canonical-path admission into an accepted graph;
- duplicate module and conflicting-origin validation;
- external typecheck requests that name modules by path;
- graphless/direct/provisional declaration identity;
- durable exported-symbol, artifact, diagnostic, and LSP identity; and
- sparse source-name indexes inside one already selected module bucket.

The goal is not to eliminate dictionaries. It is to eliminate repeated outer
module dictionaries after the module has already been resolved.

## Sequencing

```text
1. Collapse ImportableModuleIndex to one path-to-ordinal boundary
                     |
                     v
2. Add dense prepared-scope addressing to BoundModuleGraph
                     |
                     v
3. Move global-header completion onto dense module buckets
                     |
                     v
4. Move accepted global and callable outer indexes onto dense buckets
                     |
                     v
5. Measure the cumulative compiler and either retain or restore the tranche
```

Steps 2-4 should share the existing prepared-scope ordinal flow. They must not
each reconstruct their own `ModuleIdentity -> Int` dictionary.

## Step 1: Collapse `ImportableModuleIndex`

### Current shape

`ImportableModuleIndexRep` currently stores both:

```blorp
modules: List[ImportableModule]
modules_by_path: Dict[String, ImportableModule]
module_ordinals_by_path: Dict[String, Int]
```

The record-valued dictionary duplicates the authoritative module list.
Several reads consult both dictionaries, and prelude selection stores a path
only to perform another dictionary lookup later.

### Change

- Delete `modules_by_path`.
- Resolve canonical paths once through `module_ordinals_by_path`, then read
  the selected module from `modules`.
- Store `prelude_ordinal: Option[Int]` instead of `prelude_path`.
- Make exact-path membership test `module_ordinals_by_path`, while request
  aliases continue through `candidate_paths_by_request`.
- Keep `dependency_ordinals_by_module` and its index-local ownership exactly
  as implemented by Issue 50.

### Expected value

This removes one persistent dictionary containing managed module values from
each dependency and all-module importable index. Successful module selection
still performs one path hash at the source/path boundary, but all value access
after that lookup becomes a bounds-checked list read.

### Complications and pitfalls

- The target and dependency/all indexes have separate ordinal universes. An
  ordinal from one index must never address the other.
- `List.get` returns `Option`; a missing or invalid ordinal must preserve the
  existing missing result rather than defaulting to another module.
- Prelude recognition currently checks exact `prelude` first and then scans
  supported identities. The same precedence and deterministic winner must be
  preserved before storing the ordinal.
- `importable_module_index_modules_for_paths` sorts by module ordinal. Removing
  the module dictionary must not replace that ordering with request order.
- Dictionary construction currently overwrites duplicate path values, while
  graph validation is responsible for rejecting illegal duplicates. Tests
  must prove that this responsibility does not silently move.
- Avoid generic `map` over stack-valued ordinal carriers if generated C shows
  boxing. Prefer the existing explicit loops for construction and access.

### Fast feedback

Run the module binding, module visibility, module prelude, import precedence,
frontend graph typecheck, and LSP imported-definition/reference suites. Add
structural tests for exact path, alias, missing path, prelude precedence,
dependency/all-index isolation, and invalid ordinal failure.

Inspect generated C to confirm that the final path lookup obtains an integer
and the selected module is loaded from the list without constructing a second
module dictionary.

## Step 2: Address `BoundModuleGraph` by Prepared Scope

### Current shape

`BoundModuleGraphRep` retains a target, a selected dependency list, and:

```blorp
modules_by_canonical_path: Dict[String, BoundModule]
```

Many internal declaration phases already operate on a `PreparedModuleScope`
or a product that owns one, but recover a `ModuleIdentity`, construct/display
its path, hash the path, and validate the selected `BoundModule` again.

Prior Issue 49 instrumentation observed approximately 45,000
`bound_module_graph_find` calls. Its bounded candidate retired 23,232 of those
calls and produced large focused allocation reductions, but did not clear its
standalone whole-compiler gate.

### Change

- Keep a canonical-path boundary for callers that genuinely possess only a
  path or durable identity.
- Change its dictionary value from `BoundModule` to the narrowest stable list
  index when doing so avoids retaining managed values twice.
- Add a private dense selector from the graph's prepared-scope slot to a bound
  module slot.
- Add a narrow scope-based lookup that validates graph compatibility and then
  performs one list read.
- Migrate only callers that already own a `PreparedModuleScope`, `BoundModule`,
  or graph-owned product carrying that scope. Do not reconstruct a scope from
  a nominal identity to call the new path.

### Partial-graph complication

A `BoundModuleGraph` may contain the target plus only selected dependency
modules, while `PreparedModuleScope.module_index` addresses the complete
indexed graph. Its dense selector therefore cannot assume that the bound list
and prepared table have identical lengths or positions.

Use an explicit exact-length slot map owned by `BoundModuleGraph`, for example
a list of optional/sentinel-free selections, or another representation that
can distinguish "valid prepared module but not bound in this graph" from an
out-of-range slot. Do not use a magic negative integer. Measure whether an
`Option[Int]` list introduces one managed allocation per slot; choose a
stack-valued tagged representation if necessary and inspect generated C.

### Additional pitfalls

- Separately allocated but structurally equivalent prepared graphs currently
  have defined compatibility behavior. Preserve it; do not compare bare slots.
- Accepted and recoverable graphs differ in which modules are available.
  Missing/rejected modules must not become default list entries.
- Target slot zero and dependency slot offsets are easy sources of off-by-one
  errors because `IndexedGraph.modules` currently excludes the target.
- Do not retain a `PreparedModuleScope` per declaration merely to gain a slot;
  that would add managed values and can erase the lookup saving.
- Identity and canonical-path lookups remain required for free-standing
  `GlobalId`, `CallableId`, `TraitId`, and diagnostics until their owning phase
  is migrated.

### Fast feedback

Pin target, first/middle/final dependency, missing selected dependency,
recoverable failure, incompatible graph, equivalent separately allocated
graph, same path/different origin, and sparse/reordered selection behavior.

Use exact function instrumentation to ratchet down identity/path-based
`bound_module_graph_find` calls. That call-count reduction is an intermediate
structural gate, not the final performance claim.

## Step 3: Densify Global-Header Completion

### Current shape

`global_header_completion.brp` constructs temporary nested dictionaries such
as:

```blorp
Dict[String, Dict[String, GlobalHeader]]
Dict[String, Dict[String, Dict[Int, GlobalInitializerDependency]]]
```

The outer key is a serialized `ModuleIdentity`. During dependency discovery,
the code repeatedly converts an owner ID back into a bound module and then
uses the descriptive identity to select another module bucket.

### Change

- Bind each participating module to the Step 2 prepared-scope slot once.
- Replace outer module dictionaries with graph-aligned lists of module-local
  name/dependency dictionaries.
- Pass the already resolved owner/imported module selection through the
  private reference-resolution path.
- Preserve `GlobalId`, source name, and definition/dependency identity exactly.
- Keep source-name dictionaries inside a module bucket; those keys are sparse
  and semantic.

### Expected value

Global initializer expressions can contain many identifier references. This
change removes module identity serialization and outer hash probes from that
per-reference work while keeping the existing name lookup.

### Complications and pitfalls

- An earlier isolated global-header prototype increased whole-compiler
  instructions by approximately 0.026%. The new version is justified only if
  it consumes the shared Step 2 slot flow and does not add its own conversion
  index or per-header carrier.
- Annotated and pending globals have different completion paths. Dense storage
  must preserve their current stable ordering and cycle diagnostics.
- Qualified aliases, selectively imported names, ordinary field syntax, and
  local globals have different resolution rules. The module slot must be
  chosen only after existing `ModuleView` resolution has selected the module.
- Global dependency graphs use definition/source facts in addition to module
  ownership. Do not flatten those dimensions into a single integer namespace.
- Sparse graphs may have many modules with no globals. Compare eager empty
  buckets against a compact slot-to-bucket index; do not allocate a heap
  dictionary for every empty module without measurement.
- Cycle and unresolved-reference diagnostics must retain exact order, spans,
  and wording.

### Fast feedback

Cover local, imported, qualified, selectively imported, same-name,
annotated/unannotated, chain, diamond, cycle, missing owner, and recoverable
module cases. Derive expected dependency edges independently from fixture
source rather than from the new indexes.

Measure module-bucket reads, storage-key constructions, list reads,
allocations/releases, and semantic checksums through the production completion
path. Do not retain a benchmark-only alternate implementation after selection.

## Step 4: Densify Accepted Global and Callable Tables

### Current shape

Accepted global and callable tables store declaration slots once, but their
outer indexes are still keyed by serialized module identity:

```blorp
indices_by_module_and_name: Dict[String, Dict[...]]
indices_by_module_and_definition_id: Dict[String, Dict[...]]
```

Path-indexed tables also exist for imported bindings. Those path indexes serve
a real import boundary and are not automatically redundant.

### Change

Implement globals first, then callables using the same reviewed pattern:

- bind the table to one prepared graph owner;
- build module-local name and definition-ID buckets in prepared-scope order;
- select the owner bucket once when constructing an authority;
- retain existing path-and-name indexes for imported source bindings unless
  an already resolved module slot is available at that exact boundary;
- keep declaration slots, stable IDs, visibility, localization, and source
  ordering unchanged; and
- remove the old module-identity outer indexes after every graph-owned reader
  migrates.

### Expected value

Authority construction and body inference repeatedly consult these indexes.
Selecting one dense owner bucket up front amortizes the compatibility check and
avoids repeated module-key construction during declaration use.

### Complications and pitfalls

- Issue 46's isolated callable prototype reduced its focused allocation window
  by only about 0.03% and increased whole-compiler instructions by 0.096%.
  Do not recreate that design if it mapped each declaration through a new
  conversion layer. The cumulative candidate must reuse the established slot
  flow and select buckets once per authority/session.
- Callable same-name history and overload order are observable. Module bucket
  construction must append in the existing source order, and public filtering
  must preserve its current reverse/newest-first traversal.
- Duplicate callable definition IDs are rejected. A dense outer dimension must
  not weaken or reorder that rejection.
- Globals have declared, owner-localized, completed, and initializer-specific
  availability. Dense addressing changes only bucket selection, not which
  binding form is returned.
- Path-based imported bindings may name the same module through aliases. Do
  not infer module identity from a display path or merge path and identity
  indexes without an exact resolver-owned association.
- Direct-program and compiler-surface authorities may not belong to an
  accepted graph. Preserve a separate exact descriptive path or keep those
  products out of the dense constructor; never reserve magic module slots.
- Empty category buckets can dominate small graphs. Build buckets with explicit
  loops and compare eager exact-length lists with a compact module-slot map.
- Do not carry `PreparedModuleScope` in every accepted declaration record.
  Resolve ownership once per module/category construction boundary.

### Fast feedback

For globals, test local/imported/private, declared/completed/initializer,
same-name/different-module, wrong-kind, missing, and direct/compiler-surface
cases.

For callables, test local/imported/private, overload order, same-name history,
duplicate definition IDs, UFCS candidate order, wrong-kind, missing, and
direct/compiler-surface cases. Existing semantic occurrence and LSP
definition/reference suites must remain byte-identical.

Track exact module-key constructions and outer dictionary reads separately
from inner semantic name/definition-ID reads. A successful migration should
drive graph-owned outer module-key work to zero without pretending that inner
name dictionaries were removed.

### Implementation boundary found during the first tranche

The first implementation audit excluded this step from the initial cumulative
candidate. `accepted_global_authority.brp` and
`accepted_callable_authority.brp` are deliberately below the prepared graph
and module-view layer: `module_view.brp` imports both authorities, while
`bound_module_graph.brp` owns `ModuleView`. Importing `PreparedModuleScope` or
`BoundModuleGraph` into either authority would therefore create a dependency
cycle rather than reuse the graph's ordinal domain.

The remaining local option is to add a module ordinal to every accepted
global/callable input record, or to map every declaration through a second
graph-specific carrier before constructing the table. That is the
per-declaration conversion layer prohibited above. It also recreates the
Issue 46 callable prototype shape, which reduced its focused allocation
window by only about 0.03% and increased whole-compiler instructions by
0.096%. The tables additionally need durable `ModuleIdentity` lookup for exact
global completion, exact callable lookup, and direct/compiler-surface tests,
so the old descriptive index could not simply disappear in that shape.

Revisit this step only after a higher-level graph-owned authority factory can
select and pass one module-local bucket without moving the low-level authority
modules or adding per-declaration conversion data. This exclusion leaves the
accepted global/callable representations and semantics unchanged in the first
tranche.

## Deferred Follow-Ups

Do not include these in the first cumulative tranche:

### Trait and implementation authority

`accepted_trait_implementation_authority.brp` contains several module-keyed
outer dictionaries and many storage-key constructions, so it may offer a large
follow-up. It also owns trait coherence, implementation lookup, overloads,
UFCS, qualified methods, and owner relationships. Migrating all those indexes
before the simpler global/callable pattern is proven would expand the semantic
blast radius substantially.

### Definition index

`DefinitionIndex` performs module-bucket lookups for every reserved and queried
definition and may ultimately be one of the highest-value targets. It also
supports accepted graphs, direct/provisional programs, compiler surfaces, and
durable definition keys. A follow-up must first separate graph-owned addressing
from graphless identity without changing allocation order. It should not be
folded into this roadmap's initial tranche opportunistically.

### Declaration catalog

Issue 51 remains deferred until a production-retention consumer accounts for a
measurable share. Dense storage should not be justified by a benchmark-only
catalog consumer.

## Measurement Contract

### Baseline

Before Step 1 production edits:

- capture the current compiler and source commit identities;
- run one warmup and at least three serial production self-checks;
- record byte-identical response hashes, elapsed time, retired instructions,
  cycles, peak RSS, allocator totals where available, and Stage 06 checkpoint
  timing;
- collect exact counts for module storage-key construction, bound-module
  identity/path lookup, and the affected authority/completion boundaries; and
- retain raw output under an ignored roadmap-specific log directory.

### Intermediate gates

Each step must pass focused semantic, ownership/leak, formatting, and manifest
checks. Each step must also show its intended structural work reduction:

- Step 1 removes the record-valued importable-module dictionary;
- Step 2 reduces identity/path bound-module lookups for migrated callers;
- Step 3 removes graph-owned outer module hashes from global completion; and
- Step 4 removes graph-owned outer module hashes from accepted global and
  callable authority construction/query.

An intermediate result below whole-compiler timing noise may continue to the
next step. A clear allocation/instruction regression, new per-item carrier, or
failure to remove the intended old work must be corrected before proceeding.

### Final merge gate

Build baseline and cumulative candidate from matched source trees with the
same bootstrap compiler. Run one warmup each, then at least three alternating
baseline/candidate production pairs. Require:

- byte-identical stdout/stderr protocol responses and semantic hashes;
- identical diagnostics, definition frontier, and test checksums;
- no leak, timeout, sanitizer, or memory-status failure;
- a repeatable reduction outside sample noise in retired instructions and
  Stage 06 allocator work;
- no material peak-RSS, elapsed, or one-module/small-program regression; and
- the exact gate applied to this experiment: at least 1% lower production
  retired instructions, with non-regressing Stage 06 allocations, elapsed,
  and RSS.

The threshold was recorded before candidate timing and was not weakened after
seeing the result. Focused microbenchmarks explain mechanism; they do not
substitute for the cumulative compiler gate.

## Matrix

Use deterministic fixtures varying independently:

```text
modules:                 1, 8, 32, 128
declarations per module: 0, 1, 16, 64
topology:                chain, star, layered/diamond, dense
globals/functions mix:   all-global, mixed, all-function
duplicate names:         none, cross-module, same-module valid overloads
selection:               target-only, sparse dependencies, complete graph
graph state:             accepted, recoverable module failure
```

Record graph dimensions, semantic checksum, errors/diagnostics, module-key
constructions, path-boundary dictionary reads, dense list reads, inner name
dictionary reads, allocations, releases, retained objects/bytes, elapsed,
retired instructions, cycles, and RSS. Keep semantic inventory, modeled work,
exact function counts, and cost measurements as separate evidence classes.

## Generated-C Audit

For every retained dense product, inspect generated C and confirm:

- module ordinals are unboxed integer values;
- list access does not allocate an ordinal wrapper;
- no generic `map` or callback path boxes per-module structs;
- construction does not repeatedly copy the complete outer list;
- empty buckets do not allocate one managed dictionary each unless measured
  and accepted; and
- the old record-valued or module-identity outer dictionary is absent from the
  migrated production path.

## Completion Criteria

The roadmap tranche is complete only when:

1. Steps 1-4 are implemented or a measured step is explicitly excluded with
   the remaining boundary documented;
2. every migrated product uses one graph-owned ordinal domain and validates
   provenance before list access;
3. all old graph-owned outer module dictionaries and conversion bridges for
   migrated paths are deleted;
4. focused, stage, leak, LSP semantic, and production replay behavior is exact;
5. generated C confirms the intended representation and access pattern;
6. the cumulative candidate clears the predeclared significant merge gate;
7. code-reviewer, test-runner, and code-optimizer approve the final diff; and
8. documentation records exact retained and deferred boundaries without
   claiming that graph-local IDs replace durable module identity everywhere.

If the cumulative candidate fails the final gate, retain the measurement and
restore changes that exist only for performance. A simplification such as
removing a provably redundant dictionary may be proposed separately, but it
must not be represented as a compiler speedup without evidence.
