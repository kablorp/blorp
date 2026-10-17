# Compiler source byte classification migration

## Status, problem and dependencies

Plan only; no implementation or compiled work is authorized by this document.
Planning base: `545a6a07d32fb4c713442e441ddc8d93cd544756`. Root and independent
compiler/HOF review agreed the five-file boundary and ceilings below. Root and
an independent reviewer must review this document before its plan-only commit;
production requires a later writing and compiled-lane grant.

The [source plan's String boundary](BOOTSTRAP_SOURCE_PLAN.md#string-and-library-boundary)
requires counted integer-byte access and checked scalar encoding. Compiler
source still constructs one-byte Strings for classification, consumes Char
values and materializes `List[Char]` to emit literal bytes. Those dependencies
block the intended source subset and can split valid UTF-8 while examining it.
This is a behavior-preserving source refactor, not new input syntax.

Host `string.byte_at` and `string.from_codepoint` landed in `86777d833`.
The matching target APIs have separate focused/broad validation work; their
feature-cost acceptance and integration remain prerequisites. Current temporary
String declarations on this planning base do not yet provide them. Freeze the
accepted target commit and supporting host/runtime/library epoch before writing
production. Do not copy a host binary or quietly change the selected libraries.
The coordinator controls the serialized compiled lane. Compiled work requires
a separate grant and must not overlap another worker's compiled commands.

The authoritative interfaces are:

```blorp
pure func byte_at(value: String, index: Int) -> Option[Int]
pure func from_codepoint(value: Int) -> Option[String]
```

`byte_at` observes unsigned bytes; None is out-of-bounds, while Some(0) is NUL.
`from_codepoint` validates the full Int before narrowing and returns exact UTF-8
for every scalar, including NUL and noncharacters. Input Strings are trusted
valid UTF-8. Existing lexer rejection/diagnostic paths remain; this slice neither
adds admission nor removes checks because admission exists elsewhere.

## Scope and fact ownership

Line anchors refer to the planning base. Only these five production files change:
lex, parse, names and emit are the four Char consumers; main adds byte-column
classification. The linked [delivery item 4](BOOTSTRAP_SOURCE_PLAN.md#delivery-order-and-parallel-ownership)
gets only that boundary clarification. Neither this plan nor that wording change
marks the migration complete or advances the recorded 36/38 source frontier.

| Owner | Exact boundary | Required preservation |
| --- | --- | --- |
| [lex](src/lex/lex.brp):275–310, 376–494, 662–693, 739, 768, 920–965 | `is_byte`, `byte_is`, `byte_in`, UTF-8/quoted/Char readers, `punctuation`, code/comment/pipe/indentation reads | Existing ByteClass, Utf8Form, scanners, evaluated order, unsupported-Char errors and extents |
| [parse](src/parse/parse.brp):803–874, 894–1001, 2732–2743 | Integer/Float classification, continuation and escape reads, hex accumulation/scalar encoding, fixed escapes and type-parameter validation | Rigid token validation, range/error priority, raw spelling, count/shape rules and byte spans |
| [names](src/utils/names.brp):102–125 | `spelling_bucket` reads unsigned bytes directly | Exact wrapping `multiply(add(hash, byte), prime)`, constants, bucket normalization, full spelling equality and NameId issuance |
| [emit](src/emit/emit.brp):191–209 | `append_string_bytes` replaces `StringOps.chars` and `to_int` with byte iteration | Decimal bytes, comma order, logical length, and empty `{0}` storage |
| [main](src/main.brp):37–51 | `render_file_location` observes LF through byte access | Byte columns, LF reset, negative/past-EOF span behavior and rendered text |

No shared classifier, table, cache, new AST/IR state, closure/function-type
infrastructure, numeric literal patterns, library API or runtime representation.
Use named ASCII Int constants at the narrowest useful owner. Punctuation and
fixed-escape dispatch use direct numeric predicates, not Int/Char/String literal
patterns. Keep helpers first-order; introduce no callbacks to map Option values.
The parser adds only two private digit-value helpers, returning Option[Int], and
rewrites its existing type-parameter validator; remove the replaced alphabet
lower/search helpers rather than retaining a second classification path.

Leave whole-boundary slices unchanged: lex quoted contents:465, numeric
spelling:515, identifier spelling:700 and pipe runs:998; parse reserved-keyword
spelling:760 and raw String runs:1029. The fixed ASCII alphabet slice in
[float_literal](src/emit/float_literal.brp):66 stays. Checked slicing, joins,
filesystem admission, general HOF/pattern migration and opaque/hash work remain
separate. Do not repair adjacent semantics under this refactor.

## Literate changes and caller-specific absence

Current lexer predicate (`lex`:296) reads a Char solely to recover its byte:

```blorp
match StringOps.get(text.bytes, position):
    Some(character):
        is_byte(to_int(character), expected)
    None:
        False
```

The replacement changes `expected` to Int and consumes the byte directly:

```blorp
match StringOps.byte_at(text.bytes, position):
    Some(byte):
        IntOps.equals(byte, expected)
    None:
        False
```

Apply the same direct substitution to existing scanners without moving reads or
changing their termination/error branches. Decimal and hexadecimal helpers take
an Int byte and return its digit value or None. Reject non-ASCII bytes explicitly
by the accepted numeric ranges. Absence is handled by each caller, never by an
invented byte, empty String or global `get_or(0)` convention.

Current Float validation (`parse`:864) uses:

```blorp
Text.equals(spelling.substring(start, 1), "0")
    and DECIMAL_DIGITS.contains(spelling.substring(IntOps.add(start, 1), 1))
```

For forged Float tokens `"0"` and `"-0"`, the second substring is empty and
`contains("")` succeeds. Keep that absent-second-byte compatibility only here:
when the first byte is ASCII zero, a missing second byte retains the existing
leading-zero diagnostic. A present second byte must be a decimal digit for that
diagnostic. Callers preserve None for absent bytes; the Int-byte digit helpers
return None for non-digits.
Preserve forged integer rejection and the existing negative accumulation/range
checks; do not let arithmetic overflow outrank an invalid digit.

Unicode escape handling keeps the existing seventh hexadecimal digit consumption
(`hex_digits` stops after more than MAX_UNICODE_HEX_DIGITS), then validates
opening/closing shape and the one-to-six digit count. Only a shape-valid escape
calls `from_codepoint`, once. Some supplies `DecodedEscape.bytes`; None enters
the existing invalid-Unicode-escape error calculation, including its capped
digit position and `character_end` expansion. The API owns scalar-range/surrogate
validation; do not duplicate those checks merely to declare None unreachable.
No String is allocated speculatively for a malformed escape shape. Unknown and
truncated forged quoted-token escapes keep their existing parser error and span,
even where ordinary source would already be rejected by lexing.

Current name hashing (`names`:112–116) unwraps a Char in
`multiply(add(hash, to_int(byte)), SPELLING_HASH_PRIME)`. Change only the read and
remove `to_int`. Keep the bounded-loop None invariant documented; do not change
the hash to another algorithm suggested by its FNV-like constants.

Current emission (`emit`:198–203) iterates `StringOps.chars(bytes)` and appends
`to_int(character)`. Its replacement is the existing append loop driven by EOF:

```blorp
while True:
    match StringOps.byte_at(bytes, position):
        Some(byte):
            if IntOps.greater_than(position, 0):
                projected = projected.concat(",")
            projected = projected.append_int(byte)
            position = IntOps.add(position, 1)
        None:
            break
```

Retain the existing empty-array fallback after that loop. Some(0) is emitted and
counted; it cannot terminate iteration. In diagnostic rendering, by contrast,
the loop still ends at `span.start`: None is not LF and still advances the column.
Do not clamp a forged past-EOF span. For `"éx"`, offset 2 reports column 3 and
offset 5 reports column 6; LF after multibyte text still starts column 1.

## Characterization and sensitive mutations

Source-refactor tests must pass on the accepted baseline before production.
Do not manufacture a feature red. Reuse existing TestSuites and language fixtures:

- [String syntax](test/unit/test_parse/test_string_literals_syntax.brp):117–218
  already checks UTF-8/NUL/scalar boundaries, normalization/noncharacters,
  unknown `\\é`, invalid `\\u{é}`, invalid scalar escapes and seven-digit errors.
  Preserve exact source, message, help, note and half-open byte span.
- [Parser literals](test/unit/test_parse/test_parse.brp):259–299 already forges
  IntegerLiteral spellings. Add analogous FloatLiteral `"0"`/`"-0"` controls
  with the existing leading-zero error and unchanged token span; add a forged
  trailing escape characterization if the existing suite does not cover it.
- [Names](test/unit/test_utils/test_names.brp):97 onward: add multilingual
  reinterning/extension/rehash observations through public APIs, retaining
  existing collision/full-equality tests. Review arithmetic directly; changing
  a consistent hash alone need not change public identities.
- [Main](test/unit/test_main/test_main.brp): use `render_diagnostics` and existing
  source helpers for byte columns, LF after multibyte text and past-EOF spans.
- [Emitter](test/unit/test_emit/test_string_literals_ownership.brp):337–369
  already pins NUL-containing arrays, `{195,169,240,159,152,128}`, empty storage
  with logical length zero and a long literal. Reuse existing String e2e cases.

Mutate one fact at a time, record the named failure, restore exact bytes, then
rerun green: remove the Float absent-byte compatibility; shorten diagnostic
scalar expansion to one byte; stop emission at Some(0); reject uppercase hex
digits (add a baseline uppercase-escape case if needed); or accept encoder None
as an empty decoded String. A full-spelling-equality mutation must be killed by
the existing name-collision oracle. Compiler errors, setup failures and timeouts
do not establish the intended oracle. No production test export or new observer.

Preserve the seventh-digit scan rule by source comparison. Do not claim that a
stop-at-six mutation is necessarily killed by rejection/span tests: the existing
cap followed by `character_end` can produce the same public diagnostic. Use only
demonstrably sensitive behavioral mutations; do not export private scan state
or invent a counter to force this distinction into a test.

## Commands, identity and costs

Commands below are future acceptance commands, run from the authorized checkout
after dependency acceptance and root's serialized compiled-lane grant. The
supporting host must be FRESH for its own checkout; `make` rebuilds when needed.

```sh
scripts/compiler-build-status
make
scripts/compiler-build-status
bin/blorp test --suite --timeout 180 \
  blorp_2/test/unit/test_parse/test_string_literals_syntax.brp \
  blorp_2/test/unit/test_parse/test_parse.brp \
  blorp_2/test/unit/test_utils/test_names.brp \
  blorp_2/test/unit/test_emit/test_string_literals_ownership.brp \
  blorp_2/test/unit/test_main/test_main.brp
bin/blorp test --suite --timeout 180 \
  blorp_2/test/unit/test_lex blorp_2/test/unit/test_parse
mkdir -p build/source-byte-migration
bin/blorp compile --no-format --stop-after=lower --dump-core-after=lower \
  blorp_2/src/main.brp \
  > build/source-byte-migration/pre-dce-core.log 2>&1
make -C blorp_2 test
```

The first focused command is the repeatable characterization/mutation loop;
individual owning suites are the shortest iteration where appropriate. Full
pilot acceptance builds its compiler once and exercises unmodified fixture C
and real mains under the existing sanitizer/e2e protocol. This plan adds no
alternate main, emitted-C repair or new execution harness.

Require complete target C identity between local baseline B and candidate C,
plus matching outcomes/stdout and exact rendered diagnostics on every unchanged
owned input, including existing Unicode/NUL/long-literal fixtures. Cumulative
R0/C keeps and reviews complete raw target C diffs for all accepted intervening
features, including UTF-8 argv rejection/cleanup and both integer-facing String
helpers. No C normalization or fixture adaptation is permitted. A cumulative
diff not explained by those accepted features is a stop, not an identity waiver
for this source refactor. Inspect raw host-generated compiler C changes
separately: the compiler source changed, so its own generated C is not an identity
oracle. Preserve source, C and binary hashes and the actual bootstrap frontier.

Inspect the complete source inventory of all 38 compiler modules, together with
a bounded static check of these five files. Corroborate source references against
the fresh pre-DCE `lower` dump using the established source-plan invocation above;
retain module/declaration coverage and resolved callee evidence. A `perceus` dump
follows DCE and proves only reachable-code facts. The lower dump alone also does
not prove complete source coverage: reconcile every module and relevant source
reference, including forms absent from the dump, before claiming a complete
resolved call inventory. Require no compiler-owned Char values/literals/conversions,
`String.get`/`String.chars` reads or String alphabet lower/search calls. Identify
these APIs by resolved library owner, including import aliases; `List.get` remains
required. Comments, diagnostic wording, unchanged whole-boundary slices and
host-shim internals do not establish such a
dependency. Retain the source inventory, Core artifact and exact invocation.
If existing tooling cannot establish coverage or resolution, stop and report that
limit; introduce no scanner/export and delete no parity rows.

Planning estimates are 180–280 gross/+40–90 net production and 80–140 gross/
+60–120 net tests, not measured patch counts. Hard physical ceilings remain
**320 gross added / +110 net production**, **180 gross
added / +150 net tests**, **zero new fixture files/lines**. Count deletions and
documentation separately. Do not compress formatting, delete coverage or stack
another pilot's allowance. Scope expansion or a breach stops before further work.

The [source-plan cost protocol](BOOTSTRAP_SOURCE_PLAN.md#acceptance-and-cost-boundaries)
uses these three explicit variants under one frozen accepted supporting-host,
runtime/toolchain and build-mode epoch:

| Variant | Source and temporary target library | Comparison |
| --- | --- | --- |
| R0 | Exact unmodified reset `78bc406d6646eb7a1b61700b71d1faa9e9eaca09`, with its original temporary target library | Total cumulative baseline; not a supporting-host baseline |
| B | Immediately preceding accepted feature-era source with its matching temporary target library | Local baseline |
| C | This source migration over B, with the same feature-matched temporary target library as B | Candidate |

Use the same explicitly selected, frozen supporting-host standard library for all
R0/B/C producer builds and host proxies. Pin that uniform host-stdlib selection
and each variant's target-library selection separately. R0 keeps its original
temporary target library because its target compiler does not support the new
builtin labels; no historical host-stdlib selection is implied. Rebuild all
three with the same frozen supporting host and flags. Report host/runtime
transition costs separately; do not change epochs within the pair.

The cumulative program corpus is the original **452 exact program files** shared
with R0. Verify actual membership and bytes against the frozen inventory; counts
alone, names or path-prefix heuristics cannot establish that boundary. Local B/C
also includes the four accepted API fixtures (`byte_at.brp`, `byte_at_zero.brp`,
`from_codepoint_ownership.brp`, `from_codepoint_nul.brp`) from the accepted feature
inventory, with their exact bytes. Keep all four in local identity/cost checks,
full gates and their existing absolute caps. They are new relative to R0: do not
require R0 to compile unsupported APIs or change its original target library.
This plan adds no fixtures. Finite call accounting belongs to the later reviewed
recipe.

For allocations and normal min3 instructions, require **C/B <= 1.03 for every
local input**, **total C/R0 <= 1.03 for every shared reset input**, and **both
ratios for the host source-to-C proxy**. Total cumulative cost includes every
intervening accepted feature and its target-library changes. It is deliberately
stricter than subtracting feature costs: neither a feature's separate acceptance nor
another input's gain provides a deduction or allowance. Report all raw metrics
and the applicable ratios.

R0 source stays byte-identical. Do not backport accepted target features into it,
adapt sources/fixtures/C, construct a counterfactual R1 overlay or silently swap
target libraries to make a comparison pass. Any local or cumulative 3% breach stops
the stage and returns evidence to root before further work; it never triggers an
automatic overlay. An incompatible workload or unexplained output/diagnostic
change also stops for root. Host wrapper/Option dispatch may increase instructions
even when temporary Strings disappear; no successful cost result is predicted.

Reuse existing measurement recipes and one physical input/CWD/output boundary,
with three serial alternating normal pairs and separate strict leak/count runs.
Freeze source/library membership and hashes, host/bootstrap/toolchain/flags,
compiler C/binary provenance and raw samples. Root assigns paths and lane; no
shared scratch writes, host/std switch or measurement controller is implicit.
Preserve stricter fixture limits. A local or cumulative per-input breach stops;
neither aggregate allocation wins nor future-bootstrap credit waives it.

## Sequence, review and handback

1. Review this plan independently and with root, then publish its plan-only
   commit. No production or test implementation is authorized yet.
2. After target API acceptance/integration and an explicit writer/lane grant,
   freeze the accepted base/epoch, obtain passing baseline characterizations and
   baseline output/cost artifacts. No merging while a measured pair is running.
3. Implement only the five-file change; add bounded tests, prove sensitive
   mutations/restoration, then inspect the exact diff, generated C and inventory.
4. Obtain independent implementation/code-reviewer and test-runner evidence,
   the focused/full gates and both local/cumulative cost verdicts before root
   integrates. Keep the plan and implementation separately reviewable.

Return branch/commits and exact patch hashes; production/test/documentation and
fixture counts; baseline, mutant and restored outcomes; output/diagnostic identity;
inventory/source-subset evidence; raw sample paths and per-input/proxy verdicts.
Stop for a host defect, admission/identity disagreement, changed diagnostic
priority, ownership ambiguity, missing observer, required new mechanism or cap
breach. Reduce and report the witness to root; do not fix an adjacent subsystem
or silently widen the contract. Root and independent review precede any commit.
