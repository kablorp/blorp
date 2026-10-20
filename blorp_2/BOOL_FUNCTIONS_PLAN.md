# Ordinary Boolean functions

Implement the user's six call forms in Blorp 2: `True.not()` / `not(True)`,
`flag.and(other)` / `and(flag, other)`, and `flag.or(other)` / `or(flag, other)`.
The separate Boolean operator implementation is paused. These are ordinary,
eager function calls; use explicit `match` when the right side must be skipped.

## Smallest complete path

Add three ordinary pure functions in `standard_library/bool.brp`, importing
`_base: Bool(True, False)`. Implement their truth tables entirely with `match`:

```blorp
pure func not(value: Bool) -> Bool:
    match value:
        True: False
        False: True
```

`and(left, right)` returns `right` for True and False otherwise; `or(left,
right)` returns True for True and `right` otherwise. Both arguments have
already been evaluated by the caller. Select `bool: not, and, or` in the
prelude: existing named function imports provide direct calls and UFCS. Its
own declarations deliberately are not exported; preserve that namespace rule.
Document the temporary bootstrap convenience of implicit availability; moving
these selections later does not require another compiler representation.

The lexer keeps `AndKeyword`, `OrKeyword`, and `NotKeyword`. Append their
spellings after existing seeded names, retaining issued IDs in the existing
`ContextualWords`. A narrow parser helper maps those three token variants to
their canonical IDs. Do not recover names from source spelling or numeric IDs.
Use the helper for function headers, selected imports, direct calls, qualified
members and receiver calls. Keep ordinary `consume_name` unchanged for bindings,
types, fields and module aliases. No other keyword becomes a callable name.

`not` followed by the `(` token parses as an ordinary call, with the same
spacing rule as other calls: both `not(True)` and `not (True)` work. Use that
same prefix-not distinction in range operand parsing. Postfix keyword selectors
require call parentheses; qualified function references may follow the existing
qualified-name path. Bare unqualified keyword references remain out of scope.
Prefix `not value` and infix `left and right` / `left or right` retain their
existing unsupported-operator path. No Boolean IR, join construction, traits,
backend/runtime mechanism, namespace exception, `if`, `while`, or wholesale
compiler-source migration belongs in this change.

## Evidence and bounds before implementation

Compiler/library forecast: 123–168 added and about 103–148 net lines. Hard
bounds are 200 added /175 net production; reassess at 170 added or 149 net.
Allow 550 added test lines, a 45-line fixture, 35 API documentation lines and
100 plan lines. Keep readable, granular coverage; stop to reforecast rather
than compressing tests or removing assertions to fit.

Before code, freeze the exact accepted main containing the pending Contains
addition as B, with its complete compiler source, target library, functional
host/STD and cost producer provenance. Name the commit and physical paths in
the evidence before any measurements. This is a new ordinary-call feature;
do not replace or reinterpret the paused operator feature's original receipts.
Preserve all existing absolute fixture limits. For shared target controls,
retain a 5% allocation/instruction target and 10% hard ceiling per metric.
For the matched compiler-construction proxy require allocations and normal
retired instructions each at most B+3%; label it a proxy, not self-compilation.
Measure serially, same physical inputs and toolchain, positive min-of-three
normal instructions and the unique schema1 construction allocation checkpoint
for that proxy. Keep failures, raw samples and output identity evidence.

## Validation and landing

Start with a failing parser TestSuite and real-main fixture using the six
requested forms. Check canonical name identity, declaration/import/qualified
calls, chaining, spaced `not (True)` and unchanged reserved-name diagnostics.
Check all ten truth-table outcomes, nested calls, eager left-to-right argument
effects, and an explicit match that skips the same RHS. Verify exact ordinary
unknown-name, arity, operand-type and purity diagnostics. Existing operator
rejections and all unrelated grammar/type/ownership assertions stay in place.
Prove the new oracles with a small deliberate fault and exact restoration.

Use the FRESH repository host only for TestSuites and building Blorp 2. Build
the candidate once, then compile fixture programs with that explicit candidate
through the normal e2e harness. Run their real main with unmodified C at O0,
ASan/UBSan, strict balanced accounting and exact streams/status; inspect C.
Run relevant parser/name/namespace/check suites, current component/native gates,
shared accepted/rejected output comparisons, matched costs and a frontier probe.
Record actual commands, inputs and totals rather than old suite counts.

Parser/ergonomics/data-authority input approved this design before code.
Publish this plan first; implementation needs independent code-reviewer and
test-runner approval before commit. Update the owning Blorp 2 grammar/README,
library README and scoped GUIDE/GRAMMAR notes with the feature; do not promise
this new callable-keyword syntax in the legacy compiler. Root integrates the
bounded feature, verifies destination gates, then pushes main to origin.
