# Step 2e Importable-Graph Normalization Cleanup

## Scope

This is one matched baseline/candidate screen for three related deletions in
the graph import path:

1. `ImportableModuleIndex` keeps one canonical path-to-ordinal index instead
   of a second path-to-module dictionary. Alias buckets no longer perform a
   redundant linear membership check. Dependency construction reuses one dense
   ordinal epoch table across the graph, replacing repeated linear membership
   checks without allocating a set or sorting each module's adjacency row.
2. `IndexedGraph` normalizes selective export demand once, after finalized
   import paths and `ModuleId` rows exist. The retained row is an explicit
   `none`/`one`/`many` value; the common zero- and one-name cases do not allocate
   a hash set. Importable-module construction reads the exact module row rather
   than rebuilding one graph-wide source-string set on every admission. A
   linear count/offset/scatter builder groups wide requests before publishing
   their buckets, avoiding quadratic copy-on-write growth.
3. Imported type facts replay the accepted `GraphSelectiveDefinitionBinding`
   module and definition IDs. The old path-to-surface dictionary and export
   rescan are gone.

Two rejected prototypes are intentionally not retained. A dense persistent
list updated once per import increased the focused importable-stage allocation
count from 12.87M to 16.12M. A sparse integer dictionary was effectively the
same. Moving normalization to `IndexedGraph` removed that repeated work; using
one hash set per module then exposed a 2.5% indexed-stage allocation increase,
so the final `none`/`one`/`many` representation replaced it.

## Fast feedback

The comparison used the existing cached plain workers and one sample per
stage. The workload has 64 modules, 16 shapes per module, selective imports,
and fanout 4. Checksums, output counts, lookup counts, and constructor work
counts were exact.

```bash
/usr/bin/time -lp <worker> \
  importable 1000 64 16 1 4 memory 100 selective
/usr/bin/time -lp <worker> \
  indexed 100 64 16 1 4 memory 100 selective
/usr/bin/time -lp <worker> \
  accepted 3 64 16 1 4 memory 100 selective
```

The baseline worker key was
`b86e9fe50aed84859c0643b34a2be55011062617f546523c73c7c0e3fb36558c`;
the candidate key was
`4ebac8404d5d7900ae0c20a64221428c7f0e9b82d441b9f87fcded6bb468859d`.

## Results

| Stage and signal | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Importable allocations | 12,872,001 | 12,867,001 | -0.039% |
| Importable retained objects | 10,152 | 10,149 | -3 |
| Importable retained bytes | 726,192 | 725,808 | -384 B |
| Importable retired instructions | 30,555,542,915 | 30,026,792,883 | -1.73% |
| Importable peak footprint | 54,149,480 | 54,051,152 | -0.182% |
| Indexed allocations | 1,541,501 | 1,575,101 | +2.18% |
| Indexed retired instructions | 9,568,887,101 | 9,665,775,101 | +1.01% |
| Indexed peak footprint | 55,411,048 | 55,411,048 | 0.000% |
| Accepted allocations | 3,279,658 | 3,273,205 | -0.20% |
| Accepted retired instructions | 19,866,818,822 | 19,858,697,801 | -0.041% |
| Accepted peak footprint | 235,717,112 | 235,749,880 | +0.014% |
| Worker bytes | 5,915,120 | 5,916,816 | +0.029% |

The indexed-stage allocation increase is the explicit cost of retaining
module-scoped demand once in the normalized graph product, including the
linear grouping buffers that keep wide buckets from quadratic COW growth. Its
1.01% instruction movement is paid once per graph, while peak footprint is flat.
The downstream importable and accepted stages both reduce allocations, while
the importable stage also reduces retained bytes and retires 1.73% fewer
instructions. Accepted-stage instructions and peak footprint are flat-to-lower
in this one sample. The combined production path therefore keeps the normalized
owner rather than reconstructing demand
for each later consumer. Wall time moved in the same direction in this sample,
but no latency claim is made from one pair.

## Correctness gates

```bash
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_indexed_graph.brp
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_definition_index.brp
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_bound_module_graph.brp
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_typecheck_decl.brp
bin/blorp test blorp/test/compiler/stage_04_modules/test_imports.brp
python3 blorp/test/compiler/stage_06_typecheck/support/test_declaration_boundary.py
scripts/compiler-check --changed
```

The indexed-graph regression covers distinct module rows, the compact
single-name state, the multi-name set transition, and an empty target row.
The unresolved-path branch deliberately applies demand conservatively to all
modules; it does not infer semantic identity from a source spelling.
