# The existing lexer cannot nest interpolation, keep braces in pipe strings or read character literals in a hole

Status: open. Blocks the discovery acceptance roadmap's same-program criterion (the
adapter's rebuilt parsed AST equals the old parser's) and one-syntax criterion (both
parsers agree on every rule decidable from syntax) for these inputs only.

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
  that also holds a hole is read as a hole. Finalization takes each hole's
  location from its `${...}` in the source and rejects a hole the source does
  not write that way, so such a string is now a parse error (help: write the
  brace as `\{`) rather than a hole with another hole's location.

- **Character literals in a hole.** The lexer scans a hole's code for quotes
  and braces without knowing character literals, so `"${'}'}"` is closed at the
  `}` inside the literal and rejected, as are `'"'`, and a literal holding
  `$` or `\` is not read as one. The discovery stage reads a character literal
  in a hole as one token (`test_body_parser.brp` pins `}`, `"`, `$`, `\` and
  `\u{7d}`); the existing lexer rejects the input, so it cannot be a parity
  fixture, which compares accepted programs.

The discovery stage reads these as the language says (a stack of code and string
frames in `hole_scan`, `lex/lexer.brp`). Two inputs the existing lexer read
wrongly in the first segment of a quoted interpolated string were fixed in the
existing lexer when the adapter's differential found them: `\u{...}` after a
hole, and braces and backslashes before the first hole.

## Evidence

- `blorp/test/compiler/tools/fixtures/known_differences/interpolation_nesting.brp`
  is in the corpus; the adapter differential reports it, and
  `ADAPTER_DIFFERENCES` in `scripts/compiler-new-parity` lists the difference
  with this reason.
- `blorp/test/compiler/tools/fixtures/known_differences/interpolation_pipe_braces.brp`
  is in the corpus; the existing parser rejects it and the stage accepts it, and
  `KNOWN_DIVERGENCES` in `scripts/compiler-new-parity` lists it.
- `test_body_parser.brp` pins the stage's reading to four levels and to a brace
  in a nested string.

## Proposed fix

Replace the flag in `scan_interpolated_string_tail` with the frame stack the
stage uses: only a `${` outside every string becomes `{` in the token text, a
nested `${` stays as written, and a pipe line is scanned the same way. Then
delete the `ADAPTER_DIFFERENCES` entry and both fixtures' `KNOWN_DIVERGENCES`
reasons.
