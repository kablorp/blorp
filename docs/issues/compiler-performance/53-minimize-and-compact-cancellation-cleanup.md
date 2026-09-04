# Emit Cancellation Cleanup Only Across Cancellable Regions And Compact Its C Representation

**Status:** Proposed

## Objective

Make generated cancellation cleanup proportional to values that are actually
live across a possible task-cancellation point, then represent the remaining
protection with one compact function/scope-level cleanup structure instead of
one linked frame and C cleanup guard per managed value.

The change must preserve deterministic ARC, cancellation safety, structured
concurrency, task/resource cleanup order, and every current leak baseline. It
must not remove cooperative checkpoints or use purity as a proxy for whether an
operation can cancel.

## Current problem

The backend currently protects most immutable managed `let` bindings for their
entire body. `let_tracks_cleanup` in
`blorp/src/compiler/stage_10_backend/emit.brp` checks the release policy and
whether the body takes ownership, but not whether any intervening expression
can cancel:

```blorp
private pure func let_tracks_cleanup(
	cleanup_policy: CoreReleasePolicy,
	body: CoreExpr,
	variable: CoreVar,
) -> Bool:
	(
		release_policy_requires_cleanup(cleanup_policy)
		and not let_body_takes_cleanup_ownership(body, variable)
	)
```

Each protected value expands to a full linked frame, one GCC/Clang cleanup
guard, registration, and later lookup-based pop:

```c
blorp_String* value = ...;
blorp_CancelCleanupFrame __blorp_cleanup_value;
BLORP_TASK_CLEANUP_SCOPE(__blorp_cleanup_value);
blorp_task_cleanup_push(
    &__blorp_cleanup_value,
    &value,
    (void*)value,
    blorp_cleanup_release_arc_value
);
/* body */
blorp_task_cleanup_pop_slot(&value);
blorp_release(value);
```

The current runtime representation in
`blorp/src/lib/runtime/native/runtime_decl.c` stores seven fields per protected
value:

```c
typedef struct blorp_CancelCleanupFrame {
    struct blorp_CancelCleanupFrame* prev;
    const void* slot;
    void* value;
    blorp_CancelCleanupFn release_value;
    long release_count;
    blorp_CancelCleanupKind kind;
    bool active;
} blorp_CancelCleanupFrame;
```

This is correct but extremely verbose in emitted C. At self-host revision
`3d8ec393b04d`, excluding the embedded runtime body:

| Generated-C construct | Occurrences |
| --- | ---: |
| `blorp_CancelCleanupFrame __blorp_*cleanup_*` declarations | 48,212 |
| `BLORP_TASK_CLEANUP_SCOPE(...)` | 48,221 |
| `blorp_task_cleanup_push(...)` | 48,218 |
| `blorp_task_cleanup_pop_slot(...)` | 89,960 |
| `blorp_task_cleanup_duplicate_slot(...)` | 48,069 |

Those five forms alone occupy approximately 282,680 generated source lines,
about 20% of the 1,416,117-line self-host translation unit. They also enlarge
the compiler's largest pattern-generated functions, which repeat the same
cleanup scaffolding along duplicated branches.

Refresh these counts against the direct parent revision before implementation.
Issue 52's match-continuation sharing may remove duplicated branches first, so
the percentage acceptance target below applies to that refreshed baseline;
the `3d8ec393b04d` figures remain the historical point of reference.

Some existing code already recognizes narrow non-suspending transfer prefixes
through `transfer_prefix_is_non_suspending`, but `UserCall`, closure calls,
foreign calls, and many aggregates conservatively return false. This local
predicate is not a complete interprocedural cancellation model and cannot
answer which owner is live at which cancellation point.

## Required architecture

Implement this in two independently measurable slices. Slice A removes
unnecessary protection. Slice B compacts the protection that remains. Do not
combine them into one unreviewable emitter rewrite.

### Slice A: explicit cancellation effects plus owner liveness

Create `blorp/src/compiler/stage_10_backend/cancellation_plan.brp` as the first
Stage 10 planning step. It consumes the final prepared Core program after
`compiler_core_prepare` and prepared-union reuse, and runs before C-symbol
projection/emission. Its output is the sole cleanup plan consumed by
`emit.brp`; the emitter must not independently rediscover cancellation or
ownership liveness.

This is a late-Core analysis: cooperative fairness checkpoints have already
been inserted and callable identities are exact. The minimum effect lattice is
explicit, not boolean folklore:

```blorp
union CoreCancellationEffect:
	CannotCancel
	MayCancel

record CoreCallableCancellationSummary {
	identity: CoreDefinitionIdentity,
	effect: CoreCancellationEffect
}
```

Compute user-call summaries as a fixed point over exact callable identity. A
callable is `MayCancel` when its reachable body contains any of:

- `CooperativeCheckpointExpr`;
- a builtin/direct-runtime operation explicitly classified as cancellable or
  blocking (channel send/receive/select, sleep/timer waits, task join/window
  operations, relevant stream/network waits, and future registered operations);
- a call to another `MayCancel` user callable;
- a closure/unknown/deferred call whose exact target and effect are not proven;
  or
- a foreign call not explicitly registered as `CannotCancel` under its ABI.

Recursive strongly connected components reach `MayCancel` if any member or
outgoing edge may cancel. Unknown cases default to `MayCancel`. Purity,
function spelling, source module, and C symbol prefixes are not evidence of
`CannotCancel`.

Use one named builtin/runtime effect registry beside the existing exact
`CoreCallKind` classification. The registry must be exhaustive under a test:
adding a new builtin/direct runtime call kind must require assigning an effect
or inherit the documented conservative `MayCancel` default.

Then compute a `CancellationProtectionPlan` per function from exact
`CoreVar`/temporary identity and control flow:

```blorp
opaque type CancellationSlotId = Int

union CancellationProtectionEvent:
	TrackCancellationOwner(CancellationSlotId, CoreVar, CoreReleasePolicy)
	DuplicateCancellationOwner(CancellationSlotId)
	UntrackCancellationOwner(CancellationSlotId)

record CancellationProtectionPlan {
	max_live_slots: Int,
	events_by_site: List[CancellationProtectionSite]
}
```

A managed owner needs protection only from the point at which it becomes live
until the first event on that path that consumes, returns, transfers, or drops
it, and only if that interval contains a `MayCancel` expression. Examples:

```blorp
-- No protection: no cancellation point while `label` is live.
label: String = make_label()
size: Int = label.length()
size

-- Protection required across `sleep`.
label: String = make_label()
sleep(10)
label.length()

-- Protection may be needed while evaluating later arguments and the callee.
consume_or_borrow(make_first(), evaluate_second_then_wait())
```

Respect left-to-right evaluation. An earlier owned call argument is protected
while a later argument is evaluated only when that later evaluation may
cancel. A borrowed argument remains protected through a `MayCancel` callee. A
consumed argument is unregistered immediately before the exact ownership
handoff, never after it. Branch joins use the conservative union of reachable
live owners; loops require a fixed point or structured equivalent.

That untrack is legal only under an explicit `CalleeOwnsAtEntry` handoff. For a
user callable, the callee's protection plan must track an owned parameter in
its generated prologue before any checkpoint, blocking operation, argument
evaluation, or `MayCancel` call can run. It may omit the track only when the
parameter is consumed/dropped before its first possible cancellation. For a
native/runtime consumer, its ABI entry must synchronously install equivalent
internal ownership protection before its first cancellation point. Otherwise
the caller must remain responsible across the call. Encode this distinction in
the call/ownership registry; do not infer it from a `consumed_args` bit alone.

Keep this plan out of ad hoc C strings. Either add a phase-owned prepared Core
form or a Stage 10 planning product keyed by explicit expression/site IDs.

### Slice B: one compact cleanup scope per function activation

Replace the per-value linked-frame ABI with one stack-resident scope per
generated function activation (or a smaller explicitly delimited scope only
when needed). One possible ABI is:

```c
typedef struct {
    const void* slot;
    void* value;
    blorp_CancelCleanupFn release_value;
    long release_count;
    unsigned long order;
    blorp_CancelCleanupKind kind;
    bool active;
} blorp_CancelCleanupEntry;

typedef struct blorp_CancelCleanupScope {
    struct blorp_CancelCleanupScope* prev;
    blorp_CancelCleanupEntry* entries;
    long capacity;
    unsigned long next_order;
    bool active;
} blorp_CancelCleanupScope;
```

Illustrative generated C:

```c
blorp_CancelCleanupEntry __cleanup_entries[3];
blorp_CancelCleanupScope __cleanup;
BLORP_TASK_CLEANUP_SCOPE_INIT(__cleanup, __cleanup_entries, 3);

blorp_String* value = ...;
blorp_task_cleanup_track(
    &__cleanup, 0, &value, value, blorp_cleanup_release_arc_value
);
/* cancellable region */
blorp_task_cleanup_untrack(&__cleanup, 0);
blorp_release(value);
```

The exact runtime shape may differ, but it must provide:

- one link/guard per active generated function/scope, not per owner;
- deterministic compiler-assigned slot IDs;
- a compile-time known capacity equal to maximum simultaneously protected
  entries when possible;
- exact `release_count` semantics for `DupExpr`/`DropExpr` balance;
- task, task-window, resource, stack-result, ordinary ARC, and ARC-only cleanup
  kinds;
- LIFO cleanup by registration time, including a slot that is reused later;
- safe arbitrary untracking where current ownership transfer requires it;
- nested call/scope ordering equivalent to the current linked frames; and
- one normal-exit unlink that works for every C return path.

If a function has no protection events, emit no cleanup scope. If it has one,
the compact form is still preferred so generated policy is uniform. Do not use
a heap allocation for fixed-capacity cleanup metadata.

The runtime cancellation drain must operate on the new scope representation
directly. Do not retain a shadow linked frame per entry, which would preserve
the code and stack-size problem behind a wrapper.

## Implementation guidance

1. **Freeze a controlled baseline.** Add scripts or test helpers that count
   cleanup declarations/operations in generated program C with
   `--no-embed-runtime`. Record the current self-host counts above, a tiny
   cancellation-free fixture, and a fixture with an owner spanning a channel
   wait.
2. **Add failing effect-summary tests.** Add
   `blorp/test/compiler/stage_10_backend/test_cancellation_plan.brp`. Cover a
   direct checkpoint, direct blocking runtime call, a two-hop user call, a
   recursive SCC, a known-safe leaf, and unknown/closure/foreign conservative
   cases. Keep `test_core_fairness.brp` as the focused proof that checkpoints
   exist before the planner runs.
3. **Add failing plan tests before emitter changes.** Assert exact track,
   duplicate, and untrack site IDs for straight-line, branch, loop, returned,
   consumed, borrowed, and multi-argument evaluation cases. Test `CoreVar`
   identity collisions with equal spellings. Include a `CalleeOwnsAtEntry`
   user function whose first body operation can cancel and require parameter
   tracking to precede it. Include a consuming runtime call with the same
   handoff contract.
4. **Thread summaries through an explicit environment.** Compute callable
   summaries once per program. Do not rescan callee bodies from each call or
   from each local binding.
5. **Replace body rescans.** Cut over
   `body_consumes_var_before_suspension`, `let_body_takes_cleanup_ownership`,
   `body_consumes_var`, `call_arg_needs_cleanup`, and the narrow transfer-prefix
   logic only as their behavior is represented in the new plan. Delete each
   obsolete scan when its last consumer moves; do not leave two authorities.
6. **Emit Slice A using the existing runtime ABI first.** This isolates effect
   and liveness correctness from runtime layout. Measure the reduction and run
   all cancellation/leak regressions before compacting frames.
7. **Implement the scope ABI test-first in the runtime.** Unit-test activation,
   duplicate, arbitrary untrack, slot reuse, LIFO drain, nested scopes, and all
   cleanup kinds. Preserve fast no-current-task branches.
8. **Cut the emitter over to scope slots.** Precompute `max_live_slots`, emit one
   scope declaration/guard, and map plan events mechanically to runtime calls.
   Never search by source/C name when a slot ID is available.
9. **Remove the old ABI and codegen.** Delete per-value frame emitters and old
   slow functions after every caller is migrated. Do not ship both paths.
10. **Re-run the historical cancellation leak corpus under leak-check and
    sanitizers.** The nested worker-group/channel cancellation regression is a
    required blocker, not an optional broad test.

## Correctness requirements

- Cancellation can occur only at explicitly classified Core/runtime points;
  the analysis must conservatively classify uncertainty as `MayCancel`.
- Every managed owner live across such a point is registered exactly once plus
  its explicit duplicate count.
- No owner already consumed, returned, or dropped is registered when control
  transfers.
- Every caller-to-callee untrack has one explicit ownership handoff. A user
  callee protects an accepted owner before its first possible cancellation; a
  runtime callee either does the same internally or leaves protection with the
  caller.
- Normal completion performs exactly the same releases and COW-relevant ARC
  operations as before.
- Cancellation releases every still-owned value exactly once and in the same
  observable resource order as before.
- Nested worker groups, fixed joins, channels, select, sleep, streams, TCP/UDP,
  task windows, stack results, and resource scopes remain safe.
- A callee cannot inherit a pointer to a caller cleanup scope after that caller
  returns.
- Stack slots remain valid until runtime cancellation drain has finished using
  them.
- Recursion allocates independent scopes per activation.
- Non-task execution retains the cheap no-op behavior and never drains a scope.
- The implementation remains portable across supported Clang/GCC CI lanes.
- No fairness checkpoint is removed or delayed by this issue.

## Tests to add or extend

### Compiler analysis and emission

Use:

- `blorp/test/compiler/stage_09_core/test_core_fairness.brp`;
- `blorp/test/compiler/stage_10_backend/test_cancellation_plan.brp`;
- `blorp/test/compiler/stage_10_backend/test_core_emit.brp`; and
- generated-C audit fixtures under
  `blorp/test/compiler/pipeline/codegen_audit/should_pass/`.

Required generated-C shapes:

- managed local with no reachable `MayCancel`: no cleanup declaration or call;
- owner spanning one checkpoint: one scope slot active across that checkpoint;
- owner consumed before checkpoint: untracked before handoff;
- owner created after last checkpoint: no tracking;
- two owners with disjoint cancellable lifetimes: reuse capacity one safely;
- two simultaneously live owners: capacity two;
- earlier call argument spanning cancellable later argument evaluation;
- borrowed versus consumed `MayCancel` call arguments;
- consumed user/runtime arguments that cancel immediately after entry, proving
  there is no gap between caller untrack and callee protection;
- branch and loop joins; and
- stack-result, ARC-only, resource, task, and task-window cleanup kinds.

### Runtime and ownership regressions

At minimum run and, where needed, extend:

- `blorp/test/runtime/concurrency/test_cancellation.brp`;
- `blorp/test/runtime/memory/leak_check_baselines/nested_worker_group_cancel_channel.brp`;
- `sleep_cancelled_string.brp`;
- `channel_cancelled_send_string.brp`;
- `channel_cancelled_recv_string.brp`;
- `channel_cancelled_select_string.brp`;
- `concurrent_cancelled_fixed_join_string.brp`;
- `list_concurrent_cancelled_join_string.brp`;
- `select_cancelled_stack_result.brp`;
- `tcp_cancelled_accept_string.brp`;
- `tcp_cancelled_read_string.brp`;
- `udp_cancelled_recv_string.brp`; and
- the stream/resource cancellation baselines in the same directory.

Keep the focused codegen-audit coverage for
`channel_send_attempt_stack_result_temp_cleanup.brp`,
`select_stack_result_receive_cleanup.brp`,
`tcp_resource_read_cancellation_cleanup.brp`,
`concurrently_loop_owned_iterable_cleanup.brp`,
`stack_result_match_scrutinee_cleanup.brp`, and
`resource_cleanup_break_continue.brp`.

## Detailed fast feedback loop

### 1. Red/green the effect lattice

```bash
bin/blorp check --no-format blorp/src/compiler/stage_10_backend/cancellation_plan.brp
bin/blorp test blorp/test/compiler/stage_10_backend/test_cancellation_plan.brp
bin/blorp test blorp/test/compiler/stage_09_core/test_core_fairness.brp
```

Keep six tiny callable graphs in the test: safe leaf, direct checkpoint, direct
blocking call, two-hop propagation, recursive SCC, and unknown call. Print or
assert summaries by exact definition identity so failures identify the wrong
edge immediately.

### 2. Red/green the protection plan and current-ABI emission

```bash
bin/blorp check --no-format blorp/src/compiler/stage_10_backend/emit.brp
bin/blorp test blorp/test/compiler/stage_10_backend/test_core_emit.brp
```

For each tiny Core fixture, assert the exact ordered protection events before
asserting C substrings. During Slice A, keep the existing runtime ABI and prove
only that unnecessary frames disappear. This is the fastest way to distinguish
an analysis error from a runtime-scope error.

### 3. Exercise one safe and one cancellable source fixture

After one `make`, compile two small codegen-audit fixtures without embedding
runtime C:

```bash
probe_dir=$(mktemp -d "${TMPDIR:-/tmp}/blorp-cancel-cleanup.XXXXXX")
for fixture in cancellation_free_owner owner_spans_channel_wait; do
  bin/blorp compile --no-format --no-embed-runtime \
    -o "$probe_dir/$fixture.c" \
    "blorp/test/compiler/pipeline/codegen_audit/should_pass/$fixture.brp"
  wc -l -c "$probe_dir/$fixture.c"
  rg -n 'CancelCleanup|task_cleanup_(track|untrack|push|pop|duplicate)' \
    "$probe_dir/$fixture.c" || true
done
rm -f "$probe_dir"/*.c
rmdir "$probe_dir"
```

The safe fixture must contain no cleanup scope. The cancellable fixture must
show one track before the wait and one untrack after it.

### 4. Red/green the compact runtime ABI

Add a native probe that registers known sentinel releases and records order.
Run it under both normal compilation and ASan/UBSan. Exercise:

1. track A, duplicate A, track B, untrack B, drain A twice;
2. track A, untrack A, reuse its entry for B, drain B once;
3. nested scopes with inner then outer cancellation order;
4. normal scope exit with no drain; and
5. every cleanup kind.

Then rerun `test_core_emit` and the two source fixtures. Do not start with the
full leak gate; a wrong slot order should fail in seconds.

### 5. Run the cancellation leak cluster

```bash
bin/blorp test blorp/test/runtime/concurrency/test_cancellation.brp
bin/blorp test --leak-check --suite --timeout 30 \
  blorp/test/runtime/memory/leak_check_baselines/nested_worker_group_cancel_channel.brp
bin/blorp test --leak-check --suite --timeout 30 \
  blorp/test/runtime/memory/leak_check_baselines/channel_cancelled_select_string.brp
bin/blorp test --leak-check --suite --timeout 30 \
  blorp/test/runtime/memory/leak_check_baselines/select_cancelled_stack_result.brp
scripts/test leak
scripts/test runtime
```

Use the same focused commands under the applicable compiler/runtime sanitizer
route before the final full gate.

### 6. Recount self-host C after each slice

```bash
self_dir=$(mktemp -d "${TMPDIR:-/tmp}/blorp-cleanup-census.XXXXXX")
self_c="$self_dir/blorp.c"
bin/blorp compile --no-format --no-embed-runtime -o "$self_c" blorp/src/main.brp
wc -l -c "$self_c"
rg -o 'blorp_CancelCleanup(Frame|Scope)' "$self_c" | wc -l
rg -o 'BLORP_TASK_CLEANUP_SCOPE' "$self_c" | wc -l
rg -o 'blorp_task_cleanup_(push|pop_slot|duplicate_slot|track|untrack)' \
  "$self_c" | sort | uniq -c
rg -o 'blorp_(retain|release|release_arc_only)\(' "$self_c" | sort | uniq -c
rm -f "$self_c"
rmdir "$self_dir"
```

Report Slice A and Slice B separately. Also report C-emission time and native C
compile time at `-O2`, because this issue is justified primarily by reduced C.

## Acceptance criteria

1. A named, test-covered `CannotCancel`/`MayCancel` analysis is computed once
   per exact callable and reaches a fixed point for recursion.
2. Unknown, closure, unresolved, and unclassified foreign/runtime calls default
   conservatively to `MayCancel`; purity and names are not used as heuristics.
3. A phase-owned protection plan tracks exact values only across reachable
   cancellable intervals and models left-to-right argument evaluation.
4. A managed value with no cancellable point in its lifetime emits no
   cancellation cleanup; focused generated-C tests prove this.
5. Remaining protection uses at most one linked cleanup scope/guard per emitted
   function activation, with compact deterministic slots rather than one linked
   frame per owner.
6. The old per-value frame codegen and runtime ABI are removed after cutover.
7. Cleanup order, duplicate counts, arbitrary untracking, slot reuse, recursion,
   nested scopes, every cleanup kind, and every exit path have focused tests.
8. Caller/callee ownership handoff is explicit and tested for an immediate
   callee-side cancellation; no accepted owner is temporarily unprotected.
9. The five cleanup forms measured above fall by at least 50% in aggregate from
   the controlled direct-parent self-host baseline. The PR reports that
   refreshed baseline, the historical approximately 282,680-line count, and
   the separate effect-analysis and compact-scope reductions.
10. Generated `blorp_retain`, `blorp_release`, and `blorp_release_arc_only`
   counts do not increase; intentional changes are attributed.
11. The complete cancellation/leak regression cluster, `scripts/test leak`,
    `scripts/test runtime`, `scripts/compiler-check --changed`, and relevant
    sanitizer gates pass with zero leaked objects and no use-after-free.
12. Before/after generated C lines/bytes, cleanup counts, C-emission time, and
    `-O2` native C compile time are included in the PR.
13. Fairness checkpoint placement and bounded cancellation behavior are
    unchanged.

## Out of scope

- removing or amortizing cooperative fairness checkpoints;
- weakening cancellation responsiveness;
- changing Perceus ownership contracts, retain/drop placement, or COW
  uniqueness except where an existing ownership event is registered;
- exceptions or general-purpose stack unwinding;
- heap-allocating cleanup metadata for fixed compiler-known scopes; and
- treating all pure/user/foreign calls as non-cancelling without exact evidence.
