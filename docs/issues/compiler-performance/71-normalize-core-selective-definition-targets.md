# Normalize Core Selective-Definition Targets

**Status:** Complete

**Roadmap:** [Normalized Semantic Compilation Roadmap](NORMALIZED_SEMANTIC_COMPILATION_ROADMAP.md), Step 2d

**Depends on:** Step 2c exact graph selective-definition targets (`0f68273a`)

## Outcome

Ordinary graph selective imports now enter Core resolution with exact definition
identities:

```blorp
CoreExactSelectiveDefinitionImport(
	local_name: String,
	definition_ids: List[Int],
)
```

The previous adapter reconstructed `module_path` and `source_name` from the
authoritative module and definition tables, then asked Core to join those
strings back to declarations. The new adapter converts only the already
validated `DefinitionId` values at the current typed/Core identity boundary:

```blorp
GraphSelectiveDefinitionBinding(local_name, _, definition_ids):
	Some(CoreExactSelectiveDefinitionImport(
		local_name,
		definition_ids.map(definition_id_runtime_value),
	))
```

The target module path and source spelling no longer survive this boundary.
The local alias remains temporarily because Core's active-import index is still
keyed by the source-visible name. After resolution, calls and references carry
their selected definition identity and the compiler-derived Core symbol name;
the import environment is not retained by later transformation or emission
passes.

## Context And Scope

Step 2c made `GraphSelectiveDefinitionBinding(ModuleId, [DefinitionId])` the
accepted semantic fact, but Core immediately projected it back to
`(module_path, source_name)`. That preserved behavior while leaving three
costs:

1. the pipeline performed two table projections for a fact already resolved;
2. Core retained target path/name strings and inserted the path into its module
   membership set; and
3. Core could only rediscover the target through name-keyed callable/global
   maps.

This packet removes that compatibility projection for ordinary graph imports.
It deliberately does not combine the change with the complete Stage 06
visibility-table migration. That larger work still needs a compilation-local
`SourceNameId`, explicit precedence outcomes, and migration of typechecking and
LSP queries. Keeping the packet at one boundary gave a sub-four-second focused
test loop and exposed the allocation shape before the broad gate.

Three descriptive cases remain explicit:

```blorp
CoreQualifiedModuleImport(String, String)
CoreSelectiveDefinitionImport(String, String, String)
```

- graph trait-method imports retain a source name because `TraitMethodId` is
  issued after the Stage 06 import-binding boundary;
- standalone imports have no graph-owned identity tables; and
- qualified Core lookup remains module-path keyed.

Those are subsequent deletion targets, not hidden fallbacks for ordinary graph
definition imports.

## Core Resolution Contract

Core builds three exact indexes beside its existing descriptive indexes:

```blorp
record CoreCallResolveEnv {
	callable_targets_by_id: Dict[Int, CoreCallableTarget],
	global_targets_by_id: Dict[Int, CoreGlobalTarget],
	constructor_targets_by_id: Dict[Int, CoreConstructorTarget],
	colliding_definition_ids: Set[Int],
	-- Existing name/path indexes remain for unmigrated resolution modes.
}

union CoreCallableTargetResolution:
	CoreUserCallableTarget
	CoreBuiltinCallableTarget(String)
	CoreForeignCallableTarget(CoreForeignTarget)
```

One callable index covers user functions, concrete implementation methods,
builtins, and foreign functions. The explicit resolution union prevents a
definition ID from losing its call ABI or being guessed from a name. Global
targets retain exact type information for reference matching.

An exact overload set is resolved by parameter and result type:

```blorp
for id in definition_ids:
	if not Sets.contains(env.colliding_definition_ids, id):
		match env.callable_targets_by_id.get(id):
			Some(target):
				if selected_signature_matches(target, callee, args):
					-- Accept exactly one matching target.
```

Resolution fails closed when an ID collides, no target matches, or more than
one target matches. It never falls back from an exact binding to its local
alias, a module path, UFCS, an intrinsic, or a same-spelled declaration. A
selected `CoreVar.def_id` is accepted only when it belongs to the import's ID
set, and first-class function matching includes purity as well as parameter and
result types. This is covered for user, builtin, foreign, overloaded,
function-reference, constructor, and global-reference cases.
Constructors are indexed by ID separately from their source-name index, so an
aliased import such as `Some as Just` resolves to the canonical `Some` target
without reconstructing the source spelling.
The duplicate-global regression additionally proves that malformed Core with a
reused definition identity does not silently take the last dictionary entry.

## String Lifetime Improvement

For each ordinary graph selective binding, this packet retires:

- the canonical target module-path string from `CoreResolveImportBinding`;
- the target declaration's source-name string from that binding;
- the target path's membership/set entry when no other Core operation needs
  it; and
- the pipeline calls that projected both strings from identity tables.

The packet intentionally retains:

- the local alias until source-visible Core names are resolved;
- compiler-derived Core/C symbol names used to rewrite calls and references;
- diagnostic/source tables owned by earlier stages; and
- descriptive bindings for trait, standalone, and qualified cases.

This matches the repository direction that source strings should become less
useful as compilation advances. It does not claim Core or emission are already
string-free.

## Implementation Strategy

The bounded sequence was:

1. Add failing resolver tests for exact user calls, builtins, foreign calls,
   globals, first-class function references, missing IDs, and overloads.
2. Introduce the exact Core import variant without changing the descriptive
   variants needed by qualified, trait, and standalone compilation.
3. Change the graph pipeline adapter to pass definition identities directly
   and delete its target path/name projections.
4. Generalize the existing user-function ID index into one callable-ID index
   whose target variant preserves user/builtin/foreign behavior.
5. Add global- and constructor-ID indexes for exact imported values and
   aliased constructors.
6. Track duplicate callable/global/constructor identities in one definition-domain
   collision set and fail closed.
7. Extend the retained Core-resolution benchmark so half its selective
   bindings are exact and its observation checksum covers the new indexes.
8. Preserve `TypedGlobalVarInfo.definition_id` while lowering graph-backed
   globals; mint a Core-only ID only for unindexed/standalone globals. This
   closes the identity domain for exact global imports.
9. Compile the production selective-import fixture and inspect the generated-C
   diff against Step 2c.

The first correct implementation constructed each new callable target twice.
The narrow benchmark reported 7,880 allocations, +15.8% over Step 2c. Reusing
one constructed target reduced the final count to 6,849 (+0.69%) before broad
validation. This is the intended fast-feedback behavior: reject an expensive
representation while the change is still local.

## Fast Feedback Loop

The implementation loop is:

```bash
make -j2
bin/blorp test blorp/test/compiler/stage_09_core/test_core_resolve.brp
bin/blorp test \
	blorp/test/compiler/stage_09_core/test_core_call_resolve_profile_benchmark.brp
bin/blorp compile --no-format -o /tmp/blorp-step2d-smoke.c \
	blorp/benchmark/compiler/selective_import_graph_fixture/main.brp
```

The isolated resource screen uses one retained baseline/candidate pair:

```bash
/usr/bin/time -lp bin/blorp run --release --no-format \
	blorp/benchmark/compiler/compiler_core_call_resolve_profile.brp \
	-- 1 512 32 4 64 4
```

The benchmark reports deterministic index counts, module-path work, managed
allocations/releases, retained objects, and a checksum. A single production
compile supplies retired instructions, cycles, RSS, peak footprint, compiler
size, and generated-C diff and size as guard metrics. Wall time is recorded but is
not an acceptance signal. Once the narrow checks are stable, run one owner
gate:

```bash
scripts/compiler-check --changed
```

## Acceptance Criteria

- [x] Ordinary graph selective imports enter Core with their validated
  definition IDs and no target module/source strings.
- [x] User, implementation, builtin, foreign, and global targets can be found
  by exact definition identity.
- [x] Overload selection uses typed signature data and preserves exact target
  identity.
- [x] Missing, ambiguous, or colliding identities fail closed without
  name-based guessing.
- [x] Existing descriptive behavior remains explicit for graph trait methods,
  standalone imports, and qualified imports.
- [x] The retained benchmark directly exercises exact bindings and asserts the
  new ID indexes and reduced path membership.
- [x] Focused resolver and benchmark tests pass, and a production graph fixture
  compiles.
- [x] Generated C has identical size and differs only in three uses of one
  private C symbol, as expected when graph globals stop consuming fresh Core
  IDs; the generated artifact compiles in the integration gate.
- [x] Deterministic allocations remain within 1%; retained object count is
  unchanged.
- [x] Production retired instructions, RSS, and peak memory improve; compiler
  size remains within 0.10%. The isolated command's deterministic work remains
  bounded and its secondary native counters are reported without hiding a
  +1.78% whole-process instruction sample.
- [x] The changed-owner compiler gate passes: 3 production sources, 11 focused
  suites, and 4 special checks completed with zero failures.

## Measurements

The immutable baseline is Step 2c commit `0f68273a`. Exactly one final
baseline/candidate pair is retained; no wall-time claim is made.

| Isolated Core environment metric | Step 2c | Step 2d | Change |
| --- | ---: | ---: | ---: |
| module-path entries | 162 | 98 | -39.51% |
| module-path membership checks | 674 | 610 | -9.50% |
| managed allocations | 6,802 | 6,850 | +0.71% |
| managed releases | 6,801 | 6,849 | +0.71% |
| retained objects | 1 | 1 | 0 |
| retained bytes | 176 | 192 | +16 bytes |
| instructions retired, process guard | 31,907,223,325 | 32,474,390,512 | +1.78% |
| cycles, process guard | 8,202,369,973 | 8,249,921,428 | +0.58% |
| maximum RSS, process guard | 248,283,136 | 250,626,048 | +0.94% |
| peak footprint, process guard | 219,496,976 | 221,135,352 | +0.75% |

| Production selective compile metric | Step 2c | Step 2d | Change |
| --- | ---: | ---: | ---: |
| instructions retired | 4,596,060,359 | 4,594,001,851 | -0.04% |
| cycles | 1,109,319,786 | 1,109,661,406 | +0.03% |
| maximum RSS | 50,003,968 | 49,954,816 | -0.10% |
| peak footprint | 36,733,312 | 36,651,344 | -0.22% |
| compiler executable bytes | 19,300,176 | 19,318,976 | +0.10% |
| generated C bytes | 1,533,809 | 1,533,809 | exact |

The benchmark's changed semantic checksum is expected because its observation
schema and half of its synthetic imports changed. `workload_valid=True` and the
focused fixture assertions validate the new expected counts. The generated C
kept the same 1,533,809-byte size. Its SHA-256 changed from
`9ac6e7cc009f155c5ab8f2f717dee55a2825d78eb855e23a64e8db665f187ea9`
to `ad2e5f7c5d39cd891c9ac63c0ead60b89ac15424c9715d2d118d324b104c35fb`.
The complete 29-line unified diff changes only the declaration, call, and
definition of one private C symbol (`brp_nX` to `brp_nt`). Graph globals now use
their existing semantic IDs instead of incrementing the Core-only ID stream, so
that internal projection change is expected and explicitly covered by this
packet.
The isolated command includes compiling the benchmark before its deterministic
managed-memory window. Its +1.78% instruction sample is therefore retained as
an investigated secondary guard: the directly attributed allocation/path
counters are unchanged by the review fixes, while the production compiler
screen improves instructions by 0.04%; generated size is neutral and the only
diff is the inspected private symbol rename.
Raw commands, hashes, and counters are retained in
[`compiler_core_selective_targets_step2d_2026-09-11.md`](../../../benchmarks/results/compiler_core_selective_targets_step2d_2026-09-11.md).

## Next Packet

Step 2e begins with
[`72-normalize-qualified-alias-source-name-identities.md`](72-normalize-qualified-alias-source-name-identities.md).
That packet issues a compilation-local `SourceNameId`, migrates graph qualified
alias lookup, and deletes its string-keyed target map. Subsequent packets should
preserve candidate provenance and precedence explicitly, migrate one production
query family at a time, and delete a string-keyed map whenever an index replaces it.
Trait-method identity, CTFE's string-keyed imported-global environment, and
qualified Core lookup should move only when their owning identity/visibility
relation is available and independently measurable.
