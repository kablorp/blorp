# First-order constant fills

Status: maintained plan for review before plan commit; implementation pending.
Planning base `62844e180193f6383cbc3caf1b0a75c9e646e013` is not a frozen cost B.
The ignored investigation `094781bd2534fcd9aefa90bb37fc28c42e16fea277ca9ab2ef747b37f2e10074`
received root and independent compiler-expert approval. This tracked version needs
root and peer review. No compiler/native/test/cost call or source edit followed.
Parent/pilot AGENTS and HANDOFF_SPEC apply; SOURCE policy hold remains unwaived.

## Census correction: six remain; the historical seventh is already migrated

BOOTSTRAP_SOURCE_PLAN.md:81,171–176,347,400 describes **seven** constant-fill maps.
Current inspection finds **six** remaining sites in four modules, listed below.
The seventh historical map was own.block_uses:

```blorp
-- Historical reset 78bc406..., src/own/own.brp:283:
var uses = definitions.map(pure func(_: ValueDefinition) -> Option[Int]: None)
-- Already accepted by unary db8abb15a; current own/own.brp:303–304:
unused: Option[Int] = None
var uses = repeat(unused, block_value_count(steps))
```

The accepted version must remain unchanged: M2 steps can publish several values,
so replacing its count with steps.length() would erase carried-value slots.
`git show db8abb15a -- blorp_2/src/own/own.brp` records the original migration;
`git show 78bc406d:blorp_2/src/own/own.brp` retains the old seventh map.
The existing `test_own/test_own.brp:317` callback
`test_join_outputs_have_separate_value_slots_at_one_step` explicitly checks three
steps versus four value slots and `[Some(1), None, Some(2), Some(3)]`. Keep that
proof: the accepted uses fill must stay value-counted, not step-counted.
Do not manufacture a seventh edit or move another nonconstant map into this scope.

The six rows below exhaust the current `.map` callbacks whose result ignores its
input and returns a fixed fill value, by bounded inspection of all current source
map calls. This is a source census, not a fresh resolved-callee/Core inventory.
Other maps project real binding IDs, types, declared layouts or call contracts and
are deliberately excluded. Name/spelling recovery is never an alternative.

## Six sites, before and proposed after

| Site and owning function | Current expression | Proposed expression / seed |
| --- | --- | --- |
| lower/lower.brp:907, lower_function | `function.bindings.map(pure func(_: ConcreteBinding) -> Option[ValueId]: None)` | `unbound: Option[ValueId] = None`; `repeat(unbound, function.bindings.length())` |
| own/own.brp:853, insert_steps | `steps.map(pure func(_: LoweredStep) -> List[ScheduledDrop]: [])` | `empty_drops: List[ScheduledDrop] = []`; `repeat(empty_drops, count)`; current `count = steps.length()` stays |
| verify/verify.brp:810, verify_layout_graph | `records.map(pure func(_): UnvisitedLayout)` | `repeat(UnvisitedLayout, records.length())` |
| verify/verify.brp:811, verify_layout_graph | `unions.map(pure func(_): UnvisitedLayout)` | `repeat(UnvisitedLayout, unions.length())` |
| emit/emit.brp:575, append_aggregate_definitions | `records.map(pure func(_): UnvisitedAggregate)` | `repeat(UnvisitedAggregate, records.length())` |
| emit/emit.brp:576, append_aggregate_definitions | `unions.map(pure func(_): UnvisitedAggregate)` | `repeat(UnvisitedAggregate, unions.length())` |

For example, lower's complete local change would be:

```blorp
-- Before:
var values = function.bindings.map(pure func(_: ConcreteBinding) -> Option[ValueId]: None)
-- After, with list: repeat, set imported:
unbound: Option[ValueId] = None
var values = repeat(unbound, function.bindings.length())
```

Own imports repeat already. Add repeat to the existing list imports in lower,
verify and emit; do not add a wrapper, generic fill helper, enum dispatch or cache.
The two explicit typed local seeds constrain the generic argument without a
lambda, explicit call type arguments, placeholder IDs or a new public type.
Keep var bindings and every subsequent update/consumer unchanged.

## Meaning, authority, ownership and evaluation

* Lower owns a body-local `List[Option[ValueId]]`, indexed by the complete accepted
  binding ordinal. None means no immutable value selected yet. Parameter and
  statement processing publish real ValueIds into these slots; downstream join
  PRE snapshots and final binding maps keep their accepted M2 semantics. No ID is
  inferred from spelling, position text or function names.
* Own owns one `List[List[ScheduledDrop]]` per inserted block, indexed by **step**
  position, independently of its separate value-indexed source vector. Buckets
  collect exact OwnerId/Span obligations and are consumed at their scheduled step.
  A shared empty seed creates equal values, not shared mutable buckets: append
  creates a new value, then outer set replaces exactly one slot. Preserve ordered
  acquisitions, scheduled releases, arm cleanup and terminal transfer.
* Verify's private LayoutVisit vectors belong to one by-value graph traversal;
  record and union ordinals are distinct domains even when raw numbers coincide.
  State changes Unvisited→Visiting→Complete drive cycle validation. Nothing is
  published as a new semantic fact; final verification remains the authority.
* Emit's private AggregateVisit vectors belong to one dependency-ordered aggregate
  emission. Record/union identities and existing stored-by-value edges remain the
  authority; Unvisited→Visiting→Emitted prevents missing/duplicate definitions.

Host `standard_library/src/list.brp:1276` and target
`standard_library/list.brp:5` agree: repeat(element, count), **element first**.
The target runtime/list.brp:140–168 normalizes nonpositive counts to zero, allocates
one owned list root and acquires each managed child occurrence. Actual source
counts here come from lengths and are nonnegative. Zero input stays zero output;
repeat does not mean count copies of independent mutable cells. Host List value
semantics likewise preserve logical independence when later slots are replaced.

Map calls a pure input-ignoring callback N times; repeat evaluates its fixed value
once, then its count. These constants are None, empty List, or nullary private
visit constructors: no effects, mutable captures, failures or identity-dependent
semantics. For N=0 the new seed is still evaluated once; old map never invokes its
callback. This changes possible infrastructure allocation, not a language result.
Do not claim allocation equivalence: inspect generated C and measure the host and
target boundary, especially the empty-list seed's shared reference occurrences.

Work is O(N) for both forms and O(2N) at doubled input; result storage is O(N).
Repeat removes six callback uses, not six guaranteed runtime allocations. A managed
empty bucket seed may replace N empty roots by one shared root with N obligations;
host lowering/COW details must be observed, not guessed. No growth-by-append loop
or new retained table is proposed; later updates keep their current costs.

## Shortest evidence and prospective scope

This is a behavior-preserving source refactor: characterize the SAME tests on
accepted B and candidate C, both expected GREEN. Do not call baseline GREEN a RED.

| Boundary | Small existing TestSuite and useful named behavior |
| --- | --- |
| Binding fill | test/unit/test_lower/test_lower.brp: scalar identity/type/span; parameter initializer reads original value; reassignment/old alias; empty call receiver. Add test_lower/test_join.brp to retain M2 outgoing versions. |
| Drop buckets | test/unit/test_own/test_own.brp: empty block returning prefix; distinct owners at separate final uses; immediate unused drop; returned versus unused owner. test_own/test_join.brp retains simultaneous carried acquisitions and cleanup. |
| Verify visits | test/unit/test_verify/test_recursive_unions.brp: independent record/union domains, mixed by-value cycle rejection, legal boxed/managed cycle. test_verify/test_record.brp retains unused-layout validation. |
| Emit visits | test/unit/test_emit/test_record.brp and test_recursive_unions.brp: dependency-ordered definitions and exactly-once boxed helpers. Existing test_list_phases exercises mixed record/union/list dependency ordering. |
| repeat precedent | test/runtime/test_generic_list.brp already has negative/zero/minimum repeat, equal mortal child obligations, nested escape, replacement preserving old aliases and 16/32/64/128 occurrence counts. No runtime implementation change is proposed. |

Future shortest owning command (only after managed writer worktree and lane grant):

```sh
ROOT=/Users/keithphilpott/CLionProjects/blorp
env -u BLORP_CC -u BLORP_MEMORY_STATS -u BLORP_LEAK_CHECK \
  "$ROOT/bin/blorp" test --std-dir "$ROOT/standard_library/src" --suite --timeout 180 \
  blorp_2/test/unit/test_lower/test_lower.brp
```

Use the FRESH coordinator-pinned host and explicit std, warmed default config;
record exact current host/std provenance before execution, not this proposal's
historical host convenience. Run the owning four boundaries next, then applicable
full components/grammar and real-main e2e with one unchanged-C pilot. Inspect
generated C for repeat's typed specialization, child acquisitions/drop and no
function-typed fill callbacks; no alternate main or rewritten output.

The existing `test_distinct_owners_drop_at_their_separate_final_uses`
(`test_own/test_own.brp:624`) already requires two exact DropOwner positions,
OwnerIds 0/1 and literal spans40/50 between separate borrowed calls. Reuse this
strong bucket-independence oracle; add no duplicate merely to reach a test count.
Any genuinely missing zero/multiple-slot case uses the existing typed builders.
Prove named oracles effective with bounded typed faults: shorten one vector count
at a time for last-slot coverage; replace Unvisited by Complete/Emitted for cycle
or definition coverage. Require actual named semantic failures, immediate exact
restore and restored GREEN; a setup failure is not an oracle kill. Select the
finite mutation set from actual prepared tests before jobs, not an invented count.

## Budgets, policy hold and next decision

Retain the existing SOURCE fill ceiling **40 gross added/+14 net production** for
the corrected six-site scope; forecast about 11 added/9 removed (+2) across four
modules including imports and typed local seeds, before readability adjustments.
Propose **160 gross/+160 net tests**, zero new fixtures and zero public API docs.
Budget the maintained evidence/implementation plan separately at <=220 physical
lines, plus <=30 added lines for source-plan/roadmap census and status edits.
New general APIs, runtime changes, identity carriers, source migration elsewhere
and unrelated map elimination are out of scope. Review caps before implementation.

The original SOURCE acceptance remains binding: local current-B/C and cumulative
reset-R0/C +3% allocations and normal min3 instructions for each unchanged input
and the **original schema1 artifact_construction_complete** source proxy; exact
C/diagnostics, all absolute caps and strict balanced zero remain. The unary and
three-site type-argument exceptions do NOT cover fills. The retained sorter screen
R0=9634/C=10166 (cap9923) and attribution acceptedB=10178 are actual historical
failures/observations, not this slice's measurements. No current fill sample exists.

This plan names the corrected six-site scope. Root/user must explicitly resolve
the SOURCE cumulative policy hold before cost freeze, acceptance or landing.
Do not freeze a fresh denominator, borrow the unary exception, roll B, select a
smaller corpus or launch thousands of samples as a workaround. Source/test static
preparation can proceed only under root's separate implementation grant; no
performance acceptance or landing is implied. Independent compiler/code and
test review plus root review precede this plan's separate docs-only commit; root
owns integration and the later managed implementation worktree.

Hand back exact six-site diff, source/test/fixture physical counts, accepted-base
comparison, actual characterization/mutant/restoration receipts, generated-C
observations and complete matched cost evidence if policy and lane are approved.
Stop on a seventh-site mismatch (now documented), new mechanism, cost/LOC breach,
unexpected diagnostics/C, missing host provenance or authority disagreement.
