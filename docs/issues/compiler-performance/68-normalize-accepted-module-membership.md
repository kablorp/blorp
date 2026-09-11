# Normalize Accepted Module Membership

**Status:** Complete

**Roadmap:** [Normalized Semantic Compilation Roadmap](NORMALIZED_SEMANTIC_COMPILATION_ROADMAP.md), Step 2a

**Depends on:** Step 1 accepted semantic catalog (`005c1f96`)

**One-sentence packet:** Make graph-owned `BoundModuleVisibility` the sole
accepted authority for visible/direct module membership, validate it with
compilation-issued `ModuleId` values, and remove retained imported-module path
containers from `ModuleView`.

## Why This Is The First Step 2 Packet

Step 2 ultimately normalizes all module-visible bindings, including aliases,
selective names, namespaces, precedence, and source-name handles. That is too
large for one implementation change. Qualified alias lookup still enters from
parsed `String` spellings and most of its consumers still expect canonical path
strings. Adding `SourceNameId` now would retain an interner beside those strings
without yet deleting the path-based consumers.

Module membership has a complete, smaller boundary today:

- `BoundModuleVisibility` already owns the ordered visible and direct module
  payloads attached to each accepted `BoundModule`;
- every `ImportableModule` in that product carries a `PreparedModuleScope`, and
  therefore a `ModuleId` and issuing `ModuleTable`;
- `ModuleView` separately retains the same membership as an ordered
  `List[String]` and a `Dict[String, Bool]`; and
- accepted record-header construction uses the string dictionary to filter the
  already-validated direct-module list, implicitly distinguishing source
  imports from ambient implementation modules.

Removing that duplication is useful on its own. It retires a redundant
string-keyed membership relation without claiming that the canonical strings
themselves can yet be released, shortens the import-registration update path,
and establishes the ID/provenance pattern that qualified bindings can reuse in
Step 2b.

## Current Authority And Representation

### Retained `ModuleView` copy

```blorp
private record ModuleViewRep {
	-- other name and accepted-table facts
	imported_modules: List[String],
	imported_modules_by_path: Dict[String, Bool]
}
```

`module_view_add_imported_module` hashes the canonical path, appends it to the
list, inserts it into the dictionary, and rebuilds the persistent record for
every first import. `typecheck_state_add_imported_module` and
`typecheck_state_has_imported_module` expose that copy to the binder.

### Graph-owned visibility product

```blorp
private record BoundModuleVisibilityRep {
	visible_import_modules: List[ImportableModule],
	direct_import_modules: List[ImportableModule]
}
```

The lists preserve graph order and provide the module surface and prepared
scope required by header construction. The current constructor validates
duplicates and direct-in-visible membership through transient
`Dict[String, Bool]` values keyed by canonical path. It does not verify that
the scopes came from the same `ModuleTable`. The direct list also appends an
ambient implementation module after source-selected imports. The retained
`ModuleView` dictionary was therefore doing two jobs: duplicate membership and
an implicit source-direct/ambient distinction.

### Constructors, writers, and readers

- `module_binding.brp`
  - `register_program_imports` resolves import requests and currently writes
    retained membership through `TypecheckState`.
  - `register_program_import_syntax` does the same for standalone/recovery
    tooling even though no accepted graph exists.
- `decl.brp`
  - `typecheck_bind_program_module_view` selects visible/direct modules,
    registers source bindings, constructs `BoundModuleVisibility`, and returns
    the completed binding product.
  - `typecheck_bind_standalone_program_module_view` returns an empty visibility
    product because it has no loaded graph.
- `bound_module_graph.brp`
  - `bound_module_visibility` is the accepted visibility constructor.
  - `bound_module_direct_import_modules` and
    `bound_module_visible_import_modules` are its ordered readers.
- `accepted_record_graph.brp`
  - `accepted_record_table_authority_for_module` is the first production
    consumer. It currently guards each direct module with a
    `module_view_has_imported_module` path lookup, making the source/ambient
    distinction depend on the duplicate string-keyed relation.
- Tests and benchmark fixtures inspect `module_view_imported_modules` or
  `typecheck_state_has_imported_module`; those observations are representation
  checks, not language behavior.

## Target Contract

`BoundModuleVisibility` remains compact: it retains the two ordered module
lists because downstream header construction needs their payloads. Direct
modules preserve source-selected imports as a prefix and append ambient
semantic evidence afterward; an explicit prefix length lets source-name
consumers exclude ambient modules without retaining a third list. The
constructor validates identity relations against the owner scope using sparse,
transient membership keyed by verified `ModuleId` table positions.

```blorp
union BoundModuleVisibilityBuild:
	BoundModuleVisibilityReady(BoundModuleVisibility)
	BoundModuleVisibilityDuplicateVisible(String)
	BoundModuleVisibilityDuplicateDirect(String)
	BoundModuleVisibilityDirectNotVisible(String)
	BoundModuleVisibilityInvalidSourceDirectCount(Int)
	BoundModuleVisibilityIncompatibleVisible(String)
	BoundModuleVisibilityIncompatibleDirect(String)

pure func bound_module_visibility(
	owner_scope: PreparedModuleScope,
	visible_import_modules: List[ImportableModule],
	direct_import_modules: List[ImportableModule],
	source_direct_import_count: Int,
) -> BoundModuleVisibilityBuild
```

The owning module scope establishes compilation provenance, including for an
empty product. For each visible/direct module, the constructor first proves
that its prepared scope carries the exact owner `ModuleTable` allocation. Only
then may it interpret
`module_id_table_index(prepared_module_scope_id(scope))`. Sparse dictionaries
avoid clearing module-count-sized vectors for every module in a graph:

```blorp
var visible: Dict[Int, Bool] = {}
visible = visible.set(module_id_table_index(module_id), True)
```

The dictionaries are not retained. The accepted product keeps only the ordered
module payloads and the source-direct prefix count. This makes the relationship
exact without replacing two retained string containers with a new permanent
membership index or introducing quadratic initialization for sparse graphs.

Duplicate source imports are a different concern from retained accepted
visibility. Registration still has to emit the existing user diagnostic in
source order. The registrar therefore uses a short-lived set for the duration
of one graph-aware source-binding operation. It records canonical resolved
identities after module resolution, so alternate request spellings cannot
bypass duplicate detection. Registration also publishes a transient ordered
list of only the canonical imports it accepted. Missing, ambiguous,
policy-rejected, and repeated requests never enter that list. Module selection
immediately projects those paths to graph-owned `ImportableModule` values,
builds the visible closure, and publishes only the normalized module payloads
plus source-prefix count. Standalone syntax binding has no accepted graph
membership to publish and does not retain or invent one. Neither transient
container becomes part of `ModuleView` or survives accepted graph publication.

## String-Lifetime Budget

Entry to module binding necessarily retains parsed import spellings and
canonical resolver paths. This packet permits those strings for lookup and
diagnostics while binding.

At exit:

- `BoundModuleVisibility` retains `ImportableModule` payloads whose prepared
  scopes point to the compilation's canonical module table;
- it does not retain a second list or dictionary of membership strings;
- `ModuleView` retains alias/import-name strings still required by unresolved
  name lookup and diagnostics; and
- duplicate tracking and the accepted-path handoff are released once graph
  visibility has been constructed.

The next packet may normalize alias targets to `ModuleId` and introduce a
compilation-local source-name table only when a production consumer can retain
the IDs and delete the corresponding path-string values.

## Implementation Strategy

1. Add a structural test proving `BoundModuleVisibility` rejects module scopes
   issued by another graph even when their raw integer IDs overlap. Extend the
   existing duplicate/direct-membership test to preserve exact error ordering.
2. Change `bound_module_visibility` to accept the owning
   `PreparedModuleScope`. Validate exact issuing-table provenance before
   inspecting any imported ID, and use transient sparse integer-keyed
   dictionaries for duplicate and subset checks. The global empty visibility
   value remains only for deliberately empty test/standalone products and
   contains no imported ID.
3. Pass the prepared scope, rather than a parallel path string, through the
   production binder. The binder derives its current canonical path from that
   scope and uses the same capability to construct visibility.
4. Move duplicate-import tracking into the graph-aware registration loop and
   have that single policy boundary publish accepted canonical paths in source
   order. Preserve the existing diagnostic text and first-error order,
   including two request spellings that resolve to one canonical module.
   Missing, ambiguous, policy-rejected, and duplicate requests must not become
   normalized source-direct membership. Keep standalone syntax registration
   free of accepted membership state.
5. Delete `ModuleViewRep.imported_modules`,
   `ModuleViewRep.imported_modules_by_path`, their accessors/mutator, and the
   `TypecheckState` wrappers. Replace tests that inspect those containers with
   assertions over aliases, selective bindings, diagnostics, or
   `BoundModuleVisibility` as appropriate.
6. Preserve the source-direct/ambient distinction explicitly as a validated
   prefix length on the ordered direct list. Remove the path-keyed membership
   guard in accepted record authority construction and consume only that
   source-direct prefix. Test that ambient implementations remain available
   while an ambient record is excluded from field-inference candidates.
7. Fingerprint the source-direct prefix explicitly in the bound-phase fixture,
   using the old membership guard on the parent and the normalized prefix on
   the candidate, so the checksum detects source/ambient misclassification.
8. Add allocation counters to the existing module-binding benchmark output so
   the retained-container deletion is observable. Do not create a new broad
   benchmark harness.

## Code Examples

### Provenance before raw IDs

```blorp
if module_tables_are_compatible(owner_table, imported_table):
	index = module_id_table_index(prepared_module_scope_id(imported_scope))
	if index >= 0 and index < module_table_count(owner_table):
		visible = visible.set(index, True)
else:
	BoundModuleVisibilityIncompatibleVisible(importable_module_path(module))
```

Two different module tables can both issue integer zero. Comparing those raw
integers before checking table provenance would silently conflate modules.

### Source-direct membership is explicit

The registrar is the single acceptance boundary. It returns the updated
namespace state plus a short-lived canonical handoff:

```blorp
record ProgramImportRegistration {
	state: TypecheckState,
	accepted_canonical_module_paths: List[String]
}
```

Only direct candidates named by source are offered to registration. After
registration applies ambiguity, policy, and duplicate rules, module selection
projects the accepted paths to `ImportableModule` values and computes their
dependency closure. This prevents a large transitive closure from being
re-indexed merely to bind a few direct source imports.

Before:

```blorp
for imported_module in bound_module_direct_import_modules(bound_module):
	if module_view_has_imported_module(module_view, importable_module_path(imported_module)):
		bindings = append_direct_import_bindings(bindings, type_headers, imported_module)
```

After, the direct list remains authoritative and its source-selected prefix is
explicit rather than inferred from a path-keyed side table:

```blorp
var index = 0
while index < bound_module_source_direct_import_count(bound_module):
	match bound_module_source_direct_import_module_at(bound_module, index):
		Some(module): bindings = append_direct_import_bindings(bindings, type_headers, module)
		None: void
	index += 1
```

The constructor owns the range invariant. Ambient semantic modules can still
provide implementations without becoming source-visible record candidates.

## Fast Feedback Loop

The narrow behavior loop is deliberately three owner suites and should
complete before running the full compiler gate:

```bash
bin/blorp test blorp/test/compiler/stage_04_modules/test_imports.brp
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_bound_module_graph.brp
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_typecheck_decl.brp
```

The first red tests are the foreign-scope visibility case and the rejected
standard-library/package import membership case. After the structural contract
is green, use the manifest-owned changed check:

```bash
scripts/compiler-check --changed
```

One benchmark screen is enough during iteration:

```bash
benchmarks/compiler_module_binding_profile 10 64 16
```

The benchmark must report allocations, releases, current objects, allocated
bytes, semantic counts, and a checksum. Capture one clean parent/candidate
pair. Use retired instructions from the generated benchmark worker when the
host supports a stable counter. Wall time is a guard, not an acceptance claim,
when contention prevents a clean comparison.

Final validation:

```bash
scripts/compiler-check --stage typecheck
benchmarks/compiler_typecheck_phase_profile bound 1 8 32 64 4 memory
benchmarks/compiler_typecheck_phase_profile bound 1 128 1 1 1 memory
```

Run broader gates only after these narrow commands are green.

## Result

The packet was accepted on 2026-09-10. The module-binding worker preserved its
semantic checksum and reduced allocations by 1.32%, allocated bytes by 0.68%,
and retired instructions by 0.79%. The bound-phase guard preserved both
semantic checksums while reducing retained objects by 9.52%, allocated bytes
by 11.41%, and retired instructions by 0.12%; allocation calls increased by a
guarded 0.36%. Benchmark worker sizes grew by 0.03% and 0.02%, while the
complete compiler binary grew by 0.09%.

One-shot elapsed time and operating-system memory readings were noisy. The
module-binding worker's small-process RSS and footprint increased by at most
64 KiB, while the larger bound-phase worker varied by at most 32 KiB. Those
values are retained as guards, not performance claims. At 128 modules with
fanout one, allocations fell 9.94%, retained objects fell 12.44%, allocated
bytes fell 10.17%, and retired instructions fell 1.99%. See
[`compiler_module_membership_step2a_2026-09-10.md`](../../../benchmarks/results/compiler_module_membership_step2a_2026-09-10.md)
for the commands, raw values, and decision.

## Performance Hypothesis And Guards

Primary expected wins for an import-heavy module are:

- two fewer retained `ModuleView` containers;
- no persistent dictionary insertion or record update per imported module;
- fewer module-path string hashes and ARC operations during binding;
- lower retained object count and allocated bytes; and
- fewer retired instructions in graph-aware import binding.

Peak RSS, compiler executable size, generated benchmark size, and whole
typecheck latency are guards. No metric may regress substantially to buy a
small allocation reduction. Investigate any deterministic regression above 1%
in retired instructions, allocated bytes, retained objects, or native artifact
size. Treat noisy wall-time/RSS changes within 1% as neutral unless repeated
evidence shows otherwise.

## Acceptance Criteria

- `BoundModuleVisibility` rejects visible/direct modules from a different
  issuing table before comparing their raw IDs.
- Duplicate visible modules, duplicate direct modules, and direct-not-visible
  modules retain their exact existing classification and deterministic path.
- Duplicate source imports retain their current user-facing diagnostic text
  and source order, including alternate spellings that resolve to one canonical
  module.
- Missing, ambiguous, policy-rejected, and repeated import requests are absent
  from normalized source-direct membership.
- `ModuleView` no longer stores or exposes an imported-module list or membership
  dictionary.
- Accepted record authority construction consumes the explicit source-direct
  prefix without a path-keyed recheck; ambient implementations do not make
  ambient records field-inference candidates.
- Standalone/recovery binding does not claim accepted graph membership and does
  not retain its transient duplicate set.
- Focused and stage-wide typecheck tests pass.
- Module-binding semantic counts and checksum match the parent baseline.
- Allocated bytes, retained objects, and retired instructions improve at the
  normal bound-phase shape; its allocation-call count remains within the 1%
  guard. The sparse scale shape improves every deterministic resource metric.
  Latency, RSS, and artifact sizes stay within guard thresholds.
- Results, raw commands, and the accept/reject decision are checked in under
  `benchmarks/results/` before the packet is marked complete.

## Rollback Rule

Reject the packet if exact behavior requires restoring a retained membership
map, if provenance cannot be represented without trusting raw integer IDs, or
if the candidate causes a repeatable greater-than-1% regression in a primary
resource metric without a compensating measured win. A rejected experiment
may keep only the structural provenance test and the recorded evidence.
