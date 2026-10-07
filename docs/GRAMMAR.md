# Blorp Formal Grammar

This document is the authoritative specification of Blorp's syntax. A parser
implementer, a reviewer or a fuzzer should be able to decide from it alone
whether a source text is syntactically valid and, if it is, how it is
structured. It has five parts, in the style of the Haskell 2010 Report:

1. [Lexical structure](#1-lexical-structure): how source text becomes tokens.
2. [The layout algorithm](#2-the-layout-algorithm): how line breaks and
   indentation become `NEWLINE`, `INDENT` and `DEDENT` tokens.
3. [Context-free grammar](#3-context-free-grammar): the syntax over the token
   stream, with the operator table.
4. [Position rules](#4-position-rules): the few rules the token stream cannot
   express, because they compare source columns.
5. [Static syntactic restrictions](#5-static-syntactic-restrictions): rules the
   parser (or, where stated, the typechecker) enforces beyond the grammar.

[Section 6](#6-owner-decisions-of-2026-10-06) records the language decisions
this specification already follows, [section 7](#7-decisions-needed) lists the
questions still open, and [section 8](#8-where-current-behaviour-differs)
collects every place where today's parsers differ from the intended grammar.

Name resolution, scoping, UFCS dispatch, trait coherence and type rules are
outside this document; the [Language Guide](GUIDE.md) and
[Architecture](ARCHITECTURE.md) describe them. Where a syntactic form has a
type rule that users meet as part of its syntax (subscript assignment, an
interpolation hole), the rule is stated in section 5 with the phase that
enforces it.

## 0. Status, notation and evidence

### 0.1 Intended grammar and current behaviour

The grammar rules (prose and EBNF) state what is **decided**: today's
behaviour, changed by every owner decision. Three kinds of note mark where
that differs from what the parsers do, or where a question is open.

> **Current behaviour differs:** what the parsers do today. *(pending language
> change)*

A decided rule that is not implemented yet. The change itself is separate
work.

> **Current behaviour differs:** what the parsers do today. *(implementation
> defect)*

A rule the language does not need to decide, because the parsers hang, accept
an input every reading of the grammar rejects, or reject the right input with
the wrong diagnostic or at the wrong place.

> **Recommended (D*n*):** the rule this document recommends for an open
> question.

An open question from [section 7](#7-decisions-needed). Until it is decided,
the rule above the note (today's behaviour) stands, and the note shows the
recommended replacement. A rule with no note describes what the parsers do
today.

Quoted diagnostics are the discovery stage's text, which the compiler reports;
it is a lowercase message with a separate help line, quoted or paraphrased
after "with the help". The old parser's wording differs in a few places,
listed in [section 8.2](#82-old-parser-and-discovery-stage-disagreements).

### 0.2 The implementations

Three implementations, holding four parsers, read this grammar today:

- the **discovery stage** under `blorp/src/compiler_new/stage_01_discovery/`,
  which the compiler runs (`check`, `compile`, `run`, `test`). It has one lexer
  (`lex/`) and two parsers (`parse/`): the **tree path** (`parse/tree_*.brp`),
  which reads what it supports and declines the rest, and the **table path**
  (`parse/body_parser.brp`, `parse/declaration_parser.brp`,
  `parse/block_layout.brp`), which reads everything the tree path declines;
- the **old lexer and parser** under `blorp/src/compiler/stage_02_lex/` and
  `stage_03_parse/`, which still serve `compile --ast`, test discovery and the
  LSP, and which defined today's behaviour;
- the **formatter's** own copy of the parser.

The `compiler-new-parity` gate keeps the discovery stage and the old parser in
agreement. [Section 8.2](#82-old-parser-and-discovery-stage-disagreements)
lists the places where they disagree.

### 0.3 Evidence references

File and line references are to the source at the commit that introduced this
revision of the document. They drift as the code changes; search for the named
function when a line has moved. Short names:

Paths in the table are relative to `blorp/src/`; `DISC/` stands for
`compiler_new/stage_01_discovery/`.

| Short name | File |
| --- | --- |
| `LP` | `compiler/stage_03_parse/language_parser.brp` (old parser) |
| `OLX` | `compiler/stage_02_lex/lexer.brp` (old lexer) |
| `LEX` | `DISC/lex/lexer.brp` |
| `LAY` | `DISC/lex/layout.brp` |
| `STR` | `DISC/lex/string_literals.brp` |
| `HOLE` | `DISC/lex/interpolation.brp` |
| `CHR` | `DISC/lex/char_literals.brp` |
| `SCAN` | `DISC/lex/scan_support.brp` |
| `BODY` | `DISC/parse/body_parser.brp` |
| `BLK` | `DISC/parse/block_layout.brp` |
| `QRK` | `DISC/parse/layout_quirks.brp` |
| `STOP` | `DISC/parse/stop_reason.brp` |
| `TREE` | `DISC/parse/tree_body_parser.brp` |
| `TTYPE` | `DISC/parse/tree_type_parser.brp` |
| `TYPE` | `DISC/parse/type_parser.brp` |
| `TOK` | `DISC/tables/token.brp` |
| `LIM` | `DISC/tables/limits.brp` |
| `POS` | `DISC/tables/source_position.brp` |
| `RND` | `DISC/diagnostics/render.brp` |
| `FIN` | `compiler/stage_03_parse/source_ast_finalize.brp` (old parser's hole parsing) |
| `INFER` | `compiler/stage_06_typecheck/infer.brp` |
| `SEM` | `compiler/stage_06_typecheck/type_system/semantic_type.brp` |

### 0.4 Notation

The grammar uses Extended Backus-Naur Form:

```
=           definition                    ;      end of a rule
|           alternation                   [ x ]  optional (zero or one)
{ x }       repetition (zero or more)     ( x )  grouping
"text"      a keyword or symbol token     UPPER  any other terminal token
lower       a non-terminal                (* *)  comment
```

In the lexical rules of section 1, a quoted text is a sequence of characters,
and a double quote is written `'"'`. `seq(x)` abbreviates a sequence of `x`
items on successive lines; it is defined in
[section 3.1](#31-terminals-and-item-sequences).

## 1. Lexical structure

### 1.1 Source text

A source file is UTF-8 text. Lines end with a line feed (U+000A). A carriage
return is not whitespace: it is reported as an unexpected character, so files
with CRLF line endings are rejected (`LEX:920-947`). Outside string, character
and comment text, only ASCII characters may appear; any other character is an
unexpected character (`LEX:932-947`).

Columns are one-based. A tab advances the column to the next tab stop, and tab
stops are every 4 columns: a tab at column `c` moves to column
`c + 4 - (c - 1) mod 4`. So the indentations "two spaces then a tab", "one
tab" and "four spaces" are all 4 wide (`POS:17-24`,
`SCAN:198-215`). Blanks are spaces and tabs.

### 1.2 Comments

A comment starts with `--` and runs to the end of its line (`LEX:818-824`).
Comments are not tokens. `--` inside a string or character literal is text. A
`---` fence line is a docstring, not a comment ([1.6](#16-string-literals)).

A line holding only a comment is *not* a blank line for layout: see
[section 2.4](#24-consequences-and-quirks) and [D1](#d1-comment-only-lines).

### 1.3 Identifiers

```ebnf
IDENT  = ( letter | "_" ) { letter | digit | "_" } ;   (* not a keyword, and not "_" alone *)
letter = "a".."z" | "A".."Z" ;
digit  = "0".."9" ;
```

Identifiers are ASCII (`SCAN:101-106`). A lone `_` is the `"_"` token, not an
identifier (`LEX:825-836`). `enum`, `fixed`, `raw` and `struct` are identifiers:
`fixed` introduces a declaration only directly before `record` or `union`
(`LP:1171-1178`), and `raw` introduces a raw string only as described in
[1.6](#16-string-literals).

### 1.4 Keywords

These spellings are keywords (`TOK:161-208`):

```
after       alias       and         as          break       builtin
concurrent  concurrently            continue    debug       detach
else                    False       for         foreign     from
from_opaque func        if          implements  import      in
into_opaque match       not         on          opaque      or
private     pure        record      resource    select      sealed
Self        trait       True        try         type        union
var         void        where       while       with
```

Keywords fall into two classes.

**Reserved keywords** may never be written where a name is declared: a
binding, parameter, pattern variable, field, function, type or declaration
name. Writing one there is a syntax error that names the keyword, for example
``error: `alias` is a reserved keyword and cannot be used as a name``, with the
help ``choose another identifier such as `alias_name` `` (`RND:926-930`,
`LP:1482-1526`). Every keyword not listed as soft below is reserved. `try` is
reserved only so that the removed `try:` block can be diagnosed; it starts no
construct. `Self` and `void` are also accepted as type names
(`LP:1441-1453`).

**Soft keywords** may also be used as names. The intended soft keywords are:

```
after  concurrent  concurrently  on  sealed  with
```

`debug` and `select` are reserved (owner decision,
[section 6](#6-owner-decisions-of-2026-10-06)), so `debug:` and `select:`
always begin their blocks.

> **Current behaviour differs:** `debug` and `select` are soft keywords
> (`LP:1455-1479`): `debug = 1` and `select = 1` bind names. `debug: Int = 1`
> is a typed binding, `debug` followed by `.` reads the name `debug`, and
> `debug` anywhere else in an expression starts a `debug:` block, so a bound
> `debug` can never be read on its own (`LP:7728-7741`). *(pending language
> change)*

Soft keywords are names in these positions: a binding, parameter, lambda
parameter, `for` binder, pattern variable, record field (declared, written in
a literal, or accessed with `.`), function name, import symbol or module path
segment. Whether a soft keyword can be *read* as a value differs by keyword,
and whether the six above should stay soft is open: see
[D7](#d7-the-remaining-soft-keywords).

`from` is reserved, yet the old parser and the table path read `from`, `after`
and `sealed` in expression position as the names `from`, `after` and `sealed`
(`LP:7671-7715`, `BODY:1976-1985`); `on` and `concurrently` cannot be read as
values (`LP:7742`).

> **Recommended (D7):** reserve `with` and `concurrent` as well, and make
> `after`, `sealed`, `on`, `concurrently` and `from` contextual identifiers,
> keywords only in their one position each.

### 1.5 Numeric literals

```ebnf
INT   = digit { digit } ;
FLOAT = digit { digit } "." digit { digit } ;
```

A number is scanned greedily: digits, then at most one `.` that is directly
followed by a digit (`LEX:140-164`). There is no sign, exponent, digit
separator, or hexadecimal, octal or binary form. `1.` is the integer `1`
followed by `.`, and `.5` is `.` followed by `5`.

An integer literal's value must not exceed the largest `Int128`
(170141183460469231731687303715884105727); a larger literal is a lexical error
(`LEX:880-904`). Whether a literal fits the type it is given is a type rule:
literals above the `Int64` range are valid only where `UInt64` or a 128-bit
type is expected. A float literal must denote a finite IEEE 754 64-bit value;
otherwise it is a lexical error with a suggestion to write a smaller number
(`LEX:905-914`). Its decimal digits are kept for conversion to the width that
typechecking selects.

Because a number ends where its digits end, `0x10` is the integer `0` followed
by the identifier `x10`, and `1e5` is `1` followed by `e5`. Since no separator
is required between statements today, these are accepted as two statements
([D2](#d2-items-written-on-one-line)).

### 1.6 String literals

Every string literal is one token. There are seven kinds.

**Plain string** `"..."`: a double quote, then any characters except `"`, `\`,
a line feed, or a `${` hole opener, then a closing `"` (`STR:132-152`,
`STR:179-276`). Escapes:

```
\n  \t  \r  \\  \"  \'  \0  \{  \}  \u{X...}
```

where `\u{X...}` holds 1 to 6 hexadecimal digits naming a Unicode scalar
value (`CHR:54-147`; [1.8](#18-character-literals) gives the EBNF, `escape`).
Any other escape is an error. A line feed before the closing quote is an
error: a quoted string lies on one line.

**Interpolated string** `"...${expr}..."`: a quoted string containing at least
one hole `${ ... }`. Outside holes, `{` and `}` are literal text, and escapes
are as above. Holes are described in [1.7](#17-interpolation-holes).

**Raw string** `raw"..."`: the spelling `raw` immediately followed by `"`, then
any characters except `"` and line feed, then `"`. No escapes and no holes
(`STR:282-306`, `LEX:713-741`).

**Pipe string**: a run of lines, each starting with a `|` marker. A pipe string
begins at a `|` that is the first token of its line (`LEX:717`), the *margin
marker*; its column is the string's margin. A line's content is everything
after its marker up to the line feed, verbatim: there are no escapes. The
string continues onto the next line when that line's indentation width is
exactly the margin column minus one and its first non-blank character is `|`
(`STR:360-415`). A marker written `||` contributes a literal `|` as the first
content character. Lines are joined with a line feed. The token includes the
line feed that ends its last line, and [section 2](#2-the-layout-algorithm)
treats that as the end of the line.

**Interpolated pipe string**: a pipe string whose content contains a `${`
hole. Holes are as in quoted strings, and a `{` or `}` outside a hole is
literal text.

**Raw pipe string**: the spelling `raw`, then only blanks to the end of its
line, then a line whose first non-blank character is `|`. That `|` is the
margin marker; the block continues as a pipe string's does, with no holes and
no `||` escape (`STR:418-435`). The token runs from `raw` to the end of the
block. Anywhere else `raw` is an ordinary identifier.

Owner decision: a `|` starts a pipe string only after `=`, so that a `|` at
the start of a line inside braces is a record-update bar:

```blorp
updated = { config
    | retries = 3 }        -- the `|` is a record-update bar
```

Read literally, the decision also excludes pipe strings that follow something
other than `=` today (a function body, a call argument, a pattern). Which
positions count as "after `=`" is open
([D8](#d8-where-a-pipe-string-may-start)), so the exact lexical rule waits on
that answer. Until then the rule stated above, a `|` that is the first token
of its line, stands.

> **Current behaviour differs:** the example above lexes `| retries = 3 }` as a
> pipe string (`LEX:717`) and fails with ``expected `}` after vector literal``.
> *(pending language change)*

> **Recommended (D8):** a line-start `|` starts a pipe string unless its line
> break is insignificant (inside brackets, L2 case 1) and the token before it
> can end an operand (a name, a literal, `)`, `]` or `}`); then it is an
> operator bar.

**Docstring**: a fence line, then text lines, then a closing fence line. A
fence is `---` followed by nothing but blanks to the end of its line
(`STR:48-49`). The opening fence may begin where any token may begin; the
closing fence must start at column 1 (`STR:81-118`). The token's text is the
lines between the fences, joined with line feeds, and the token includes the
closing fence's line feed. `----` and `--- x` are comments, not fences.

### 1.7 Interpolation holes

A hole starts at `${` inside an interpolated string and ends at the matching
`}`. Its text is scanned to find that `}` (`HOLE:175-266`):

- a `{` opens a brace and a `}` closes one; the hole ends when its own opening
  brace closes;
- a string literal inside the hole is opaque: braces and quotes inside it open
  and close nothing, except that a `${` inside it opens a further hole;
- a character literal inside the hole is opaque;
- a `\` skips the byte after it;
- a line feed inside a hole is an error: a hole lies on one line;
- at most `MAX_INTERPOLATION_DEPTH` = 64 braces and holes may be open at once
  (`LIM:6-9`); one more is an error.

> **Recommended (D12):** drop this lexical limit and count braces inside a
> hole toward `MAX_SYNTAX_NESTING` ([5.4](#54-nesting-limit)).

The hole's text is then lexed on its own, as one line, and must form exactly
one expression ([5.5](#55-interpolation-hole-contents)).

Owner decision: an interpolated string may not appear inside a hole. A plain
string, raw string or character literal may.

> **Current behaviour differs:** holes nest to any depth within the 64-brace
> limit, so `"outer ${"inner ${name}"}"` is accepted, and the Guide documents
> it. *(pending language change)*

### 1.8 Character literals

```ebnf
CHAR      = "'" ( character | escape ) "'" ;   (* character: any scalar but ', \ and line feed *)
escape    = "\" ( "n" | "t" | "r" | "\" | '"' | "'" | "0" | "{" | "}" )
          | "\u{" hex_digit [ hex_digit [ hex_digit [ hex_digit [ hex_digit [ hex_digit ] ] ] ] ] "}" ;
hex_digit = digit | "a".."f" | "A".."F" ;
```

A character literal holds exactly one Unicode scalar value, written directly
or as one of the escapes of [1.6](#16-string-literals) (`CHR:174-267`). `'ab'`
and `''` are errors.

### 1.9 Dimension names

```ebnf
DIMNAME = "#" IDENT ;     (* no blank between `#` and the name *)
```

A `#` immediately followed by an identifier that is not a keyword and not a
lone `_` is one `DIMNAME` token (`LEX:497-509`, `LEX:837-856`). Otherwise `#`
is the `"#"` token, as in `#3`, `#_` and `#(`.

> **Current behaviour differs:** the old lexer emits `#` and the name as two
> tokens, and the old parser accepts blanks between them (`Int[# N]`); the
> discovery stage rejects `# N` with ``expected dimension name or literal
> after `#` ``. The discovery stage's rule is the intended one.

### 1.10 Symbols

Symbols are matched longest first (`LEX:218-427`):

```
(   )   [   ]   {   }   ,   :   .   ..   ...   _   @   #   |   %
+   -   *   /   =   ==  !=  <   <=  >   >=  ->  =>  +=  -=  *=  /=  ?=
```

`!` and `?` are valid only in `!=` and `?=`. `;`, `&`, `^`, `~`, a `$` outside
a string, a backquote and `\` are unexpected characters.

### 1.11 Token kinds

Besides keywords and symbols, the lexer produces:

```
IDENT  DIMNAME  INT  FLOAT  CHAR  DOCSTRING
STRING  ISTRING  RAW_STRING  PIPE_STRING  IPIPE_STRING  RAW_PIPE_STRING
NEWLINE  INDENT  DEDENT  EOF
```

`ISTRING` is an interpolated quoted string and `IPIPE_STRING` an interpolated
pipe string. The layout tokens are the subject of the next section.

## 2. The layout algorithm

Blorp is indentation-sensitive. The lexer turns line structure into three
tokens: `NEWLINE` separates two lines at the same indentation, `INDENT` opens a
deeper level, and `DEDENT` closes one. The algorithm below is normative. It is
how both lexers behave: `LEX:596-968` with `LAY:113-393`, and `OLX:2044-2250`,
which agree token for token.

### 2.1 Definitions

- A **content line** is a line whose first non-blank character is neither a
  line feed nor the end of the input. A comment-only line *is* a content
  line. A **blank line** holds only blanks.
- The **indentation** of a line is the tab-expanded width of its leading
  blanks ([1.1](#11-source-text)).
- The **bracket depth** is the number of `(`, `[` and `{` tokens seen minus the
  number of `)`, `]` and `}` tokens seen, never below zero. Brackets inside
  strings, characters and comments do not count.
- A **bracketed block** is a block opened inside brackets: one whose `:` is the
  last token on its line while the bracket depth is above zero. Its *group*
  is the bracket depth where it opened and its *base* is the indentation level
  that was innermost when it opened.

### 2.2 State

| State | Initial value | Meaning |
| --- | --- | --- |
| `levels` | `[0]` | stack of open indentation levels; the innermost is `top(levels)` |
| `bodies` | `[]` | stack of open bracketed blocks, each a `(group, base)` pair |
| `depth` | `0` | bracket depth |
| `pending` | false | a line ended that owes a `NEWLINE` |
| `prev` | none | the kind of the last token emitted |
| `has_token` | false | the current line has emitted a token |

Two predicates decide whether a line break inside brackets matters
(`LAY:113-133`):

```
insignificant(depth) = depth > 0 and (bodies is empty or depth ≠ top(bodies).group)

opens_block(depth)   = depth > 0 and prev = ":"
                       and (bodies is empty or depth > top(bodies).group)
```

### 2.3 The algorithm

The lexer scans the source once. Steps L1 and L2 handle line structure. Every
other character is scanned into tokens as section 1 describes; each token sets
`prev` to its kind and `has_token` to true, and each bracket symbol updates
`depth`. Comments emit nothing and change neither `prev` nor `has_token`.

**L1. At a line feed** that is not inside a token (`LEX:684-696`):

```
if opens_block(depth):
    push (depth, top(levels)) on bodies          -- a bracketed block opens
    pending := true
else if insignificant(depth):
    pending := false
else:
    pending := pending or has_token
has_token := false
continue at L2 with the next line
```

**L2. At the start of a line** with indentation `w` (`LAY:325-370`):

```
1. if insignificant(depth):
       emit nothing
2. else if the line is blank:
       emit nothing; leave pending unchanged; stop
3. else if bodies is non-empty and depth = top(bodies).group
        and top(bodies).base < w < top(levels)
        and w lies strictly between two adjacent levels:
       DEDENT-TO(top(bodies).base)            -- the line closes a bracketed block
4. else if w > top(levels):
       if pending: emit NEWLINE
       emit INDENT; push w on levels
5. else if w = top(levels):
       if pending: emit NEWLINE
6. else:
       DEDENT-TO(w)
pending := false
```

```
DEDENT-TO(t):                                 (LAY:286-313, LAY:378-393)
    while top(levels) > t: pop levels; emit DEDENT
    if top(levels) ≠ t:
        report "inconsistent indentation"     -- t matches no enclosing level
    else:
        pop every entry of bodies whose base ≥ t   -- those blocks are closed
```

A dedent emits no `NEWLINE`, before or after its `DEDENT` tokens.

**L3. Tokens that end a line themselves.** A pipe string or raw pipe string
consumes the line feed that ends its last line; afterwards `pending := true`,
`has_token := false`, and scanning continues at L2 for the next line
(`LEX:777-780`). A docstring consumes the line feed after its closing fence;
afterwards `pending := false`, `has_token := false`, and scanning continues at
L2 (`LEX:770-773`).

**L4. At the end of the input:** emit one `DEDENT` for every level above 0,
then `EOF` (`LEX:949-961`). No `NEWLINE` is emitted for a pending line end.

### 2.4 Consequences and quirks

These follow from the algorithm, and the grammar relies on them.

1. **`NEWLINE` appears only between two lines at the same level, or before an
   `INDENT`.** It never follows a `DEDENT`, and it precedes one only when a
   comment-only line at the closing level produced it (consequence 6). So
   `if c:` / `    a` / `b` is `if c : NEWLINE INDENT a DEDENT b`, and the
   statement after a block follows the block's `DEDENT` directly.
2. **`INDENT` is emitted for any deeper line**, not only after a `:`. A deeper
   line that does not follow a block header is a syntax error, except where a
   position rule of section 4 consumes the `INDENT` (a method chain, a value on
   the next line). For example, `x = 1` followed by a more-indented `y = 2`
   reports ``expected declaration`` where the function ends.
3. **Blank lines are invisible.** They emit nothing and leave `pending`
   unchanged, so blank lines may appear anywhere, including between an `if`
   block and its `else`.
4. **Inside brackets, line breaks are insignificant**, as in CPython's implicit
   line joining, *unless* a bracketed block is open at the current depth.
   Lines inside further brackets nested within a bracketed block are
   insignificant again.
5. **A bracketed block's lines are laid out like any block.** Its first line
   is normally deeper than the base and gets an `INDENT`. The block ends at a
   line indented at or below the base (L2 case 6), or at a line indented
   between the base and the block's own level (L2 case 3). A closing bracket
   does not close a bracketed block: the block's `DEDENT` is emitted only at
   the start of a later line, so `xs.map(func(x):` / `    x + 1)` produces
   `... INDENT x + 1 ) ... DEDENT`, with the `)` inside the block (see
   [4.9](#49-closing-bracket-on-a-blocks-last-line)).
6. **A comment-only line is a content line.** It takes part in L2 like any
   other line: at the current level it emits the pending `NEWLINE`; at a
   shallower indentation it emits `DEDENT`s and closes blocks; at a deeper one
   it emits `INDENT` and pushes a level, which the next line closes with a
   `DEDENT`. The common case is commented-out code at column 1 inside a
   function. It closes the function, and the next line's `INDENT` then opens
   nothing:

   ```blorp
   func f() -> Int:
       x = 1
   -- disabled: x = 2
       x
   ```

   Both parsers report ``expected declaration`` at the last line. A comment
   indented deeper than the code around it fails the same way:

   ```blorp
   func f() -> Int:
       x = 1
           -- this comment opens an indentation level
       x
   ```

   > **Recommended (D1):** treat a comment-only line as a blank line in L2,
   > so it emits nothing and leaves `pending` unchanged.
7. **Inconsistent indentation.** A dedent to a width that matches no enclosing
   level is reported as ``inconsistent indentation``, with the help to indent
   every line of a block by the same amount and to dedent only to the
   indentation of an enclosing block, a tab counting as 4 columns.

### 2.5 Examples

Each example shows the source, then its tokens.

A function, an `if` statement, and a dedent by two levels:

```blorp
func f(c: Bool) -> Int:
    if c:
        1
    else:
        2
```

```
func f ( c : Bool ) -> Int : NEWLINE INDENT
if c : NEWLINE INDENT 1 DEDENT
else : NEWLINE INDENT 2 DEDENT DEDENT EOF
```

A block lambda inside a call, with the closing bracket on its own line at the
base indentation:

```blorp
    ys = xs.map(func(x):
        y = x + 1
        y
    )
```

```
ys = xs . map ( func ( x ) : NEWLINE INDENT
y = x + 1 NEWLINE
y DEDENT ) ...
```

A value on the next line that is a pipe string, which ends its own line:

```blorp
    text =
        |first
        |second
    print(text)
```

```
text = NEWLINE INDENT PIPE_STRING DEDENT print ( text ) ...
```

## 3. Context-free grammar

### 3.1 Terminals and item sequences

The grammar's terminals are the tokens of section 1 and the layout tokens of
section 2. Keywords and symbols are written in quotes.

Many constructs are sequences of items on successive lines: the statements of
a block, the cases of a `match`, a module's declarations. An item that ends
with a block ends with that block's `DEDENT`, after which the layout algorithm
emits no `NEWLINE` (consequence 1). So:

```ebnf
seq(x) = x { [ NEWLINE ] x } ;
block  = INDENT seq(statement) [ NEWLINE ] DEDENT ;
```

No separator is required between items: each item loop parses an item and
continues while the next token can start another (`LP:4588-4621` and
`BODY:538-571` for statements; the `match` case, union variant and top-level
declaration loops behave the same way). So `x = 1 y = 2`,
`print("a") print("b")`, `1: 2 3: 4` in a `match`, `A B(Int)` in a `union`
and two globals on one line are all accepted. The optional `NEWLINE` before
`DEDENT` is the one a comment-only line can produce (consequence 6).

> **Recommended (D2):** require a separator:
>
> ```ebnf
> seq(x)    = x { separator x } ;
> separator = NEWLINE
>           | (* nothing, when the item before it ends with DEDENT *) ;
> ```

### 3.2 Modules

```ebnf
module     = [ module_doc ] [ seq(top_item) ] [ NEWLINE ] EOF ;
module_doc = DOCSTRING ;                      (* followed by an import_block *)
top_item   = import_block | foreign_block | declaration ;
```

A module docstring must be the file's first token and must be followed by an
`import:` block (`LP:10857-10893`). A docstring before any later import block
is rejected with ``a docstring cannot document an import block``
(`LP:10764-10778`). Elsewhere a docstring documents the declaration after it.

### 3.3 Declarations

```ebnf
declaration = [ DOCSTRING ] [ "private" ] declaration_body ;

declaration_body = function_decl
                 | global_decl
                 | record_decl
                 | union_decl
                 | alias_decl
                 | builtin_type_decl
                 | trait_decl
                 | impl_decl ;
```

Declarations are public unless marked `private`; there is no `export`.
`private` does not apply to `import` or `foreign` blocks. The old parser also
accepts annotations and `pure` written before `private` (`LP:10729-10763`).

#### Functions

```ebnf
function_decl   = { annotation } [ "pure" ] "func" name [ type_params ] params
                  [ "->" type ] [ where_clause ] ":" function_body ;

annotation      = "@" annotation_name [ NEWLINE ] ;
annotation_name = IDENT ;   (* tail_recursive, debug_only, no_copy or resource_result_ordinary *)

function_body   = NEWLINE block                   (* block body *)
                | expression                      (* same-line body *)
                | (* nothing *) ;                 (* forward declaration *)

where_clause    = "where" dim_constraint { "," dim_constraint } ;
dim_constraint  = dim_expr "==" dim_expr ;
```

- An annotation takes no arguments: `@name(...)` is rejected with ``function
  annotations do not take arguments``. An unknown name is rejected with the
  list of the four names (`LP:1206-1310`). Annotations must be followed by a
  function (`LP:10751-10760`).
- A same-line body is one expression, not a statement, and must start on the
  line of the `:` (`LP:8289-8336`). A block inside it is laid out by
  [4.6](#46-blocks-inside-same-line-bodies).
- A **forward declaration** is a top-level header whose `:` is followed by the
  end of its line with no indented block, or by `DEDENT` or `EOF`. It is valid
  only when the module also has a top-level function of the same name with a
  body (`LP:8426-8458`). Otherwise, and for any local function, implementation
  method, or trait method written with a `:`, a missing body is ``function has
  no body``. A header that ends with neither `:` nor a body is ``expected `:`
  before function body``.
- A function marked `@debug_only` may be called only inside `debug:` blocks,
  in `--debug` builds, or under `blorp test`; that is checked after parsing.

#### Type parameters and parameters

```ebnf
type_params  = "[" [ type_param { "," type_param } [ "," ] ] "]" ;
type_param   = IDENT [ ":" bounds ]           (* T, or T: Equatable + Orderable *)
             | DIMNAME                        (* #N *)
             | "#" "_" ;                      (* #_ *)
bounds       = trait_ref { "+" trait_ref } ;
trait_ref    = IDENT [ "." IDENT ] ;          (* Trait, or alias.Trait *)

params       = "(" [ param { "," param } [ "," ] ] ")" ;
param        = binder_name [ ":" type ]
             | tuple_binder [ ":" type ] ;
tuple_binder = "(" binder_name "," binder_name [ "," binder_name [ "," binder_name ] ]
               [ "," ] ")" ;
binder_name  = name | "_" ;
```

A type parameter's name starts with a capital ASCII letter and contains only
ASCII letters and digits (`T`, `Elem`, `Item2`); a dimension parameter follows
the same rule after `#`. A dimension parameter takes no bounds: `#N: Equatable`
is an error. A capitalized type name that is neither declared in a
`type_params` list (or an `implements` receiver) nor a defined type is an
error that suggests declaring it.

#### Globals

```ebnf
global_decl = "var" name [ ":" type ] "=" value
            | IDENT [ ":" type ] "=" value ;
```

An immutable global starts with an identifier; a `var` global may use any
name. Immutable globals are compile-time constants: calls in their
initializers must be pure and evaluable at compile time. `var` initializers
cannot call functions, methods or closures. Subscripts in global initializers
are accepted only where the checker can lower them without runtime helper
work. These rules are checked after parsing.

> **Current behaviour differs:** the old parser rejects an immutable global
> whose name is a soft keyword (`after: Int = 1` reports ``expected
> declaration``, `LP:10811-10822`), while the discovery stage accepts it.
> [D7](#d7-the-remaining-soft-keywords) decides which is intended.

#### Records and unions

```ebnf
record_decl  = [ "fixed" ] "record" IDENT [ type_params ]
               "{" [ field_decl { "," field_decl } [ "," ] ] "}" ;
field_decl   = name ":" type ;

union_decl   = [ "fixed" ] "union" IDENT [ type_params ] ":" NEWLINE
               INDENT seq(variant) [ NEWLINE ] DEDENT ;
variant      = variant_name [ "(" [ type { "," type } [ "," ] ] ")" ] ;
variant_name = IDENT | "True" | "False" ;

```

`fixed` is the identifier `fixed` directly before `record` or `union`. Both
record spellings, and both union spellings, have the same value semantics.
Layout is not part of the grammar: the compiler stores a `fixed record` of
numbers, `Char` values and other such records inline, and every other record
managed (GUIDE, "Fixed Records"). A record's field names are distinct. A
variant declares at most `MAX_UNION_VARIANT_FIELDS` = 64 payload fields
(`LIM:11-15`). A union variant may have empty parentheses. `enum` is not a
declaration form. `fixed union` is currently a temporary synonym for `union`,
not a checked payload, no-boxing or allocation guarantee.

#### Aliases and builtin types

```ebnf
alias_decl        = "type" "alias" IDENT [ type_params ] "=" type
                  | "opaque" "type" IDENT [ type_params ] "=" type ;

builtin_type_decl = "type" IDENT [ type_params ] "=" "builtin"
                  | "resource" "type" IDENT [ type_params ] "=" "builtin"
                    [ "(" STRING ")" ] ;
```

Builtin type declarations are accepted only in the standard library.

#### Traits and implementations

```ebnf
trait_decl   = "trait" IDENT [ type_params ] ":" trait_tail ;
trait_tail   = NEWLINE INDENT seq(trait_method) [ NEWLINE ] DEDENT
             | bounds                                         (* supertraits only *)
             | bounds ":" NEWLINE INDENT seq(trait_method) [ NEWLINE ] DEDENT ;
trait_method = [ "pure" ] "func" name params [ "->" type ] [ ":" function_body ] ;

impl_decl    = "implements" IDENT "for" receiver_type ":" NEWLINE
               INDENT seq(impl_method) [ NEWLINE ] DEDENT ;
impl_method  = { annotation } [ "pure" ] "func" name [ type_params ] params
               [ "->" type ] [ where_clause ] ":" function_body ;
receiver_type = type ;
```

A trait method without a `:` is abstract; one with a `:` has a default body.
An implementation method must have a body. `receiver_type` is a type whose
arguments may introduce the implementation's type parameters, bare or bounded
(`Labeled[T: Stringable]`); it is the only type in which a bound may be
written. An implementation method may add type parameters but may not
redeclare one of the receiver's.

#### Imports

```ebnf
import_block       = "import" ":" NEWLINE INDENT seq(import_item) [ NEWLINE ] DEDENT ;
import_item        = module_path [ "as" name ] [ ":" import_symbols ] ;
import_symbols     = import_symbol_line
                   | NEWLINE INDENT seq(import_symbol_line) [ NEWLINE ] DEDENT ;
import_symbol_line = import_symbol { "," import_symbol } [ "," ] ;
import_symbol      = name [ "(" name { "," name } [ "," ] ")" ] [ "as" name ] ;

module_path        = [ "." "/" | { ".." "/" } ] name { "/" name } ;
```

`./` may only begin a path, and `../` may only repeat at its start; a `.` or
`..` segment later in a path is an error with a rewriting hint
(`LP:8800-8923`). Each module appears at most once per file, and there are no
brace or wildcard imports. A module alias must not reuse a visible declaration
name, and a selected symbol's local name must be unique in the file. These are
checked after parsing.

#### Foreign functions

```ebnf
foreign_block = "foreign" [ "(" foreign_arg { "," foreign_arg } ")" ] ":" NEWLINE
                INDENT seq(foreign_item) [ NEWLINE ] DEDENT ;
foreign_arg   = IDENT ":" STRING ;
foreign_item  = [ "private" ] { "@" annotation_name } [ "pure" ] "func" name params
                "->" type [ "=" STRING ] ;
```

`include:` names a C header, resolved from the declaring file. `link:`,
`link_linux:` and `link_macos:` accept only `-lNAME`, `-LDIR`, `-IDIR`,
`-framework NAME` and `-pthread`. New explicit `foreign` declarations do not
belong in `standard_library/src/`.

#### Names

```ebnf
name         = IDENT | soft_keyword ;
soft_keyword = "after" | "concurrent" | "concurrently" | "on" | "sealed" | "with" ;
```

> **Current behaviour differs:** `soft_keyword` also includes `"debug"` and
> `"select"`. *(pending language change)*

### 3.4 Statements

```ebnf
statement = local_function
          | var_decl
          | binding
          | question_binding
          | compound_assignment
          | discard
          | destructuring
          | subscript_assignment
          | while_stmt
          | for_stmt
          | detach_stmt
          | expression ;

local_function      = [ "pure" ] "func" name [ type_params ] params [ "->" type ]
                      [ where_clause ] ":" function_body ;
var_decl            = "var" name [ ":" type ] "=" value ;
binding             = name [ ":" type ] "=" value ;
question_binding    = name [ ":" type ] "?=" value ;
compound_assignment = name ( "+=" | "-=" | "*=" | "/=" ) value ;
discard             = "_" "=" value ;
destructuring       = "(" binder_name "," binder_name [ "," binder_name [ "," binder_name ] ]
                      [ "," ] ")" "=" value ;
subscript_assignment = place "=" value ;
place               = name subscript { subscript } ;
subscript           = "[" expr_list "]" ;

value = NEWLINE INDENT expression [ NEWLINE ] DEDENT     (* value on the next line, 4.3 *)
      | expression ;

while_stmt    = "while" expression ":" NEWLINE block ;
for_stmt      = "for" for_binder "in" expression ":" NEWLINE block
              | "for" binder_name "in" expression "concurrently" "(" concurrent_args ")" ":"
                NEWLINE block ;
for_binder    = binder_name | tuple_binder ;
detach_stmt   = "detach" expression ;
```

`select`, `break` and `continue` are expressions today
([3.6](#36-primary-expressions), [3.7](#37-control-expressions-and-blocks)),
so they appear here as expression statements.

> **Recommended (D9, D10):** make them statements, and remove `select_expr`
> from `control_expr` and `"break"` and `"continue"` from `primary`:
>
> ```ebnf
> statement     = ... | select_expr | break_stmt | continue_stmt | ... ;
> break_stmt    = "break" ;
> continue_stmt = "continue" ;
> ```

A statement that begins with `func` (or `pure func`) is a local function when
the next token is not `(`, and a lambda expression statement when it is
(`LP:6490-6507`). A statement that begins with a name followed by `=`, `?=`, a
compound operator, or a `:` whose type is followed by `=` or `?=` on the same
line, is a binding form (`LP:3518-3588`, `LP:6684-6749`); otherwise it is an
expression statement.

A `binding` declares a new immutable name or, when the name is a `var` in
scope, reassigns it; resolution decides which. `x: T = v` always declares an
immutable name, and a destructuring always declares its names. The placement
rules for `break`, `continue` and `?=`, and the full rules for assignable
places, are in [section 5](#5-static-syntactic-restrictions).

`while`, `for` and `for ... concurrently` are statements and have no value. A
`for` where a value is required is ``for` is a statement and has no value``,
with a hint to use `map` (`LP:6115-6134`).

> **Current behaviour differs:**
> - `place` is any postfix expression ending in a subscript, so
>   `xs.f()[0] = v` and `box.items[0] = v` parse and are rejected only by the
>   typechecker (`LP:6548-6617`). *(pending language change)*
> - `detach` is a prefix operator usable in any expression (`1 + detach f()`,
>   `x = detach f()`), binding like unary minus (`LP:8038-8053`,
>   `BODY:1746-1767`). *(pending language change)*

### 3.5 Expressions

```ebnf
expression     = or_expr ;
or_expr        = and_expr { "or" [ NEWLINE ] and_expr } ;
and_expr       = not_expr { "and" [ NEWLINE ] not_expr } ;
not_expr       = "not" not_expr
               | comparison ;
comparison     = range_expr [ compare_op [ NEWLINE ] range_expr ] ;
compare_op     = "==" | "!=" | "<" | ">" | "<=" | ">=" ;
range_expr     = additive [ ".." [ NEWLINE ] additive ] ;
additive       = multiplicative { ( "+" | "-" ) [ NEWLINE ] multiplicative } ;
multiplicative = unary { ( "*" | "/" | "%" ) [ NEWLINE ] unary } ;
unary          = "-" unary
               | control_expr
               | postfix_expr ;
postfix_expr   = primary { postfix_op } [ indented_chain ] ;   (* indented_chain: 4.2 *)
postfix_op     = "." field_name
               | NEWLINE "." field_name             (* leading dot, 4.2 *)
               | "(" [ expr_list ] ")"
               | "[" expr_list "]" ;
field_name     = name ;
expr_list      = expression { "," expression } [ "," ] ;
```

The optional `NEWLINE` after a binary operator is
[the operator-then-newline rule](#44-operator-then-newline): the operand may
start on the next line only at the same indentation. A prefix operator takes
no line break after it.

`as` after an expression is rejected with ``type ascription with `as` was
removed`` and the help to annotate the binding instead (`LP:8110-8135`).

#### Precedence and associativity

From lowest to highest:

| Level | Operators | Associativity |
| --- | --- | --- |
| 1 | `or` | left |
| 2 | `and` | left |
| 3 | `not` | prefix |
| 4 | `==` `!=` `<` `>` `<=` `>=` | none |
| 5 | `..` | none |
| 6 | `+` `-` | left |
| 7 | `*` `/` `%` | left |
| 8 | `-` (negation) | prefix |
| 9 | `.` field, `( )` call, `[ ]` subscript | postfix, left |

Assignment and `?=` are statements, not operators
([5.1](#51-assignment-is-a-statement)).

- **`not` binds below comparisons**, as in Python: `not a == b` means
  `not (a == b)`, and `not a and b` means `(not a) and b`. A `not` cannot be
  the operand of a comparison, range or arithmetic operator without
  parentheses: `a == not b` and `1 + not b` are syntax errors.
- **Comparisons do not chain.** `a < b < c`, `a == b == c` and `a < b > c` are
  syntax errors whose message suggests `a < b and b < c`. Parentheses make a
  nested comparison explicit: `(a < b) == c`.
- **`..` does not chain.** `a..b..c` is a syntax error with a teaching
  message. `(a..b)..c` is grammatical and rejected by the typechecker. The
  range *type* `..#N` ([3.8](#38-types-and-dimensions)) is a different
  construct and is unaffected.
- Negation applies to a postfix expression: `-x.f()` is `-(x.f())`, `- 2 * 3`
  is `(-2) * 3`, and `2 - -1` is `2 - (-1)`.

> **Current behaviour differs** *(pending language change)*:
> - `not` is a prefix operator at level 8, with negation, so `not a == b`
>   parses as `(not a) == b`, and `a == not b` parses (`LP:8021-8037`,
>   `BODY:1746-1767`).
> - Comparisons are one left-associative level: `a < b < c` parses as
>   `(a < b) < c` and fails only in typechecking (`LP:8138-8158`).
> - `..` is left-associative: `a..b..c` parses as `(a..b)..c` and fails in
>   typechecking with ``Range start must be Int``.
> - `detach` is a prefix operator at level 8 (see 3.4).

### 3.6 Primary expressions

```ebnf
primary = IDENT
        | INT | FLOAT | CHAR
        | STRING | ISTRING | RAW_STRING | PIPE_STRING | IPIPE_STRING | RAW_PIPE_STRING
        | "True" | "False" | "void"
        | "_"                                           (* the Void value; D11 *)
        | "break" | "continue"                          (* D10 *)
        | "after" | "sealed" | "from"                   (* read as names; D7 *)
        | "(" ")"                                       (* the Void value *)
        | "(" expression ")"                            (* grouping *)
        | "(" expression "," expression [ "," expression [ "," expression ] ] [ "," ] ")"
                                                        (* tuple, 2 to 4 elements *)
        | "[" [ expr_list ] "]"                         (* list *)
        | braced
        | "builtin" [ "(" STRING ")" ]                  (* standard library bodies *)
        | "into_opaque" conversion_type "(" expression ")"
        | "from_opaque" conversion_type "(" expression ")"
        | with_expr
        | debug_block
        | concurrent_block ;

conversion_type = IDENT [ "." IDENT ] [ "[" type_args "]" ] ;

braced = "{" "}"                                                        (* empty Dict *)
       | "{" field_init { "," field_init } [ "," ] "}"                  (* record *)
       | "{" expression "|" field_init { "," field_init } [ "," ] "}"   (* record update *)
       | "{" dict_entry { "," dict_entry } [ "," ] "}"                  (* Dict *)
       | "{" expression { "," expression } [ "," ] "}" ;                (* vector *)
field_init = name "=" expression ;
dict_entry = expression "=>" expression ;
```

- A braced form is a record literal when the token after `{` is a name
  followed by `=`. Otherwise its first expression is read, and the token after
  it decides: `=>` a Dict, `|` a record update, anything else a vector
  (`LP:7413-7454`). A record literal or update gives each field once
  (``duplicate field `x` ``, `LP:7113-7140`). A record field's `=` is part of
  the literal, not an assignment.
- The field expressions of a record literal are evaluated in the order they
  are written, and each value is stored in its declared field. A record update
  evaluates its base once, then its replacements in written order, before any
  field write. Omitted fields inherit the original base value.
- `(x,)` is ``a tuple has two to four elements, and `(x,)` has one``; more
  than four elements is ``Tuples support 2-4 elements`` (`LP:6900-6973`).
- `t.0` is not tuple access, since a field name must be a name; write `t[0]`.
- `_` is the Void value, the same as `void` (`LP:7790-7795`, `BODY:1974`).
  `break` and `continue` are expressions whose placement 5.3 restricts.
  `after`, `sealed` and `from` are read as the names `after`, `sealed` and
  `from` (`LP:7671-7715`, `BODY:1976-1985`).
- Owner decision: **`{}` is always an empty Dict.** `{` `}` is the first
  `braced` alternative.

> **Current behaviour differs:** `{}` is parsed as an empty record literal
> (`LP:7419-7426`), and the typechecker gives it the expected type: an empty
> `Dict` where a `Dict` is expected, an empty `Set` where a `Set` is, and
> otherwise ``Cannot infer record type without annotation``. The decision
> keeps the about 273 production sites that write an empty Dict this way, and
> breaks those that write an empty Set: `standard_library/src/set.brp:232`
> (and its generated copy in `embedded_std.brp`),
> `DISC/tables/invariants/spans_and_names.brp:540` and
> `DISC/parse/tree_module_assembly.brp:196`, plus 18 in tests. They need
> migrating to `set()`; the comment at `set.brp:229-231` says the pinned
> bootstrap compiler cannot infer `set()` there, so that site waits for a
> bootstrap rotation. *(pending language change)*

> **Current behaviour differs:** `debug` followed by `.` is read as the name
> `debug` (`LP:7728-7741`); with `debug` reserved it is an error. *(pending
> language change)*

> **Recommended (D7, D11):** drop the `"_"` alternative, and lex `after`,
> `sealed` and `from` as identifiers recognized as keywords only in their own
> positions, so that they are `IDENT` here.

### 3.7 Control expressions and blocks

```ebnf
control_expr = if_expr | match_expr | select_expr | lambda ;   (* select_expr: D9 *)

if_expr     = "if" expression ":" NEWLINE block [ else_branch ] ;
else_branch = "else" ":" NEWLINE block
            | "else" if_expr ;

match_expr  = "match" expression ":" NEWLINE INDENT seq(match_case) [ NEWLINE ] DEDENT ;
match_case  = pattern ":" case_body ;
case_body   = NEWLINE block
            | if_expr | match_expr                 (* anchored at the pattern, 4.8 *)
            | statement ;                          (* same-line statement *)

select_expr = "select" ":" NEWLINE INDENT seq(select_arm) [ NEWLINE ] DEDENT ;
select_arm  = binder_name "from" expression ":" NEWLINE block
            | "sealed" expression ":" NEWLINE block
            | "_" "after" expression ":" NEWLINE block ;

with_expr   = "with" binder_name [ ":" type ] "=" expression ":" NEWLINE block
            | "with" binder_name [ ":" type ] "?=" expression
              [ "on" binder_name "=>" expression ] ":" NEWLINE block ;
debug_block = "debug" ":" NEWLINE block ;
concurrent_block = "concurrent" [ "(" concurrent_args ")" ] ":" NEWLINE block ;
concurrent_args  = concurrent_arg { "," concurrent_arg } ;
concurrent_arg   = name ":" expression ;

lambda       = [ "pure" ] "func" "(" [ lambda_param { "," lambda_param } [ "," ] ] ")"
               [ "->" type ] ":" lambda_body ;
lambda_param = binder_name [ ":" type ] ;
lambda_body  = NEWLINE block              (* a bracketed block when inside brackets *)
             | expression ;               (* same-line body *)
```

- `else` follows the `DEDENT` that ends the `if` block; blank lines and comment
  lines between them are allowed. There is no single-line `if`: a block always
  follows its header's `:` on a new line, so `if c: 1`, `else: 2` and
  `while c: f()` are ``expected newline before indented block``. Only a
  `match` case may put its body on the case's line.
- A block opened inside an expression (the block of an `if` or `match` used as
  a value, a block lambda) must also satisfy the
  [bracketed-block anchor](#41-the-bracketed-block-anchor). The `with`,
  `debug` and `concurrent` blocks are measured from their keyword
  ([4.7](#47-with-debug-and-concurrent-blocks-used-as-values)).
- `concurrent_args` accepts `max_threads` and `timeout`; `for ... concurrently`
  requires `limit` and accepts `limit` and `timeout`. `max_threads` and
  `limit` are positive integer literals that fit in `Int`; `0`, negative
  numbers, larger literals and other expressions are errors. Each name
  appears at most once. `for ... concurrently` takes a single name as its
  binder. These are parser rules (`LP:5442-5764`).
- `with` takes exactly one binding; a second one is rejected with the help to
  nest `with` blocks (`LP:5319-5378`).
- `select` may be a binding's value today, and both the parser and the
  typechecker accept `x = select: ...`, although the Guide says `select` is
  statement-only; see [D9](#d9-select-as-a-value). A `debug:` block evaluates
  to `Void`; normal builds erase its body after Core lowering, and
  `--debug` builds and `blorp test` keep it.

#### Control expressions as operands

An `if`, `match`, `select` or lambda may be an operand (`1 + if c: ...`). It
ends at its last block's `DEDENT`, or, for a lambda with a same-line body, at
the end of that body's expression.

When the control expression was read inside the operator loop, as an
expression statement or as an operand, a binary operator, `as` or `=` written
on the line after its `DEDENT` continues the expression
([4.5](#45-operator-after-a-block)). So

```blorp
    if c:
        print("a")
    - 3
```

parses as `(if c: print("a")) - 3`, and in `x = 1 + if c: ...` a following
line `+ 4` adds 4 to the whole sum. An `if` or `match` that is a binding's
whole value is not read inside the operator loop (`LP:3677-3698`), so there
the operator line is ``expected expression``.

> **Recommended (D3):** what follows the `DEDENT` that ends a control
> expression is always the next statement, so a line starting with `-` is a
> negation statement and a line starting with another binary operator is
> ``expected expression``.

### 3.8 Types and dimensions

```ebnf
type          = type_primary { array_suffix } ;

type_primary  = type_name [ "[" type_args "]" ]              (* Int, List[Int], Int[#3] *)
              | IDENT "." IDENT [ "[" type_args "]" ]         (* module.Type *)
              | "(" ")" [ "->" type ]                         (* Void, or () -> T *)
              | "(" type ")"                                  (* grouping *)
              | "(" type "," type [ "," type [ "," type ] ] [ "," ] ")"   (* tuple *)
              | "(" type { "," type } [ "," ] ")" "->" type   (* function *)
              | "pure" "(" [ type { "," type } [ "," ] ] ")" "->" type
              | ".." dim_atom                                 (* range type ..#N *)
              | dim_expr ;                                    (* a dimension argument *)
type_name     = IDENT | "Self" | "void" ;

type_args     = type_arg { "," type_arg } [ "," ] ;
type_arg      = type | variadic_dim | bounded_param ;
array_suffix  = "[" dim_arg { "," dim_arg } [ "," ] "]" ;
dim_arg       = dim_expr | variadic_dim ;
variadic_dim  = ( DIMNAME | "#" "_" ) "..." ;
bounded_param = IDENT ":" bounds ;            (* receiver_type arguments only *)

dim_expr      = dim_term { ( "+" | "-" ) dim_term } ;
dim_term      = dim_atom { ( "*" | "/" ) dim_atom } ;
dim_atom      = DIMNAME | "#" "_" | "#" INT | INT | "(" dim_expr ")" ;
```

- A `[ ... ]` after a type name whose arguments are all dimensions makes an
  array or tensor type (`Int[#3]`, `Float[#M, #N]`); otherwise it holds a
  generic type's arguments (`LP:2300-2445`). Each further `[ ... ]` suffix must
  hold dimensions (``expected array dimensions``).
- A parenthesized type list followed by `->` is a function type's
  parameters; without `->` it is a grouping (one type) or a tuple.
- `(T)` is `T`. `(T,)` is ``a tuple type has two to four elements, and `(T,)`
  has one``. A function type's return type extends as far as a type can, so
  `(A) -> (B) -> C` returns `(B) -> C`.
- A `(` that begins a dimension (`(#N + 1)`, `(2 * #N)`) is read as a
  dimension expression, not a type grouping (`LP:2682-2704`).
- `..` must be followed by a dimension atom: `..#N`, `..#5` or `..(#N - 1)`.
- `bounded_param` is accepted only inside an `implements` receiver. Anywhere
  else it is ``a bound cannot be written inside a type``, with the help to
  declare the parameter and its bounds in brackets (`LP:2336-2350`).
- `#Ds...` denotes caller-supplied concrete dimensions, not a dynamic length.

### 3.9 Patterns

```ebnf
pattern        = simple_pattern { "|" simple_pattern } ;          (* or-pattern *)

simple_pattern = "_"
               | binder_name                                     (* variable, or a bare constructor *)
               | IDENT "(" [ pattern_list ] ")"                   (* constructor *)
               | IDENT "." name [ "(" [ pattern_list ] ")" ]      (* qualified constructor *)
               | [ "-" ] INT | [ "-" ] FLOAT
               | STRING | RAW_STRING | PIPE_STRING | RAW_PIPE_STRING | CHAR
               | "True" | "False"
               | tuple_pattern
               | list_pattern ;

pattern_list   = pattern { "," pattern } [ "," ] ;
tuple_pattern  = "(" pattern "," pattern [ "," pattern [ "," pattern ] ] [ "," ] ")" ;
list_pattern   = "[" "]"
               | "[" "..." spread_target "]"
               | "[" pattern { "," pattern } [ "," "..." spread_target ] "]" ;
spread_target  = name | "_" ;
```

- Bare names resolve after parsing against the matched type and local scope.
  An unshadowed constructor available bare is a constructor pattern. A local
  shadowing name or a name unrelated to the matched type binds a variable.
  A matching constructor from another module that is not imported bare requires
  an import or module qualification, rather than becoming a variable binding.
- Or-pattern alternatives cannot introduce variable bindings, including
  payload, tuple, list-element, and named list-spread bindings. This rule also
  applies to nested or-patterns and is checked during typechecking. Wildcards,
  literals, and constructors with no bound payloads are valid. Bindings outside
  a nested or-pattern are unaffected. Use separate match arms to bind data.
- The `-` before a numeric literal may be separated from it by blanks (`- 2`).
- An interpolated string is not a pattern: ``a string with `${...}` holes
  cannot be a match pattern`` (`LP:4424-4440`).
- A list pattern takes no trailing comma; a tuple pattern may have one.
- A list pattern without a spread matches exactly its element count; with a
  spread it matches at least the fixed prefix.
- A pipe-string pattern ends its line, so the case's `:` cannot follow it on
  that line. Write it inside a constructor's parentheses: `Some(`, then a line
  `|text`, then a line `):`.

## 4. Position rules

The token stream carries most layout, but a few rules compare the line and
column of tokens. Each is named here, with its exact statement, the old
parser's evidence, and whether the token grammar can express it. The discovery
stage keeps these rules in `parse/layout_quirks.brp` (`QRK`) and the
continuation helpers of `parse/block_layout.brp` (`BLK`).

"Past an anchor" is defined once and used throughout:

> A token is **past** an anchor token when it starts on a later line than the
> anchor *and* in a later column (tab-expanded, [1.1](#11-source-text)), and it
> is not a `DEDENT` or `EOF` (`LP:4542-4552`, `BLK:33-40`, `QRK:67-73`).

### 4.1 The bracketed-block anchor

**Rule.** Every block is read with an anchor. Before its first statement, the
parser consumes the block's `INDENT`; failing that, it accepts a first token
that is past the anchor; failing that, it reports ``expected an indented
block`` (`LP:4567-4585`, `BLK:64-74`). It then reads statements while the next
token is past the anchor; the first token that is not past it ends the block
(`LP:4588-4621`, `BODY:538-550`). A block whose first statement is not past
the anchor is empty, which is a syntax error.

For a block that is a statement of its own (a `while` body, a function body, a
statement-level `if`), the anchor is the statement's first token, and the
`INDENT` already puts every statement past it. The rule matters for a block
opened inside an expression, whose anchor can sit in the middle of a line. The
anchor depends on where the expression is:

| Expression position | Anchor | Evidence |
| --- | --- | --- |
| Expression statement | the statement's first token | `LP:6548-6559` |
| Value after `name =`, `name: T =`, `?=` or a compound operator | the name | `LP:6275-6280`, `LP:6306`, `LP:6362` |
| Value after `var name =` | the `var` keyword | `LP:6247-6252` |
| Value of a destructuring | the opening `(` | `LP:6472-6477` |
| Value of a subscript assignment | the start of the target | `LP:6563-6569` |
| Global initializer | the declaration's first token | `LP:10594-10599` |
| Value on the next line after `=` | the value's own first token | `LP:3722` |
| `if` or `while` condition | the condition's first token | `LP:8194-8209` |
| `if` block | the anchor the `if` was read under | `LP:4701` |
| `else` block, `else if` | the `else` keyword | `LP:4717`, `LP:4739` |
| `match` scrutinee, `for` iterable, `select` channel or timeout, `with` value | its own first token | `LP:4856`, `LP:6158`, `LP:4939`, `LP:5022`, `LP:5283` |
| `match` cases, `select` arms | the anchor the `match` or `select` was read under | `LP:4879-4887`, `LP:5128-5136` |
| A `match` case's block body | the case's pattern | `LP:4776-4782` |
| A `select` arm's block | the arm's first token | `LP:4952`, `LP:4990`, `LP:5035` |
| `for` block | the anchor the `for` was read under (its keyword) | `LP:6204` |
| `while` block | the `while` keyword | `LP:6096` |
| `with`, `debug`, `concurrent` block | the keyword | `LP:5377`, `LP:5187`, `LP:5816` |
| Lambda block body | the anchor the lambda was read under | `LP:6879-6885`, `LP:6781-6799` |
| Same-line lambda or function body | the body's first token | `LP:6798`, `LP:8311` |
| Function block body | the declaration's first token | `LP:8289-8303` |
| Call arguments, subscript indices | the anchor the call was read under | `LP:7906-7913`, `LP:7942-7948`, `LP:3854-3880` |
| List items | the opening `[` | `LP:7752-7761` |
| Grouping and tuple items | the opening `(` | `LP:6998-7006`, `LP:6915-6925` |
| Record field value, Dict key and value, vector item, update base, opaque conversion value | the item's own first token | `LP:7091`, `LP:7237`, `LP:7280`, `LP:7336`, `LP:7428`, `LP:7532` |
| Right operand of a binary operator, operand of a prefix operator | the anchor the operator expression was read under | `LP:8143-8150`, `LP:8040-8045` |

So a block lambda as a list item must be indented past the `[`:

```blorp
    handlers = [func(x):
        x]                    -- error: `x` is not past the `[`
```

while the same lambda as a call argument needs only to be past the statement's
first token.

**Token grammar.** Not expressible: the lexer's `INDENT` says only that the
block is deeper than the enclosing *line*, and the anchor can be a token later
in that line. Whenever the anchor is the first token of its line, the rule is
implied by the `INDENT` and adds nothing.

**Implementations.** `QRK:41-73` (`block_may_open`, `ExpressionAnchor`,
`BlockAnchor`) for the tree path; `BLK:33-74` and `BODY:500-571` for the table
path.

There is one more way into a block. When a lambda's `:` ends a line whose
break is insignificant (inside brackets nested within an open bracketed block,
[2.4](#24-consequences-and-quirks) consequence 4), no `NEWLINE` or `INDENT`
follows. The lambda's body is still read as a block if its first token is on a
later line than the `:` and past the anchor (`LP:6792-6796`,
`BODY:1606-1620`), and its statements then have no separators.

> **Recommended (D5):** drop the anchor. A block opened inside an expression is
> valid when the lexer opens an indentation level for it, as for any other
> block, and a block without an `INDENT` is rejected.

### 4.2 Method-chain continuation

**Rule.** After a primary expression, the postfix loop reads field, call and
subscript operations. A `.` may also continue the chain from the next line:

- `NEWLINE "."`: the next line, at the same indentation, starts with `.`
  (a leading dot);
- `NEWLINE INDENT "."`: the next line is deeper and starts with `.` (an
  indented chain). The chain takes ownership of that `INDENT`.

A call's `(` and a subscript's `[` never continue from the next line: `x =
print` followed by a line `("a")` is two statements.

The loop keeps a counter `c` of the `INDENT` tokens it owns, starting at 0
(`LP:7839-7982`, `BODY:1793-1847`). At each step:

1. If `c > 0` and the next token is `DEDENT`: consume it and decrement `c`; if
   `c` reaches 0, the chain ends.
2. If `c > 0` and the next tokens are `NEWLINE DEDENT`: consume both and
   decrement `c`; if `c` reaches 0, the chain ends.
3. If the next tokens are `NEWLINE INDENT "."`: consume `NEWLINE INDENT` and
   increment `c`. If they are `NEWLINE "."`: consume the `NEWLINE`.
4. If the next token is `.`, `(` or `[`, read that postfix operation and
   continue; otherwise the chain ends.

So a chain may step in by several levels, each owned `INDENT` closed by its
`DEDENT`, and a line that steps back out to an inner chain level continues the
chain:

```blorp
    total = items
        .filter(func(x): x > 0)
            .map(double)
        .sum()                 -- continues: items.filter(...).map(...).sum()
```

A `.` line that steps back out to the statement's own level after an indented
chain does not continue it, because its `DEDENT` ended the chain at step 1; it
is ``expected expression``.

**Leaked indentation.** When the chain ends at step 4 with `c > 0`, because
something other than a line break follows the last continuation line, the
owned `INDENT`s are still open. One case is repaired: after a statement or a
value, if the next tokens are `{ NEWLINE } DEDENT` and the expression is a
binary or logical expression whose left operand contains a line-continued field
access (or whose right operand needs the repair, recursively), that one
`DEDENT` is consumed (`LP:3590-3675`, applied at `LP:6775` and `LP:3745`;
`BLK:93-189`). So these parse:

```blorp
    x = xs
        .length() + 1          -- the repair consumes the chain's DEDENT
    ok = xs
        .is_empty() and ready
```

and these do not, and report errors where the function ends:

```blorp
    x = -xs
        .length() + 1          -- the left operand is a negation: not repaired
    y = xs
        .length()
            .abs() + 1         -- two owned levels: only one DEDENT is repaired
```

**A line inside an indented chain must continue it.** Inside an indented
chain, a line at the chain's indentation must start with `.`. Any other line
is a syntax error at its first token, ``expected `.` to continue the method
chain``, with the help to start the line with `.` or to move it out of the
chain.

> **Current behaviour differs:** step 3 finds neither pattern, and the old
> parser loops forever without consuming a token (`LP:7859-7877`). These
> sources hang it:
>
> ```blorp
>     x = xs
>         .f()
>         y                      -- likewise [0], (1) or ..1 on this line
> ```
>
> The table path ends the chain instead (`BODY:1815-1822`) and reports a
> cascade at the end of the function (``expected `=` after top-level variable
> declaration``): the right verdict at the wrong place. *(implementation
> defect)*

**Token grammar.** Steps 1 to 4 are token rules, so a chain whose owned levels
close right after its last line is expressible. `postfix_expr` in
[3.5](#35-expressions) ends with an optional `indented_chain`:

```ebnf
indented_chain = NEWLINE INDENT "." field_name { postfix_op | indented_chain }
                 [ NEWLINE ] DEDENT ;
```

An indented chain is the last link of the chain that owns it: once its
`DEDENT` returns the chain to the statement's own level, the chain has ended
(step 1 with `c` reaching 0), so a `.` line there is not a link. Both parsers
reject it with ``expected expression``:

```blorp
    x = xs
        .length()
    .abs()                     -- error: the chain ended at the DEDENT
```

Inside an indented chain, links may follow a nested indented chain, as in the
`total` example above, because the nested chain's `DEDENT` leaves `c` above 0.
See [D4](#d4-method-chain-continuation) for whether a same-indentation leading
dot should continue a chain at all.

The leaked-indentation repair is not context-free: the `DEDENT` that closes a
chain's level comes after tokens that belong to the enclosing expression.

> **Recommended (D4):** the chain's owned levels belong to the enclosing
> statement: after any statement or value, every `DEDENT` still owed to a
> chain inside it is consumed, so both rejected examples above are accepted.

### 4.3 Value on the next line after `=`

**Rule.** After the `=` of a binding, `var`, global, destructuring, subscript
assignment or discard, after `?=`, and after a compound assignment operator,
the value may start on the next line, indented:

```ebnf
value = NEWLINE INDENT expression [ NEWLINE ] DEDENT | expression ;
```

The indented value is exactly one expression, not a block (`LP:3700-3753`,
`BODY:690-724`). A next line that is not indented is ``expected indented
assignment value``, with the help to indent the lines of the block under its
header. The value's own first token anchors any block inside it, and an
indented method chain may continue it on deeper lines.

A second line at the value's indentation is a syntax error at its first
token: ``expected the end of the assignment value``, with the help that an
indented value is one expression.

> **Current behaviour differs:** both parsers end the value after its first
> expression and leave the `INDENT` open, so
>
> ```blorp
>     x =
>         1
>         2
>     x
> ```
>
> reads `2` as a statement and reports misleading errors where the function
> ends. *(implementation defect)*

**Token grammar.** Expressible, as above.

### 4.4 Operator then newline

**Rule.** A binary operator at the end of a line continues the expression onto
the next line only when that line has the same indentation: the operator is
followed by `NEWLINE` and then the operand (`LP:8143-8144`, `BODY:1719-1744`).
An operand on a deeper line follows `NEWLINE INDENT` and is ``expected
expression``; an operand on a shallower line follows a `DEDENT` and is
``expected expression``. A prefix operator (`-`, `not`) takes no line break:
`x = not` followed by a line `True` is ``expected expression``. An operator at
the *start* of a line does not continue the line before it; it begins a new
statement.

Inside brackets line breaks are insignificant, so an expression may be split
anywhere there.

**Token grammar.** Expressible: `binary_op [ NEWLINE ] operand`, as in 3.5.

### 4.5 Operator after a block

**Rule.** When an `if` or `match` expression, or a block lambda, is
read inside the operator loop (as an expression statement or as an operand), a
binary operator, `as` or `=` on the line after its closing `DEDENT` continues
the expression ([3.7](#37-control-expressions-and-blocks)).

**Token grammar.** Expressible: the control expression ends with `DEDENT`, and
the operator loop simply continues with the next token. The tree path declines
this form (`TREE:219-225`) and leaves it to the table path. See
[D3](#d3-operator-after-a-block) for the recommended rule.

### 4.6 Blocks inside same-line bodies

**Rule.** A same-line function body or lambda body is an expression whose
anchor is its own first token (`LP:6798`, `LP:8311`). A block inside it (an
`if` that is the body, a block lambda in a call in the body) is read only if it
is indented past that token's column:

```blorp
    xs.map(func(x): x.map(func(y):
        y + 1                         -- error: `y` is not past the second `x`
    ))
```

Indenting `y + 1` past the column of the second `x` makes it valid, and so is
`func f(c: Bool) -> Int: if c:` followed by a then-block indented past the
`if`.

**Token grammar.** Not a separate rule: it is the bracketed-block anchor (4.1)
with the anchor in the middle of the header's line. The usual summary "a
same-line body may not end in a block" is true only of blocks indented the
usual way.

### 4.7 `with`, `debug` and `concurrent` blocks used as values

**Rule.** The blocks of `with`, `debug:` and `concurrent:` are anchored at
their keyword, not at the statement (`LP:5377`, `LP:5187`, `LP:5816`). As
statements this changes nothing. As a value, the block must be indented past
the keyword's column:

```blorp
    x = with r = open_resource():
        r.read()                      -- error: not past the `with`
```

**Token grammar.** An instance of 4.1 with the keyword as anchor. The tree
path declines these values (`TREE:360-366`).

### 4.8 Case-line nesting

**Rule.** A `match` case whose body is on the case's line may begin an `if` or
`match` there. That construct is anchored at the case's *pattern*, so its block
(or its cases) must be indented past the pattern's column, and its `else` may
sit at the pattern's column (`LP:4783-4796`):

```blorp
    match a:
        True: match b:
            True: 1
            False: 2
        False: 3
```

Any other same-line case body is a statement anchored at its own first token
(`LP:4798`), so a block lambda there must be indented past the lambda itself:
`True: func(x):` followed by a body indented one level under the case is an
error.

**Token grammar.** An instance of 4.1 with the pattern as anchor.

### 4.9 Closing bracket on a block's last line

**Rule.** A bracketed block must end, with its `DEDENT`, before the bracket
that contains it closes. Because the lexer emits that `DEDENT` only at the
start of a later line (consequence 5), a closing bracket on the block's last
line is inside the block, where it cannot start a statement:

```blorp
    ys = xs.map(func(x):
        x + 1)                        -- error at `)`
```

Both parsers report ``expected expression`` at the bracket and then
``expected `)` after call arguments``. The closing bracket goes on its own
line, indented at or below the lambda's base level, or between the base and
the block's own level (L2 case 3):

```blorp
    ys = xs.map(func(x):
        x + 1
    )
```

The same holds for an `if` or `match` value inside brackets: its last block
cannot end on the bracket's line.

**Token grammar.** Expressible: a `block` is `INDENT ... DEDENT` and cannot
contain the closing bracket, so the grammar rejects it.

> **Recommended (D6):** keep the rejection with a diagnostic that names the
> rule, ``a block inside brackets must end before the closing bracket``, with
> the help to put the bracket on its own line.

## 5. Static syntactic restrictions

The parser enforces these rules beyond the grammar. Unless a rule says
otherwise, a violation is a syntax error, and both parsers report it.

### 5.1 Assignment is a statement

Assignment (`=`), compound assignment, `?=` and bindings are statements
([3.4](#34-statements)). An assignment operator after an expression that is
not in statement position is an error at the operator; the value after it is
parsed and discarded, so no cascade follows (`LP:6619-6663`, `BODY:921-955`):

- in an `if` or `while` condition, `=` is ``a condition cannot be an
  assignment``, with the help ``use `==` to compare, or assign on its own line
  before the condition`` (`RND:1386-1390`);
- anywhere else (a list item, a call argument, an operand, a parenthesized
  expression, an interpolation hole) it is ``an assignment is a statement, not
  an expression``, with the help ``assign on its own line first, then use the
  name where the value is needed`` (`RND:1391-1395`).

Blorp has no named arguments: `f(name = value)` is such an assignment. The `=`
of a record field and of a record update is part of that syntax.

### 5.2 Assignable places

| Target | Form | Rule |
| --- | --- | --- |
| A name | `name = v` | Declares an immutable name, or reassigns a `var` in scope (decided by resolution). |
| A typed name | `name: T = v` | Declares an immutable name. |
| A new mutable name | `var name [: T] = v` | Declares a mutable name. |
| A name, compound | `name += v` (and `-=`, `*=`, `/=`) | `_` is ``compound assignment cannot update `_` ``. |
| An unwrapped name | `name [: T] ?= v` | `_` is `` `?=` cannot bind to `_` ``, with the help ``use a name for the unwrapped value``; placement in 5.3. |
| A discard | `_ = v` | Evaluates `v` and discards it. |
| A destructuring | `(a, b) = v`, `(_, b) = v` | 2 to 4 names or `_`, flat and untyped. It always declares; a name that is a `var` in an enclosing scope is rejected rather than shadowed. |
| A subscript place | `name[i] = v`, `name[i][j] = v` | Any chain of one or more subscripts on a name. Validity is a type rule, below. |
| A field | `p.x = v` | Rejected: ``field assignment is not supported``, with the help ``use record update syntax: { record \| field = value }`` (`RND:1381-1385`, `LP:6581-6604`). |

Any other target is a syntax error. Owner decisions:

- **Destructuring does not nest**: `((a, b), c) = v` is a syntax error.
- **Destructured elements carry no type annotation**: `(a: Int, b) = v` is a
  syntax error.
- **Subscript assignment** is valid only where the index is statically known
  to be in bounds: on a tuple with a literal index, and on a tensor
  (`T[#N...]`, `Vector`, `Matrix`, `Tensor`) with one index per dimension, each
  of which the typechecker proves in bounds. The proofs it accepts are a
  literal, a range-refined `..#N` index, a loop variable over
  `0..length(t)`, `i % n` where `n` is at most the dimension or is
  `length(t)`, and a flattened row-major index (`validate_array_index` and
  `validate_dynamic_array_index`, `INFER:17292-17733`). Elsewhere it is
  rejected, for example `d[k] = v` on a `Dict`, or `xs[i] = v` with a plain
  `Int` index on a `List`; lists and dicts use their update functions. The
  name the place starts with must be mutable: a `var` local or a mutable
  global; otherwise it is ``Cannot assign to subscript of immutable variable
  'name'`` (`subscript_assignment_mutability`, `INFER:18835-18900`). **These
  are typecheck rules**, enforced by inference (`infer_subscript_assign_expr`,
  `INFER:19142`), not by the parser.

> **Current behaviour differs:**
> - The parser accepts any postfix expression ending in a subscript as a place
>   (`xs.f()[0] = v`, `box.items[0] = v`) and leaves it to the typechecker.
>   *(pending language change)*
> - `((a, b), c) = v`, `(a: Int, b) = v`, `f(x) = v` and `(x) = v` are
>   rejected, but with the generic ``expected expression`` (or ``expected `)`
>   after expression``) instead of a message about assignment targets.
> - The typechecker accepts subscript assignment only on tensor types
>   (`array_type_parts`, `SEM:941`), so assigning a tuple element with a
>   literal index is rejected; it is the one new capability in the decision.
>   *(pending language change)*

### 5.3 `break`, `continue` and `?=`

- `break` and `continue` are valid only inside the body of a `while`, `for` or
  `for ... concurrently` loop. A function body, a lambda body and a
  `concurrent:` block start a new context, so a `break` there cannot leave an
  enclosing loop. Elsewhere it is `` `break` can only be used inside a loop ``
  (likewise for `continue`), with the help ``move `break` into a `while` or
  `for` body, or remove it`` (`RND:1484-1493`, `LP:3466-3489`; contexts at
  `LP:5813`, `LP:5889`, `LP:6093`, `LP:6201`, `LP:6788`, `LP:8295`).
- `?=` is not valid anywhere inside a loop body: `` `?=` cannot be used inside
  a loop body ``, with the help ``bind it before the loop, or use `match`
  inside the loop`` (`RND:1479-1483`, `LP:3491-3508`). A lambda or
  `concurrent:` block inside a loop starts a new context, so `?=` inside one
  is allowed. Whether the enclosing function or lambda returns an `Option` or
  `Result` is a type rule.
- Owner decision: **`break`, `continue` and `?=` may not appear inside an `if`
  or `match` used as a value** (a binding's value, an operand, an argument)
  within a loop. They must sit in statement-position constructs all the way to
  the loop body (for `break` and `continue`) or to the function body (for
  `?=`).

> **Current behaviour differs:** `break` and `continue` inside a
> value-position `if` or `match` in a loop are accepted by the parser;
> `x = if a: break ...` fails only as an if-else type mismatch. (`?=` there is
> already rejected, by the rule above that forbids it anywhere in a loop
> body.) *(pending language change)*

`break` and `continue` are also accepted as operands and arguments today
(`x = break`, `print(break)`); see [D10](#d10-break-and-continue-as-operands).

### 5.4 Nesting limit

Owner decision: syntax nests at most `MAX_SYNTAX_NESTING` = 128 levels. Each of
these counts one level where it nests inside another counted form:

- a bracketed form: a parenthesized expression, a call's argument list, a
  subscript, a list, tuple, vector, record, record update or Dict literal, and
  an interpolation hole;
- an indented block;
- a lambda body, whether a block or a same-line expression, so
  `func(a): func(b): ...` counts one level per lambda;
- a control expression read as an operand (`1 + if ...`);
- each operator of a prefix-operator chain (`not not x`, `- - x`);
- a nested written type: type arguments (`List[List[...]]`), grouped and
  tuple types, and a function type's parameters and its return type, so
  `(A) -> (B) -> C` counts one level per arrow (the return type is parsed by
  recursion, `TTYPE:345-346`, `TYPE:627-632`);
- a nested pattern (constructor, tuple and list patterns);
- a parenthesized dimension expression.

Chains that the parser builds with a loop do not count: binary operator chains,
postfix chains, `else if` chains, the cases of a `match` and the arms of a
`select`. Exceeding the limit is a syntax error that names the limit and
suggests binding the inner value to a name or moving the inner block into a
function of its own.

> **Current behaviour differs:** neither parser has the limit yet; it is
> planned for the discovery stage's parse state
> ([DISCOVERY_REDESIGN.md](DISCOVERY_REDESIGN.md), section 3.14). The old
> parser accepts any depth its stack allows. *(pending language change)*

### 5.5 Interpolation hole contents

A hole holds exactly one expression, written on one line: the form of a
`value` after `=`, without the next-line alternative (`BODY:2469-2491`).
Anything more is ``an interpolation hole must hold exactly one expression``; an
empty hole is ``expected expression``; an assignment is rejected as in 5.1. A
hole lies on one line, so it cannot hold a block, and therefore no `if` or
`match`; a lambda with a same-line body is allowed. The owner decisions add:

- the expression's type must be `Stringable`, a type rule enforced by
  inference (``Interpolated expression has type ... which cannot be converted
  to String``);
- an interpolated string may not appear in a hole
  ([1.7](#17-interpolation-holes)).

Lexically a hole is also bounded by `MAX_INTERPOLATION_DEPTH` = 64 open braces
and holes ([1.7](#17-interpolation-holes)).

> **Current behaviour differs:** nested interpolated strings are accepted.
> *(pending language change)* The old parser does not parse holes itself: it
> keeps their text, and `FIN` later parses each hole as the global
> `x=<hole>` (`FIN:2416-2470`). The discovery
> stage parses holes with the rest of the module.

### 5.6 Other restrictions

- **Tuple arity.** Tuple expressions, tuple types, tuple patterns, tuple
  parameters, `for` tuple binders and destructurings have 2 to 4 elements.
- **Union variants** have at most 64 payload fields. **Field names** are
  distinct in a record declaration, literal and update.
- **`for` has no value** (3.4); **`as` was removed** (3.5); **`try:` was
  removed** (1.4).
- **Annotations** are known names, take no arguments, and precede a function
  (3.3).
- **Forward declarations** are top-level only and need a same-named function
  with a body (3.3).
- **Bounds** appear only in `type_params` and in `implements` receivers, and a
  dimension parameter takes none (3.3, 3.8).
- **Concurrency parameters** are as listed in 3.7, and `with` takes one
  binding.
- **Docstrings** precede a declaration, or begin the module before its first
  `import:` block (3.2).
- **Owner decision: `detach` is a statement only.** It is not valid as a value
  or an operand (3.4).
- **`select` is a statement only**: recommended in
  [D9](#d9-select-as-a-value), stated by the Guide, not enforced today.

## 6. Owner decisions of 2026-10-06

These decisions are part of the intended grammar above. The last column says
whether today's parsers follow them.

| Topic | Decision | Rule | Current |
| --- | --- | --- | --- |
| `{}` | Always an empty Dict. | [3.6](#36-primary-expressions) | Differs: an empty record literal that typechecks as the expected Dict or Set; the empty-Set uses need migrating. |
| `debug` | Reserved, so `debug:` is unambiguous. | [1.4](#14-keywords) | Differs: soft keyword. |
| `select` | Reserved, like `debug`. | [1.4](#14-keywords) | Differs: soft keyword. |
| `\|` | Starts a pipe string only after `=`; a line-start `\|` inside braces is a record-update bar. | [1.6](#16-string-literals) | Differs: every line-start `\|` starts one. |
| `not` | Python precedence, below comparisons. | [3.5](#35-expressions) | Differs: binds like negation. |
| Comparisons | Non-associative; `a < b < c` is an error suggesting `a < b and b < c`. | [3.5](#35-expressions) | Differs: one left-associative level. |
| `..` | Non-associative; `a..b..c` is an error. `..#N` is unaffected. | [3.5](#35-expressions) | Differs: left-associative. |
| `detach` | Statement only. | [3.4](#34-statements) | Differs: prefix operator. |
| Interpolation holes | Any `Stringable` expression; no nested interpolated strings. | [5.5](#55-interpolation-hole-contents) | Differs: nesting accepted. |
| `break`, `continue`, `?=` | Not inside a value-position `if` or `match` in a loop. | [5.3](#53-break-continue-and-) | Differs: accepted. |
| Nesting limit | 128. | [5.4](#54-nesting-limit) | Differs: no limit. |
| Destructuring | Flat only, with no element types. | [5.2](#52-assignable-places) | Rejected today, with generic messages. |
| Subscript assignment | Any chain of subscripts on a name; valid only on tuples (literal index) and tensors (proven index); a typecheck rule. | [5.2](#52-assignable-places) | Differs: any postfix place parses; tuples are rejected. |

## 7. Decisions needed

Each item states today's behaviour, the question, and a recommendation.

### D1. Comment-only lines

A comment-only line is a content line for layout (2.4, consequence 6). A
comment shallower than its block, typically commented-out code at column 1
inside a function, closes the block and every block inside it, and a comment
deeper than its block opens a level; either breaks the parse with ``expected
declaration``. **Recommendation:** treat a comment-only line as a blank line in
L2, as Python and Haskell do. No valid program changes meaning; some programs
that are rejected today become valid.

### D2. Items written on one line

No parser requires a separator between statements, cases, arms, variants or
declarations (3.1). So `x = 1 y = 2` is two statements, `0x10` is `0` then
`x10`, and `1e5` is `1` then `e5`. **Recommendation:** require the `separator`
of 3.1, a `NEWLINE` or nothing after a `DEDENT`, and report the second item's
first token: ``expected a new line before this statement``. For a number
followed directly by a letter, add a lexical error explaining that Blorp has no
hexadecimal or exponent literals.

### D3. Operator after a block

An operator on the line after a control expression's `DEDENT` continues the
expression in statement and operand positions, but not as a binding's value
(3.7, 4.5). An `if` statement followed by a line `- 3` silently becomes a
subtraction. **Recommendation:** an expression that ends with a block's
`DEDENT` ends there, and what follows is the next statement. A line starting
with `-` is then a negation statement, and a line starting with any other
binary operator is ``expected expression`` with the help that an operator
cannot start a line. This also removes the tree path's decline.

### D4. Method-chain continuation

There are two defects: a non-`.` line inside an indented chain hangs the old
parser, and the chain's indentation leaks when the chain sits inside a
negation or `not`, or is two levels deep (4.2). **Recommendation:** specify the
hang as the error given in 4.2, and make the chain's owned levels belong to the
enclosing statement, so that after any statement or value every `DEDENT` still
owed to a chain inside it is consumed. Then `x = -xs` followed by
`    .length() + 1` is accepted. Also decide whether a same-indentation leading
dot (`x = xs` followed by `.length()` at the same indentation) should continue
a chain: it is accepted today, the Guide documents only the indented form, and
it reads like a new statement.

### D5. The bracketed-block anchor

A block opened inside an expression must be indented past an anchor that
depends on where the expression is (4.1, 4.6, 4.7, 4.8). Users cannot see
anchors, and re-indenting a block that the lexer already reads as a block can
make it an error. **Recommendation:** replace the anchor with the lexer's
`INDENT` alone, so a block opened inside an expression is valid when the lexer
opens a level for it, as for any other block. Every program that is valid
today stays valid, and `layout_quirks.brp` can be removed. Also reject the
block without an `INDENT` described at the end of 4.1, which only unusual
layouts reach.

### D6. Closing bracket on a block's last line

`xs.map(func(x):` followed by `    x + 1)` is rejected (4.9).
**Recommendation:** keep the rejection, since a `)` that closes a bracket
opened lines earlier while also ending a block is hard to read, and give it the
teaching message of 4.9.

### D7. The remaining soft keywords

`with`, `concurrent`, `concurrently`, `after`, `sealed` and `on` are soft
keywords, and `from` is reserved. They behave unevenly:

| Keyword | Bindable | Readable as a value | Why it is a keyword |
| --- | --- | --- | --- |
| `with` | yes | no: starts a `with` block | `with` blocks |
| `concurrent` | yes | no: starts a `concurrent:` block | `concurrent:` blocks |
| `after` | yes, except as an immutable global in the old parser | yes, as a name | `_ after t:` select arms (`LP:5049-5065`) |
| `sealed` | yes, with the same exception | yes, as a name | `sealed ch:` select arms |
| `on` | yes, with the same exception | no | `?= v on e => m` in `with` |
| `concurrently` | yes, with the same exception | no | `for x in xs concurrently(...)` |
| `from` | no: reserved | yes, as a name | `x from ch:` select arms |

`after` looks accidental: it is a keyword only because a timeout arm is
written `_ after t:`, a position where an identifier would be unambiguous, and
the tree path declines it in expressions (`STOP:216`). **Recommendation:**
reserve `with` and `concurrent` for the reason `debug` and `select` are
reserved: each starts a block, so binding one creates a name that cannot be
read. Make `after`, `sealed`, `on`, `concurrently` and `from` contextual
identifiers, lexed as identifiers and recognized only in their one position
each: after `_` at the start of a select arm; at the start of a select arm,
before an expression and `:`; after a `with` binding's `?=` value; after a
`for` iterable; after a select arm's binder. They are then ordinary names
everywhere else, including immutable globals, which also ends the old parser
and discovery stage disagreement about globals.

### D8. Where a pipe string may start

The owner decided that `|` starts a pipe string only after `=`. Today 16 pipe
strings in the repository start elsewhere. Fourteen are a function's whole body
on the line after its header (`blorp/src/lib/runtime_cache.brp:161`, and
tests such as `test_plan.brp`, `test_doctest.brp`,
`test_type_header_graph.brp`, `test_lsp_source_loader.brp` and two formatter
fixtures); one is a function's last statement, after other statements
(`test_project_source_catalog.brp:93`); and one is a pattern inside a
constructor's parentheses (`string_patterns_plain_raw_and_pipe.brp:16`). A
call argument (`print(` then a line `|text`) is also accepted today. 310 pipe
strings follow `=`, and 111 are raw pipe strings after `raw`.
**Question:** which positions count as "after `=`": a compound assignment
(`+=`), a function body or statement, a call argument, a list item, a pattern?
**Recommendation:** a line-start `|` starts a pipe string unless its line
break is insignificant (inside brackets, L2 case 1) and the token before it
can end an operand (a name, a literal, `)`, `]` or `}`); then it is an
operator bar. That keeps every use above, makes the record-update bar work,
and is decided by the lexer from its own state and the previous token.

### D9. `select` as a value

`x = select: ...` is accepted by the parser and the typechecker, although the
Guide says `select` is statement-only (3.7).
**Recommendation:** reject it in the parser, with the Guide's explanation.

### D10. `break` and `continue` as operands

`break` and `continue` are primary expressions today (`x = break`,
`print(break)`). **Recommendation:** make them statements, as the owner
decision on value-position `if` and `match` implies; a `break` in an operand is
then a syntax error with the help to write it on its own line.

### D11. `_` as an expression

`_` in expression position means `void` (3.6). **Recommendation:** reject it,
with the help to write `void`, so that `_` means "discard" or "wildcard"
everywhere it is valid.

### D12. One interpolation limit

Holes are limited by `MAX_INTERPOLATION_DEPTH` (64, lexical) and will also
count toward `MAX_SYNTAX_NESTING` (128). With nested interpolated strings
gone, the lexical limit only bounds brace depth inside one hole.
**Recommendation:** drop `MAX_INTERPOLATION_DEPTH` and count braces inside a
hole toward `MAX_SYNTAX_NESTING`, like any other bracket.

## 8. Where current behaviour differs

### 8.1 From the intended grammar

| Area | Current behaviour | Intended | Kind |
| --- | --- | --- | --- |
| `debug`, `select` | Soft keywords | Reserved | Pending change |
| Line-start `\|` | Always a pipe string | A pipe string only after `=` | Pending change |
| `not` | Binds like negation | Below comparisons | Pending change |
| Comparisons | Left-associative | Non-associative | Pending change |
| `..` | Left-associative | Non-associative | Pending change |
| `detach` | Prefix operator | Statement | Pending change |
| `{}` | Empty record literal | Empty Dict | Pending change |
| Nested interpolated strings | Accepted | Rejected | Pending change |
| `break`, `continue` in a value `if` or `match` in a loop | Accepted | Rejected | Pending change |
| Nesting | Unlimited | 128 | Pending change |
| Subscript place | Any postfix expression ending in `[...]` | A name with subscripts | Pending change |
| Subscript assignment on a tuple | Rejected (tensors only) | Allowed with a literal index | Pending change (typecheck) |
| Item separators | Not required | A `NEWLINE`, or nothing after a `DEDENT` | [D2](#d2-items-written-on-one-line) |
| Comment-only lines | Layout content | Recommended: layout-transparent | [D1](#d1-comment-only-lines) |
| Operator after a block | Continues the expression | Recommended: ends it | [D3](#d3-operator-after-a-block) |
| Non-`.` line in an indented chain | Old parser hangs; table path reports a cascade | An error at that line | Intended rejection (4.2) |
| Leaked chain indentation | Error cascade | Recommended: accepted | [D4](#d4-method-chain-continuation) |
| Second line of a next-line value | Error cascade | An error at that line | Intended rejection (4.3) |
| Closing bracket on a block's last line | ``expected expression`` | A teaching error | [D6](#d6-closing-bracket-on-a-blocks-last-line) |
| `select` as a value | Accepted | Rejected | [D9](#d9-select-as-a-value) |
| `break`, `continue` as operands | Accepted | Recommended: rejected | [D10](#d10-break-and-continue-as-operands) |
| `_` as an expression | The Void value | Recommended: rejected | [D11](#d11-_-as-an-expression) |

### 8.2 Old parser and discovery stage disagreements

| Input | Old parser | Discovery stage |
| --- | --- | --- |
| An immutable global named by a soft keyword (`after: Int = 1`) | ``expected declaration`` (`LP:10811-10822`) | Accepted |
| `#` and a dimension name separated by blanks (`Int[# N]`) | Accepted | ``expected dimension name or literal after `#` `` (`LEX:837-856`) |
| A non-`.` line inside an indented chain | Hangs (`LP:7859-7877`) | Ends the chain and reports errors where the function ends (`BODY:1815-1822`) |
| Interpolation holes | Hole text is kept and parsed later as `x=<hole>` (`FIN:2416-2470`) | Parsed with the module: ``an interpolation hole must hold exactly one expression`` (`BODY:2469-2491`) |
| Nesting past 128 | Accepted | Accepted today; to be rejected (5.4) |

The old parser's diagnostics join the message and its help into one sentence
in these places, where this document quotes the discovery stage:

| Diagnostic | Old parser (`LP`) | Discovery stage (`RND`) |
| --- | --- | --- |
| Reserved keyword as a name (1.4) | ``…cannot be used as a name; choose another identifier such as `x_name` `` (`LP:1490-1495`) | message ``…cannot be used as a name``, help ``choose another identifier…`` |
| Assignment in a condition (5.1) | ``A condition cannot be an assignment. Use `==` to compare, or assign on its own line before the condition`` (`LP:198-201`) | message ``a condition cannot be an assignment``, help ``use `==` to compare…`` |
| Assignment in an expression (5.1) | ``An assignment is a statement, not an expression. Assign on its own line first, then use the name where the value is needed`` (`LP:203-206`) | message ``an assignment is a statement, not an expression``, help ``assign on its own line first…`` |
| Field assignment (5.2) | ``Field assignment is not supported. Use record update syntax: { record \| field = value }`` (`LP:6594-6595`) | message ``field assignment is not supported``, help ``use record update syntax…`` |
| `?=` binding `_` (5.2) | `` `?=` cannot bind to `_`; use a name for the unwrapped value `` (`LP:6319`) | message `` `?=` cannot bind to `_` ``, help ``use a name for the unwrapped value`` |

The tree path declines, rather than rejects, several forms that the table path
reads: an operator after a block, `with`, `debug` and `concurrent` values,
tuple destructuring, and `after`, `sealed`, `on` and `concurrently` in
expressions (`TREE:1-15`, `STOP:198-239`). A decline is not a disagreement:
the table path then reads the form as the old parser does.
