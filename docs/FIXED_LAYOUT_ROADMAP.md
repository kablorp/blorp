# Record Simplification Roadmap

Status: S1–S4 are landed. Ordinary `record` and `fixed record` use the same
managed-record semantics and ARC/COW representation. The old value-record
pipeline is deleted, and native snapshot boundaries use explicit adapters.
The source migration and keyword retirement remove the legacy `struct`
declaration form; `struct` is now an ordinary identifier.

Read [WORKER_CHECKLIST](WORKER_CHECKLIST.md) before compiler work. The
[Language Guide](GUIDE.md), [Grammar](GRAMMAR.md), and
[Memory Model](MEMORY_MODEL.md) describe the current source contract.

## Landed simplification and evidence

A nominal product has one value model: immutable logical values, managed
children, value-preserving updates, and ownership-aware reuse through ARC/COW.
Generic and dimension-parameterized records remain supported. `fixed record`
preserves its spelling in tooling but promises neither inline or stack
placement, no allocation, nor a native by-value ABI. `fixed` is contextual
before `record` and remains an identifier elsewhere.

S1 classified the former product layouts and froze the cost baseline; S2
migrated callers and allocation oracles; S3 adapted native boundaries; S4
converged semantic headers, Core, ownership, and emission. Retained evidence:

- [Semantic catalog pilot](../benchmarks/results/record_unification_catalog_counts_pilot_2026-10-03.md),
  [metric pair](../benchmarks/results/record_unification_metric_pair_2026-10-03.md),
  and [header counts](../benchmarks/results/record_unification_header_counts_2026-10-03.md)
  retain the bounded precursor measurements.
- [Repair checkpoint](../benchmarks/results/record_s4_repair_checkpoint_2026-10-03.md)
  and [remaining gates](../benchmarks/results/record_s4_remaining_gates_2026-10-03.md)
  retain S4 provenance, commands, ownership oracles, and validation repairs.
  The prepared S4 integration passed 25,438 checks across 13 gates, the
  three-stage C fixpoint, the 228-fixture stage-2 codegen audit, quality, and
  stage-2 runtime/layout controls. These are correctness results, not a
  performance or release acceptance claim.
- [R0 evidence](../benchmarks/results/fixed_layout_r0_2026-10-03.md),
  [managed-union pilot](../benchmarks/results/STRUCT_PAYLOAD_S2A_OUTCOME.md),
  and [accessor follow-up](../benchmarks/results/struct_payload_managed_union_s2b_probe_2026-09-23.md)
  explain why earlier layout proposals were not admitted. Static box counts,
  smaller generated C, or isolated inline construction do not prove a win.

The syntax-capable bootstrap `dev-8228a8fa12e3` supports `fixed record`.
Keyword retirement removes the legacy lexer/parser/source-form/discovery/
formatter branches and migrates embedded source fixtures. C `struct`
syntax, native aggregates, and the scalar `Option`/`Result` storage machinery
remain valid. This cut changes source syntax, not representation.

The [keyword-retirement report](../benchmarks/results/struct_keyword_retirement_2026-10-04.md)
retains the final 19,893-check packet, measured cost, output identity, source
provenance, and the bounded S5 census. Same-cwd allocations were unchanged;
sampled instruction deltas establish no speed benefit.

## Boundaries retained for future optimization

Native snapshot adapters are selected by explicit `DeclaredAbi` identity.
Their schemas own field order and types; typechecking validates the language
record before emission. Each adapter takes one native snapshot and constructs
an owned, allocating managed result. Source spelling and rendered type names
do not select a native ABI.

Managed `get_mem_stats()` snapshots allocate. Exact single-fiber intervals use
nonallocating scalar `read_memory_counter(MemoryCounter)` endpoints and construct
reports after the measured interval. Counter-active flags remain mandatory;
disabled instrumentation is not zero activity. Separate scalar reads do not
promise a coherent concurrent snapshot.

Managed pointers are not ABI-equivalent to C by-value aggregates. Use explicit
scalar/`Ptr` wrappers for foreign aggregate boundaries. Direct C aggregate
support, generalized aggregate annotations, and copy-in/copy-out metadata
remain deferred; do not infer an ABI from field shapes.

Tuples remain structural products with ordinal access. Existing local/match
scalar replacement and multiple results stay distinct from managed records;
[the tuple plan](VALUE_TUPLES_AND_STATE_HANDOFF.md) owns stored-tuple work.
`union`, `enum`, `Option`, and `Result` retain their current sum
representations. Fixed-union syntax and enum retirement require separate ABI
and active-payload ownership decisions.

## S5. Decide which layout optimizations are worth reintroducing

The narrow literal-only scalar-record projection pilot is **parked**: a
schema-validated fusion-Core census found zero strict eligible sites among
11,653 record locals in 18,234 top-level functions (224 bodyless). Aliases,
embedded implementation methods, globals, managed fields, nonliteral right-hand
sides, capture, and whole-value uses were outside the admitted subset. This is
bounded static evidence, not a dynamic ROI claim or closure of the wider S5 work.

The [dynamic managed-record allocation census](../benchmarks/results/record_allocation_census_2026-10-04.md)
keeps that literal-only pilot parked and redirects the next investigation:
small tuple/SSA mint wrappers have tiny dynamic reach, while `Cursor` dominates
the workspace self-compile ranking. The [source-coordinate builder pilot](../benchmarks/results/cursor_scalar_reconstruction_2026-10-04.md)
is accepted as a bounded source-owned optimization: matched self-compile
allocations fell 13.93% and minimum retired instructions 8.19%, with identical
emitted C and completed correctness, quality and fixpoint gates. Managed record
APIs/layout are unchanged; this is not general scalar replacement, a general
inliner or a reintroduced layout promise. The wider S5 work remains open.

Profile actual record constructions and escapes before choosing an optimization.
The compiler may scalar-replace a nonescaping record or fold a fresh nested
record into one parent allocation while preserving ordinary record semantics.
For parent inlining, every constructor of one type must use the same field
layout; an extracted independent child may require materialization and an
explicit borrow/ownership rule.

Compare full-pipeline allocations, retired instructions, retains/releases, and
C size against the simpler baseline. Reopen an explicit `fixed` layout promise
only with a sound contract across typed, erased, collection, closure, generic,
and foreign positions and a substantial measured benefit. Otherwise keep
optimization implicit.

Each optimization needs its own accept/park decision. No performance claim
follows from static source counts, shorter C, or a microfixture alone.

## Verification

Start with the owning narrow suite and `scripts/compiler-check --changed
--plan`, then the selected compiler gates. Syntax cuts require focused
parser/discovery/formatter suites, editor sync, doctests, and compiler-new
parity. Codegen/ownership cuts also require generated-C inspection, codegen
audit, runtime/leak and relevant sanitizers; C-changing compiler cuts require
`scripts/compiler-fixpoint`. Run compiled gates serially on macOS and retain
full logs and raw measurements under `benchmarks/results/` or linked artifacts.
