# Minimize And Compact Cancellation Cleanup

**Status:** In progress

## Implementation State

- Checkpoint 0: the existing Perceus/backend benchmark now reports cleanup
  frame declarations and cleanup-scope guards alongside push/pop/duplicate
  counts. The direct-parent self-host census and channel-wait fixture remain.
- Checkpoint 1: semantic activation, site, owner, slot, action, and handoff types
  exist, and ordinary release-policy classification is consumed by production
  emission without changing generated C. Routing specialized producers and
  typed event pairing remains.
- Checkpoint 2: final-Core function and dynamic-global bodies are scanned once
  into local cancellation facts and exact definition-ID call edges. A
  deterministic reverse-call worklist propagates effects through user calls
  and recursion. Precise local reasons remain inspectable; transitive effects
  use one explicit `TransitiveCallBoundary` reason rather than copying every
  reachable reason through the graph. All final call-kind families are covered
  conservatively by focused tests.
- Checkpoint 3: production emission computes one indexed program cancellation
  summary, then builds one current-behavior protection plan for each emitted
  function, closure body, and dynamic global initializer. Semantic `let`
  cleanup and backend-owned call arguments, iterables, concurrent results,
  select values, moved captures, and match scrutinees now pass through typed
  plan decisions. The four recursive cleanup-decision scans formerly embedded
  in `emit.brp` have been deleted. The 32-owner nested regression visits 65
  expressions once, versus a conservative 2,048-visit lower bound for the
  removed scans, a 96.8% reduction. Four representative generated-C fixtures
  are byte-identical to the direct parent, and all 307 Core-emitter tests pass.

  On the self-host workload, the direct parent completed in 66.62 seconds with
  2,193,276,928 bytes maximum RSS; Checkpoint 3 completed in 65.14 seconds with
  2,157,199,360 bytes maximum RSS on the same machine. Backend time changed
  from 31.46 to 32.13 seconds. This checkpoint therefore centralizes cleanup
  decisions without materially regressing the production workload; semantic
  suppression remains reserved for Checkpoint 4.
- Checkpoint 4: production emission now treats the activation cancellation
  effect as the single authority for ordinary local-owner protection. Functions,
  closure bodies, and dynamic global initializers that cannot cancel retain the
  same ARC, stack-result, and COW operations but emit no local cleanup
  push/pop/duplicate protocol. Typed backend candidates remain intact so
  evaluation order and temporary materialization do not depend on whether
  cleanup is suppressed. Resource frames and task-window protocols remain
  unconditional; select and conservative unknown-call paths remain protected.

  A same-source self-host census compared the rebased Checkpoint 3 compiler
  with the Checkpoint 4 compiler. Cleanup pushes fell from 35,781 to 34,503,
  pops from 77,704 to 75,437, and duplicate-slot calls from 48,424 to 43,472:
  8,497 fewer local cleanup calls, or 5.25%. Cleanup suppression affected
  1,729 of 22,616 emitted C functions (7.65%). Generated C fell by 12,062
  lines and 863,462 bytes, both about 0.9%. Retain, release, ARC-only release,
  and stack-result retain/release counts were exactly equal in the census.
  In one paired local sample, wall time changed from 70.67 to 66.03 seconds and
  maximum RSS from 2,154,348,544 to 2,148,532,224 bytes; treat the timing as
  directional until repeated samples are collected.

  The focused compiler suites, Core sanitizer, generated-C audit, all 4,461
  runtime tests, and all 880 leak checks pass. The formerly failing LSP leak
  checks are covered by the retained-projection ownership normalization now in
  the merge base. The full default gate passes all 10,733 tests.

## Objective

Reduce generated cancellation cleanup without weakening Blorp's ownership or
structured-concurrency guarantees.

The work has two eventual outcomes:

1. emit cleanup protection only when an owner can remain live across an
   operation that may cancel the current task; and
2. represent the remaining protection with compact activation-level cleanup
   scopes instead of one linked frame and one C cleanup guard per owner.

The implementation must preserve deterministic ARC, left-to-right evaluation,
resource cleanup, task and task-window ordering, recursion, all normal return
paths, and every cancellation leak baseline. It must not remove or delay
cooperative checkpoints. Purity is not evidence that an operation cannot
cancel the current task.

This issue deliberately begins with useful, byte-identical refactoring. The
compiler must first have one typed cleanup model and one planning authority.
Cleanup suppression and runtime ABI changes follow only after that foundation
has parity tests and measurements.

## Current Problem

The backend currently protects most immutable managed `let` bindings for their
entire body. `let_tracks_cleanup` in
`blorp/src/compiler/stage_10_backend/emit.brp` checks the release policy and
whether the body appears to transfer ownership, but not whether a cancellation
point is reachable while the owner is live:

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

The emitter also repeatedly scans expression bodies through
`body_consumes_var_before_suspension`, `body_consumes_var`,
`let_body_takes_cleanup_ownership`, and
`transfer_prefix_is_non_suspending`. These helpers are conservative and are
not an interprocedural cancellation analysis.

Each protected owner currently expands to a linked frame, a GCC/Clang cleanup
guard, registration, and later slot lookup:

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

The current runtime frame in
`blorp/src/lib/runtime/native/runtime_decl.c` contains seven fields per
protected owner:

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

At self-host revision `3d8ec393b04d`, excluding the embedded runtime body:

| Generated-C construct | Occurrences |
| --- | ---: |
| `blorp_CancelCleanupFrame __blorp_*cleanup_*` declarations | 48,212 |
| `BLORP_TASK_CLEANUP_SCOPE(...)` | 48,221 |
| `blorp_task_cleanup_push(...)` | 48,218 |
| `blorp_task_cleanup_pop_slot(...)` | 89,960 |
| `blorp_task_cleanup_duplicate_slot(...)` | 48,069 |

Those forms occupied approximately 282,680 generated source lines, about 20%
of the historical 1,416,117-line self-host translation unit. Refresh all
counts against the direct parent before changing behavior. Match-continuation
sharing and static string pooling have changed the current workload.

## Current Pipeline Boundary

The relevant production order is:

```text
resource
-> fairness
-> compiler_core_prepare
-> reuse(prepared unions)
-> cancellation planning
-> C symbol projection
-> C emission
```

`PreparedCoreProgram` is currently an opaque wrapper around `CoreProgram`.
Cancellation planning belongs after the final prepared-reuse pass because that
is where all fairness checkpoints, resource scopes, exact callable identities,
Perceus ownership operations, and backend preparation decisions are visible.
It belongs before C-symbol projection because plans use semantic identities,
not generated C spellings.

Production and unprojected test emission must consume the same plans. Dynamic
global initializer bodies also call the ordinary expression emitter and must
be represented explicitly; this is not only a function-body analysis.

## Architectural Decisions

### One cleanup authority

Create `blorp/src/compiler/stage_10_backend/cancellation_plan.brp`. Its public
product is consumed by `emit.brp`. Once plan parity is complete, the emitter
must not independently rescan Core to decide whether to track, duplicate, or
untrack an owner.

Do not build a second general backend IR. Add the smallest typed planning layer
that can describe cleanup candidates and ordered events before C strings are
rendered.

### Stable activation, site, and owner identities

Core source locations are diagnostic metadata and may repeat. Generated C
variable names are presentation. Neither is a valid cleanup identity.

Use phase-owned identities equivalent to:

```blorp
opaque type CancellationSiteId = Int
opaque type CancellationOwnerId = Int
opaque type CancellationSlotId = Int

union CancellationActivationIdentity:
	FunctionCancellationActivation(CoreDefinitionIdentity)
	GlobalInitializerCancellationActivation(CoreDefinitionIdentity)

union BackendCleanupTemporaryRole:
	CallArgumentTemporary(Int)
	CallResultTemporary
	MatchScrutineeTemporary
	IterableTemporary
	ChannelValueTemporary
	SelectValueTemporary(Int)
	ConcurrentCaptureTemporary(Int)
	ConcurrentResultTemporary
	ClosureMoveTemporary(Int)
	PreparedStackResultTemporary

union CancellationOwnerIdentity:
	CoreVariableCancellationOwner(CoreVar)
	BackendTemporaryCancellationOwner(
		CancellationSiteId,
		BackendCleanupTemporaryRole,
	)
```

Exact names may follow nearby conventions, but the distinctions are required.
Every owner identity is scoped by its activation. Equal source spellings and
equal source locations must not collide.

Backend-created temporaries receive typed identities when they are
materialized, before cleanup strings are emitted. The planner must cover both
currently emitted and currently omitted candidates so it can detect missing as
well as redundant protection.

### Closed cleanup actions

`CoreReleasePolicy` covers ordinary ARC shapes but does not represent resource,
task, or task-window protocols. The cleanup model therefore needs a separate
closed action type equivalent to:

```blorp
union CancellationCleanupAction:
	ReleaseArcCancellationOwner
	ReleaseArcOnlyCancellationOwner
	ReleaseStackResultCancellationOwner
	ReleaseResourceCancellationOwner(ResourceCleanupIdentity)
	CancelJoinTaskCancellationOwner
	CloseTaskWindowCancellationOwner
	RuntimeOwnedCancellationOwner(RuntimeCleanupIdentity)
```

`ResourceCleanupIdentity` and `RuntimeCleanupIdentity` are typed wrappers around
the exact callback/protocol selected by preparation. They must not be inferred
from a C variable name or symbol prefix.

Task, task-window, select, and resource protocols remain distinct even if they
eventually share one runtime entry representation.

### Explicit cancellation effects

Use the current-task-specific lattice:

```blorp
union CoreCancellationEffect:
	CannotCancelCurrentTask
	MayCancelCurrentTask
```

A summary also records why an operation is `MayCancelCurrentTask`, including
whether the reason is a known cancellation point or a conservative unknown
boundary. Unknown does not need a third effect variant: it is a reason for
`MayCancelCurrentTask`.

The existing `BuiltinRuntimeEffect` registry in
`stage_06_typecheck/type_system/builtins.brp` remains the semantic source of
truth for builtin effects. Do not create a competing Stage 10 name list.
Projection must carry enough closed effect information into final Core, or
into an exact final-Core call catalog, for the planner to classify each call
without guessing from C names.

The current registry's fallback to `NoRuntimeEffect` cannot be interpreted as
proof that an unknown final-Core operation cannot cancel. Every final-Core call
form must either have an explicit registered effect or conservatively become
`MayCancelCurrentTask`.

User-call summaries reach a fixed point over exact callable identities. A
callable is `MayCancelCurrentTask` when its reachable body contains:

- `CooperativeCheckpointExpr`;
- an explicitly classified current-task cancellation or parking operation;
- a call to another `MayCancelCurrentTask` callable;
- an unresolved, deferred, closure, or otherwise unknown call; or
- a foreign call not explicitly proven `CannotCancelCurrentTask` by its ABI.

Recursive and mutually recursive groups converge deterministically. The solver
revisits compact call-graph facts, not Core bodies.

### Explicit caller/callee ownership handoff

`ConsumeArg` says the caller transfers ownership. It does not prove that the
callee installs cancellation protection before its first cancellation point.
These are separate facts.

Use a closed handoff contract equivalent to:

```blorp
union CancellationHandoffContract:
	CallerProtectsThroughCall
	CalleeOwnsAtEntry
```

A caller may untrack a consumed argument before a call only for
`CalleeOwnsAtEntry`. A user callee with that contract must install parameter
protection in its generated prologue before any checkpoint, blocking call, or
other possibly cancelling work. A runtime callee may use that contract only if
its ABI synchronously establishes equivalent internal protection. Otherwise
the caller remains responsible through the call.

Do not infer this contract from `consumed_args`, a source name, or a runtime
symbol prefix.

### Structured, path-sensitive protection plans

Protection events are attached to explicit evaluation sites and phases:

```blorp
union CancellationProtectionEvent:
	TrackCancellationOwner(
		CancellationSlotId,
		CancellationOwnerId,
		CancellationCleanupAction,
	)
	DuplicateCancellationOwner(CancellationSlotId)
	UntrackCancellationOwner(CancellationSlotId)

record CancellationProtectionSite {
	site_id: CancellationSiteId,
	before: List[CancellationProtectionEvent],
	after: List[CancellationProtectionEvent]
}

record CancellationProtectionPlan {
	activation: CancellationActivationIdentity,
	max_live_slots: Int,
	sites: List[CancellationProtectionSite]
}
```

The actual representation may annotate a prepared expression tree or use a
phase-owned site catalog. It must preserve branch and loop structure; a flat
unordered event list is insufficient.

The analysis respects left-to-right evaluation. An earlier owned call argument
is protected while a later argument is evaluated when the later evaluation may
cancel. A borrowed argument remains protected through a possibly cancelling
callee. A consumed argument is untracked immediately before a proven handoff.

At a branch join, owner liveness is the conservative union of reachable
incoming states, while maximum simultaneous slot capacity is the maximum over
reachable paths, not the cardinality of all branch-local owners. Loops use a
fixed point or an equivalent structured proof. Break, continue, return, and
resource-cleanup exits are explicit edges.

## Incremental Implementation Strategy

Every checkpoint below is independently reviewable and mergeable. Do not
combine semantic suppression with the runtime representation rewrite.

### Checkpoint 0: Freeze The Direct-Parent Baseline

Add a deterministic cleanup census using generated C produced with
`--no-embed-runtime`. Record:

- self-host C lines and bytes;
- frame declarations, guards, pushes, pops, and duplicate updates;
- C emission time;
- `-O2` native C compilation time;
- a cancellation-free managed-owner fixture; and
- an owner spanning a channel wait.

The census is measurement, not semantic classification. It may scan generated
C for exact runtime forms, but compiler decisions must never depend on that
scan.

### Checkpoint 1: Typed Cleanup Inventory, Byte-Identical

Add the owner, action, activation, and site types. Route every
current cleanup producer through centralized typed helpers while preserving
the current decision and exact generated C.

Cover:

- immutable lets and moved closure captures;
- generated call arguments and call results;
- match scrutinees;
- ordinary and concurrent iterables/results;
- channel and select temporaries;
- stack results;
- resource scopes;
- tasks and task windows; and
- dynamic global initializer bodies.

Runtime-owned native frames are inventoried separately. They are not rewritten
in this checkpoint.

Acceptance:

- every push has one typed owner and cleanup action;
- emitted and non-emitted candidate sets are representable;
- push/pop/duplicate pairing is checked by typed identity;
- no category is inferred from C text;
- production and unprojected test emission agree; and
- controlled generated C is byte-identical.

This checkpoint is valuable independently: it removes scattered stringly
classification and establishes one vocabulary for later planning.

### Checkpoint 2: Authoritative Cancellation Effects, Byte-Identical

Carry the existing builtin runtime-effect authority into final Core and add the
fixed-point callable summary. Keep known reasons and conservative boundaries
inspectable.

Add focused tests for:

- an explicit checkpoint;
- direct known blocking and known nonblocking runtime operations;
- a two-hop user-call chain;
- safe and cancelling recursive groups;
- closure and unresolved calls;
- foreign calls; and
- every final `CoreCallKind` variant.

Acceptance:

- every final call form is handled exhaustively;
- unregistered operations fail closed to `MayCancelCurrentTask`;
- recursion converges deterministically;
- summaries use exact callable identity;
- no callee body is rescanned per call site; and
- generated C remains byte-identical.

### Checkpoint 3: Current-Behavior Cleanup Plans, Byte-Identical

Build a `CancellationProtectionPlan` for every emitted function, closure body,
and dynamic global initializer. First reproduce existing cleanup decisions,
including conservative ones. Make emission a mechanical plan consumer.

Delete emitter body scans only when their last consumer has moved:

- `body_consumes_var_before_suspension`;
- `let_body_takes_cleanup_ownership`;
- `body_consumes_var`;
- `transfer_prefix_is_non_suspending`.

Move the nonrecursive `call_arg_needs_cleanup` classification into typed
candidate construction. Small shape helpers may remain when they are not
parallel cleanup-policy authorities.

Acceptance:

- exact ordered events are asserted for straight-line, branch, loop,
  break/continue, return, consumed, borrowed, and multi-argument cases;
- equal variable spellings and repeated source locations do not collide;
- backend-created temporaries are planned explicitly;
- global initializer and closure-body emission consume plans;
- no cleanup-decision Core scan remains in the emitter;
- cleanup-decision expression visits fall by at least 80%; and
- generated C remains byte-identical.

This checkpoint is also independently useful: it removes repeated backend
analysis even if no cleanup is suppressed.

### Checkpoint 4: Whole-Activation Suppression Using The Existing ABI

Apply the deliberately coarse first optimization:

```text
if activation.effect == CannotCancelCurrentTask:
    emit ordinary ARC
    emit no local cancellation registration
else:
    emit the current-behavior protection plan
```

Keep resource, task, task-window, and runtime-owned protocol cleanup unless the
plan proves they are local owner registrations covered by the same rule.

Acceptance:

- eligible activation fixtures emit no local push/pop/duplicate calls;
- ordinary retain, release, and COW behavior is unchanged;
- the predicted eligible count equals the actual statement reduction;
- cancellation, leak, and sanitizer gates pass; and
- the self-host eligible fraction and generated-C reduction are reported.

### Checkpoint 5: Region-Sensitive Liveness, Conditional

Proceed only after Checkpoint 4 measurement. If whole-activation suppression
removes fewer than 5% of self-host cleanup statements, do not automatically
add region-sensitive complexity. First demonstrate that cleanup-heavy
functions account for meaningful generated-C size or compile time.

For accepted workloads, protect an owner only from acquisition until its first
release, transfer, return, drop, or enclosing cleanup adoption, and only when
that interval crosses `MayCancelCurrentTask`.

Required cases:

- owner with no cancellation point in its lifetime;
- owner consumed before the first cancellation point;
- owner created after the last cancellation point;
- borrowed versus consumed possibly cancelling calls;
- earlier call argument spanning later argument evaluation;
- branches and loops;
- caller/callee `CalleeOwnsAtEntry` with immediate callee cancellation; and
- disjoint versus overlapping owner lifetimes.

Emit the reduced plan through the existing linked-frame ABI. This isolates
liveness correctness from runtime layout changes.

Acceptance:

- no unknown proof suppresses cleanup;
- exact event plans match expected evaluation order;
- retain/release counts do not increase;
- focused generated leak/cancellation fixtures pass; and
- measured C-size or compile-time improvement justifies retaining the added
  analysis.

### Checkpoint 6: Compact Runtime Scope ABI

After semantic plans are stable, replace generated per-owner frames with one
stack-resident cleanup scope per function activation, or a smaller explicitly
delimited scope where required.

One possible representation is:

```c
typedef struct {
    const void* slot;
    void* value;
    blorp_CancelCleanupFn release_value;
    long release_count;
    unsigned long registration_order;
    blorp_CancelCleanupKind kind;
    bool active;
} blorp_CancelCleanupEntry;

typedef struct blorp_CancelCleanupScope {
    struct blorp_CancelCleanupScope* prev;
    blorp_CancelCleanupEntry* entries;
    long capacity;
    unsigned long next_registration_order;
    bool active;
} blorp_CancelCleanupScope;
```

The exact shape may differ. It must provide:

- one task-stack link and one normal-exit guard per generated activation;
- compile-time fixed storage for compiler-known slots;
- deterministic slot IDs and safe arbitrary untracking;
- counted duplicate ownership;
- slot reuse with registration-time LIFO order;
- independent scopes for recursive activations;
- nested activation order equivalent to the current linked stack;
- fast no-current-task behavior; and
- direct cancellation drain without a shadow frame per entry.

The native runtime also creates cleanup frames, including dynamically sized
task-window task slots. Treat those as explicit runtime-owned scopes or
entries. Fixed compiler-known metadata must remain stack allocated; genuinely
runtime-sized task-window metadata may remain dynamically allocated. The old
and new structures must share one ordering model during development, and the
final cutover must not ship two independent cancellation stacks.

The runtime drain currently performs special passes to flush task windows,
cancel children as a group, deactivate child slots owned by windows, and then
release remaining entries. Preserve those phases over the new scope/entry
iterator.

Runtime tests must cover:

1. track A, duplicate A, track B, untrack B, then drain A twice;
2. track A, untrack A, reuse its slot for B, then drain B once;
3. nested scopes draining inner registrations before outer registrations;
4. normal scope exit without draining;
5. arbitrary untracking;
6. recursion;
7. every cleanup action; and
8. task-window deactivation of child task entries.

### Checkpoint 7: Emitter Cutover And Old-Path Deletion

Emit one scope only for activations with protection events. Map plan events
mechanically to slot operations. A one-slot plan still uses the uniform compact
scope representation.

After every generated and native caller is migrated:

- delete per-owner frame rendering;
- delete slot-address lookup from generated cleanup operations;
- remove the old frame ABI and obsolete slow functions;
- remove exact-C expectations for the old forms; and
- retain behavioral and structural tests for the new forms.

Do not retain a compatibility cleanup stack.

## Correctness Requirements

- Every uncertain operation is `MayCancelCurrentTask`.
- Every managed owner live across a reachable cancellation point is protected
  exactly once plus its explicit duplicate count.
- No consumed, returned, transferred, or dropped owner remains protected after
  its ownership endpoint.
- Caller-to-callee untracking requires an explicit handoff contract.
- A `CalleeOwnsAtEntry` callee protects an accepted owner before its first
  possible cancellation.
- Normal completion performs the same releases and COW-relevant ARC operations
  as before.
- Cancellation releases each still-owned value exactly once and preserves
  observable resource/task cleanup order.
- Stack slots remain valid until cancellation drain has finished reading them.
- No scope or entry pointer outlives its C activation.
- Break, continue, return, branch joins, loops, and recursive calls are modeled
  explicitly.
- Nested worker groups, channels, select, sleep, streams, TCP/UDP, task windows,
  stack results, and resource scopes remain safe.
- Non-task execution keeps a cheap no-op path.
- Supported Clang and GCC lanes retain equivalent behavior.
- Fairness checkpoint placement is unchanged.

## Required Tests And Gates

Compiler tests:

- `blorp/test/compiler/stage_09_core/test_core_fairness.brp`;
- new `blorp/test/compiler/stage_10_backend/test_cancellation_plan.brp`;
- `blorp/test/compiler/stage_10_backend/test_core_emit.brp`; and
- generated-C audit fixtures under
  `blorp/test/compiler/pipeline/codegen_audit/should_pass/`.

Keep or adapt focused codegen coverage for:

- `channel_send_attempt_stack_result_temp_cleanup.brp`;
- `select_stack_result_receive_cleanup.brp`;
- `tcp_resource_read_cancellation_cleanup.brp`;
- `concurrently_loop_owned_iterable_cleanup.brp`;
- `stack_result_match_scrutinee_cleanup.brp`;
- `resource_cleanup_break_continue.brp`; and
- borrowed network write/send fixtures.

Cancellation/leak coverage includes:

- `blorp/test/runtime/concurrency/test_cancellation.brp`;
- `nested_worker_group_cancel_channel.brp`;
- `sleep_cancelled_string.brp`;
- channel send, receive, select, and timeout cancellation baselines;
- concurrent fixed-join and list-join cancellation baselines;
- `select_cancelled_stack_result.brp`;
- TCP accept/read, UDP receive, TLS, WebSocket, and stream cancellation
  baselines; and
- resource cancellation baselines in the same directory.

Fast focused loop:

```bash
bin/blorp check --no-format \
  blorp/src/compiler/stage_10_backend/cancellation_plan.brp
bin/blorp test \
  blorp/test/compiler/stage_10_backend/test_cancellation_plan.brp
bin/blorp test \
  blorp/test/compiler/stage_10_backend/test_core_emit.brp
bin/blorp test \
  blorp/test/compiler/stage_09_core/test_core_fairness.brp
```

Before each behavior-changing checkpoint completes:

```bash
scripts/compiler-check --changed
scripts/test leak
scripts/test runtime
make compiler-core-sanitize-test
```

Run the complete quality and premerge gates before final cutover.

## Measurement And Acceptance

Report each checkpoint separately against its direct parent:

- generated C lines and bytes;
- frame/scope declarations and guards;
- track, duplicate, and untrack operations;
- generated `blorp_retain`, `blorp_release`, and
  `blorp_release_arc_only` counts;
- C emission time;
- `-O2` native C compile time; and
- relevant compiler analysis counters.

Final acceptance requires:

1. one exact, test-covered cancellation-effect authority;
2. one typed cleanup-plan authority for functions, closure bodies, backend
   temporaries, and dynamic global initializers;
3. no emitter cleanup-decision body rescans;
4. conservative unknown handling and explicit caller/callee handoffs;
5. no local registration in proven noncancelling activations;
6. region-sensitive suppression only if its measured value justifies its
   complexity;
7. at most one generated linked cleanup scope/guard per protected activation;
8. no old per-owner generated frame ABI or parallel cancellation stack;
9. exact duplicate counts, arbitrary untracking, slot reuse, recursion, nested
   scopes, and runtime-owned protocols covered by focused tests;
10. at least a 50% aggregate reduction in the historical cleanup forms from a
    refreshed direct-parent baseline;
11. no increase in generated retain/release operations unless separately
    explained and approved;
12. all cancellation, leak, runtime, compiler, sanitizer, and codegen-audit
    gates passing; and
13. unchanged fairness placement and bounded cancellation behavior.

## Out Of Scope

- removing or amortizing cooperative fairness checkpoints;
- weakening cancellation responsiveness;
- changing Perceus retain/drop placement or COW uniqueness;
- general exceptions or stack unwinding;
- a general backend IR redesign;
- heap-allocating fixed compiler-known cleanup metadata;
- inferring effects or ownership handoffs from names, prefixes, purity, or
  source-module conventions; and
- retaining old and new cleanup ABIs as compatibility paths after cutover.
