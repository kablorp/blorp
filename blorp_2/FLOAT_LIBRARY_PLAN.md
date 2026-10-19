# Required Float library APIs

Status: proposed implementation contract, before production changes or compiled
calls. Publish this plan after two independent reviews, then authorize test-first
implementation separately. Earlier drafts remain evidence, not accepted code.

## Scope and current authority

Add exactly seven pure concrete APIs to `standard_library/float.brp` in Blorp 2:

| Function | Parameters | Return |
| --- | --- | --- |
| abs | value: Float | Float |
| copysign | value: Float, sign: Float | Float |
| equals | first: Float, second: Float | Bool |
| less_than | first: Float, second: Float | Bool |
| greater_than_or_equal | first: Float, second: Float | Bool |
| is_nan | value: Float | Bool |
| is_finite | value: Float | Bool |

Accepted source reference is `1d02a670027ee05c2e18e0d19cbd22ac64ad23e4`.
Fresh resolved compiler demand is respectively 1/1/1/2/2/1/3 calls, eleven total.
Consumers: `src/emit/float_literal.brp:16–62`, `src/parse/parse.brp:905`,
`src/verify/verify.brp:1187`. Host contracts are `standard_library/src/float.brp`
lines 444/475/503/593/651/659/668. Do not migrate compiler calls or change the
host library, primitive Float identity, zero-divisor policy, traits, FFI or M7.

The two ordinary wrappers below require only accepted match/call syntax and the
new Float primitives. No held Int API or M3 normalization is a dependency.
Concurrent Int/M3 changes overlap parser, builtin contracts, specialization and
Emit; port narrowly onto then-accepted main and review those seams separately.
No historical branch or draft counts as an accepted prerequisite or baseline.

## One producer-to-consumer path

Five labels: `float.copysign`, `float.equals`, `float.less_than`, `float.is_nan`,
`float.is_finite`. `utils/syntax.brp:365` owns their parsed operation variants;
`parse/parse.brp:2630–2724` recognizes labels and owns quoted-label diagnostics.
`namespace/builtins.brp:73–212` owns closed RuntimeOperation variants and the sole
runtime_contract: binary Float-to-Float copysign, binary Float-to-Bool comparisons,
and unary Float-to-Bool classifications, all pure and nongeneric.

`check/signatures.brp:345–386` attaches actual designated Bool constructors once.
`specialize/specialize.brp:2184–2200,2315–2322` translates those published IDs via
translate_boolean. No name lookup, assumed ordinal, phantom element or hidden
metadata. Lower/Own/Verify production and their existing generic contracts stay
unchanged; their focused tests observe real operations and independent faults.

`emit/emit.brp:1290–1389` currently has only String/Int EqualityComparison cases;
held numeric Comparison code is not available. Extend the current closed binary
comparison cases for Float == and <. Unary isnan/isfinite must extract exactly
one operand, not fabricate a second or reuse a binary-only helper unchecked.
Keep one designated-Bool declaration/constructor publication authority. A narrow
extraction of that existing publication code is allowed if needed by both arities;
an emitted condition String is ordinary backend text, never a semantic protocol.
No condition registry, operator-string parameter or broad emitter refactor.
Copysign emits an ordinary direct `copysign` call through the existing scalar call
path. Float operand types already select `runtime/float.brp` and its <math.h>;
add no runtime wrapper, requirement flag, new ABI or always-emitted fragment.

## Ordinary helpers and binary64 semantics

```blorp
pure func abs(value: Float) -> Float:
    match less_than(value, 0.0):
        True: copysign(value, 1.0)
        False: value

pure func greater_than_or_equal(first: Float, second: Float) -> Bool:
    match less_than(second, first):
        True: True
        False: equals(first, second)
```

Abs preserves host behavior: negative finite/subnormal values and -inf become
positive, while -0 and NaN return unchanged. Equality equates both zeros and
rejects NaN; ordering rejects unordered pairs, and >= is false for either NaN.
Zeros/subnormals are finite; infinities/NaNs are not. Copysign transfers even a
zero/NaN sign while preserving magnitude; no NaN payload or FP-exception promise.
Keep existing binary64/subnormal/no-fast-math/separate-rounding requirements.

## Tests first, meaningful faults and acceptance

First prepare baseline-compatible parser label tests and a normal-main fixture;
observe exact unknown-operation RED before adding parsed variants or primitives.
Then cover builtin-header purity/arity/input/result/generic errors with exact
message/help/span/note. A distinct local Bool must not impersonate the foundation.
Check real designated IDs; Specialize real concrete constructors (including swapped
Bool declaration order); Lower/Own unmanaged operand order; Verify malformed public
runtime calls independently. Preserve all old negatives and existing fixture mains.
Use existing parser/builtin, Float phase/runtime and e2e owners; no new runner,
production observer, alternate main, C rewrite or duplicate compiler test pipeline.

One ordinary-main fixture, <=80 lines, observes +/-0, +/-minimum subnormal, finite
values, infinities and signed NaNs. Make infinity by overflowing multiplication,
not zero division. Set NaN signs via copysign(infinity-infinity, sign); do not
assume subtraction's NaN sign/payload. Observe signs via copysign(1.0, result),
not equality or formatted NaN/zero text alone. Test both NaN positions for >=.
Prospective new-only caps: 60,000 allocations/200M diagnostic instructions and
200M normal min3; these are unmeasured, not a fabricated baseline success.
Prove named semantic kills/restorations for sign copying, equality, strict order,
NaN/infinity classification and unguarded not-less >=. Freeze each fault before
execution; setup/resource failure is not a kill. Restore bytes/modes and semantic
index before classification, then require the same owner GREEN.

Run focused suites, full components/runtime/grammar, generated-C review and full
native using real main, strict zero leaks, C11/O0 ASan/UBSan, required counters and
all unchanged absolute caps. Run an actual source frontier without fixpoint claims.
All unchanged CLI states retain status/stdout/ordinary stderr/fresh-C-or-no-C and
exact C. The five added builtin labels may change only their insertions in help
for unknown-operation/expected-quoted-label errors; bind exact old/new strings
before calls. Preserve message/span/note/other streams. Existing goldens include
parse/test_string_literals_syntax:421, emit/test_builtin_functions:193 and grammar/
test_conformance:210,221,2583. Audit the complete current corpus at freeze; no
blanket exclusion, successful-root assumption or other diagnostic normalization.

## Size, fixed costs and stops

| Category | Forecast ADD/DEL/net | Hard stop |
| --- | --- | --- |
| All compiler + target-library production | 205/45/+160 | 250 gross ADD / +200 net |
| Nonfixture tests | 650/20/+630 | 800 gross ADD / +780 net |
| One fixture | <=80/0 | 80 physical lines |
| API docs | 45/12/+33 | 60 gross ADD / +50 net |
| This canonical plan | <=160 lines | 160 physical lines |
| Final measurement report | <=100 lines | 100 physical lines |

Fixed accepted B is `1d02a670027ee05c2e18e0d19cbd22ac64ad23e4`; keep it
unchanged through later current-main composition. No earlier Float cost epoch was
measured or replaced. Freeze exact C and full libraries, 41 compiler sources,
STD/tool producer roles and physical input/library/output paths/CWD. No baseline
roll, borrowed numeric allowance, compressed formatting or deleted coverage.
Four unchanged controls: return/zero, calculator/float, conversion/float and
calculator/float_literals under `test/e2e/fixtures` (all `.brp`). Each independently
retains +5% targets/+10% hard ceilings for allocations and normal min3, plus all
tighter absolutes. Balanced strict diagnostic B/C calls are separate from normal
B1,C1,C2,B2,B3,C3; preserve positive counters, exact within-role/B-C C and all raw
failures. No cross-input/metric averaging or fixed floor. New fixture is C-only.
Independent HOST source-to-C proxy retains +3% allocations AND normal min3 using
the original paired producer/STD roles and unique schema1
artifact_construction_complete checkpoint, never FULL EXIT TOTAL. Reuse verified
original provenance; do not rebuild/replace producers or copy another full bundle.
Historical numeric regressions are risk evidence only, not Float headroom.
Stop before LOC excess, provenance/schema/semantic/identity failure or a hard
resource breach; retain it and seek bounded review, not retries or silent waiver.
Exact B/artifact pins, test postimages, current controls/corpus and actual physical
counts require review before any setup/sampling lease. No compiled calls follow
plan publication automatically; final code-reviewer/test-runner reviews precede
root-only current-main integration, full destination gates and publication.

Cost-stop exception: after review, root may grant remaining planned finite correctness/cost calls once.
Keep B, semantics, thresholds/caps and original samples/FAILs; no retries, resampling or merge.
Relative/absolute budget misses stay FAIL; the unchanged native umbrella may finish/report all fixed fields.
All non-budget failures still stop immediately; data serves only a bounded proposal, never budget acceptance.
