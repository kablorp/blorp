# Ownership Optimization Admission Gates

**Status:** Conditional. Earlier Perceus contract, borrowed-boundary, and
whole-function cleanup cuts are in production. A current profile has not
admitted a universal all-value ownership analysis or match-identity rewrite.
The separate [cancellation cleanup issue](53-minimize-and-compact-cancellation-cleanup.md)
owns the live compact cleanup-ABI continuation.

**Current contract:** [Ownership Model](../../OWNERSHIP_MODEL.md) defines the
managed-value, call, storage, COW, and cleanup ABI. Optimizations may change
the placement or count of operations only when they preserve value semantics,
destruction order, reuse proofs, and cancellation behavior. Core ownership
events and generated C are observable validation artifacts.

**Next action:** Reprofile current production Perceus and generated-program
ownership work. Admit exactly one new consumer-specific issue only if a named
legacy scan, action family, or nonescaping allocation remains material. A
negative census closes that candidate without building a universal framework.

## Possible Cuts, Not An Implementation Queue

### All-Value Facts

An all-value/region fact product is **not admitted** by the last retained
profile. A new issue must name at least two measured consumers, the exact
body visits it removes, and the owner of each fact. Collect direct syntax
facts once per function; solve recursive contracts over compact graph facts,
not by revisiting Core bodies. Do not retain a second collector or broad fact
record without an immediate production reader and measured net benefit.

### Ownership Plan And Materialization

Only after shared value facts pay for themselves, consider a separate
function-local plan for lexical, branch, match, repetition, transfer, and
return actions. Materialization should insert `DupExpr`/`DropExpr` from that
plan without rediscovering ownership. Migrate one region family at a time,
preserve exact event order, and delete the old decision path in the same cut.
Do not introduce a plan wrapper that simply coexists with current insertion.

### Proven Action Removal

Only an explicit plan with provenance may remove redundant retain/release
actions. Start from a regression with a predicted exact operation delta and
near-miss cases. Never erase a terminal `DropExpr` that reuse still consumes as
the proof of owner death. Either retain that witness or teach reuse an
equivalent explicit fact first. Require COW uniqueness, cancellation,
runtime/leak/sanitizer, and generated-C evidence for each rule.

### Tranche 9: Remove Nonescaping Container Allocations

Start only when a current compiler/self-host census finds enough eligible
record sites to measure. Prefer scalar replacement of a local aggregate over
placing a heap-compatible ARC object on the stack. A pre-Perceus escape
analysis must own exact post-projection Core sites and reject returned,
stored, captured, foreign, unknown-call, and COW-observable aggregates.
Folding a child into a surviving parent's heap allocation is a distinct,
stronger [admission-gated prototype](NESTED_RECORD_FOLDING_PROTOTYPE_ROADMAP.md),
not an incidental extension of local SROA.

## Fast Feedback And Decision

First use the current direct Perceus benchmark and a production self-host
profile to count the claimed work or occurrence. Keep setup outside the timed
pass. For an admitted candidate, compare exact ownership-event traces, Core,
generated C, allocation/release counts, retired instructions, peak memory,
and paired latency on matched baseline/candidate binaries. Include a
low-occurrence control so fixed analysis overhead remains visible.

Run the focused owning Core suite while iterating; before acceptance run
compiler, runtime, leak, sanitizer, cancellation, and codegen-audit gates
affected by the change. Record raw samples in `benchmarks/results/`.
Reject a candidate that merely creates a cleaner representation, shifts
allocation to another phase, loses a reuse witness, or wins only on a
synthetic fixture. Stop the workstream when no current profile admits another
cut; an intentionally avoided architecture is not unfinished work.
