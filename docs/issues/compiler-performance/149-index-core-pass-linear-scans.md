# Index The Remaining Linear Scans In Core Passes

**Status:** Ready. Coordinator-owned acceptance; five bounded cuts.

**Current state:** The 2026-09-16 self-compile profile shows several Core
helpers doing linear scans keyed by name or `Option[Int]` definition ID:

| Helper | Calls | Mechanism |
| --- | ---: | --- |
| `perceus.constructor_contract_by_return_type` | 1.55M | scans the parent-name bucket comparing `entry.def_id == Some(value)`; 32M `Option[Int]` equality calls overall |
| `prepare.find_union_decl` | 76k | scans all ~19k declarations per call |
| `dce.apply_reachability_facts` | 14k | copies six closure-state collections per call (COW) |
| `mono_data.find_template` | 2.0M | scans the template list; `template_name` called 16M times |
| `stage_08_core_lower/identity.sanitize_core_module_name` | 505k | re-sanitizes a module name for about 400 distinct modules |

**Next action:** Replace each scan with an exact index that preserves
first-match order, one helper per commit, measuring after each.

**Read first:** the five functions above; `perceus.build_env` (the
`constructor_contracts_by_def_id` dictionary already exists);
`prepare.prepare_program` and `prepare_decl`; `dce.close_reachability`;
`mono_data` where `templates` is collected; the focused suites
`test_core_perceus.brp`, `test_core_prepare.brp`, `test_core_dce.brp`,
`test_core_mono*.brp`; [issue 133](133-dce-reachability-fact-application.md),
which this issue supersedes, as it did the deleted
`late-core-latency/02-index-core-preparation-declarations.md`; the
[measurement protocol](../../../benchmarks/README.md#self-compile-measurement-protocol).

**Fast loop:**

```bash
bin/blorp test --timeout 180 blorp/test/compiler/stage_09_core/test_core_prepare.brp
make && scripts/compiler-build-status
benchmarks/self_compile_measure --label issue-149-<cut> --input-rev <baseline input_rev> \
  --baseline benchmarks/results/self_compile_baseline_O0_2026-09-16.json \
  --output /tmp/issue-149-<cut>.json --require-identical
```

**Decision:** Accept when generated C is IDENTICAL, retired instructions for
the self-compile fall by at least 2% across the cuts, early/late Core
allocations fall, and the small program does not regress more than 1%.
Consult the coordinator if an index would change first-match order or if a
cut needs a new field on a Core declaration.

## Cuts

### A. Constructor contracts by definition ID (perceus.brp)

`constructor_contract_by_return_type` receives `def_id: Option[Int]`. When it
is `Some(value)`, look the entry up in `env.constructor_contracts_by_def_id`
and keep the same predicate (`entry.name == name`, parent type name matches,
`contract_matches_arity`). Prove the first match is the same entry as the
parent-name scan would return: both dictionaries are filled in one pass over
`program.decls` in `build_env`, so insertion order within a bucket is
declaration order; write a test with two same-named constructors of different
parents and two same-def-ID entries of different arity. Do not touch any other
Perceus function; issue 148 owns the rest of this file.

### B. Union declaration index in prepare (prepare.brp)

Build a `Dict[String, CoreUnionDecl]` once in `prepare_program` (first
declaration wins; keep same-kind duplicates behaving as today) and pass it to
`prepare_decl` in place of, or alongside, the raw declaration list. Replace
`find_union_decl` scans with lookups. Leave record and enum lookups alone
unless the after-measurement still shows them; report their counts. The
earlier rejection in late-core-latency/02 measured a synthetic paired latency;
this issue's acceptance is instructions and allocations on the self-compile
with the small-program guard, so the query density argument is now explicit.
Delete late-core-latency/02 in the same commit and note the decision in the
handoff.

**Decision (cut B, landed):** a union-name index built once per public
preparation call cut the self-compile from 532,809,411,705 to
519,274,731,917 retired instructions (-2.54% on top of cut A) with
byte-identical C and total allocations up by four. The small program moved
+0.07%, inside its 1% guard. The earlier paired-latency rejection in
late-core-latency/02 measured a synthetic workload whose query density did
not match the compiler's; that document is deleted. Record and enum lookups
stayed as first-match scans.

### C. Fact application without state copies (dce.brp)

`apply_reachability_facts` binds `var reachable = state.reachable` and the
five sibling collections, then appends; because `state` still references the
same lists and sets, every append copies. Restructure so the collections are
moved out of the consumed `state` before mutation (destructure once, rebuild
once), and return the input state unchanged when every fact list is empty.
Preserve first-encounter order and `fail_closed` exactly as in issue 133;
delete issue 133 in the same commit and carry its invariants here.

### D. Template index in mono_data (mono_data.brp)

Where `templates: List[CoreMonoDataTemplate]` is collected, also build a
`Dict[String, CoreMonoDataTemplate]` keyed by `template_name` (first wins) and
pass it to the `find_template` callers. Keep the list for anything that
iterates in order.

### E. Module-name sanitization (stage_08_core_lower/identity.brp)

`sanitize_core_module_name` runs per identity. Precompute the sanitized name
once per module unit (where lowering already knows the module) and pass the
result to `core_module_member_name` callers, or memoize through the lowering
context that already flows to those callers. Skip this cut if the
after-measurement of A to D shows it below 0.3% of retired instructions;
say so in the handoff.

## Invariants And Tests

- Generated C is byte-identical on the self-compile and the small program.
- First-match semantics and declaration order are preserved everywhere; an
  index is a lookup accelerator, never a second authority.
- Each cut adds or extends a focused test naming the ordering behavior it
  protects (same-name different-parent constructors, duplicate union names,
  DCE fact idempotence and order, duplicate template names).
- No index outlives its pass invocation.

## Measurement

Measure after each cut with the harness; keep the JSON for each and report
the final comparison tables for the self and small programs. Primary:
retired instructions and per-phase allocations. Also report the
`Equatable_equals_Option_Int` call count before and after using a calls
profile of the compiler if the harness delta is smaller than expected.

## Acceptance And Rejection

Accept: IDENTICAL C on both programs; retired instructions down at least 2%
overall; early_core plus late_core allocations down; small program not up
more than 1%; `test_core_perceus.brp`, `test_core_prepare.brp`,
`test_core_dce.brp`, `test_core_mono*.brp`, and
`benchmarks/self_compile_measure lock -- scripts/compiler-check --changed`
green. Reject any cut that changes which declaration or contract is selected.
