# Remaining first-order source migration ledger

## Status and boundary

Remaining work is planning only. The written-fields port is accepted; its
[report](../benchmarks/results/blorp_2_first_order_written_fields_2026-10-18.md)
records current functional and fixed-baseline cost acceptance. This ledger
grants no further implementation, compiled job, cost setup, new baseline or exception. The [source plan](BOOTSTRAP_SOURCE_PLAN.md#acceptance-and-cost-boundaries)
still requires a complete estimate and cumulative ceiling before broad callback
removal. Pilot allowances are not additive permission.

The original planning snapshot starts at accepted
`f1a27fcb2cfc1b951dd27e4ffa0e10e9e1e226b3`. That snapshot has the already landed
type-argument and unary preparation ports. Sorter, six fills and scalar adapters
remain separate held candidates. Opaque composition is a separately reviewed
input, not transplanted into this branch. Its specialization still has eight
`translated_list` calls, eight lambdas and one function-typed parameter; the
existing first-order type-list operation is named `semantic_arguments` there.
The accepted written-fields port removes two of those calls/lambdas; six
`translated_list` callers and its function-typed parameter remain.

Evidence is the source plan's historical 64-call/53-lambda inventory, the existing
post-sorter/fills 51-call inventory, maintained reports/plans below, and root's
independent opaque-composition audit. The evidence index under ignored
`build/remaining-callback-ledger/` pins these exact inputs. This is a source
planning record, never a measurement freeze or fresh bootstrap acceptance claim.

## Count reconciliation

| Source state | HOF calls remaining | Executable lambdas remaining | Explanation |
| --- | ---: | ---: | --- |
| Historical source-plan census | 64 | 53 | Seven fills, twelve projections, twenty-four scalar/pipeline adapters, seven predicates, eleven translations, three sort passes |
| Before written fields | 60 | 49 | Three type-argument callbacks and one unary ownership-use fill already removed |
| Accepted source | 58 | 47 | Two written-field callbacks removed by one typed domain loop |
| Plus held sorter | 55 | 44 | Three sort callbacks removed |
| Plus held six fills | 49 | 38 | Six constant-fill callbacks removed |
| Plus held scalar adapters | 46 | 36 | Two lambdas and named `list_inference_type` callback removed |
| Complete proposed callback migration | 0 | 0 | Remove the remaining six translation calls and forty other calls; delete the function-typed helper after its final caller |

The final 46 calls contain 36 lambdas and ten named callback arguments. They
are fifteen scalar Option/Result adapters, six pipeline error adapters, seven
predicates, twelve collection projections, and six fallible translations.
The original census found no stored/returned callable; that historical finding
is not a claim about arbitrary future source. Nested `?=` simplification is a
different migration and removes no additional callback call.

Count the union-row scalar hunk once. Opaque composition already replaces that
`next_nominal` map while admitting opaque rows. The chain above reserves that
same removal under the three-site scalar port: after composing opaque first,
subtract only the scalar port's two remaining inference adapters, not all three
again. The canonical scalar-port physical row below owns this overlap; adding
an opaque feature diff must exclude its duplicate hunk from combined totals.

## Spent ports and physical accounting

Counts include readable physical imports, comments and blanks. They are actual
diffs, not ceilings. Held candidates are counted prospectively once, and their
validation/cost limitations remain held.

| Port | Production added/deleted/net | Tests added/deleted/net | State |
| --- | ---: | ---: | --- |
| Three type-argument translations | 28 / 18 / +10 | 44 / 0 / +44 | Landed; [report](../benchmarks/results/blorp_2_first_order_type_arguments_2026-10-18.md) |
| Written record fields | 29 / 12 / +17 | 47 / 1 / +46 | Landed; [report](../benchmarks/results/blorp_2_first_order_written_fields_2026-10-18.md) |
| Six remaining fill maps | 11 / 9 / +2 | 0 / 0 / 0 | Held, 154B/154C characterization; twelve mutations pending; [plan](FIRST_ORDER_FILLS_PLAN.md) |
| Stable List ordering | 56 / 4 / +52 | 346 / 2 / +344 | Held, functional B41/C41 plus join/runtime green; mutation pairs pending; [plan](STABLE_LAYOUT_ORDER_PLAN.md) |
| Three scalar adapters | 10 / 3 / +7 | 0 / 0 / 0 | Held, implementation and finite69B/69C plus three mutation pairs prepared; not run |
| **Callback-port subtotal** | **134 / 46 / +88** | **437 / 3 / +434** | Does not claim resource acceptance or include a fictitious unary sub-hunk credit |

The one already removed ownership-use fill is contained within the landed unary
preparation, which is **432/265/+167 production and 969/522/+447 tests** in its
[report](../benchmarks/results/blorp_2_unary_preparation_2026-10-18.md). It is not
separately charged as another fill or assumed to explain that entire refactor.
Including that whole preparation gives **566/311/+255 production** and
**1,406/525/+881 tests** alongside the callback-port subtotal.

Other spent SOURCE migrations are the 28 construction functions
(258/200/+58 production, 70/56/+14 tests) and sixteen argument-control lifts
(110/132/-22 production, no test delta). Their
[construction](../benchmarks/results/blorp_2_construction_values_2026-10-16.md)
and [argument-control](../benchmarks/results/blorp_2_argument_controls_2026-10-16.md)
reports remain authoritative. Adding those separate source migrations produces
the selected-ports context **934/643/+291 production** and
**1,476/581/+895 tests**, before remaining work. This is not an assertion that
those ports are the whole Git delta or resource cost from original R0: accepted
language features and other changes also exist. No percentage gains are summed.

## Complete remaining callback estimate

These conservative upper forecasts describe one whole remaining migration, not
five independently stackable allowances. They require root/peer approval and
exact per-slice characterization, diff and oracle maps before writing. No
unimplemented M7 feature is counted as deleted production code.

| Remaining family | Calls | Gross added production upper | Net production upper | New nonfixture test upper |
| --- | ---: | ---: | ---: | ---: |
| Scalar Option/Result matches | 15 | 180 | +45 | 100 |
| Pipeline error matches | 6 | 45 | +20 | 60 |
| Short-circuit predicates | 7 | 80 | +50 | 80 |
| Typed projections/local builders | 12 | 180 | +100 | 180 |
| Six remaining fallible domain loops | 6 | 370 | +220 | 340 |
| **Remaining callbacks** | **46** | **855** | **+435** | **760** |
| Separate nested-propagation simplification | 0 | 45 | +25 | 80 |
| **Combined future upper forecast** | **46** | **900** | **+460** | **840** |

The original independent opaque audit reserved 420/+260 and 400 test additions
for seven domains. Removing the written-fields reservation (50/+40/60) leaves
370/+220/340 for six domains; the actual 29/+17/47 is charged as spent above.
The other upper bounds are planning forecasts from the existing classified
sites, including reindentation of retained bodies in gross additions. They are
not observed patches or validated economic decisions. No new language fixture
files are forecast; existing phase inputs and ordinary-main fixtures remain the
oracles. If actual coverage needs another fixture or a higher bound, review it
before exceeding the chosen ceiling; do not delete tests or compress formatting.

The resulting callback-specific upper, including spent callback ports, is
**989 added / +523 net production** and **1,197 added / +1,194 net tests**.
Including whole unary preparation is **1,421 added / +690 net production**.
Including construction/control source context and the separate propagation
proposal is **1,834 added / +751 net production** and
**2,316 added / +1,735 net tests**. These differently scoped totals must not be
presented as the same number. The historical callback estimate +442–739 was an
estimate, not an approved ceiling, and did not license these broader subtotals.
The combined future 900/+460 forecast fits below the remaining reviewed ceiling
below; write permission is never inferred from that old range or pilot caps.

### Reviewed combined hard ceiling

The original combined 1,000 production additions/+530 net/930 test additions
ceiling is not renewed by landing written fields. Its actual 29/+17/47 consumes
that allowance, leaving **971 production additions/+513 net/883 test additions**
for the remaining callback/propagation work, including future composition.

The original review approved one **combined hard ceiling: 1,000 production
added / +530 net / 930 test added**, inclusive of nested propagation. Its
original 950/+500/900 forecast fit inside it. Domain rows and later slice
limits consume this same ceiling; none adds to it.

Including spent callback ports, the hard ceiling's cumulative scope is
**1,105 production added / +601 net / 1,320 test added**. Including whole unary
preparation instead is **1,537 / +768 / 2,289**; including all selected source
context is **1,905 / +804 / 2,359**. These are three accounting views of the
same ceiling, not additional allowances. The [SOURCE fixed-baseline contract](BOOTSTRAP_SOURCE_PLAN.md#source-cost-acceptance),
exact output/C, zero leaks and existing absolute caps govern acceptance. Approval of this
ledger authorizes no source writes, sampling or landing.

## Owning sites and bounded order

Anchors below use the opaque-composition audit input. The evidence index retains
its source hash so line drift cannot silently retarget a slice. Existing held
ports must be composed narrowly before a remaining-call count is claimed.

1. Scalar matches: `check/expressions:355,410,476,533,566`,
   `check/render:218,952–957,1301,1305,1310`, `own/own:611`, and
   `verify/verify:1089,1383,2063`. Preserve child evaluation once, exact Result
   errors and Option fallback, field-spelling before owner-spelling failure,
   and invalid-owner→missing-parameter→invalid-spelling diagnostic priority.
   Keep substantial verifier actions inline at their existing boundary.
2. Pipeline matches: `main:30–35`. Keep `render_failure` for the checked
   program's complete source inventory and `singleton_diagnostic` for each
   later phase. Do not conflate CheckFailure with a single Diagnostic or add
   an error-context carrier.
3. Predicates: `emit:237,2594`, `verify:350`, and
   `check/declarations:731,733,829,834`. `has_payload` already owns its loop;
   the four declaration calls can share a private argument-list predicate
   invoking existing `contains_parameter`. Do not substitute the distinct
   identity-specific `recursion.contains_parameter_id`. Preserve early exit
   and surrounding `and`/`or` evaluation order.
4. Projections: `check/signatures:439,442`, `check/bodies:861,874,1058`,
   `check/constructors:175`, `check/recursion:121`, `check/declarations:176`,
   `specialize:202,2834,2837`, `main:85`. Each local builder retains its domain
   order and original child action; only complete lists are published.
5. Fallible translations: the six remaining domains below. End by deleting
   `translated_list` and its function-typed `translate` parameter, never before
   its last caller. `semantic_arguments` is already first-order and is not
   reimplemented, re-counted, or given the spent type-argument allowance again.

| Domain | Original opaque-audit call anchors | Existing child authority | Share of remaining 370/+220 upper |
| --- | --- | --- | ---: |
| Inherited update fields | 2416 | Existing retained-field translation and span | 45 / +25 |
| Statements | 2541 | Existing statement translator | 65 / +35 |
| Signature parameters | 2652 | Each existing TypeUse's own span | 50 / +30 |
| Bindings | 2686 | Existing binding identity/origin/type translation | 55 / +35 |
| Tail arms | 2712 | Existing arm/pattern/body translation | 75 / +45 |
| Function requests | 2784 | Existing request/instance lookup and function translation | 80 / +50 |

That table apportions one remaining upper forecast. Written fields are complete:
one private `translate_record_fields` serves both sites at actual 29/12/+17
production and 47/1/+46 tests, below the original 50/+40/60 reservation. It uses
no opaque-only argument; future opaque composition must preserve its same
field-ID-before-child authority and authored order. Other loops stay in existing
boundaries unless a helper earns its place through reuse or an existing
domain/recursion contract. Pass the
actual required constants, substitutions, keys, layouts and opaque facts;
introduce no argument-context bag, task enum or generic callback replacement.

Opaque-audit child authority (before future composition):

```blorp
id ?= translate_field(field.field, owner, records, field.span)
child ?= translate_expr(field.value, constants, substitution, keys, unions, records, opaques)
Ok({ field = id, value = child, span = field.span })
```

The first-order loop calls that child unchanged, appends only successful fields,
records the first error and breaks; it returns Err without publishing the partial
list. Resolve a literal's owner before fields. An update stays
owner→base→written replacements→inherited fields. Keep written replacement order,
canonical field IDs, ordinals, values and spans. Checking already validated full
unique coverage; do not sort, re-resolve names or repeat that validation here.

The separate nested-propagation estimate covers explicit matches at lower:526,
verify:1654 and opaque-expression wrap branches. It is not a reason to add a
propagation dispatcher or reuse a callback-removal budget for broader syntax
cleanup. Its precise inventory and per-site error/cleanup order need review.

## Acceptance and cost stop rules

Every bounded source slice first runs unchanged baseline characterization, then
candidate characterization and sensitive mutations with required named witnesses.
Restore exact candidate production/test source bytes and modes, and verify all
source/library/test pins before classifying a result. Retain emitted C unmodified. Existing
diagnostic error paths retain exact message/help/source span and priority. A
setup/compiler failure is no semantic red or mutant kill. Preserve failed
attempts, correct metadata without rerunning valid results, and stop on drift,
unexpected failures, surviving witnesses or failed restoration. Root owns all
compiled leases and two review assignments; no parallel compiled work.

The completed written-field proof used the existing record literal/update
specialization owners plus a written-order case with two replacements and one
inherited field. Remaining domains need their own finite owner/oracle maps;
full component, ordinary-main and ownership/native gates remain integration
requirements. Existing first-order type-argument evidence is historical evidence
for that exact port, not acceptance of another span or argument domain.

Loops/builders remain compiler-source migrations while target managed-loop and
break cleanup are unfinished. Target List append/set currently copy a new root;
local ownership does not prove linear construction or a performance win. Do not
distort a correct model to avoid an unmeasured host cost.

The user-approved fixed-baseline policy governs remaining SOURCE slices; retain
historical R0 criteria/failures and report cumulative trends. Per-slice +3%
allocations and normal min3, absolute caps and exact outputs stay binding.
Do not roll/refreeze a slice after failure, add resource percentages,
replace schema1 construction-checkpoint metrics with an
exit TOTAL, or substitute functional c04/std91 for required frozen cost roles.
No fresh cost packet or baseline is created by this ledger. The known sorter
failure 10166>9923 against 9634 retains its historical FAILED verdict; new
acceptance requires a separately named fixed B and complete candidate.

Keep semantic strings at interning/discovery, loading, diagnostics and emission
boundaries. Namespace/type/layout decisions use their existing typed IDs. String
prefix/equality/path API gaps are separate library work, not callback emulation.
Resource acceptance must measure the actual integrated source/library composition,
including accepted features; physical-line subtotals never substitute for it.
