# Compiler Priorities

The overriding goal is a fast feedback loop: compile `blorp/src/main.brp` to C
in about 10 seconds. [Architecture](ARCHITECTURE.md) and
[Ownership Model](OWNERSHIP_MODEL.md) own production contracts; Git history and
`benchmarks/results/` own completed work and measurements.

## Measure First

Every performance proposal is judged with the
[self-compile measurement protocol](../benchmarks/README.md#self-compile-measurement-protocol):
retired instructions and per-phase allocations on the frozen self-compile
input, byte-identical generated C, and the small-program guard. The retained
`benchmarks/results/self_compile_baseline_*_r2.json` files are the current
reference. Wall time is confirmation, never the argument.

## Where The Time Goes

The 2026-09-16 profile of the self-compile put about half of self time in
Core passes (Perceus, traversal, DCE, preparation), a sixth in typechecking,
and the rest spread across lexing and parsing, backend emission, and the
standard library's own collection operations. The structural causes were
whole-tree rebuilds per pass, repeated ownership summaries, and linear scans
keyed by names or definition IDs. The first round of cuts removed about a
fifth of instructions and allocations; the remaining hand-rolled rebuilders
in preparation and closure conversion, the Perceus call-contract lookup, and
per-identity module-name sanitization are the next measured targets.

## Rules For The Next Round

- One change per change, with byte-identical C unless the change is a
  correctness fix, and the focused suite plus the manifest-owned checks green.
- Prefer removing work (fewer walks, fewer copies, shared unchanged subtrees)
  over tuning allocation policy.
- Record acceptance measurements in `benchmarks/results/`; do not write
  packets or roadmaps in this tree.
