# Publish accepted facts and narrow their owners

## Problem and scope

The source audit at `51d98be37bf467db383c91f3a541d14c54885b08` found four
bounded architecture issues, without a demonstrated source-program
miscompilation:

1. Receiver visibility is admitted, discarded, and reconstructed per call.
2. Default-method written header bounds are proved through two traversals.
3. A specialization index exposes construction outside its actual owner.
4. Verify and Emit separately walk the same aggregate dependency graph.

This plan resolves those four findings only. It does not redesign the pipeline,
extend the language, activate unrelated deferred tests, change dictionaries or
record bounds, or narrow independent ownership verification. Transient state
may still be discarded; not every repeated projection deserves storage.

Read [AGENTS.md](AGENTS.md) and the parent
[handoff rules](../docs/HANDOFF_SPEC.md). Refresh these source anchors against
current main before implementation: other work continues there. Examples below
are proposed interfaces, not code already accepted by a compiler.

## Sequence and ownership

| Milestone | Audit finding | Producer and lifetime | Consumers |
| --- | --- | --- | --- |
| F1 | Duplicate default-header proof | Existing trait-header proof; no new retained product | Body checking uses the existing normalized contract |
| F2 | Public specialization index | Private Specialize construction state; gone at publication | Specialize discovery, settlement and sealing |
| F3 | Repeated receiver visibility | Check admission; retained through body checking only | Receiver resolution and overlap admission |
| F4 | Duplicate aggregate traversal | Verify completion order; retained through emission | Aggregate definition rendering |

Land F1 and F2 independently; their implementation and review can run in
parallel. F3 and F4 can also be developed independently after early seam
review. Serialize compiled gates and measurements, and rebase each landing
before its final gate. Four reviewed implementation commits are sufficient;
do not create planning-only landing commits for every checkpoint.

## F1: prove a default's written header once

**Current boundary.** `src/check/well_formed.brp:301–303` first proves every
trait method, then every accepted function. Defaults occur in both inventories.
`src/check/signatures.brp:515` already accepts the default contract once and
only normalizes its parameter identities for the body.

Current second traversal:

```blorp
_: Void ?= first_error(functions, pure func(function): prove_signature(traits, function.declaration.parameters, function.declaration.return_type, function.signature, function.signature.requirements))
```

Instead traverse the existing `FunctionRow` inventory in its current order,
using its existing role. Do not add a flag, role field or membership set:

```blorp
-- Sketch of the per-row helper; preserve the existing invariant diagnostic.
match row.role:
    TraitDefaultBody:
        Ok(void) -- prove_trait_methods owns this written header.
    FreeFunctionBody | ImplementationBody:
        -- Read the accepted row by its existing FunctionId, then invoke
        -- the unchanged prove_signature with its requirements.
        prove_ordinary_header(row, functions, traits)
```

Keep default normalization, body-local annotation proofs, implementation
receiver proofs and post-finalization supertrait checks unchanged. The ordinary
header helper must reject a missing accepted row, never silently skip it.

**Tests.** Extend the active declaration-bound coverage with an accepted
default whose signature applies a bounded nominal type, a rejected default
missing entailment, and rejected free-function and implementation headers.
Assert exact message, help, note and span. Keep a default body-local annotation
rejection to demonstrate that skipping its header does not skip its body.
Temporarily bypass the trait-header proof to show its rejection test fails.
Source review, rather than a test that counts calls, establishes removal of the
duplicate proof.

**Acceptance.** Same accepted programs, checked identities and diagnostics;
one written-header proof path per default. Expected production growth is
10–25 lines for explicit role dispatch, not another representation.

Implementation and validation evidence is retained in the
[F1 results](../benchmarks/results/blorp2-architecture-facts-2026-10-31.md).
F1 is complete: independent code-reviewer and test-runner approvals, the
self-hosted fixpoint gate and matched-cost checks pass. F2–F4 remain pending.

## F2: make the specialization index phase-private

**Current boundary.** `src/specialize/indexed_list.brp:27` publicly exposes
`entries` and its derived `positions`. Its only production importer is
`src/specialize/specialize.brp:24`. Existing mutations at lines 1488/1530
(pending settlement) and 2067 (record sealing) legitimately preserve digests.

A generic opaque wrapper with an unchecked `replace` or `map` would merely
hide the same precondition. Checking bucket membership on every replacement
can introduce quadratic work for colliding slots. Neither is the plan.

Move the existing container and its four helpers into `specialize.brp`, all
private, and delete the standalone module:

```blorp
private record IndexedList[T] {
    entries: List[T],
    positions: HashMaps.HashMap[Int, List[Int]]
}

-- Move existing bodies unchanged and make them private:
-- empty_indexed_list, append_entry, candidate_positions, find_position.
```

Entries remain source data; the index remains derived. Specialize owns both
the digest policy and transformations. Preserve its existing distinction:
record sealing reuses a stable index, while union sealing rebuilds its index
because its completed digest changes. Add a concise invariant comment at
those transformations. No new storage or public container API is needed.

**Tests.** Migrate the observable cases in `test_indexed_list.brp` and its
direct-table user in `test_instance_digest.brp` before removing the former.
Use ordinary Specialize inputs, not test-only production exports:

```blorp
record Box[T] { value: T }
pure func box[T](value: T) -> Box[T]:
    { value = value }
func main() -> Int:
    first = box(7)
    second = box("text")
    repeated = box(8)
    first.value
```

The two concrete `Box` layouts share the production origin/arity digest.
Assert their distinct field types and reuse of the integer layout. Cover a
missing key inside an occupied bucket, repeated pending requests, settlement
and references after record/union sealing. Mutate full-key comparison,
settlement and record index preservation separately to prove the oracles.

The forged dangling-index test becomes inaccessible by design. Record that
specific internal-diagnostic coverage loss; replace public-construction
coverage with a private-name import rejection. Do not claim the replacement
still tests malformed internal storage. Keep applicable full-key digest tests.
The rejection must import `IndexedList` from the actual production
`src/specialize/specialize` module through the normal loader. Register it in
the active `test/e2e/self_hosted_harness.brp` using its existing rejection
helper and pin the private-selection diagnostic/help/span. A synthetic module
declaring another private type would not test this boundary. Do not activate
the deferred namespace driver.

**Acceptance.** No external construction or public signature exposes the
container; no generic transformation escape hatch; same instance identities
and fixture C. Remove the old module/import and obsolete suite registration
only with the coverage mapping complete. Expected net production change:
approximately −20 to −25 lines, including the move.

## F3: publish complete admitted receiver scopes

**Current boundary.** `src/check/receiver_clashes.brp:240` computes
`visible_method` results and discards them. `src/check/callables.brp:268`
computes them again per receiver expression. However, the former enumerates
trait-method names only. Retaining that subset alone would leave a fallback
lookup path for ordinary functions.

Have the existing admission orchestrator return one complete scope per
module. Put the small shared types in `check/model.brp`, avoiding a new
callables-to-receiver_clashes dependency:

```blorp
record ReceiverFunction {
    id: FunctionId,
    import_site: Option[Span]
}
union ReceiverLookup:
    VisibleMethod(TraitMethodId)
    VisibleFunctions(List[ReceiverFunction])
record AdmittedReceiverScope {
    names: HashMaps.HashMap[Int, ReceiverLookup]
}
```

`VisibleFunctions` rows are nonempty. Store ids and import anchors, never
accepted declarations or source bodies. Accepted signatures remain the sole
contract authority; resolving an id to its accepted row is not name resolution.

Change `reject_receiver_clashes` into admission returning module scopes.
Construct in dependency order; publish scopes indexed by the existing module
numbering and select a body's scope once when constructing `ResolutionContext`.
Validate that every loaded module has exactly its own scope; do not assume
dependency order equals module-number order. Discard scopes when Check
publishes `CheckedProgram`.
An unfilled module scope is an invariant failure, never an empty-scope
default. An absent name inside a successfully admitted scope is a semantic
lookup miss.

The producer covers local/explicitly selected functions, zero-parameter
functions, qualifying receiver-function imports, qualifying trait providers,
and prelude inheritance. Reuse the existing name-collection and overlap
admission machinery rather than adding a parallel builder. Preserve current
family-conflict-before-overlap order **within each module**, import route
deduplication and the first qualifying import anchor.

At a call, an absent name means no method or receiver function. It must not
invoke `visible_method` or rebuild bindings. Keep the existing constructor
lookup solely to choose `ConstructorUFCS` versus `UnknownFunction`; that is
separate diagnostic classification. Keep call-site spans, arity, purity,
inference, receiver-type selection and implementation entailment at calls.
Overlap checks consume these same admitted candidates.

**Tests.** Port only needed cases from the receiver-clash, overlap, method
visibility/resolution and derived-visibility suites into active TestSuites.
Cover ordinary-only and missing names, constructor UFCS, zero-parameter arity,
duplicate import routes, private/public providers, prelude inheritance,
unused conflicts and overlaps, and repeated calls at different spans.
Positives assert selected identities; negatives pin message/help/note/span.
Temporarily misclassify an ordinary-only name and omit a conflict to prove
both consumer and admission oracles. Source review confirms calls cannot
fall back to visibility construction.

**Acceptance.** Complete scopes, unchanged diagnostics and targets, no retained
scope in the checked program. Early review must approve the name-domain and
diagnostic-order inventory before implementation. Estimated net production
growth: 60–140 lines; ceiling 150. Measure receiver-heavy checking as well as
whole compilation. Stop and simplify if retaining the complete domain costs
more than the gates below; do not introduce lazy misses or a general cache.

## F4: emit aggregates in verification's completion order

**Current boundary.** `src/verify/verify.brp:857` returns `Void` after graph
verification; `src/emit/emit.brp:692` walks the same graph again. Both walkers
follow inline records and unboxed unions, skip pointer-like child edges, and
include every catalogue row as a root. Their root/child stack ordering agrees.

Move the emitter's definition-reference concept to Verify and publish the
order in the existing seal:

```blorp
-- Catalogue indices into this exact verified program, not manufactured IDs.
union AggregateDefinition:
    RecordDefinition(Int)
    UnionDefinition(Int)

private record VerifiedContents {
    program: OwnershipProgram,
    aggregate_order: List[AggregateDefinition]
}
opaque type VerifiedProgram = VerifiedContents
```

`verify_layout_graph` returns the order, appending a row exactly when its
successful finish step marks it complete. Record completion remains after
its storage-summary check. Seal only after all function and entrypoint
verification succeeds. Retain `verified_contents` and add a read projection
for the order. Change private `aggregate_runtime_contents` to take
`VerifiedProgram` so callers cannot pair unrelated programs and orders.

Emit loops over this order with existing renderers. Delete its visit states,
worklist, dependency classification and traversal-only failures. Preserve
forward declarations/helper prototypes and renderer invariant checks.
Retain every Verify raw-IR/layout rejection independently of Own. Managed
records and boxed unions remain roots although edges *to* them do not recurse.

**Tests.** Add active Verify/Emit aggregate-order suites: empty catalogues,
independent roots, higher-index children, mixed record/union dependencies,
shared children, pointer-recursive graphs, and excluded managed/List/callable
edges. Include exact rejections for by-value cycles, unknown layouts and
invalid inline storage. Verify all catalogue rows appear exactly once and
definitions follow dependencies; inspect generated C for prototype order.
Port the bounded useful cases from deferred `test_recursive_aggregates.brp`.
Reverse recorded completion order and separately admit a cycle to prove the
positive/negative oracles.
Add the existing `test/e2e/fixtures/recursive/group.brp` and `kinds.brp` to
the active `self_hosted_harness.brp` selection. Their ordinary mains must
produce exactly `10\n` and `5\n`, respectively, in its normal/strict
ASan/UBSan modes. Independently establish their allocation expectations;
do not infer them from an unchecked candidate. This activates two bounded
native witnesses, not the deferred recursive-aggregate suite.

**Acceptance.** Frozen fixture C remains byte-identical, including definition
order. No emission graph walker or compatibility path remains. Only the order
and seal record survive Verify; visit vectors and function-verification state
do not. Expected production reduction: 80–130 lines; require net reduction.

## Shared validation and cost gates

Each milestone starts with its boundary tests. For semantics-preserving
refactors, the old implementation should pass behavior tests; do not invent a
failing source-text/count test. Use visibility rejection for F2's changed
boundary and the specified mutations for invariant protection.

Build once, run the smallest active suite selection while iterating, then one
final fixpoint gate, which includes the full active self-hosted component and
native selections under the self-built compiler. Example (substitute the actual
active suites for each milestone):

```sh
make -C blorp_2 test-compiler
make -C blorp_2 test-target-components \
  TARGET_COMPONENT_SOURCES='blorp_2/test/unit/test_check/test_declaration_bounds.brp'
scripts/blorp2-fixpoint --prove
```

Register new suites in `TARGET_COMPONENT_SOURCES`; deferred suites receive
no PASS credit. Before `--prove`, preserve any borrowed
`blorp_2/build/fixpoint/` artifacts: the script replaces them. Require its
actual self-built component/native gates, exact rejection diagnostics, strict
leaks and relevant aggregate native sanitizer checks. Do not run legacy tests
or substitute direct calls to generated internals.
`make -C blorp_2 test` remains available for failure triage; it is not another
mandatory broad gate immediately before the same checks in `--prove`.

Before coding each milestone, freeze baseline/candidate toolchain settings,
the pinned seed, source/library hashes and workloads. Retain separate normal
and diagnostic self-built binaries: retired instructions come from normal
runs; allocation/release counts from strict diagnostic runs. On macOS, a
normal sample has this ordinary CLI boundary:

```sh
/usr/bin/time -l "$normal_compiler" --library-root "$frozen_library" \
  "$frozen_source/src/main.brp" "$sample_directory/compiler.c"
BLORP_LEAK_CHECK=strict "$diagnostic_compiler" --library-root "$frozen_library" \
  "$frozen_source/src/main.brp" "$sample_directory/compiler.diag.c"
```

Link each normal/diagnostic pair from the same self-built compiler C, with
the same C toolchain and options except accounting configuration.
Use three serial normal samples per side, compare minima and retain every
sample. Compare baseline and candidate on the **same frozen compiler input**,
then also record each revision compiling its own source. Do not expect C from
different compiler source revisions to match. Require normal/diagnostic C
identity per input and cross-revision C identity for every common frozen
measured input, including compiler source, F3/F4 workloads and unchanged
fixtures. Reject performance comparisons with unexplained output differences.
F3 additionally measures a frozen receiver-heavy input; F4 uses mixed-layout
input through the ordinary compiler CLI. Direct phase tests establish the
targeted invariant; do not add profiling infrastructure solely for this plan.

Target no regressions. Preimplementation whole-compile ceilings are +1% each
for allocations and normal retired instructions, per milestone and against
the initial frozen baseline cumulatively. Repeat an apparent miss before
concluding it is real; investigate and rescope a repeatable miss rather than
silently changing limits. Existing stricter fixture limits remain unchanged.
Report production/test additions, deletions and net counts separately; F1
stays within +25 production lines, F2 is non-increasing, F3 within +150, F4
reduces production lines. Aim for net deletion across the plan; investigate
aggregate production growth over 100 lines. Necessary coverage is not cut or
compressed to meet a line target.

These are architecture cleanups, not promised speedups. Evidence belongs in
one current report under `benchmarks/results/`; raw runs stay under ignored
`build/architecture-facts/`. Retain original failures and identify unrelated
debt separately. Stop for a false premise, required extra mechanism, significant
regression or suspected compiler defect; report evidence and bounded options.

## Review, landing and handback

Every milestone needs an independent code-reviewer approval and test-runner
approval on the final diff, including the authority/lifetime trace, migrated
coverage, generated C where affected, matched costs and line counts. F3/F4
also need an early design review of their publication seam. No approval from
this plan substitutes for implementation review.

Return the commit/diff, source and binary provenance, exact gate results,
mutation evidence, C/diagnostic identity results, allocation/instruction
comparisons, production/test counts, and any explicitly lost or deferred
coverage. Land each complete slice as one squash commit; update this plan's
status with its implementation rather than standalone progress commits.
No bootstrap pin or release change is part of this work. Revert a failing
slice as a unit; do not retain both representations as a fallback.
