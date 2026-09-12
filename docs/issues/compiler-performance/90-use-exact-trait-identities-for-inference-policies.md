# Use Exact Trait Identities For Accepted Inference Policies

**Status:** Complete

**Roadmap:** [Normalized Semantic Compilation Roadmap](NORMALIZED_SEMANTIC_COMPILATION_ROADMAP.md), Step 2e, nineteenth packet

**Depends on:** Exact selected and qualified accepted trait-call targets (Issues 88-89)

## Outcome

Accepted trait calls no longer project `TraitId` to a source name and then
re-enter string-keyed policy lookup. The three remaining accepted call-policy
consumers now stay in the identity domain:

```blorp
accepted_trait_matches_compiler_identity(
	authority,
	issuing_table,
	trait_id,
	compiler_trait_id,
)
accepted_resolve_trait_id_obligation(
	authority,
	issuing_table,
	env,
	receiver_type,
	trait_id,
)
accepted_find_impl_method_info_by_trait_id(
	authority,
	issuing_table,
	env,
	trait_id,
	method_name,
	receiver_type,
)
```

These queries serve elementwise tensor eligibility, trait-method `Self`
obligations, and resource-argument policy selection respectively. Their exact
table and topology paths do not project a source name. String projection
remains explicit at two compatibility boundaries: a compiler-linked trait may
project the compiler identity name for graphless Env fallback, and a failed
self-bound obligation projects the source trait name for its diagnostic.

Graphless Env calls and graph calls that do not yet have a selected accepted
target retain their explicit string-backed compatibility variants. This packet
does not pretend that an unresolved name is an ID.

## Context

Issues 88 and 89 changed a selected accepted trait-call target from:

```blorp
ResolvedSelectedTraitMethodCall(String, CallableId)
```

to:

```blorp
ResolvedAcceptedTraitMethodCall(TraitId, CallableId)
```

The retained target was normalized, but three inference helpers immediately
reversed that progress:

```blorp
trait_name = infer_facts_accepted_trait_method_name(facts, trait_id)
```

The projected name then selected compiler elementwise behavior, resolved the
receiver's trait obligation, or found the implementation method carrying its
resource policy. Besides repeated table and string work, this made the policy
boundary look name-authoritative even though accepted selection had already
published the exact declaring trait.

Name equality is insufficient for compiler-owned policy. A user trait named
`Equatable`, `FloatingPoint`, or `Absolute` is not the compiler trait merely
because it has the same spelling. The accepted trait table already stores the
explicit `compiler_builtin_id` link for the source prelude declaration. The new
identity query uses that link and never treats spelling as evidence.

## Invariants

1. Accepted call policies take the exact `TraitId` retained in
   `ResolvedAcceptedTraitMethodCall`.
2. Compiler policy applies only when the exact trait is a compiler trait or the
   accepted table explicitly links its source declaration to that compiler
   identity.
3. Same-spelled unlinked traits do not acquire compiler policy.
4. Trait-method `Self` obligations query the accepted topology and
   implementation relations by trait identity.
5. Resource-argument selection follows the exact topology method slot and
   implementation candidate relation by ID.
6. Existing string-based helpers remain only for graphless or unresolved
   compatibility variants.
7. Name projection remains isolated to compiler-Env compatibility fallback and
   the user-facing diagnostic after exact resolution reports
   `TraitObligationUnsatisfied`; names are not lookup keys in the accepted
   table or topology.
8. Every exact policy query receives the `DefinitionTable` that issued its
   `TraitId` and rejects a table that does not share allocation provenance with
   the accepted authority. Equal integer IDs from independent compilations are
   never reinterpreted as local rows.
9. No retained dictionary, ID side list, sentinel, packed identity, or generic
   integer map is added.

## Code Example

For a selected accepted call:

```blorp
match call.target:
	ResolvedAcceptedTraitMethodCall(trait_id, _):
		accepted_resolve_trait_id_obligation(
			authority,
			issuing_table,
			env,
			receiver_type,
			trait_id,
		)
```

the old path did this instead:

```blorp
trait_name = trait_id_name(definition_table, trait_id)
accepted_resolve_trait_obligation(
	authority,
	env,
	trait_obligation(receiver_type, trait_name),
)
```

For compiler policy, an accepted source trait is checked through its explicit
semantic link:

```blorp
accepted_trait_matches_compiler_identity(
	authority,
	issuing_table,
	selected_trait_id,
	compiler_floating_point_id,
)
```

A user-defined trait with the source spelling `FloatingPoint` has no such link
and therefore does not match.

## Implementation Strategy

### 1. Prove the old projection remains

The millisecond structural test requires all three ID-backed authority queries,
requires their accepted inference consumers, and rejects the old
`infer_facts_accepted_trait_method_name` helper. It failed before the production
change because none of the exact policy queries existed.

### 2. Prove identity provenance at the query boundary

All three exact policy queries take the definition table that issued the
incoming `TraitId`. Their shared row lookup first requires
`definition_tables_share_provenance`, the same allocation-identity capability
used by exact record, union, callable, and global queries. This prevents a raw
ID from an equal-layout foreign compilation from selecting a local row while
keeping the retained call target compact.

The declaration test constructs two independent definition tables with the
same trait layout and equal numeric trait IDs. Local policy succeeds; replaying
the foreign ID and its foreign issuing table fails closed.

### 3. Add one semantic identity comparison

`accepted_trait_matches_compiler_identity` compares exact IDs through the
accepted table's existing compiler-link relation. The requested compiler ID
must itself be in the compiler-owned domain. Equal names are never consulted.

### 4. Resolve self bounds by table identity

`accepted_resolve_trait_id_obligation` locates the exact accepted trait row and
uses the existing implementation and supertrait topology. Compiler Env fallback
is available only when that row explicitly carries a compiler link. The linked
compiler name is projected only inside that compatibility fallback.

The existing structural-equality exception remains in inference. It first
proves that the selected trait matches the compiler `Equatable` identity, then
checks the existing structural-equality fact. This preserves main's operator
semantics without reconstructing a source obligation.

### 5. Select resource policy by exact method slot

The implementation lookup was split into one shared candidate scanner plus two
entry points. The compatibility entry point prepares candidates from a trait
name. The accepted entry point finds the trait topology row by `TraitId`, finds
the requested method slot, and scans the already indexed implementation
candidates for that exact trait. Both paths reuse the same matching and
localization logic.

### 6. Preserve the diagnostic exception

When exact self-bound resolution fails, inference projects the validated trait
name from the retained definition table solely for
`Type ... does not implement trait ...`. Successful accepted calls do not make
that projection.

## Fast Feedback Loop

Run the representation boundary first:

```bash
python3 -m unittest \
  blorp.test.compiler.stage_06_typecheck.support.test_declaration_boundary.\
DeclarationBoundaryTests.test_accepted_trait_policies_consume_exact_identity
```

Then run the two semantic owners. The declaration suite covers explicit
compiler-link versus same-name identity; the bridge suite covers graph-backed
trait selection and both direct and UFCS resource-policy preservation:

```bash
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_typecheck_decl.brp
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_typecheck_bridge.brp
```

Run inference next to guard graphless compatibility behavior:

```bash
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_infer.brp
```

Use one retained regression pair, not repeated wall-time sampling:

```bash
/usr/bin/time -lp benchmarks/compiler_typecheck_phase_profile \
  bodies 1 32 4 16 16 memory
```

Finish with the manifest-owned changed check. Broader compiler tests are the
pre-commit gate, not the inner loop:

```bash
scripts/compiler-check --changed
scripts/test compiler-blorp
```

## Acceptance Criteria

- [x] The focused structural test fails against the old name-projection path.
- [x] Accepted elementwise policy compares an exact trait with an explicit
  compiler identity.
- [x] Accepted self-bound resolution consumes `TraitId` and preserves compiler
  structural equality.
- [x] Accepted resource-policy selection consumes `TraitId` and follows the
  exact topology method slot.
- [x] Same-name identity without an explicit compiler link does not match the
  compiler trait.
- [x] Equal numeric trait IDs from independent definition tables fail the
  exact policy provenance check.
- [x] Accepted table and topology success paths do not call `trait_id_name`;
  compiler-Env fallback may explicitly project its compiler identity name.
- [x] The failed-obligation diagnostic still reports the source trait name.
- [x] Graphless and unresolved compatibility variants remain explicit and
  behavior-compatible.
- [x] All 46 structural, 144 declaration, 309 inference, and 118 bridge tests
  pass.
- [x] The retained workload preserves its semantic and constructor checksums.
- [x] Allocations, releases, retained objects, and allocated bytes are exactly
  neutral; peak footprint improves 0.277%.
- [x] Retired instructions, RSS, cycles, and compiler size remain within 0.20%.
- [x] The manifest-owned changed check and independent review pass.

## Known Baseline Gate Failure

The final `scripts/test compiler-blorp` run passed 4,483 of 4,485 cases. The two
failures are the production check fixtures
`distinct_trait_ids_do_not_conflict_cross_module.brp` and
`qualified_namesake_trait_identity.brp`; both report an unqualified `show`
method collision between distinct qualified `Show` traits. They reproduce with
the clean `main` compiler at `f891949b`, and Issue 90 does not change the
authority-preparation collision block. The bounded follow-up is to admit only
genuinely unqualified methods to that name map while preserving the existing
local ambiguity diagnostic.

## Measurements

The retained checked-bodies workload produced the same semantic checksum
`2057305071532051463`, constructor checksum `-2142865109331864226`, 34 primary
outputs, and zero secondary outputs in both runs.

| Metric | Main baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Allocations | 17,244 | 17,244 | neutral |
| Releases | 12,936 | 12,936 | neutral |
| Retained objects | 4,308 | 4,308 | neutral |
| Allocated bytes | 350,408 | 350,408 | neutral |
| Retired instructions | 6,271,463,729 | 6,273,064,011 | +0.0255% |
| Cycles | 1,739,863,660 | 1,738,509,208 | -0.0778% |
| Maximum RSS | 25,067,520 | 25,018,368 | -0.1961% |
| Peak footprint | 17,744,184 | 17,695,032 | -0.2770% |
| Compiler bytes | 19,477,648 | 19,477,968 | +0.0016% |

Setup, measured-window, and wall time moved -0.12%, -0.83%, and -0.06%
respectively. They are one-shot observations, not latency claims. The retained
workload is a whole-typecheck regression guard rather than a causal measurement
of the selected trait-call path. The exact changed path is covered by the
structural and accepted-graph semantic owners above.

Raw counters and commands are retained in
[`benchmarks/results/compiler_accepted_trait_policy_identity_step2e_2026-09-11.md`](../../../benchmarks/results/compiler_accepted_trait_policy_identity_step2e_2026-09-11.md)
and its TSV companion.

## Next Packet

Completed as
[`91-preserve-exact-accepted-unresolved-trait-calls.md`](91-preserve-exact-accepted-unresolved-trait-calls.md):
graph-backed unresolved calls now retain `TraitId`, while name-only Env
candidates remain in the explicit compatibility variant.
