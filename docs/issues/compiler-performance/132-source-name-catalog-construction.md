# Build The Source-Name Catalog Without A Growing Intermediate List

**Status:** Implemented and validated against `bdce2c5a`

**Current state:** indexed-graph construction threads one private insertion-
ordered dictionary through prepared-program declaration traversal. The
dictionary issues each spelling's stable ID at first insertion and materializes
the ordered spelling list once during finalization. The former graph-wide
candidate list and second pass no longer exist in production.
**Next action:** Keep the retained `source-names` benchmark in compiler
performance comparisons and use `indexed` for the wider graph-construction
control.
**Read first:** `blorp/src/compiler/stage_06_typecheck/graph/source_name_table.brp`,
`blorp/src/compiler/stage_06_typecheck/graph/indexed_graph.brp`, and
`blorp/test/compiler/stage_06_typecheck/test_indexed_graph.brp`.
**Fast loop:** Exercise the `indexed` stage of
`benchmarks/compiler_typecheck_phase_profile` with module count, declarations,
imports, imported symbols, constructors, and duplicate spellings varied
independently.
**Decision:** Preserve first-seen spelling order and every issued `SourceNameId`.
Ask for guidance before changing the opaque table API or allowing a builder to
escape indexed-graph construction.

## Objective

Remove a graph-wide growing candidate list and its second pass while retaining
one exact compilation-local spelling authority.

A private insertion-ordered dictionary is the construction state:

```blorp
private type alias SourceNameTableBuilder = Dict[String, Int]

private pure func source_name_table_builder_add(
	builder: SourceNameTableBuilder,
	spelling: String,
) -> SourceNameTableBuilder:
	if builder.contains(spelling):
		builder
	else:
		next_id = builder.length()
		builder.set(spelling, next_id)
```

Dictionary key order is insertion order, so finalization materializes the
ordered spelling list once with `builder.keys()`. The builder is threaded as an
owned value through module, declaration, import-symbol, and constructor
traversal. It never escapes indexed-graph construction.

## Invariants And Tests

- Preserve prepared-module order, declaration order, import order, selected
  symbol order, and constructor order.
- The first occurrence of a spelling determines its exact integer ID.
- Duplicate local/imported spellings remain idempotent at this catalog layer;
  later visibility or binding diagnostics retain their current authority.
- Preserve qualified-import default aliases, explicit aliases, source-extension
  stripping, private declaration recursion, trait methods, and exclusions for
  implementation bodies, fields, and parameters.
- Cover empty graphs, duplicate-heavy graphs, alias collisions, selective
  imports with constructors, foreign blocks, private declarations, and two
  module orders containing the same spellings.
- Verify both spelling-to-ID and ID-to-spelling projections, not only counts.

For example, a fixture whose traversal encounters `alpha`, `beta`, `alpha`,
`gamma` must still issue IDs `alpha=0`, `beta=1`, and `gamma=2`.

## Measurement

The retained source-name profile prepares and validates the complete graph,
then measures only the production catalog constructor over the ordered prepared
programs. Parsing, graph setup, and later inference remain outside the window.
It reports total candidates, unique candidates, duplicate probes, dictionary
insertions, allocations, elapsed time, and an ordered `(id, spelling)` checksum
that also validates each spelling-to-ID dictionary entry.

```bash
benchmarks/compiler_typecheck_phase_profile indexed
BLORP_COMPILER_BENCHMARK_INSTRUMENTATION=plain \
BLORP_COMPILER_BENCHMARK_DEBUG=0 \
benchmarks/compiler_typecheck_phase_profile \
  source-names 10 32 96 0 8 4 4 memory
bin/blorp test --timeout 180 \
  blorp/test/compiler/stage_06_typecheck/test_indexed_graph.brp
scripts/compiler-check --stage typecheck
scripts/test compiler-blorp
```

Use a duplicate-light width series and a duplicate-heavy series. Keep a tiny
one-module control so dictionary/build fixed costs cannot hide a regression.
For a final comparison use matched binaries and the same prepared graph; do not
compare independently parsed inputs.

### Implementation Results

The matched comparison used optimized binaries from `bdce2c5a` and this change,
the same fully prepared fixture, 15 interleaved warm samples, and exact ordered
checksums. Fixture parsing and full typechecking remained outside the timed
window. The baseline benchmark called its production
`source_name_candidates_for_decl` traversal followed by `source_name_table`;
the candidate called `graph_source_name_table_for_programs`.

| Workload | Baseline median | Candidate median | Allocations |
| --- | ---: | ---: | ---: |
| 32 modules, 96 unique names/module, 10 catalog builds | 11,882 us | 8,202 us | 1,780 -> 40 (-97.8%) |
| 32 modules, 96 shared names/module, 10 catalog builds | 6,750 us | 3,100 us | 1,760 -> 40 (-97.7%) |
| One module, one name, 200 catalog builds | 210 us | 176 us | 1,000 -> 800 (-20.0%) |

The duplicate-light allocated-byte count fell from 33,008 to 29,944; the
duplicate-heavy count fell from 8,432 to 6,136. A whole indexed-stage control
also improved from 112,401 to 110,351 allocations and retained the exact output
checksum. The one-module, one-name whole-stage control remained within noise at
59,776 us versus 59,194 us (-1.0%). Other indexed-graph products dominate the
wider count.

The exact work profile shows the intended boundary: after subtracting one
registration call, 43 candidate probes produced 27 insertions, 16 duplicate
probes, and one finalization, with exactly 27 dictionary sets. Generated C
confirms every loop consumes its dictionary accumulator without retaining it
before insertion; import dispatch also avoids an aggregate match allocation.

Raw elapsed samples in microseconds, in baseline/candidate pairs:

- Duplicate-light baseline: `10401,10609,10754,11882,14510,11213,10996,14304,12387,13306,9722,13930,12837,11271,13042`
- Duplicate-light candidate: `7756,7272,8016,9834,10416,11259,11311,6172,7702,10940,9516,7758,6528,8202,11676`
- Duplicate-heavy baseline: `7000,6629,6750,7506,6585,7407,6049,7202,7409,6804,6849,6037,6102,5464,5226`
- Duplicate-heavy candidate: `4794,4619,2603,8187,2224,2711,5934,3100,2626,2726,5159,4076,2234,2333,4203`
- Tiny baseline: `214,203,204,214,203,562,210,197,215,199,202,297,196,245,225`
- Tiny candidate: `176,165,189,229,168,169,168,162,238,256,166,305,167,209,178`

### Reproducing The Historical Baseline

The retained
[`132-source-name-catalog-baseline.patch`](132-source-name-catalog-baseline.patch)
adapts the current benchmark fixture to the production catalog path at
`bdce2c5a`. It removes candidate-only debug markers and replaces only the
measured constructor with the baseline candidate-list traversal.

```bash
candidate_root=$PWD
git worktree add --detach /tmp/blorp132base bdce2c5a
make -C /tmp/blorp132base
cp \
  "$candidate_root/blorp/benchmark/compiler/compiler_typecheck_phase_profile.brp" \
  "$candidate_root/blorp/benchmark/compiler/compiler_typecheck_phase_profile_fixture.brp" \
  "$candidate_root/blorp/benchmark/compiler/compiler_source_name_catalog_profile_fixture.brp" \
  /tmp/blorp132base/blorp/benchmark/compiler/
git -C /tmp/blorp132base apply --unidiff-zero \
  "$candidate_root/docs/issues/compiler-performance/132-source-name-catalog-baseline.patch"

BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 \
  /tmp/blorp132base/benchmarks/compiler_blorp_benchmark_runner \
  compiler-source-name-base \
  blorp/benchmark/compiler/compiler_typecheck_phase_profile.brp \
  plain source-names 10 32 96 0 8 4 4 memory

BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 \
BLORP_COMPILER_BENCHMARK_INSTRUMENTATION=plain \
BLORP_COMPILER_BENCHMARK_DEBUG=0 \
  benchmarks/compiler_typecheck_phase_profile \
  source-names 10 32 96 0 8 4 4 memory
```

The final duplicate-light raw outputs both reported 3,873 candidates, 3,713
unique names, 160 duplicates, ordered checksum
`-7556172533034521486`, and `workload_valid=True`. Baseline allocation output
was `total_allocations=1780 allocated_bytes=33008`; candidate output was
`total_allocations=40 allocated_bytes=29944`.

SHA-256 provenance for the measured Darwin arm64 artifacts:

| Artifact | SHA-256 |
| --- | --- |
| Baseline compiler | `9a8bddbb16796f4d049b36c57caaaea6753cfa4292076368f1fcecb117f06feb` |
| Candidate compiler | `ddfb2531ba8a4789d270fe60714caa341c439e59dd9da68df03cca5d075e6804` |
| Baseline benchmark binary | `599773d5716c236c030cf92c72514295acb37358f9b282f9258346a0950ad1ea` |
| Candidate benchmark binary | `eba5e5850a5f7894c0db745000bbfcfa9a3abaf64d8968df46b1e101b8747e2c` |
| Baseline profile source after adapter | `9994fe8020a88c5e2f0baea34927b621e9ea3736e1da883980b18748c4ff0554` |
| Baseline fixture source after adapter | `f82b4cfe6cf5be277ec5c2450e6705e598a425c3b2e92a817bb6f39c6905ddf5` |
| Candidate profile source | `cf77dfd20aee23359f785f43871e7533c88a79b3b2d61726d6e2ee7aae135c2c` |
| Candidate fixture source | `f5a54535cbf40859480529424d55c0cbb556e24c0cfdd47e8cc9966320cfc78e` |
| Shared source-name workload fixture | `778ed258c5cb4d9aa8ae0bd639b5a07f225feabfb7ab7fcda2b66e4ea3a9b2ed` |

The baseline and candidate compilers emitted byte-identical C when compiling
the same current `blorp/src/main.brp` tree (SHA-256
`1def50130c892a82bbfaa154343ad67218705800f1ab0076bc9a42ebac308d6b`).
The retained checksum includes source-name count, exact ID order, reverse
spelling-to-ID agreement, and table totality, so later comparisons cannot miss
catalog reordering or divergence between the table's two projections.

## Acceptance And Rejection

Accept when the intermediate candidate list is removed, modeled prefix/second-
pass work falls by at least 80%, a compiler-shaped wide graph improves retired
instructions or allocations by at least 10%, the small control stays within
3%, exact ID/order checksums match, and compiler-self C is byte-identical.
Reject if the builder is repeatedly copied under value semantics, table order
changes, another component keeps the old candidate list alive, or improvements
come only from duplicate-heavy synthetic input.
