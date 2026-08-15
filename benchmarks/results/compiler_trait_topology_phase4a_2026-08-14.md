# Phase 4A Trait Topology Benchmark

Date: 2026-08-14

## Contract

`benchmarks/compiler_trait_topology_profile` measures only
`compiler_trait_topology_graph_build`. Fixture setup parses the generated
source and validates the complete Phase 1-3 predecessor chain once, outside the
profile window. The measured builder is the same API used by production
typechecking.

The default fixture contains:

- 256 traits in one inheritance chain;
- four uniquely named methods per trait, alternating required and default;
- one direct supertrait edge and one type-parameter-bound edge per trait after
  the root; and
- 1,024 method slots and 510 exact trait edges in total.

The benchmark verifies all counts and a stable semantic checksum after the
measured window. Its checksum is `2231335485996721930`.

## Measurement

Commands:

```bash
for run in 1 2 3 4 5 6 7; do
    BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 \
        benchmarks/compiler_trait_topology_profile 100 256 4
done
```

The retained iterative topology builder with graph-wide integer definition-ID
indexes measured, in microseconds for 100 complete graph builds:

```text
69944 69985 70543 70421 70332 69997 70689
```

The median is 70,332 microseconds, or 0.703 milliseconds per topology build.

The preceding iterative implementation used short-name buckets followed by
exact identity filtering. It measured a median of 93,157 microseconds for the
same workload. The retained integer index is 24.5% faster and removes the
bucket's same-name collision scaling. A discarded collision-safe string-key
index measured a median of 110,795 microseconds because constructing compound
keys in each lookup added managed-string work.

For an earlier baseline, the recursive cycle detector measured:

```text
193187 182945 188775 179283 176142 172043 230957
```

Its median was 182,945 microseconds. The retained implementation is 61.6%
faster on this isolated fixture. These are phase-constructor results, not
claims of equivalent end-to-end compiler improvement.

## Depth Regression

The iterative walk also completed this generated chain without consuming host
stack proportional to source inheritance depth:

```bash
BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 \
    benchmarks/compiler_trait_topology_profile 1 4096 2
```

It produced 4,096 traits, 8,192 methods, 8,190 edges, and checksum
`-8413876238334718851` in 62,162 microseconds. The previous short-name index
took 205,734 microseconds on this depth case.

## Design Result

The topology product stores exact trait and method identities. A method ID owns
its exact trait ID, source-order index, and structural identity, so skeletons
and topology slots cannot disagree about method ownership. Source trait headers
share the definition index's graph-wide allocation frontier, so the builder
uses their integer definition IDs as allocation-free lookup keys and validates
exact identity equality after every indexed read. Method lookup resolves that
owner header and indexes its ordered method slots directly before validating
the full method ID. Compiler-surface prelude identities do not enter the
source-header table.
Construction atomically rejects missing owners, unknown or duplicate trait
references, duplicate parameters or methods, and inheritance cycles. The
compiler-owned builtin trait manifest assigns every enum member an explicit
topological rank; construction also rejects the manifest if any inheritance
edge does not strictly descend. This preserves the accepted-graph invariant
without traversing the fixed builtin graph once per root trait.
Every measured build must succeed; the runner stops and exits nonzero on the
first measured construction error rather than validating a stale pre-window
graph.

The next Phase 4A benchmark should extend this fixture only when callable trait
signatures become a distinct phase product. It should not fold parsing, fixture
construction, or body inference into this window.

## Rough Edge

While writing the characterization suite, equality for
`Option[List[String]]` produced a missing generated specialization. The test
uses explicit `match` followed by list equality. This is a separate backend
generic-equality issue; the topology API does not rely on nested optional
collection equality.

Leak characterization also exposed a generated ownership imbalance when a
managed local alias was used both as diagnostic provenance and as a stored
field during pure graph construction. The retained builder projects the parsed
identifier directly at each use and the focused leak gate covers the complete
topology suite. That backend ownership pattern remains a separate issue to
isolate if it appears outside this constructor.
