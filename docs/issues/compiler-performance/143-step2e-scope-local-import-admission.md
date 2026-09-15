# Step 2e: Scope-Local Graph Import Admission

**Status:** Complete. The production binder publishes one immutable graph view;
its bound owner now contains exact accepted/rejected candidate history and the
accepted import payload column. The former successful-only graph inventory is
deleted. Final evidence is in the
[Step 2e completion screen](../../../benchmarks/results/compiler_step2e_visibility_completion_2026-09-14.md).

## Why this cut exists

The bound `ModuleView` already has one graph-name occupancy table, but graph
alias and selective registrations each published a new immutable view. A wide
import block therefore repeatedly copied growing occupancy and binding
collections. Import processing could not simply be reordered: module selection,
missing/private symbol errors, alias/selective conflicts, constructor checks,
and type-home recording have source-ordered observable effects.

The binder now decides each module declaration once as it walks source order.
Only selected modules reach symbol and alias admission. For a graph-owned
view, `TypecheckState` begins one opaque `GraphImportAdmission`; alias,
selective-definition, trait-method, and constructor registrations update its
scope-local occupancy and ordered binding collections. Conflicts leave those
collections unchanged and flow through the existing diagnostic wording. The
binder publishes one `ModuleView` after the import loop. Standalone source
registration remains separate; the low-level scalar graph constructor path
uses the same checked annotation boundary. An empty sequence of actual import
declarations skips builder construction and publication; a second begin on an active
admission reports an internal error without discarding pending rows.

The builder checks the exact active module and definition-table provenance at
each registration; it cannot infer ownership from an equal-looking table,
string path, or numeric index. The initial view is retained only to transfer
its graph scope, local occupancy, and accepted authorities at publication.

## Fast feedback

The direct fixture now has a tenth argument, `batch_graph_imports` (0 or 1).
It keeps module identities, spellings, local prescan, duplicate attempts, and
queries identical while changing only graph import admission:

```bash
bin/blorp test blorp/test/compiler/pipeline/test_module_binding_benchmark.brp
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_module_view.brp
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_typecheck_decl.brp
env BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 \
  benchmarks/compiler_visibility_width_profile 100 16 32 32 16 16 128 0 1 0
env BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 \
  benchmarks/compiler_visibility_width_profile 100 16 32 32 16 16 128 0 1 1
```

Replace `32 32 16 16 128` with `128 128 64 64 512` for 320 bound rows.
Use `/usr/bin/time -l` around the same command on macOS for whole-process
retired instructions and peak-memory screens. One sample per width is enough
to reject an obvious regression; short wall-time differences are directional.

Both modes reported the same final rows, binding count, duplicate outcomes,
query hits/checksum, and one retained object/96 net bytes. At 100 iterations:

| Bound rows | Tracked allocations, scalar → builder | Retired instructions, scalar → builder |
| --- | ---: | ---: |
| 80 | 58,001 → 45,501 (−21.6%) | 228.9M → 211.2M (−7.7%) |
| 320 | 230,801 → 179,901 (−22.1%) | 1,000.0M → 923.1M (−7.7%) |

Sampled peak footprint improved 1,818,912 → 1,720,608 bytes at 80 rows.
At 320 rows two short pairs varied: one was 1,884,448 → 1,933,600 bytes,
and the other was 1,917,216 → 1,884,448 bytes. Do not claim a peak-memory
win from those samples. The compared modes are in one worker binary, so this
fixture cannot establish a code-size change. The production module-binding
fixture preserved checksum 126,080, 128 bindings, zero errors, and 1,416
retained objects at 64 modules/16 exports; tracked allocations were 45,580
before this local cut and 44,410 afterward. That is a single pair, not a
compiler-wide latency claim.

## Correctness and completed boundary

The view test checks one publication, initial-view immutability, same-target
alias/selective overlap, duplicate outcomes, and rejection of foreign-table,
wrong-path, uncataloged-name, and different-target candidates. The benchmark
suite compares scalar and builder final observations. Declaration tests check
private/missing/duplicate errors, constructor registration, source-order
diagnostics, and accepted import behavior.

Cut B now retains every admitted local/import request and every idempotent,
conflicting, invalid-source, or invalid-target admission with an issued row ID
and explicit outcome. Occupancy rows point to their winning candidate IDs.
Graph `import_bindings` is no longer a second field: accepted bindings are the
candidate owner's ordered semantic payload column, and named compatibility
readers project that column at their existing boundary.

The binder-transient `GraphImportAdmission` remains an optional construction
field in broad `TypecheckState`. Removing it requires changing the state
product used throughout header installation, inference, and body checking; it
does not displace another visibility authority and did not contribute retained
state after publication. That type-state refactor is therefore explicitly out
of Step 2e completion and should proceed only as a separate measured product
change. Reentry and finish tests continue to prove that no pending admission
escapes the import boundary.

## Streaming module decisions before candidate history

The binder no longer creates an `OrderedImportDeclDecision` list and then
replays it. It makes and applies each `ImportDeclDecision` in one source-order
walk, marking accepted canonical paths before the next decision. The graph
admission begins lazily at the first real import, so empty import blocks do not
publish an unchanged view. This deletes a transient copy of every parsed
declaration/decision pair and creates the point where a future candidate owner
can append the exact outcome. It does not yet retain rejected candidates.

The focused declaration suite now covers missing, accepted, and duplicate
decisions across separate import blocks with an interleaved local declaration
and an empty block. The retained `compiler_module_binding_profile 10 64 16`
returns the same 64 aliases, 64 imported names, 128 bindings, zero errors, and
checksum 126080. Against the committed two-walk baseline, allocation calls move
44,410 → 43,720 (−1.55%) and releases 42,994 → 42,304; both retain the same
1,416 objects and 97,064 net bytes, and one cached run retires
311,238,151 → 309,935,187 instructions (−0.42%). Worker size falls
1,897,536 → 1,897,056 bytes. One process-level peak RSS/footprint sample moves
4,177,920/2,523,424 → 4,128,768/2,474,272 bytes; short peak and elapsed
samples are directional, not latency claims. The next change remains the
candidate/outcome owner, not another transient sidecar.

## Graph constructor inventory deletion

The next bounded deletion removed the builder's separate
`imported_constructors` list. Production graph constructor admission now
creates a constructor-specific occupancy row in one write;
alias-plus-constructor overlap has its own variant. The row stores one
`BoundConstructorPayload` pointer containing the already-admitted
`ImportedNameBinding` plus parent names. Thus ordinary name lookup reuses its
existing record without allocating, and the maximum bound-occupancy union
payload does not grow for ordinary names. The standalone source-mode list
remains separate. `module_view_imported_constructors` projects graph
constructors in successful import-binding order for the existing
accepted-union reader. It does not retain that projection in the view.

The production one-write API returns `GraphSelectiveAdmission` and shares the
same issuer, target, spelling, and conflict validation as ordinary selective
admission. `TypecheckState` first validates the exact parent/constructor export
pair against the active definition index; the low-level API trusts that
parent/ID proof from its caller. The older annotation API returns
`Option[GraphImportAdmission]`, and the scalar compatibility path returns
`Option[ModuleView]`: both reject a name without the latest admitted graph
selective definition, a trait-method-only binding, a different source
spelling/path, or a second annotation. On conflict, production keeps the
previous admission builder and adds the existing diagnostic; an unexpected
compatibility annotation failure rolls back to the original state with an
internal diagnostic. The direct fixture uses an actual
indexed union constructor ID and checks both alias/constructor admission
orders, invalid targets, duplicate conflicts, projection, and qualified-only
hiding. The source-level declaration suite checks that an explicit constructor
import reaches accepted union resolution and projects exactly one constructor
binding with the expected fields.

The final-payload 80-/320-row direct fixture retains the same 45,501/179,901
tracked allocations, 1 retained object/96 net bytes, bound-row counts,
successful-binding counts, duplicate outcomes, and query checksums as the
`1021f4db` snapshot. A cached wrapper run retired 208.54M/914.09M
instructions versus 208.36M/918.60M for that snapshot; these short samples
are not latency claims. The direct worker grew from 1,936,336 to 1,953,888
bytes (+0.91%). Direct process peak RSS and footprint moved upward by roughly
5–9% in one explicit baseline/candidate worker pair despite identical managed
allocation counters. This exceeds the roadmap investigation threshold for that
small process and leaves Cut A's direct-width memory gate open. `size` attributes
16,384 additional bytes to the worker's `__TEXT` segment and no change to
`__DATA`; that does not by itself explain the full process-peak difference.

The 32-module accepted-stage fixture, which produces 136 accepted constructor
rows, passed with identical semantic/constructor checksums, 265,735 tracked
allocations, 81,995 retained objects, 6,016,080 allocated bytes, and identical
collection-copy counters. To compare native artifacts without an unrelated
absolute-path symbol-size difference, the `1021f4db` source was compiled in a
sibling `blorp` worktree of the same path shape with the same bootstrap compiler.
That baseline/candidate pair retired 8,285,919,678/8,287,142,216 instructions
(+0.015%), peaked at 37,715,968/37,683,200 RSS bytes (-0.087%) and
30,933,304/30,998,840 footprint bytes (+0.212%), and produced
9,980,384/9,997,696-byte workers (+0.173%). These are one-shot guard samples,
not proof of a constructor-heavy memory win: this fixture contains accepted
constructor rows but primarily qualified imports. At this historical
checkpoint a selective-constructor fan-out screen and the combined Step 2e
resource checkpoint remained open.

## One-write constructor admission screen

The retained `compiler_constructor_admission_profile` uses one indexed union
constructor and imports it under 64 distinct local names for 100 iterations.
Setup is outside the measured window; each iteration includes admission and
the existing ordered constructor projection. The first baseline used selective
admission followed by annotation, while the candidate uses the production
one-write API. Both returned `status=OK` and the same 64 accepted bindings and
projected constructors per iteration.

| Signal | Two writes | One write |
| --- | ---: | ---: |
| Tracked allocations / releases | 84,000 / 84,000 | 71,200 / 71,200 |
| Retained objects / net bytes | 0 / 0 | 0 / 0 |
| Cached-run retired instructions | 268,192,923 | 218,906,930 |
| Peak RSS bytes | 3,162,112 | 3,145,728 |
| Peak footprint bytes | 1,753,376 | 1,753,376 |
| Worker bytes | 1,857,976 | 1,859,048 |

Thus this constructor-heavy boundary saves 15.2% allocation calls and 18.4%
retired instructions in one matched direct comparison; the worker grows 0.06%.
The short peak-memory samples do not establish a peak win, and no wall-time
claim is made. The earlier experiment wrapped every selective
request in a heap-backed candidate union and increased the constructor-sparse
80-row probe from 45,501 to 55,901 allocations (+22.9%); it was discarded.
The retained private helper instead takes optional constructor parents only
from its checked constructor wrapper and rejects a trait-method/parent pair.
The final constructor-sparse 80-/320-row probes return to 45,501/179,901
allocations and unchanged checksums; their cached-run instructions move
208.54M/914.09M to 209.25M/914.75M (below 0.4%). Short process-peak
samples still vary and do not close Cut A's direct-width memory question.
The final 32-module accepted-stage guard keeps the same checksums, 136
constructor rows, 265,735 allocations, and collection-copy counters as the
pre-one-write payload run. One whole-process sample moves 8,287,142,216 to
8,290,828,874 retired instructions (+0.045%), 37,683,200 to 37,797,888 peak
RSS bytes (+0.30%), and 30,998,840 to 31,113,552 footprint bytes (+0.37%);
the worker grows 32 bytes. This primarily qualified-import fixture is a
regression guard, not evidence for constructor-heavy latency or peak memory.

## Importable-graph normalization cleanup

The next bounded cleanup removes three avoidable reconstructions around the
binder without pretending to complete Cut B:

- `ImportableModuleIndex` has one canonical path-to-ordinal index. Exact lookup
  projects through the dense module list; alias construction and dependency
  construction no longer run redundant linear duplicate scans.
- `IndexedGraph` owns selective export demand by `ModuleId` after import-path
  finalization. Its explicit no-name, one-name, and many-name states keep hash
  sets out of the common cases. Importable construction no longer creates one
  graph-wide source-name union and applies it to every module.
- Imported type-home replay reads the exact accepted selective binding and
  `DefinitionId` rows. It no longer rebuilds a string path-to-surface map and
  rescans module exports.

The rejected dense-list and sparse-dictionary prototypes materially increased
focused allocation calls; they were discarded before broad validation. The
retained design moves a measured 2.18% allocation cost into one-time indexed
graph construction, where a linear count/offset/scatter builder prevents wide
selective buckets from quadratic COW growth. The repeated importable stage
reduces allocations slightly and retired instructions by 1.73%. The accepted
stage also removes 6,453 allocation calls across three iterations. Checksums
and work counts are exact; the only measured peak-footprint increase is 0.014%
in the accepted stage. See the
[matched resource screen](../../../benchmarks/results/compiler_importable_graph_normalization_step2e_2026-09-14.md).

This cleanup strengthened the normalized ownership boundary before the final
candidate/outcome owner landed. The completed relation, exact accepted joins,
and combined resource decision are recorded in the Step 2e completion screen.
