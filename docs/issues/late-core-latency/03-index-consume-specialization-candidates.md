# Index Consume-Specialization Clone Candidates

**Status:** Ready

**Kind:** Pass-local late-Core latency and state-model cleanup

**Production owner:** `blorp/src/compiler/stage_09_core/consume_specialize.brp`

## Objective

Replace the four repeated linear query families over consume-specialization
clone candidates with one ordered, pass-local catalog and one exact used-key
index.

Candidate discovery, clone definition-ID allocation, call retargeting, clone
selection, clone placement, ownership operations, and output order must remain
identical. This issue corrects the representation of immutable candidate facts;
it does not change what is cloneable.

## Why This Work Exists

Consume specialization runs after projected DCE and before static-string
lowering and Perceus. It currently:

1. discovers candidate function parameters in declaration/parameter order;
2. allocates a clone definition ID for every candidate;
3. recursively rewrites eligible self-replacement calls;
4. traverses rewritten expressions to discover which clones were used; and
5. inserts used clones immediately after their original function.

`ConsumeSpecializeState` stores all candidates and used keys as lists:

```blorp
private record ConsumeSpecializeState {
	unions: List[CoreUnionDecl],
	next_def_id: Int,
	candidates: List[CloneCandidate],
	used_clone_keys: List[CloneKey]
}
```

Four hot query families scan those lists:

- `find_clone_target` scans every candidate for each eligible assignment call;
- `candidate_for_clone_call` scans every candidate for each matching user-call
  node during used-clone discovery;
- `clone_key_used` scans every used key during insertion and deduplication; and
- `clones_after` scans every candidate for every original function.

The resulting work is approximately:

```text
eligible assignments × all candidates
+ visited user calls × all candidates
+ used-key operations × used keys
+ original functions × all candidates
```

The native compiler sample attributed about 5.8% of late Core to consume
specialization. Within that pass, string equality represented about 20.9% self
time and used-clone collection about 11.7%. These figures overlap other leaves
and the shared Core benchmark does not generate cloneable source-managed
parameters, so a dedicated production-pass benchmark is mandatory.

## Exact Semantics To Preserve

### Candidate identity

The established key is:

```blorp
private record CloneKey {
	original_name: String,
	original_def_id: Int,
	arg_index: Int
}
```

`find_clone_target` also requires structural equality between the candidate's
parameter type and the assignment target type. Do not flatten this identity
into a string. Do not discard `original_name` merely because definition IDs
normally identify functions: current focused fixtures permit the same numeric
ID on differently named synthetic functions.

### Collision behavior

The current target scan retains the last exact match. Clone-call recognition
returns the first candidate matching clone name and clone definition ID. A
single-value map keyed only by a definition ID would change behavior on
synthetic or malformed collisions.

Index original definition IDs to ordered buckets of candidate ordinals. Reapply
every remaining name, argument, and type predicate within the narrow bucket, in
the same direction and with the same last-result rule. Generated clone IDs are
allocated monotonically from one pass-local counter and are unique by
construction, so clone-ID lookup may use one validated ordinal.

### Order and ID allocation

- Candidate discovery order remains declaration order, then parameter order.
- Clone IDs are allocated for all candidates before body rewriting.
- Unused candidates continue to consume clone IDs; compacting IDs after usage
  discovery would change later identities.
- Used clones remain in candidate order immediately after their original
  function.
- Retargeted calls retain the exact generated clone name and definition ID.
- Terminal drops, recursive match-field transfer, release policies, and
  diagnostics do not change.

## Required Representation

Keep one ordered payload authority and store only stable ordinals in indexes:

```blorp
private record CloneCandidateCatalog {
	ordered: List[CloneCandidate],
	ordinals_by_original_def_id: Dict[Int, List[Int]],
	ordinal_by_clone_def_id: Dict[Int, Int]
}

private record UsedCloneKeyIndex {
	arg_indices_by_name_by_def_id:
		Dict[Int, Dict[String, Set[Int]]]
}

private record ConsumeSpecializeState {
	unions: List[CoreUnionDecl],
	candidates: CloneCandidateCatalog,
	used_clone_keys: UsedCloneKeyIndex
}
```

The nested used-key shape is illustrative. A private equivalent is acceptable
if it represents the complete `CloneKey` exactly and supports membership
without scanning unrelated used keys.

Candidate discovery may first produce the ordered list and then construct both
indexes in one linear pass. The builder must assert or test that every generated
clone ID is absent before insertion. This cleanly separates ID allocation from
lookup representation. Building the indexes incrementally during discovery is
also acceptable if it preserves exactly the same IDs and ordering and measures
no additional COW cost.

Never duplicate `CloneCandidate` payloads into buckets. An ordinal must be
validated with `ordered.get` before use so corrupt internal state fails closed.

## Required Query Behavior

`find_clone_target` becomes:

```text
look up the original-definition-ID bucket
visit its ordinals in discovery order
validate original name, argument index, and structural parameter type
retain the last exact match
```

`candidate_for_clone_call` becomes:

```text
look up the unique clone-definition-ID ordinal
read and validate the candidate
return it only when the requested clone name also matches
```

`clones_after` becomes:

```text
look up the original function's definition-ID bucket
retain candidates with the exact original name and exact used CloneKey
emit retained candidates in bucket/discovery order
```

`mark_clone_used` performs exact indexed membership and insertion. It must not
rely on clone definition ID alone.

## Scope Boundary

`ConsumeSpecializeState.unions` and its `find_union` /
`find_union_variant` scans are a separate query family. Do not index them in
this issue. Count their residual work if convenient, but do not bundle union
identity and candidate identity into one acceptance decision.

Do not fuse body rewriting with used-clone discovery. That could be valuable,
but it changes traversal and state ordering and is independently rejectable.

## Test-First Plan

Add or strengthen focused tests before changing candidate storage:

1. no candidates;
2. one candidate and one used clone;
3. several candidate parameters on one function;
4. candidates spread across several functions;
5. used and unused candidates receive the same IDs as the baseline;
6. a later used candidate retains IDs reserved by earlier unused candidates;
7. same numeric original definition ID with different function names remains
   isolated;
8. generated clone definition IDs remain unique even when original definition
   IDs collide and earlier candidates are unused;
9. structurally different target type does not select a candidate;
10. target scan preserves last-exact-match behavior under an exact duplicate;
11. repeated references to one clone record one used key;
12. clone placement is immediately after the original and follows parameter
    order;
13. globals and implementation methods retain existing traversal behavior;
14. recursive match-field ownership transfer and terminal drop shapes are
    unchanged; and
15. complete Core JSON and generated C remain identical.

Use identity-pressure fixtures where names and definition IDs disagree in
different ways. A happy-path-only test cannot detect an over-aggressive scalar
key.

## Focused Benchmark

Add lane-owned files:

```text
blorp/benchmark/compiler/compiler_consume_candidate_index_profile.brp
blorp/benchmark/compiler/compiler_consume_candidate_index_profile_fixture.brp
benchmarks/compiler_consume_candidate_index_profile
```

Suggested interface:

```text
benchmarks/compiler_consume_candidate_index_profile \
  <plain|profile> <iterations> <functions> <candidates_per_function> \
  <user_calls> <used_percent> <collision_mode>
```

Scale independently:

- 64, 256, and 1,024 unrelated candidate functions;
- 64, 256, and 1,024 relevant user calls;
- 1, 8, and 32 cloneable parameters per selected function;
- zero, sparse, and dense used-candidate populations; and
- same-definition-ID/different-name collision pressure.

Every timed iteration must rewrite the original input program, not the previous
iteration's output. Otherwise later iterations will benchmark an already
specialized tree.

Report:

```text
catalog_builds
candidates_discovered
candidate_ordinals_indexed
target_lookup_requests
target_candidate_ordinals_visited
clone_call_lookup_requests
clone_call_candidate_ordinals_visited
used_key_membership_requests
used_key_linear_candidates_visited
clone_emission_queries
emission_candidate_ordinals_visited
clones_emitted
elapsed_microseconds
allocations
releases
retained_objects
semantic_checksum
```

The checksum must include ordered original and clone names, original and clone
definition IDs, argument indexes, retargeted call IDs, emitted clone count and
position, and terminal drop shapes.

Include a production-shaped mixed fixture and a zero-candidate control. The
control catches a catalog whose unconditional construction cost penalizes
programs with nothing to specialize.

## Incremental Implementation

1. Add deterministic counters around all four current scans.
2. Add identity, collision, ID-allocation, and output-order tests.
3. Record immediate-parent focused and compiler self-compilation baselines.
4. Introduce the ordered catalog and ordinal indexes.
5. Cut over target lookup and preserve last-exact-match behavior.
6. Cut over clone-call recognition and preserve first-match behavior.
7. Introduce exact indexed used-key membership and remove the flat used list.
8. Cut over clone emission to original-definition-ID buckets.
9. Delete superseded scan helpers and any fallback authority.
10. Compare candidate order, clone IDs, Core JSON, generated C, and ownership
    shape with the baseline.
11. Collect alternating optimized focused measurements.
12. Build the candidate compiler once, run compiler self-compilation, and
    complete correctness and performance review.

The counters in step 1 belong in the issue-owned profiler or behind
`@debug_only`. Inspect the optimized compiler artifact and confirm that normal
`rewrite_program` executes no counter mutation, allocation, or branch.

After each cutover, the focused test and one short benchmark run must pass. Do
not wait for the entire implementation to discover an identity regression.

## Fast Feedback Loop

```bash
bin/blorp test --timeout 180 \
  blorp/test/compiler/stage_09_core/test_core_consume_specialize.brp

benchmarks/compiler_consume_candidate_index_profile \
  plain 1 256 8 256 25 none

scripts/compiler-check --changed
```

Mechanical scan audit:

```bash
rg -n "find_clone_target|candidate_for_clone_call|clone_key_used|clones_after|for candidate in state\.candidates" \
  blorp/src/compiler/stage_09_core/consume_specialize.brp
```

Before review:

```bash
scripts/compiler-check --changed
scripts/test compiler-core-sanitize
scripts/test compiler-blorp
scripts/test leak
```

Run full compiler-on-compiler measurement only after the direct pass benchmark
and output identity are stable.

## Expected Result

Candidate selection changes from scans of all candidates to scans of only an
exact definition-ID bucket. Used-key membership becomes indexed, and clone
emission stops visiting every candidate for every function.

The historical profile supports a directional expectation of 1–4% lower late-
Core time, but the candidate scans are only part of a 5.8% pass. The primary
merge gate is a measurable improvement in the production pass plus eliminated
work growth; whole late-Core time is a regression guard when the absolute
change is below its noise floor.

## Definition Of Done

- One catalog is constructed per `rewrite_program` invocation.
- The catalog's ordered list is the sole candidate payload and ordering
  authority.
- Target lookup, clone-call lookup, used-key membership, and clone emission use
  exact indexes without visiting unrelated candidates or keys.
- Candidate identity, collision behavior, ID allocation, and clone ordering
  match the baseline.
- Old flat scans and duplicate storage authorities are removed.
- Complete Core, generated C, diagnostics, and ownership behavior are
  unchanged.
- Immediate-parent focused and compiler measurements are recorded.
- Correctness, performance, test-runner, and code-reviewer reviews pass.

## Acceptance Criteria

- [ ] `catalog_builds == 1` for one `rewrite_program` invocation.
- [ ] Every candidate appears once in `ordered`, once in its original-ID
      bucket, and once in the scalar clone-ID index.
- [ ] Candidate discovery and clone-ID allocation order match the baseline.
- [ ] Unused candidates continue reserving clone IDs.
- [ ] Complete `CloneKey` identity remains authoritative for usage.
- [ ] Original-definition-ID collision buckets preserve name/type predicates
      and last-match behavior; generated clone IDs are proven unique and still
      validate clone names.
- [ ] Unrelated candidates do not affect inspected-ordinal counts after index
      construction.
- [ ] `used_key_linear_candidates_visited == 0`.
- [ ] Work counters add no instructions or state to the normal optimized
      consume-specialization pass.
- [ ] The 1,024-candidate/1,024-call case performs at least 90% fewer candidate
      inspections.
- [ ] That large focused case improves median elapsed time by at least 20%.
- [ ] The production-shaped direct-pass fixture improves by at least 5%.
- [ ] The zero-candidate control does not regress by more than 2%.
- [ ] Focused allocations do not increase by more than 2%, and peak RSS does
      not regress by more than 1%.
- [ ] Compiler `late_core` and whole-compile distributions show no repeatable
      regression above 2%.
- [ ] Core JSON, generated C bytes/SHA-256, diagnostics, clone order/IDs, and
      ownership/drop shapes match the baseline.
- [ ] Focused consume-specialization, changed compiler, Core sanitizer,
      compiler-owned, and leak suites pass.

## Pitfalls

### Scalar original-definition-ID maps

Synthetic Core can reuse original numeric IDs across names. Use ordered buckets
for original IDs and reapply complete predicates. A scalar map is valid only
for monotonically allocated, uniqueness-checked clone IDs.

### Tracking only clone IDs

Generated clone IDs are convenient but are not the established used-key
contract. Preserve the exact original-name/original-ID/argument-index key.

### Compacting clone IDs

Allocating IDs only after discovering usage changes observable Core identities.
All candidates reserve IDs before rewriting, as they do now.

### Reordering clone emission

Dictionary enumeration must never drive output. Emit from ordered candidate
buckets attached to each original function.

### Payload duplication

Copying `CloneCandidate` into multiple dictionaries may erase the lookup win
with ownership traffic. Store ordinals into one ordered payload.

### Scope creep into union lookup

Union facts and candidate facts have different identities and evidence. Leave
`state.unions` for a separately measured issue.

## Non-Goals

- Changing cloneability analysis or ownership semantics.
- Indexing union declarations or variants.
- Fusing expression traversals.
- Allocating clone IDs only for used candidates.
- Sharing a catalog across compiler passes.
- Changing Perceus, prepared reuse, Core preparation, or C emission.
