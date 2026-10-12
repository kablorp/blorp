# Quoted String literals

Calculator increment 3 starts with this executable example:

```blorp
func main() -> Int:
    length("hello")
```

It exits 5 through its real main. The compiler at `2f5795cc7` rejects quoted
values outside builtin declarations. This increment adds UTF-8 literal
construction, copies and returns; Void, printing, input, interpolation, raw
strings and multiline literals remain separate increments. Unicode support is
included from the start following the user's explicit steering.

## Syntax and ownership of facts

Identifiers and comments retain their current ASCII rules. A quoted literal
occupies one physical line and accepts well-formed UTF-8 scalar sequences.
Ordinary ASCII contents are printable bytes other than quote and backslash. The nine fixed
escapes from Blorp's existing grammar are supported: `\n`, `\r`, `\t`, `\0`,
`\\`, `\"`, `\'`, `\{` and `\}`. Unicode escapes use `\u{X...}` with one to six
hexadecimal digits naming a scalar from U+0000 through U+10FFFF, excluding
surrogates U+D800 through U+DFFF. No normalization is performed. Raw ASCII
control bytes, DEL, missing closing quotes, unknown escapes, malformed UTF-8,
invalid scalar escapes and `${` interpolation openers produce precise
diagnostics with help. Escaping the brace permits literal `${` text. Comment
markers inside quotes are ordinary contents. Noncharacters remain valid scalars.

The lexer publishes one general quoted token retaining its raw contents and
original half-open source byte span. Parsing decodes expression literals once
into a typed String expression. Builtin declarations still match the raw label
exactly to the closed operation enum; escapes cannot alias an intrinsic label.
There is one escape decoder, and later phases never reinterpret source spelling.

Decoded String bytes are literal value data, rather than names used for
resolution. Each typed phase carries its ordinary literal variant and complete
type. A literal has no declaration identity; lowering gives each evaluated
occurrence an existing function-local ValueId. No literal table, pool, cache,
global lifetime exception or additional pass is needed for this example.

This follows the separation of literal tokens and interpreted literal values in
the [Rust reference](https://doc.rust-lang.org/reference/tokens.html#string-literals).
UTF-8 validation follows [RFC 3629 section 4](https://www.rfc-editor.org/rfc/rfc3629#section-4),
rejecting overlong sequences, surrogates, out-of-range scalars, truncated
sequences and isolated continuation bytes. The single-line restriction is this
pilot's scope. Raw validated UTF-8 slices are copied unchanged; only Unicode
escapes invoke scalar-to-UTF-8 encoding. Temporary host Char conversion helpers
used for byte inspection/encoding remain dependencies to cover before bootstrap.

## Managed construction and emission

A lowered String value becomes a String definition producing a fresh
OwnedResult. The existing ownership analysis handles copies, borrowed calls,
unused values, reassignment and return transfer. Independent verification derives
StringType from the operation and rejects a missing, borrowed, reused or leaked
owner. This continues the existing explicit RC lifetime model; the
[Lean reference](https://lean-lang.org/doc/reference/latest/Run-Time-Code/Reference-Counting/)
provides established context for owned and borrowed runtime values.

The runtime constructor accepts bytes and their explicit length, allocates one
ordinary immutable String with reference count one, copies exactly those bytes
and appends a trailing NUL. Embedded NUL is part of the value and length.
String length remains the UTF-8 byte count, matching the existing library's
contract: `length("é")` is 2 and `length("🙂")` is 4. The
existing integer formatter reuses that constructor so allocation/header
initialization has one implementation. Each String definition emits a flat,
function-local `static const unsigned char` array named from its existing
ValueId, then passes those bytes and their explicit length to the constructor.
Empty backing arrays contain one dummy zero byte with logical length zero.
This avoids C string-token length limits, escape ambiguity, and automatic
stack storage or initialization copies for the backing bytes. It adds no
literal identity, pool or pass; each evaluated runtime String remains fresh
and mortal. Literal ownership and destruction follow the existing rules.
Block-scope compound literals would use automatic storage under C11; the
[WG14 storage-duration discussion](https://www.open-std.org/jtc1/sc22/wg14/www/docs/n3038.htm)
explains why an explicit static declaration is needed here.

Extending the shared runtime fragment intentionally changes the C prefix of
existing String programs. Existing function bodies must stay unchanged, and
programs without the String runtime should remain byte-identical. Native
behavior, sanitizers and ownership tests remain the correctness gates. This
does not broaden the existing rejection of managed binding prefixes before
tail matches or managed values in annotated tail-recursive functions.

## Tests and acceptance

Start with failing direct lexical/parser and ownership tests, then the first
fixture. Use Blorp TestSuite callbacks for lexer spans, decoding and rejection
diagnostics, parsed/checked/concrete values, lowering/use facts, fresh owner
insertion, copies, drops and returns. Test independent verification with malformed
String definitions and obligations. Unit tests should exercise their owning
phase directly where practical. Update EBNF conformance and supported grammar
documentation together.

Approved direct String-runtime C tests check exact bytes, explicit lengths,
empty, UTF-8 and embedded-NUL values, independent allocations, reference counts and
final frees. Add native fixture programs for basic length, empty/escaped text,
copies/returns, Unicode scalars/escapes, unused and reassigned literals, generic use and managed union
payloads. Fixtures use normal main and unchanged generated C. Deliberately break
construction or emission and require its regression to fail, then restore it.

Use focused tests while iterating, then strict unit/runtime/grammar/tooling
suites with ASan/UBSan and leak checking, followed by the full end-to-end suite
with timeout 0. Build the pilot once per e2e run and compile each fixture once,
at -O0. Compiler-expert implementation and independent code/test/document
review are required; serialize compiled gates and measurements.

Freeze the current compiler, prelude, target library and 147 existing executable
fixture roots (139 previous roots and 8 Int-addition roots), including local
dependencies. Three paired samples compare whole pilot compilation through C
emission under the same explicit library root and toolchain. Both allocation
and retired-instruction aggregate ceilings are +10%. Probe representative long
literal sizes for accidental repeated reconstruction during scanning, decoding
or emission, and compile a literal above the strict C toolchain's 4,095-byte
string-token limit without suppressing diagnostics. This is an owned-input
proxy, not self-compilation. Report intentional runtime-only C differences and
production/test line changes separately; aim for at most 600 added production
lines. Set new fixture cost ceilings after retaining observed costs. Evidence
lives under ignored `build/strings/`, with one retained report linking artifacts.
