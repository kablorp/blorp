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

## Prospective correction to the integration cost comparison

The original whole-CLI +3% criterion above was incorrectly based on the
pre-feature target. It measures the accepted contextual-inference feature as
well as integration. The contextual-inference report already records substantial
overhead against its pre-feature compiler, including +40.76% allocations and
+22.08% instructions for ufcs-128; its accepted repair ceilings used a feature
draft, not that older compiler. The target comparison is still retained as
feature-growth evidence. Its failed ceiling is not retroactively a pass.

Before the equality repair and final measurements, the integration criterion is
explicitly rescoped to the existing source-to-C `compilation.compile(source)`
API against immutable accepted feature `14fc4b9c9`, with the same fresh host,
identical benchmark driver, unchanged source inputs, O0 diagnostic link flags,
three paired samples, stable allocations, minimum instructions and strict
allocation balance. Keep +3% for both metrics per common input. No cap is raised.
Both independent reviewers approved this narrower measurement scope before
execution. Final acceptance also requires independent review of this amendment
and the measured results; a failing corrected comparison still blocks landing.

The primitive foundation implementations intentionally differ: the target
assembles explicit prelude selections, whereas the accepted feature used its
earlier foundation policy. That real integration work remains in the measured
cost. This is not identical parsed input, a post-parse benchmark, or a claim
about whole-CLI filesystem/module-loading performance. It includes source read,
lexing, parsing, foundation construction, checking through C emission and output
write. All 20 unchanged controls and the eight primitive-only fields-int/captures
feature inputs must succeed on both variants. Other feature inputs are excluded
because they require target-library operations; none are rewritten.

The first additional comparison passes strict balance and C identity for all
28 inputs but fails the corrected cost guard. Constructors-128 grows +25.49%
allocations/+7.43% instructions; wrap-128 grows +12.73%/+4.05%. Independent
source review and prefix probes isolate the added cost to typechecking:
constructor allocation excess at widths 16/32/64/128 is 415/1,855/7,807/31,999,
exactly `2*n*n - 6*n - 1`. Lexing/parsing allocate less. The target-derived
`check_model.same_types` constructs both list tails on each recursive comparison;
the accepted feature used indexed traversal. The bounded repair keeps the
public model/module boundaries and restores traversal without copied tails.
Leaf type projection is outside that repair. These failed observations remain
under `build/roadmap-integration/phase-cost/`, separate from final repair results.

## Observed integration baseline and review findings

Integration is isolated on `codex/blorp-2-aggregate-integration` at the managed
`aggregate-milestone-integration` worktree. The original feature checkout is
clean and checkpointed. A separate local checkout owns an older `blorp-2` plus
substantial staged work; it is untouched. The integration input is frozen
`origin/blorp-2` at `3f98023d`.

The fresh target host is FRESH (SHA `7c28b09440cfabed7bd4140f6dd46287f9fe82be43f1cec56cc6156ba712c900`),
CLI O0/runtime O2, Apple Clang 21 arm64. Its baseline sanitized unit/runtime/
grammar run passes 1,702 checks across 119 summaries. The O0 diagnostic pilot
baseline is `c0213d6893744c4f2ed924864914739f04dfe518029ee069776824e1a7253a38`,
generated C `1788efc1a50f22ece1b5934961aa4cbd05a5dc3775df2277055c092907ead4ff`.
It compiles 16 unchanged control programs and rejects exactly the four nested
record controls at the existing Int-only declaration rule, without publishing C.
The baseline pilot link has 55 warnings; it is not warning-clean. These artifacts
and all baseline packets are retained under `build/roadmap-integration/`.

The focused combined frontend run passes all 125 callbacks: five new aggregate
syntax/assembly cases, 29 load cases including three new error-order cases,
74 conformance cases and 17 record grammar cases. The complete production entry
source also passes host type checking. Neither result establishes the combined
milestone until the final gates below are complete.

Independent review found an actual inherited inference-policy defect in both
record literals and union constructors. An earlier nested record argument could
solve a shared generic variable before a later bare-parameter argument was
planned. Following that solution selected a nominal owner that the supplied
hint had not established. A retained red packet proves both programs were
accepted using two positive controls while their exact rejection assertions
failed. Restricting owner selection to the supplied structural hint restores
the documented rule. Known nominal heads and explicit expected-result hints
remain valid; four new callbacks cover both negative and positive forms.
The focused generic-record suite then passes all 35 callbacks. This is a real
semantic issue, distinct from test-authoring mistakes.

Review also identified repeated closed-signature admission and an unread return
type in call publication. The bounded remedy publishes a CheckedCall directly
and removes duplicate admission inside publication, preserving
child, substitution, parameter, return/purity and argument error order. It adds
no inference state or phase. Closed-readiness validation and child-first freeze
remain distinct boundaries; this is not a global validate-once claim. Both remedies together pass 140 focused checks
across six suites, without source drift. Final source/evidence review and
combined gates remain required.

Two source-check repairs are recorded separately: reserved local names and a
fallback indentation in a new parser test, and a missing Own import in an
existing phase test. Embedded input programs and assertions are unchanged.
The first broad integrated strict run stopped on that missing import before
callbacks; it is a failed setup run, not a passing compiler test gate.

## Final integration outcome

The candidate preserves the current target's structural layout tokens,
parse-module/assembly boundary, explicit base/prelude policy, deterministic
loading/error order, thirteen checker modules, complete accepted declaration
wrappers/spans and private expression-local inference. It carries the accepted
finite aggregate/contextual-inference milestone through those boundaries.
General lists, record updates, recursive data and broader tail-call work remain
later increments. No host compiler, runtime, census, library or main-signature
changes from the target are reverted. The unrelated staged local `blorp-2`
checkout remains untouched.

The final equality repair changes only `check_model.same_types`: ordered indexed
traversal replaces recursive list-tail construction. Its public export,
`same_type` and namespace leaf projection remain intact. Actual old generated C
contains two `blorp_list_drop` calls, whose runtime allocates even empty tails;
the final generated function contains zero. Direct tests cover empty/unequal
vectors, ordering, nested record/union/List types and rigid parameter ownership.
The retained failing cost series precedes the repair; a failing semantic test
is not invented for this semantics-preserving performance correction.

Final validation, serialized on the same FRESH target host:

| Boundary | Result | Evidence packet |
| --- | --- | --- |
| Model/contextual/generic focused suites | 83 checks, 0 failures | `checker-equality/focused` |
| Sanitized unit/runtime/grammar | 2,031 checks, 136 summaries, 25.269 s | `strict-final` |
| Real-main e2e | 322 cases, 0 failures, 173.685 s | `e2e-final` |
| Accepted-feature → integration source-to-C API | 28 inputs, 168 balanced runs, all within both +3% caps | `phase-cost-final-packet` |
| Target → final CLI feature-growth observations | 36 inputs, 156 balanced runs; descriptive, not the integration guard | `cost-final-packet` |
| Fresh actual host Core/C | C identical to e2e wrapper C | `final-host-core` |

All packets are under `build/roadmap-integration/`. The final source-consuming
gates have no timeout or source drift. The e2e wrapper logs exactly one Generate
and one Link; 763 printed PASS lines across 309 nested summaries are distinct
from its 322 grouped cases. Actual fixture C is compiled at O0 with ASan/UBSan.
Runtime helper tests observe real allocation/free calls. Launcher strict counts,
target runtime tests and consuming-setter proofs are different evidence; native
LSan is unavailable here. The target's ordinary C link has 55 warnings; the
pre-repair candidate link and final C syntax check both have 71: three discarded
qualifier, 59 equality-parentheses and nine pointer/integer-comparison warnings.
The increase is 16 equality-parentheses warnings. Generated C is not warning-clean;
warning cleanup remains out of scope. Counts alone do not establish the safety
of the inherited warning categories. `final-c-warnings` retains the final check.

For the corrected API comparison, every one of the 28 unchanged inputs produces
identical C on both compilers. Allocation counts are stable across three paired
samples and improve by 0.37–15.31%; minimum retired instructions improve by
0.67–19.79%. These are observed supported-input proxies, not a whole-compiler
speedup or global linearity proof. Both reviewers independently recomputed all
168 raw samples, checked the executed binary hashes and all 478 source-manifest
entries. The 91-file host standard-library inventories match byte-for-byte.
Original and final fixture hashes agree; no source or entrypoint is rewritten.

The final whole-CLI comparison still reflects accepted feature overhead against
the pre-feature target: ufcs-128 observes +34.97% allocations/+19.88% instructions,
while constructors-128 observes -7.88%/-1.67%. It does not pass the original
pre-feature +3% criterion, which was explicitly rescoped above. Earlier failed
CLI and API series remain retained. Eight common CLI outputs are byte-identical;
eight constructor/wrap outputs intentionally reflect changed aggregate layouts.
Their native behavior and layout/ownership contracts are covered independently.

Final real-main C SHA is
`764e0912addab8a4db29dbe1c7e2e677f1e6811a019254151c570a544fa01525`;
e2e executable SHA is
`2f6c8a0f5188336ccb944281dcdd2d4e4a661802d80d66168f89c36b7ae3b508`;
fresh Perceus Core SHA is
`9568f006698bc6620ee0a91dcaeb654db5ca8ae3c45cab0d06ab4d7841b00a98`.
The refreshed actual Core/C map retains `own.exit_last_uses` declaration 1704,
its local roots 6806/8768 and consumed setter argument 0. Complete emitted
`brp_ru` and `brp_14H` bodies are byte-identical before/after equality repair:
local updates add no root retain; terminal aliasing permits one initial O(V)
copy. `C-ownership.md` retains actual positions and extracted function evidence.

Final benchmark binaries: accepted feature
`0097cc87191559cd59dc46df8f093449e836d99ad3c20afdfdfcd944b51e9b66`,
integrated API candidate
`61fb9ab2f416c1052dedb119e014aa4a30090977aab2d445cb51473272c5fc06`.
The production/test/grammar archive SHA is
`33266cf257eeab64808c1e31780b8ff2aee3ebd7d368f005bedf0599483c5128`.
Later report edits do not alter those frozen source inputs.

Physical handwritten line totals cover `blorp_2/src` and `blorp_2/test` only,
counting `.brp`/`.c`/`.h`, including comments and blank lines. They exclude
`standard_library_temp`, generated build files and the rest of the repository:

| Snapshot | Production | Tests/fixtures/runtime drivers |
| --- | ---: | ---: |
| Target `3f98023d` | 17,961 | 57,933 |
| Accepted feature `14fc4b9c9` | 21,911 | 67,544 |
| Integrated milestone | 21,443 | 68,460 |

The integrated milestone is 468 production lines smaller than the accepted
feature while adding 916 test lines. Relative to the pre-feature target it adds
3,482 production and 10,527 test lines for the accepted capabilities. The narrow
equality repair itself adds nine production and 51 test lines; the traversal
cost is fixed rather than hidden by compressed formatting.

Two independent compiler-expert reviewers approve the final source, corrected
cost contract, tests and fresh executable/ownership evidence with zero remaining
P0–P3 findings. Their final notes are `final-review-1.md` and `final-review-2.md`
under the evidence root. This milestone does not authorize later roadmap work
or automatic publication.
