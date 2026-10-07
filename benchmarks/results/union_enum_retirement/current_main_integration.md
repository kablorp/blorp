# Current-main integration checkpoint

## Frozen 5fed integration: validation pending

The next integration merges main `5fed50a38` into the retirement feature after
the reviewed 7ab epoch below. Current source repairs are frozen; root's normal
immutable-pin O2 build passed and reports FRESH (`08bc4a862f41-dirty`, compiled
by `dev-dbc23276a2a6`, Clang 21, split 8). Binary SHA256
`2aac4cff9644f2f4f9b8efc82582db3ef60cdf2bae3746c20238c3942c7d1e30`;
compiler C `c0f24da2a49f39d271a6f127e150b3ba124cbf91e6a519c85ad0d1345d02b144`.
The earlier 904/904 result does not validate
this new record-derived equality/discovery epoch. Broad premerge, sanitizer and
fixpoint results remain pending; the historical Linux failure is not waived.

The production and discovery shared name vocabularies contain the same 236
spellings, including `not_equals` at row 235. Discovery-only rows are derived
from that list: tail_recursive 236, no_copy 237, debug_only 238,
resource_result_ordinary 239, into 240, max_threads 241 and `<impl>` 242.
Main's syntax nesting limit remains 128. The actual production fixture runner
discovers 856 marked `.brp` inputs: main's 854 plus four retirement/Hash controls
minus the two obsolete enum-only negatives. Its pure Python owner passes 13/13;
this registration proof is not compiler fixture execution.

Combined census caps against main are header `id` 74→77, type-system `id`
128→132, direct typecheck `name` 244→248, type-system `name` 85→87 and Core Dict
181→188. These preserve the previously reviewed +3/+4/+4/+2/+7 feature debts
on top of main's new source cases, rather than taking the larger conflict side.
The same source-backed rationales in the historical table below apply. Exact
sites are main 869→candidate 867 (+24/−26); main's additional backend ABI Dict
fingerprint remains, while the scalar-union Set fingerprint replaces the retired
enum one. Pure census passes 3,422 rows. No scanner, exemption, allowed boundary,
capability, coverage or source-revision policy was relaxed.

GUIDE retains main's record-derived and conditional collection equality, no
identity fallback, default tag equality for non-generic payload-free unions of
either spelling, and explicit Hashable. Payload-union derivation and checked
fixed-union guarantees are not claimed.

### Native ABI magic-spelling closure

Publication premerge quality stopped at four new findings and two stale entries
(`/tmp/blorp-union-ec665-premerge.KCD4l6/premerge.log`). The scoped allowlist
amendment records three closed `NativeManagedBuiltin` kind-to-ABI-key outputs
in `language_surface_manifest.native_managed_builtin_canonical_name` and one
collision-denial comparison in `lower.native_managed_core_projection_is_unambiguous`.
Native kind selection still requires a standard-library builtin header and its
issued type/module authority; the projection comparison can only reject a
different issued type's collision, not admit native identity by name. The two
removed entries were obsolete global ABI-name readers for `DnsName` and `IpAddress`.

Only those four rows, their rationale comments and the two stale rows changed;
production code, scanner and unrelated allowlist entries remain unchanged.
`scripts/check-magic-spellings --strict` passes with 509 allowlisted findings
and zero stale entries; `python3 -m unittest
blorp.test.test_build.test_check_magic_spellings` passes all 15 tests.
Raw before/after logs are in `/tmp/blorp-native-magic-closure.fxVxjr`.
This closes the specific hygiene failure, not the pending full premerge gate.

### Obsolete enum-only benchmark retirement

The next premerge attempt passed quality but stopped at benchmark tooling
(`/tmp/blorp-union-2af877-premerge.M7QCRi/premerge.log`): the old enum-field
probe reported `generated compiler C contains no compact explicit-enum fields`
instead of reaching its historical missing-field assertion. Its source inventory
excluded fixed unions, and `emitted_fields` required `site.enum_syntax == "enum"`
before guessing source-spelled C record and member names. That retired model
cannot observe the common union declarations or compact emitted symbols.

The obsolete `compiler_enum_field_layout` tool, its standalone shell negative
case and README instructions are removed. The common `compiler_record_layout`
runner, codegen fixture and all its guards remain unchanged; the final-Core
helper's authority is retained through the scoped-API migration below:
scalar-union byte fields, explicit wire tags and native ABI,
Boolean packing, O0/O2 sizes/offsets, and invalid symbol-mapping rejection.
This intentionally retires the historical whole-compiler source inventory and
mechanically widened-C comparison; the bounded common oracle is not equivalent
measurement coverage or evidence of a performance improvement. The premerge
failure remains a separate epoch; the full premerge retry and fixpoint are pending.

The focused shell contract and benchmark-tooling target passed, but the real
layout oracle then stopped before producing rows: its support helper still
imported the removed `c_record_member_of` API (raw diagnostic:
`/tmp/blorp-enum-tool-focused.ZjwwDm/oracle.stderr`). The helper now constructs
`c_record_member_scope` once per record and uses `c_record_member` with the same
field name and resolved `CoreFieldRef`. No compatibility wrapper or guessed
member spelling is introduced.

The repaired focused epoch passes all three commands in order:
`benchmarks/compiler_record_layout` (16 actual native rows: eight layouts each
at O0/O2), the shell contract above, and `make benchmark-tooling-check`.
Scalar-union heap-state fields are one byte at offsets 24/25/26; foreign state
remains eight bytes and foreign Boolean fields four bytes. FRESH and tracked
inputs are unchanged before/after. These bounded layout facts do not replace
the retired whole-compiler measurement or establish blanket ABI correctness.
Raw evidence is `/tmp/blorp-record-helper-focused.XT9NKH`; its `REPORT.md` SHA256
is `d6b803a68a5676f11eaefaac6c04e7e79efb8cc2bdc66ba21e8481b6d1e051cd`.
The earlier zero-row import failure remains distinct. Full premerge and
fixpoint validation are still pending.

### Subsequent compiler gate setup failure

The next premerge epoch passed build, quality and benchmark tooling, then failed
compiler validation. Native suite setup stopped before assertions; the separate
check-fixture phase passed 855/856. The raw aggregate is therefore
`compiler_blorp FAIL: passed=855 failed=2 tests=857`, not two executed assertion
failures. The driver stopped after that completed blocking verdict;
compiler-tools had begun automatically and was stopped, not accepted. Later
premerge gates were not completed or accepted; Docker and fixpoint were unrun.
Evidence:
`/tmp/blorp-union-1015-premerge.fSOuVN/REPORT.md`, SHA256
`1f6ea5caa1293e9fbb1cf91c2577259feacf4477c7a2bd3a0075cf8eec46cf22`.

Independently reviewed test-only repairs add the existing explicit no-native
authority to two hand-authored empty-table programs, inspect scalar storage by
exact variant match instead of requiring storage-carrier equality, remove two
duplicate module imports, and update two exact Hashable-help pins to the actual
current diagnostic. IDs, tags, assertion intent and fixture registration remain
unchanged. The focused follow-up passes Core lower 159/159, hash callbacks
20/20, header graph 61/61 and the exact repaired check fixture 1/1, each exit 0
(`/tmp/blorp-1015-test-repair.4zc8rf`). FRESH and input comparison are unchanged
(comparison exit 0). This proves those narrow owners, not the full aggregate;
remaining non-exhaustiveness and Range-authority diagnostics are not declared
resolved or attributed to cascading errors without the aggregate rerun.
No compiler production policy is changed by these repairs, and no phase
completion is claimed.

### Benchmark layout fingerprint repair

The separate c3b4 premerge epoch still failed native aggregate setup with zero
assertions; all 856 check fixtures passed. Its raw combined verdict was
`compiler_blorp FAIL: passed=856 failed=1 tests=857`. Compiler-tools began but
had no completed verdict; subsequent gates, Docker and fixpoint remain
unvalidated. Report: `/tmp/blorp-union-c3b4-premerge.pArgF8/REPORT.md`, SHA256
`f71a5cd611709486afe06e396941b5b3a02851040cadccb47b4155772c89b8c9`.

The omitted match was in the benchmark fixture's builtin-layout fingerprint,
not production header installation. The benchmark-only extraction preserves
existing layout fingerprint text and order, adds explicit closed native-kind
tags, and leaves the surrounding issued header identity fingerprint unchanged.
Three same-seed tests check exact fingerprints and separation from each other
and generic managed storage, rather than relying on different names or IDs.

The exact owning suite reproduced setup RED (exit 1, zero assertions), then
passed 14/14 (exit 0, empty stderr) after the reviewed two-file repair. The same
normal-pin O2 compiler remained FRESH, with compiler/Std inputs and binary/C
unchanged. Report: `/tmp/blorp-phase-profile-green.i7TexQ/REPORT.md`, SHA256
`11a3024e9cdc898b9a43168e817c292a7073e2c2c79300cbfbdf9ce06127ac77`.
This closes the owning benchmark matcher; it does not establish full aggregate
closure or classify all aggregate CTFE errors. Full premerge and fixpoint
validation still require a new successful epoch.

### Seven executed compiler assertion failures and bounded repair

The fe5c premerge epoch executed 6,075 native compiler assertions: 6,068 passed
and seven failed. All 856 production check fixtures passed; the combined record
was `compiler_blorp FAIL: passed=6924 failed=7 tests=6931`.
Report: `/tmp/blorp-union-fe5c-premerge.Cac6fa/REPORT.md`, SHA256
`e8f88818526b17fab8bc59b1877c251bcbf159129b238f35660c5c437e6738a8`.

Six failures were stale fixture expectations: explicit Hashable admission,
renamed fixed-point builtins, the native equality callback signature and the
separate accepted default-equality fact. Their repairs retain explicit Hashable,
exact trait identities, method ordinals and callback ABI rejection controls.
The seventh exposed a production name-ID bug: removing the enum seed shifted
`not_equals` to 235, but its constant remained 236 and selected `tail_recursive`.
The constant is corrected to 235; a bidirectional lexer roundtrip regression
records RED 68/1 → GREEN 69/0, and the unchanged derived-record target oracle
records RED 0/1 → GREEN 1/0 (pass/fail).

The rebuilt normal immutable-pin O2 compiler remained FRESH; all six owners
passed 479/479: lexer 69, derived equality 1, catalog 30, builtins 17, origin
agreement 21 and inference 341. Frozen source inputs and rebuilt binary/C
matched before/after those tests. Report: `/tmp/blorp-owner-green.1TKDPu/REPORT.md`,
SHA256 `1b5a2bec0289d8606649187e44e602a7322f44b83f0391968b68ff705d29f9d7`.
This closes those owners only; full premerge, Docker, sanitizer, codegen audit
and fixpoint remain unvalidated by this bounded follow-up.

## Historical reviewed 7ab integration epoch

Source base `535096f01` is being merged with `origin/main` at `7ab679600`.
The current immutable bootstrap is `dev-dbc23276a2a6`; historical retained-host
proofs in [checkpoint.md](checkpoint.md) are not proof of this integrated tree.
The third normal-pin O2 build passes and reports FRESH; native gates are still
pending, with no overall acceptance claimed. Actual compiled_by is
`dev-dbc23276a2a6`, source version `535096f01-dirty`. Binary SHA
`dd3ae8abc45ddab00f6500580dfec2d9037d1d6b27a8c04d2d06bc5ed2f40054`;
compiler C SHA `96f8168523ef0937cf2b33989584f95e9676fe78cee3e55762fb99c8f365d69d`.
Earlier mechanical setup failures remain distinct from this successful build;
local logs are `/tmp/blorp-retirement-merge-core.Z4XkR4/build-3`.

## Preserved boundaries

Main's production discovery table adapter remains separate from the isolated
one-pass tree projection used by tests/parity. Removed tree-owner replay and
enum-preview compatibility paths are not restored. Incoming live declarations
and generated fixture inputs use unions; `enum` remains an ordinary identifier.
The exact fixture router finds844 marked inputs: main842 plus four additions
and two obsolete enum-only negative removals. This is registration, not test proof.

The new formal grammar and inline fixed-record policy are preserved. `fixed union`
is still a temporary synonym, not a checked payload or no-boxing guarantee.
Default tag equality applies only to non-generic wholly payload-free unions;
authored equality wins and Hashable is explicit. The obsolete constant-False
hash capability/guard is removed, with actual Hashable obligation controls.
The closed native-managed authority transport remains explicit, not a name-based
ARC classification. Mechanical imported-model repairs are not new trait policy.

## Reviewed identity debt

Against main `7ab679600`, the candidate changes exactly five numeric caps.
The latest amendment changes three of them; the other two were already in the
retirement checkpoint and are explicitly approved here from their actual sites,
not merely because that checkpoint contained them.

| Boundary | Before → after | Source-backed accounting |
| --- | --- | --- |
| Header `id` member reads | 73 → 76 | Three issued header ID reads in native_managed_authority_from_headers: resolve module/name and publish the validated fact. |
| Type-system `id` member reads | 126 → 130 | Four issued-ID checks/projections: builtin_trait_evidence_registry_row validates its registry row; accepted_match_source_trait_implementation_with checks the requested declaration ID and retains the implementation ID in candidate and selected proof. Inherited checkpoint debt, explicitly reviewed. |
| Direct typecheck `name` member reads | 242 → 246 | Four union-layout uses in decl: graph-backed and graphless accepted-layout lookups, then source span and diagnostic text when layout is absent. Inherited checkpoint debt, explicitly reviewed; not native ownership admission. |
| Type-system `name` member reads | 80 → 82 | Two member projections: accepted callable to compiler-scoped member; registry method to canonical trait ID/ordinal. Two helper renames are count-neutral. |
| Core string Dict annotations | 181 → 188 | Nine added/two removed fingerprints: seven new annotations plus two count-neutral registry/query renames. Validation parameters, immutable capture and three actual decoder/invariant/synthesis phase snapshots; no table rebuild per read. |

The full main-to-candidate exact-site inventory is **862 → 860**, with24 added
and26 removed fingerprints, classified below. These are recognition fingerprints,
not a claim that every addition builds a new table or that every removal erases
identity debt.

| Boundary | Added / removed | Classification |
| --- | --- | --- |
| Env/scope scalar facts | 5 / 5 | Three shadow-filter fingerprints rename without_shadowed_enums to without_shadowed_scalar_tag_unions; Env and snapshot each rename one physical-layout field. The two separate default-Eq field fingerprints already on main remain unchanged. |
| Lowering | 7 / 16 | Four added checked native-witness/projection carriers replace thirteen repeated Dict parameter annotations. Three further pairs replace enum-name physical-kind table/read/build fingerprints with common scalar-storage facts. |
| Core | 9 / 2 | Seven storage-validation/decoder/invariant/synthesis annotations plus two registry/query renames, as accounted above. |
| Backend record layout | 3 / 3 | Enum-width Set fingerprints in c_heap_record_field_storage, classify_c_record_layouts and CRecordLayoutRegistry become common scalar-union width facts; no new Set budget. |

The latest amendment alone has six added/fifteen removed exact fingerprints and
the three cap changes73→76,80→82,181→188. Its before/after hashes below describe
that incremental amendment, not the entire main-to-candidate reconciliation.
The obsolete sparse-option budgets for CoreEnumDecl and CoreEnumVariant are
removed because those source families are gone; no replacement exemption is added.
All other numeric caps, allowed_boundaries, coverage, schema_version,
source_revision and capability records (including unsupported coverage) match
main. No scanner, exemption or allowlist policy changed. These maps still
use current canonical keys: this is reviewed feature debt, not a nominal-identity
or performance win.

Pure `scripts/compiler-identity-census --check` passes 3,404 rows with budgets within
baseline. `bash -n scripts/test` and `git diff --check` pass. The historical
managed-row cost cannot be applied to new inline rows.

## Matched allocation reconciliation

The fresh O2 narrow epoch passed 532 assertions and failed one exact load pin:
the fixed-union type family measured 286,205 against the old 280,201. The
parser-only allocation owner passed 29/29. A same-binary scratch measurement
then compared identical type-family inputs differing only in `union E:` versus
`fixed union E:`; input construction preceded each counter reset.

| Repeats | Plain load | Fixed load | Difference |
| --- | ---: | ---: | ---: |
| 500 | 70,183 | 71,687 | 1,504 |
| 1,000 | 140,192 | 143,196 | 3,004 |
| 2,000 | 280,201 | 286,205 | 6,004 |

At 2,000 repeats, isolated lexer counts were 164,089 / 168,093 (+4,004),
bridge counts 28,022 / 30,022 (+2,000), and parser counts 88,065 / 88,065 (0).
The six load, two lexer and four bridge/parser scratch assertions passed, with
zero diagnostics, retained token-count guards and active memory/oracle counters.
`lexed_bridge.brp` rewrites each contextual `fixed` IdentifierToken into an owned
token update; its repeated-name allocation control documents this per-token cost.
Thus lexer and bridge spelling products account for the full delta. Post-helper
live bytes were zero, but do not measure cumulative copying or prove no COW growth.

The load owner now pins fixed spelling at 286,205 and separately retains plain
spelling at 280,201. `EXACT_TOLERANCE` remains 100; no table-copy guard, fixture
router count (844), or production code changed. These test edits were independently
reviewed with zero findings and the edited load owner passed 25/25 in the twelve-owner
epoch below; scratch results remain separate from that owner validation.
Compiler provenance is the unchanged binary/C above under the normal immutable
pin. All 2,842 previously frozen source/Std/owner inputs matched during diagnosis.
Raw local packet: `/tmp/blorp-union-spelling-allocation.bdVJMs`; report SHA256
`fef1a19d775683ab0a0396d9d3a64ca109cd19f8f1ba52f6c1fafd6a3ab269d0`.

Local evidence (not retained repository logs):
`/tmp/blorp-union-merge-surface.952YFS` contains raw RED/GREEN census output,
before/after JSON and the exact amendment diff. Before SHA
`54e1144f408f7002ba9b28f045435332b10105b413403743834a32a9b5267e37`;
after `35f42258be25a16da8901d7b037b4daf8f2b63f00a77c167a2f8cb57c5eb1b96`;
diff `fa55d219563822e5e4225546bcc3bc041d434cbe966fe7258cebe97526a9dde9`.
Core accounting is `/tmp/blorp-retirement-merge-core.Z4XkR4/CORE_DICT_REVIEW.md`,
SHA `45c18053d989630c4b7cc147837825a08898148ea449f95229547385399972aa`.

The reviewed twelve-owner aggregate passed **904/904**, exit 0: Env 43,
header graph 61, trait call targets 2, Core trait resolve 63, Core JSON 151,
record representation 19, discovery adapter 122, tree projection 4, tree assembly 15,
parser allocation 29, load allocation 25 and Core emitter 370. It used
`bin/blorp test --suite --timeout 180`, normal pinned O2 with no ambient Std or
bootstrap override. FRESH status and all 2,841 enumerated source/Std/owner inputs
matched before/after; binary/C provenance above was unchanged. Raw local packet:
`/tmp/blorp-retirement-narrow-final.zUzd5t`; report SHA256
`86a0774eb52f8367e307551e45ca146a4b6b25bf25759dee1e26a17d7bae6bf7`.
The earlier helper-name collision stopped setup with zero assertions and is
retained separately; it is not counted as an executed test failure here.

Full applicable gates, formatter coverage, sanitizer, parity and O2 fixpoint
must still validate this merge after the merge commit and fresh build. Historical
failures are not waived by static census acceptance. Match-access/DirectoryEntry
hardening, migration costs, full payload/generic default equality and checked
fixed-union guarantees remain separate pending work.

The earlier [Linux publication failure](../scalar_union_bootstrap.md#integrated-publication-state)
remains separate:18696 passed/zero counted failures did not mean gate success.
Clang18/aarch64 sanitizer failed with function-type callback UBSan followed by
ASan CHECK/SIGSEGV in the runtime Int128/UInt128 hash suite; baseline classification
was unresolved. Raw local report: `/tmp/blorp-scalar-publish-docker-retry.Xc1ugc/REPORT.md`.
No current Mac build result closes that sanitizer failure.

## Narrow key-callback signature repair: publication still blocked

On feature `27268629c` plus the reviewed adapter repair, a closed hash/equality
slot role selects the runtime's `unsigned long`/`bool` return signatures.
Language implementations retain `Int`/`Bool`, their ordinary C returns remain
`long`/`int`, and runtime declarations and key storage are unchanged.

The emitter regression failed before the fix (370 pass, one signature failure)
and passes afterward (371/0). Separate focused owners pass: callback minting
20/0, JSON 157/0, backend projection 49/0 and origin agreement 21/0. These are
focused runs, not a combined premerge verdict. Normal immutable-pin O2 builds
report FRESH. Candidate stage-2 normal/profile C and fixture execution pass;
prototypes, definitions and profile result temporaries use the correct native
returns. The O2 fixpoint passes: stages 1, 2 and 3 emit identical 82,194,195-byte
C, SHA256 `9b7cc668e96821d40ce9698edfd242650db318c0b63e5c182469d4b7ae8e470e`.
Local evidence: `/tmp/blorp-hash-signature-finalfocus.G6LDwO/REPORT.md`, SHA256
`b999553e3a1e91e8faff11b76a73a21629917bd46f0abfccabb03ce794c0281b`.

The first stage-2 runtime leak control still fails: the UInt128 Set test reports
three leaked objects/96 bytes (11 pass, one failure). The retained pre-repair
stage-2 compiler and candidate produce byte-identical stdout/stderr using the
same fixture and `test --suite --leak-check --timeout 180` command. This failure
predates the narrow signature repair; it has not been classified against main
and is not waived for publication. The overall final leak summary does not
override the per-test failure. Comparison evidence:
`/tmp/blorp-hash-signature-finalfocus.G6LDwO/REPORT.baseline-comparison.md`, SHA256
`6ab07c746bcb050d122ba52d3946c683fbdb4015fdb24d4ffab1966127ce27bd`.
Further ownership work, the full audit and premerge gates remain pending.

## Publication authorization and remaining validation gaps

On 2026-10-07 the user explicitly instructed publication despite the known
stage-2 UInt128 Set leak above, then authorized commit and push after the
post-squash sanitizer timeout. These are publication exceptions, not fixes or
passing validation results; the earlier blocked results remain historical.

The post-squash source tree `48bd359e18f20582caaa352ec3be9c46a5c23e9f`
exactly matched feature `d90f201c39eb0c7c4fe921cc8433ebb15cb3f043` on main
`5fed50a38bf09d8e0e32c92965d59604a90c91fa`. The clean immutable-pin O2 build,
quality, benchmark tooling, all 19,096 native tests, all 233 codegen audit
checks, preview smoke, example checks and example runs passed. Source inputs
did not change during validation. Only this publication note was added afterward.

The full premerge command exited 2 with an actual FAIL verdict: the standard
Darwin sanitizer gate's 575-source batch timed out after 30 seconds. This is
distinct from the UInt128 leak; its cause and baseline status remain unverified.
Docker, security scan, and final drift/hygiene checks were not reached, and no
full-premerge or Docker success is claimed. The earlier Linux sanitizer failure
also remains unresolved. These exceptions do not complete the roadmap's
validation phase or establish the final checked `fixed union` guarantee.

Local post-squash evidence: `/tmp/blorp-scalar-union-publish.WKAdY7/REPORT.md`,
SHA256 `cc1ec0d48a22c5dd29ff33cd6e97ac44d744b8051100065a14b9df3a54794de8`.
All owned native jobs ended before publication.
