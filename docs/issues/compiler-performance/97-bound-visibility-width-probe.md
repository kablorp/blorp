# Bound Visibility Width Probe

**Status:** Candidate-only width probe, graph-local batch publication, and API-adapted historical comparison complete. A one-table occupancy simplification and graph-alias inventory deletion improve the current candidate, but Cut A's mixed-width resource regression remains open for Cut B import ownership.

**Roadmap:** [Step 2e visibility convergence](94-step2e-visibility-convergence.md)

**Evidence provenance:** The quantitative baseline/candidate pairs below were
captured before the 2026-09-13 merge of `main` into the Step 2e branch.
Each pair used its stated matched compiler/build, but its executable size,
instruction, and memory values are not measurements of the post-merge tree.
Re-run the narrow width and accepted-stage pairs before closing Cut A's
resource gate; post-merge test results can establish correctness separately.

## Purpose and boundary

The earlier accepted-stage screen had little isolated visibility work. The
new `compiler_visibility_width_profile` exercises the graph `ModuleView`
occupancy rows and ordered import bindings directly. Setup creates validated
graph module/definition identities, precomputes spelling strings and selective
`DefinitionId` payload lists, and constructs a graph view. The timed window
then registers locals before aliases and selective imports; retries duplicate
spellings; and queries all three kinds. It excludes parsing, graph creation,
source spelling construction, and definition lookup.

The setup deliberately constructs a source-name catalog for this low-level
fixture under the validated graph's exact module table. It is not a full
production importer or accepted-graph benchmark. A separate genuine
graph-binder test checks that private and missing imports are absent, a valid
selective import survives, and the three exact diagnostics retain source
order. Existing module-view tests cover overlap, conflict, clearing, and
foreign/equal-layout provenance.

```bash
bin/blorp test blorp/test/compiler/pipeline/test_module_binding_benchmark.brp
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_typecheck_decl.brp
benchmarks/compiler_visibility_width_profile 1000 16 32 32 16 16 128
benchmarks/compiler_visibility_width_profile 1000 16 128 128 64 64 512
benchmarks/compiler_visibility_width_profile 1000 16 128 128 64 0 0 1
benchmarks/compiler_visibility_width_profile 1000 16 128 128 64 64 512 0 1
BLORP_VISIBILITY_WIDTH_PROFILE_FUNCTIONS=1 \
  benchmarks/compiler_visibility_width_profile 1 16 32 32 16 16 128
```

The first seven controls are iterations, dependency modules, aliases,
selectives, locals, duplicate attempts, and queries. An eighth flag enables
alias/selective spelling overlap for cost attribution. A ninth flag selects
initial graph-local batch publication; both modes admit locals first, and the
batch candidate tuples are prepared outside the measured window. `final_*`
counters describe the last
iteration, whereas `requested_name_operations` and
`total_bound_query_checksum` span all iterations. The checksum checks alias
module IDs, selective imported paths, and local kinds; it is **not** an exact
selective-`DefinitionId` or accepted-identity checksum. Exact definition IDs
and binding order remain covered by the module-view suite. Native string-hash
and dictionary-probe counts are not exposed by current instrumentation;
the function profile provides exact call counts at the Blorp function boundary.

## Candidate-only width screen

These historical, pre-batch-order results are two workload widths on the
**same implementation**, not a before/after compiler comparison. They use 16 dependency modules and 1000
iterations; all width/operation dimensions other than module count grow 4×.
Both runs returned `status=OK`, with expected final rows/bindings and no
retained object growth. One pair is enough to flag a scaling question without
over-interpreting wall time.

| Signal | 80 rows | 320 rows |
| --- | ---: | ---: |
| Requested name operations | 224,000 | 896,000 |
| Final import bindings | 64 | 256 |
| Total allocations | 913,001 | 3,649,001 |
| Releases | 913,000 | 3,649,000 |
| Retained objects | 1 | 1 |
| Net live bytes after window | 96 | 96 |
| Measured window | 104,180 µs | 699,359 µs |

At 100 iterations, the same pair retired 279,963,843 versus 1,319,930,954
instructions and peaked at 1,786,144 versus 1,949,984 bytes of footprint.
Those whole-process instruction counts include the runner and setup; they
are not per-operation visibility instructions. The wider window takes about
6.7× the measured time for 4× the requested work, while allocations remain
approximately proportional. This is a **candidate scaling concern**, not a
regression against the prior compiler. The overlap experiment below
attributes the mechanism.

For the historical 80-row, one-iteration instrumented run,
`module_view_graph_source_name_index` and `source_name_table_find_id` each ran
224 times, matching requested name operations; `bound_visibility_occupancy`
ran 320 times. Instrumented elapsed time uses unoptimized generated C and is
not comparable to the plain window. The plain generated C artifact for this
fixture had SHA-256
`95d9437bc098311d1a7633b63993708465169a3ce026faa76458d929dfdecc4e`.
Both historical widths ran the same binary and generated C. That digest is
not an identifier for the current locals-first/batch-enabled fixture.

## Scaling diagnosis and rejected local fix

Independent dimension runs show lookup count is not the main problem. At a
fixed 80-row view, increasing queries from 128 to 512 moved the 1000-iteration
window from about 98 ms to 118 ms and left allocation count unchanged. By
contrast, widening alias-only admissions from 32 to 128 moved it from about
33 ms to 195 ms; selective-only admissions moved from about 36 ms to 201 ms.
These are different candidate workloads, not before/after compiler data.

The generated C for `module_view_with_graph_occupancy` retains the old
`BoundVisibility`, then retains its `rows` before `List.append`. The COW
capacity check therefore sees a shared list and copies it. The integer
`row_index_by_source_name.set` path calls `blorp_dict_cow` while the old
visibility still holds the dictionary, likewise cloning growing storage.
The ordered `module_aliases`, `imported_names`, and `import_bindings` lists
also grow through immutable view updates. This is an ownership/construction
boundary, not a string-hash lookup bottleneck.

The earlier optional overlap runs distinguish row/index growth from ordered
inventory growth. With 320 admission requests and 256 bindings in both runs,
distinct spellings yielded 320 rows, 3,585,001 allocations, and 701,018 µs;
matched alias/selective spellings yielded 192 rows, 3,457,001 allocations,
and 535,777 µs. A mostly-local 320-row case with only two bindings still
took 444,227 µs. Both row/index copying and compatibility inventory growth
matter.

## Initial graph-local publication slice

Graph prescan now gathers local declaration candidates, builds its keyed
occupancy table in a uniquely owned local variable, and publishes one
immutable `ModuleView` before import registration. A non-fresh/foreign view or
uncataloged local name falls back to the previous per-name path, preserving
its exact error. Standalone prescan still uses its direct registration path;
empty graph-local batches return the original view without republishing.

The retained width fixture compares the sequential control and local-batch
mode on the **same current binary**, in the same locals-first admission order.
Setup prepares the batch candidate tuples, so the timed delta isolates
admission/publication rather than list construction. The generated C for the
current fixture has SHA-256
`b62053b29514c529ddb9ee87652d6c0f12a9e7e82780c6e50458bfa36bc250aa`.
All rows, bindings,
duplicate decisions, query hits, and checksums matched. At 1000 iterations:

| Workload | Sequential allocations / window | Batched allocations / window |
| --- | ---: | ---: |
| 16 locals, 2 imports | 153,001 / 12,517 µs | 63,001 / 4,426 µs |
| 318 locals, 2 imports | 2,569,001 / 446,549 µs | 672,001 / 48,821 µs |
| 80 rows, 64 imports | 913,001 / 105,630 µs | 823,001 / 99,838 µs |
| 320 rows, 256 imports | 3,649,001 / 733,791 µs | 3,273,001 / 679,437 µs |

At 100 iterations, the 320-row mixed control/batch pair retired
1,267,763,789 / 1,183,449,144 instructions; both reported a 1,949,984-byte
peak footprint. The 318-local pair retired 859,632,646 / 126,018,796
instructions, while peak footprint was 1,868,064 / 1,933,600 bytes (a small
increase in this one process-level sample). These counters include setup and
the runner, not only view admission. The direct benchmark excludes candidate
collection time, so it does **not** establish an end-to-end compiler resource
win; the production graph binder does collect that list. Import rows and
ordered inventories still COW-update per candidate. Cut B must bring those
admissions under a single owner and delete the superseded inventories.

A sparse 32-slot paged row-table experiment improved the 320-row full-width
window from about 703 ms to 559 ms, but raised allocations from 3,649,001 to
5,257,001 (+44%) and made the 80-row window slower (about 107 ms to 131 ms).
It was reverted; no paged representation remains in production. Improving
wide latency while materially worsening allocations and the smaller case
fails this roadmap's resource guard.

The coherent fix belongs at graph binding's construction boundary: hold
uniquely owned keyed-occupancy and ordered-candidate builders while imports are
admitted, then publish one immutable bound visibility product. Cut B's
candidate provenance log should replace, not sit beside, the current ordered
compatibility inventories. Do not insert a mutable shared view or retain a
second row authority merely to make this benchmark faster. Before
implementation, verify that every early conflict and header lookup has a
phase-correct builder or published-view consumer. The same width fixture,
accepted-stage checksum, generated C, and broad resource gates then provide
the fast feedback and no-regression checks.

## Historical direct comparison and keyed-occupancy simplification

The pre-Cut-A source at `cb716ccf` was checked out in a temporary worktree.
Its narrow/wide direct fixture was API-adapted to the older
`module_view_for_graph(source_name_table(...))` constructor and registration
signatures, then compiled with the **same current compiler executable** and
the old checkout's standard library. It uses the same prepared names,
locals-first admission sequence, duplicate/query counts, and workload widths
as the current fixture. The old API has no bound-row-count query, so its
`final_bound_rows` field is inferred from the admitted distinct names; exact
binding counts, duplicate decisions, query hits, and checksums match. The old
implementation has no graph-local batch API, so sequential admission is the
strict mode comparison. This is a direct fixture comparison, not an accepted-
stage or end-to-end compiler comparison.

Removing the new row-list-plus-index pair leaves one private dictionary row
per source-name index, with `BoundNameOccupancy` as the value. The existing
ordered import inventories still own order; no semantic decision uses
dictionary iteration order. This is a bounded representation simplification,
not a replacement for Cut B's candidate log and import builder.

At 1000 iterations, with 16 modules and exact matching checksums:

| Representation / admission | 80-row allocations / window | 320-row allocations / window |
| --- | ---: | ---: |
| Pre-Cut-A three maps, sequential | 561,001 / 80,928 µs | 2,241,001 / 406,019 µs |
| Cut A row list + index, sequential | 913,001 / 111,712 µs | 3,649,001 / 758,776 µs |
| One keyed occupancy table, sequential | 753,001 / 123,273 µs | 3,009,001 / 666,670 µs |
| Cut A row list + index, batched locals | 823,001 / 101,006 µs | 3,273,001 / 691,945 µs |
| One keyed occupancy table, batched locals | 676,001 / 97,512 µs | 2,692,001 / 636,094 µs |

The windows are single runs, so their elapsed times indicate direction only.
Allocation counts are deterministic for this fixture. The keyed table
reduces current batched allocations by about 18% at both widths, yet still
allocates about 20% more than the old maps. At 100 iterations, the old maps
retired 154.2M / 756.8M instructions at the narrow/wide widths, while the
current batched keyed table retired 185.1M / 1,068.5M; peak footprints were
1,736,992 / 1,851,680 bytes versus 1,818,912 / 1,900,832 bytes. Both
widths retained one object and 96 net live bytes after the window. These
whole-process counters include setup and the runner. The simplification is
an improvement over the current Cut A shape, **not** a historical resource
win. Cut B should first target the import admission owner and delete the
superseded graph inventories; rerun this exact pair before closing the gate.
The current keyed-table generated C exposes one `blorp_Dict*` occupancy field
in `BoundVisibility` and has SHA-256
`b86d5158b544cead0a37b2aea5d602cae52174fb59bda2b0b6f9c547de61639f`.
Its retained benchmark executable is 1,912,880 bytes, 256 bytes smaller than
the corresponding row-list/index executable; this is a small code-size
improvement, not a meaningful compiler-output-size claim.

## First ordered-inventory deletion

`ModuleView` also appended every admitted graph alias to both `module_aliases`
and the ordered `import_bindings` list. That second list copied on immutable
per-candidate updates. The graph alias list is now deleted. Early readers
resolve a qualified alias through the keyed graph occupancy only when the
type actually names it; standalone aliases keep their separate string-keyed
lookup. `GraphQualifiedModuleBinding` remains the sole graph-alias admission
log. A graph fixture admits alias, selective, alias in the opposite order of
its source-name catalog and checks exact binding order, target IDs, and
prior-view immutability. The structural boundary check rejects restoration
of the second list or an eager alias-list lookup in type resolution.

This is a preparatory Cut B deletion, not the candidate-provenance log or a
scope-local import builder. Source-order diagnostics still arise from the
existing registration loop; grouping that loop without representing errors
as ordered events would risk reordering them. The direct width fixture shows
the cost of this deletion against the previous keyed-table binary, with
identical final rows, bindings, duplicate decisions, query hits, and checksums:

| Batched-local workload, 1000 iterations | Before allocations / window | After allocations / window |
| --- | ---: | ---: |
| 80 rows, 64 imports | 676,001 / 97,512 µs | 612,001 / 100,396 µs |
| 320 rows, 256 imports | 2,692,001 / 636,094 µs | 2,436,001 / 594,784 µs |

Allocations fall about 9.5% at both widths, with one retained object and 96
net live bytes in each run. One-sample elapsed values are not a latency claim.
The new counts are still about 9% above the API-adapted pre-Cut-A three-map
baseline (561,001 / 2,241,001 allocations), so Cut A's direct resource gate
remains open. At 100 iterations the wide pair retired about 1,068.9M versus 977.7M
instructions. Its peak footprint was 1,900,832 versus 1,933,600 bytes in
one process-level sample (+1.7%); the narrow peak fell from 1,835,296 to
1,671,456 bytes. The retained direct-fixture executable shrank 64 bytes.

The first deletion trial projected all aliases as a list for each type
resolution request. Review identified an unbounded `imports × annotations`
cost, so the final code replaced that adapter with exact keyed lookup. It
checks the view's exact graph table and selected-module owner once before
resolving a type; a regression fixture rejects sibling-module and foreign
equal-layout views without suppressing a valid alias. A
matched accepted-stage pair compares that intermediate projection trial to
the final direct-lookup version on `accepted 1 32 4 16 16 memory`: checksum
`-6362768653699369705`, 1,257 primary outputs, and 81,995 retained objects
match. The candidate also updates the benchmark fingerprint to read the
ordered binding log, so this pair is a packet-level guard, not isolation of
the alias-lookup function. Allocations fall 266,131 → 265,702, whole-process
retired instructions fall 8,238,298,488 → 8,200,807,247, and executable
size falls 9,785,792 → 9,785,632 bytes. One process-level peak-footprint
sample rises 30,949,688 → 30,966,096 bytes (+0.05%), while peak RSS and
retained objects are unchanged. This pair shows no material resource regression
on this accepted-stage workload; it is **not** a matched comparison
against the pre-deletion keyed-table implementation. Full import ownership
and accepted-stage baseline comparison remain required before closing the
performance gate.

## Module-declaration decision boundary

The next preparatory slice makes module selection and admission one explicit
`ImportDeclDecision`: missing, ambiguous, forbidden package, duplicate, or
selected. It is applied immediately in the source loop. The selected case
alone registers symbols/aliases and updates the accepted-module set; rejected
cases preserve their existing diagnostics and source order. A graph binder
fixture combines missing, selected, and duplicate declarations and asserts
exact diagnostic order and a single accepted binding. The existing standard-
library package fixture protects the forbidden case, and declaration tests
cover ambiguity resolution. This is **not** Cut B's retained candidate log or
batch import owner.

A direct `compiler_module_binding_profile 10 64 16` baseline/candidate pair
returned the same checksum, 45,580 allocations, 44,164 releases, 1,416
retained objects, and 97,064 net live bytes. The candidate executable was
176 bytes smaller (1,838,864 → 1,838,688 bytes). One native pair retired
254,002,124 → 253,765,288 instructions; one process-level peak-footprint
pair was 2,474,272 → 2,523,424 bytes (+1.99%), while a second pair reversed
that peak direction. These are small/noisy differences, not a latency or
memory improvement claim. On the accepted-stage `accepted 1 32 4 16 16
memory` workload, the checksum, 265,702 allocations, 183,707 releases,
81,995 retained objects, and 6,016,080 net live bytes match the preceding
candidate. Its executable grew 240 bytes (9,785,632 → 9,785,872), one native
pair retired 8,228,163,141 → 8,202,038,525 instructions, and peak footprint
was 30,949,688 → 30,982,456 bytes (+0.11%). These baseline binaries are the
immediately preceding keyed-occupancy candidate, **not** the pre-Cut-A
three-map implementation; Cut A's resource gate remains open.

An initial two-union implementation allocated one extra object per import
(+640 in the direct fixture). Merging lookup and admission into the single
decision union restored exact allocation parity. The next slice should use
this decision in a scope-local ordered event owner, represent rejected symbol
and alias candidates as well as module decisions, and delete the old per-
candidate graph inventories only when the owner can publish one immutable
view with unchanged diagnostics. Do not retain a second full event list
beside `import_bindings`.

## Second ordered-inventory deletion: graph selective names

Graph selective registration also appended each admitted name to both
`imported_names` and `import_bindings`. The graph list is now deleted at
admission: keyed `BoundNameOccupancy` owns the exact current-name payload,
and the binding log owns source order. `module_view_imported_names` reconstructs
an ordered list only for compatibility readers; standalone mode retains its
existing list. Header annotation canonicalization now resolves a graph import
by exact keyed name instead of constructing and scanning that list for each
type. A graph fixture checks interleaved alias, definition-selective, and
trait-method-selective rows; earlier-view snapshots and ordered projection
remain stable, including module path and source-name payloads. Accepted
type-alias installation scans the binding log without materializing the
full graph list for each header. The structural test rejects restoring the
graph append or the hot annotation list projection.

The matched direct-width worker used one compiler executable and 100 iterations
at each width. It verifies identical bound rows, accepted bindings, duplicate
decisions, query hits, checksum, and one retained object/96 live bytes:

| Aliases / selectives / locals | Before allocations | Candidate allocations |
| --- | ---: | ---: |
| 80 / 80 / 64 | 157,201 | 149,201 |
| 320 / 320 / 256 | 627,601 | 595,601 |

The 5.1% allocation reduction is deterministic for these workloads. One
wide native pair retired 4,766,275,026 → 4,522,872,709 instructions (about
5.1% fewer); a second pair was within 0.1% of those values. The retained
worker executable shrank 32 bytes (1,913,120 → 1,913,088). A 32-module
accepted-stage guard kept its checksum and retained objects, with allocations
265,702 → 265,735 (+0.012%). That fixture's source uses qualified imports,
not selective fan-out, so it does **not** validate the compatibility projection
cost or prove a production latency win. The bound-stage allocation count
remained 101,427 for the same reason.

Peak process memory remains an investigation item: three wide process pairs
put the baseline at 2.327–2.376 MB and candidate at 2.376–2.507 MB, with
overlapping ranges but candidate medians above the roadmap's 1% investigation
threshold. The binary's text/data segment sizes and net retained objects are
unchanged or lower, so these process-level samples do not identify a retained
table regression; they also do not prove the increase is noise. Do not close
Cut A's combined resource gate on this packet. A narrow production fixture
with real selective imports and an accepted-graph handoff is the next needed
check before deleting another compatibility reader or claiming a peak win.

## Acceptance and next check

- [x] Retained direct fixture varies all named workload dimensions and
  excludes name/path/ID payload construction from the measured window.
- [x] Exact row, binding, duplicate-decision, query-hit, and bound-query
  checks pass in the fixture test.
- [x] Graph binder test checks exact private/missing/duplicate diagnostic
  messages and source order, with rejected names absent from the view.
- [x] Candidate-only allocation, release, retention, native instruction,
  peak-memory, and generated-C signals are recorded.
- [x] Earlier width-probe review found no remaining fixture or binder-test
  issue; its changed-owner gate passed (5 sources, 12 suites, 1 check).
- [x] Compare the same direct workload with an API-adapted pre-Cut-A fixture
  using the same compiler executable, as recorded below. The result fails the
  resource-improvement gate; completing the comparison does not close Cut A.
- [x] Attribute wider-workload cost to row/index COW copying and ordered
  inventory growth; reject a paged fix that worsens allocations.
- [x] Publish initial graph-local rows once, preserve snapshots, and exercise
  the production binder with local-first conflicts and uncataloged fallback.
- [x] Delete the duplicate graph-alias list, resolve qualified aliases from
  owner-checked keyed occupancy, and preserve interleaved binding order. At
  that packet's checkpoint, `scripts/compiler-check --changed` passed (6
  sources, 11 suites, 1 check);
  the direct benchmark fixture passes 5/5, with independent review complete.
- [x] Make module-declaration admission outcomes explicit and preserve
  missing/selected/duplicate source order in a graph binder fixture. The
  direct import workload has allocation and retention parity with the
  preceding candidate. The changed-owner gate passes (7 production sources,
  13 suites, 2 special checks), and independent review has no actionable
  finding. This does not close Cut B or Cut A's resource gate.
- [x] Delete the duplicate graph selective-name append, preserve ordered
  compatibility projection and keyed annotation resolution, and verify the
  direct-width allocation/instruction reduction. Peak-memory and real
  selective-import accepted-stage guards remain open, so this is not Cut B
  completion.
- [ ] Extend the phase-correct batch construction owner through import
  admission with Cut B candidate
  provenance, remove superseded inventories, and show a strict majority of
  resource families improve without a material small-workload regression.
  Native hash/probe counters need an explicit instrumented hook if they become
  an acceptance requirement; do not label estimated requests as actual hashes.
