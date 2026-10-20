# Ordinary Boolean functions

Implement the user's six call forms in both compilers: `True.not()` / `not(True)`,
`flag.and(other)` / `and(flag, other)`, and `flag.or(other)` / `or(flag, other)`.
The separate Boolean operator implementation is paused. These are ordinary,
eager function calls; use explicit `match` when the right side must be skipped.

## Bootstrap order

The legacy host must build source migrated to these calls too. Its active
discovery builder, maintained tree parser and stage03 parser need scoped callable
names. Stage03 also serves formatting, AST output and test discovery. Existing
legacy name tables already issue keyword IDs; use those authorities, without
new token kinds or broad keyword unreservation.

Default `make` uses the immutable bootstrap with the checkout's host library.
That bootstrap rejects keyword function declarations. Land three green slices:

1. A: legacy parser capability with the unchanged host library. Accept the three
   callable names in declarations/imports/UFCS/qualified calls, plus direct
   `and(...)`/`or(...)`. Keep unqualified `not(...)` as unary syntax for this
   preparatory slice, so current sources still work without a prelude function.
   Test ordinary `not` calls through UFCS/qualification and actual callee identity;
   do not claim the final six forms are complete yet.
2. B: successful main CI automatically publishes immutable dev snapshots. Verify
   the actual released source/capability and all three platform asset digests,
   then rotate the bootstrap pin. Run default make and the maintained bootstrap,
   release-toolchain and package gates; no local override or old-library fallback.
3. C: add ordinary host `bool.brp` functions/prelude selections and switch legacy
   `not` followed by `(` to a function call together. The verified A bootstrap can
   parse those headers. Existing legacy unparenthesized operators remain available
   to host current compiler sources; Blorp 2 rejects those operator forms.

Blorp 2's parser/helpers may land independently: its target library is not the
host library read by `make`. Each slice still needs two reviews and its own green
gates. Do not migrate compiler source operators wholesale in these slices.

## Smallest complete path

Add three ordinary pure functions in `blorp_2/standard_library/bool.brp`, importing
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
Add the same match bodies to the host's existing `standard_library/src/bool.brp`
in C and expose the names through its prelude; keep existing trait methods intact.

In Blorp 2 the lexer keeps `AndKeyword`, `OrKeyword`, and `NotKeyword`. Append their
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
In Blorp 2, prefix `not value` and infix `left and right` / `left or right` are invalid.
Use the existing rejection path, with diagnostics teaching ordinary calls;
remove promises that these operators will arrive at a later milestone.
Keep the negative cases and update their exact expected message/help.
No Boolean IR, join construction, traits,
backend/runtime mechanism, namespace exception, `if`, `while`, or wholesale
compiler-source migration belongs in this change.

## Evidence and bounds before implementation

Combined production forecast: 238–363 added lines, with no new IR or runtime.
Blorp 2 retains 200 added /175 net; reassess at 170 added or 149 net.
Legacy A allows 180 added /150 net, C allows 50 added /40 net; final combined
production stays within 430 added /365 net. B is the verified manifest change.
Allow 550 added Blorp 2 test lines plus a 45-line fixture; legacy A allows 600
test/80 fixture lines and C allows 250 test/50 fixture lines. API docs stay within
50 added lines and this expanded plan within 150. These are ceilings, not goals;
reuse ordinary-call tests. Stop to reforecast rather than compress or drop coverage.

Before code, freeze the exact accepted main containing the pending Contains
addition as B, with its complete compiler source, target library, functional
host/STD and cost producer provenance for each slice. Name commits and paths in
the evidence before any measurements. This is a new ordinary-call feature;
do not replace or reinterpret the paused operator feature's original receipts.
Preserve all existing absolute fixture limits. For shared target controls,
retain a 5% allocation/instruction target and 10% hard ceiling per metric.
For construction proxies and legacy self-compilation require allocations and
normal retired instructions each at most B+3%; label only construction as a proxy.
Measure serially, same physical inputs and toolchain, positive min-of-three
normal instructions and the unique schema1 construction allocation checkpoint
for a construction proxy. Measure legacy self-compilation at its actual boundary
with its retained measurement tool. Keep failures, raw samples and output identity
evidence; do not mix host or library roles between phases.
Keep the original accepted B source and ceilings through the pin transition.
The final legacy comparison must use one verified A-capable producer for both
B and C, pinned before sampling; never compare pre-pin and post-pin timings.

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
Legacy fixtures belong to their legacy owners; never run Blorp 2's e2e suite
through the legacy compiler. Use discovery fixtures, `scripts/test compiler-new`,
`scripts/test compiler-blorp compiler-new-parity`, and the changed
compiler checks selected by `scripts/compiler-check --changed --plan`.
For C, test formatting twice: old `not (a and b)` intentionally becomes an
ordinary call and should print as `not(a and b)` consistently. Preserve plain
`not foo()` as legacy unary syntax; test AST/callee identity, not truth output
alone. Add a formatter code change only if a real roundtrip failure requires it.

Parser/ergonomics/data-authority input approved this design before code.
Publish this plan first; implementation needs independent code-reviewer and
test-runner approval before commit. Update the owning Blorp 2 grammar/README,
library READMEs and GUIDE/GRAMMAR notes with each supported stage. Root integrates the
bounded feature, verifies destination gates, then pushes main to origin.
