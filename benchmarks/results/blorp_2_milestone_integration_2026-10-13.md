# Aggregate milestone integration

Status at design review: reconciliation design only; no conflicts resolved. The user
chose to stop feature development at the validated aggregate milestone and asked
that current `blorp-2` be understood before integration. Lists, updates,
recursive data and further lowering preparation remain future roadmap work.

## Inputs and decision

The feature checkout is `codex/blorp-2-aggregate-roadmap`, based at `79deebd`,
checkpointed as `14fc4b9c9` after independent acceptance reviews.
Its seven accepted slices cover mixed finite records, contextual inference,
owned match prefixes, generic records, ordinary union payload types, multiple
ordered payload fields and local ownership-use builders. Final validation is
1,985 sanitized unit/runtime/grammar checks and 321 e2e cases, with two final
independent expert approvals per slice. The individual retained reports own the
precise evidence and limitations; these passes do not establish integration
correctness.

The target was audited at `c38fb3d2da4590fa47f140d6a56cf6efc5aa33fb` and refreshed
to `3f98023dcae6a52411687c1143a17ca281a70330` before this design. The refresh has
no pilot source changes: it adds host cancellation planning and ownership-test
repairs, census updates, a test-support rename and small historical prose edits.
Keep all of those changes. Common ancestry is `98983aa8f512116239a202e66ad7b5cc556c4fec`;
divergent commit counts include rebased history and do not measure semantic work.

Use the target's architecture and module policy. Transplant the accepted feature
behavior into its owners; do not restore our monolithic checker/parser, add a
compatibility layer or choose whole-file ours/theirs. Preserve the validated
feature checkout and integrate in a separate managed worktree at a frozen target
revision. Inspect target advancement again before landing. Do not overwrite the
separate checkout that currently owns local `blorp-2`.

Read-only audit artifacts are under `build/roadmap/integration-target/`:
`typechecker-audit.md`, `frontend-audit.md` and
`frontend-migration-inventory.json`. They contain source anchors, the complete
mechanical inventory and tests whose behavior differs intentionally. The
maintained acceptance contract is below; ignored audit files are supporting
working evidence rather than a new framework.

## Preserve target authorities

| Boundary | Required integration |
| --- | --- |
| Lexer and parser | Keep target Newline/Indent/Dedent and Spacing tokens, original byte spans, trivia and EOF behavior. Port only generic record parameters, ordinary ordered variant type annotations and positional pattern fields into its existing parser leaves. |
| Assembly | `parse_module` publishes ParsedModule; `assemble.append_module` and `seal_program` exclusively publish the complete ParsedProgram and linked imports. Remove the moved parse-owned assembly API. |
| Loading and namespace | Keep deterministic cycle rejection, explicit library `_base` imports, prohibited explicit prelude imports and library-to-user imports. User modules alone receive selected prelude visibility. Preserve `_base.brp`/`prelude.brp`, with no legacy path or implicit primitive repair. |
| Checked declarations | Keep target CheckedField and CheckedVariant wrappers, including declaration identities and WrittenNames. Extend record parameters and replace the variant payload with ordered TypeUse fields. FieldId remains checked-model-owned; concrete layout IDs are specialization-owned. |
| Checking | Keep target orchestration/sealing API and grouped errors. Put the single temporary solver/pending elaboration/freeze engine privately in check_values; keep arity/purity contracts in check_calls and body bindings in check_bodies. Retire the replaced eager inference paths in the same slice. |
| Specialization onward | Translate complete checked facts to concrete instance identities, preserving ordered field occurrences, phantom arguments, managed children and separate ownership obligations. Port accepted lower/own/verify/emit changes and adapt imports to assemble/check_model/builtins. |
| Host compiler | Preserve all target Core/backend changes and tests. Rebuild the host in the integration worktree; old generated-host-C proof is insufficient for the new host sources. |

Target dependency direction remains model/errors -> declaration types ->
builtins/signatures -> call/method contracts -> values -> bodies, with separate
rendering and recursion consumers. Do not expose expression-local variables in
published facts or make check_calls depend on check_values. The checker retains
complete expected TypeUse data for generic field errors rather than reconstructing
types from spans or spellings. Both constructor-child recursion observers must
visit every field, including unused and non-tail children. Both actual branches
still reject generic `@tail_recursive`; this integration does not expand it.

For example, preserve the target wrapper while extending its payload:

```blorp
fixed record CheckedVariant {
    id: VariantId,
    name: WrittenName,
    fields: List[TypeUse]
}

fixed union Pair[A, B]:
    Pair(A, B)
pure func make[T](value: T) -> Pair[T, Int]:
    Pair(value, 7)
```

The declaration keeps union-owned A/B; `make` keeps function-owned T. Substitution
is simultaneous and owner-qualified. `Pair(value, value)` retains two ordered
storage obligations even though both reads have the same value identity. Pattern
`Pair(_, second)` skips ordinal zero and binds ordinal one; ownership preparation
separately discharges storage obligations. Neither field names nor
a solved bare inference variable may invent a nominal record owner.

## Tests, docs and intentional expectation changes

Keep both sides' meaningful cases. Preserve target layout/provenance, assembly,
namespace, cycle, explicit foundation, checker-model/error/signature and recursion
suites. Preserve our granular accepted-feature, malformed ownership IR, raw
verifier, real-allocation runtime and normal-main e2e cases. Migrate imports and
typed expected products, not their semantic observations. Target TestFoundation
explicitly separates types and prelude selections; change all test builders
coherently before interpreting setup failures.

Our cycle-acceptance tests become the target's exact closing-import rejection
cases. Generic UFCS and ordinary finite payload/record restriction tests become
the accepted positives, with exact owner/arity/admission negatives retained.
Bare-T/contextless record literals remain rejected. Ordered arity, duplicate
binder spans/notes and complete expected generic types remain exact assertions.
If combined tests reveal an unplanned diagnostic-priority disagreement, stop at
the owning boundary for a decision rather than quietly changing the oracle.

Add combined cases for imported Box/Pair with written library `_base` imports,
second-field annotation origin, wildcard-zero/capture-one, nested type commas,
trivia between variants/arms, EOF without LF, nullary variants between nonempty
ones and cycles combined with parser/semantic errors. Each must observe the
intended boundary, not fail earlier in helper setup.

Keep target concise agent principles and merge the already-approved direct
aggregate runtime-helper C-test exception. Consolidated ROADMAP replaces retired
plans while preserving future work. Keep target structural EBNF/import prose;
extend only accepted productions and capability descriptions. Preserve the
target's recent historical document edits while redirecting retired plan links.

## Exclusive implementation owners

Root assigns these roles before source migration. Each file has one writer;
other owners send requested changes through root instead of editing it.

| Owner | Exclusive files and responsibilities |
| --- | --- |
| Frontend | syntax/lex/parse/assemble/load/namespace/builtins; shared unit helpers module_input/input/compilation; frontend/layout/assembly/import/foundation unit suites and grammar tests; e2e import/frontend/string-foundation suites and import fixtures. Preserve existing target foundations. Prepare EBNF changes for root to apply. |
| Checker | check and all check_* modules; checking/signature/method/recursion/record/generic/contextual/direct-payload/multiple-field semantic suites, including mixed phase assertions and manual method-visibility builders; corresponding feature e2e suites and fixtures outside import fixtures. |
| Backend and ownership | specialize/lower/own/verify/emit; ownership_inputs/managed_union_inputs; dedicated specialization/lowering/ownership/verifier/emitter and raw suites; all runtime-helper suites and fixtures. Request mixed semantic suite changes from checker. |
| Root | main/build/registration/harness/caps/test_main; AGENTS/README/EBNF/ROADMAP/reports; baseline and final provenance, costs and gates; coordination and landing. Assign any unlisted file before editing. |

The frontend publishes the target TestFoundation and assemble APIs plus widened
syntax carriers first. Checker freezes checked-model/error schemas for backend
consumption, preserving wrappers and complete expected TypeUse. Each sole writer
applies its own assembly/builtins import and test-foundation changes from the
frontend inventory. Shared helper changes go to frontend; cross-owner bulk
replacements are prohibited. No compiled feedback until affected consumers agree
on the frozen schemas, and root serializes all compiled gates.

## Sequence and acceptance

1. Independently review this reconciliation design and checkpoint the accepted
   milestone without touching unrelated worktrees. Freeze a current-target
   integration worktree and target baseline source/library/compiler provenance.
2. Rebuild target host and require FRESH. Establish the existing target's narrow
   parser/checker/module tests before feature migration. No parallel compiled
   gates on the shared macOS machine.
3. Port syntax/accepted model facts, then declaration/signature/builtin rules,
   then private expression elaboration/capture/recursion rules. Reconcile later
   consumers and test foundations with explicit file ownership. No second parser,
   checker, inventory, fallback or registry.
4. Run narrow tests while adapting, then all sanitized unit/runtime/grammar and
   the normal e2e wrapper. The wrapper builds the pilot once at O0 and runs each
   fixture's unmodified emitted C through its real main. Record exact diagnostics,
   no-publication failures, counts and source/toolchain fingerprints using the
   existing recorder.
5. Inspect fresh generated C for representative managed mixed/generic records,
   direct/multiple payloads, repeated children, borrowed projections and match
   prefixes. Re-establish the ownership builder's bounded physical copying with
   the integrated host, using actual Core identities rather than old C symbols.
6. Require independent compiler-expert code review and test-evidence review of
   the combined result, zero outstanding correctness findings, accurate docs,
   `git diff --check` and proportionate repository landing gates. Record any
   inherited limitation explicitly. Recheck remote drift before actual landing.

Runnable broad pilot gates after host freshness is established:

```sh
bin/blorp test --suite --sanitize --leak-check --timeout 180 \
    blorp_2/test/unit blorp_2/test/runtime blorp_2/test/test_grammar
bin/blorp test --suite --timeout 0 blorp_2/test/e2e
```

No old passing count substitutes for the combined result. Keep direct C tests
limited to the approved runtime helpers; do not call generated language functions
or rewrite fixture inputs. Native LeakSanitizer remains unavailable on this host;
ASan/UBSan, compiler counters and allocation-occurrence tests are separate proof.

## Cost contract

The prior accepted-branch costs remain their own evidence. Do not adapt its old
foundation library to fabricate a comparison with the new target's import policy.
Instead freeze the current target compiler/library and compare the common
supported control programs against the integrated candidate, using that same
library and host toolchain. Classify every one of the 20 existing frozen controls
against the actual target baseline before migration, retaining exact rejections.
The four nested-record `fields-{16,32,64,128}.brp` controls are known to exceed its
Int-only record rule; do not call them common or rewrite their inputs. Other
acceptance must be demonstrated rather than assumed.

Retain the existing +3% allocation and retired-instruction ceilings for every
baseline-positive control, three matched paired samples, stable allocation counts
and minimum-of-three instructions. Keep all 20 original control inputs; rejected
controls receive candidate-only observations, not replacement workloads or a
fabricated common-input count. Do not raise ceilings to land. Classify
intentional layout/identity changes before interpreting generated-C differences;
unchanged paths require output identity, changed layouts require exact native,
layout and ownership equivalence. Unsupported new aggregate feature workloads
get candidate-only width/cost observations, not fabricated baseline successes.
Keep existing e2e caps. Record source/binary/C/flags/input hashes, raw samples,
sampled machine activity and production/test LOC separately. These are supported
input proxies until self-compilation is possible; they do not prove global
linearity. Investigate repeatable excess at the owning phase before proceeding.

## Handback and stop rules

Each owner returns its precise files, source/binary evidence, test results,
intentional changed expectations, unresolved findings and cost limitations to the
root coordinator. Only the coordinator integrates/commits/lands. Stop and report
if a public fact would lose target identity/provenance, a feature needs an
unapproved mechanism, a host ownership issue prevents valid evidence, a cost
ceiling fails or target advancement changes the contract. This integration does
not authorize later roadmap features or automatic publication.
