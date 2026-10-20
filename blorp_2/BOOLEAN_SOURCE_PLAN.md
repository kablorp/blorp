# Boolean calls in compiler source

Migrate `blorp_2/src` to ordinary Boolean functions. The user explicitly chose
`.not()` for negation now and wants no further legacy compiler work. Host
standard library, legacy parser, bootstrap pin and namespace rules stay fixed.
This is a source migration, separate from the ordinary-call parser feature.

## Baseline and scope

Freeze main `07bc7629a132bb0cd45fe401e539d19e99c73fbb` as SOURCE B.
The canonical legacy parsed-AST projection inventories all 41 source modules:
373 operators in 29 modules (134 `not`, 183 `and`, 56 `or`). Comments,
documentation and literal string contents are not executable operators.
Legacy `compile --ast` prints only a declaration summary; the ignored audit
uses the existing parser and canonical JSON projection for full expression
identity. SourceSpan columns use the source authority's four-column tab stops.
Keep original files, AST products and the audit under ignored `build/`.

Add `src/utils/boolean.brp` with three ordinary pure functions using the existing
prelude's Bool and constructors. Their complete bodies are matches:

```blorp
pure func not(value: Bool) -> Bool:
    match value:
        True: False
        False: True
```

`and(left, right)` returns right for True and False otherwise. `or(left, right)`
returns True for True and right otherwise. These are eager calls. Select only
needed helper names explicitly in each source module. This local module is a
temporary bootstrap bridge until the host library offers the ordinary APIs;
remove it and change imports when that later work is authorized and ready.
Do not add a host-library compatibility shim or duplicate Bool type.

The target Boolean feature keeps its public `bool.brp` functions but removes
three implicit function selections from its prelude. Its fixture imports them
explicitly. Otherwise a user helper's own declarations collide with different
FunctionIds already received from the prelude. Keep namespace admission intact.
The original fixed af7 FEATURE baseline, all its ceilings and prior FAILs remain
binding. Preserve the earlier 44 GREEN as historical evidence for its original
configuration; the successor names this API change and validates a real user helper.

## Rewrite rules

Use `.not()` on exactly the original AST operand, preserving its grouping.
For example, in `check/receiver_clashes.brp`, `not inherited.is_empty()` becomes
`inherited.is_empty().not()`. With bounded independent operands,
`not x and y` becomes `and(x.not(), y)`.
Use direct `and(left, right)` and `or(left, right)` for independent, bounded
pure predicates. Do not change left-to-right, once-only argument evaluation.

Preserve short-circuit work guards with direct or bound matches. For example,
`found = found or recurs(arm.body)` in `check/recursion.brp` becomes:

```blorp
found = match found:
    True: True
    False: recurs(arm.body)
```

Keep such work at its original evaluation point, inside the same loop or arm.
Do not hoist a guarded RHS before an `else if`, or freeze a loop condition.
Nested match expressions are outside the target subset: bind a match result
before a condition/call when needed, rather than nesting a match in its argument.
Preserve recursive structural comparisons, list scans and alias lookups;
confirm their bodies rather than guessing from function names. Lexer/parser
byte and token lookups are total and cheap, so they need no blanket matches.
Retain the guarded scans identified at baseline lexer 594/897/1002/1156/1275
and parser1248, plus the recursive/scan families in checking and specialization.
Do not add lazy callbacks, a new parser/IR form or a generic rewrite framework.
Mechanical editing may use the existing AST spans in an ignored one-off script;
review its actual diff and retain comments, strings and unrelated syntax.

## Bounds set before implementation

Production ceiling: 750 added lines and +300 net, including the helper/imports
and explicit work guards; forecast 450–650 added/+120–240. Reassess if a sound
complete migration will exceed either ceiling; do not compress formatting.
New/changed unit and harness tests allow 250 added/+225 net lines, with one
source-helper native fixture of at most 80 lines. API docs allow 15 added lines.
Do not borrow unused allowance from the parser feature or other roadmap tasks.

Complete SOURCE C contains fixed07bc plus the reviewed ordinary-call feature
with explicit imports and this source migration. Freeze both reviewed patches
before sampling: include the dependency's cost against07bc, without rolling B.
Use one preserved A-capable O2 normal/diagnostic producer pair and fixed host
STD before measuring source construction. Compare B/C source at the same
physical input path; preserve/restore complete source trees and outputs.
Label this compiler-construction measurement as a proxy for self-compilation.
It does not replace the parser feature's original fixed-baseline contract.

For this SOURCE epoch, construction allocations and normal min-of-three retired
instructions each stay within B+3%. Also measure unchanged accepted/rejected
input controls through matched O2 B/C Blorp2 pairs, independently within B+3%
for allocations and normal min3 instructions. Preserve all existing absolute
limits. Freeze exact controls, binaries, modes, toolchain, inputs and private
environment before sampling; keep failures and every raw sample. A new helper
fixture initially allows 150,000 allocations and 500M instructions. It must
also pass its value/stream oracle and strict balanced ownership checks.
No source tree swap, role or budget change may be hidden in a receipt.

## Acceptance and landing

Write helper truth-table TestSuite tests first, prove a semantic RED with
incorrect helper bodies, then implement all ten truth cases. Use canonical
callee identity and actual native calls, not only AST shape. Existing parser
feature tests cover eager order and explicit-match skipped arguments; the new
fixture selects the real source helper under the real target prelude.

After migration the AST census of all 42 source modules has zero executable
`not`/`and`/`or` operators. Reconcile every original site with a call or explicit
match; preserve mixed precedence, comments, string bytes and diagnostics.
Run all component/runtime/grammar suites, build once with the FRESH legacy
host, and run native e2e with the actual candidate through the normal harness.
Compare unchanged-input generated C and exact error streams on frozen controls;
run lexer/parser goldens for EOF, truncation, fractions, comments and indentation.
Use the maintained commands from the repository root:

```sh
make
bin/blorp test --suite --timeout 180 blorp_2/test/unit blorp_2/test/runtime blorp_2/test/test_grammar
make -C blorp_2 test-compiler test-e2e
```

Never run Blorp2 fixture programs through the legacy compiler.

The source migration may be prepared independently, but its actual Blorp2
parse/native validation requires the separately reviewed ordinary-call feature.
Keep that dependency explicit; host compilation alone does not prove target
readiness. Probe self-compilation after the reviewed composition and report its
actual next error without bundling missing-library or language work.
Publish this plan first. Every implementation change needs code-reviewer and
test-runner approval before commit; Root integrates, validates and pushes main.
