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
subtraction-mutant clarification. Its fresh ceilings and all SOURCE/cost-policy
limits remain unchanged. [Blorp 2 rules](AGENTS.md), the
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
rg -n 'pure func (equals|less_than|greater_than)' blorp_2/standard_library_temp/int.brp
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
| `standard_library_temp/int.brp` | Add the two ordinary declarations shown above; retain the original upstream provenance and note the target's ordinary greater-than implementation |

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
| Nonfixture tests across phase owners and e2e registration | 300–440 added | 500 / +500 |
| One ordinary language fixture | 30–42 lines | 1 file / 48 lines |
| Public documentation, excluding this plan and final evidence report | 20–35 added | 45 / +45 |

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
