# Formatter

Status: approved by Keith on 2026-11-06 (revision 3, after two reviews), with
D1 decided as (a). F1 to F3 have landed: the parse tree keeps parentheses and
declaration starts (`3887c855e`), the formatter is in `864c9b950`, and the
repository was formatted in `1ca080abd`, which `.git-blame-ignore-revs` lists;
`make -C blorp test` checks that every parsable source stays formatted.

## Problem

Blorp has no formatter, and the repository's hand layout has drifted:

- 50 files under `blorp/src` indent with tabs; most tests and every example in
  `README.md` indent with four spaces.
- 2,608 lines under `blorp/src` are wider than 100 columns. The longest,
  `check/traits.brp:8`, is one 900-character import selection.
- The same construct wraps differently from file to file:
  `check/render.brp:241-243` breaks a chain before two of its links, while
  `check/declarations.brp:994-996` breaks before every link.

A reviewer cannot tell layout changes from real ones, an exact-text edit tool
fails on a tab it did not expect, and code an agent writes has no canonical
shape to aim for.

Reproduction at `5b48adb9e`, from the repository root:

```sh
files=$(git ls-files 'blorp/src/*.brp' 'blorp/src/**/*.brp')
awk 'length > 100' $files | wc -l                 # 2608
grep -l "$(printf '^\t')" $files | wc -l          # 50
```

## Background

What the formatter reuses (surveyed 2026-11-06):

- **The lexer drops comments, `---` documentation blocks and blank lines** as
  trivia (`lex/lex.brp:948-1100`, `grammar.ebnf:90-99`). A documentation
  block opens and closes with a `---` line at column 1, and its body admits
  any byte except CR. `LexedProgram` keeps the whole `source_text` and every
  token's byte-offset `Span` (`utils/syntax.brp:8-12`, `:216-226`), so every
  piece of trivia is recoverable from the gaps between tokens.
- **The parser builds an abstract tree.** Every `ValueExpression` has a
  `base_span` and a `span` (`utils/syntax.brp:367`), and so do names, import
  selections, type syntax, patterns, match arms and Dict entries. `x.f(y)`
  (`ReceiverInvocation`) stays distinct from `f(x, y)` (`DirectApplication`).
  It drops:
  - parentheses: a group is transparent (`parse/parse.brp:2029`);
  - trailing commas and line breaks inside brackets;
  - the order between declaration kinds, which go into separate lists
    (`parse/parse.brp:4330-4360`);
  - a whole-declaration span: `ParsedFunction`, `ParsedRecord` and
    `ParsedUnion` locate only their names, and `pure` and `fixed` carry no
    span (only `Visibility.Private(Span)` does);
  - literal spellings: literals hold decoded values;
  - the difference between `else if` (`ElseIf(ParsedIf)`) and an `else:`
    block holding only an `if`, which are different trees
    (`parse/parse.brp:1880-1887`, `utils/syntax.brp:586, 649-651`).
- **Lexing and parsing run on one file alone.** `lex` then `parse_module`,
  then the public `module_contents` (`parse/parse.brp:189`), with a
  `SourceId`, a `ModuleId` and the base `program_names().names`, as
  `test/unit/module_input.brp:75-78` already does. No imports are loaded.
- **Name ids depend on lexing order** (`utils/names.brp:240`).
- **No source printer exists** anywhere in `blorp/`.

### Decisions already taken (Keith, 2026-11-06)

1. Indent with 4 spaces.
2. Wrap at 100 columns.
3. Sort import modules: library modules, then relative paths, each
   alphabetical. Names inside one selection keep their written order.
4. Wrap all or nothing: a list of parameters, arguments, fields, elements or
   selections is on one line, or has one item per line with a trailing comma.
5. Hug a final list literal, record literal or block lambda when everything
   before it fits on the first line.
6. Never move a trailing comment, even past the width.
7. Two blank lines between top-level declarations, except that a run of
   one-line constants keeps the 0 or 1 blank lines it was written with.
   Inside a body, at most one blank line in a row.
8. Remove parentheses only where they wrap a whole value: a binding value,
   argument, element, condition, body's final value, record field or Dict
   entry value, or `?=` value (the last four by D1). Keep every other pair
   the author wrote.
9. A declaration's header line holds its keyword, name and opening bracket.
10. `--check` changes nothing, prints `path:line: would reformat` per file
    that would change, and exits 1 if any would.
11. The architecture: the shared parser plus source positions.

Settled without a choice: one space around binary operators, `=` and
annotation `:`, and after commas; a space inside record braces and none inside
`[]` or `()`; no column alignment; `if` is always a block, and an `else:`
block prints as written; the formatter never turns it into `else if`;
continuation lines start with `.` or an operator; literals, escapes, pipe
strings and documentation blocks print as written; interpolation holes never
break; declarations, match arms and call spellings are never reordered or
rewritten; LF endings and one final newline.

The `else:` clause was decided by Keith on 2026-11-06, replacing "an `else:`
holding only an `if` prints as `else if`": the two are different trees, and in
statement position they compile to different C, so the rewrite would change
structure, not layout, and break F3's byte-identical self-compiled C.

### D1: where the formatter may add parentheses (decided: a)

Breaking a long operator chain needs parentheses (a line cannot end in `+`).
For idempotence the formatter adds them only where it also removes them, so
that at those positions parentheses are purely layout: present exactly when
the chain is broken. Keith chose (a) on 2026-11-06: decision 8's positions
are binding values, arguments, elements and conditions, plus a body's final
value, record field and Dict entry values, and `?=` values. Each is a whole
value whose parentheses can never change meaning. The rejected option (b)
kept decision 8's original four, leaving chains elsewhere unbreakable.

## Proposed solution

### Architecture

The formatter lexes and parses one file with the compiler's front end and
prints the tree. It never recognizes syntax on its own. What the tree lacks
comes from the source by position, never by guessing:

- **Literals and documentation blocks** print as their source text
  (`source_text.slice(base_span)`; a documentation block's lines verbatim).
- **Declaration order** comes from merging the per-kind lists by start span.
- **Trailing commas and import grouping** are canonical, so their loss does
  not matter.
- **Parentheses and declaration starts** are the two facts the tree must
  start keeping (F1), without changing what Check sees.
- **Comments and blank lines** come from the gaps between nodes (below).

### Comments

Comments are not attached to tree nodes. The printer keeps a cursor into the
source, as gofmt does. Before it emits a node or a closing delimiter, it
emits the trivia between the cursor and that position:

- **Placement.** A comment that starts on the same source line as the last
  emitted code stays a trailing comment of that line, including after a block
  header's `:`. Any other comment gets its own line at an indentation level
  taken from its own source indentation, counted in the lexer's units (one
  tab or four spaces per level): the deepest open block, including the block
  the next code line opens, whose level does not exceed the comment's.
  Comment lines carry no layout meaning in the grammar, so this keeps a
  comment at the end of a block inside that block, and a comment just after
  `if c:` inside the new block. A comment at column 0 between statements
  stays at column 0. A broken bracketed list and a broken method chain count
  as open levels too, so a comment inside one, or between two chain links,
  takes its items' or links' indentation, whatever its own.
- **Closing delimiters.** Before a `)`, `]` or `}`, the printer flushes
  trivia up to the delimiter's position, at item indentation. The position
  is the closing token itself, found in the lexed tokens as the first token
  after the last item that is not a comma; the grammar allows nothing else
  there. This works for parameter lists, record and variant fields and
  import selections, whose nodes carry no closing span, and covers comments
  after the last item and inside empty brackets.
- **Forced breaks.** A construct with a comment anywhere inside it is laid
  out broken, never flat, so code is never joined onto a comment line.
  Patterns, types and declaration header lines (a declaration's keyword,
  name and type parameters, or a binding's name and annotation before its
  `=`) never break, so a comment inside one stops formatting that file with
  a diagnostic at the comment: "the formatter cannot keep a comment inside a
  pattern" (or a type, or a declaration's header line), with the help "move
  this comment above the line; the formatter keeps comments only between
  items it can break". A comment after a binding's `=` or `?=` stays on that
  line, and the value moves to the next one.
- **Imports.** Sorting moves rows, so imports are the one place with
  attachment: a comment on a row's line, or directly above it with no blank
  line between, moves with that row. Other comments in the import block stay
  at its top.
- **Invariant.** A gap may hold only spaces, LF, `--` comments and
  documentation blocks. Anything else means a span is wrong; the formatter
  reports an internal error and leaves the file untouched.

### Layout engine

Each construct is laid out from its own contents and indentation only:
print it flat; if that passes column 100 or holds a comment, break it by its
one rule (one item per line, one chain link per line, or parenthesized
operands with the operator first), then lay out each child the same way.
Only the outermost operator chain of a value breaks; its operands stay flat
unless they are themselves parenthesized or bracketed. There is no cost
function and no search across siblings, so an edit changes the layout of the
constructs containing it and of nothing beside them.

### Rejected alternatives

- **A separate formatter parser.** A second grammar drifts; the legacy
  formatter's copy needed a parity gate and still drifted.
- **A token-tree formatter.** It still needs precedence, lambda bodies and
  match arms, so it is a smaller second grammar. It is the fallback if F1's
  spike exceeds its ceiling.

### Phases

Grouping and declaration starts are syntax, so the change belongs to Parse
(`AGENTS.md` rule 8). Check must see exactly the tree it sees today. The
formatter is a new module, `src/format/`, that depends only on `lex`, `parse`
and `utils`, so it formats files that do not type-check.

1. **F1: keep parentheses and declaration starts in the parse tree.**
2. **F2: the formatter**, its `--format` and `--check` modes and its tests.
3. **F3: format the repository** in one commit, list it in
   `.git-blame-ignore-revs`, and add the check to `make -C blorp test`.

## Code

### F1: parentheses the formatter can see and Check cannot

Today the group disappears at `parse/parse.brp:2027-2029`:

```blorp
private pure func finish_enclosed_value(enclosed: ParsedEnclosed) -> Result[ParsedValue, Diagnostic]:
	inner: ValueExpression ?= match enclosed.contents:
		GroupedContents(value): Ok(value)
```

Check must see exactly today's tree. It reads written expressions at about
twenty sites in `check/expressions.brp` and `check/bodies.brp` (for example
`expressions.brp:577, 602, 701, 845, 894, 945` and `bodies.brp:259, 277,
797`), several through `_` arms that would silently accept a new shape, and
several depend on today's shape: `for i in (0..3)` must stay a range,
`X: Int = (5)` a closed initializer, `t[(0)]` a literal index, and
`(x.f()).g()` one application list. A group variant in `ExpressionBase` would
reach those `_` arms, and a group-free copy of the expression types would
cost far more than the ceiling. So the parentheses are recorded beside the
tree, where Check never reads them. The expected design:

```blorp
-- utils/syntax.brp
record ValueExpression {
	base: ExpressionBase,
	base_span: Span,
	applications: List[PostfixOperation],
	span: Span,
	-- The written parentheses around this value, outermost first; the
	-- formatter reads them, Check never does.
	parentheses: List[Span]
}
```

`finish_enclosed_value` adds the group's span to its value's `parentheses`
instead of discarding it. Check never reads the field. The cost is the 34
places in `parse/`, `parse/assemble.brp` and `check/` that build a
`ValueExpression` literal today, each of which gains `parentheses = []` (or
becomes a record update), which the line ceiling must absorb. The one case this cannot
express is a group whose value is then flattened into an outer chain,
`(x.f()).g()`, which reprints as `x.f().g()`; the spike counts how often the
repository writes that and reports it.

The spike compares this with a `group_spans` list on `ParsedModuleContents`.
That list would leave `ValueExpression` alone, but the formatter would then
have to match spans, which needs spans that are exact for every value.

Declarations gain a `start: Span` covering their first token (`private`,
`pure`, `fixed` or the keyword), for blank-line and documentation placement.

### F2: the CLI

`src/main.brp:131-139` matches argument lists. Two arms join it, and
`usage_error` (`main.brp:142`) names both modes:

```blorp
		[_, "--format", ...paths]: paths.format_files(FormatInPlace)
		[_, "--check", ...paths]: paths.format_files(ReportUnformatted)
```

No library root is needed. In-place writes use `write_text`, as `publish`
does (`main.brp:151`). `--check` reports the first line where the formatted
text differs from the input. An unparsable file prints the parser's usual
`path:line:col: error:` diagnostic, stays untouched, and makes the command
exit 1.

## Scope and non-goals

In scope: `utils/syntax.brp` and `parse/` (F1), Check's reading of groups,
`src/format/`, `src/main.brp`, their tests, a Formatting section in
`README.md`, and `grammar.ebnf` only where a comment describes grouping.

Not in scope: LSP or editor integration; code blocks in `.md` files; lint
rules; any rewrite beyond layout; lexer changes.

## Risks and unknowns

- **F1 spike: where parentheses are recorded.** Question: does a
  `parentheses` field on `ValueExpression`, or a `group_spans` list on the
  module, record every written group within the ceiling, with Check's
  behaviour untouched? Throwaway code on a branch that does not land; one day. Ceiling: self-compile allocations and retired
  instructions each within +0.5% of the matched baseline, production lines
  within +60, and the self-compiled C byte-identical. If neither option fits,
  stop and report with the token-tree fallback.
- **Parse tests.** `test/unit/test_parse/test_grouping.brp:64-99` asserts
  that `(7)` is an `IntegerExpression` with `base_span` 23..24. With the
  expected design that stays true and the test gains the recorded
  parentheses; if the spike chooses otherwise, the parse suites that match
  `.base` are rewritten. No Check suite may change.
- **Spans that start late.** The comment cursor needs every node's span to
  start at its first token. F2 starts by checking this for every node kind
  over the repository; a node whose span starts late is fixed in Parse first.
- **Long import lines.** Wrapped one name per line, the 900-character
  selections become long blocks. That is the decided behaviour.

## Testing

Suites live under `test/unit/test_format/` and are listed in
`COMPONENT_SOURCES` in `test/e2e/self_hosted.brp` (`blorp/AGENTS.md`,
"Tests"), plus the Parse suites F1 rewrites.

- **F1:** a parse test that `(a + b) * c` records the parentheses' span on
  `a + b`, that `((a))` records both pairs, and that declarations' `start`
  covers `private pure`. Every Check suite passes unchanged.
- **Layout pairs:** an input and expected output per rule, each named for its
  rule. They include hugging, constant runs, every parenthesis position,
  a trailing comment past the width, comments after the last item and inside
  empty brackets, a comment at the end of a block and one just after a block
  header, a documentation block with blank and arbitrary lines, imports with
  attached and trailing comments, parentheses added to break a chain at the
  start of a statement (which Parse reads through
  `consume_parenthesized_line`, `parse/parse.brp:2610`), and an unparsable
  input.
- **Idempotence:** formatting every expected output returns it unchanged.
- **Meaning preserved:** for every `.brp` file in the repository that parses,
  `parse(format(file))` equals `parse(file)` under a test-only rendering that
  prints name spellings rather than ids, omits spans and the parentheses
  that wrap a whole value at decision 8's positions, and sorts imports. It
  also compares the declarations' written order across kinds, and each
  comment's text, whether it is trailing or on its own line, and how many
  names, literals and keywords precede it. A file that does not parse
  (failure fixtures) is skipped and counted, and must be left byte-identical
  by `--format`.
- **Locality:** lengthen one argument's name in chosen files, format, and
  check that only the containing statement's lines differ.
- **Red check:** break one rule in the printer (for example drop the
  trailing comma) and confirm only that rule's pair and idempotence fail.

Commands: `make -C blorp test-target-components
TARGET_COMPONENT_SOURCES=blorp/test/unit/test_format/<suite>.brp` while
iterating; `make -C blorp test` before review.

## Acceptance criteria

- F1: the new parse tests fail before and pass after; `make -C blorp test`
  passes with no Check suite edited; the ceiling above holds, reported with
  production and test line counts separately; self-compiled C byte-identical.
- F2: every layout pair, idempotence, meaning-preserved and locality test
  passes. `blorp/build/compiler --check` on an unformatted file prints
  `path:line: would reformat` and exits 1, and on an unparsable file prints
  the parser diagnostic and exits 1.
- F3: `--check` over the repository prints nothing and exits 0; `make -C
  blorp test` passes; the self-compiled C is byte-identical before and after
  the formatting commit.

## Release strategy

Three landings in order: F1, F2, F3. F3 holds only the formatter's output,
`.git-blame-ignore-revs` and the check's Makefile line, so it reverts
cleanly. None adds a builtin, so no bootstrap rotation is needed.
