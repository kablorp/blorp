# Or-pattern binding prohibition evidence

Final integration baseline: `3434c656d` (enum-to-union main). The original payload-layout investigation was recorded against `5fed50a38`; its locations refer to that source before migration. Current-main migration, C and gate results are recorded separately below.

Or-pattern alternatives may not introduce variable bindings, even when all
payload types agree. This is an intentional language decision: use wildcards
for shared case selection and separate arms to access payload data. The check
rejects bindings without comparing or unifying their types.

Against current main, 191 binding groups are replaced by 540 independent arms
across 54 files: 173 production groups, six retained benchmark groups and twelve
existing test/runtime helper groups. Eleven remaining groups from the original
heterogeneous-payload report become 34 arms; the other 180 groups become 506
arms to enforce the stricter rule. Current main already contains both original
`late_invariants` loop splits; this change preserves them.

Every inventory entry includes its impact classification. The 180 same-type
groups have no heterogeneous receiver hazard. Two remaining heterogeneous loop
groups have differing iterable/body ordinals, masked in the full compiler by
source-named C fields. Three aligned binding groups account for the five
corrected callback casts; six others read aligned payload fields. No physical
wrong-field read was demonstrated in those full-compiler sites. The ordinary
record A/B reproduction is the demonstrated physical miscompile: `A.body` is
field 0, while `B` has `flag` and `extra` before `body` at field 2. The old shared
`ShapeA(item) | ShapeB(item)` body reads `B.f0` for `item.body`.

[The current-main inventory](MIGRATED_SITES.json) records every migrated pattern,
original location, alternatives and body hash. Bodies are copied verbatim after
any nested mechanical expansion. Two enclosing `module_surface` bodies contain
inner migrated groups; their separate baseline-body hashes preserve that
distinction. Independent replay verifies the migration. The scout is only an
editing aid: fresh production typechecking is the semantic completion oracle.
A locally shadowed constructor in a positive fixture also required a semantic
migration, preserving the existing single-arm shadowing coverage.

## Payload types and ordinals

All listed records are nominally distinct, not aliases. Ordinals are zero-based declaration order.

| Variant payloads | Fields read by the migrated code |
| --- | --- |
| `CoreForChannel` | `binder` 0; `iterable` 1; `body` 2 |
| `CoreForList` | `binder` 0; `iterable` 2; `body` 4. Ordinal 1 is `layout`. |
| `CoreForTensor` | `binder` 0; `iterable` 2; `body` 4. Ordinal 1 is `element_storage`. |
| `CoreForString`, `CoreForDict`, `CoreForSet`, `CoreForStream`, `CoreForResourceSource` | Each has `binder` 0; `iterable` 1; `body` 3. Ordinal 2 is `iterable_release_policy`. |
| `CorePreClosureConcurrentlyLoop`, `CoreConcurrentlyLoop` | Read fields align: `variable` 0; `iterable` 3; `body` 4; `timeout` 5; `limit` 6. Post-closure record adds `task` 8. |
| `CorePreClosureConcurrentBlock`, `CoreConcurrentBlock` | Read fields align: `bindings` 0; `body` 1; `timeout` 2. Binding element types differ: `CorePreClosureConcurrentBinding` and `CoreConcurrentBinding`; both put `variable` at 0 and `rhs` at 2. |
| `CoreListConstruct`, `CoreTensorBoxedLiteral` | `elements` aligns at 1 with type `List[CoreBoxedStorageValue]`; other payload fields differ. |

Variant authority: `blorp/src/compiler/stage_09_core/ir.brp:1786-1870`. Record declarations: `2255`, `2360`, `2458-2512`, `2552-2605`, `2679`.

## Migrated sites

Paths in the table are relative to `blorp/src/compiler/stage_09_core/`.

| File:line / function | Alternatives | Classification |
| --- | --- | --- |
| `ownership_contracts.brp:515`, `contract_expr_introduces_parameter_shadow` | Pre/post closure blocks | Distinct record and binding element types; accessed positions align |
| `ownership_contracts.brp:519`, same function | Pre/post closure concurrent loops | Distinct types; variable position aligns |
| `ownership_contracts.brp:979`, `contract_body_expr_matches` | List construct / boxed tensor literal | Distinct types; elements position and element type align |
| `ownership_contracts.brp:1122`, same function | Eight sequential For variants | Iterable/body ordinals differ |
| `ownership_contracts.brp:1127`, same function | Pre/post closure concurrent loops | Distinct types; accessed positions align |
| `ownership_contracts.brp:2055`, `schedule_contract_linear` | Pre/post closure concurrent loops | Distinct types; accessed positions align |
| `ownership_contracts.brp:2069`, same function | Pre/post closure blocks | Distinct types; timeout/body positions align |
| `ownership_contracts.brp:2828`, `summarize_function_return_ownership_uses` | Pre/post closure blocks | Distinct record and binding element types; accessed positions align |
| `late_invariants.brp:644`, `resource_body_has_unrewritten_exit` | Eight sequential For variants | Iterable ordinal differs for List/Tensor |
| `late_invariants.brp:1183`, `checkpoint_expr_violations` | Eight sequential For variants | Iterable/body ordinals differ |
| `perceus/uses.brp:3006`, `summarize_linear_ownership_uses_non_binding` | Eight sequential For variants | Iterable/body ordinals differ; binder position aligns |
| `perceus/uses.brp:3015`, same function | Pre/post closure blocks | Distinct record and binding element types; accessed positions align |
| `perceus/uses.brp:3032`, same function | Pre/post closure concurrent loops | Distinct types; accessed positions align |

## Why full self-compile C masks the ordinal defect

Field lowering emits the accepted field's ordinal (`stage_08_core_lower/lower.brp:2470-2503`). Or-pattern inference gives the shared body the first alternative's environment, and match expansion preserves its receiver types and ordinals (`match_lowering.brp:580-625`).

C emission spells a field using that receiver type plus ordinal (`stage_10_backend/emit.brp:11919-11944`; `emit_record_layout.brp:136-147`). Ordinary records use `f<ordinal>`, exposing the wrong-field bug. Foreign-exposed records preserve source field names. CoreExpr is foreign-exposed by `perceus_engine_summary_enter` (`perceus/uses.brp:159-164`); layout classification follows union payloads and nested records transitively (`emit_record_layout.brp:476-504`). Thus the full self-compile emits source-named Core members. A first-arm Channel ordinal 1 yields the spelling `iterable`, and C resolves `actual_list_pointer->iterable` to the List record's own physical field 2. The same applies to `body`.

Inspection of all four affected baseline self-compile C walkers confirms correct `->iterable`/`->body` accesses. They are ordinal hazards in Core, not demonstrated physical misreads in the full baseline compiler. A standalone suite without retained CoreExpr foreign exposure can expose ordinal reads; its before/after test result must establish that effect. The ordinary-record A/B reproduction directly demonstrates the alternate record being read at the first record's ordinal.

## Check boundary

`stage_06_typecheck/infer.brp` owns the check. Pattern inference first resolves
bare names using the scrutinee type and local scope, then
`typed_pattern_has_binding` inspects
typed alternatives, including tuple/list/constructor nesting and named spreads.
Each or-pattern that introduces a binding reports:

```text
error: Or-pattern alternatives cannot bind variables
    help: use wildcards to ignore payloads, or split the alternatives into separate match arms to bind them
```

The error points at the or-pattern. Bindings outside a nested or-pattern remain
valid. Wildcards, literals and constructors without bound payloads remain valid.
Both parser paths reach this shared semantic boundary; syntax remains unchanged.

## Regression coverage

The frozen current-main compiler accepts `Ok(value) | Err(value)` with `Int`
payloads. The new negatives reject that shape, including equal types at
different positions, binders only in later alternatives and named spreads.
Other exact fixtures cover the original record/scalar mismatch, nested tuple/
list/constructor alternatives, unrelated constructor-looking binder names,
qualified constructor payloads and locally shadowed constructors. The prior
name-set negatives now pin the prohibition and teaching help. All eight changed
fixtures pass their expected production checks.

The positive fixture keeps wildcards, constructors, literals, discarded spreads
and bindings outside nested alternatives valid. Inference units assert that a
forbidden inner or-pattern beneath an outer one emits one diagnostic, with help.
Runtime tests use separate arms to read both record layouts, different
constructor payload positions and both Result alternatives. Core/Perceus guards
cover List, Tensor and String iterable/body ownership and List/Tensor parameter
contracts. Those Core guards were not demonstrated before-failing; they are
coverage, not evidence of a physical repair in the full compiler.

## Current-main generated C

The frozen `3434c656d` compiler was copied only after its build-input status
reported `FRESH` against the clean main checkout. Its binary hash is
`39a6eae489b811afb570430a4a6d30e751fcb38f5dd7d07a2835df07080e3e21`;
the older `5fed50a38bf0-dirty` stamp is recorded as build metadata, while the
freshness check verifies the actual current source inputs. Its source archive
includes the matching generated standard library and build-info inputs. It and the fresh candidate compile the same
final source via `benchmarks/build_stage2_compiler --generator <compiler>
--generated-c <output> --c-only`. `cmp` confirms byte-identical C, SHA256
`b8c1bb6cbb0f808f7e75f11face2125f52f30788b22887838cc0285e353ed619`.

Comparing each source's self-C, current main has 82,194,195 bytes / 1,915,662
lines (SHA256 `9b7cc668e96821d40ce9698edfd242650db318c0b63e5c182469d4b7ae8e470e`),
and the candidate has 82,188,484 bytes / 1,915,651 lines: -5,711 bytes and -11
lines. All 2,631 raw C struct definitions and the matching semantic type-name
sets (2,434 names) are unchanged. Callable definitions move from 20,195 to
20,196: the typed-pattern binding helper and concat specialization replace the
unused free-variable environment helper. String-pool entries move from 8,818
to 8,819: the prohibition and teaching help replace the old name-set diagnostic.
Both outputs contain 5,202 closure thunk definitions and 1,332 actual static
closure object definitions. The struct count includes emitted union structs.

The six control-shape differences remain:

| Function | C body lines | Explanation |
| --- | ---: | --- |
| `tensor_arithmetic_satisfies_trait` | 70 → 61 | Removes redundant nested tuple capture/rebinding; both subjects are still evaluated once, left then right. |
| `resolve_trait_self_call` | 612 → 600 | Removes three formerly forced cleanup frames. |
| `singleton_constructor_value` | 100 → 91 | Removes two formerly forced cleanup frames and the now-unused cached task pointer. |
| `graph_import_admission_register_selective` | 780 → 764 | Removes four formerly forced cleanup frames. |
| `with_pinned_hash_constructor` | 179 → 159 | Removes redundant nested binding-match scaffolding. |
| `classify_call` | 128 → 120 | Removes two formerly forced cleanup frames; trait/direct field positions remain correct. |

The eleven frame removals follow the existing source-span ambiguity mechanism.
`match_projection.match_temp_var` gives authored scrutinees id zero and a name
derived from owner, span and nesting depth. Cloning or-arm bodies retains those
spans and repeats exact scrutinee identities in sibling branches.
`cancellation_plan.ambiguous_match_scrutinees` forces protection for repeats;
separate authored bodies have distinct spans and avoid that fallback. No
cancellation-planner or emitter rule changes. Ordinary release-call counts in all six bodies are unchanged. Five
callback casts become `CoreConcurrentBinding` rather than
`CorePreClosureConcurrentBinding`, at the three aligned binding groups: parameter-shadow detection, return-ownership
summary and linear-ownership summary. Their named physical field reads remain aligned. Raw type identifiers
are retained in the follow-up comparison so these changes are not hidden by
normalization. Generated callable/local identities, closure names, static-pool
ordering and moved generic specialization blocks also change; those are
attributed separately from the six control bodies. Normalized fingerprints
help locate differences and do not prove equivalence. The raw common-input
comparison and stage fixpoint are the exact output checks.

Sixteen groups differ textually from the earlier migration inventory: fourteen
updated groups and two new groups in `core_union_type_storage_errors`. Each
binds identical nominal types across its alternatives: thirteen `String` name
groups, one `TypeId` group, one `List[CoreType]` group and one two-`CoreType`
group. The new list group binds at different constructor-payload positions;
separate arms preserve each constructor's own extraction. These incoming-main
groups introduce no heterogeneous receiver-layout hazard. Direct before/after C
inspection of `core_union_type_storage_errors` confirms `NamedType.args` reads
field 1 and `TupleType.items` field 0, both as lists; Stack/Boxed Result payloads
read their `CoreType` fields 0 and 1. These positions were already correct.

## Separate lowering limitation

A runtime probe for `(value, Red | Blue)` exposed a pre-existing nested
or-pattern lowering gap: typechecking succeeds, but the backend emits a
`could not emit function body` error. The frozen former compiler reproduces
it too. Match lowering currently expands top-level or-patterns only. This
prohibition changes no lowering logic; nested semantic boundaries are covered
by inference tests, and a separate lowering fix is required for runtime support.
The retained Guide examples use top-level alternatives.

## Final validation on current main

The production fixture count is 863 (incoming main's 856 plus seven new
marked checks). Identity census rows move from 3,422 to 3,444. Only necessary
heuristic caps increase: typecheck/name 248 → 250 and Perceus/name 412 → 420.
The Core def_id/name counts are 290/484 and fit main's existing 293/498 caps.
Exact identity budgets, boundaries and unsupported capabilities are unchanged.
The existing `option_unbox_kind` marker producer appears twice after its arm
split; strict spelling checks report 510 findings with no stale entries.
All 47 Python census/spelling contracts pass.

The frozen current-main compiler accepts the same-type binder probe; the
candidate rejects it with the pinned prohibition and help. Validation runs
serially on the rebased source:

| Gate | Result |
| --- | --- |
| O2 `make` and compiler build-input status | PASS, FRESH |
| `make hygiene-check` | PASS |
| `scripts/compiler-check --changed --base origin/main` | PASS, 6,809 checks |
| `scripts/test --no-build compiler-blorp compiler-new compiler-new-parity` | PASS: 6,949 / 1,007 / 3,632 |
| `scripts/test --no-build --serial compiler-core-sanitize leak runtime` | PASS: 2,503 / 1,219 / 4,773 |
| `scripts/compiler-fixpoint` | PASS, all three stage outputs byte-identical |

Compiler-blorp includes 6,086 suite tests and all 863 pinned fixtures. Parser
parity has zero mismatched files; two existing known divergences remain.
The changed-source gate includes 2,928 owning-suite tests, 158 CLI checks,
2,503 Core sanitizer checks, 1,219 leak checks and one generated-C audit.
The explicit ownership/runtime rerun totals 8,495 checks and includes six leak
diagnostic controls. Repeated gate counts overlap by design. Compiler-check
removes successful internal suite/CLI logs; its component counts were recorded
by the runner before cleanup, and the final aggregate/selection logs are
retained. The broad and explicit ownership/runtime logs are retained in full.

All three fixpoint outputs are 82,188,484 bytes, SHA256
`b8c1bb6cbb0f808f7e75f11face2125f52f30788b22887838cc0285e353ed619`.
The stage-2/stage-3 builds use the repository's default O0 CLI optimization;
the installed compiler used by the gates remains O2, with O2 runtime objects.
Source and tests were unchanged throughout these final gates. Only this report
and the migration impact metadata were updated afterward.

All gate processes completed with no failures. No merge or push has occurred;
the Docker gate was not run.
