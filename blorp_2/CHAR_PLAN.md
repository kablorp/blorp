# M6a: Unicode Char values and their numeric projection

**Bootstrap scope update.** This reviewed primitive-Char design and the held
decoder preparation remain future work. The active [source plan](BOOTSTRAP_SOURCE_PLAN.md)
uses String byte access and checked scalar encoding through Int-facing APIs,
avoiding target Char and Bytes representations while preserving UTF-8. The
budgets below do not transfer to that different implementation route.

Reviewed plan; implementation and acceptance remain pending. Root and an
independent compiler expert approved the design before implementation. No
compiler, test, build, probe or measurement ran while preparing it. Read
parent/pilot AGENTS and HANDOFF_SPEC; this plan needs no ignored preparation files.

## Problem, evidence and bounded order

At accepted keyword commit `854bff86637c6296cc70f59f2a5fc0a572fcf848`, the historical
parser frontier is reported as 34/36: `lex.brp` stops at a Char expression;
`specialize.brp` still needs function types. Those are prior observations, not
rerun results. The 36-source manifest SHA256 is
`60756c64f6a319125f9f11d024ec640028fd91ed5ebef8baadee209a89fd7919`.
Source anchors and the 36-module audit below refer to that commit, not historical
parity-table line numbers. The later reviewed UFCS integration has 37 source
modules, adding `check/receiver_clashes.brp`; no refreshed frontier is claimed.
M5a.1 is separately reviewed but awaits acceptance; implementation
must start from the actual accepted integration base and review any API delta.

A read-only source-form audit of those 36 modules, skipping actual comments,
quoted Strings and pipe/doc bodies, found:

| Actual current use | Count / owner |
| --- | --- |
| Char literal expressions |72, all `lex/lex.brp` |
| Char literal patterns |14, all `lex/lex.brp:610–636` |
| Explicit Char parameter annotations |3, lexer `is_byte`, `byte_is`, `punctuation` |
| Bare `to_int(...)` calls |20, lexer16 / parser2 / emitter1 / names1 |
| `StringOps.get` |13, lexer10 / parser2 / names1 |
| `StringOps.chars` |1, emitter197 |
| `StringOps.from_char(to_char(...))` |1, parser947 |

Zero unknown quoted forms were encountered. This is a bounded audited lexical
census, not a compiler-produced AST inventory or proof that those modules
already typecheck. The old parity counts 51/52 literals and 13 patterns are stale.
M2b still owns Char-pattern matching; M6a must preserve complete parsed scalar
data for it without implementing that decision tree now.

Delivery order:

1. **Preparatory extraction, if required by the concrete patch:** one shared
   scalar/escape owner, preserving every String/UTF-8 outcome and diagnostic.
   Independent review/gates; CharLiteral/PatternChar stay unchanged until step2.
2. **M6a, this complete value path:** Char literals, canonical primitive type,
   `char.to_int`, existing aggregates/generics/List storage and unmanaged values.
   Add Char closed constants on the accepted M5a.1 path, without references,
   records or evaluation machinery. Migrate 20 source conversions to qualified
   `CharOps.to_int` in their four owning modules.
3. **Separate M6b plan:** `int.to_char`, `string.from_char`, byte-indexed
   `string.get -> Option[Char]`, and `chars`/other library bodies. First settle
   invalid Int-to-Char behavior; do not inherit an unchecked cast by accident.
   M2b implements the 14 pattern cases separately. Other M6/M7 rows stay deferred.

## Language contract and first executable example

The names are existing APIs: `standard_library/src/char.brp:20` supplies
`to_int(Char)->Int`; there is no proposed `to_code`. Host trait implementation
syntax is not copied into the target library. The parity table's noteA already
establishes qualified `CharOps.to_int` as host-compatible.

First ordinary fixture, `fixtures/char/scalar.brp`:

```blorp
import:
    char as CharOps
    int as IntOps

func main() -> Int:
    match IntOps.equals(CharOps.to_int('λ'), 955):
        True: 23
        False: 17
```

Require real-main exit 23 and empty streams. Comparing 955, rather than returning
it through an 8-bit process status, catches UTF-8 lead-byte/truncation mistakes.
A second fixture prints exact decimal 955/128512/0/1114111 via existing Int
formatting, testing raw λ/😀, escaped NUL and the maximum scalar. No generated
language-function calls, alternate entrypoints or emitted-C edits.

Char denotes exactly one Unicode scalar: 0..10FFFF excluding D800..DFFF. All
unassigned/noncharacter scalars remain valid; no Unicode character database,
normalization, grapheme segmentation or locale dependency. `'é'` is one value;
`'é'` contains two and rejects. This matches upstream
formal grammar 1.8 (`docs/GRAMMAR.md`),
[Unicode's definition](https://www.unicode.org/glossary/#unicode_scalar_value)
and the scalar model documented by
[Rust](https://doc.rust-lang.org/std/primitive.char.html#validity-and-layout).
Rust's fixed 32-bit scalar representation informs our choice; it does not prove
Blorp's ownership or import rules. We copy neither its traits nor unsafe APIs.

Admit raw valid UTF-8 plus the existing fixed escapes `\n \r \t \0 \\ \" \'
\{ \}` and `\u{H}` with 1–6 hex digits. Source locations stay half-open UTF-8
BYTE spans; String length/indexing stays byte based. The host's String
`get`/`chars` return byte values as Chars (`runtime.c:8846`), not Unicode
iteration. Every byte 0..255 is itself a scalar, so this later API remains
coherent without conflating it with raw literal decoding.

## Smallest shared boundary and literal code changes

Today `lex.brp:415–450` scans one raw scalar or backslash+one byte and publishes
payload-free `CharLiteral`; therefore `\u{...}` currently fails lexical width.
`parse.brp:1246` rejects every Char value, while 2027 publishes only a pattern span.

```blorp
-- Current parse/parse.brp:1246
CharLiteral:
    Err(diagnostic(token.span, "Char literals are not supported yet", ...))

-- Proposed complete products (names are the proposed interface, not existing APIs).
-- utils/unicode.brp, imports only Int operations:
opaque type UnicodeScalar = Int
pure func unicode_scalar(value: Int) -> Option[UnicodeScalar]:
    -- Range/surrogate check; only this function uses into_opaque here.
pure func scalar_number(value: UnicodeScalar) -> Int:
    from_opaque UnicodeScalar(value)

-- utils/syntax.brp
CharLiteral(UnicodeScalar)
CharExpression(UnicodeScalar)
PatternChar(UnicodeScalar, Span)

-- parse.brp
CharLiteral(value):
    Ok({ base = CharExpression(value), span = token.span, next = after })
```

The scalar constructor owns range validity; its representation stays private.
Preparation uses it for existing String escapes/raw UTF-8 validity and moves the
escape switch without adding Char token/AST payloads or an unused Char diagnostic
context. The existing lexer remains the sole encoding/shortest-form validator;
String parsing copies validated raw byte runs without revalidating UTF-8.

Today `utf8_end:343` discards its accumulated scalar and returns only the end.
M6a changes that producer to return `{scalar: UnicodeScalar, next: Int}`; its
String-facing wrapper still projects only `next`, while Char retains both facts.
This is a real carrier/API change, not an existing decoding API. Decode once,
preserve continuation/overlong-error priority, and never rescan to recover a
number. Ordinary consumers retain the scalar without revalidating its spelling.

The genuinely shared escape decoder currently lives at `parse.brp:903–991`.
Move its fixed/hex scanning and escape-result concept to `lex/escapes.brp`,
used by String parsing AND Char lexing, returning `{scalar: UnicodeScalar,
next: Int}`. Callers supply source identity/base offset and a precise String/Char
literal context for teaching diagnostics (Char context added only with M6a).
Preserve exact String errors/spans;
String parsing performs its existing UTF-8 encoding once after decoding.
No second escape switch, validator or String-to-Char roundtrip.

These two small leaves avoid a lexer→parser dependency: `unicode` imports no
syntax; `syntax` imports UnicodeScalar; `escapes` imports syntax/unicode;
lexer/parser both import escapes. A separate error framework, callback engine,
general codec hierarchy or source-slice registry is unnecessary. An Int opaque
wrapper/result record is not assumed physically free: inspect/probe it before
propagating the representation. If this cut exceeds preparation bounds, stop
for review rather than merging lexer/parser or duplicating logic.

Target library:

```blorp
-- _base.brp: sixth required primitive
type Char = builtin
-- prelude.brp: add Char to its existing _base selection only.
-- new char.brp; operation stays explicitly imported, not implicitly loaded.
import:
    _base: Char, Int
pure func to_int(value: Char) -> Int:
    builtin("char.to_int")
```

`CharToIntBuiltin` is assigned once by the parser's builtin-label table;
`RuntimeOperation.CharToInt` has one canonical pure `[Char]->Int` contract.
Char's seeded contextual NameId admits `type Char=builtin`; foundation checks
publish `BuiltinChar`/`PrimitiveHead(BuiltinChar)` once. Keep the existing rule
that all primitives are required; no optional-Char compatibility path.

### Mandatory primitive producers and intentional precedence

Append the required Char lookup after existing Int→String→Void→Float→List,
before designated unions (`namespace/builtins.brp:424–451`). Missing Char yields
`MissingBuiltinType(CharType)`, `missing Char builtin declaration`, help
`add type Char = builtin to _base.brp`, foundation EOF SourceId/span, no note.
Earlier missing roles, duplicate declarations, foundation-shape and outside-base
errors retain their priority. A five-primitive foundation formerly reaching
Bool/Option/Result validation now fails MissingChar; complete producers must add
Char rather than weakening those later oracles.

| Existing producer / oracle | Required migration |
| --- | --- |
| `standard_library/{_base,prelude}.brp` | Add declaration and prelude selection. Explicit char module adds no implicit import. |
| `test/unit/module_input.brp:26–53` | FOUNDATION_TYPES plus PRIMITIVE_BASE/TEST_BASE selections; all helper consumers inherit it. |
| `unit/test_namespace/test_builtins.brp:30,155` | TYPES/reversed complete bases, distinct-name assertions, Char role comparator; keep old missing-role/shape/duplicate precedence and add Char-only omission/duplicate/foreign/private cases. Missing designated-union tests keep their original error after complete-base update. |
| `unit/test_main/test_option_input_phases.brp:19` | Add Char to complete REVERSED_OPTION_TYPES; reversed Option identity/layout oracle unchanged. |
| `unit/test_lower/test_float_phases.brp:460`; `unit/test_emit/test_list_phases.brp:53`; `e2e/test_strings.brp:16` | Intentionally incomplete bases retain Float/List/String-first errors because Char is last. Preserve old bytes; add competing MissingChar controls separately. |
| `unit/test_load/test_load`, `unit/test_parse/{test_assemble,test_visibility}`, `test_grammar/{test_trivia,test_conformance}`, `unit/test_main/test_main` | Load/parse/seal-only incomplete bases and fabricated rendering diagnostics are not complete foundations: preserve their old partial-source oracles. Extend parser alternatives with Char; unknown-Bool builtin remains rejected, but its exhaustive teaching help gains Char. |

This source search found these 12 test files with primitive declarations; no
ordinary e2e fixture declares its own base. Refresh against the accepted feature
base before editing; accepted M5 may add consumers. Keep missing-role tests
explicitly incomplete; never blanket-add Char to every inline `_base` String.

## Immutable owner/lifetime and exhaustive consumers

| Product / owner | Published fact and consumers |
| --- | --- |
| Unicode leaf | Valid scalar value; token/AST/checked/concrete/lower/owned literals share it for their normal product lifetime. No source String retained by the scalar. |
| Lexer→syntax | `CharLiteral(scalar)` plus complete quote span; parser reads payload, including parsed-but-rejected Char patterns. KeywordToken/SymbolToken separation remains unchanged. |
| Names/parser/foundation | Seeded Char NameId, ParsedBuiltinType.CharBuiltin, accepted BuiltinChar identity and runtime contract. Namespace/head selection uses identities; strings only at parse/diagnostic/emission projection. |
| Checker | CharType and LiteralChar(scalar), complete TypeUse/use span; model equality/head, inference publication/substitution, declaration/recursion leaf walks, signature/runtime acceptance and renderer cover Char. Char≠Int in every direction. |
| M5 accepted scalar path | CharConstant(scalar), annotation checked before initializer as today; ReadConstant projects an ordinary Char literal at each use span. No new evaluation stage. |
| Specializer | Concrete CharType, complete aggregate/layout keys; Char fields are unmanaged and eligible for existing numeric/Char inline-record rules. Char/Int instantiations remain distinct. |
| Lower/uses/own | Fresh ValueId, CharValue→CharDefinition, no operands and NoOwnership; a List root still owns its allocation, with no Char element obligations. No managed Char box. |
| Independent verify | Derive CharType from the actual definition, reject wrong declared type/acquire/drop/store/call contracts. Invalid scalar literals are prevented by the opaque constructor, not a second normal-path checker. |
| Emission/list key | Explicit `uint32_t` and `UINT32_C(code)`; CharToInt emits safe int64 widening. List Char gets a distinct disposable key/rank appended after existing ranks, preserving old suffixes/C. No target allocation/runtime destructor for a Char. |

Actual observer files: utils/{names,syntax}, lex/lex, parse/parse,
namespace/{namespace,builtins}, check/{model,declarations,expressions,inference,
signatures,recursion,render}, specialize/specialize, lower/lower, own/own,
verify/verify, runtime/list, emit/emit; plus M5 check/constants when accepted.
Update their exhaustive matches and unit owners; no wildcard fallback to Int.
Old compiler precedent is lexical codepoint payload (`lexer.brp:1156–1253`),
dedicated Char typing (`infer.brp:24350`) and literal emission
(`emit_literal.brp:295`); runtime uses int32_t. uint32_t is this pilot's explicit
nonnegative 32-bit representation choice, not a new public numeric-width feature
or FFI ABI promise. No Int↔Char implicit coercion.

## Diagnostics, tests and deliberate mutations

TDD first: literal parser acceptance and the real fixture above must fail on
the frozen baseline for the known Char rejection, not merely a missing module
or new enum import. Retain actual semantic red, then implement. Preparatory
refactor controls stay green/C-identical; compile/setup failures are not reds.

Preserve existing empty/multiple/unterminated/control-byte Char diagnostics
(`test_lex/test_char_literals.brp`) and first-error order. New exact errors:

| Input | Owner / exact message / help and span |
| --- | --- |
| malformed raw UTF-8 | lexer: `invalid UTF-8 in Char literal`; existing UTF-8 teaching help; offending encoded-byte range |
| `\q` | shared decoder: `unknown Char escape`; `use \n, \r, \t, \0, \\, \", \', \{, \}, or a Unicode scalar escape such as \u{E9}`; full escape |
| `\u{D800}`, `\u{110000}`, bad/empty/7-hex-digit escape | shared decoder: `invalid Unicode escape`; existing UNICODE_ESCAPE_HELP unchanged; full offending escape/first invalid unit as the String precedent |
| `CharOps.to_int(1)` | existing typed ArgumentTypeMismatch(expected Char, actual Int); `argument type does not match the parameter type`, `use an expression of type Char here`; actual argument span |
| `main()->Int: 'a'` | existing typed ExpressionTypeMismatch(expected Int, actual Char); `expression does not match the expected type`, `use an expression of type Int here`; full literal span |

All pin SourceId/full endpoints/message/help/None-note. Retain Char-pattern
UnsupportedSyntax until M2b. Migrate only the existing parser/e2e/grammar
Char-value rejection oracles to acceptance or the correct typed mismatch;
enumerate every actual changed diagnostic before editing it. Preserve old inputs.

Granular named suites: scalar boundaries 0/D7FF/E000/10FFFF and invalid adjacent
values; token payload+1/2/3/4-byte spans/all fixed escapes; shared String/Char
escape values and exact priority; parser expressions/pattern payload; foundation
missing/duplicate/private/foreign Char and malformed builtin signatures;
Int≠Char and same-spelling nominal counterexample; bidirectional generic calls;
Char constants/privacy/use spans; generic record/union/List specialization
identity, inline eligibility and distinct key; lower fresh literals/operands;
uses leaf and ownership NoOwnership independently; forged raw definition type,
unmanaged acquire and managed-container cleanup; exact uint32 emission.

Ordinary e2e includes maximum scalar through functions/generics, Char+String
record/union fields, List[Char] repeat/get/set/concat and exact scalar output.
Runtime-helper TestSuites use the existing approved C exception only: Char
element has zero dup/drop effects, container/String children free exactly once.
Default Clang O0 and ASan/UBSan compile UNMODIFIED C, real main exact outcomes.

Kill range/surrogate acceptance, UTF-8 lead-byte substitution, escape offset,
Char-as-Int equality, wrong runtime contract, Char-as-managed ownership,
reused List[Int] emission key and lost constant-use-span mutants. Restore exact
bytes and rerun owning suites. No new tracing or alternate assertion main.

## Dependencies and overlap

Keyword 854 is accepted. M6a's constant bridge depends on accepted M5a.1; do not
copy its unaccepted WIP or add a parallel constant path. M4's recursive storage
changes and M2's control work may touch type visitors, ownership and emission:
root integrates those accepted APIs and re-reviews conflict decisions. Ordinary
Char needs no new opaque-language feature, recursive-layout mechanism or control
form. M2b and the invalid-input policy for M6b remain separate work.

## Pre-set physical/cost bounds and acceptance

Combined preparation+M6a estimate: 180–220 net / 300–370 added production;
goal 180 net, hard 250 net / 400 added physical lines, imports/comments included.
Preparation independently ≤+50 net / 200 added and ROADMAP's +3% per-input limits.
Tests excluding fixtures estimate +650–850; fixtures +120–180; report separately.
These are proposals before code, not permission to compress formatting or
remove coverage. Stop before exceeding a hard bound or widening the design.

Feature shared-input allocation/instruction target +5%, hard +10% PER input;
proposed canonical host proxy hard +8% normal instructions / +10% checkpoint
allocations, explicitly a source-to-C proxy until M8. New fixtures start at
35,000 allocations / 140M strict instructions each; existing budgets remain unchanged.
Freeze accepted base/candidate source, binaries, libraries, toolchain and inputs
first; normal serial alternating min3 has both memory variables unset OUTSIDE
time, strict allocations separate/positive/balanced/zero leaks.

Adding required Char necessarily changes library versions: B cannot parse the
new builtin declaration. Root has approved this measurement design in principle:
freeze explicit B/C libraries, copy each to the SAME canonical library root
OUTSIDE timing, keep every ordinary old fixture byte/path unchanged and record
the exact library delta. Never claim identical library bytes or compare a new
success against an old rejection cost. Existing shared target C stays identical;
all changed rejection outcomes/diagnostics are explicit exceptions.

Scale 16/32/64/128 raw scalars, escaped scalars, independent reads, and Char fields/
List elements. Record input bytes, scalar/read/definition counts, allocations,
normal instructions and C bytes/depth; expected decoding work is linear in
bytes, aggregate work in fields/elements. Contrast unchanged String controls
to locate decoder/carrier regressions; measure actual host C layouts before
claiming opaque/Option carriers allocation-free. Investigate near 4x doubling;
no cache/optimizer/backend-depth waiver is authorized.

Run focused scalar/lex/parse/check/spec/lower/uses/own/raw-verify/emit/runtime
suites, full grammar/unit/e2e, strict+C/diagnostic identity and matched costs,
then actual-main Make and dynamic frontier with measured numerator/denominator.
Do not predict a fixed frontier count after new modules/M5. Update README,
grammar.ebnf, library parity and roadmap with actual scope; main GUIDE/GRAMMAR
already specify scalar syntax, so alter them only for an actual contract change.

Narrow commands after root grants the serialized lane, then final owning gate:
`bin/blorp test --suite --timeout 180 blorp_2/test/unit/test_lex/test_char_literals.brp`;
`bin/blorp test --suite --timeout 180 blorp_2/test/test_grammar/test_strings.brp`;
`make -C blorp_2 test`. Freeze/check the approved host first; no host rebuild here.

Stop on ambiguity about invalid runtime Int→Char policy, ownership/layout,
decoder diagnostic parity, host faults, cost/source caps or accepted-base
dependencies. Do not implement M6b/M2b/traits/loops/opaque types as a workaround.
Hand back bounded patch/provenance/counts, exact red→green/mutants/native/phase
facts, full costs and remaining limits. Root and an independent compiler expert
review each slice; independent runner owns execution. No implementation or
publication acceptance follows from approving this proposal.
