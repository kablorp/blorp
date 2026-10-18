# Self-compilation handoff — 2026-10-18

**Current direction update, 2026-10-18.** Remaining callback removal was
abandoned. All 41 compiler files now parse; pure function types parse, while
callable checking/execution remains pending. Pure Void returns are accepted.
The [Option/Result catalog and plan](OPTION_RESULT_PLAN.md) owns the nine required
helpers and their callable prerequisites. The original starting commit and held
work below remain historical handoff evidence, not a current-main claim.

## Problem and verified starting point

Blorp 2 does **not** compile itself yet. Several substantial implementations
exist in separate worktrees, but passing their standalone tests does not mean
they are integrated or accepted. Finish those paths rather than restarting them.

At this handoff, local and remote `main` both resolve to
`47c008b8df15d0b19f3498a32b1a5f06e9e6016e`. Integration checkout:
`/Users/keithphilpott/CLionProjects/blorp`. Preserve the unrelated dirty checkout
`/Users/keithphilpott/.codex/worktrees/35a5/blorp`; do not reset or stash it.
The new handoff documents themselves are initially working-tree changes.

Read the parent [AGENTS.md](../AGENTS.md), [Blorp 2 AGENTS.md](AGENTS.md),
[ROADMAP.md](ROADMAP.md), and the task-specific plan before editing.
[BOOTSTRAP_SOURCE_PLAN.md](BOOTSTRAP_SOURCE_PLAN.md) owns source simplification;
[LIBRARY_PARITY.md](LIBRARY_PARITY.md) owns host/target interfaces. This document
provides the execution order and handover state; it does not replace their
contracts. [SELF_COMPILATION_WORKSTREAMS.md](SELF_COMPILATION_WORKSTREAMS.md)
records every current coordinating subthread, actual worktree, and next step.

**Already on main:** the quality-roadmap corrections and namespace rewrite;
literal constants and construction-source migrations; argument-control lifts;
existing joins and reassigned-binding carriers (`7acd6df25`),
data/layout/ownership foundations and List construction;
integer-facing String primitives; native current-directory, read-file,
write-file and stderr operations; pure target path joining; retained-product
tests; strict target allocator accounting; and the `-O0` fixpoint driver.
Plans for additional capabilities are not those capabilities.

**Not established:** complete source checking, a linked target-built
compiler, target-built compiler leak freedom, actual compiler-product destruction
depth, or the A/B/C proof. The historical parse frontier is not a current count.

## Direction and scope

Get to self-compilation by reducing source requirements while keeping a coherent
language. Retain typed identities, ordinary generics and aggregates, nominal
opaques, required recursive data, UTF-8 Strings, local mutation, explicit
ownership, and pure compilation after loading. Do not weaken these to make a
fixture pass.

Retain executable callbacks/function types and implement their required semantics.
Migrate compiler source away from Char operations, parser classification
substrings, managed flat recursive walks,
range execution, and general nested/list/literal patterns where the reviewed
source pilots remain clear. Preserve the remaining dependency until its real
callers are gone. Already-supported input features need not be removed.

Defer general expression-control infrastructure, broader managed tail-call
optimization, extra recursive layout families without a stored-payload witness,
traits, target Char/Bytes, and self-hosted TestSuite support. Keep the reviewed
candidates and rejection tests; do not delete them as cleanup.

## Architecture that every increment must preserve

The actual public pipeline in `src/main.brp:29` is:

```blorp
checked ?= check(program).map_err(render_failure)
specialized ?= specialize(checked).map_err(singleton_diagnostic)
lowered ?= lower(specialized).map_err(singleton_diagnostic)
owned ?= own(lowered).map_err(singleton_diagnostic)
verified ?= verify(owned).map_err(singleton_diagnostic)
emit(verified).map_err(singleton_diagnostic)
```

The callbacks above remain in the compiler; the Option/Result plan adds their
required library support. Preserve the phase boundaries.
Builders are local and published products complete and immutable. Namespace
identity, semantic type identity, runtime layout identity, value identity and
ownership obligations have distinct authorities. No downstream reconstruction
from names or rechecking of already accepted facts. Strings belong to source
discovery, diagnostics, emitted text, paths or actual program String data.

For control flow, use the existing checked joins and one explicit runtime Loop
model. Source-specific admission belongs in checking/specialization. Own inserts
resource operations; Verify independently proves resource safety rather than
replaying Own's recipe. A sole arm-local ownership move can be safe even though
Own canonically acquires outgoing managed occurrences. Acquiring each required
outgoing occurrence before retiring old owners remains a producer invariant.

## Proposed solution: finish in these increments

### 1. Recover the in-progress work and close independent small slices

Check the workstream register before creating another worker. Most candidate
changes are **uncommitted**; a branch name alone will not recover them. Preserve
their patches and ignored evidence before moving or archiving anything.

Finish current reviews, missing mutations, native checks and current-base
acceptance for written record-field translation, Option/Result first-order
helpers, signed Int comparisons, checked UTF-8 slicing, qualified flat patterns,
Boolean operators and local annotations. These are largely independent; they
can be reviewed in parallel and landed separately. Shared checker, specialization,
lowering and emitter regions require an explicit integration owner.

At this handoff, restricted-if had four pure Void fixture failures. The owner
subsequently allowed pure Void functions; that fixture-only repair is historical.
The held candidate still needs current-base validation. Boolean exact-mode
profiling expected the wrong metadata field;
the check correction is drafted, with the original observation preserved.
Neither finding authorizes weakening assertions or restarting successful runs.

Exit: each landed slice has current-base functional evidence, effective restored
mutations, generated-C review where relevant, and independent review. Standalone
green candidates remain marked unmerged until destination acceptance finishes.

### 2. Finish restricted control flow using accepted join-carried variables

Complete [RESTRICTED_CONTROL_PLAN.md](RESTRICTED_CONTROL_PLAN.md): canonical Bool
operators, statement/binding/function-tail/arm-tail `if`, top-level `?=`, and
local annotations. Preserve omitted-else rules by syntactic role, exact
diagnostic/help/span and real cleanup on propagation. Pure functions returning
Void remain rejected under the existing signature rule.

Reassigned outer bindings through joins are already landed at `7acd6df25`.
Reuse that path under [CARRIED_BINDINGS_PLAN.md](CARRIED_BINDINGS_PLAN.md),
retaining precise binding, value and owner identities, including false-edge
carriers for `if`. Some historical plan prose still describes its pre-publication
state; actual main carries these values through checking, lowering, Own and Emit.
Do not rebuild that feature. General arbitrary expression children are outside
the slice.

Exit: granular parser/check/join/ownership/verifier tests plus real-main fixtures
cover normal arms, reassignment, early propagation, omitted else and rejection.

### 3. Converge scalar tail recursion onto common Loop, then managed loops

The two M3 implementers have complementary static patches; the combined closure
is not yet runnable. Compose Specialize/Lower/Emit from `ordinary_tail_prep`
with Own/Verify from `target_memory`. The approved Own interface is already in
the author tree: apply it **once**, not again with the peer's incremental core.
Finish every old-tail observer/test port, then delete the replaced model.

Specialize establishes scalar source eligibility once. Lower publishes fresh
header identities and parent outputs. Emit snapshots incoming values before
assigning mutable header storage. Own acquires outgoing managed occurrences
before retirement; Verify uses the actual pre-output snapshot across every
break/recur arm and checks availability, arity, types and resource discharge.

First prove the scalar checkpoint without changing runtime behavior. Then add
ordinary unmanaged `while`, followed by managed String carriers. Managed List
carriers are a later separately admitted extension of the same Loop model.
[M3_LOOP_PLAN.md](M3_LOOP_PLAN.md) owns the sequence.
Do not add a second tail-specific backend or trampoline to get around it.

Exit: separate Lower, Own, Verify and Emit tests, malformed raw IR rejection,
independent safe alternatives, swap/duplicate outgoing values, zero-header and
managed-parent-output cases, effective mutations, native sanitizers and strict
memory checks. Exercise million-step tail recursion with exact results and
0/1/17 controls; a large count alone is not an oracle.

### 4. Accept ordinary nominal opaque types

The opaque candidate already passes a full standalone functional run; preserve
and integrate it rather than reimplementing it. Accept its semantic-key
preparation separately from the opaque feature. Keep nominal declaration and
application identities through checking and instance-key construction; project
representation at the accepted specialization authority.

Test explicit construction/projection, distinct equal-representation types,
generic substitution, visibility, managed underlying values and destruction.
Reuse existing aggregate layout and ownership. Opaque wrappers do not imply
allocation-free physical storage. [OPAQUE_TYPES_PLAN.md](OPAQUE_TYPES_PLAN.md)
owns the design. This work can proceed beside steps 2–3 with shared-file review.

### 5. Finish independent byte, loop and source-pattern migrations

Compose retained byte/classification candidates narrowly.
Preserve the held sorting/fill/scalar-adapter callback-removal candidates and
[remaining callback ledger](REMAINING_CALLBACK_LEDGER.md) as evidence; do not
resume that migration. Preserve evaluation once, collection order, first-error
ordering, spans and complete publication. Callable support follows the
[Option/Result plan](OPTION_RESULT_PLAN.md), with early architecture review.

After managed loops land, migrate flat recursive builders and all source ranges
to ordinary loops. Preserve bound evaluation once, direction, exclusive ends and
wrapping arithmetic. Complete qualified flat constructor heads and non-binding
alternatives, then source-pattern simplification under
[QUALIFIED_PATTERN_SOURCE_PLAN.md](QUALIFIED_PATTERN_SOURCE_PLAN.md). Do not
replace a clear pattern with unbounded boilerplate merely to claim removal.

Exit: a fresh resolved inventory establishes each claimed Char/classification,
pattern or range removal has zero real remaining callers. Callbacks remain
required and are tracked separately. Report actual checking/frontier results;
historical textual counts are not acceptance evidence.

### 6. Complete target library parity and the actual shell/loader

Finish signed Int guards, String slicing/joining, ordinary target `path.dirname`
and `path.normalize`, and the remaining first-order numeric/String/List helpers
actually imported by source. Dirname depends on Slice, Int guards and scalar
loops; normalize's component stack needs managed List loop carriers.

Then finish [LOADER_SHELL_INTEGRATION_PLAN.md](LOADER_SHELL_INTEGRATION_PLAN.md).
Replace the loader's old current-directory call with the Result API; integrate
the existing target read/write/stderr operations through normal imports. Paths
remain normalized absolute logical paths, with component-boundary containment;
no symlink canonicalization or implicit checkout knowledge.

Preserve the real entrypoint and CLI:

```blorp
func main(args: List[String]) -> Int
```

```text
compiler --library-root DIRECTORY INPUT.brp OUTPUT.c
```

Return 0 on success, 1 on usage/loading/compile/output errors. Successful
compilation is silent; diagnostics go to stderr. Test relative invocations from
different working directories, UTF-8 and embedded NUL contents, NUL-path errors,
file errors and partial-write cleanup. Regenerate `LIBRARY_PARITY.md` from actual
resolved source calls; its historical MISSING table is not a current inventory.

Exit: every required import has matching host/target signatures, the actual
compiler shell uses them, and real CLI fixtures pass without fixture rewriting.

### 7. Validate actual compiler-shaped ownership and structural depth

Existing retained-product tests and nested-join tests are useful preparation.
They do not prove the full compiler's destruction depth or leak freedom.
Exercise representative complete parsed/checked/specialized products, recursive
types, managed List builders, joins, loops and rejection cleanup at meaningful
depth. Inspect emitted C and compile with supported C toolchains' default limits.

Keep per-phase resource fault tests separate from native runtime lifetime tests
and whole-program strict accounting. The explicitly permitted old-host leak is
not permission for pilot or target-runtime leaks. Fix ownership/design failures
before self-compilation; defer optional ARC/COW optimizations.

### 8. Run the actual A/B/C proof at `-O0`

Use the existing driver; do not create another runner. A is host-built from the
final source. A compiles that same source/library into B; B produces C; B and C
emit identical C for the compiler. A and B must emit identical C/diagnostics for
every unchanged fixture, and B must pass the complete e2e suite.

Only `scripts/blorp2-fixpoint --prove` exiting 0 establishes M8. Keep stage
binaries, source/library/toolchain identities, outputs and logs. A known expected
C change during an increment does not relax the final deterministic fixpoint.
Then perform the required [M9 architecture audit](ROADMAP.md#m9-post-self-compilation-architecture-audit)
on the actual self-compiled compiler before major feature expansion.

## Execution, review and runnable acceptance

Parallelize implementation and reviews by disjoint ownership. Every writing
worker gets an isolated branch/worktree; one coordinator composes shared schemas.
Use at least two reviews per slice including coordinator review, with independent
code and test validation. Land one coherent accepted slice at a time. Existing
acceptance rules remain in the owning plans; this handoff changes none of them.

Serialize compiled work on this macOS machine; there is no outstanding compiled
job authorized at the handover. Do not rebuild the shared host casually. Its
current binary is `bin/blorp`, SHA-256
`c04f68ba64ac06f6cd3f924cdb4d87ce6b3d40d0f8fba2ef89b20e324b21ca57`.
Recheck freshness and explicit library correspondence before reuse. Some retained
acceptance packets intentionally use older pinned hosts/libraries; never mix them
with this binary or silently relabel old evidence.

From the integration checkout, the normal final commands are:

```sh
scripts/compiler-build-status
bin/blorp test --suite --timeout 180 blorp_2/test/unit blorp_2/test/runtime blorp_2/test/test_grammar
make -C blorp_2 test-compiler test-e2e
scripts/blorp2-fixpoint --frontier
scripts/blorp2-fixpoint --prove
```

Run an owning suite first during iteration. E2e builds the compiler once, runs
unmodified fixtures through real `main`, and has no 30-second suite timeout.
On hosted CI, retired-instruction collection is explicitly disabled by the
existing workflow; that does not disable functional or memory gates.
`--frontier` normally exits 0 even when self-compilation fails: report its rung,
not its exit code as success. Both driver modes replace `blorp_2/build/fixpoint/`, so
preserve any previous evidence before rerunning. No new infrastructure is needed.

## Handback to the next coordinator

The first concrete work is to review the saved restricted-if fixture repair and
finish the four remaining M3 test ports while independent reviewers inspect the
two M3 core patches. In parallel, close acceptance of the already-tested small
library/source candidates. Do not wait for every track to finish before landing
an independently accepted slice, and do not start new feature work to avoid a
pending integration task.

Start with the subthread register and ask each relevant owner to resume its
named next step. All seven app subthreads were asked to checkpoint without new
implementation or compiled runs. The two M3 workers have returned stable static
patches. Do not archive worktrees with borrowed ignored artifacts. Copy needed
evidence into the integration checkout's `build/bootstrap-evidence/` and verify
it first; Git snapshots omit ignored evidence.
For a handoff to another machine, export the uncommitted source patches and
referenced ignored artifacts explicitly; repository commits alone do not carry
these held implementations or their complete evidence.

Report progress as **authored**, **focused-tested**, **full-functional-tested**,
**accepted**, and **landed**. Name the actual current frontier and a concrete
next action. Stop and seek a design decision when a prerequisite assumption is
false, a migration becomes less clear than the feature it avoids, or independent
ownership verification exposes an unsound boundary. Do not work around those
failures with hidden inputs, alternate entrypoints or parallel implementations.
