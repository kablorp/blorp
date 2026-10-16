# Discarded managed results acquire ordinary lexical owners

Status: **design approved by root and an independent compiler expert, including
the uniform non-Void rule, existing identity APIs and numerical ceilings.**
Implementation and compiled validation remain pending a separate TDD lane.
The rejected backend candidate remains parked for comparison and must not be
integrated.

## Problem and evidence

An ordinary non-final expression or wildcard assignment producing
`Option[String]` can lose its owned non-ASCII payload. Two FRESH host binaries,
899e0a92 and 390bdd0, agree on five failing and six passing scratch controls
with the same explicit standard library. The standalone natural-main fixture's
untouched generated C reports one 35-byte leak under ASan/UBSan and the runtime
leak checker. Named unused managed bindings release their payload correctly.

The two-file backend candidate is rejected: its expression classifier treats
If/Seq/Let/BorrowLet/Drop wrappers as owned based on result type alone. Mixed
borrowed/owned branches require different acquisitions. Neither recursive AND
nor OR can make one disposal boolean correct for both branches.

The following standalone reproductions and commands are sufficient to repeat
the failure without ignored artifacts. Original native C and logs remain
preserved under `build/host-discarded-option-leak/` as supplemental evidence.
These observations establish the leak, not the correctness of the proposed fix.

### Standalone reproductions

The first program discards an ordinary function's Option result as a non-final
expression. Its dynamic U+00E9 (é) String is valid two-byte UTF-8 and requires a
heap allocation; the proposed standard-library wrapper is unnecessary.

Save as `nonfinal.brp`:

```blorp
import:
	io: print
	memory:
		MemoryCounter(ManagedAllocations, ManagedReleases, LiveManagedObjects, MemoryStatsActive),
		read_memory_counter, reset_mem_stats
	string: from_char


func runtime_int(value: Int) -> Int:
	value


func make_option(value: Int) -> Option[String]:
	if value < 0:
		None
	else:
		Some(from_char(to_char(runtime_int(value))))


func main(args: List[String]) -> Int:
	reset_mem_stats()
	make_option(233)
	active = read_memory_counter(MemoryStatsActive)
	allocations = read_memory_counter(ManagedAllocations)
	releases = read_memory_counter(ManagedReleases)
	live = read_memory_counter(LiveManagedObjects)
	print("active=${active} allocations=${allocations} releases=${releases} live=${live}")
	if active == 1 and allocations > 0 and releases == allocations and live == 0:
		0
	else:
		1
```

The second program exercises wildcard disposal independently. Save as
`wildcard.brp`:

```blorp
import:
	io: print
	memory:
		MemoryCounter(ManagedAllocations, ManagedReleases, LiveManagedObjects, MemoryStatsActive),
		read_memory_counter, reset_mem_stats
	string: from_char


func runtime_int(value: Int) -> Int:
	value


func make_option(value: Int) -> Option[String]:
	if value < 0:
		None
	else:
		Some(from_char(to_char(runtime_int(value))))


func main(args: List[String]) -> Int:
	reset_mem_stats()
	_ = make_option(233)
	active = read_memory_counter(MemoryStatsActive)
	allocations = read_memory_counter(ManagedAllocations)
	releases = read_memory_counter(ManagedReleases)
	live = read_memory_counter(LiveManagedObjects)
	print("active=${active} allocations=${allocations} releases=${releases} live=${live}")
	if active == 1 and allocations > 0 and releases == allocations and live == 0:
		0
	else:
		1
```

The matching producer/disposal shapes have already failed on both recorded
hosts. These standalone listings are the reproducible specification; this
document-only revision has not executed them again.

### Existing-bin source-to-C and native leak commands

Set up a fresh directory, then save the two complete listings above there:

```sh
repro_dir=$(mktemp -d "${TMPDIR:-/tmp}/blorp-discard-owned.XXXXXX")
task_root=/Users/keithphilpott/.codex/worktrees/8d2a/blorp
host_root=/Users/keithphilpott/.codex/worktrees/blorp-2-compiler-comparison/blorp
expected_host_sha=899e0a92cfe1bc91f992bd3ccdd0755448903eb91d91780ac4870bd13d8cfa17
printf '%s\n' "$repro_dir"
```

After saving the files, run from the existing host's own cwd. Stop if build
status is not FRESH; do not rebuild or silently substitute another binary.
The frozen host's recorded SHA256 is
`899e0a92cfe1bc91f992bd3ccdd0755448903eb91d91780ac4870bd13d8cfa17`.

```sh
cd "$host_root"
repro_build_status=$(scripts/compiler-build-status) || exit 1
printf '%s\n' "$repro_build_status"
case "$repro_build_status" in
    FRESH:*) ;;
    *) exit 1 ;;
esac
actual_host_sha=$(shasum -a 256 bin/blorp) || exit 1
printf '%s\n' "$actual_host_sha"
test "${actual_host_sha%% *}" = "$expected_host_sha" || exit 1

for repro_name in nonfinal wildcard; do
    bin/blorp compile --no-format \
        --std-dir "$task_root/standard_library/src" \
        --dump-core-after=dce,perceus,final \
        --dump-core-file="$repro_dir/$repro_name.core.txt" \
        -o "$repro_dir/$repro_name.c" "$repro_dir/$repro_name.brp" || exit 1
    clang -std=gnu11 -O0 -g -DBLORP_MEMORY_DIAGNOSTICS=1 \
        -fsanitize=address,undefined -fno-omit-frame-pointer -pthread \
        "$repro_dir/$repro_name.c" -o "$repro_dir/$repro_name-sanitize" || exit 1
    if BLORP_LEAK_CHECK=1 "$repro_dir/$repro_name-sanitize" \
        > "$repro_dir/$repro_name.log" 2>&1; then
        repro_exit=0
    else
        repro_exit=$?
    fi
    cat "$repro_dir/$repro_name.log"
    test "$repro_exit" -eq 1 || exit 1
    rg -q '^active=1 allocations=1 releases=0 live=1$' "$repro_dir/$repro_name.log" || exit 1
    rg -q '^blorp: leak check: .* 1 leaked, 35 bytes$' "$repro_dir/$repro_name.log" || exit 1
done
```

Both existing-host cases must report snapshot
`active=1 allocations=1 releases=0 live=1`, exit 1, and one leaked String
payload (35 bytes on the recorded aarch64 host). Process-wide allocation totals
also include diagnostic printing and are not the one-payload oracle. No ASan
fault is required for this leak: the runtime leak report and exact counters
are the red. Preserve generated C without edits.

For the second existing host, repeat in a new repro directory with identical
source and explicit std directory, setting
`host_root=/Users/keithphilpott/CLionProjects/blorp` and
`expected_host_sha=390bdd0dd10d2f916c2d795462a278ed6bfa88b4c47928f9807ede748d331c7a`.
Verify FRESH status and its hash from that cwd before running. Keep outputs
separate. Neither binary hash is interchangeable evidence for the other.

Candidate acceptance reverses the oracle: snapshot
`active=1 allocations=1 releases=1 live=0`, exit 0 and zero leaked payloads.
The saved original C remains the red; candidate C is regenerated from the
unchanged Blorp inputs. Compiled commands await root's lane grant.

## Reconciled design

The independent compiler-expert review in chat
`01a145b6-3ee1-7130-b8e7-2c7fbf287433` recommends an explicit immutable managed
Let with a constant Void body, followed by the original continuation. I agree.
It gives the existing ownership engine a named owner and lets it emit a typed
Drop, rather than teaching emission another ownership inference algorithm.

My earlier alternative was to promote discarded results with the existing
assignment-result normalizer and then consume them at two backend sites.
That reuses existing alias logic, but still establishes an implicit disposal
contract across the Perceus/backend boundary and needs source-reuse fixes.
An explicit Let/Drop makes the producer and lifetime visible in existing Core,
so it is the preferred plan. The original C-layout fallback is unnecessary.

Before ownership processing:

```text
Seq(discarded_value, continuation)
    => Seq(Let(discard_owner, immutable, T, discarded_value, Void), continuation)

Assign(wildcard, discarded_value)
    => Let(discard_owner, immutable, T, discarded_value, Void)
```

Select every discarded non-Void result, including literals, without classifying
ownership here. Do not reuse the product-field literal skip or add another
filter. Perceus remains the sole managed/unmanaged authority: for a borrowed
managed value it supplies an independent reference using the existing
contract/alias normalizers. An unmanaged Let needs no retain or Drop. Extra
scalar and literal bindings are real work and must fit the cost ceilings.

The temporary's body is Void. Keep the continuation outside the Let so its
lifetime closes before the next operation, and balancing never scans an
ever-growing remaining block once for every synthetic binding. Never fabricate
a declaration `def_id` to enter the proven-unused-binding fast path.

## Identity and traversal placement

PerceusEnv has no threaded binder frontier. Its current helper derives
identities from locations and origins; `retain_alias_as_owned` already uses
PerceusOwnedResult ordinal zero. Reusing that pair or inventing a local name
counter is not acceptable, especially for nested/synthetic locations.

The existing pre-ownership evaluation normalizer already has the required
identity authority:

- `product_evaluation.brp` threads `ProductEvaluationTraversal.next_binder_id`
  across functions, globals, methods and children.
- `pipeline.brp:411` passes in `CorePassState.next_binder_id` and reserves the
  reported consumption with `core_reserve_binder_ids`.
- That pass runs immediately before standalone ownership contracts or fused
  ownership/Perceus. All Perceus body catalogs therefore see the new owners.

Extend that existing traversal instead of adding a separate whole-tree pass or
threading a new allocator through Perceus. A new discard owner takes the current
shared binder ID, decrements the same frontier, and carries an existing typed
pass origin. The fixed origin is `PassTemporary(PipelineTemp, 0)`. Use private
name prefix `$blorp$discarded_result$`, suffixed by the reserved shared binder
ID's decimal spelling, following the existing evaluation-binding convention.
For reserved ID -7, the display spelling is `$blorp$discarded_result$-7`.
That source-illegal name is unambiguous for existing name-indexed consumers;
the shared binder ID is the identity authority. No consumer inspects the
prefix or spelling to infer ownership. No local string counter, location-based
freshness, or new origin variant is introduced.

Do not build or carry a ManagedTypeIndex here. The earlier draft's extra
index/context and literal skip are withdrawn: Perceus already owns ownership
classification. Exact Void type alone selects this evaluation boundary. Add
no managed-type approximation, name filter, literal filter, or lazy cache.

At each existing Seq-spine item, normalize its children once through the current
evaluation traversal, then wrap that mapped non-Void result.
Use the returned frontier for the next item. For wildcard assignment, map its
RHS once and replace the mapped assignment with the same owner binding. Do not
re-enter the traversal on a newly wrapped RHS. The later Perceus pass then sees
the new Let before processing its RHS exactly as it sees a source binding.

This placement does not require the earlier proposed Perceus source-reuse
change: the normalized tree is already the ownership pass's original input.

### Exact fresh-node and binder checkpoint

There are two independent identity domains. An ordinary Let binds a CoreVar
using the shared binder frontier. Its newly introduced VoidExpr also needs a
genuinely fresh Core node ID; neither the RHS location nor a synthetic zero is
freshness. Let/Seq are structural wrappers with no own node-ID field, so do
not mint an extra node for either wrapper.

The existing allocator is
`pass_runner.core_mint_node_id(state, origin) -> (CorePassState, CoreSourceLoc)`
at pass_runner.brp:1195. Its input frontier is the incoming
`CorePassState.next_node_id`; it decrements that frontier and appends origin
to `CorePassState.minted_origins`. The returned CoreSourceLoc is a fresh
negative node ID. The allocator itself reserves that node: there is no separate
node-reservation API to invent or a binder reservation to substitute for it.

For each new discard body, the conceptual code is:

```blorp
origin = core_node_id_resolve_origin(core_expr_source_loc(rhs), current.minted_origins)
(minted, void_id) = core_mint_node_id(current, origin)
body = VoidExpr(VoidType, void_id)
```

The RHS's resolved location is only provenance. `void_id`, issued by the
allocator, is the identity placed in VoidExpr; it must differ from the RHS's
own node ID. Resolving an already-minted RHS origin avoids recording an
unresolved negative ID as its apparent source location. A synthetic input can
still have unknown/zero provenance, but its new Void identity is fresh and
negative. Input state must retain valid existing mint origins; do not reset
the allocator or fabricate missing provenance.

The owner variable takes the current
`ProductEvaluationTraversal.next_binder_id`, decrements the same shared binder
frontier, and uses the reviewed existing typed pass origin. Report the complete
number of consumed binder IDs, including current product/list/tensor bindings,
through existing `core_reserve_binder_ids(state, count)` at pass_runner.brp:1112.
Binder IDs and node IDs are separate domains; numeric equality across those
domains is harmless and must not be mistaken for an identity collision.

The current `(program, next_binder_id) -> ProductEvaluationResult` API cannot
preserve a node frontier or origins. Change the existing entry point to:

```blorp
normalize_product_evaluation(state: CorePassState) -> CorePassState
```

Thread the existing CorePassState as mint state through the private traversal
and declaration/function helpers, alongside their existing batched binder
frontier. Carry every result of core_mint_node_id to the next child/function.
Return its advanced next_node_id and minted_origins, update program, and apply
core_reserve_binder_ids for the actual binder delta. Existing
`tailrec.lower_tailrec_program(state)` / its private mint_state threading is
the precedent. No new allocator, ownership metadata, counter namespace or
string counter is needed.

Update `pipeline.run_product_evaluation_pass` to return that advanced state
directly. Do not reconstruct it with core_pass_state, which resets node IDs and
origins. Adapt the existing normalizer tests to seed/control a CorePassState;
do not keep the old production API as a compatibility wrapper. Existing
product binding helpers may keep their batched integer frontier internally;
they do not mint expression nodes. This is bounded plumbing in the evaluation
normalizer and its existing pipeline adapter; pass_runner's allocator API
itself is unchanged.

For N new discard bodies and B existing evaluation bindings, verify:

- next_node_id_out = next_node_id_in - N;
- minted_origins_out has its original prefix plus exactly N new entries;
- next_binder_id_out = next_binder_id_in - (N + B);
- all new Void node IDs are distinct, resolve to their intended origins, and
  differ from existing RHS own-node IDs; all new owner binder IDs are reserved.

Seed tests with a nonempty origin table and previously minted RHS nodes, then
include repeated/synthetic RHS locations and nested/shared-location wrappers.
Those inputs must still produce distinct Void IDs and owner IDs, without
revisiting or reevaluating the RHS. Keep all other pass state fields intact.
The existing +100 production / +320 test ceilings and cost caps apply to this
API/context plumbing; stop for review if it cannot fit them.

## Ownership authorities and wrappers

`plan_managed_let` and its binding-alias normalization own acquisition. Existing
call contracts distinguish ReturnOwned, ReturnBorrowed and ReturnAliasOfArg.
Existing normalizers handle borrowed leaves, local binding transfer, exact Dup
effects and mixed branches. Existing Let balancing owns the disposal Drop.
Backend Let/Drop emission consumes that explicit policy; no emitter classifier
or blanket type-based release is changed.

| Input result | Existing normalization obligation |
| --- | --- |
| Fresh Some/call/String | Transfer its owned reference into discard_owner, then drop once. |
| Borrowed parameter/field/getter | Acquire a separate unit for discard_owner; drop that unit and preserve the original owner. |
| Mixed If | Acquire in the borrowed arm only; both selected results supply one owner. |
| Let wrapper | Respect the inner local's owned transfer and any unrelated borrowed result. |
| BorrowLet wrapper | Preserve borrowing; retain the outgoing alias when it enters the outer owner. |
| Seq wrapper | Preserve evaluation order and exact preceding retain effects. |
| Drop wrapper | Preserve valid existing releases and the outgoing live result. Do not attempt to repair already-invalid use-after-drop Core. |
| Primitive or literal non-Void result | Introduce an ordinary Let; Perceus alone chooses ownership operations. |
| Void result | Leave the discard position unchanged. |

Borrowed-result acquisition may add a retain/release pair. The safety oracle
is preserved original owners plus balanced temporary obligations, not a blanket
ban on release operations. Zero-live-payload and actual-execution requirements
remain unchanged.

## Accepted pilot ceilings and pending final plan review

Root accepted these hard replacement ceilings for the internally reviewed
rescope, subject to actual results. Final root/document review and the plan-only
commit precede implementation; this is no permission to run compiled work.

- At most **+100 net handwritten production lines**, primarily the existing
  evaluation-normalization module. No backend, runtime or C-layout change.
  At most one additional existing production owner if identity plumbing proves
  necessary; no new index/context, pass/module/IR constructor or ownership metadata.
- At most **+320 net handwritten test lines** across existing evaluation/Core
  owners and the runtime-memory regression. Preserve all baseline coverage.
  Remove only this task's rejected-candidate C-layout assertions, which no
  longer describe the revised change. Do not compress formatting to meet caps.
- Matched unchanged-workload source-to-C allocations **<= +0.1%**, retired
  instructions **<= +0.5%**. Investigate repeatable owning-phase increases;
  reject or rescope an over-budget result. Compiler data-model/context changes
  require those matched measurements before acceptance.

Keep Blorp 2 source-constructor/argument lifting and String API wrapper work
independent. This host fix remains based on cd061c77f; do not import unrelated
working-tree changes from the primary checkout. No commits or integration are
authorized by this proposal.

## Required controls and acceptance

1. Original heap leak, inline Some, ordinary String/Option calls, and wildcard
   disposal execute and leave zero live payloads. Keep the standalone native C
   red; regenerate untouched candidate C for the green.
2. Parameters, projections and actual ReturnBorrowed/ReturnAliasOfArg getters
   remain usable after disposal in both positions. Inspect acquisition and
   typed Drop facts; test runtime behavior where source syntax reaches them.
3. Mixed If in both branch orders and both runtime selections: fresh arm
   disposes once, borrowed arm acquires/drops only its independent unit.
4. Let/BorrowLet/Seq/Drop wrappers preserve scope, alias lifetime and evaluation
   order; capture exact Core and generated-C evidence.
5. Synthetic/nested/shared-location fixtures prove distinct binder IDs,
   correct shared-frontier reservation, one RHS evaluation and one ownership
   visit. Unmanaged Lets have no retain/Drop; non-Void literals are bound and
   Void positions stay unchanged. New Void bodies have fresh minted node IDs
   with preserved provenance, independent of reserved owner binder IDs.
6. N16/32/64/128 discard sequences have constant-body disposal owners without
   growing continuation scans or duplicated ownership operations.
7. Mutations omitting the Drop, omitting borrowed acquisition, and duplicating
   disposal fail their specific oracles. Restore source and prove green.
8. Focused ownership/evaluation/emitter suites, compiler-check selected gates,
   relevant native sanitizer/leak/codegen/fixpoint checks and matched costs
   pass. Two independent code reviews plus root/test-runner validation precede
   any commit.

## Dependencies and stop conditions

First complete final root approval and second document review of this
self-contained plan, then the separately authorized plan-only commit. Root
will grant the TDD lane afterward. Replace the rejected candidate rather than
stacking it underneath the new design. The compiled lane remains separately
controlled by root; no build or test starts before it is granted.

Stop if the existing managed-binding path cannot normalize a wrapper case,
fresh identity needs new global metadata, ownership needs a duplicate
classification authority, source order/RHS visit counts change, or any cost/LOC
ceiling is exceeded. Return the concrete failing boundary rather than adding
an emitter fallback, library workaround or unchecked path.
