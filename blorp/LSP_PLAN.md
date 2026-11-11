# Language server: `blorp lsp`

**Status: plan, 2026-11-10, awaiting Keith's review of four open decisions.**

## Problem

Blorp has no editor support: no colours, no go-tos, and no errors until you
compile. The command a language client would start does not exist:

```console
$ blorp/build/blorp lsp
blorp: error: unknown command `lsp`
help: run blorp help to list the commands
$ echo $?
2
```

(`src/cli.brp:128`; 2 is `EXIT_USAGE`.)

We want a `blorp lsp` that speaks the Language Server Protocol over standard
input and output, launched by a minimal editor plugin. Keith's priorities
are highlighting, then go-to-definition, then find-references.

## Background

**Keith decided on 2026-11-10:**

- a `blorp lsp` subcommand;
- start simple, with one loop and whole-program analysis;
- semantic tokens only, with no TextMate grammar;
- comments as lexer output if that is cleaner (it is);
- a limited v1 root, with its limits documented;
- library go-to through a temporary folder;
- the cleanest rotation path;
- an ergonomic way to write output without a newline (`put` was rejected).

**What exists:**

- the `json` codec;
- loader source snapshots: `load_program_with_sources`
  (`src/common/analysis/load/load.brp:722`, see `SOURCE_SNAPSHOTS_DECISIONS.md`);
- the embedded library (`1a68dbd3b`);
- byte-range spans on every token and definition name
  (`src/common/syntax/syntax.brp:8`);
- process `capture`, which writes and then closes `stdin: Option[String]`.

**What is missing:**

- **`check` requires `main`.** Without it, checking fails with `MissingMain`
  (`src/common/analysis/check/signatures.brp:188`).
- **Name uses go unrecorded.** Nothing keeps which definition a name
  resolved to.
- **The lexer skips comments** in four places, and the formatter finds them
  again (`src/format/trivia.brp:185`).
- **A failed lex keeps no tokens.** Names are interned only after a
  successful scan (`src/common/syntax/lex.brp:1890`).
- **The console cannot read.** `print` always adds a newline and never
  flushes.
- **Each phase reports only its first error.**

**Related plans:**

- `STRING_PLAN.md` moves byte work to `byte_*` functions.
- `PATH_PLAN.md`: its naming rules, rotation (landing 5) and exact-error
  rules all apply here.

## Open decisions

1. **First editor.** I recommend **CLion**, Keith's editor. JetBrains
   supports `semanticTokens/full` from 2024.2.2, and the old plugin
   (`ee9e001c6de8:editor/intellij/`) supplies a launcher. VS Code needs about
   30 lines and documents semantic tokens better.
2. **The console API.** The names below, plus the rule that every read
   flushes standard output first. That rule is implicit behaviour, so it
   needs Keith's approval (`blorp/AGENTS.md`).
3. **Recording occurrences.** If recording them on every compile fits the
   ceilings, the checker always records them. Otherwise only analysis does,
   behind an explicit argument. A spike decides.
4. **Serving broken files.** I recommend keeping each document's last
   successful analysis and mapping its spans onto the current text. Without
   it, every transient error while typing drops all identifier colour and
   every go-to. As a per-document cache, it needs approval.

## Proposed solution

### Shape

- **Compiler** (`src/common/`): pure analysis, with no
  editor state.
- **Language server** (`src/lsp/`): four pure modules.
  - `protocol`: framing, and JSON-RPC to and from `Json`.
  - `positions`: byte offsets to and from LSP positions.
  - `tokens`: semantic-token encoding.
  - `server`: open documents, one step per message.
- **Transport** (`src/main.brp`), the only impure code: read, step, analyse
  on request, write.
- **Editor plugin** (`editor/intellij/`): it launches `blorp lsp`.

### Analysis without an entry point

`check` splits in two.

- **`analyze`** checks declarations and bodies, and records a missing entry
  function as a fact.
- **`check`** runs `analyze`, then requires the entry function. A present
  `main` is still validated in full.

The analysis holds `Option[Entrypoint[FunctionId]]`, and `CheckedProgram`
holds `Entrypoint[FunctionId]`, so the types keep the cases apart.
`MissingMain` is unchanged.

### Comments as lexer output, and lexing past an error

The lexer records each comment where it consumes one:

- `code_comment_end` (`src/common/syntax/lex.brp:1119`), reached from 1012 and
  1846;
- `next_code_line` (1249);
- `doc_block_end` (1196).

The list is threaded through the scanners' results and returned beside the
tokens. Each entry is a span and a `documentation` flag. The parser never
sees it.

`source_trivia` takes the list instead of scanning gaps for comments; it
still finds blank lines in the gaps. Its "text outside every token" check
now admits only blanks and listed comments. `Trivia` and the formatting
rules are unchanged, so formatter output is byte-identical.

A failed lex returns its prefix as a `LexedProgram`. The failure path runs
the single `intern_names` pass over the tokens finished before the error.
Tokens inside a half-scanned string, interpolation or pipe string are
dropped. The loader and the formatter use only the diagnostic.

### The occurrence table

Analysis records one row per name written in source: the name's span, the
definition's name span, and the kind.

**Coverage.** Rows cover:

- functions, trait methods, UFCS calls;
- constants, locals and parameters;
- types and type parameters;
- fields, in access, update, construction and patterns;
- variants and traits;
- import-list entries;
- names inside `${…}`.

A definition records a row with both spans equal. Synthesised names (derived
equality, the test wrapper) get no row.

**Where rows are recorded.**

- `namespace` records import entries (`import_row`,
  `src/common/analysis/namespace/namespace.brp:1058`).
- `check` records the rest.

So `Occurrence` lives in a new `src/common/analysis/occurrences.brp`. It is a
`fixed record` with a payload-free `fixed union` kind, so rows are stored
inline with no allocation each.

**Identity.** The definition's name span is the identity: every definition
has one, locals have nothing else, and it is what go-to-definition returns.
The server compares paths and byte ranges, never `SourceId`s, which differ
between loads.

**Rejected:** re-resolving names in the server (it duplicates the checker),
and `FunctionId`-keyed rows (locals have no id).

### The console

`io/console` keeps `print` and `print_error`, and gains:

- `write` and `write_error`, which write text as given;
- `flush`;
- `read_line`;
- `read_exact(byte_count)`.

**Flushing.** Every read flushes standard output first, as Python's `input`
does. So a prompt shows before the program
waits, and the server's write-then-read loop needs no extra call. `flush`
covers output that no read follows.

**`read_line`** drops LF or CRLF, as `fold_lines` does. A last line without
LF is returned as is.

**`read_exact`** returns:

- `None` only when input has already ended;
- `Some("")` for a count of zero or less;
- an error when input ends part-way.

Both reads share one buffer. Input that is not UTF-8 is an error. Each read
has its own exact error union (`PATH_PLAN.md`), designed with the Bytes
session and implementing `Stringable`.

**Rejected:**

- `print(text, ending = "")`, which needs named optional arguments;
- dropping `print`'s newline, which breaks every call site;
- `read_text(n)`, which reads as characters and clashes with
  `fs.read_text(path)`.

### The server

**Initialization.**
- **Positions.** The server picks UTF-8 if the client offers it in
  `general.positionEncodings`, and UTF-16 otherwise. It echoes the choice.
- **Capabilities.** It announces full sync, definition, references, and
  full semantic tokens with a legend.
- **Line breaks.** `positions` accepts `\n`, `\r\n` and a lone `\r`, as the
  protocol requires.

**Analysis on demand.**
- `didOpen` and `didChange` store the text and mark every open document
  stale, since any may import the changed one; `didOpen` analyses at once.
- A request on a stale document first analyses the program rooted there,
  with every open document as a snapshot.
- So a burst of edits followed by one request costs one analysis.

**Diagnostics.** Each analysis publishes diagnostics:
- to every file it reports in, open or not;
- as `[]` to every file it reported in last time but not now.

The latest analysis wins when two roots share a file. Library files are
never published. URIs are percent-encoded.

**The library on disk.**
- The server runs inside
  `fs.with_temporary_directory("/tmp", "blorp-lsp-", …)`.
- At startup it writes each module named in the generated
  `EMBEDDED_LIBRARY_PATHS` there.
- It analyses with `LibraryDirectory(folder)`, so library spans carry real
  paths.
- A killed server leaves the folder behind. `/tmp` is a named constant: all
  supported platforms are POSIX.

**Semantic tokens.**
- **From the lexer:** keywords, comments, strings, numbers and operators.
- **From occurrences:** functions, methods, types, variants, fields,
  parameters, locals, type parameters, traits and module aliases, only at
  the lexer's identifier tokens. Equal spans add `declaration`.
- **Standard names:** only the protocol's token types and modifiers.
- **No overlap:** string pieces are already separate lexer tokens that stop
  at `${`, so no token overlaps another.
- **Multiline tokens** are always split per line.

**Broken files** (open decision 4). When analysis fails, the server keeps
the last successful analysis and its text, and maps rows onto the new text:
- A row inside the common prefix of the old and new text keeps its spans.
- A row inside the common suffix shifts by the change in length.
- A row that touches the change is dropped.
- A `definition` in the edited file maps the same way.

**Definition** returns the definition of the row at the position, or `null`
if there is none. A position at an identifier's end counts as inside it.

**References** returns every row with that definition. It includes the
declaration only on request.

**Lifecycle.**
- `shutdown` returns `null`.
- `exit` ends with status 0 after `shutdown`, and 1 otherwise. End of input
  without `exit` also ends with 1.
- Requests before `initialize` get -32002, unknown requests -32601, and
  invalid JSON -32700.
- Unknown notifications and cancellations are ignored.

### v1 limitation: the open file is the root

**What works.**
- Go-to-definition reaches any definition in the open file's program: the
  file itself, its imports, and the library.
- References cover that same program.

**What doesn't.**
- References from modules that import the file are missed. Asked in
  `src/common/syntax/lex.brp`, references to `lex` miss
  `src/common/analysis/load/load.brp:526` and `src/format/format.brp:1030`.
- Rows that touch an edit stay missing until the file analyses again, and an
  edit's errors appear with the next request.

**How it lifts.** A landing after v1 has the plugin pass the workspace's
roots (such as `blorp/src/main.brp`) in `initializationOptions.roots`.
References then cover every root's program. Once packages exist (`pkg/`), a
manifest supplies the roots instead. Until then the README documents the
limitation.

### Later

- Lexing resumes after an error, if colour below an unclosed string is
  missed.
- Incremental sync and cancellation, if latency exceeds its ceilings.
- More errors per phase, hover, and `TMPDIR`.

## Code

**Analysis without `main`.** Today the missing entry is an error inside
signature checking (`src/common/analysis/check/signatures.brp:176`):

```blorp
    entrypoint: Option[FunctionId] = match namespace.named_value(
        root_module_id(),
        parsed.entrypoint,
    ):
        Some(NamedFunction(id, DeclaredHere)): Some(id)
        _: None
    headers ?= parsed.implementation_headers(namespace)
    functions ?= parsed.accept_functions(namespace, designated, entrypoint, headers, contracts, [])
    id: FunctionId ?= match entrypoint:
        Some(present): Ok(present)
        None: Err(signature_error(parsed.end, MissingMain))
```

and `check` is the only entry point (`src/common/analysis/check/check.brp:189`):

```blorp
pure func check(program: ParsedProgram) -> Result[CheckedProgram, CheckFailure]:
    program.check_program()
```

After the change (the implementer chooses the internal names):

```blorp
-- Declarations and bodies, checked; the entry function is optional. What an
-- editor analyses.
pure func analyze(program: ParsedProgram) -> Result[Analysis, CheckFailure]:
    program.analyze_program()


-- What `compile` needs: an analysis whose root declares the entry function.
pure func check(program: ParsedProgram) -> Result[CheckedProgram, CheckFailure]:
    analysis ?= program.analyze()
    match analysis.entrypoint:
        Some(entrypoint): Ok(analysis.checked_program(entrypoint))
        None: Err(program.missing_main(analysis))
```

**Comments.** Today `LexedProgram` (`src/common/syntax/syntax.brp:246`) has no
comments, and `lex` (`src/common/syntax/lex.brp:1717`) fails with a bare
`Diagnostic`:

```blorp
record LexedProgram {
    source_text: String,
    tokens: List[Token],
    end: Span,
    base_names: NameTable,
    names: NameTable,
}

pure func lex(
    origin: SourceId,
    source: String,
    names: NameTable,
) -> Result[LexedProgram, Diagnostic]:
```

The formatter recognises `--` a second time (`src/format/trivia.brp:185`):

```blorp
            else if and(source.byte_is(cursor, MINUS_BYTE), source.byte_is(cursor + 1, MINUS_BYTE)):
                comment_end = source.line_end(cursor)
                if and(source.line_start(cursor) == cursor, source.fence_at(cursor)):
                    end = source.documentation_end(cursor)
```

After the change:

```blorp
-- A comment the lexer read: `--` to the end of its line, or a whole `---`
-- block from its opening fence to the end of its closing fence.
fixed record Comment {
    span: Span,
    documentation: Bool,
}

record LexedProgram {
    source_text: String,
    tokens: List[Token],
    comments: List[Comment],
    end: Span,
    base_names: NameTable,
    names: NameTable,
}

-- The first error, and everything lexed before it, so an editor can still
-- colour the file.
record LexFailure {
    error: Diagnostic,
    prefix: LexedProgram,
}

pure func lex(
    origin: SourceId,
    source: String,
    names: NameTable,
) -> Result[LexedProgram, LexFailure]:
```

`source_trivia` gains a `comments` parameter. It sorts each comment into
`DocumentationBlock`, `TrailingComment` or `OwnLineComment` by today's rules,
and `fence_at` and `documentation_end` move out of `trivia.brp`.

**The occurrence table** (`src/common/analysis/occurrences.brp`):

```blorp
-- A name written in source, and the definition it resolved to.
fixed record Occurrence {
    span: Span,
    -- The definition's name span: the entity's identity, and where go-to
    -- lands. Equal to `span` at the definition itself.
    definition: Span,
    kind: NameKind,
}

fixed union NameKind:
    FunctionName
    TraitMethodName
    ConstantName
    LocalName
    ParameterName
    TypeName
    TypeParameterName
    TraitName
    FieldName
    VariantName
    ModuleAliasName
```

For `check` above, the rows are:

- `check`: a definition (`FunctionName`);
- `program`: a definition (`ParameterName`);
- `ParsedProgram`, `Result`, `CheckedProgram`, `CheckFailure`: uses
  (`TypeName`);
- `program`: a use of the parameter;
- `check_program`: a use (`FunctionName`).

**The console.** Today all of `standard_library/io/console.brp` is:

```blorp
func print(value: String) -> Void:
    builtin("string.print")


func print_error(message: String) -> Void:
    builtin("string.print_error")
```

The additions, for ergonomics review:

```blorp
-- The text exactly as given; no newline is added.
func write(text: String) -> Void
func write_error(text: String) -> Void
-- Sends buffered standard output now. Every read does this first.
func flush() -> Void
-- The next line without its LF or CRLF; a last line with no LF as it is;
-- None once input has ended.
func read_line() -> Result[Option[String], ReadLineError]
-- Exactly `byte_count` bytes as text; None once input has ended; Some("")
-- for a count of zero or less; an error if input ends part-way.
func read_exact(byte_count: Int) -> Result[Option[String], ReadExactError]
```

A first-time user's prompt needs no flush:

```blorp
import:
    io/console: write, read_line


func main() -> Int:
    write("Name: ")
    match read_line():
        Ok(Some(name)):
            print("Hello, ${name}")
            0
        Ok(None):
            0
        Err(error):
            print_error("could not read standard input: ${error}")
            1
```

**The server step** is pure. When a request needs an analysis, the server
holds it pending; the transport analyses, then calls `analysed`, which
answers it:

```blorp
-- src/lsp/server.brp
record Step {
    server: Server,
    replies: List[Json],
    -- The open document to analyse before the pending request can be answered.
    analyse: Option[String],
}

pure func receive(server: Server, message: Json) -> Step

pure func analysed(server: Server, path: String, result: DocumentAnalysis) -> Step
```

**`Command`** (`src/cli.brp:42`) gains a case, and the overview text
(`src/cli.brp:71`) gains a line:

```blorp
union Command:
    Compile(CompileRequest)
    Format(FormatRequest)
    LanguageServer
    Help(String)
```

## Scope and non-goals

**May touch:**
- `src/common/syntax/` and `src/format/`;
- `src/common/analysis/{check,namespace,load}/`, for the analysis product and its
  rows;
- new code: `src/common/analysis/occurrences.brp` and `src/lsp/`;
- `src/cli.brp` and `src/main.brp`;
- `io/console`, the runtime and the builtin tables;
- `editor/`, the README and the tests.

**Not:** completion, hover, rename, formatting through the server, TextMate,
threads, incremental analysis, `Bytes` input, or grammar changes.

**Concurrent work:**
- **The Bytes session's `PATH_PLAN.md` landings** edit the same builtin
  tables and `io/`. Coordinate before landings 5 and 7.
- **The String plan's breaking switch:** whichever lands second migrates the
  other's `length` and `slice` uses.

## Risks and unknowns

- **Can occurrences always be recorded?** The landing 4 spike answers this.
  A one-day spike on a scratch branch records rows for the whole compiler.
  It measures a stage-2 self-compile as `STRING_PLAN.md` describes, and
  reports rows per line and lines per file. The ceilings decide.
- **Do semantic tokens alone colour a file in CLion?** JetBrains doesn't say.
  - The plugin landing probes this first, with a stub server.
  - It also probes how the client treats `null` and error replies.
  - If nothing colours, stop and ask: VS Code first, or a plugin lexer,
    which would reopen the TextMate decision.
- **Bootstrap.** A library call to a `builtin` label the seed lacks stops
  the seed parsing the library (`src/common/syntax/parse.brp:4439`). That breaks
  every seed-built target. So the console labels land alone, a rotation
  follows, and only then come the library functions.
- **Latency.** Analysing `blorp/src/main.brp` (72,000 lines) may be slow;
  the ceilings bound it.

## Dependencies

- Landing 4 follows landing 1.
- Landings 5, 6 and 7 go strictly in order.
- Landing 7 needs Keith's console answer and Bytes timing; landing 8, his
  answer on decision 4.
- Landing 8's pure modules follow landings 1, 3 and 4. Its transport follows
  landing 7.
- Landing 9 needs the editor choice.

## Release strategy

Each landing is one squashed commit, gated and reviewed on its own. A revert
backs it out; for landing 6, re-pinning the previous seed does.

1. **Analysis without an entry point.**
2. **Comments as lexer output.** Formatter output stays byte-identical.
3. **The lexer keeps its prefix on failure.**
4. **The occurrence table.** The spike comes first.
5. **Console labels.** Builtin labels, runtime and emission, with no library
   change.
6. **Seed rotation.** This is `PATH_PLAN.md`'s landing 5 if that comes after
   ours; otherwise a plain rotation.
7. **The `io/console` functions.** After ergonomics review and Keith's
   approval.
8. **`blorp lsp`.** The `src/lsp/` modules, which can be built during
   landings 5 to 7; the transport; and the README section with the v1
   limitation.
9. **The editor plugin.**

**Ceilings** are measured against the parent commit, as a stage-2
self-compile unless stated, with production and test lines counted
separately. Compile-cost changes must also fit the 15% margin of the e2e
instruction ceilings (`72d65fd7a`).

| Landing | Instructions | Allocations | Peak heap | Production lines |
| --- | --- | --- | --- | --- |
| 1 analysis | ≤ +0.2% | ≤ +0.05% | ≤ +0.1% | ≤ +80 net |
| 2 comments | ≤ +0.5%, and formatting the repository ≤ +0.5% | ≤ +0.3% | ≤ +0.3% | ≤ +60 net |
| 3 prefix | ≤ +0.1% | ≤ +0.01% | ≤ +0.1% | ≤ +60 net |
| 4 occurrences, always recorded | ≤ +1% | ≤ +0.5% | ≤ +0.5% | ≤ +600 net |
| 4 occurrences, on request | compile path ≤ +0.2% | ≤ +0.01% | ≤ +0.1% | ≤ +650 net |
| 5 console labels | ≤ +0.1% | ≤ +0.01% | ≤ +0.1% | ≤ +150 net |
| 7 console functions | ≤ +0.1% | ≤ +0.01% | ≤ +0.1% | ≤ +60 net |
| 8 server | ≤ +3% (more source to compile) | ≤ +3% | ≤ +3% | ≤ +2,000 |

**Latency.** Per request after one change, on this host: ≤ 1.0 s for
`blorp/src/main.brp`, and ≤ 50 ms for a one-module program. Landing 1
reports `analyze`'s one-shot time on `main.brp` as the baseline.

## Testing

Each landing starts with a failing test.

| Landing | Tests |
| --- | --- |
| 1 | `test/unit/test_common/test_analysis/test_check/`. A module without `main` analyses, and `check` of it reports `MissingMain` with the exact message, help and span. A malformed `main` fails both. |
| 2 | `test/unit/test_common/test_syntax/test_lex/`: one case per comment site. Formatter suites are unchanged, and formatting the repository changes nothing. |
| 3 | An unclosed string keeps the tokens before it and drops its own. The loader's diagnostic is unchanged. |
| 4 | One case per name kind, checking both spans. Mutation proof: stop recording one kind, and only its case fails. |
| 5 | Direct C tests of the natives, under `test/runtime/`. |
| 7 | e2e programs driven through `capture`: LF and CRLF, a final line without LF, header and body in one chunk, a short `read_exact`, a count of zero, invalid UTF-8, and `write` output appearing before a read. |
| 8 | `test/unit/test_lsp/`: framing; positions for `é`, an astral emoji and `\r`; token splitting; lifecycle errors; broken-file mapping; each request through `receive`. An e2e session in `self_hosted_cli.brp` (new `process` import and overview text) runs `initialize` through `exit` and checks the replies, the diagnostic and status 0. Input that ends without `exit` gives status 1. |
| 9 | A manual checklist in the plugin's README. |

**Commands:**
1. `make -C blorp test-target-components TARGET_COMPONENT_SOURCES=<suite>`, to
   iterate;
2. `make -C blorp test`;
3. `scripts/blorp-fixpoint --prove`, for compiler landings;
4. `make -C blorp test-e2e INSTRUCTION_CHECK=on`, for changes in compile
   cost.

## Acceptance criteria

- [ ] **1.** A module without `main` analyses, and `blorp compile` of it
  prints the unchanged `MissingMain`.
- [ ] **2.** `make -C blorp format-check` passes, formatter expectations are
  unchanged, and only the lexer recognises comments.
- [ ] **4.** Every name kind passes. The spike's numbers and the chosen form
  are in `benchmarks/results/`.
- [ ] **6.** `scripts/blorp-fixpoint --prove` passes with the new seed.
- [ ] **7.** The console e2e programs pass on all four CI platforms.
- [ ] **8.** The e2e replies match exactly. Definition on `print` returns a
  file in the temporary folder, and the folder is gone after `exit`.
  Latency is within ceiling.
- [ ] **9.** The chosen editor colours a file even while it has an error, and
  definition and references work, including into the library.
- [ ] **Every landing** meets its ceilings, passes `make -C blorp test`, and
  is reviewed and test-run.

## Handback

Each landing returns:
- its branch and commit;
- evidence per criterion;
- measurements with raw-sample paths;
- anything it found but did not fix.

Stop and ask the coordinating session if:
- a ceiling is exceeded;
- CLion shows no colour;
- an occurrence needs information the checker has already discarded;
- the console errors conflict with the Bytes session's design.

Changes to the console API go to Keith.
