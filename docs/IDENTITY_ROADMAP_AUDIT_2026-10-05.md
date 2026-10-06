# Identity roadmap audit — 2026-10-05

Audited revision: `ff4da4b31dc2f5e0e1b9425a2ac96c06f6399a63`.
The audit uses a fixed managed checkout because the primary checkout advanced
during investigation. The preceding revision, `c3040e79c7d8`, differs only in
`blorp/build/bootstrap.env`. Previously reviewed but uncommitted cleanup work is
excluded from landed-state claims.

Scope: the entire [Identity Roadmap](IDENTITY_ROADMAP.md), its current source
boundaries, named tests, scanner contracts and gate routing. Three read-only
specialist audits covered frontend identity, Core/backend identity, and tooling;
an independent reviewer challenged the integrated design findings. This document
is an audit record, not another implementation roadmap.

## Verdict

The staged direction is sound. It matches active String-based identity bridges,
reuses substantial landed authority, preserves useful negative experiments, and
usually supplies appropriate output, ownership and performance gates. It should
be executed as bounded deliveries with explicit deletion targets.

Before starting the affected deliveries, correct the stale descriptions below,
reconcile the red census baseline, and resolve the issuer/carrier and memo-key
contracts. These findings do not block every independent identity improvement.
No new production miscompilation, ownership failure or performance regression
was established by this audit. The nominal-name collision already pinned by the
repository remains a concrete correctness target.

## Current-state inventory

“Landed” below describes inspected implementation and test coverage, not a fresh
execution of the native compiler suites.

| Roadmap boundary | Current state | Remaining delivery |
| --- | --- | --- |
| Compilation names and parsed identifiers | `NameId` and compilation name tables exist; `ParsedIdentifier` still carries text and span. Standalone graph entrypoints can own private tables. | Unify the standalone issuer and rendering boundary before deleting `.text`. |
| Builtin/intrinsic vocabularies | Special inference and CTFE maps use `NameId`; `builtin_runtime_effect` still dispatches on String. | Migrate source effects while preserving explicit runtime/foreign ABI spellings. |
| Traits and bounds | `TraitId` is carried through bounds, obligations and supertraits; bound identities already own the authority. Accepted and compatibility trait-call states both exist. | Retire by-name entrypoints and derived String readers; reuse accepted targets instead of adding a parallel resolver. |
| Diagnostics, dumps, formatter | Table-based rendering is partly landed. Call diagnostics, semantic lint, CTFE, JSON and formatter still have text readers. | Inventory each reader by semantic/display purpose; removal is not yet ready. |
| Function/module origins | Origins, known-function catalogs and callable IDs exist alongside names/paths. Functions have module origins; globals retain only `source_module`. | Give globals explicit module provenance before deleting paths or redundant function spelling. |
| Definition authority | Discovery and Stage 6 currently issue separate definition catalogs. Frozen Stage 6 source rows and later allocation frontiers are distinct. | Adopt discovery authority through the adapter with checked category/module mapping and output compatibility. |
| Authored locals | Inference resolves through existing lexical admission/lookup. `VarSymbol` has optional definition ID but no proposed lexical value identity; compatibility binder IDs remain span-derived in lowering. | Select one authored issuer, prove its carrier, copy the exact identity to uses, and delete one repeated lexical lookup family. |
| Core value carrier and synthetic binders | `CoreVar` retains name, hygienic ID, optional definition ID and origin; equality is name plus ID. Counters and some id-zero producers remain. | The proposed resolved-value identity, checked mint/remap authority and clone coverage are open work. |
| Emission by ID | Callable/variant projection and nonzero local binder projection are active. Variant symbols no longer require `CoreUnionConstruct.constructor_c_name`. | Globals, id-zero/synthetic families, source-spelling recognition and explicit ABI exceptions remain. Measure a paying emission-table consumer first. |
| Late-Core exact targets | DCE and resolve still have deliberate by-name fallback paths. Perceus has a tested transitional `(id, def_id)` index. | Complete all producer paths before removing fallback indexes; preserve both identity dimensions until their replacement is authoritative. |
| Typed value-use satellites | Typed names already carry callable/global/trait/builtin target facts through existing representations. Proposed name-site satellites and seed lifecycle are absent. | Define one authoritative local/nonlocal target mapping and its handoff; avoid duplicating the scalar spine. |
| Nominal types and members | `FieldId` and scalar `ResolvedFieldIdentity` are active in typed fields and lowering. Named semantic/Core types and layout maps still use Strings. | Reuse the field authority; add nominal identity with specialization/layout and display provenance kept explicit. |
| Structural type interning | No proposed `SemanticTypeTable` or published Core type interner exists. Mono substitution already preserves unchanged inputs in several arms; equalities remain structural. | Named-type identity precedes the semantic interner. A mono-scoped Core interner remains a measured hypothesis. |
| Dispatch/layout by type ID | Rendered type keys and String-keyed layout indexes remain. Concrete mono data gets fresh variant IDs. | Use concrete structural/instance identity, not a source nominal declaration ID alone. |
| Core node tables | Packed source handles, negative pass-minted handles and selective tree reconstruction are active. Universal occurrence-key uniqueness is unproved. | Validate the exact memo scope, key and environment dependence before reopening cached Perceus summaries. |
| CoreTypeId and blocks | Recursive Core types and let/sequence nesting remain. | These are large later changes. Keep stable table prerequisites and the separate block ownership/order prototype. |
| Frontend fact ownership | `InferModuleFacts`/`InferSession` already split the body boundary. Import admission remains in the returned 14-field state. | Keep the broad state rewrite closed; retain the two bounded ownership probes and their capability gates. |
| Lowering lookup tables | String-keyed prefixes/layout indexes remain. FFI annotation and list annotation each build a layout index at the initial boundary. | Prove the intervening annotation preserves index facts before sharing that build; later rewritten programs need their own validity decision. |
| Header cache | Completion is recomputed; the roadmap correctly asks for a design note, with zero cold-compile gain. | Specify cache product, invalidation, publication and identity/session rebinding before implementation. |

## Corrections to the document

### 1. The identity census is currently red

The roadmap calls the census a migration ratchet (lines 808–817), but
`scripts/compiler-identity-census --check` fails on the audited revision:
186 new exact sites, two unclassified boundaries and 29 budget increases.
The baseline revision is `d63979ecee34ab080f9991969d8f075261f675c6`,
348 commits behind this snapshot; exact-site drift includes 193 removals.

Review and classify the drift before changing the baseline. An exact-site
addition can reflect moved or rewritten source, an accepted boundary, or real
remaining semantic work; the count is not 186 proved compiler defects.
Keep unsupported capability rows visible. A blind regeneration would discard
the reviewed starting point rather than restore a trustworthy ratchet.

### 2. Table-based diagnostic rendering is only partial

Roadmap lines 245–246 overstate the current diagnostic boundary.
[`infer.brp`](../blorp/src/compiler/stage_06_typecheck/infer.brp):8756–8811
reads `TypedNameExpr.name.text` in `call_name`, then uses it in arity and argument
mismatch diagnostics. Existing tests in `test_infer.brp` pin those messages.
Semantic lint also retains text readers. Revise the landed claim and add these
owners to the exit inventory before flipping `ParsedIdentifier.text`.

### 3. Binder-origin payloads and minting instructions need reconciliation

Roadmap lines 353–355 describe `Authored(NameId)` and
`DerivedFrom(binder_id)`. The actual variants in
[`ir.brp`](../blorp/src/compiler/stage_09_core/ir.brp):1096–1102 are
`AuthoredBinder`, `LoweringTemporary(kind)`, `PassTemporary(kind, Int)`,
`PerceusTemporary(kind, Int)`, `PerceusBorrowedResultTemporary(kind, Int, Int)`
and `DerivedFrom(String, kind, Int)`. Label the desired payloads as future work.

Lines 418–424 tell producers to mint from `CorePassState.next_binder_id`,
while lines 599–612 require the checked owner/domain/key authority and prohibit
direct counters. Describe the counter as legacy state and make the new authority
the sole future mint/remap API. Preserve old emission IDs/spellings during the
raw-C-identical transition: nonzero binder IDs already affect emitted symbols
in [`c_naming.brp`](../blorp/src/compiler/stage_10_backend/c_naming.brp):347–354.

### 4. Row contiguity is not an allocation-frontier proof

Roadmap lines 526–529 need to state the universe of their invariant.
[`definition_index.brp`](../blorp/src/compiler/stage_06_typecheck/graph/definition_index.brp):1753–1767
explicitly permits body-local/generated IDs to advance the allocation frontier
without synthesizing source rows. A contiguous frozen source-table slice does
not imply every allocated ID indexes that table, or every retained Core
declaration occupies the allocation range.

Separate source-row indexing, generated allocation frontiers and current-program
row views. Each has its own checked owner and coverage. Never infer an allocated
frontier from `next_def_id - 1`, a scan of retained declarations or a sparse maximum.

### 5. Memo admission must cover packed keys as well as minted keys

“Node identity minted by lowering (landed)” at lines 978–981 is true for the
existing handle machinery; it is not a guarantee of fresh expression-occurrence
identity across duplication. The memo paragraph already acknowledges this risk.
Its instruction to check “the minted ids” is too narrow.

[`ir.brp`](../blorp/src/compiler/stage_09_core/ir.brp):781–795 uses packed
source coordinates, a negative minted range and zero synthetic handles.
`core_expr_own_node_id`:2109–2117 excludes let/borrow-let/sequence wrappers.
[`pass_runner.brp`](../blorp/src/compiler/stage_09_core/pass_runner.brp):860–872
is report-only unless `BLORP_NODE_IDENTITY=strict`. Its check is limited to
function bodies (:1065–1082), and its semantic-match walk deduplicates shared
`CoreSemanticMatchTree` subtrees (:900–912); ordinary expression traversal
visits each occurrence (:874–890).

Require uniqueness/validity over every eligible actual memo key after shadow
freshening, an explicit zero/loc-less policy, and a distinction between shared
physical nodes and duplicated occurrences. Prove the `PerceusEnv` dependencies
separately. The old UAF cause remains a hypothesis, not a diagnosed current bug.

### 6. The proposed callee memo has an incomplete fallback key and no owner

Lines 856–864 correctly require a generic-instantiation test before using only
the callee definition ID. Their fallback `(def_id, lowered argument types)` is
still insufficient: `list[T](capacity: Int) -> List[T]` can have identical value
argument types and distinct instantiated return types. The existing
[`compile_time_collection_builders.brp`](../blorp/test/compiler/stage_06_typecheck/fixtures/typecheck/should_pass/compile_time_collection_builders.brp):7
demonstrates expected-return inference for `L.list(limit)`; a two-return-type
memo regression has yet to be written.

[`infer.brp`](../blorp/src/compiler/stage_06_typecheck/infer.brp):1834–1855
retains the declaration callable ID while recording instantiated parameters and
return separately. Key the complete instantiated callee type, under the relevant
lowering authority, including return/dimension/purity distinctions that affect
lowering. Account for `module_member_prefixes`, an actual type-lowering input.

[`lower.brp`](../blorp/src/compiler/stage_08_core_lower/lower.brp):5050–5057
returns only `Result[CoreExpr, CoreLowerError]` from an immutable Reader context.
Adding a dictionary field there does not publish new entries across sibling
calls. Select an explicit owner/update path before implementation and measure
its ownership costs. The roadmap's parked construction-time Core table already
records this publication failure at lines 873–877. This is a defect in a future
design instruction, not a bug in a live memo.

### 7. Snapshot counts and gate descriptions need qualification

Lines 869 and 965 say 860 diagnostic fixtures;
[`scripts/test`](../scripts/test):185 currently pins 830 marked compiler-check
fixtures. Line 918 says 95 stdlib type-name allowlist entries; the current keyed
allowlist has 97 entries producing 98 findings. Qualified-name entries/findings
remain 28. Label these as snapshot counts or use the owner command instead of
keeping drifting numbers in the plan.

The old census owner labels are already explicitly mapped at lines 800–806;
they are not an additional stale-plan defect.

## Contracts to settle before their affected slices

1. **Discovery adoption and output compatibility.** Discovery row categories
   and module IDs differ from Stage 6 reservation order and issuers. Stage 6
   reserves inherited default-method projections and uses target/dependency
   ordering. Pin category, child/owner, module-authority, builtin, standalone and
   generated-default mappings. The identity slice requires raw-C compatibility;
   the discovery acceptance roadmap allows normalized IDs in some migrations.
   Choose the stricter oracle for this slice and test divergent semantic/emission
   IDs for functions and globals. No parallel spelling resolver or shadow
   enumerator is needed.
2. **Carrier and pair-mint representation.** The roadmap already requires
   carrier probes and stop conditions; feasibility is not assumed. However, the
   earlier definition slice's no-heap paired frontier result lacks a selected
   supported representation. [`FIXED_LAYOUT_ROADMAP.md`](FIXED_LAYOUT_ROADMAP.md)
   confirms `record` and `fixed record` are managed; an opaque alias preserves its
   target representation. Choose the atomic pair API and carrier model before
   producer edits. Scalar fields in an existing owner and checked scalar handles
   are possible probe subjects, with different authority and lookup contracts.
   Prove nested occurrence/capture/pass behavior, not just isolated construction.
   No new source-level layout promise follows from this audit.
3. **Authored stability and typed-use handoff.** “Stable across unrelated edits”
   at line 283 is undefined. Counters, source offsets and discovery row IDs do
   not establish unrestricted stability after earlier insertions. Specify
   deterministic identical-input and transformation preservation separately from
   persistent incremental identity; the roadmap otherwise says IDs are
   compilation-local and never persisted. Then decide whether later name-site
   satellites replace or supplement direct typed IDs, which artifact owns them,
   and which lookup is deleted. Existing callable/global/trait/builtin/closure
   and field target families must retain their provenance.
4. **Nominal, structural and concrete-layout IDs.** Current graph `TypeId` is a
   nominal declaration identity. An interned `SemanticTypeId`/`CoreTypeId` would
   identify structural instantiations. Concrete specialization and occurrence
   release/layout facts are separate again. Generic layouts cannot be indexed
   by source nominal ID alone. Preserve session distinction and define whether
   compound meta-bearing types are excluded from interning. Existing scalar
   `ResolvedFieldIdentity` is a reusable foundation, not another identity to mint.
5. **Frontend ownership and cache scope.** The broad state rewrite is correctly
   closed; the two remaining probes are not unconditional recommendations.
   Graph import admission currently stores no active definition table; binding
   validated authority once is a meaningful prerequisite, subject to its managed
   field cost gate. The cache design must distinguish within-compilation reuse
   from reuse across compilations: persisted products must rebind definitions,
   modules, types and session-sensitive meta facts to current authorities.
   `typecheck_session_for_prepared_module` in
   [`decl.brp`](../blorp/src/compiler/stage_06_typecheck/decl.brp):7506–7514
   already reconstructs context with the supplied meta session.

## Tooling evidence and limits

| Executed check | Result |
| --- | --- |
| `scripts/compiler-identity-census --check` | Failed: 186 new exact sites, 2 unclassified boundaries, 29 increased budgets. |
| `scripts/compiler-identity-census --json` | 3,401 rows; 203 covered source files: typecheck 71, lowering 7, Core 107, backend 18. |
| `scripts/check-magic-spellings --strict` | Passed: 506 allowlisted findings, zero stale. |
| `scripts/check-magic-spellings --report` | 493 deduplicated file/line/role sites; intentional report deduplication explains the different count. |
| Owning Python scanner tests | 43 passed: census 28, magic spellings 15; no skips. |

The census classifies 139 rows as legacy semantic, 720 as legacy source shape,
2,520 as heuristic candidates, 12 as allowed boundaries and 10 as unsupported
static capabilities. Its scope is lexical and limited to those four compiler
phases; 2,441 member reads require receiver typing. It checks path/count coverage,
not a semantic `coverage_complete` predicate. Unsupported metadata names desired
oracles; it does not execute them. A zero lexical budget would not prove identity
continuity, exact target provenance or absence of semantic spelling fallbacks.

`compiler-tools` runs the scanner unit tests and is selected by premerge.
The current source census `--check` has no automatic route through `make
hygiene-check`, default `scripts/test` or the direct CI lanes. Current CI quality
runs `make quality`; its tooling list omits these two owning scanner test modules.
`make hygiene-check` runs the magic scanner without `--strict`, so stale entries
are reported without failure. State explicit strict invocations for roadmap
milestones until enforcement is wired. The scanner's declaration/count keys and
regex wrapping behavior remain lexical limitations, even when strict passes.

All nine explicit roadmap test references/globs resolve; the mono and specialize
globs cover nine and five files respectively. Existing suites are available
owners, not evidence that future identity regressions are already implemented.

Reproduction commands for the Python portion:

```bash
PYTHONDONTWRITEBYTECODE=1 scripts/compiler-identity-census --check
PYTHONDONTWRITEBYTECODE=1 scripts/compiler-identity-census --json
PYTHONDONTWRITEBYTECODE=1 scripts/check-magic-spellings --strict
PYTHONDONTWRITEBYTECODE=1 scripts/check-magic-spellings --report
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v \
  blorp/test/build/test_compiler_identity_census.py \
  blorp/test/build/test_check_magic_spellings.py
```

Raw reports and logs are retained at
`/tmp/blorp-identity-vet-20261005/`: `frontend.md`, `core-backend.md`,
`tooling.md`, `census-check.log`, `census.json`, `magic-strict.log`,
`magic-report.log`, `python-tests.log`, and `tooling-summary.json`.

## Recommended execution order

1. Correct the roadmap's current-state claims and future memo instructions;
   review census drift and restore an explicit green ratchet start. Freeze the
   identity relation, source/generated issuer mapping and paired-frontier API.
2. Probe the selected representation at the actual ownership boundary. Keep the
   probe small; stop at definition authority if the value carrier cannot meet
   the existing ceilings. Select one authored family, carry its exact ID to
   lowering and remove that family's second lexical walk.
3. Complete the atomic Core carrier/handoff and synthetic mint/remap families;
   then migrate one exact-ID consumer at a time, deleting its fallback/index.
   Preserve legacy output identity until the separate emission change.
4. Run disjoint builtin, trait and formatter/name-table cuts independently when
   their issuers are ready. Nominal collision/member work follows its own schema
   prerequisites; it need not await completion of all local-value families.
   Named-type identity precedes semantic interning and type-ID dispatch.
5. Keep the two frontend ownership cuts conditional. Reopen memo/interner work
   only with current source/binary provenance and matched measurements. Node
   summaries, CoreTypeId and blocks retain their separate prerequisites; blocks
   remain last.

For each delivery, require a concrete old lookup/carrier/bridge to disappear,
a failing-before/passing-after regression, and the roadmap's matching output,
ownership and instruction gates. Measure net source reduction as well as new
machinery, but do not compress types or invariants to satisfy a line-count goal.
The historical allocation counts, percentages and expected gains are useful
leads and stop-rule context; they were not remeasured here and do not establish
current ROI.

No native compiler build, compiled suite, sanitizer run, self-compile identity
comparison or performance measurement was performed for this read-only audit.
Those are implementation gates, not results of source inspection. The original
roadmap, source, tests, baseline and allowlist remain unchanged in this checkout.
