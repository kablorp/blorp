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

Tuples keep structural identity and ordinal access, but Core shares one
product model with records: the same operations, scalar replacement and
multi-value results, with representation (managed box or inline value) kept
separate from identity. [Product unification](PRODUCT_UNIFICATION.md) owns
that work; the declaration/use identity below is its prerequisite for one
Core product type.
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

## Fixed-record continuation: checked layout contract

The next fixed-record workstream is a future checked no-box contract, not a
description of the landed representation. A fixed value would have a known
shallow layout without a separate root allocation or hidden transport box.
Managed children would still allocate and require copy/drop ownership. Source
admission must wait until every admitted placement preserves the contract;
unsupported erased, collection, closure, generic and foreign positions must
produce a precise diagnostic before emission. A syntax spelling or a direct
local oracle alone cannot establish this contract.

Prioritize [product unification](PRODUCT_UNIFICATION.md) and measured
product opportunities before opening this source promise. Keep `Option` and
`Result` as sums: only the active payload is initialized and owned, and
nullable, tagged and boxed specialized representations remain independent
decisions. Record work does not authorize fixed-union admission, enum
retirement, or replacing sum storage with ordinary record fields.

### Recover ownership prerequisites in bounded slices

Earlier value-record experiments targeted a pipeline that the landed record
unification removed. Their checkpoints are historical evidence, not proof that
the current managed-record tree supports owned inline values. These
obligations remain open:

1. Establish declaration/use identity across frontend lowering, specialization,
   Core and C symbol projection. A rendered name, module-path sanitization,
   declaration order or a second unchecked name map is not nominal identity.
   Cover same-spelling types from distinct modules and wrong-kind uses at the
   earliest authoritative boundary. A local `union Option[T]` and the prelude
   `Option` already lower to one Core type reference; see
   [`core-lowering-nominal-origin-collision`](issues/core-lowering-nominal-origin-collision.md).
2. Bind prepared cleanup and cancellation facts to the exact final Core program.
   Open: the actions and activations inside a present cancellation row,
   same-shape corrupted rows, and cleanup-plan rows are not checked. Any such
   check that can fail must return a typed error on both single- and
   split-unit emission entries, never a default. Delete the emit-side
   fallbacks `global_cancellation_plan_or_default`,
   `function_cancellation_plan_or_default` and
   `empty_cancellation_protection_plan`, which turn a missing row into an empty
   plan.
3. Give backend-created owners explicit site and slot provenance. Rendered C
   text cannot prove that an expression is an addressable cleanup temporary.
   Prepare the operation and value-versus-address callback ABI from one checked
   authority before rendering.
4. Prove existing ARC, ARC-only and stack-`Result` behavior first, then add one
   owned-inline vertical slice. Direct-local tests need dynamically allocated
   children, copy/move/update/drop, branch joins and cancellation. Test a
   one-child and two-child owner with exact allocation/release/live counts and
   a comparable ordinary managed-record control.

Keep representation, owner existence, copy/drop, cancellation and ABI placement
as separate explicit facts. An inline value with owned children is not an ARC
pointer. Never substitute an empty release, inert cleanup action or generated
error C for an unsupported owner. If a required action can only be discovered
during rendering, convert the smallest owning call chain to a typed error
channel before expanding admission.

### Recovery and acceptance boundary

Integrate the declaration/use identity candidate only after the Perceus fix on
branch `perceus/for-loop-global-retain` lands. It repairs a heap-use-after-free
on main: the for-loop arms in `perceus/borrowed.brp` skipped retaining a
managed global stored into a record. Integrate declaration/use identity,
checked plan and slot authority, and the product oracles as separate reviewed
slices against the current APIs.

Stop at any unexplained leak, retain/release, use-after-free or cancellation
difference. Each preparatory slice must preserve existing behavior and emitted
C where applicable; each physical-layout slice needs inspected C, exact dynamic
ownership oracles, relevant sanitizers, the stage-2/3 C fixpoint and matched
stage-2 allocations/retired instructions. A passing test packet, smaller C or
a static count cannot close those gates.

## Verification

Start with the owning narrow suite and `scripts/compiler-check --changed
--plan`, then the selected compiler gates. Syntax cuts require focused
parser/discovery/formatter suites, editor sync, doctests, and compiler-new
parity. Codegen/ownership cuts also require generated-C inspection, codegen
audit, runtime/leak and relevant sanitizers; C-changing compiler cuts require
`scripts/compiler-fixpoint`. Run compiled gates serially on macOS and retain
full logs and raw measurements under `benchmarks/results/` or linked artifacts.
