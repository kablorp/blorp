# Direct accepted-type equality before ground overlap — review only

**Implementation checkpoint.** The integrated +9-line preparation passes
29 owning callbacks, the complete 445-input identity/leak matrix and all
separately measured cost ceilings. Corpus allocations/instructions fall
2.083%/0.462%. The destination's full gate passes 2,799 component checks and
445 e2e checks; the measured parsing frontier remains 33/35. The
[equality evidence](../benchmarks/results/blorp_2_type_equality_2026-10-16.md)
records the accepted-source boundary and distinguishes earlier mutant runs.
The design below preserves its original planning context.

This reviewed plan starts from published main `648cf95f1`. Root
requested this bounded preparatory plan after source inspection disproved the
initial allocation assumption for the ground-overlap fast path.

## Premise and limitation

The ground fast path is mathematically exact for the existing checker:
`inference_type(value, [], start)` returns AcceptedType(value)
(`inference.brp:739`); inference_head leaves it unchanged; inference_action of
two AcceptedTypes invokes model.same_type directly (`inference.brp:1098–1104`).
With no flexible variables there are no slot, binding, occurs or diagnostic
error paths to preserve. Every remaining ParameterType is rigid, compared by
owner kind, owner identity and position through same_parameter.

However same_type's current leaf fallback (`model.brp:352–365`) constructs
type_head(left) and type_head(right), then calls same_head. For bare record
pairs this allocates exactly the two RecordHeads seen in disjoint_heads.
Adding only the proposed ground shortcut therefore does **not** remove the
16,256 head materializations in the measured 128-provider describe group.

## Smallest direct preparation

Keep ListType, AppliedRecordType, AppliedUnionType and ParameterType branches
and their order unchanged. Replace only the 14-line fallback with these 24
lines, in the existing equality authority:

```blorp
		VoidType:
			match right:
				VoidType: True
				_: False
		IntType:
			match right:
				IntType: True
				_: False
		FloatType:
			match right:
				FloatType: True
				_: False
		StringType:
			match right:
				StringType: True
				_: False
		RecordType(owner):
			match right:
				RecordType(other_owner): IntOps.equals(record_number(owner), record_number(other_owner))
				_: False
		UnionType(owner):
			match right:
				UnionType(other_owner): IntOps.equals(union_number(owner), union_number(other_owner))
				_: False
```

The body change is **+10 physical production lines**, including normal arm
formatting already used by namespace.same_head. Removing the now-unused
same_head import makes the complete preparation **+9**. No helper, carrier,
state, type, index or matcher is added. type_head remains unchanged for namespace
consumers. The preparation's +9 stays below its +20 ceiling. The separate
current UFCS prototype's +28 becomes **+37** when this preparation is
integrated, below the original +102 whole-change ceiling.

The mapping is exactly the old TypeRef -> TypeHead -> same_head composition:
four distinct primitive constructors, record identity and union identity.
Every cross-constructor case stays false. Bare Record/Union versus applied
forms stays false in both directions, including an empty applied argument
list with the same owner. There is no normalization or arity interpretation.
Applied types retain their owner, ordered arguments, lengths and recursive
equality; rigid parameters retain exact existing identity semantics.

Only after that independent preparation is reviewed and validated, add the
ground case at the beginning of types_overlap:

```blorp
-- No flexible declaration variables: use the solver's accepted-type equality.
if left_parameters.is_empty() and right_parameters.is_empty():
	Ok(same_type(left, right))
else if disjoint_heads(left, right):
	Ok(False)
else:
	-- Existing generic path, unchanged.
```

Relative to the existing if, this adds **+3 physical production lines**, comment
included: **+40 total** versus the prototype's frozen source. This revises the earlier +38
estimate for the query-only stage; it does not widen the hard +102 ceiling.
Functions with phantom generic parameters still take the existing generic path.

## Correctness and measurement checkpoints

Existing test_model has a 24-representative, 576-pair structural equality
cross-product, built from ordinary declaration inventory IDs. It already covers
every TypeRef constructor, distinct nominal owners, different applied argument
counts/orders and rigid owner kind/identity/position. Extend its representatives
with empty applied record/union values using the same owners as bare types,
and distinct rigid union/record owners, so the cross-product explicitly pins
those cases in both directions and each claimed identity mutation. Add no
parallel expected-equality implementation; the unique representative positions
remain the oracle. Baseline functional tests should pass before this equivalent
cleanup; the existing cost breach is the failing performance oracle.

Use ordinary TestSuites for model, shared receiver overlap and declaration
clashes. After the ground shortcut, supplement accepted-producer overlap cases
for equal/distinct records, equal/distinct unions, equal/different List elements,
nested ground applications and equal/distinct rigid parameter owners with both
parameter lists explicitly empty. Keep every existing flexible generic,
repeated-variable, phantom and occurs test unchanged.

Mutation checks should reject: one primitive matched as another; nominal owner
comparison erased; bare/applied forms conflated; argument length/order ignored;
rigid owner kind or identity erased. Use ignored source snapshots through the
normal suites, never generated internal calls or altered emitted C. Existing
model coverage already targets several; strengthen only demonstrated gaps.

Root and the independent compiler expert approve this direct design. Commit
the plan before preparation implementation. Measure the preparation alone in
the clean quality-type-equality worktree against the same published-main bytes,
before adding it to the dirty UFCS prototype or introducing the shortcut:
no allocation growth on unchanged accepted corpus/stress, <=+0.5% normal
instructions, <=+1% host compilation proxy allocations and instructions, and
<=+20 production lines. Require
exact fixture outcomes/C and strict zero leaks. Normal env unsets
BLORP_LEAK_CHECK/BLORP_MEMORY_STATS; strict allocation runs remain separate.
Use minimum three matched serial samples and exact source/C/binary/host manifests.

After integration into the UFCS prototype, compare borrowed-plus-preparation
against borrowed-plus-preparation-plus-ground-shortcut independently on zero,
unchanged accepted corpus
and the existing exact 32×16/128×8 workloads. Source/C predict removal of
992/16,256 describe-pair head allocations only after both stages; preparation
alone leaves disjoint_heads' materializations intact. The pair count, routing
suffix scans and dedup comparisons stay quadratic; no instruction target is
promised. Preserve original measurements and the unresolved historical 31,000
workload mismatch. Stop/rescope at repeatable new ceilings or correctness/leak/
identity failures. Full integration still requires rebase onto the accepted
question/pattern/private stack and independent complete gates.

The possibility that a later M8 unmanaged-union representation removes similar
head boxing is an unverified future compiler hypothesis, not present evidence
or a reason to waive these gates.
