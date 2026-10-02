# Compiler Priorities

The overriding goal is a fast feedback loop: compile `blorp/src/main.brp` to C
in about 10 seconds. [Architecture](ARCHITECTURE.md) and
[Ownership Model](OWNERSHIP_MODEL.md) own production contracts; Git history and
`benchmarks/results/` own completed work and measurements.

## Measure First

Every performance proposal is judged with the
[self-compile measurement protocol](../benchmarks/README.md#self-compile-measurement-protocol):
retired instructions and per-phase allocations on the frozen self-compile
input, byte-identical generated C, and the small-program guard. The newest
`benchmarks/results/self_compile_baseline_*.json` and
`self_compile_small_baseline_*.json` (and the `stage2` pair for codegen and
runtime work) built with your toolchain are the reference; compare only
against a baseline from the same toolchain. Wall time is confirmation, never
the argument.

## Where The Time Goes

Do not restate a profile here; it is stale as soon as the next cut lands. The
per-phase allocation and instruction rows come from the harness above, the
per-pass work and attribution reports are retained in `benchmarks/results/`
(for example the Perceus, Core lowering, backend emission and typecheck
attribution files), and `benchmarks/README.md` says how to take a fresh sample
of any pass. Open speed work is in the
[Compiler Speed Roadmap](COMPILER_SPEED_ROADMAP.md),
[Per-Node Codegen Roadmap](PER_NODE_CODEGEN_ROADMAP.md) and
[Identity And Tables Roadmap](IDENTITY_ROADMAP.md).

## Rules For The Next Round

- One change per change, with byte-identical C unless the change is a
  correctness fix, and the focused suite plus the manifest-owned checks green.
- Prefer removing work (fewer walks, fewer copies, shared unchanged subtrees)
  over tuning allocation policy.
- Record acceptance measurements in `benchmarks/results/`. Plans for active
  work live in this directory and hold only open work; open issues are files in
  [`issues/`](issues/) (see the [maintenance rules](README.md#maintenance-rules)).
