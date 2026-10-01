# The existing lexer cannot nest interpolation or keep braces in pipe strings

Status: open. Blocks roadmap criteria 1 and 6 for these inputs only.

The language lets an interpolated string hold, in a hole, another string with
holes, to any depth (`docs/GUIDE.md`, `docs/GRAMMAR.md`). The existing lexer
(`blorp/src/compiler/stage_02_lex/lexer.brp`) and its second step
(`finalize_interpolation_program`) do not:

- **Nesting.** The lexer tracks "inside a string" in a hole with one flag that a
  quote flips, so a string inside a hole inside a string inside a hole is
  mis-paired. Three levels (`"a ${f("b ${g("c ${h}")}")} d"`) lex to a text
  `c {h}` at the innermost level, silently; four levels, or a `}` in a nested
  string (`"p ${f("q ${g("}")} r")} s"`), is rejected.
- **Pipe strings.** Every `${` of an interpolated pipe string is read as `{`,
  and the splitter then reads every `{` as a hole, so `{kept}` in a pipe string
  that also holds a hole becomes a hole.

The discovery stage reads both as the language says (a stack of code and string
frames in `hole_scan`, `lex/lexer.brp`). Two inputs the existing lexer read
wrongly in the first segment of a quoted interpolated string were fixed in the
existing lexer when the adapter's differential found them: `\u{...}` after a
hole, and braces and backslashes before the first hole.

## Evidence

- `blorp/test/compiler/tools/fixtures/known_differences/interpolation_nesting.brp`
  is in the corpus; the adapter differential reports it, and
  `ADAPTER_DIFFERENCES` in `scripts/compiler-new-parity` lists both
  differences with this reason.
- `test_body_parser.brp` pins the stage's reading to four levels and to a brace
  in a nested string.

## Proposed fix

Replace the flag in `scan_interpolated_string_tail` with the frame stack the
stage uses: only a `${` outside every string becomes `{` in the token text, a
nested `${` stays as written, and a pipe line is scanned the same way. Then
delete the two `ADAPTER_DIFFERENCES` entries and the fixture's reason.
