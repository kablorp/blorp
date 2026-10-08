# Record allocation and storage roadmap

Status: R1 is implemented, reviewed and validated. Shared
typed storage and main `87e312047` are reconciled; fresh focused, selected,
broad, sanitizer/probe and fixpoint gates pass, as do matched stage-2 cost
guards. Refreshed generated-C mapping review and final static checks also pass.
R2 is a separate unvalidated prototype; R3–R12 remain proposed. This roadmap
activates no source guarantee. Current behavior stays in
[Guide](GUIDE.md#fixed-records) and [record simplification](FIXED_LAYOUT_ROADMAP.md).

The goal is to remove record container allocations while reducing duplicated
compiler/runtime logic. Deliver complete vertical slices: each implementation
landing removes a demonstrated allocation and the production path it replaces.
Do not land a second record optimizer or a framework awaiting future consumers.

Read [Worker Checklist](WORKER_CHECKLIST.md), [Code Shape](CODE_STYLE.md) and
[Handoff Spec](HANDOFF_SPEC.md) before implementing. Recheck current source and
the immediate parent; paths below are owners, not frozen line numbers.

## Destination and decisions

The agreed destination policy is:

| Record | Placement |
| --- | --- |
| `fixed record` | No separate heap record container or heap transport box; check this constraint first. |
| Ordinary record with shallow payload size at most the inline limit | Inline in locals, calls, returns and enclosing storage. |
| Larger ordinary record used locally or through a supported borrow | Local fields/storage or caller-provided storage, without a separate heap container. |
| Larger ordinary record at a use requiring boxed storage | A managed container, preserving value semantics and ownership. |

Start the named ordinary inline limit at **128 bytes**. Measure its cost before
raising it. Size means target payload size including alignment, padding, nested
inline fields and managed-child handles; exclude an ARC box header and child
allocations. A function call or an owned value alone is not a boxing reason.

Children and enclosing objects allocate independently. A record inline inside
a List, union, closure or task occupies that owner's storage without another
record allocation. Managed fields need copy/move/drop even when the record has
no ARC header. Fixed-record storage does not impose the distinct payload
admissibility rules of [checked fixed unions](FIXED_UNION_ROADMAP.md#p5-activate-checked-fixed-unions).

Before policy activation, resolve these decisions with the owner:

- Recommend rejecting `same_object`, `is_unique` and `refcount` on automatically
  inline record types, extending today's inline-fixed diagnostic. Early
  optimizations preserve identity observations and child-object identity.
- Define finite recursive layouts through checked indirection. Reject an
  impossible fixed layout; a size threshold cannot break a recursive cycle.
- Specify borrowed native payload pointers and ownership transfer through
  explicit ABI authority. New foreign by-value aggregate syntax is not assumed.
- Bound large fixed layouts and frames, including collection element-width
  limits. Never satisfy a fixed constraint with a hidden heap fallback.

Until activation, improvements are placement optimizations under the current
source contract. They do not advertise a partial fixed or 128-byte guarantee.
Unsupported ordinary uses retain their existing storage through the same
checked placement analysis. Owned-inline admission requires complete layout,
ownership and producer/consumer contracts for every admitted crossing; an
unhandled crossing cannot reach byte-copy-only transport. Activation deletes
provisional policy gates and diagnoses unsupported fixed uses. Automatically
inline ordinary records also permit no silent boxes after activation: provide
supported inline/borrowed transport or a boundary diagnostic. Delay ordinary
policy activation if its crossings cannot meet that contract.

## Ownership and dependencies

This roadmap owns the record allocation policy and its implementation order.
[Product Unification](PRODUCT_UNIFICATION.md) owns common product operations
and group/multi-value machinery; this sequence refines its record optimization
work rather than creating another implementation. Historical whole-pilot
estimates and allocation percentages are not budgets for these slices.

The `codex/tuple-record-storage` worker owns checked product construction,
written-order evaluation, shared binder issuance, typed tuple storage and its
native migration. Its branch has committed the construction prerequisite and typed storage.
The record worktree consumes the accepted storage and cleanup commits,
`ce6e8156e` and `8f9fecfa3`. Its `docs/TUPLE_RECORD_STORAGE.md` puts
shared storage before scalar replacement. Local-only R1 can be developed against
committed construction without changing storage or call ABIs; integration
acceptance still validates the landed shared storage. Reconcile that version at R0.
Tuple syntax, storage migration and tuple-specific optimization are outside
this workstream. Extend the resulting shared machinery, coordinating any
common-file changes; do not edit or integrate the other worker's checkout.

[Union P4](FIXED_UNION_ROADMAP.md#p4-optimize-one-shared-union-representation-authority)
owns concrete union shape, tag/nullable/inline/boxed representation and active
payload ownership. Consume that authority for record payloads. Option and
Result are cases of the union work, not new private layout or cleanup paths.
Record work grants neither fixed-union payload eligibility nor a native ABI.
This dependency applies before R7 too: R4/R5 cannot admit inline fields whose
ownership needs a union's active-payload plan until that plan is available.

Share declaration identity, field ordinals, layout and ownership facts with
existing Core authorities. Keep payload layout, placement, owner existence and
call transfer distinct. Representation-sensitive admission follows concrete
specialization before collection and ownership consumers; group transformations
must precede ownership discovery/Perceus in the canonical pipeline. Prepare
callback value-versus-address contracts before rendering C. Extend shared
allocation reporting when a slice changes prepared allocation behavior;
[allocation contracts](ALLOCATION_CONTRACT_ROADMAP.md) remain a separate owner.

## Delivery and measurement contract

R0 is preparation; R12 is policy/release acceptance. Neither pretends to be an
allocation optimization. R1–R11 are independently reviewable implementation
slices. Split a row further if it needs several unrelated producer/consumer
changes; every resulting optimization landing keeps both acceptance columns.

For every implementation landing:

1. Freeze an input and refresh its baseline on the immediate parent. Retain
   exact commands, source/compiler/runtime hashes, toolchain and raw results.
2. Show fewer total allocations on the named workload, balanced child lifetime
   counts and no added boxes on preserved source-to-sink controls. Attribute
   container, transport, child and enclosing-owner allocations separately.
3. Record added/deleted/net production LOC separately from tests/docs/tools,
   and name the deleted adapter, traversal or duplicate decision. Default to
   non-increasing production LOC. If a required capability still grows code,
   combine its first consumer and deletion where bounded; otherwise stop for
   review with the exact growth and remaining simplification. No promised later
   deletion establishes an incremental complexity reduction.
4. Use matched stage-2 O2 builds for compiler costs. Follow the harness's current
   instruction sampling/noise rules; define the acceptance budget before the
   candidate run. Require non-regressing instructions and memory on the affected
   workload plus small-program/self-compile controls. Tiny-program allocation
   wins do not establish compiler-wide savings.
5. Review generated C and ownership, run owning gates and fixpoint, and update
   this status/evidence before starting the dependent slice.

The [retained scalar probes](../benchmarks/results/record_scalar_preparation_2026-10-07.md)
observed at N=256/512: local/alias/branch/call-result allocations N; managed-child
N+1; fresh mutable assignments N+1; unique updates 1; inline control 0. Targets
below are acceptance predictions to verify, not achieved results. Refresh after
prerequisites land. Maker census counts describe executed constructors, not
removable allocations or authored call-site reach.

The [recursive managed-result baseline](../benchmarks/results/record_recursive_results_2026-10-07.md)
shows existing reuse already removes intermediate wrappers: shared-child results
allocate N+1 objects, and discarded fresh-child results allocate 2N+1. R2 must
remove the remaining N containers while preserving child allocations and the
mixed-root identity control. The existing local-group use walk now lives in
`product_group_uses.brp`, with its lazy cache retained by the local pass. This
preparatory extraction adds 31 net production lines; it does not implement
result transport or claim an allocation or complexity reduction. Executable
result transport consumes the committed typed-storage interface after R1
integration acceptance; later obsolete-code cleanup and bootstrap rotation
are not prerequisites.

## Incremental sequence

| Slice | Allocation acceptance on its workload | Simplification delivered with the win |
| --- | --- | --- |
| R1. Immutable local groups | Local/alias record containers N → 0; managed-child total N+1 → 1. | Generalize the existing group admission, field lookup and projection handling; remove replaced tuple-only local branches. |
| R2. Branch and producer results | Branch and direct producer-result containers N → 0. | One checked product producer/result expansion replaces family-specific reconstruction and call expansion. |
| R3. Mutable local groups | Fresh reassignment total N+1 → 0 for the scalar probe. | Group assignment replaces whole-record build/drop/install sequences and duplicate mutable expansion. |
| R4. Typed function-value transport | Plain inline argument/result call boxes 2N → 0, excluding closure creation. | Typed signatures replace migrated aggregate StructBox/StructUnbox call adapters. |
| R5. Owned inline records and List storage | Accepted fresh records in a list lose N record containers; list/child setup remains. | One aggregate ownership plan replaces scalar-inline versus pointer-only copy/drop decisions. |
| R6. Vector and tensor storage | Accepted aggregate elements lose their former per-element record/transport boxes. | Reuse element operations; delete replaced aggregate slot/callback branches per container. |
| R7. Union payload integration | Remove additional record payload boxes at admitted union crossings. | Union shape supplies payload storage/cleanup; delete replaced record-specific boxing and duplicate active-payload decisions. |
| R8. Hash containers | Inline keys/values lose per-entry record boxes; inline lookup probes lose temporary boxes. | Shared typed slot/probe contracts replace migrated erased aggregate adapters. |
| R9. Channels | Admitted messages lose N record/transport boxes; channel storage remains. | Typed owned slots replace record-message boxing/unboxing branches. |
| R10. Task captures and results | Admitted task crossings lose record capture/result boxes; task/fiber allocation remains. | Reuse call/storage ownership plans; delete migrated task-specific aggregate adapters. |
| R11. Native borrowing and adapters | Supported borrowed aggregate boundaries lose their record transport boxes. | Prepared typed adapters replace emission-time record boxing for migrated ABIs. |

### R0. Refresh prerequisites and select the first win

Integrate current main in the implementation worktree and consume the storage
worker's landed APIs. Refresh scalar probes and the constructor census. Audit
identity observations, real authored sites, provisional code to remove, target
layout availability and union P4 status. Retain the audit; write no new optimizer.

The first real compiler case is the projected local resolve context in
`stage_09_core/resolve.brp`; producer-result candidates include mono-data rewrite
wrappers and map state. Their maker totals do not prove each site's dynamic
reach. If R1 lacks a shared group boundary, coordinate its generalization with
the product owner rather than starting a standalone record pass.

### R1. Immutable local records

Extend existing `tuple_flatten` group-source/use facts through the authoritative
product view and checked builds. Start with literal locals and immutable aliases
used only through fields. Preserve evaluation order, complete binder identity,
borrowed-field lifetimes and child identity. Whole storage, call, capture and
root-identity uses remain boxed. Prove the real resolve-context case as well as
the retained scalar/managed-child probes. No source-type representation policy
changes. Fail closed on unresolved fields or ownership.

Local implementation evidence is in the
[R1 report](../benchmarks/results/record_local_groups_2026-10-07.md).
The refreshed receipt compares accepted storage plus main `87e312047`
(`ce72f2a46`) with R1 plus the same dependencies (`3d42ce5c8`), compiling frozen
input `8f9fecfa3` with matched stage-2 O2 pairs. Self-compile allocations fall
285,949,331 → 284,188,419 (−1,760,912); both self and five-sample small controls
pass the predefined ≤1% instruction/RSS growth guards. The retained probes keep
local/alias containers at zero and the shared-child total at one; all 24 normal
and 24 sanitizer rows balance releases with zero live deltas.

The storage reconciliation preserves one checked schema issuer: generated row
fields come from the accepted catalog/layout authority, while logical tuple
admission remains separate from physical product classification. Fresh gates
pass 137 focused tests, 7,155 selected checks and 16,840 broad compiler/discovery/
parity/runtime tests; stages 1–3 emit identical C. The four production files add
542 lines and remove 371, net +171. This is a reviewed bounded capability
exception, not a LOC reduction or a credit against later deletions. Refreshed
C mapping review and final static checks pass. Fresh review explains the 18
resolver bodies and confirms unchanged declarations and storage; earlier cost
tables and C symbols remain historical. The receipt records the integration
checkpoint before publication.

### R2. Branches and direct producer results

Validate direct named producers first (R2a), including branches inside their
result paths. Then extend local branch-result groups (R2b) through the existing
group boundary. Local branch probes remain boxed until R2b is accepted.

A separate direct-result prototype is unvalidated
and requires its own capability-exception review, behavior/ownership gates and
matched measurements before acceptance. R1's passing receipt does not validate
R2. Neither implementation activates Option/Result-specific handling or the 128-byte
representation policy.

Extend the shared producer analysis and named-call parameter/result transport,
with ordered field owners and a checked call-graph result. Handle branch-built
records and known returned wrappers. Include mutual recursion, mixed fresh versus
existing-box results, early exits and a caller storing the result whole. Preserve
existing boxes when forwarding a source; count any reconstruction at sinks.
Keep indirect/native boundaries explicit. Do not guess eligibility from a
function name or syntactic literal. If only a bounded producer expansion is
available, state that limit instead of claiming general multi-value calls.

### R3. Mutable and loop-carried records

Use the same groups and control-flow/binder authorities. Evaluate replacements
into owners before installing fields, preserving old-value reads, snapshots and
aliases. Cover managed-child reassignment, branches, break/continue, propagation,
cancellation and tail-recursion transfers. Existing unique update reuse must not
regress. Do not add another fresh-record reuse matcher as a substitute for this
shared value model. Identity controls retain source boxes until R12's decision.

### R4. Calls through function values

Replace aggregate argument/result erased transport with typed signatures or
caller-provided storage, including function references and closure adapters.
First remove the existing two-box plain-inline call case. Use checked transfer
contracts for managed fields; generic callbacks and native callbacks keep their
explicit boundaries until migrated. The same function signature must agree at
every call. A closure environment allocation is separate from its captured record
storage. Pair schema work with the first deleted call adapter; no ABI-only landing.

### R5. Owned inline values through Lists

Deliver one complete owned-inline record slice: locals, nested fields, typed
List slots, field access and cancellation. Extend common field metadata and
copy/move/drop plans; `InlineRecordType` must no longer imply ownership-free.
Validate all crossings of the admitted concrete placement before selecting it;
other ordinary uses retain current storage. Do not silently route managed
children through today's byte-copy-only `blorp_box_struct`.
One concrete function signature cannot alternate between boxed and inline ABI.
Use a consistent checked signature, or explicit checked conversions between a
local placement and existing boxed transport. Count those conversions in the
slice's net allocation oracle; they are not exemptions to the final policy.

Test one and two dynamically allocated children, repeated children, temporary
projections, partial initialization, shared-list COW, unique growth, replacement
and destruction. Moving bytes transfers owners; copying bytes alone does not.
Use typed element operations for native producers/consumers as well as emitted
constructors. Include the current narrow element-size metadata in the layout
check. No source-wide fixed guarantee is activated here.
Bind field cleanup and cancellation actions to the exact prepared program,
including partial owners and backend-created temporaries. Missing or unsupported
actions fail through the shared diagnostic path on every emission entry.

### R6. Vectors and tensors, one container at a time

Extend the proven element contract to Vector, then Tensor; land separately if
their native boundaries differ. Cover construction, fill, slicing, views,
replacement, collection conversions, fusion, COW and parallel callbacks that
actually accept the record element type. Preserve dimension/rank and packed/raw
storage rules. Unsupported element kinds are not newly admitted. Reuse R4's
callback transport and R5's owner operations instead of duplicating them.

### R7. Records in generalized union shapes

Depend on the union owner's validated shape and active-payload plan. Exercise
payload-free, one-record, multi-field and nested variants, with scalar and
managed children. Preserve nullable/niche distinctions and existing sum semantics;
record size must not choose a union encoding. Only active fields acquire owners
and cleanup. Remove the extra record box, not necessarily the enclosing union
allocation. Test custom unions alongside Option/Result so names cannot select
the new behavior. If P4 is incomplete, leave this slice pending rather than
implementing a private Option/Result path. Record remaining union work there.

### R8. Dict and Set entries and probes

Migrate each hash-container interface through typed slot size/alignment and
copy/move/drop/hash/equality contracts. Include lookup keys, replacement,
rehashing, removal, iteration, COW and conversions to lists. Borrowed probes need
no owning record box. Equality/hash operate on fields, never padding bytes or
storage addresses. Preserve separate native callback authority while sharing
aggregate operations. Count entry and lookup wins independently.

### R9. Channel messages

Add typed owned message slots and transfer rules for send/receive/select,
buffer growth, sealing, failed sends, blocked operations and cancellation.
Borrowed sends acquire child ownership before suspension; receives transfer or
copy according to the existing channel contract. Drop all abandoned messages
once. Empty channel creation and synchronization costs remain counted separately.

### R10. Tasks and captures

Migrate task entry, capture and result storage through the same aggregate
transport and ownership plans. Cover structured join, detach, cancellation,
repeated result reads and destruction of results that are never read. Captured
values preserve value semantics; managed children keep atomic ARC. Do not count
task/fiber allocations as record regressions or hide them as record savings.

### R11. Explicit native boundaries

Audit runtime helpers, foreign declarations, callbacks and native snapshots as
producer/consumer pairs. Migrate a supported borrowed payload contract with an
actual removed transport box. An address must not outlive its storage; native
ownership transfer cannot masquerade as borrowing. Keep declared ABI selection
explicit and validate prepared adapters on both split/single-unit emission.
Unsupported fixed foreign uses diagnose at R12. A new C by-value aggregate ABI
is separate work, not required to accept an incompatible native signature.
Automatically inline ordinary records have the same no-transport-box rule after
activation; an incompatible native crossing must diagnose or delay activation.

The pinned bootstrap may require old runtime entry points. Retain only that
named dependency until release validation and pin rotation permit deletion;
ordinary new code must not select the legacy path. Track its exact retirement.

### R12. Activate and verify the source policy

Activate the fixed constraint first and ordinary shallow-size policy second.
Resolve identity semantics, migrate affected compiler/standard-library sources,
and delete provisional admission gates, fixed managed fallbacks and forbidden
record transport-box branches, including fallback boxes for automatically inline
ordinary records. Verify all accepted crossings against the same checked plan;
an unknown backend/helper crossing cannot certify either guarantee. Larger
records use the shared local/call analysis;
remaining boxed sinks are explicit facts, not a catch-all for function arguments.

Fixed declarations with invalid layouts reject even if unused. Generic
constraints validate symbolically where possible and concretely when required;
unproved instantiations cannot claim the guarantee. Unsupported fixed placements
name the boundary and suggest ordinary storage or a supported interface. Decide
check/LSP integration through the shared validation service; frontend-only
success is not proof of a layout obligation. Cover module checking without main,
unused declarations, stop/dump paths and late-generated types.

Update Guide, Grammar, memory/ownership documentation and all affected examples
with activation. Verify below/at/above-limit layouts, alignment, empty/nested and
generic records, cross-module identity, large fixed frames and recursive cases.
Accepted fixed values have zero record root/transport boxes at every supported
placement. Enclosing-owner and child allocations remain independent. Final
production LOC must be below the refreshed R0 baseline, with one common product
storage/ownership implementation and no duplicate record optimizer. Report the
policy checkpoint separately from the preceding measured optimization wins.

## Feedback, gates and handback

Begin each slice with a failing allocation/value/ownership regression at its
boundary and an exact diagnostic expectation for rejection paths. Use scalar
counter endpoints outside formatting/setup; releases count deallocations, not
all ARC operations. Add retain/drop and cancellation evidence where needed.

```bash
scripts/compiler-check --changed --plan
BLORP_CLI_C_OPTIMIZATION=-O2 make
scripts/compiler-build-status
benchmarks/record_scalar_prepare --output /tmp/record-scalar.json
benchmarks/record_scalar_prepare --sanitize --output /tmp/record-scalar-sanitize.json
```

Extend that runner as oracles change; its current identity control intentionally
requires boxes. Run the owning Core/runtime suites first. Compiler implementation
and diagnostic fixtures belong in `blorp/test/test_compiler/` and its ownership
manifest; runtime cases belong in `blorp/test/test_runtime/`. Then select broader
gates proportionate to the slice:

```bash
make hygiene-check
scripts/compiler-check --changed --base origin/main
scripts/test --no-build --serial compiler-blorp compiler-new compiler-new-parity
scripts/test --no-build --serial compiler-core-sanitize leak runtime
scripts/compiler-fixpoint
```

Inspect generated C and run the codegen audit through its owning selector.
Concurrency/native changes add their focused gates; CLI/LSP changes add those
gates. Use fresh tools, `--no-format` on compile/run/check, serial compiled
workloads and matched stage-2 measurements from Worker Checklist. Normal and
diagnostic compilers agree within each measurement pair; intentional codegen
changes use behavioral review and stage-2/3 fixpoint rather than parent/candidate
C identity. Do not end while a build/gate runs. No Docker gate, publication or
bootstrap rotation is requested by this roadmap.

Get code-reviewer and test-runner review for every landing. Hand back: scope,
commit, before/after counts, instructions/memory, added/deleted production LOC,
deleted paths, generated-C differences, gate results and remaining boundaries.
Stop if allocation merely moves to an adapter, source boxes are rebuilt,
ownership/cancellation becomes ambiguous, a second authority is needed, or the
measured benefit cannot justify remaining complexity. Retain negative evidence
and revise the next slice instead of treating a missed budget as completion.
