# Union Simplification and Checked Fixed Union Roadmap

Status: **P2c IMPLEMENTED / VALIDATION IN PROGRESS; CHECKED GUARANTEE PENDING.**
Published source implements `fixed union` as an alternative spelling of ordinary
`union`. The declaration migration is already reviewed and validated; the current
P2c cut removes the remaining enum internals. No checked payload or placement
guarantee is enforced. Non-generic payload-free unions have default tag equality;
an authored equality implementation wins, and hashing requires explicit
`Hashable`. Payload-bearing/generic default equality and broader caller-selected
evidence closure remain planned. The synonym and checked guarantee are separate deliveries.
Checked-record work is separate, not a prerequisite or a guarantee from this cut.

**Execution order superseded by user direction:** migrate all maintained
declarations and live generated fixture source first, resolve actual test failures,
review and commit that cut, then remove all enum internals. Common-trait closure,
nominal-identity repairs and earlier capability/native prerequisite ordering below
are deferred work, not gates for the mechanical declaration cut; their saved
failure evidence remains valid and is not described as fixed. Keep `fixed union`
as an ordinary synonym, with no no-boxing or checked placement promise.

**Current integration in progress:** source base `535096f01` is being merged with
`origin/main` at `7ab679600`, including the immutable `dev-dbc23276a2a6`
bootstrap, isolated one-pass discovery tree projection, and inline fixed-record
policy. Enum retirement and the closed native-managed ownership repair are being
ported to those boundaries; production still uses the table adapter. New main
features and explicit union hashing are preserved. The reviewed narrow identity
census amendment passes3404 static rows; its added debt is not an identity or
performance win. The third normal-pin O2 build passes and is FRESH under
`dev-dbc23276a2a6`; focused gates, sanitizer, parity, fixpoint, cost and overall
acceptance remain pending. The earlier Linux sanitizer failure is not waived. See the
[current integration checkpoint](../benchmarks/results/union_enum_retirement/current_main_integration.md). `fixed union`
remains a temporary synonym, not a checked placement or no-boxing guarantee.

**Historical main integration:** `origin/main` at `aa602e4ce051` is merged in
`c80069ae0c98`; the recovered enum-retirement WIP remains uncommitted. Maintained
tests now use `test_*` parent/suite paths, with explicit raw-fixture/support
exceptions. Pure path audit passes; restored-WIP build passes and is FRESH only
under the retained `ebbd309a` bridge (CLI O0/runtime O2), after removing one stale
`EnumKeyword` alternative. Default pin `d2959d886320` still fails build-tool C
compilation; cached tools do not prove default-pin closure. Seven focused renamed
owners now pass 585/585 after warmup exit0, with unchanged bridge/compiler inputs.
The authorized closed native-managed ownership repair now builds FRESH under
that bridge: the unchanged strict IP echo passes with 48 allocations/48 releases,
zero leaked objects/bytes (baseline 48/46/two objects/84 bytes). The TCP suite
passes 18/18, including actual IP echo. Earlier broad gates/fixpoint below are historical, not post-merge
acceptance; current broad gates/fixpoint/LSP, default-pin capability closure,
ABI, match-access, cost and fixed guarantees remain open. No ready-to-merge or
publication claim is made. See the [integration evidence](../benchmarks/results/union_enum_retirement/checkpoint.md#current-native-managed-ownership-repair).

**Historical P2c working checkpoint:** branch `codex/union-enum-retirement`, source base
`07c1ee302`, implements one semantic union kind and one Core union declaration,
with explicit scalar-tag versus managed storage. The pre-loss `9f0170` compiler
was FRESH under the explicit retained-stage2/O2 override: all 267 disjoint owners
passed 5859 assertions, all 840 check fixtures passed, and strict runtime 38/38
plus the unchanged Bool probe passed. Earlier source-owner and RED/timeout
epochs remain separate. The normal combined retry also passed its native
5859/5859, then ended with an infrastructure FAIL when checkout removal prevented
206 fixture commands from starting; it was not a semantic failure or gate PASS.
Recovery verified source equality and rebuilt caches separately. The clean
recovered normal compiler gate then passed 6699/6699 (5859 native assertions
and 840 fixtures), with identical compiler/C hashes and final override FRESH.
Separate frontend closure now passes compiler-new 839, parity 3563 (zero
mismatched files), tools 241 and Std 1; earlier seed-pin and indexed-deletion
failures remain separate. The actual O2 self-host fixpoint also passes: full
stage1/2 and stage2/3 generated C comparisons agree. New-stage2 audit 229/0 and
seven runtime owners 38/0 pass; canonical native owners fail 31/1 only on IP echo
ownership (two unknown objects/84 bytes). The retained prior compiler reproduces
the same failure with current owner/Std; this is not a fresh parent-07 comparison
or waiver. Hygiene passes after one retired-import permission was removed.
Broader gates pass runtime 4701, leak 1174, doctest 1057 and CLI 177, then stop
at LSP FAIL 1/1/2 (native suite 18 tests/one diagnostics timeout); a full retry
also fails 1/1/2. Separate isolated-test 1/1 and instrumented-prefix 4/4 passes
are diagnostic, not LSP closure or cause proof. Independently authorized package
49/49 and Core sanitizer 2431/2431 now pass; neither waives LSP or IP ownership.
Full acceptance/cost remain open. The
internal `TypeKind` layout payload is boxed and its temporary cost unmeasured.
No checked-fixed, default-pin or publication guarantee follows. See the
[provisional P2c evidence](../benchmarks/results/union_enum_retirement/checkpoint.md).
An inherited DirectoryEntry native-pointee field-width mismatch remains a
separate P3 hardening task; native behavior tests do not prove its ABI layout.

**Validated declaration-cut checkpoint:** validation source base `cbffad8a3` includes the merge of
recorded `origin/main` at `3f80e94e0`; the declaration cut is reviewed and validated.
Final host `2f44843a7` is FRESH only with the frozen
bridge/O2 override; default-pin closure is unverified. Independent final-host
compiler 6672, runtime 4701, leak 1174, sanitizer 2413, product/CLI/LSP/package
gates, codegen audit 229, O2 fixpoint and retained stage2 runtime 29/audit 229 pass.
The separate reviewed numeric-only census closure passes hygiene and Python 32;
the earlier hygiene RED remains frozen. Earlier frontend/parity and repair proofs
retain their own epochs, not relabeled final-host runs. Default tag Eq/Hash is
preserved; potentially matching custom Eq requires explicit Hash. The bounded
late-loop traversal repair does not fix general heterogeneous OR-pattern field
identity, which remains deferred. Enum-family deletion, checked fixed/no-box
guarantees and broader caller-selected trait closure remain pending. See the
[final validation](../benchmarks/results/fixed_union_declaration_migration/final-validation.md)
for counts, hashes, retained failures and scope. Immutable
bootstrap pin rotation is not requested. The prior `dd23675b7` checkpoint records accepted static producer
foundation `93dbe8f8f`, published-main merge `3c3383357`, and lexical callable-bound
slots (author `dfadf1a`). Its FRESH root O2 proof belongs to `3c3383357`;
that historical binary is not the migrated-root host.
The isolated source-only recursive/supertrait producer passes 25 owner cases and
626 distinct selected cases, including an admitted diamond regression; it remains
unintegrated and implements no inference/Core/CTFE transport, builtin capabilities
or executable templates. Diamond products prefer an exact own override, merge
equal full parent targets, and report actionable conflicts for different targets;
current language admission is unchanged until transport is wired.
Separate resource guards and constructor-identity repairs have independent green
bounded gates; constructor fixpoint and retained stage-2 correctness gates pass.
Matched resource guard costs are accepted within two O0 diagnostic-worker
workloads, with output identity and small added allocation costs; constructor
remap-product costs remain unmeasured. The TCP opaque String pilot has observed
zero-residual ownership controls, independently verified across 364 distinct
cases and the unchanged IPv4 probe. Direct fixture expectations pass 11/12;
qualified default foreign parameters still produce three copy-guard errors.
The separate foreign-copy candidate is rejected as-is despite its FRESH own host,
212 focused passing cases and three clean negative pins. V10 lower inspection
finds imported TextBuffer's primitive String target rebound through the consumer's
root String=Bytes alias, selecting the wrong Bytes copy policy. The fourth probe,
full C and native runtime are unrun. Independent source-derived diagnosis finds primitive and
issued nominal type references erased to the same named String representation;
complete repair must preserve that distinction through relevant typed/Core
consumers and exceeds the three-owner boundary. No broader repair is implemented
or approved; temporary fail-closed shadow admission would narrow supported
language behavior and requires a deliberate policy decision.
The frozen native candidate has broad green evidence alongside unresolved
resource/TCP failures, with stage2/fixpoint/admission
pending. These repairs do not complete P2. The evidence transport seam has one
serial owner.
The [progress checkpoint](../benchmarks/results/union_progress_checkpoint.md#current-execution-checkpoint)
owns current revisions, counts, provenance and remaining gates. The
[caller design/evidence](../benchmarks/results/union_caller_evidence/DESIGN.md)
retains the preparatory, foundation and lexical frozen proofs. Canonical native
admission/shared representation, broader common-trait/default closure and bootstrap
publication remain open. Declaration migration is reviewed and validated;
P2c enum-family deletion and P3–P5 remain pending. No release, pin rotation or publication is authorized by this checkpoint.

**Historical reconciliation:** the synonym integration was assembled over
`4dc9a9aceea35279e4c706b74a0dc8a6b8a258c9` ("Preserve nested pattern guards").
Historical compound-pattern failures below describe their saved
base2ac/frozen-candidate epochs. No historical gate count, binary hash or
freshness claim is relabeled as current-source evidence.

**Historical checkpoints:** the syntax cut was reviewed, validated and committed
as `073b78ae6` against `133eaf73a63830522b659ab6a2da65f9f2963711` before
this integration. Prerequisite acceptance below records task-branch epochs.
The prior `175a38215`
combined prerequisite gates pass within their recorded scope. Frozen assembled
root `8a4580717` passes its FRESH O2 selected/CTFE/leak and executable controls;
see the [assembled checkpoint](../benchmarks/results/fixed_union_concrete_binder/ASSEMBLED.md).
That historical checkpoint does not claim freshness after this documentation
update, bootstrap publication, or later phase completion.

One logical model treats enums as payload-free unions: simplify/migrate first,
optimize shared representations second, enforce `fixed` third. Both spellings use
one optimizer; the qualifier selects no parallel semantic/ownership/backend pipeline.

Read the [Worker Checklist](WORKER_CHECKLIST.md), [Architecture](ARCHITECTURE.md),
and [Code Shape](CODE_STYLE.md). Common recipes belong to [Development](DEVELOPMENT.md),
the [measurement protocol](../benchmarks/README.md#self-compile-measurement-protocol),
and [Releases](RELEASES.md#preview-validation). Each bounded delivery starts with
failing regressions and ends with independent code-reviewer/test-runner review;
every phase also gets a bounded cleanup review. Sizeable cleanup is separate.
Retain evidence in `benchmarks/results/`. Release actions are separately authorized
implementation checkpoints; local implementation does not authorize publication.

Historical task-branch progress (full P0 closure and the P1 bootstrap gate remain open):

- [x] P1 source-form metadata implemented in the local candidate: legacy
  `ParsedUnionDecl.form`, discovery form/source row kind, and formatter declaration kind.
- [x] Candidate built FRESH at `-O2` using `dev-d44472d3a5d0`; this is a local
  build, not a new bootstrap release. Legacy parser suite passes 201/201.
- [x] Five editor Python tests and metadata drift checks pass; independent
  production review has zero findings, including the indentation repair.
- [x] All assigned local owner, compiler-new/parity, compiler-blorp, tools,
  sanitizer, leak, LSP, and doctest gates pass; detailed counts are retained in
  the candidate `benchmarks/results/fixed_union_p1.md` and independent runner report.
- [x] Narrow Core proof passes 150/150 with existing erased managed payload storage;
  runtime proof passes 3/3 with per-test zero tracked live objects and retained Core/C controls.
  The harness resets before each test and again after the suite; its process-end
  3 allocations/releases are the post-suite interval, not fixture allocation cost.
- [x] Bounded cleanup review complete; legacy source/formatter JSON forms, table
  enum rows, and boolean fixture helpers remain for future enum retirement.
- [x] Matched normal/diagnostic stage-2 self/small costs and local self-host fixpoint
  retained in the [evidence packet](../benchmarks/results/fixed_union_p1.md): raw C
  identical, allocations exactly equal, instruction deltas cost-neutral, not a speedup.
  Stage-2 ownership fixture passes 3/3 with per-test live-object checks.
- [x] Classified lexical [migration census](../benchmarks/results/fixed_union_p1/census/REPORT.md)
  reviewed; raw-line and exact-declaration counts remain distinct.
- [ ] Full P0 semantic/native closure, including dynamic generators and imported
  trait identity; lexical inventories and bounded measurements do not complete it.
- [ ] Separately authorized immutable syntax-capable release verified and pinned;
  actual-pin self-host/build/package gates complete before P2 conversion.

| Cut | Dependency / safe parallel work |
| --- | --- |
| P0 contract census and baseline | Before implementation; reviewed readiness packet |
| P1 syntax/tooling, then bootstrap | Agree source-form contract first; parser and formatter/editor work may proceed in separate files |
| P2 declarations first | Migrate all maintained declarations and fixture source; resolve actual failures, validate, review and commit using the authorized local staging host |
| P2 family deletion second | After the validated declaration commit, remove enum internals; common-trait/native design work remains deferred, with no P4 performance expansion |
| P3 proof and cleanup | After semantic convergence; real runtime/self-host evidence |
| P4 representation admissions | P3 baseline; one bounded layout/storage cut at a time |
| P5 checked constraint | P4 position proofs and audit of all interim fixed uses |

## P0. Establish readiness and classify the census

**Boundary:** repository orientation, current contracts, and measurement inputs.
At the baseline revision above, `blorp/build/bootstrap.env` pins `dev-d44472d3a5d0`.
Do not assume it understands `fixed union`. The old parser serves AST tooling,
test discovery, and LSP; formatter declaration/JSON models, discovery tables, and
their legacy adapter are additional syntax boundaries. Editing one AST is insufficient.

The baseline separation is `ParsedUnionDecl.is_enum`, header `UnionLayout`
(`FieldlessEnum`/`TaggedUnion`), environment `TypeEnum`, foreign scalar admission,
and Core `CoreEnumDecl`/`EnumType`. Semantic named types and CTFE constructor
values are already shared; preserve those authorities.

The local P1 candidate replaces the source boolean with
`ParsedUnionDecl.form: OrdinaryUnion | FixedUnion | LegacyEnum`. Discovery
records explicit written form and source row kind; formatter metadata uses
`UnionSpelling` and `TypeDeclarationKind`. These source distinctions preserve
spelling without changing the accepted union layout or creating new logical families.

Reproduce and classify the census:

```bash
rg -n '^[[:space:]]*(private[[:space:]]+)?enum[[:space:]]+' --glob '*.brp' blorp standard_library pkg examples
rg -n 'is_enum|FieldlessEnum|TypeEnum|CoreEnumDecl|EnumType|enum_decl' blorp/src blorp/test
rg -n 'enum|union|fixed' editor blorp/src/format docs/GUIDE.md docs/GRAMMAR.md
rg -n 'foreign|blorp_read_memory_counter|MemoryCounter' standard_library/src/memory.brp pkg blorp/test
```

P0a records declaration/constructor identities, imports, auto traits, CTFE,
native contracts, container/capture positions, and embedded source generators.
P0b retains fixtures, a fresh normal/diagnostic pair, source/bootstrap/Clang/
optimization provenance, generated C, allocations, instructions, and ownership
controls. Active scalar counters bracket exact intervals; allocating snapshots stay outside.

Local retained census: selected roots have 366→369 raw anchored enum lines but
365→368 exact lexical declarations (one docstring line is prose); full source
inventory has 425→429 declarations, including three source-form metadata enums
and formatter fixture `Legacy`. Existing declarations remain unconverted. The
[snapshot report and inventories](../benchmarks/results/fixed_union_p1/census/REPORT.md)
classify embedded headers, native enums, negatives and manual owner exceptions;
they do not establish semantic/import/native-call closure. IpFamily's builtin
`long family` mapping IPv4=0 / IPv6=1 joins the required canonical native set.

The [cost packet](../benchmarks/results/fixed_union_p1.md) retains unchanged raw
normal/diagnostic stage-2 JSON: self allocations 241,661,755 and small 1,733,952
match exactly, frozen-input raw C matches, and minimum instruction deltas are
approximately -0.02% / -0.003% (cost-neutral). Unmodified O2 stage 1/2/3 C fixpoint
and narrow stage-2 ownership pass. External small-pair helper metadata labels the
stage incorrectly; binary hashes establish actual stage 2, without rewriting JSON.
These local proofs do not authorize release publication, pinning or conversion.

Baseline existing enums plus ordinary-union counterparts; distinct programs are
not identical-source performance evidence. Record migration cost honestly, then
establish a common syntax-capable frozen-source baseline for P4/P5.

**Accept:** reviewed semantic and native contract matrix; shortest fixtures and
commands chosen; all source-string generators classified; honest baseline packet.
**Stop:** an unclassified native contract, inactive counters, uncertain provenance,
or unresolved ownership failure. Review P0 before conversion; counts are not runtime proof.

## P1. Add `fixed union` as an ordinary-union synonym

**Boundary:** both parsers, discovery/adapter, formatter/editor/LSP, metadata,
diagnostics, and language docs. The current discovery route remains table parsing
through `parse_module_declarations` in
[`stage_01_discovery/pipeline.brp`](../blorp/src/compiler_new/stage_01_discovery/pipeline.brp).
Typed/tree parsers and previews are additional syntax surfaces; P1 changes no routing.

Source map:

- Table discovery: [`parse/declaration_parser.brp`](../blorp/src/compiler_new/stage_01_discovery/parse/declaration_parser.brp),
  [`parse/declaration_header.brp`](../blorp/src/compiler_new/stage_01_discovery/parse/declaration_header.brp),
  [`parse/definition_openings.brp`](../blorp/src/compiler_new/stage_01_discovery/parse/definition_openings.brp),
  [`tables/row_kinds.brp`](../blorp/src/compiler_new/stage_01_discovery/tables/row_kinds.brp),
  and [`tables/invariants/cardinalities.brp`](../blorp/src/compiler_new/stage_01_discovery/tables/invariants/cardinalities.brp).
- Typed/tree discovery: [`parse/tree_union_parser.brp`](../blorp/src/compiler_new/stage_01_discovery/parse/tree_union_parser.brp),
  [`parse/tree_declaration_preview_parser.brp`](../blorp/src/compiler_new/stage_01_discovery/parse/tree_declaration_preview_parser.brp),
  [`parse/union_preview.brp`](../blorp/src/compiler_new/stage_01_discovery/parse/union_preview.brp),
  [`parse/parse_state.brp`](../blorp/src/compiler_new/stage_01_discovery/parse/parse_state.brp),
  [`syntax/declarations.brp`](../blorp/src/compiler_new/stage_01_discovery/syntax/declarations.brp),
  [`syntax/ids.brp`](../blorp/src/compiler_new/stage_01_discovery/syntax/ids.brp),
  and [`syntax/dump.brp`](../blorp/src/compiler_new/stage_01_discovery/syntax/dump.brp).
- Legacy source/JSON: [`stage_03_parse/language_parser.brp`](../blorp/src/compiler/stage_03_parse/language_parser.brp),
  [`parsed_ast.brp`](../blorp/src/compiler/stage_03_parse/parsed_ast.brp),
  [`parsed_ast_json.brp`](../blorp/src/compiler/stage_03_parse/parsed_ast_json.brp),
  and [`discovery_adapter.brp`](../blorp/src/compiler/discovery_adapter.brp).
- Formatter: [`format/projection.brp`](../blorp/src/format/projection.brp) and
  [`engine/declaration_documents.brp`](../blorp/src/format/engine/declaration_documents.brp).

Preserve the qualifier through formatter
declaration construction, JSON decoding, and printing, not only the source AST.

These are legal examples under the implemented synonym semantics:

```blorp
fixed union Direction:
    North
    South
    East
    West

-- TEMPORARY P1–P4 synonym example; rejected by P5 fixed enforcement.
fixed union Response:
    Accepted(Int)
    Rejected(String)

pure func accepted_value(response: Response) -> Int:
    match response:
        Accepted(value): value
        Rejected(_): 0
```

At P5, this `Response` must use ordinary `union` or redesign its payload, for
example `Rejected(Int)` carrying an error code. `String` is not an admissible
checked fixed payload, even when already allocated or stored as a fixed-size pointer.

P1a adds syntax/recovery tests. `fixed` remains an identifier outside supported
declaration openings. Cover privacy/comments, constructors/import discovery,
LSP diagnostics/hover/definition/references/document symbols, editor syntax/snippets,
and format round trips. Parser-specialist/ergonomics input precedes implementation;
documenter review follows it.

P1b routes fixed declarations through exactly the ordinary union semantics:
payloads, type/dimension parameters, construction, matching, typechecking,
ownership, and storage, including ordinary empty-parenthesis rules. No enum-only
generic ban applies. The source bridge is `OrdinaryUnion | FixedUnion | LegacyEnum`,
not enum/fixed booleans; only legacy syntax keeps its current restrictions.
Source forms must not become three logical union kinds.

P1c updates [Guide](GUIDE.md) and [Grammar](GRAMMAR.md): the qualifier is preserved
for later checking but promises no stack placement, inline payload, absence of
boxing, or native by-value ABI. Both payload shapes exercise the ordinary path.

P1d lands syntax support while compiler/std declarations remain old-bootstrap-readable.
Validate/publish an immutable bootstrap, verify every supported asset/digest, and
pin `blorp/build/bootstrap.env`. Confirm generators, `make`, and self-hosting with
the actual pin before P2 changes declarations.

```bash
bin/blorp test --timeout 180 \
  blorp/test/test_compiler_new/test_stage_01_discovery/test_parse/test_parser_fixtures.brp
scripts/test --serial compiler-new compiler-new-parity compiler-tools lsp
scripts/blorp-compiler-bootstrap --print-id
```

Use a fresh build plus the bootstrap build/release/package gates in
[AGENTS](../AGENTS.md#find-the-right-boundary-first) and [Releases](RELEASES.md#preview-validation).
**Accept:** both parsers and every tool agree; fixed/ordinary fixtures have equal
semantics and ownership; immutable syntax-capable bootstrap is verified and pinned.
**Stop:** a formatter loses the qualifier, a fixed-specific semantic branch
appears, release assets are incomplete, or the build still uses an incapable pin.

## P2. Migrate enums and delete the separate logical family

**Current dependency:** P1 syntax. User direction now places P2b declaration
migration and its actual validation/commit before P2c internals removal;
the earlier P2a/capability ordering below is deferred rather than completed.
**Boundary:** compiler/std/pkg/examples, embedded fixtures/tests/docs, headers/env,
Core/lowering/CTFE. Bounded owner migrations precede source-family removal.

### User contract: default union equality (planned complete delivery)

The latest user decision applies to every union source form, not only the
payload-free bootstrap precursor. A union has default nominal structural
`Equatable` exactly when **all payload types of all variants are Equatable**.
Payload-free variants impose no payload obligation. This is a planned contract;
it is not evidence that the complete payload-bearing implementation exists.

- Equality requires the same nominal union type and concrete type arguments;
  structurally similar declarations do not become interchangeable.
- Compare the variant tag first. Different tags compare unequal; equal tags
  compare only that variant's active fields, in declaration order.
- Compare each field using its selected `Equatable` implementation, including
  caller-selected custom payload equality. Object identity or raw field bits
  cannot replace that implementation.
- An applicable explicit union `Equatable` implementation wins over the
  default. Its behavior is not overwritten by tag or structural equality.
- Generic eligibility is conditional on the actual payload obligations.
  A generic body may use the default only with sufficient bounds/evidence;
  a concrete instantiation must discharge those same obligations.
- Eligibility examines every variant, even when a particular comparison uses
  a payload-free variant. Execution reads only the active variant's fields.
- CTFE and runtime must select the same implementation and produce the same
  result. Constructor-shaped compile-time values alone do not prove this.
- `Hashable` is **not automatically derived from Equatable**. This decision
  adds no union hashing policy or automatic hash implementation.

The intended default is illustrated by a union without an authored Eq impl:

```blorp
union Shape:
    Circle(Int)
    Named(String)
    Empty

-- Planned default Eq: Int and String both satisfy the payload obligations.
-- Circle(1) == Circle(1)       True
-- Circle(1) == Circle(2)       False
-- Circle(1) == Named("1")      False
-- Empty == Empty             True
```

A payload record does not acquire Eq merely because it is inside a union:

```blorp
record Point {x: Int}

union Located:
    At(Point)
    Nowhere

-- Without Point's Equatable impl, Located has no default Eq.
-- This also rejects Nowhere == Nowhere: eligibility is declaration-wide.

implements Equatable for Point:
    pure func equals(left: Point, right: Point) -> Bool:
        left.x == right.x

    pure func not_equals(left: Point, right: Point) -> Bool:
        not equals(left, right)

-- With this selected Point impl, Located's planned default compares At fields
-- through that impl; a custom Point equality must likewise remain observable.
```

**Current bounded precursor: locally validated.** Non-generic, wholly payload-free
ordinary/fixed union scalar representation and default nominal tag Eq pass normal
pinned make, compiler/leak/sanitizer gates and O2 fixpoint; see the
[scalar bootstrap evidence](../benchmarks/results/scalar_union_bootstrap.md).
Release publication/pinning and the separate retirement branch's gates remain
pending. Payload-bearing, generic and recursive default derivation,
selected payload-evidence transport and CTFE/runtime coherence remain pending.
The first migration check's missing `Equatable` for `TriviaKind` remains historical
RED evidence; its later tag-only repair does not establish the full contract.
The tag-only cut must not be reported as
completion of this full contract. No checked `fixed` placement or no-allocation
guarantee follows from either delivery.

### P2a. Prepare common semantics and native ABI before conversion

**Superseded ordering:** this section retains the deferred design and its
historical blockers. User direction now authorizes declaration migration before
this closure; it does not claim the blockers fixed or authorize a broader redesign.

Derive payload-free shape from accepted variants, never the `fixed` qualifier.
Common rules preserve automatic `Equatable`/`Hashable`, comparison/hashing, string
conversion, matching, imported/qualified constructors, and CTFE equally for
ordinary/fixed unions. In the current tag-only checkpoint, payload-bearing
unions gain no automatic traits. The agreed follow-up supplies default Eq iff
all declared payload types have selected Equatable evidence, conditionally for
generic instantiations; automatic Hash is not established by that decision.
Keep four independently reviewable vertical
slices: common Eq, common Hash, canonical native ABI, and foreign admission.
No slice authorizes declaration conversion or a public ABI annotation framework.
Completed payload-free shape is independent of default eligibility. The first Eq
default covers declarations without type/dimension parameters equally for
ordinary/fixed unions; legacy enums are already non-generic. Generic declarations
remain legal under existing explicit-trait rules. Automatic phantom-generic
defaults are a named follow-up, requiring explicit-template selection and bounds
gates before admission.

**Observed explicit-method prerequisite:** on a fresh `073b78ae6` FRESH baseline,
four explicit BinaryEquality runtime/folding controls passed 2/4: both runtime
tests passed, while folded explicit `equals`/`not_equals` results were wrong.
The bounded infer-only selected-callable route is accepted locally as
`d390d5e95`: original controls pass 4/4, the final expanded corpus 9/9, and
independent focused validation 179/179. See the retained
[`explicit Eq evidence`](../benchmarks/results/fixed_union_explicit_eq/EVIDENCE.md)
for corpus/provenance boundaries; this is not main integration or publication.
At that explicit-only checkpoint, the default `not_equals` CTFE failure remained
an unclosed manual repro. This explicit-only
pilot publishes no default facts, implements no automatic Eq, and does not
close aliases or generic selection. This observed coherence bug is distinct
from the planned default/tag oracle below.

**Scoped identity prerequisite accepted locally:** integrated as `a1091fd13`;
see the [durable evidence](../benchmarks/results/fixed_union_scoped_traits/EVIDENCE.md).
The real default-body metadata red now preserves issued identity, with terminal
invalid-owner controls; independent focused 519/519 and runtime 18/18 leak checks
pass. Source-linked, compiler-owned, and explicit unindexed scopes are distinct.
This publishes no defaults and proves no default-body folding. Inheritance from
a graph trait to a compiler builtin without a source row remains deferred.

**Default callable publication accepted locally:** integrated as `175a38215`;
see the [durable evidence](../benchmarks/results/fixed_union_default_facts.md).
Already-issued facts match actual materialization, retaining effective bounds and
metadata without a trait/method whitelist. Independent declaration 178/178,
UFCS 2/2 and default/shadow 12/12 leak checks pass; worker selected 244/244,
CTFE 191/191 and broad 12,371/12,371 also pass. These counts overlap and describe
the isolated publication subjects, not combined root proof. UFCS `marker` genuinely
folds 37 and selects the issued runtime target 123. A missed accepted-layout
benchmark import, already stale at base `41483b853`, was separately repaired as
`06618d7d7`; it was not a demonstrated publication regression. The evidence also
records combined root broad 12,385/12,385, CTFE 191/191, stage1/stage2 audits
228/228 each, stage2 controls 30/30 with leak checks and all-three raw-C fixpoint
identity. These overlapping gates validate the integrated prerequisites, not
nested default `not_equals` binding/folding or later roadmap phases.

**Scoped concrete binder accepted locally:** integrated as `9c8f8ffba`;
see the [durable evidence](../benchmarks/results/fixed_union_concrete_binder/EVIDENCE.md).
It binds all scoped accepted-unresolved calls with a concrete first selection,
including inner calls in materialized defaults; there is no default-body flag.
Arbitrary bare custom trait globals following the legacy
FuncSymbol/intrinsic classification remain separate. Exact first selection guards
instance bounds, effective method parameters and concrete signature; a blocked
template does not skip to a later candidate. Issued outer/inner targets and actual
folding pass. Independent owner 538, selected 609, CTFE 191, broad 12,397,
stage1/stage2 audits 228 each, stage2 probes 7 and raw-C fixpoint pass are
overlapping, snapshot-specific proofs. The canonical-source checkpoint repeats
538 owner and 7 functional leak-checked styled-source controls. The
[assembled-root checkpoint](../benchmarks/results/fixed_union_concrete_binder/ASSEMBLED.md)
separately passes selected 609/609, CTFE 191/191, styled leak controls 7/7 and
three actual executable launchers; historical broad/fixpoint gates were not rerun.
Matched ordinary lookup costs add one allocation/release per successful query
and about 5.08% tracked whole-process instructions in the retained workload,
not whole-compile overhead or a speedup.
Aliases, generic bounds, automatic Eq, Hash, native admission, and bootstrap
remain open.

**Next common Eq contract (not implemented):** the legal provider-owned private
Eq control returns custom False; an importer cannot see that implementation and
would receive the future tag default. Selection is module-owned while the shared
tag body may be assembled once per nominal type. The earlier orphan-consumer
probe is negative setup evidence only, not a dispatch bug. Generic bound checks
currently carry no selected witness: concrete nongeneric Eq and generic dispatch
are separate checkpoints. Caller-selected evidence is the settled policy for
all traits; the shared mechanism below is not implemented.
General Eq evidence also admits generic calls and implementation bounds; it is
not safe to publish before that mechanism and admission are closed.

#### General caller-selected trait evidence

The policy applies to every trait, not only equality. Trait and member identities
are resolved lexically at the generic declaration. When a concrete caller checks
a bound, it selects evidence through its accepted module authority using those
exact identities and applicable implementation bounds. It does not re-resolve
trait spellings at the caller or change orphan admission.

Carry that exact static selection through nested generic forwarding, default and
inherited members, specialization, and generated callbacks. Neither the generic
callee's module nor a global registry may reselect it. Preserve declaring-member
identity and effective purity, dimension, resource, and bound metadata. Selection
must prevent namesake substitution, private-implementation leakage, and fallback
to a bound-inapplicable implementation. Monomorphization keys distinguish
genuinely different witnesses and reuse equivalent selections.

Recursive selection and transport remain pending; the accepted static foundation
and lexical slots are recorded in the current execution checkpoint above.
This specifies semantics, not runtime
dictionaries, heap allocation, a cache schema, or completed coverage. Use one
shared mechanism for all traits, with Stringable and user-defined Selector
controls alongside Eq/Hash; there must be no Eq-specific witness pipeline. Eq is
the first oracle, not the scope of the mechanism. Acceptance requires nested
forwarding to retain exact selected targets, instantiation keys to distinguish
different selections and reuse equivalent ones, and CTFE/runtime agreement.
General automatic Eq evidence remains gated on closure of this mechanism;
future coverage checkpoints must demonstrate default/inherited dispatch and
generated callbacks rather than treating the policy decision as implementation.

**Bounded implementation sequence:**

1. Preserve existing selected Core targets by exact ID. This prerequisite is
   published within `d9c737a86`; see the
   [selected-target evidence](../benchmarks/results/fixed_union_selected_targets/EVIDENCE.md).
   Independent validation of the frozen 31-file snapshot is complete; this
   prerequisite and its disclosed temporary costs are accepted for local
   integration. These historical results do not assert freshness after later
   integration. At that checkpoint, no main publication, push, release or
   bootstrap change was claimed. Lowering
   validates issued callable identity and owner. Core maps the selected ID to the
   actual method/enclosing implementation: canonical `SelectedTraitCall.module`
   is not the method's display `source_module`, so no module-name normalization
   or string-equality owner guard is valid.
   Generic implementation materialization must issue exact source-method /
   closed-receiver to concrete-method facts, retained across the append-only
   callable fixpoint. Preserve selected source identity inside materialized
   methods until one receiver-aware final remap before generic-data rewriting.
   Reuse canonical refinement erasure and structural equality/hash; conflicting
   remap facts fail closed through an explicit Result diagnostic. An absent remap
   may already name a concrete method or an exact authorized generic builtin;
   unavailable/duplicate selected IDs fail in the exact resolver, preserving that
   existing builtin exception without type/name fallback. Result propagation and
   mechanical test-call migrations
   change no Core IR, inference or admission policy.
2. Carry shared direct generic evidence through nested forwarding and canonical
   specialization-key identity, using the general policy above.
3. Close generic implementation bounds, default/inherited members, CTFE,
   generated callbacks and higher-order evidence capture before automatic Eq
   publication. These are coverage checkpoints, not permission for an Eq-only
   pipeline or provisional trait capability.

The next shared slice must retain legitimate dependency evidence, not exclude
existing programs to reduce scope: `List[T: Equatable]` element comparisons
([list](../standard_library/src/list.brp)) and `Option[T: Equatable]` payload
equality ([option](../standard_library/src/option.brp)); default Eq/Orderable
members used by [units](../standard_library/src/units.brp) and inherited Eq in
[tuple](../standard_library/src/tuple.brp) ordering; and Stringable evidence
captured in [Dict](../standard_library/src/dict.brp) / [Set](../standard_library/src/set.brp)
formatting callbacks. These source-backed obligations are planning controls,
not newly executed coverage. Design a shared compiler-issued builtin/default
evidence product alongside source implementation selections, recursive
implementation-bound dependencies and lexical bound-slot forwarding before
coding. Preserve higher-order capture and require supported CTFE/runtime
agreement; automatic enum evidence cannot be fabricated selected callable IDs.

**Selected-ID prerequisite acceptance boundary:** missing or duplicate selected
IDs fail closed without name fallback. Both actual targets survive declaration
order changes; native versus source methods retain their authorized behavior,
and downstream callable IDs remain exact. Existing deferred/name routes remain
untouched. This first cut alone does not fix legacy-enum native/deferred dispatch,
private visibility, generic witnesses or CTFE. A genuine admitted legacy-enum
probe currently returns True for provider direct/forwarded and importer
forwarded/direct runtime comparisons, versus False in the no-private control;
the corresponding CTFE controls return False on both sides. Lower Core retains
`BinaryExpr`; specialization shares mono IDs and operator dispatch uses global
lookup. This is retained
follow-on failure evidence, not closure by this prerequisite. Independent actual
owner 180, selected 2,571 (including required Core ASan), CTFE 191, focused
runtime/leak 18 and broad 12,414 (compiler 6,571 / runtime 4,673 / leak 1,170)
pass; counts overlap. Normal and actual stage2 audits each pass 228, stage2
owners 180 and three exact-target leak-checked probes pass, and all three O2
fixpoint C emissions are identical. The evidence pins source/binary snapshots,
commands, raw logs and the broader compound-pattern failure demonstrated in
saved base2ac and frozen candidate snapshots, not a general ownership or
pattern-codegen repair. At that historical checkpoint, later main/origin
`4dc9a9ace` ("Preserve nested pattern guards") had advanced in another task and
was not integrated or re-tested in the saved snapshot; those failure findings
do not describe later main.
Receiver projection policy is inherited;
additional policy coverage remains unproven, not a demonstrated new regression.
Matched isolated costs are traits −5 allocations/iteration, mono +39 (+30%)
and about +26.93% tracked whole-process instructions. Six normal-only emissions
of the same frozen base2ac self input have identical C and about +0.699%
minimum whole-process instructions; this is not allocation or stage2 speed
evidence. Temporary costs are accepted for correctness under this roadmap,
not a performance win. Caller evidence, private visibility, CTFE coherence,
automatic common Eq/Hash, native ABI and bootstrap gates remain open.

**Historical caller-evidence baseline:** the diagnostic packet at `dde591ecd`
retains 5 passing and 5 failing cases spanning caller-private evidence,
List/Option forwarding, and CTFE/runtime divergence; non-Eq controls pass.
This remains frozen failure evidence, not a retest of current source. See the
[current execution checkpoint](../benchmarks/results/union_progress_checkpoint.md#current-execution-checkpoint)
for accepted static prerequisites and the remaining recursive/transport gates.

**Planned default/tag oracle (not yet observed):** compare a CTFE-materialized
payload-free union global with a runtime-produced value of the same constructor.
Current CTFE constructor equality compares nominal constructor identity and
arguments; backend `static_generic_union_initializer` can emit a distinct static
object while runtime nullary constructors use singleton pointers. Widening trait
evidence into pointer equality is therefore not a valid implementation.

```blorp
fixed union Direction:
    North
    South

cached: Direction = North

pure func choose(flag: Bool) -> Direction:
    if flag:
        North
    else:
        South

pure func same[T: Equatable](left: T, right: T) -> Bool:
    left == right
```

The concrete Eq regression asserts `cached == choose(True)` and
`cached != choose(False)`; generic `same` applied to the non-generic type is a
separate dispatch checkpoint requiring the caller-selected witness mechanism above.
Repeat with ordinary spelling and imported/qualified constructors; keep a
payload-bearing negative control while the payload derivation slice is pending.
For the complete contract above, the negative must instead contain a
non-Equatable payload; an Int/String-only payload union becomes positive.
Preserve the present fixture expectations until that implementation lands.
The separate Hash slice adds Dict/Set lookup,
membership, replacement/removal,
and cleanup across CTFE/runtime values. The phantom-generic follow-up repeats
these controls for concrete payload-free generic instantiations.
Inspect Core/C so folding both operands to the same pointer cannot hide the bug.
Custom Eq must also compare folded and runtime results; structural CTFE equality
alone does not prove coherence with an explicit implementation.

**Eq slice:** derive accepted payload-free shape in stage 06
`headers/type_header_graph.brp`, `headers/type_header_install.brp`,
`type_system/accepted_union_authority.brp`, and `type_system/env.brp`; maintain
nominal identity and ordinary generic rules. Emit real compiler-owned tag Eq
methods in `stage_08_core_lower/lower.brp`, using existing Core implementation
registration and `stage_09_core/trait_resolve.brp`. Evidence and executable
methods land together. Default suppression requires completed, bounds-aware
applicable explicit selection by resolved builtin `TraitId` and nominal receiver
identity, carried as reviewed facts to assembly; written Core trait names or an
exact-target census are insufficient. Red controls cover builtin aliases, unrelated
namesake traits, applicable/inapplicable blanket impls, and module/declaration orders.
`mono_impl.candidate_request` currently checks substitution/concreteness without
checking bounds; this source-backed selection risk motivates the bounded scope,
not a claimed user bug without a reproducer. The selection/assembly boundary
requires review before its implementation is chosen; overlap handling is not
yet validated. The conceptual generated body is a constructor match returning
an Int tag, followed by integer tag equality/inequality; this is not
new public source syntax. Do not use managed-pointer equality as a substitute.
Eq-only evidence must not enable automatic Hash or collection callbacks; those
require the separate Hash slice below.

**Hash slice:** generate tag Hash methods and actual Eq/Hash runtime callback
roles, then reuse `stage_09_core/hash_key_callbacks.brp` and the existing
`TraitHashKeys` path in `specialize_layout.brp`/`synth_hash_collections.brp`.
Compiler evidence alone cannot supply collection callbacks. Hash the logical
tag with the existing Int hash operation; logical tags are not foreign ordinals.
Explicit implementations win. Custom Equatable without explicit Hashable
receives no automatic tag hashing: hashed-container use requires explicit
Hashable and an actionable diagnostic. The compiler checks implementation
presence, not semantic compatibility; user-supplied methods obey the normal
Eq/Hash laws. Custom Hashable alone may retain default
tag Eq when normal trait registration permits it. Census current explicit enum
Eq implementations before migration; the declaration/impl intersection in
compiler/std/pkg currently includes `bool.Bool` and `lib/build_artifact.BuildNativeFeature`
(neither has an explicit Hashable impl). Preserve Bool's compiler builtin hashing
through a real shared canonical hashing policy/entry and regression, despite
its explicit builtin Equatable implementation. During BuildNativeFeature
migration, remove redundant Eq or supply matching Hash with tests; do not add a
name-based exception. Include paired/custom-Eq/custom-Hash tests rather than
assuming these defaults compose safely.

Prefer managed union tag operations/callback synthesis for these bounded trait
slices. Reusing scalar-tag storage as a shared union representation choice is
also coherent, but requires an atomic layout/boxing/matching/container/ownership
slice and must remove logical families, not rename enum semantics. Native
admission remains explicit under either representation. Do not expand into
arbitrary inline or niche unions. If canonical ABI preparation requires shared
layout/boxing/matching changes, stop the small native-authority slice and propose
a separately scoped atomic shared-representation prerequisite with concrete
affected identities/consumers and independent oracles; do not silently expand
P2a or preserve an enum logical family under a new name.

One logical union family does not require one physical Core schema. Scalar-tag
and managed storage may remain distinct physical products, with one nominal
constructor and trait-selection authority. Representation eligibility must
follow completed shape, not declaration spelling; storage alone grants neither
automatic traits nor native ABI admission. Physical schema convergence is not
a prerequisite for this shared-representation route.

**Accepted layout preparation (local):** `06fae9d3c` preserves the issued header
layout in the accepted union column; see
[`layout evidence`](../benchmarks/results/fixed_union_accepted_layout.md).
The selector remains LegacyEnum-only and case order unchanged. Before shared
shape eligibility, foreign admission needs independent explicit native authority,
including Option; storage must not grant ABI. No shared eligibility or
optimization is implemented by this preparation.

`EnumType` uses scalar native tags; ordinary payload unions use managed pointers
and different foreign admission. A pointer cannot replace a scalar tag. Audit
builtins as well as `foreign:` declarations. Exact
declared Bool identity preserves C `int`, `True = 1`, and `False = 0` independent
of order. `MemoryCounter` maps tags 0–15 to `blorp_read_memory_counter(long)`;
`DirectoryEntryKind` maps native `DirectoryEntry.kind: long` tags 0–4. The outer
`DeclaredAbiDirectoryEntry` does not validate its field automatically.
`net/tcp.IpFamily` also crosses builtin native `long family` arguments:
`IPv4 = 0`, `IPv6 = 1`, as used by the loopback/any-interface runtime host
selectors and pinned by the raw signatures in `runtime_decl.c`. This is a
required canonical preparation set, not an exhaustive native census. The codegen
audit's `compiler_record_layout.brp`/`compiler_record_layout_ffi.h` also pin foreign
enum fields to `sizeof(long)` and `state == 1`.

Read-only native scoping at source `c4c0833b9` found two preparation blockers
(measured/tested: none in this audit). In
[`net/tcp.brp`](../standard_library/src/net/tcp.brp), all five direct IpFamily
crossings produce resources: `listen_loopback`, `listen_loopback_any_port`,
`listen_any_interface`, `listen_any_interface_any_port`, and `connect_loopback`.
A public source wrapper around a private Int builtin is currently rejected by
[`decl.brp`](../blorp/src/compiler/stage_06_typecheck/decl.brp)'s
`validate_resource_signature_boundary`: builtin bodies are exempt, but ordinary
resource-containing returns are not. The existing
[`tcp_resource_return_carrier.brp`](../blorp/test/test_compiler/test_stage_06_typecheck/fixtures/typecheck/should_fail/tcp_resource_return_carrier.brp)
pins that rule; MemoryCounter's non-resource wrapper is not TCP precedent.

DirectoryEntryKind is an inbound native pointee field, not a direct argument.
[`runtime.c`](../blorp/src/lib/runtime/native/runtime.c) stores `DirectoryEntry.kind`
as `long` (tags 0–4); its destructor releases only the managed name. A managed
kind requires an atomic pointee layout/destructor and single-entry Option,
batch List, and stream ownership proof across
[`fs.brp`](../standard_library/src/fs.brp), the native result bridges, and
[`test_directory_resource.brp`](../blorp/test/test_runtime/test_sys/test_directory_resource.brp),
not just an argument encoder. Shared `ScalarTag` storage is a coherent
alternative already allowed above, but remains a separately reviewed atomic
prerequisite: one union model, shape-derived eligibility, explicit native
contracts, and common semantic/ownership consumers. This audit selects neither
implementation and closes neither native admission nor P2a.

**Native slice:** extend existing `type_system/language_surface_manifest.brp`
`DeclaredAbiType` authority for the exact standard-library declarations above.
`lowered_declared_abi_type` already validates standard-library origin before
consulting that authority. Carry width/signedness, explicit constructor mapping,
and direction through `lower.brp`, `stage_09_core/ir.brp`, `type_policy.brp`,
`c_type_layout.brp`, and affected backend/builtin projections; spelling, shape,
and accidental declaration order cannot select ABI. Exact Bool mapping must
not become source ordinal mapping. Pin all MemoryCounter selectors 0–15 and
DirectoryEntryKind constructors 0–4, including the recursive native field.
Document ordinals only where the native contract specifies them. Explicit `Int`
mappings for `ProcessStream`, `ProcessGroup`, and `Signal` in
[`process.brp`](../standard_library/src/process.brp) are adapter precedent.
User-defined tag contracts migrate to explicit Int encode/decode adapters, not
direct managed-union scalar FFI. Update `foreign_default_enum_param.brp` and
the codegen audit's foreign record field fixture to explicit native Int fields
and language adapters, preserving C `long` width and useful values. A decoder
returns Option/Result for unknown tags unless a total mapping is already
approved; no new invalid variant, fallback, or language panic is permitted.

**Admission slice:** validate each crossing early in stage 06
`foreign_validation.brp`, independently of transfer classification in
`stage_08_core_lower/ffi_boundary.brp`. Cover arguments/returns, recursive
aggregate fields, containers, callback signatures, and `Option[tag]`, including
pure/`@no_copy` boundaries. Unsupported scalar substitution by a managed union
rejects with an Int-adapter suggestion before affected declarations change.
Do not blanket-reject borrowed managed values: retain validated borrowed
managed-pointer ABI, with the exact pointee layout/lifetime/transfer contract.
Borrowing must not bypass admission checks or turn a pointer into a scalar.
Pin separate diagnostics for direct union arguments/returns, nested foreign
fields, callback union parameters/results, and unsupported Option/container
crossings; include positive validated borrowed-pointer controls.

Remaining crossing decisions require evidence before conversion: existing
`Option[scalar]` admission does not establish every native nullable/tag encoding;
callbacks need exact callable signature, context/lifetime and ownership rules;
borrowed aggregates need recursive field ABI and borrow-duration validation.
Inventory actual uses, preserve proven contracts, and stop an affected
conversion rather than infer representation from Option, borrowing, or shape.

Preserve allocation-free reads including selectors, wrapper matching, and cleanup.
A canonical scalar ABI or proven static-singleton adapter suffices; an `Int`
native argument alone is not proof. Retain stage-2 Core/C, active managed/raw
counters, and same-counter repeat controls. Allocating selectors stay outside the
interval; explicit raw scalar endpoints require an honest instrumentation record.

**Local MemoryCounter prerequisite complete:** accepted and locally committed as
`c4c0833b9`; see the [adapter evidence](../benchmarks/results/fixed_union_memory_adapter.md).
The public reader now uses an exhaustive native-tag encoder and private Int
builtin; its enum declaration and native `long` contract remain unchanged.
Four active intervals each retain nine zero event deltas (36 total), including
runtime-derived managed selector matching/cleanup. Independent owners pass
10/10; serial std/runtime/leak gates pass 5,835/5,835; stage-2 owners pass 6/6
and unmodified O2 raw-C fixpoint passes. These counts overlap, not additive.
This is bounded native preparation, not all-native-ABI or P2a completion,
enum conversion, a latency claim, or bootstrap publication/pin authority.

**Accepted local user-adapter prerequisite:** `66944f3e9` changes native fixture
crossings to explicit Int encode/decode adapters while preserving long widths,
external tags, and unknown-tag rejection. Independent review found zero blockers
or should-fixes; the foreign check, O0/O2 layout oracle, two leak-checked runtime
branches, warning sweep and full 229-case codegen audit pass. The
[native evidence](../benchmarks/results/union_native_preparation.md) retains the
historical build/fixture epoch and independent artifacts. This closes only the
fixture preparation, not canonical native authority, admission or P2a.

Fast feedback after a serialized FRESH build uses the owning suites:

```bash
scripts/compiler-build-status
bin/blorp test --timeout 180 blorp/test/test_compiler/test_stage_06_typecheck/test_accepted_union_authority.brp
bin/blorp test --timeout 180 blorp/test/test_compiler/test_stage_09_core/test_core_trait_resolve.brp
bin/blorp test --timeout 180 blorp/test/test_compiler/test_stage_09_core/test_core_hash_key_callbacks.brp
bin/blorp test --timeout 180 blorp/test/test_compiler/test_stage_07_ctfe/test_ctfe_globals.brp
bin/blorp test --timeout 180 blorp/test/test_compiler/test_stage_06_typecheck/test_typecheck_decl.brp
scripts/compiler-check --changed --plan
```

Put the new behavioral oracle under `blorp/test/test_runtime/`, with CTFE/Core unit
regressions under their listed owners and typechecking fixtures under
`stage_06_typecheck/fixtures/typecheck/`; register new compiler tests in the
ownership manifest. Run exact runtime/leak loops, inspect generated Core/C,
then relevant compiler, codegen-audit and sanitizer gates. No proposed red or
read-only routing command is passing behavior evidence.

**Accept each slice:** observed tag equality across CTFE/runtime materialization,
generic/default/custom-trait behavior and real Dict/Set callbacks; native widths,
explicit tags, recursive fields and allocation-free counters preserved; early
diagnostics teach adapters while proven borrowed-pointer contracts remain valid.
**Stop:** pointer equality substitutes for tag equality, evidence lacks executable
callbacks, custom equality receives automatic tag hashing without explicit Hashable
or a validated canonical shared policy, an ABI is
guessed, unknown tags gain a fallback, or preparation grows into an unreviewed
shared-layout rewrite. Traits and native admission must remain separate.

The earlier plan to publish/verify/pin a capability bootstrap before P2b is
superseded for this cut by the authorized tested local staging-host override.
Immutable pin rotation remains separately authorized deferred work. The earlier
capability contract remains: P1's release serves both checkpoints only with this preparation;
syntax alone or a local override is insufficient. The actual pin must compile
migration-shaped fixtures for `==`/`!=`, generic Equatable/Hashable, Dict/Set,
Bool tags, counter selectors/oracles, and native recursive directory-entry fields,
IpFamily builtin crossings and migrated user adapters, then build embedded
generators and fresh self-hosting. Metadata is common authority.

### P2b. Convert declarations and source-generating fixtures

```blorp
-- Before migration:
enum Direction:
    North
    South

-- After migration, during the synonym phase:
fixed union Direction:
    North
    South
```

Convert declarations mechanically, preserving nominal/constructor identity,
visibility/import aliases, and all values. Migrate docs and source strings, including
parser-fixture `PLAIN_CODES_HEADER = "fixed union PlainSyntaxCode:\n"` scanner and its
header together. Update diagnostics and expected output by intended behavior.
Classify native C/Python enums, `enumerate`, literature/identifiers, and negative
removed-syntax fixtures before replacement.

### P2c. Retire the source form and separate logical family

**Implementation checkpoint, not acceptance:** semantic `TypeKind.TypeUnion(UnionLayout)`
publishes `ScalarTagUnion` or `TaggedUnion`. Core uses
`UnionType(name, ScalarTagValue | ManagedUnionValue)` and one `CoreUnionDecl` with
`ScalarTagStorage` or `ManagedPayloadStorage(payload_storage)`; all variants share
actual names/tags/DefIDs and fields (empty for scalar storage). Scalar publication
requires no type parameters or payload fields. Ordinary/fixed source form remains
tooling metadata, not a layout choice or checked no-boxing promise. Retained
prior-host source-owner proofs and pending gates are recorded in the provisional
evidence linked above; P2c is not yet accepted.

Remove `EnumKeyword` from both lexers: `enum` becomes an ordinary identifier,
with positive binding/parameter/field/function-name tests and helpful diagnostics
for removed declarations. Delete the source form/`LegacyEnum` bridge, `is_enum`,
header/env family evidence, and separate `CoreEnumDecl`/`EnumType` logical paths;
remove only actual enum-specific CTFE branches. Scalar-tag
machinery survives only as shared shape/explicit ABI, never hidden enum compatibility.
Optional shared scalar strategy must not hold simplification hostage. Keep one
nominal union/constructor authority and exact active-payload ownership.

```bash
bin/blorp test --timeout 180 \
  blorp/test/test_compiler/test_stage_06_typecheck/test_accepted_union_authority.brp
bin/blorp test --timeout 180 blorp/test/test_compiler/test_stage_07_ctfe/test_ctfe_globals.brp
scripts/compiler-check --changed --plan
```

**Accept:** owner migrations and common trait/CTFE regressions pass; native
contracts retain defined behavior; retired-syntax diagnostics teach the new form;
classified census finds no enum logical family or accepted source declaration.
**Stop:** an ABI mapping is guessed, generic fixed unions inherit an enum ban,
an enum backend survives under another name, or payload ownership changes silently.

## P3. Prove the migration and audit cleanup

**Boundary:** production/compiler-new parity, typechecking/inference, CTFE,
formatter/editor/LSP, tools, ownership/runtime, native adapters, and self-hosting.
P3a checks payload-free and managed variants through parameters/returns, global
constants, aliases/imports, matching, generic instantiations, lists/dicts, captures,
and nested Option/Result. Include payload-bearing negative trait cases, removed
enum syntax, unsupported foreign positions, and unknown native tags.

P3b reviews generated C from a stage-2 compiler for scalar-vs-pointer signatures,
tag mappings, layout/alignment, active-payload retains/releases, static values,
temporary ownership, and warnings. Run the stage-2 codegen audit, runtime/leak
and relevant sanitizers; require stage-2/stage-3 C fixpoint for changed emission.

```bash
bin/blorp test --timeout 180 blorp/test/test_compiler/test_stage_09_core/test_core_match.brp
scripts/test --serial compiler-blorp compiler-new compiler-new-parity compiler-tools std-check
scripts/test --serial runtime leak doctest cli-deep lsp package compiler-core-sanitize
bash blorp/test/test_compiler/test_pipeline/codegen_audit/run_codegen_audit.sh bin/blorp --jobs 1
scripts/compiler-fixpoint
```

Repeat the audit with the retained stage-2 executable; stage 1 alone is insufficient.
Run compiled jobs serially on macOS. Retain real packets/counts, not hand-composed
pass lines; source censuses supplement runtime gates.

P3c independently reviews obsolete wrappers, duplicate authorities, dead imports/
variants, compatibility codecs, and stale docs. Cleanup inventory needs owner
review; sizeable cleanup is separate. Apply this checkpoint after each phase.

**Pending bounded match-access hardening:** common `UnionTagConstructorTest`
decodes its `ScalarTagAccess`/`ManagedTagAccess` separately from the scrutinee.
Current declaration/value storage checks do not also validate that match-access
fact. Valid producers currently choose correctly; the audit found no observed
source regression. Validate access against the actual resolved subject/accessor
type and issued parent identity at the appropriate whole-Core boundary, with
both scalar/managed mismatches rejected and canonical Option/Bool controls
unchanged. The local decoder lacks subject context; do not substitute name
heuristics. Owning seams are `decode_core_constructor_match_test_json` in
`stage_09_core/ir.brp`, `union_storage_violations` in `late_invariants.brp`, and
`emit_constructor_match_test` in `stage_10_backend/emit.brp`. This follow-up is
pending, not an implemented P2c guarantee.

**Implemented bounded builtin-ownership repair:** the closed native-managed
IpAddress/DnsName/InterfaceScope category preserves issued accepted authority
through typed graph/Core publication and checked canonical-key projection;
shared leaf ARC/native-pointer policies consume the Core witness. The unchanged
strict IP probe passes 48 allocations/48 releases/zero leaked objects or bytes,
and TCP passes 18/18. No managed-name whitelist, String alias or trait/FFI policy
expansion was added. Broader P2c/P3 acceptance, current fixpoint, bootstrap
capability closure and migration costs remain pending.

**Accept:** independent reports, behavior/native/ownership gates, warning review,
fixpoint, and migration costs retained. Reported temporary performance regressions
are acceptable during simplification; ownership/ABI failures and hidden fallbacks are not.
**Stop:** unresolved corruption/leaks, unexplained native warnings, inconsistent
self-hosting, unverified tool paths, or missing evidence behind a claimed pass.

## P4. Optimize one shared union representation authority

**Dependency:** P3's simpler common model and common syntax-capable baseline.
**Boundary:** concrete Core specialization, representation/type policy, ownership,
prepared allocation facts, backend/runtime, and affected container/capture layouts.
Coordinate with [record placement](FIXED_LAYOUT_ROADMAP.md),
[tuple storage](VALUE_TUPLES_AND_STATE_HANDOFF.md), and
[allocation facts](ALLOCATION_CONTRACT_ROADMAP.md); tagged sums retain their own
variant semantics and must not be forced into a record model.

The following literate sketch is conceptual, **not a binding ABI or public API**:

```blorp
union UnionShape:
    PayloadFree
    PayloadVariants

union UnionRepresentation:
    ScalarTag
    InlineTagged
    NullableNiche
    Boxed

union UnionConstraint:
    OrdinaryPlacement
    CheckedFixed
```

Shape owns variants/fields, representation owns storage, and `CheckedFixed` requires
both fixed-payload admissibility and the placement guarantee. Absence of a union
box alone does not prove fixed admission. Build one validated concrete plan after
required specialization, before ownership/backend consumers need it. Late-generated functions/types must
enter or validate against that authority; emitter heuristics cannot choose layouts.

P4a optimizes common scalar tags. P4b optimizes ordinary unions with eligible inline
payloads, including managed children, with ARC for exactly the active variant.
This also applies to the temporary synonym; shared machinery does not imply
checked fixed unions admit managed payloads. P4c admits proven
Option/Result/nested-union niches: `None`, `Some(None)`, and `Some(Some(value))`
remain distinct. P4d extends admitted layouts through real storage/call/capture
boundaries. Each is a bounded measured change.

The first preparatory cut shares the runtime stack-Option suffix catalog between
specialization, runtime-provided typedef classification and immediate Result
payload admission. Result retains its named-Void exclusion and pointer/handle
exceptions; C type spellings and erased boxes retain their distinct ABI sets.
This behavior-preserving catalog consolidation does not admit new union layouts
or complete the shared concrete representation plan above.

The next preparatory cut shares unprojected stack-Option C type selection across
preparation, list synthesis, collection specialization and erased boxing.
Primitive C spellings remain literals; backend symbol projection and the erased
box adapter's named-Void allowance remain explicit separate boundaries. This
deletes the three private C-type copies without admitting new representations.

```bash
bin/blorp test --timeout 180 blorp/test/test_compiler/test_stage_09_core/test_core_type_policy.brp
bin/blorp test --timeout 180 blorp/test/test_compiler/test_stage_09_core/test_core_match.brp
```

**Accept:** ordinary/fixed declarations share optimization machinery for payloads
each admits; managed-payload optimizations remain available to ordinary unions;
concrete layout and ownership oracles, generated-C audit, leak/sanitizer/fixpoint
gates, and matched allocation/instruction measurements support each admission.
Intentional representation changes need no old/new C identity mandate; normal/
diagnostic C identity within each pair and stage-2/3 fixpoint still apply.
**Stop:** missing nominal identities, collapsed nested states, inactive-variant
ARC, unsupported late-generated types, a second layout authority, or an optimizer
benefit claimed from C size/source counts without measured costs.

## P5. Activate checked fixed unions

**Dependency:** P4 proves enough shared layouts and all guarantee boundaries.
**Boundary:** declaration admission, concrete placement constraints, diagnostics,
ownership/allocation plans, containers/captures/generics, native ABI, and docs.
`fixed` now requires admissible fixed payloads as well as no separate union-value
allocation or intermediate payload adapter box for admitted construction/copy,
relevant update, passing/returning,
nested union/record/Option/Result, list/dict slots, captures, generic instances,
or erasure. Inline storage inside an already allocated heap container is allowed;
container growth does not relax payload admissibility. Direct or nested `String`
payloads reject at declaration admission, including unused or unreachable variants.
A fixed-size pointer representation or a preexisting `String` is insufficient.
Additional payload-type eligibility must be agreed with the checked-record policy;
this roadmap does not invent a complete pointer or foreign-type whitelist.

P5a audits every interim fixed use before activation: admit it with proof, migrate
it to ordinary `union`, or reject it with a precise diagnostic. Declaration
incompatibility rejects; payload failures or unsupported positions name the
admissibility or boxing boundary and offer ordinary `union` or a supported shape.
Silent boxes are forbidden. Enforce at the
earliest phase with sufficient facts, including specialization when necessary,
and validate final prepared/Core/emitter plans against the same constraint.

A bare recursive `Next(SelfTail)`/`End` fixed union has no finite inline layout
and rejects with ordinary `union` as the alternative. Ordinary unions retain
managed recursive representations; fixed admission needs the shared payload policy,
not a claim that a managed child fits into a pointer-sized slot.

P5b decides native ABI and header observations (`memory.refcount`, `is_unique`,
`same_object`, and `size_of`) explicitly. Queries cannot substitute a child's
header for an inline union or invent a fictional count. Define supported
observations/rejection with matching ordinary-value behavior.

P5c retains exact scalar intervals: active flags before/after warmup and measurement,
reports afterwards, observable results, and allocating positive controls. Pair
static proof with ownership/state tests for aliases, temporary parents, cancellation,
escapes, variant changes, and cleanup; counter zero alone is not universal proof.

**Accept:** every admitted position has static and runtime evidence; unsupported
positions reject. Direct/nested `String` payload declarations reject even when the
variant is unused, with an actionable ordinary-`union` suggestion; the ordinary
equivalent remains allowed and receives eligible shared optimizations. Compiler/std
fixed uses pass bootstrap/self-host gates and the P3 review/cleanup checkpoint.
Update Guide/Grammar now to distinguish this guarantee from the retired synonym
contract. **Stop:** a hidden adapter box, unclassified erasure/container/callback,
header-observation ambiguity, incomplete allocation coverage, or an existing
fixed use admitted without proof. Completion is the enforced contract, not syntax.
