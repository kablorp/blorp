Current authority: the [approved status and bounded resource limits](#current-approved-status-and-bounded-resource-limits) below supersede the historical draft status, scope and ceilings where explicitly stated. The original reviewed text is retained; its pending-review statements do not reopen completed work.

Publication provenance: root and the independent qualified compiler reviewer
approved draft `1af2fc88bddfe872c92fb1ebea04d8c6e2ba82c51e68aefd0ffd46edfb09835b`
with zero findings. Implementation worktree base is accepted
`f3d6b94219977b0e46d243ebdc3b397fade770bb`, whose compiler source and complete
temporary library are byte-identical to the draft's `2f46f31` boundary. This is
source provenance, not a cost baseline roll or freeze. Root authorized publishing
and committing this plan, then test-only admission RED preparation. Production
still waits for reviewed probes and successful RED execution under a lease.

The reviewed draft below is retained, including its original pending-review
status, except for the root-suggested and peer-approved purely unsigned
subtraction-mutant clarification and the prospective test-only amendment below.
All other ceilings and SOURCE/cost-policy limits remain unchanged. [Blorp 2 rules](AGENTS.md), the
[source plan](BOOTSTRAP_SOURCE_PLAN.md) and [development rules](../AGENTS.md)
govern this work.

---

# Add signed Int ordering through the existing Bool contract

## Status, problem and scope

Draft for root and qualified compiler review, before code. No implementation,
test run, cost setup, baseline freeze, commit or new reviewer is authorized by
this draft. Source anchors refer to accepted `origin/main`
`2f46f31f9cd60798a17a86f403b1076bce415053`; `SOURCE.json` pins the read source.
The scalar-adapter, sorter and fill worktrees stay unchanged and separate.

The compiler source already calls host `IntOps.less_than` and `greater_than`.
The temporary target library supplies equality and arithmetic but neither
ordering function. This independent target-library feature provides exactly:

```blorp
pure func less_than(a: Int, b: Int) -> Bool:
    builtin("int.less_than")

pure func greater_than(a: Int, b: Int) -> Bool:
    less_than(b, a)
```

Add one builtin label and one ordinary wrapper. Greater-than has no builtin
label or second primitive. Host Int functions already exist; host production
and host stdlib do not change. Keep signed Int64 semantics, the existing
designated Bool, and ordinary declaration/import/UFCS identities. Do not add
operators, traits, Float behavior, inclusive comparisons, inequality, min/max,
source-call migration, a lookup registry, a comparison framework or runtime C
helper. Whole-source bootstrap remains incomplete after this leaf.

Read-only reproduction at this source boundary:

```sh
rg -n 'pure func (equals|less_than|greater_than)' blorp_2/standard_library/int.brp
rg -n 'IntegerEqualsBuiltin|IntEquals\(' blorp_2/src
```

Only equality is present in the target module. A normal fixture importing
ordering currently cannot compile. A phase source defining
`builtin("int.less_than")` is rejected as `unknown builtin operation` by the
closed parser. Both are real missing-feature reds, to capture under a lease.

## Contract and smallest production path

Int is signed 64-bit. `less_than(a,b)` is true exactly when signed a is smaller
than signed b; `greater_than(a,b)` calls `less_than(b,a)`. Arguments are evaluated
once by ordinary call evaluation before the wrapper reads them in reverse order.
Equal operands return False. No subtraction, unsigned ordering or narrowing may
implement the relation. With MIN=-9223372036854775808 and MAX=9223372036854775807,
MIN<MAX is True, MAX<MIN is False and both self-comparisons are False. Wrapping
subtraction would give MIN-MAX=1 and MAX-MIN=-1, reversing that ordering.

Follow the actual `IntegerEqualsBuiltin` producer/consumer route:

| Owner at the pinned source | Bounded change |
| --- | --- |
| `utils/syntax.brp:393`, `parse/parse.brp:2592,2655` | Add `IntegerLessThanBuiltin`, one closed label and its exact supported-label help; no `int.greater_than` label |
| `namespace/builtins.brp:89,169,191,216` | Add `IntLessThan(DesignatedBoolean[Variant])`; same Pure/two-Int/BooleanResult contract as equality; classify it as designation-dependent and reuse declaration help |
| `check/signatures.brp:352–388` | Construct `IntLessThan(site.designated.boolean)` once; existing validation owns arity, purity, nongeneric header and exact designated result identity |
| `specialize/specialize.brp:2209` | Translate existing designated constructors once with `translate_boolean`, then publish `Builtins.IntLessThan(translated)` |
| `emit/emit.brp:185,1305,1341–1395,2176` | Handle the operation, emit signed `<` over Int locals, and select the actual true/false constructors; mark no runtime helper requirement |
| `standard_library/int.brp` | Add the two ordinary declarations shown above; retain the original upstream provenance and note the target's ordinary greater-than implementation |

The lower/own/verify pipeline already consumes the sole runtime contract and
`BooleanResult`. Int arguments and Bool result are unmanaged. Add no operation-
specific production branch or ARC change there. Verify that through phase tests.
The Boolean result has existing checked identity, owner and constructor facts;
do not infer them from a spelling, assume owner zero, or return C 0/1 as tags.
The normal foundation declares True first, so its True tag is currently zero.

Current contract and acceptance at builtins:169 and signatures:388:

```blorp
IntEquals(boolean):
    { purity = Pure, parameters = [PrimitiveRuntimeType(BuiltinInt), PrimitiveRuntimeType(BuiltinInt)], return_type = BooleanResult(boolean) }

IntegerEqualsBuiltin: Ok(Builtins.IntEquals(boolean))
```

Add separate flat arms for the new operation with the same established
contract, and `IntegerLessThanBuiltin: Ok(Builtins.IntLessThan(boolean))`.
Do not introduce a binding or-pattern as part of this source change.

Current emitter uses private `EqualityComparison` with StringComparison and
IntegerComparison, through `append_equals`. It already owns argument lookup,
result declaration and designated true/false projection. Extend that existing
boundary rather than duplicating it: rename it to private `Comparison` /
`append_comparison`, use StringEquality / IntegerEquality / IntegerLessThan,
and rename its local equal/different results to true_value/false_value. This
small naming adjustment is part of supporting the additional relation; no
separate general preparation project, operator string parameter or callback.

Current integer condition at emit:1375:

```blorp
IntegerComparison:
    "(".concat(left_value).concat("==").concat(right_value).concat(")")
```

After, retain equality and add the third explicit emission case:

```blorp
IntegerEquality:
    "(".concat(left_value).concat("==").concat(right_value).concat(")")
IntegerLessThan:
    "(".concat(left_value).concat("<").concat(right_value).concat(")")
```

The code examples describe the current repeated string-construction lines
compactly; implementation retains normal readable physical formatting. The
existing common tail remains `condition ? true_value : false_value`, with
both values obtained from `c_union_value` using the published constructors.
Keep existing equality emitted C identical. The exhaustive runtime-name arm
may use its corresponding diagnostic symbol, as equality does; emit no call
to a nonexistent helper and no new runtime fragment or family flag.

## Test first, then implement

After both plan reviews and an isolated branch/plan commit authorized by root,
write tests before production. All compiled work requires the coordinator's
serial lease. Do not build or replay historical setup while waiting.

1. Add the smallest TestSuite acceptance callback using existing
   `module_input.parse_modules`, with a local pure two-Int comparison declaration
   and `builtin("int.less_than")`. It expects accepted syntax without importing
   the nonexistent new enum constructor. Capture the actual parser RED message,
   full current supported-label help, quoted-label byte span and status. Pin
   that transcript; do not guess the label span or claim it was run here.
2. Add one normal target fixture importing `int: less_than, greater_than`, with
   runtime operands parsed from argv through existing `string.parse_int` and
   `list.get`. Its ordinary main prints each result using a two-use
   `print_truth(Bool)` helper matching True/False to literal `1`/`0`; malformed
   arguments exit 2. It must compile through the real target compiler and
   temporary library. Capture its actual missing-API admission RED before
   production. No target-library fallback or B adaptation.
3. Implement the one leaf and wrapper, then add granular typed boundaries to
   existing matching phase suites. Reuse `module_input`, `input`, ownership
   inputs and ordinary compilation helpers, with no new test framework.

Required boundary coverage:

- Parser: exact closed label, typed operation and complete span; constructor
  arguments after the label still reject with exact teaching help.
- Namespace/runtime contract: arbitrary designated constructor IDs survive the
  Pure/two-Int/BooleanResult contract. Bool is nominal, not a two-variant shape.
- Checker: ordinary renamed function accepts; both parameter positions reject
  String, wrong arity, impure/generic header, Int return and foreign equal-shaped
  union. Check exact mismatch message, help, label span and error priority.
- Specialization: Bool constructors translate to the actual result instance.
- Lowering and ownership: two ordinary unmanaged operands and one unmanaged
  result/return; no retain/drop or managed result is introduced.
- Verification: accept that correct contract; malformed missing/wrong argument
  and duplicate/wrong-owner Bool constructors retain exact existing rejection.
- Emission: signed `<`, correct operand order and actual Bool constructor values;
  direct and UFCS calls to the ordinary wrapper; unused declarations select no
  helper; original Int/String equality C remains unchanged. A test foundation
  with reordered Bool constructors should prove tag identity when accepted by
  the existing foundation validator, without changing foundation rules.

Do not copy the historical cross-phase `test_own/test_int_equals.brp` wholesale
as the new feature owner: new boundary assertions belong in each matching phase
folder. Keep that existing eight-callback equality suite unchanged and green.
Update the existing closed-label help observers in parser, builtin, grammar and
any matching fixtures in the same change.

## Ordinary-main and mutation oracles

Use one source fixture at `test/e2e/fixtures/int/comparisons.brp`, at most 48
physical lines. Compile it once, link its unmodified C once, and run 27 argv
rows through its real main: all ordered pairs of MIN,-1,0,1,MAX, plus
(0,4294967296) and its reverse. Each run prints the less-than bit then the
greater-than bit on separate lines, status 0 and empty stderr. `CASES.json`
contains the complete literal expected rows, independent of compiler output.
Add its owner using the maintained e2e registration route, never a new selective
entrypoint. Existing signed literal, arithmetic and equality suites remain.
Inspect retained C; native linking uses existing strict C11/O0 warnings and
ASan/UBSan with no recovery. No generated-C rewriting or internal symbol calls.

Review exact mutations before execution. Separate type-correct mutants must
compile and fail a named semantic witness: `<`→`<=` (equal rows), reversed
operands (MIN/MAX cross rows), unsigned or early 32-bit ordering (-1/0 or
0/4294967296), a deliberately wrapping subtraction/sign relation (MIN/MAX),
swapped designated Bool selection, and greater-than accidentally calling
less-than without reversing its parameters. A UB sanitizer failure alone does
not prove the subtraction-order witness. Use the deliberately wrong relation
`(((uint64_t)a-(uint64_t)b)>>63)!=0`: subtraction and shifting are entirely
unsigned, and MIN/MAX cross cases expose its wrong ordering without a signed
conversion assumption. This is a mutation oracle, never the implementation. No setup/compiler-error kill claim.
Capture every actual failure; restore exact C and verify pins before result
classification, then rerun the affected owning suite green. Stop on drift,
unexpected diagnostics/status, missing witness or failed restoration.

Shortest iteration is the parser RED TestSuite, then contract/check and emission
owners. Final integration includes all affected phase suites, unchanged equality
and arithmetic tests, component unit/runtime/grammar, and the maintained complete
e2e gate with strict memory/caps. Build the compiler once per e2e run. Full gate
command/toolchain identities and counts are frozen prospectively after the exact
patch is reviewed; an empty manifest selection is not validation of blorp_2.

## Proposed physical and cost ceilings

Before implementation, reviewers approve or tighten these fresh hard ceilings;
they are not borrowed SOURCE pilot allowances:

| Category | Forecast | Proposed gross / net hard ceiling |
| --- | ---: | ---: |
| Production, including ordinary wrappers and necessary helper naming | 35–60 added, +20–35 net | 75 / +45 |
| Nonfixture tests across phase owners and e2e registration | Prospective 501 added / +498 net | 510 / +500 |
| One ordinary language fixture | 30–42 lines | 1 file / 48 lines |
| Public documentation, excluding this plan and final evidence report | 20–35 added | 45 / +45 |

**Prospective test-only amendment, 2026-10-18; root and independent review approved.**
Root reproduced the separate 20-line imported-global TestSuite crash once:
CLI status 1, harness status 139, empty stderr and no callback report. Retained
evidence is in ROOT `build/bootstrap-evidence/int-imported-global-probe-2026-10-18/`.
The witness source has no target compiler, Result, Option or generic declarations.
This remains an unresolved host defect, not a fixed bug or Int acceptance result.

Replace only the original specialization registry's two inline lambdas with two
ordinary named callbacks, each containing its exact existing `retains_bool_roles`
call. Preserve descriptions, callback count, arguments, helper and all assertions.
The readable wrappers add eight lines: current nonfixture tests 493 added / 3
deleted / +490 net would become 501 / 3 / +498. The proposed gross ceiling rises
from 500 to 510, leaving nine lines of readability margin; the +500 net ceiling
stays unchanged. Production 75/+45, one fixture/48 lines and every cost ceiling
stay unchanged. Root and independent review precede actual wrapper writes;
no coverage deletion, formatting compression or host-fix claim follows.

Count physical readable lines, including imports/comments/blanks; report
production, tests and fixture changes separately. No formatting compression,
deleted coverage or expanded runtime mechanism to fit. If a forecast fails,
stop for review before exceeding a ceiling. Publish supported API/closed label
and signed semantics coherently in owning Blorp 2 README, grammar, library parity
and temporary-library notes, plus parent GUIDE/GRAMMAR as required for API edits.

Int inputs and Bool output add no ownership allocation at native runtime.
Compiler/library admission costs and instructions are unknown, unmeasured;
adding two declarations can increase them. No speedup or zero-cost claim.
Proposed FEATURE contract for review: +5% allocation/instruction target and
+10% hard ceiling separately on every unchanged owned input and the supporting
host construction proxy; all tighter current absolute limits remain binding.
Proposed new-fixture absolute ceiling: 45,000 compiler allocations and
150,000,000 normal minimum-of-three instructions, assessed separately for each
argv role where compilation is involved; argv repeats do not multiply compiler
inputs. These are prospective limits, not measured evidence or a waiver.

No new-only input gets an invented B success or ratio. Root must choose the
actual accepted B/exact C, complete target libraries, same physical input paths,
corpus, producer/metric roles and packet before any cost sample. Adding accepted
features while planning does not silently redefine that baseline. Preserve the
original SOURCE R0 hold and failures independently; no original R0 roll, reset,
borrowed unary/type-argument exception or cost setup is authorized here.
Feature approval is not SOURCE migration acceptance. Match strict allocation
runs and normal min3 instructions serially, retain raw results/output identity
and all intentional new-label diagnostic deltas. Do not substitute functional
c04 for a separately required frozen cost producer or switch checkpoint metrics.

The six production files shared with Slice/Join are syntax, parser, builtins,
signatures, specialization and emitter; the temporary-library README also
overlaps. Reconcile narrow arms/imports/help against the accepted composition,
preserving accepted M2/Path and any separately integrated Boolean/annotation
work. Never transplant whole old functions. Root owns integration, review
assignments, lane and final gates.
Return exact branch/diff/LOC, RED/GREEN/mutation receipts, C review, cost verdicts
and limitations. No production commit/push until validation and both reviews.

## Current approved status and bounded resource limits

The human approved this exact bounded update on 2026-10-19 after two independent reviews. The retained [approval data](../build/bootstrap-evidence/int-ordering-approved-budget-2026-10-19-01/APPROVED_PROPOSAL.json) has SHA256 `50e270dbe3e3c97eabd106f1f59f2360126771768b33464601ad9f061c45ba45`; its [authorization clarification](../build/bootstrap-evidence/int-ordering-approved-budget-2026-10-19-01/PROPOSAL_CLARIFIED.md) has SHA256 `e0f074f0ade180d54a4e9624cf27346fdd5a75796dcc3e9c4ec2a5776f6937db`. Approval authorizes the listed cap and plan edits and required final validation without another permission question. Root still schedules the serial compiled lane.

Implementation is complete: one closed signed64 `IntLessThan` primitive uses the designated Bool; greater-than, both inclusive relations, inequality, minimum and maximum are ordinary functions; both Int bounds are scalar literals. The original fixed-e706 correctness protocol completed all 19 calls. Its original cost failures and raw evidence remain unchanged. The accepted-main `cd823cc4c9583b3dadbf8142073a01895a90bb18` composition has passed 3,598 unit/runtime/grammar callbacks and generated one C file with normal and diagnostic O0 links. Final current-composition native call 5 ran once after both independent APPROVE0 reviews and root START: exit 0, empty stderr, 633 named native callbacks and all four direct real-main checks passed; all 406 positive required cost counters stayed within the approved limits.

The completed gate used the existing maintained entrypoint and fresh source-matched compiler artifacts. All 1,131 printed callbacks passed, covering 47 owners, 497 outer callbacks and 402 nested native suites. The [final report](../benchmarks/results/blorp_2_int_comparisons_2026-10-19.md) binds both receipts, source and binary hashes, the original cost evidence and the acceptance limits. No source pilot, baseline roll, new paired cost sample, replay of the original 19-call protocol or test exclusion occurred. Root owns final publication review and integration; current-main SOURCE frontier and +3% proxy acceptance are not established by the retained original FEATURE measurements.

### Exact original-control exception

The fixed B remains `e706b393d51038ba49af720999d308fd95ce4ea9`. Only the nine original unchanged inputs and their frozen measurement roles receive these finite ceilings. Allocation ceilings are `min(floor(1.40 * B), B + 4200)`; normal-min3 instruction ceilings are `min(floor(1.15 * B), B + 5600000)`. These are count limits for this feature, not global percentage allowances or a new baseline.

| Original input | Approved allocation ceiling | Approved normal-min3 instruction ceiling |
| --- | ---: | ---: |
| `call/one.brp` | 14,877 | 43,985,285 |
| `ufcs/chain_64.brp` | 25,562 | 59,049,209 |
| `generic/named/managed.brp` | 28,421 | 62,273,135 |
| `option_input/parse_int.brp` | 16,419 | 46,517,780 |
| `file_read/ownership.brp` | 20,923 | 53,387,091 |
| `file_write/ownership.brp` | 26,692 | 62,039,187 |
| `calculator/integer.brp` | 47,872 | 87,791,982 |
| `constant/integer.brp` | 14,604 | 43,654,165 |
| `int/equals.brp` | 24,515 | 56,771,586 |

All nine original +5% review-target misses in both measures remain reported; the eight allocation and six instruction +10% hard failures remain historical FAILs. Approval permits a separate acceptance decision under these explicit amended ceilings; no old receipt becomes green. The HOST construction proxy retains its existing +5% review/+10% hard limits and schema1 allocation definition. SOURCE +3%, all independent feature/source limits, the original corpus and producer/metric roles remain unchanged.

### Exact native cap changes

Only these 45 allocation fields change. Each new value is the frozen maximum over that definition’s affected roots plus 100, rounded up to a multiple of 100, leaving 100–199 allocations above the frozen maximum. Independent definitions stay independent even when their values match.

| Definition | Old allocations | Approved allocations |
| --- | ---: | ---: |
| `test_imports.brp::DIRECT_CHAIN_LIMITS` | 83,000 | 84,600 |
| `test_imports.brp::FLAT_LIMITS` | 31,000 | 34,100 |
| `test_join.brp::limits(...) for bound_int` | 16,677 | 20,000 |
| `test_join.brp::limits(...) for bound_managed` | 15,550 | 19,300 |
| `test_join.brp::limits(...) for deep` | 30,133 | 31,100 |
| `test_join.brp::limits(...) for nested` | 19,876 | 22,600 |
| `test_join.brp::limits(...) for statement` | 15,652 | 19,400 |
| `test_join.brp::limits(...) for tail_arm` | 16,555 | 20,200 |
| `test_join.brp::limits(...) for void_tail` | 15,573 | 19,500 |
| `test_lists.brp::APPEND_ENTRY_LIMITS` | 21,800 | 25,700 |
| `test_lists.brp::APPEND_INT_LIMITS` | 21,300 | 24,000 |
| `test_lists.brp::APPEND_POINT_LIMITS` | 24,400 | 28,000 |
| `test_lists.brp::CHECKED_SET_LIMITS` | 45,000 | 47,000 |
| `test_lists.brp::CONCAT_ENTRY_LIMITS` | 23,700 | 27,200 |
| `test_lists.brp::CONCAT_INT_LIMITS` | 21,600 | 25,600 |
| `test_lists.brp::CONCAT_POINT_LIMITS` | 25,100 | 28,700 |
| `test_lists.brp::ENTRY_LIMITS` | 21,500 | 24,300 |
| `test_lists.brp::LITERAL_CALL_LIMITS` | 19,300 | 22,700 |
| `test_lists.brp::LITERAL_EMPTY_LIMITS` | 17,000 | 20,700 |
| `test_lists.brp::LITERAL_ENTRY_LIMITS` | 20,400 | 23,700 |
| `test_lists.brp::LITERAL_INT_LIMITS` | 16,800 | 20,600 |
| `test_lists.brp::LITERAL_NESTED_LIMITS` | 19,700 | 22,900 |
| `test_lists.brp::LITERAL_POINT_LIMITS` | 17,000 | 20,900 |
| `test_lists.brp::MORTAL_LIMITS` | 19,000 | 22,000 |
| `test_lists.brp::NESTED_LIMITS` | 19,000 | 23,100 |
| `test_lists.brp::PRESENCE_LIMITS` | 15,500 | 18,900 |
| `test_lists.brp::SET_ENTRY_LIMITS` | 23,400 | 27,100 |
| `test_lists.brp::SET_INT_LIMITS` | 23,100 | 26,900 |
| `test_lists.brp::SET_POINT_LIMITS` | 23,800 | 27,600 |
| `test_namespace.brp::LIMITS` | 19,000 | 22,300 |
| `test_record_updates.brp::REORDER_LIMITS` | 24,000 | 25,800 |
| `test_recursive_groups.brp::BRANCHES_LIMITS` | 19,900 | 22,900 |
| `test_recursive_groups.brp::GROUP_LIMITS` | 20,500 | 23,600 |
| `test_recursive_groups.brp::KINDS_LIMITS` | 20,600 | 23,500 |
| `test_recursive_groups.brp::LINKED_LIMITS` | 17,700 | 21,100 |
| `test_recursive_groups.brp::LINKS_LIMITS` | 19,400 | 22,400 |
| `test_recursive_groups.brp::TREE_LIMITS` | 26,600 | 28,700 |
| `test_recursive_unions.brp::DEEP_LIMITS` | 17,500 | 21,300 |
| `test_recursive_unions.brp::DEPTH_LIMITS` | 14,300 | 18,300 |
| `test_recursive_unions.brp::SHARED_LIMITS` | 16,600 | 20,200 |
| `test_recursive_unions.brp::TRAIL_LIMITS` | 16,500 | 20,400 |
| `test_string_literals.brp::UNREACHED_ESCAPES_LIMITS` | 14,700 | 17,600 |
| `test_string_literals.brp::UNREACHED_LONG_LIMITS` | 11,600 | 14,900 |
| `test_syntax.brp::LIMITS` | 13,000 | 16,800 |
| `test_ufcs.brp::test_chain_64_native_and_cost: inline limits` | 24,000 | 25,600 |

The sole instruction-field change is `test/e2e/test_syntax.brp::LIMITS.instructions`: 65,000,000 → 66,500,000. All other instruction fields are unchanged. The same syntax constant covers its five selected roots. The namespace allocation constant also covers three already passing roots; DEPTH_LIMITS covers two roots and PRESENCE_LIMITS three. The retained approval data enumerates every affected and passing root.

The seven join allocation arguments change only at their listed call sites. The shared `limits` factory and its ten passing call sites remain unchanged. The numeric fixture keeps 45,000 allocations and 150,000,000 instructions. New annotation and qualified-pattern fixture limits, HOST/SOURCE limits, and every other native limit remain unchanged.

The reviewed feature LOC ceilings remain 110 gross/+80 net production, 650 gross/+640 net nonfixture tests, one fixture/48 lines and 45 added public-documentation lines excluding this plan and the final evidence report. The feature remains 79 added/23 deleted production lines; the 46 cap-literal replacements add and delete 46 test lines without changing test logic or net LOC. Preserve readable formatting and all assertions.

The compiler’s 41 source files, target library, harness, callbacks and fixture behavior are unchanged by this budget update. Reuse the already generated `9ab6dde0…` C and `02ecee8f…` normal / `ef9365be…` diagnostic binaries with their exact recorded hashes and modes. Preserve the original 1,026-input freeze, commands and first-four receipt; bind the approved test/doc hashes in a new overlay before final native execution. Any actual remaining cap failure stays FAIL and returns to root without an automatic increase or retry.
