# Caller-selected trait evidence: design and preparatory evidence

Status: the historical matcher/source-packet preparation was independently
accepted and integrated. The successor producer foundation is integrated;
the lexical-slot slice has independent approval, pending checkpoint integration;
recursive evidence selection and caller dispatch remain pending. Historical
reproduction below used `dde591ecd0ba7029f98ef6bfc6f3604b5451d2a5` before edits.
The successor source base is `a78dccbd665d5c7acb115ec914f2f4970bb370cd`, with
bootstrap `dev-c3040e79c7d8`; these are distinct evidence epochs.
This does not publish automatic Eq/Hash, change orphan admission, or close P2a.

## Existing seam and proposed ownership

`infer.brp:check_call_trait_bounds_for_params` checks each
`BoundTypeParam.bound_identities` against the caller's accepted module authority,
but retains only satisfaction. `ResolvedCallInfo` retains declared bound
parameters, not their evidence. `TypedFunctionInfo.effective_type_params` retains
those nominal identities. `lower.brp` emits `SelectedDirectCall(Int)` and
`CoreFunction.type_params: List[String]`; `CoreMonoInstanceKey` contains only
base definition and concrete type/dimension arguments. `CoreImplDecl` retains
trait/bound spellings, while generic implementation requests deduplicate by
trait spelling and receiver. These are independent points where evidence is lost.

The accepted table already owns `AcceptedImplementationTableRecord.id: ImplId`,
`trait_id: TraitId`, `method_ids: List[CallableId]`, implementation bounds, and
the derived mapping from methods to `TraitMethodId`. Source matching belongs in
`type_system/accepted_trait_implementation_authority.brp`; it must not expose
the private table representation or let inference assemble an implementation
identity from a spelling. It issues an opaque validated implementation-match
packet, including the one shared pattern substitution and dependency positions.
A small `type_system/trait_evidence.brp` owns the typed evidence product,
recursive selection and validated trait+union semantic context. It imports the
authority; the authority does not import it. `infer.brp` attaches evidence;
`decl.brp` supplies lexical slots;
`lower.brp` validates and translates it; `ir.brp` owns the Core product;
`mono_instance.brp` owns canonical equality/hash; `mono_specialize.brp` and
`mono_impl.brp` instantiate it. `trait_resolve.brp` consumes exact closed members.
One implementer owns this whole seam.

The following signatures are proposed additions, not existing APIs:

```blorp
-- A slot belongs to one lexical callable, including an implementation method.
-- ValidatedUnindexedCallableIdentity is an explicit phase product to be
-- established from the existing unindexed-callable mapping, not a name/span.
union LexicalTraitEvidenceOwner:
    AcceptedEvidenceOwner(CallableId)
    UnindexedEvidenceOwner(ValidatedUnindexedCallableIdentity)

record TraitBoundSlot {
    owner: LexicalTraitEvidenceOwner,
    parameter_index: Int,
    bound_index: Int
}

-- Compiler members have an explicitly validated registry identity; no fake
-- CallableId stands for a native operation or enum tag comparison.
union TraitMemberIdentity:
    SourceTraitMember(TraitMethodId)
    CompilerTraitMember(CompilerTraitMemberId)

union TraitMemberTarget:
    SourceTraitMemberTarget(CallableId)
    CompilerTraitMemberTarget(CompilerTraitCapability)

record SelectedTraitMember {
    member: TraitMemberIdentity,
    target: TraitMemberTarget
}

record SourceTraitEvidence {
    implementation: ImplId,
    receiver: SemanticType,
    members: List[SelectedTraitMember],
    dependencies: List[TraitEvidenceArgument]
}

union TraitEvidence:
    SourceImplementation(SourceTraitEvidence)
    CompilerProvided(CompilerTraitEvidence)
    ForwardedBound(TraitBoundSlot)

record TraitEvidenceArgument {
    -- Position in the callee's effective parameter/bound declarations.
    parameter_index: Int,
    bound_index: Int,
    evidence: TraitEvidence
}

union TraitEvidenceSelection:
    SelectedTraitEvidence(TraitEvidence)
    DeferredTraitEvidence(SemanticType)
    UnsatisfiedTraitEvidence

pure func select_trait_evidence(
    context: AcceptedTraitEvidenceContext,
    env: Env,
    typ: SemanticType,
    identity: BoundTraitIdentity,
    lexical_slots: List[ResolvedTraitBoundSlot],
) -> Result[TraitEvidenceSelection, String]
```

The implemented preparatory smart-construction APIs are specified below. Selection outcomes are
selected/deferred/unsatisfied; malformed issuer or facts use `Err`, with no
duplicate invalid-selection variant.

`CompilerTraitCapability` and `CompilerTraitEvidence` must enumerate the
existing compiler-provided rules that this slice encounters, with exact trait
and member identity and recursive dependencies where the rule has them.
They cannot mean "try the old global registry later".
`CompilerTraitMemberId` is an opaque `(TraitId, member ordinal)` validated by
the builtin trait registry's actual method sequence; no second name table is
invented. Its ID has compilation-registry lifetime. Source default bodies already have
issued materialized callable IDs: they remain source member targets, with the
declaring `TraitMethodId` preserved. Inherited projection retains that declaring
member rather than rewriting it to the requesting subtrait's spelling.

Compiler-provided evidence needs a concrete rule vocabulary, proposed as
`InstalledBuiltinImplementation` (validated builtin trait/member registry rows),
`FieldlessEnumCapability` (issued nominal enum declaration identity),
`StructuralEqualityCapability` (the existing explicitly admitted structural
representation), and `ArrayCapability` (existing Eq/Stringable/HasLength rules).
Each records its validated requested trait, receiver and dependencies. Actual
member dispatch uses an explicit native binary/unary operation or an installed
builtin registry member. These are rule identities; they cannot stand in for
source implementation evidence. Traits with no compiler fallback use the same
source evidence mechanism. The rule vocabulary must be reconciled with all
`env_resolve_trait_obligation` paths before making evidence mandatory.

`ResolvedTraitBoundSlot` records the slot plus the existing bound identity;
slot construction needs the lexical callable ID and effective parameter order
from declaration/body setup. Current `InferContext` alone does not carry that
owner, so this must be threaded explicitly through the inference session's
lexical generic context. Standalone/unindexed test contexts need an explicitly
unindexed slot domain, not a fabricated graph `CallableId`. Its lowering may
use the existing validated unindexed callable identity domain. This detail
must be settled before construction code is written.

## Issued identity and construction rules

The authority validates issuer provenance with its table and the supplied
`DefinitionTable`. Source selections refer only to an applicable visible
accepted implementation and its actual accepted method mapping. Recursive
implementation-bound evidence is selected in the same caller authority after
substituting the implementation's pattern parameters. Reuse/expose the existing
`env.brp` pattern substitution boundary; do not reimplement matching heuristics.
The current callback only returns Bool; it must return a structured match and
dependency product if evidence is to survive it.

An unresolved inference meta is explicitly deferred, then finalized after
zonking and before CTFE/lowering. A satisfied Boolean is insufficient to mint
an evidence product. Missing/conflicting issued rows yield an internal
diagnostic. An inapplicable implementation never supplies evidence. Selection
order/admission is preserved; no new global lookup or rejecting previously
legal programs to make the producer easier.

Forwarding finds the exact lexical bound slot that proves the obligation.
Supertrait forwarding includes explicit declaring-member projection. It must
not find a slot using a same-spelled trait or choose again in the callee's
module. Cyclic dependency proof attempts fail through an explicit visited
obligation path, with no arbitrary recursion limit as the proof.

## Approved transport seam

Add `trait_evidence: List[TraitEvidenceArgument]` to `ResolvedCallInfo`, with
empty arguments for unbounded calls. Preserve it in call-info equality,
instantiation, zonking, typed serialization, and CTFE materialization copies.
Typed operator checking must attach a member selection to operator metadata;
the current `TypedBinaryExpr -> BinaryExpr` route loses it. A compiler operation
stays a native operation when its selected capability says so.

Proposed Core direct-call payload:

```blorp
record CoreDirectCall {
    def_id: Int,
    trait_evidence: List[CoreTraitEvidenceArgument]
}

-- Existing constructor becomes SelectedDirectCall(CoreDirectCall).
-- CoreFunction gains trait_bound_slots in canonical declaration order.
-- CoreImplDecl gains issued implementation/trait identity and bound slots.
```

The coordinator approved this single direct-call route. It requires mechanical migrations:
`SelectedDirectCall` currently occurs in 30 production modules. Central
construction/access/update functions preserve the callee-ID invariant.
Unbounded calls use empty evidence arguments; measure construction costs at the
first usable checkpoint before further representation changes. A location-keyed
side table is insufficient: clones share locations but may carry distinct
selections. Existing string bounds remain diagnostic/binding metadata until
separately retired; selected evidence is authoritative for dispatch.

Core evidence is the phase-specific translation of the typed product:
SemanticType becomes CoreType; issued callable IDs become validated runtime
definition IDs; source implementation/trait/member identities remain canonical
IDs. It must contain receiver substitutions for generic implementation
materialization. The conversion is explicit, not a second selection.

## Specialization and dispatch

Canonical function key becomes `(base_def_id, type/dimension arguments,
closed trait evidence arguments)`. Bound arguments are ordered by callee
parameter and bound position. Canonical evidence contains exact source
implementation/member identity, normalized concrete receiver arguments, and
ordered recursive dependencies, or an explicit compiler capability identity.
Diagnostic text, display module/name, source spans and lexical forwarding-slot
IDs are not closed evidence identity. Structural equality and hash use the same
fields; equivalent selections reuse and different selections separate.

During specialization, substitute lexical forwarding slots from the instance's
evidence environment before scanning nested calls. A closed instance cannot
retain an unresolved slot. Recursive self-call reuse is allowed only when the
whole instance key agrees: the current unconditional source-ID self rewrite
must not force a differently witnessed recursive call to the current instance.

Generic implementation request identity also includes issued template identity,
concrete receiver/substitution, and closed dependency evidence. Its current
`trait_name + receiver` key is insufficient. Materialized method bodies carry
that dependency environment, and the selected source-to-concrete method remap
must distinguish those environments as well as receiver; two witnessed
instances cannot collapse into one remap row. Source members stay exact until
the existing final receiver-aware remap is extended to this key.

Trait member dispatch projects the selected member from evidence and invokes
the exact source callable or compiler capability. It does not ask the global
trait/type registry to choose another implementation. Default/inherited member
bodies receive dependency/member evidence under their lexical slots, including
calls such as default `not_equals -> equals`.

Bound member calls need an explicit Core target containing lexical slot and
declaring member identity; keeping only `DeferredTraitCall` strings would leave
namesake substitution possible. `mono_substitute.brp` currently desugars
binary nodes after type substitution, including operands that become String.
That rewrite must apply only when selected compiler evidence authorizes it;
type substitution cannot overwrite an explicitly selected source member.

| Consumer | Required change |
| --- | --- |
| accepted authority | return applicable implementation plus recursive dependency proof, with issued IDs |
| infer bound check and finalization | retain closed/forwarded arguments; resolve deferred metas before transfer |
| decl body context | issue lexical slots from actual callable and effective bound order |
| typed metadata copies/JSON | preserve and inspect evidence without rebuilding selection |
| Core lower and pre-mono traversals | validate IDs; preserve evidence and exact member projection through flatten/desugar |
| mono_instance | structural evidence equality/hash in instance identity |
| mono_specialize | close slots before nested request collection; witness-aware self calls |
| mono_impl and final remap | evidence-aware impl materialization and source-member instance mapping |
| mono_substitute | rewrite types inside receivers/dependencies; native desugar only with authorization |
| trait_resolve | consume exact selected source/native members; fail closed for malformed facts |
| CTFE IR/evaluation/materialize | carry the same evidence product/environment; track unsupported folding precisely |
| closure/eta/runtime callback synthesis | preserve lexical capture and bind the selected closed member |

## Literate oracle

```blorp
pure func same[T: Equatable](left: T, right: T) -> Bool:
    left == right

pure func forwarded[T: Equatable](left: T, right: T) -> Bool:
    same(left, right)
```

At `provider_same`, caller authority selects the lawful provider-private
`Choice` implementation. The first call carries that implementation's member
targets. The `forwarded -> same` call carries `ForwardedBound` for forwarded's
lexical `T: Equatable` slot. Mono substitutes the same closed product; the
specialized `same` equality resolves its member from that evidence.

An importer selects the existing compiler tag capability for the same enum.
It receives a distinct `forwarded` and `same` instance for identical concrete
types. Repeating the provider call reuses the provider instances. This general
mechanism must also pass user-defined Selector and Stringable target controls.
Nongeneric direct private enum dispatch is a separate existing defect and
separate assertion; generic key work alone does not establish direct privacy.

## Compatibility obligations and staged consumers

| Existing program | Evidence obligation | First slice requirement |
| --- | --- | --- |
| List[T: Equatable] equality | element evidence inside selected generic impl | retain dependencies and include them in impl/method keys |
| Option[T: Equatable] equality | payload evidence inside selected generic impl | same producer and forwarding rules as List |
| units Eq/Orderable | issued source/default members and inner default calls | carry actual default targets; no missing-target rejection |
| tuple ordering | Orderable evidence projects inherited Equatable member | retain declaring member and dependency identity |
| Dict/Set Stringable | formatting closures capture key/value evidence | preserve existing behavior; static capture closure is an explicit follow-up obligation |
| CTFE direct/generic calls | evaluator receives the same evidence environment | preserve existing supported evaluations; agreement remains a separate acceptance checkpoint |
| generated runtime callbacks | exact closed member/dependencies select callback | preserve existing callbacks; closure before automatic publication |
| higher-order functions | evidence travels through closure/eta/hoist specialization | existing paths remain legal; static evidence capture closure is staged |

The first acceptance cut must prove direct/nested generic runtime calls,
source/compiler evidence, dependency transport encountered by those calls,
canonical function/implementation/remap identity, and CTFE/runtime agreement for
the already-supported pure control programs. It cannot invent placeholder
evidence for encountered defaults/inherited paths. It must not reject ordinary
supported programs on a staged path. If a path cannot preserve evidence without
further implementation, report it before expanding scope; do not silently
discard that evidence. Full CTFE/callback/default/inherited closure remains
required before automatic Eq/Hash publication.

## Red and validation packet

The unchanged O2 base was rebuilt and confirmed FRESH; actual current outputs
are recorded below. Historical retained evidence is not current reproduction. Add exact assertions,
non-Eq controls, namesake/alias/bounds and declaration/module-order controls.

Shortest code feedback: trait-authority/evidence producer tests; mono key
identity tests; `test_core_mono_impl`, `test_core_trait_resolve`,
`test_core_mono_data`; the selected runtime source oracle. Broader acceptance
requires changed-owner gates, standard/runtime/leak/Core ASan, generated-C audit,
unmodified O2 stage2/3 fixpoint, and independent review. Record matched quiet
current-base allocations/instructions before any performance conclusion.

Approved lexical-owner domain: accepted `CallableId` versus explicitly validated
unindexed callable identity; lowering uses the existing runtime-ID mappings.
Never derive owner from name/span or fabricate a graph ID. Closed evidence keys
exclude the lexical owner. Full callback/higher-order closure is staged, with
no existing legality regression or dropped captured static evidence. Before
the broad migration, submit concrete producer/key APIs and red test drafts.

## Implemented preparatory owner seam

`env.brp` owns `opaque ImplementationPatternMatch = List[SemanticTypeSubstEntry]`.
`implementation_pattern_match(for_type, bounds, typ)` returns `Option` of the
existing matcher's exact substitution. `implementation_pattern_match_substitution`
exposes that list. `implementation_pattern_match_dependencies(matched, bounds)`
interprets supplied bound metadata in parameter/bound declaration order; it does
not validate arbitrary bounds. Rows are `InstantiatedBoundDependency(position,
type, identity)` or `UninstantiatedBoundDependency(position, identity)`, where
`position` is `{parameter_index, bound_index}`. The latter preserves existing
phantom admission, not a complete closed proof.

The current Bool applicability query retains its direct `types_equal` no-bounds
branch. Bounded applicability uses the shared match, then
`implementation_pattern_match_bounds_satisfied(matched, bounds, callback)`;
the original nested loop, missing-substitution behavior and first-failure
short circuit are unchanged. It allocates no dependency rows. Only requested
dependency projection creates a list and one position/variant per declared bound.
The bounded path introduces an Option projection around the existing substitution
list; construction cost remains a measurement obligation, not a speed claim.

`accepted_trait_implementation_authority.brp` alone smart-constructs opaque
`AcceptedSourceImplementationMatch`. Its private representation retains exact
`ImplId`, receiver, validated `List[AcceptedImplementationCallable]`, shared pattern,
and the same accepted implementation's actual `List[BoundTypeParam]`.
Callable rows are `TraitImplementationMember(member identity, CallableId)` or
`AuxiliaryImplementationCallable(CallableId)`. Only the former projects a bound
member proof. The latter retains legal extra issued methods (including explicit
not_equals when no source trait declaration supplies that slot) for later direct
calls/remap; it does not synthesize a registry ordinal. Missing mapping rows
remain errors, distinct from an accepted row with no declared projection.
Member identity is issued declaring `TraitMethodId` or
`CompilerScopedEvidenceMember(TraitId, Int)` validated by the registry owner's
shared method factory and inheritance topology. Caller Env mutation cannot
shift ordinal or topology. No fabricated callable/second registry is introduced.

```blorp
pure func accepted_match_source_trait_implementation_with[Proof, Pending](
    authority: AcceptedTraitImplementationAuthority,
    issuing_table: DefinitionTable,
    receiver: SemanticType,
    requested: BoundTraitIdentity,
    applicability: pure (AcceptedSourceCandidate)
        -> Result[AcceptedSourceCandidateDecision[Proof, Pending], String],
) -> Result[AcceptedSourceMatch[Proof, Pending], String]
```

The factory validates issuer provenance and lexical nominal trait identity,
including equality of the supplied comparison ID to the selected declaration's
canonical `trait_id_compiler_identity`; copied owner/name/span metadata cannot
mask a wrong or unregistered ID at this new boundary. Legacy Bool admission
is unchanged. The successor factory preserves existing visible candidate order
and matches once. Its callback decides Applicable(proof), Inapplicable,
Deferred(pending), or Cyclic(diagnostic); only Applicable validates member rows
and issues a selected packet. Deferred stops the first unresolved candidate
without issuing an accepted packet. Cyclic candidates are skipped, retaining a
cause only if no source succeeds, so independent compiler proof may still close
the goal. Source-only absence is not complete trait unsatisfaction.
The former public packet matcher and unguarded Boolean callback adapter had no
production consumers and are removed; projection tests now use an explicit
test-owned callback, not a claimed recursive witness. A foreign issuer returns exactly
`trait evidence issuer does not match accepted authority`.
Read-only `accepted_source_implementation_match_{id,receiver,callables,pattern}`
accessors expose those products. `_dependencies(matched)` accepts no replacement
bounds: it projects only the packet's own accepted row.

This seam is acyclic: authority imports env/IDs, while future trait_evidence
imports authority plus existing union authority/module-view facts. No new trait
or union authority storage is duplicated. No Core consumers were changed.
Owning regressions live in existing registered `test_env.brp` and
`test_accepted_semantic_catalog.brp`; runtime fixtures remain pending red witnesses.
No unresolved producer API draft imports are retained.

`builtins.brp` owns one shared `builtin_trait_methods(kind)` factory, extracted
verbatim from the installed trait declarations. Installation retains IDs
100..128 and declaration order. `builtin_trait_member_declaration(id, name)`
projects exact declaring owner/ordinal using this factory and the existing
registry inheritance DAG. It does not rebuild Env or read caller-modified rows.
Registry tests compare every installed declaration/method; packet tests shift
Env method order and remove its supertrait edge while retaining the canonical
registry projection. Constructor census: installation still creates 29 trait
definitions and their existing method lists; the ToFixed method factory has
its own Fixed type expression while the installer retains its original Fixed
expression for builtin impls. Runtime allocation effects require measurement,
not inference from expression count. Source query construction creates one
opaque packet plus one callable variant per selected implementation method;
dependency rows remain on-demand only.
Generic `!=`, default bodies and forwarding remain later transport controls,
not functionality closed by this packet.

## Current-base red/control reproduction

Artifacts: `/tmp/blorp-caller-base.K7848U/` (statuses, stdout/stderr, source hashes,
FRESH/version provenance, lower/mono JSON and final C). Build: O2, split8,
aarch64-apple-darwin, Apple clang 21.0.0, memory diagnostics disabled, dirty false.
Binary SHA256 `70b25e74e68d7480190a0fdcef01085add1136c76b1d0fab56d65427517ca6b3`.
Compiler C SHA256 `325acef21e31ee320ca4a2113aee945dcc7bfb206ed9e83da5163cd8bd423ac3`.

Each retained source in
[benchmarks/results/fixed_union_selected_targets/fixtures/caller_diagnostic/](../fixed_union_selected_targets/fixtures/caller_diagnostic/)
(`main`, `reverse`, `ctfe_direct`, `ctfe_forward`, `selector_main`,
`selector_alias_provider`, `selector_ctfe`, all `.brp`) ran with
`bin/blorp run --no-format --timeout 30 <fixture>`.
Main/reverse exit 0: all provider/importer direct/forwarded comparisons True.
CTFE direct/forward exit 0: both folded values False; both runtime values True.
Selector main exit 0: provider direct/forwarded 11; alias provider exit 0: 17.
Selector CTFE exit 1: `compile-time constant evaluation does not support intrinsic
function call 'pick_marker' yet`; this is explicitly unsupported on the base.

`bin/blorp test --timeout 30 benchmarks/results/union_caller_evidence/fixtures/test_caller_evidence.brp`
exits 1 with 5 pass/5 fail. Provider plain/List/Option, Selector and
Stringable pass; importer plain/List/Option and both CTFE-agreement assertions
fail. These are current-base red facts, not acceptance of the preparatory diff.
Missing-API drafts were never executed or counted as behavior regressions.

Compilation of
[benchmarks/results/fixed_union_selected_targets/fixtures/caller_diagnostic/main.brp](../fixed_union_selected_targets/fixtures/caller_diagnostic/main.brp)
with `bin/blorp compile --no-format --dump-core-after=lower,mono --dump-core-file=<artifact>
-o <main.c> <source>` exits 0. Lower has forwarded 120 -> same 129;
mono has one forwarded 1604 -> one same 1607 instance for Choice, with type-only
keys and binary equality. C SHA256
`4700d33b89449d92c862d3c8ab853f70aa75ddf301a26de78199534b3b8e4a73`;
Core SHA256 `c472ef139103d37eeaa7a41eae3fe033113cb93c9286bad7ac22049148e56ce1`.
No quiet performance claim is made under current external compilation load.

## Candidate validation status

First candidate `make` stopped during compiler-source parsing: new authority
loops used unsupported `?=` bindings, and one multiline lambda had invalid
syntax. No candidate binary or production-owner test result was produced.
The first mechanical attempt also used unsupported early `return` expressions
and omitted the installer Fixed binding. Repairs follow existing Result/error
loop precedents: one Result-valued selection outcome, a locally owned callable
list plus explicit error outcome, and a narrow outside-loop validation helper.
Old-base `check --no-format` accepts authority/test_env/catalog sources;
this is source legality, not candidate behavior. First repaired build was FRESH
CLI O0/runtime O2; env owner passed40/40 as smoke evidence only. The subsequent
explicit `make BLORP_CLI_C_OPTIMIZATION=-O2` succeeds and
`BLORP_CLI_C_OPTIMIZATION=-O2 scripts/compiler-build-status` reports FRESH;
`bin/blorp --version` confirms CLI/runtime O2, split8, unchanged toolchain.
Candidate binary SHA256 `921ad36d3376b860d6bc6bc6b23fc75450518b8e628a0fafa5074476591a0d56`;
compiler C SHA256 `a896b3d8cae3b68ff7d7be5924134f53d09f138d8fd39a3bae7060d3213600d3`.
Exact O2 `test_env` passes40/40; imperative catalog owner passes17/17.
`BLORP_CLI_C_OPTIMIZATION=-O2 scripts/compiler-check --changed` passes661/661
across12 selected suites, including `test_builtins` and the existing matcher
profile workload. It selects three production owners, no special checks.
Independent results are recorded below; no runtime-witness closure claim.
Logs: `/tmp/blorp-caller-prep.pHHsn8/` (`make-{1,2}.stderr` transcribed from
complete tool outputs; `make-3.*`, subsequent syntax-host stderr/stdout retained).

The final read-only selection is12 existing owners (builtin extraction adds
`test_builtins`) and recommends compiler-blorp. The existing
`test_implementation_pattern_profile_benchmark.brp` provides the isolated
8/16-parameter production matcher workload and first-failure result oracle;
reuse it for deterministic cost evidence instead of adding test-only hooks.

Generated-C review: compiled the existing matcher profile main with final-Core
dump to `matcher.{c,core.json}` in the artifact directory. Final Core identifies
`implementation_pattern_matches_with` as2466/`brp_DM`, and shared bounds helper
as2467/`brp_DN`. C53180 retains the direct empty-bounds `types_equal` branch;
C53272 invokes the satisfaction callback, C53285 breaks the inner bound loop on
False, and C53299 breaks the outer parameter loop. Missing substitutions retain
the empty branch. No dependency-record construction appears in legacy Bool reads.
This is structural/behavior evidence, not a quiet allocation/instruction comparison.

## Independent validation and frozen epoch

Independent packet: `/tmp/blorp-caller-independent.HODTxX/REPORT.md` and its
per-command recorder subdirectories. Exact owner-first results: env40/40,
catalog17/17; selected12 suites661/661; broad `compiler-blorp`6601/6601
(5771 TestSuite assertions plus830 marked production fixtures), all exit0.
These boundaries overlap: do not add owners or selected suites to the broad
total. Every compiled command ran once, sequentially; no retries/threshold
changes/timeout overrides. Broad child log has no warning/FAIL/error lines.

The independent candidate compiler was FRESH before/after, CLI/runtime O2,
split8, aarch64-apple-darwin, Apple clang21.0.0, bootstrap dev-d44472d3a5d0,
memory_diagnostics0, binary SHA256921ad36d3376b860d6bc6bc6b23fc75450518b8e628a0fafa5074476591a0d56.
Its build stamp is `dde591ecd0ba-dirty`; later evidence-comment updates are not
a new compiler-binary epoch. All five frozen production/test hashes and tracked
diff SHA256 `858fd4ee0332643aa478a8b7f6f460c142e3e379e6ffc060317447b2076c4063`
match before/after. Exact hashes reside in the independent report and author
`/tmp/blorp-caller-prep.pHHsn8/source-hashes-final.txt`.

Broad recorder retains `source_changed_during_run:true`: the9-file untracked
evidence fingerprint changed from `b15e29e9de950d593e3889267563cb3af38fe9bc899c69ca95c4a96d9017ecbb`
to `ff132b7add321425ec33ecc01e66a06b5c76b1cc7ddc5d4e46e2c3ecc8676262` during
2026-10-05T23:47:17..23:51:46UTC. The exact authorized author edit at23:50:18UTC
touched only this DESIGN's links/full command and the first two comment lines of
`benchmarks/results/union_caller_evidence/fixtures/test_caller_evidence.brp`.
No executable red-fixture code changed; that pending fixture was not a selected
owner input. None of the five tested compiler/test files or the binary changed.
The other seven untracked files' mtimes precede23:42:52UTC. This explains the
marker without overriding it or claiming a clean whole-tree snapshot.
This independent-evidence addition is a subsequent docs-only update after all
compiled jobs stopped; it does not extend the tested binary/source epoch.

Same absolute `benchmarks/self_compile/small.brp` input (SHA256
`6a67158fb09aac383ec40e77e5c5b1d64fd068b19edf6e2596a6f25060d9cc93`), same cwd:
unchanged CURRENT-dde baseline binary70b25e74e68d7480190a0fdcef01085add1136c76b1d0fab56d65427517ca6b3
and candidate each compile successfully; whole-file `cmp` exits0 with both C
SHA256 `044cbf8fe7673fd10496f07066bda0d24eac435ab27583f3098a833e3ba77480`.
No normalization. The baseline worktree later HEAD `dbd1e6fc464d0438eb37f8c659396aecd77cc256`
is not its unchanged-dde binary build epoch. The recorder's cwd-local binary
hash in the base-compile packet refers to candidate; exact argv and separate
`base-provenance/` identify the actual absolute baseline binary used.

No performance, full runtime/default closure, Linux/Docker, sanitizer or
stage2/3 claim. At that historical checkpoint coordinator quality remained
pending with c304/dd64 stable magic-spelling keys; dde tooling could not
substitute. The coordinator00c9 integration later passed its O2 build and quality,
which does not itself validate the successor dirty producer foundation.
Any actual bounded allowlist relocation requires the current tool's diagnostic
and review, not a broad exception. The narrow preparatory API is independently
validated; recursive evidence, caller dispatch and automatic publication are not.

## Separate retained nested-HOF emission defect

The initial catalog registry assertion used nested all/map closures. Its native
test link failed before executing assertions: undefined `_brp_3cS` and `_brp_3cU`.
Both the FRESH O2 candidate and the unchanged CURRENT-dde binary (SHA256
`70b25e74e68d7480190a0fdcef01085add1136c76b1d0fab56d65427517ca6b3`, retained in
the fixture-only `union-native-preparation` worktree) fail identically on those
same new test inputs. The baseline binary versus candidate inputs distinction
is intentional; this is not a historical-result substitution.

Reduced retained source: [diagnostic_registry_hofs.brp](fixtures/diagnostic_registry_hofs.brp).
Run each binary with `run --no-format --timeout 30 <that source>` from this
worktree: both exit1 with identical generated-C error at16591:
`expected identifier or '('` after dangling
`static /* function _blorp_clambda_12 kind=closure_body def_id=4599 */`.
Logs `registry-hofs-{base,candidate}.{stdout,stderr}`, reduced C/final Core,
and original catalog link failures remain in `/tmp/blorp-caller-prep.pHHsn8/`.
The simpler [nested-global control](fixtures/diagnostic_nested_global.brp)
passes with True on candidate, so the finding is not "all global captures fail".

Source diagnosis boundary: `stage_10_backend/emit.brp:24559` falls back to function
inventory when closure-body emission returns None; storage-prefix emission then
leaves a dangling declaration in single C, or a referenced prototype without
body in split C. The exact inner failed emitter fact is not yet isolated.
No backend repair belongs to this owner-API cut. Root approved replacing only
the registry assertion with imperative loops, preserving all29 installed IDs/
names, every declared method's exact owner/ordinal, and the topology check.
Independent review confirmed that equivalence. The failing source remains a
separate follow-up witness, not deleted/relabeled as passing coverage.
Current CLI has no `--emit-symbol-map`; final Core IDs and the backend's existing
base62 projection were used to map emitted callables instead.

## Successor producer foundation checkpoint (not recursive closure)

### Independent repaired foundation acceptance

The independent packet is
[`REPORT.md`](/tmp/blorp-foundation-independent.aeiUCy/REPORT.md), SHA256
`151eb25e7025a23b41890c60de1ba71fbf46bd2ecb8f2fcfc464ecddd57c6790`.
All eleven frozen inputs (ten code/test/manifest files plus this note) remained
unchanged throughout validation. Their manifest SHA256 was
`b3c6b8f4c26480d1966f737278cfede96bbc91a913d5b2402a1602e18c49d166`.
This subsequent evidence-only addition does not alter the ten tested files.

The repaired compiler was FRESH O2 before owners and after gates: source stamp
`a78dccbd665d-dirty`, bootstrap `dev-c3040e79c7d8`, CLI/runtime O2, split8,
Apple clang21.0.0, aarch64-apple-darwin, memory_diagnostics0. Binary SHA256:
`83a55da5ea2cec1295e078e56272017d937b487d42067543db34f7ee1a86ccd9`;
generated compiler C SHA256:
`e0a4f8b2b8961593981c164164699938ecbf8c41101ec4b34a0da2d04412129b`.
Owner-first results were env40/40, builtins17/17, catalog21/21 and context6/6
(84/84 total), overlapping the selected twelve suites' 803/803; do not add
these counts. Build and `make quality` exited0. All commands ran once,
sequentially, with no retries or timeout overrides; recorder packets report
`source_changed_during_run=false`. Quality includes current magic-spelling
506 allowlisted/0 stale and ownership manifest validation.

Both the frozen coordinator00c9 comparator and repaired compiler emitted the
same absolute root-owned normal small input and Stdlib, with identical flags.
Complete raw C SHA256 was
`3f4e7cf0fbabc5459ba7802a4fc5cb69a20d0699e4c19991f19dcf374cce4abe`;
`cmp` exited0 without normalization. Exact input, Stdlib and comparator hashes
and commands are retained in the report. This is a normal-program stability
control, not evidence of changed caller dispatch.

Acceptance is only the unhooked context/source-loop/registry foundation. No
broad compiler-blorp, sanitizer, runtime/default closure, stage2/fixpoint or
performance gate was claimed. Recursive selection, lexical slot issuance,
caller transport, CTFE agreement, automatic Eq/Hash and P2a remain pending.
Structural construction counts below are non-measured, not allocation results.
The retained legacy recursion and opaque-append defects remain separate bugs.

### Foundation scope and author diagnostic history

The current foundation adds one shared guarded source candidate loop, one
ordered 47-row builtin implementation factory consumed by the existing installer,
a prepared 29-trait registry, and `trait_evidence_context(view, issuer, headers)`.
Context construction borrows the module view's trait/union/callable authorities
and the existing implementation-header graph; it validates existing shared
definition-table provenance and all three actual module owners. No duplicated
union table or mutable Env implementation authority is added. Registry/facts
are prepared once per context, never per obligation.

Candidates retain exact declared trait identity and expose its ordered declared
supertraits under the same issuer. The recursive producer must close direct
supertrait proofs separately from implementation-bound dependencies, excluding
source subtrait implementations from direct-supertrait search. Inherited members
retain their exact declaring `TraitMethodId`; a source Hashable implementation
need not republish a separately proven Equatable member. Own required nondefault
members without a target remain errors. Actual declared defaults without a
published callable may later yield a validated default TEMPLATE (exact member ID
and borrowed opaque topology slot) in source or compiler evidence. This is not
an executable target: later lowering/CTFE must typecheck/materialize that template
with its implementation substitution and closed bound/supertrait proofs.

The first O2 foundation build passed, FRESH at that snapshot, with binary SHA256
`236e8a207bd4044cfe2044360ce4ee2895a8a57302f1f3c4a3a896e927cc555c` and generated
compiler C SHA256 `54814ebe5b04412e8f51b1aa7af086d90b7cff5ffa1d8ba6912b4a0d79f58131`.
It used Apple clang21, O2 CLI/runtime, split8, and bootstrap `dev-c3040e79c7d8`.
Artifacts are `/tmp/blorp-evidence-cycle.keg3x8/`: `producer-owner-make-2.log`,
`foundation-build-status.txt`, and `foundation-source-hashes.txt`. Subsequent
boundary repairs changed production inputs, so that binary is now only a source
compilation host, not a FRESH acceptance claim for the repaired foundation.

Executed source-owner feedback after repairs: catalog21/21
(`source-owner-migration.log`), builtin17/17 and context/capability6/6
(`foundation-expanded-controls.log`); env40/40 passed the earlier foundation
snapshot. Builtin controls independently assert every row, every own/inherited
declaring identity/ordinal/order, deduplication, and all 29×29 satisfaction pairs.
The capability owner also rejects nominal graph namesake registry IDs and pins
exact accepted legacy enum TypeId, ordinary-union exclusion, generic-receiver
exclusion and foreign issuer error.

Earlier catalog ordering failure was a bad control: existing coherence filtering
removes overlapping same-trait implementations. Its replacement observes two
genuinely retained Base/Derived candidates and deliberately returns Cyclic then
Applicable. It tests the owner loop, not real recursive witness closure.
The first new context suite used a non-discovered `TEST_SUITE` binding (zero
executed cases), then the conventional `tests` binding. Initial splice failures
were also false REDs caused by malformed import syntax/module paths, retained
in the diagnostic logs. The corrected control constructs both valid unspliced
contexts under one issuer with distinct owners before replacing the importer
callable authority with the provider's. It fails when only the owner equality
conjunct is removed (`context-owner-splice-genuine-red.log`), and passes with the
check restored. No inference visibility policy changed.

Construction cost is disclosed structurally, not as measured runtime allocations
or a speed claim: every executed builtin inventory factory creates 47 opaque
fact records and a new 47-entry list before installation. Each current context
prepares that inventory once plus one registry. The registry's explicit recursive
factory makes 100 row and 160 opaque member constructions to retain 29 final rows
(counts from the independent golden topology). Signature/list construction also
has cost; ARC/COW, CTFE and C optimization can affect actual allocations.
No baseline/candidate allocation comparison is claimed from two hosts importing
the same candidate implementation. Matched boundary measurement remains pending.

### Separate inline opaque conversion defect

[opaque_append_probe.brp](fixtures/opaque_append_probe.brp) fails with
`Conflicting type arguments for generic function 'list__append'` on the pinned
bootstrap and FRESH coordinator00c9 binary (SHA256
`2a60b44e6569177610ef29984f4b2a799c016f14b650414170cde9a7dbe3208a`) using the
same absolute source and successor standard-library cwd. Lower/desugar succeed;
mono fails. The retained pre-mono Core has selected direct append def_id726,
formal `[List[T], T]`, but actual types `List[Entry]` and `EntryRep`: inline
`into_opaque` lost its nominal expression type. The
[typed-local control](fixtures/opaque_append_binding_probe.brp) preserves `Entry`
at that same selected target and emits C successfully. Logs/Core remain in the
checkpoint directory (`opaque-append-*`, `opaque_append_before.core`,
`opaque_append_binding_before.core`). Temporarily removing the entire unused
registry helper block did not rescue the inline fact probe; its typed-local
control did. The foundation uses the existing typed-local construction precedent
at its two new opaque append sites only; no backend/Core fix is included.

The previously retained legacy bound-recursion SIGSEGV is likewise not fixed by
this unhooked producer. The [legal header/control](fixtures/legacy_recursive_bound_legal_header.brp)
checks successfully; changing only its body to the [concrete recursive call](fixtures/legacy_recursive_bound_cycle.brp)
caused SIGSEGV (exit -11), not a timeout, in the historical accepted-preparation
host binary SHA256 `921ad36d3376b860d6bc6bc6b23fc75450518b8e628a0fafa5074476591a0d56`.
The exact `check --no-format` observations are in `source-legality-and-cycle.log`
and repeated debugger frames in `backtrace-final.log` in the checkpoint directory.
The frames follow shared pattern matching → old bound filter →
`accepted_bound_obligation_is_satisfied` → exact source obligation resolution
and repeat. This is a retained public legacy resolver bug, not proof the new
producer fixes inference. No old-host outcome is relabeled as new-pin validation.

## Lexical callable-bound-slot checkpoint (not recursive selection)

The worker rebased cleanly onto current integration
`3c3383357914ed7a90cb3eb9ebab22ba378186d7`, retaining the accepted foundation.
`trait_evidence_callable_slots(context, issuer, callable)` issues an opaque
bundle from exact accepted headers and normalized effective parameters.
`trait_evidence_lexical_context(context, issuer, active_callable, bundle)`
validates the explicit issuer and active owner. Each detached slot retains one
shared opaque owner (issuing DefinitionTable, CallableId and module owner),
plus effective parameter/bound positions and exact BoundTraitIdentity.
`trait_evidence_lexical_slot(active_context, slot)` rejects cross-callable or
foreign-issuer transfer; two owners' same-spelled T cannot supply each other's
proof. Numeric CallableId equality alone never establishes provenance.
Graphless/unindexed issuance remains unsupported, not a fabricated owner.

Functions consume `accepted_callable_find_exact`'s normalized inventory,
including variadic-only filtering. Implementation methods and body checking
consume the same unchanged projections extracted into
`type_system/implementation_bound_params.brp`: enclosing parameters first,
then explicit method parameters; defaults retain enclosing bounds. No generic
schema, body admission or inference semantics changed. Effective inventory is
available under the validated bundle for subsequent owner-scoped forwarding.
All positive fixtures explicitly require empty body errors before slot checks.

Independent approval packet:
[`REPORT.md`](/tmp/blorp-lexical-independent.zgiiCa/REPORT.md), SHA256
`90d5b19796ea6aac215123555b111c6495d7214aeaaf306d1aaa187363d025f7`.
Five frozen code/test/manifest hashes stayed unchanged; manifest SHA256
`2d26f5caa2a66879ac8dfdd12218d7cd33249c0a3a123e69a86c03eae9b3d39e`.
Owners passed244/244 (lexical9, headers11, declarations192, body order32).
Selected eight suites passed294/294, plus the direct Python body-metrics check
actually ran one test with zero skips; the separate selector verdict was295/295. These counts
overlap, not cumulative. The direct supplements preserve real suite counts and
executed/not-skipped evidence that successful selector child-log cleanup omits;
they were disclosed evidence supplements, not retries after a failure.

Candidate was FRESH O2 before/after, stamp3c3383357914-dirty, dev-c3040e79c7d8,
split8, Apple clang21, memory_diagnostics0. Executable SHA256
`c6ad20b238f2c7b39eabf445ef55c32cf41fb22fe69fb6c0292a2d1cd40a3b59`;
actual compiler C SHA256
`376b76a01fbe2c296c4e5288a9afe3623655f0fa7a1232d977f47b79d4fc7e5f`.
Unchanged current-root comparator executable SHA256
`dc8b6f87ad881926c6caa4207ba8993c97d5c2589df8ba96555c35edfa2ba636`.
Same root cwd, absolute small input/Stdlib and flags produced complete raw C
SHA256 `3f4e7cf0fbabc5459ba7802a4fc5cb69a20d0699e4c19991f19dcf374cce4abe`,
cmp0 without normalization. Exact commands/input hashes remain in the report.

Recorder `bin_blorp_sha256` describes the cwd-local executable, not necessarily
the absolute executable in argv: author current-root source-host checks record
historical worker83a55, while candidate C emission from root cwd records rootdc8.
Actual invoked rootdc8/candidatec6ad paths and hashes were separately checked
before/after. Earlier historical-host9/9 lacked positive-body guards and remains
a pre-repair partial oracle, not final acceptance; author history is retained in
`/tmp/blorp-lexical-source.zk5xL1` and `/tmp/blorp-lexical-candidate.PBb4Oq`.

This accepts unhooked lexical ownership/positions and shared projection only.
No recursive producer, inference/CTFE/Core transport, executable default
materialization, dispatch, automatic Eq/Hash, broad/full-quality/sanitizer,
fixpoint or performance closure is claimed. Construction cost is unmeasured.
The next bounded producer must retain forwarded proofs as explicitly lexical,
defer missing proof/member facts, and include encountered actual default and
direct-supertrait/inherited projection before claiming selected interface closure.
