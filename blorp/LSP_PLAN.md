# Language server: `blorp lsp`

**Status: plan, 2026-11-10; Keith settled its decisions and asked for a byte
console on 2026-11-11. Landings 1–11 have landed; 12, the plugin on LSP4IJ,
is in progress; 13 is planned and awaits Keith's approval.**

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

(`src/common/cli/usage.brp:18`; 2 is `EXIT_USAGE`.)

We want a `blorp lsp` that speaks the Language Server Protocol over standard
input and output, launched by a minimal editor plugin. Keith's priorities
are highlighting, then go-to-definition, then find-references.

## Background

**Keith decided on 2026-11-10:** a `blorp lsp` subcommand; one loop and
whole-program analysis to start; semantic tokens only, with no TextMate
grammar; comments as lexer output; a limited v1 root, documented; library
go-to through a temporary folder; the cleanest rotation path; and an
ergonomic way to write without a newline (not `put`).

**On 2026-11-11:** CLion first; name uses always recorded;
broken files served from the last good analysis, after the plugin; and the
console reworked "to work with bytes", for the LSP. Keith then approved
the byte console as below, with read flushing and the closed-pipe rule.

**What exists:** the `json` codec; loader source snapshots
(`load_program_with_sources`, `analysis/load/load.brp:823`); the embedded
library; byte-range spans on every token (`syntax/syntax.brp:8`); and
process `capture`, which can feed standard input.

**What was missing**, which landings 1–8 supplied: analysis without `main`,
recorded name uses, comments as lexer tokens, a failed lex's prefix, and a
console that reads and writes without a newline.

**On 2026-11-21:** a line diff for broken files, and the plugin on LSP4IJ,
whose `workspace/textDocumentContent` lets landing 13 drop the folder.

**Related plans:** `STRING_PLAN.md` moves byte work to `byte_*` functions,
and the README's naming rules and the library's exact-error convention apply here.

## Proposed solution

### Shape

- **Compiler** (`src/common/`): pure analysis, with no editor state.
- **The `lsp` command** (`src/lsp/`), a command directory like `compile/`:
  - `protocol`: framing, and JSON-RPC to and from `Json`;
  - `positions`: byte offsets to and from LSP positions;
  - `tokens`: semantic-token encoding;
  - `server`: open documents, one step per message;
  - `lsp_command.brp`: the help text and the transport, the only impure code
    (read, step, analyse on request, write).

  The layer suite (`test/test_layout/test_dependencies.brp`) gains an
  `lsp/` layer that imports itself and `common/`. `main.brp` dispatches
  `lsp` there.
- **CLion plugin** (`editor/intellij/`): it launches `blorp lsp` through
  LSP4IJ (landing 12). Landing 10's plugin used CLion's own LSP API, which
  needed three workarounds.

### Analysis without an entry point

`check` splits in two. **`analyze`** checks declarations and bodies, and
records a missing entry function as a fact. **`check`** runs `analyze`, then
requires the entry function; a present `main` is still validated in full.
The analysis holds `Option[Entrypoint[FunctionId]]`, and `CheckedProgram`
holds `Entrypoint[FunctionId]`, so the types keep the cases apart.
`MissingMain` is unchanged.

### Comments as lexer output, and lexing past an error

The lexer records each comment where it consumes one:

- `code_comment_end` (`src/common/syntax/lex.brp:1183`), reached from 1077 and
  1911;
- `next_code_line` (1313);
- `doc_block_end` (1260).

The list is returned beside the tokens, and the parser never sees it.
`source_trivia` takes it instead of scanning gaps for comments; it still
finds blank lines there. `Trivia` and the formatting rules are unchanged, so
formatter output is byte-identical.

A failed lex returns its prefix as a `LexedProgram`: the failure path runs
the one `intern_names` pass over the tokens finished before the error.
Tokens inside a half-scanned string, interpolation or pipe string are
dropped. The loader and the formatter use only the diagnostic.

### Name uses, keyed by identity

The compiler establishes each declaration once, under an identity its
tables join to the written name:
- the ordinals in `analysis/ids.brp`, such as `FunctionId`;
- `TraitMethodId`, `VariantId`, `FieldId`, `TypeParameterId`, `ModuleId`;
- `TypeHead` (`namespace/namespace.brp:62`) for a type, built-in or declared;
- `ScopedBindingId` for parameters and locals (`check/model.brp:633`), whose
  `BindingDefinition` (`:703`) holds the span and mutability.

What is missing is the use. Analysis records one new fact per name used: a
`NameUse`, its span and its `Referent`, the identity the checker resolved it
to. The rest are joins:
- **go-to:** `declaration_span(analysis, referent)`;
- **references:** every use with an equal referent;
- **token type:** the referent's case;
- **modifiers:** `declaration` for the declarations themselves, read from
  the declaration tables; `readonly` for an immutable binding or a constant;
  `defaultLibrary` for anything the library declares.

**Coverage:** functions, trait methods and UFCS calls; constants, locals
and parameters; types and type parameters; fields, in access, update
and construction; variants, traits and module aliases; import-list
entries; and names inside `${…}`. Synthesised names (derived equality, the
test wrapper) get none.

**Declarations without a written name.** A built-in type such as `Int` has
none, so go-to returns `null`. A module's declaration is the start of its
file. A trait's `Self` resolves to the trait's name.

**Where.** `check`'s body walk always records uses, in a new
`check/name_uses.brp`, because fields, type parameters and bindings are
Check's identities. Import selections name only declarations, which
`namespace` resolves (`import_row`, `namespace/namespace.brp:1058`) but
keeps no spans for. It gains a table of
each selection's span and entity, which `check` turns into uses.

**Inline rows.** `NameUse` is a `fixed record` over a `fixed union`, so rows
take no allocation each. Seven plain types that already qualify become
`fixed`: `TypeHead` and `PrimitiveType` in `namespace/`, and
`TypeParameterIdentity`, `TypeParameterOwner`, `ScopedBindingId`,
`BodyOwner` and `AggregateId` in `check/model.brp`. `FieldId` gains the
`Equatable` that `Referent`'s `==` needs.

**Across analyses**, the server compares a declaration's path and byte
range, never ids or `SourceId`s.

**Rejected:** copying the declaration's span into each row, a
kind tag, and re-resolving names in the server. Each duplicates a
fact the compiler owns, and copies can disagree.

### The console

Standard streams carry bytes and the protocol counts them, so the new
console functions take and return `Bytes`, and `print` and `print_error` stay
for text lines:

- `write` and `write_error`, with no newline added;
- `flush`;
- `read_line`, without its LF or CRLF, as `fold_lines` drops them;
- `read_exact(byte_count)`, which fails if input ends part-way.

**Text at the edge.** No console function decodes, so neither read's exact
error union has a content case. The transport encodes each reply once,
counting those bytes for its header, and decodes each body once, answering
-32700 if it is not UTF-8.

**Buffers.** `print` and `write` share standard output's buffer, so their
order holds; both reads share standard input's. Every read flushes standard
output first, as Python's `input` does, so a prompt shows before the program
waits. `flush` covers output that no read follows.

**Text programs** convert at the edge too; text forms wait for a consumer.

**Rejected:** `print(text, ending = "")` (named optional arguments),
dropping `print`'s newline (breaks every call), and `read_bytes(n)` and
`write_bytes(data)`, which clash with `io/files`'s.

### The server

**Initialization.** The server picks UTF-8 positions if the client offers
them, and UTF-16 otherwise, and echoes the choice. It announces full sync,
definition, references, and full semantic tokens with a legend. `positions`
accepts `\n`, `\r\n` and a lone `\r`, as the protocol requires.

**Analysis on demand.**
- The server keeps, per root, the files its analysis read (the loader's
  `SourceInputs`).
- `didOpen`, `didChange`, `didClose` (reverting to disk) and watched
  `**/*.brp` changes stale every root that read the file, and every root
  whose load failed, since a missing file may now exist.
- `didOpen` analyses at once. A request on a stale document first analyses
  its program, with open documents as snapshots, so a burst of edits costs
  one analysis.

**Diagnostics** refresh with each analysis, so an edit's errors wait for the
next request. Each analysis publishes to every file it reports in,
and `[]` to every file it reported in last time but not now. A shared file
shows the latest analysis's. Library files are never published; URIs are
percent-encoded.

**Library files.** Analyses read the embedded library. Landing 9c wrote it to
a folder in `/tmp` for an editor to open; landing 13 drops the folder, its
shutdown order and 9c's open folder items.
- **URIs.** A library location is a hierarchical URI with no authority, such
  as `blorp-library:///io/console/output.brp`: the file's path below the
  library root, percent-encoded as `file_uri` does. `uri_path` reads only
  `file:` URIs, so a decoder joins it, and open library files are keyed by
  that path. `didOpen` tells a library file by its scheme, and `targets`
  picks the URI by the module's role. A diagnostic about a library file names
  that path.
- **Capability.** When the client's `workspace.textDocumentContent` object is
  present, `initialize` answers `capabilities.workspace.textDocumentContent =
  { schemes: ["blorp-library"] }`. Otherwise library entries are left out of
  definitions and references, and the README names the LSP 3.18 client this
  needs.
- **Content.** `workspace/textDocumentContent` answers the embedded file's
  text, found by table lookup, so `..` reaches nothing; any other URI gets
  -32602. The text never changes, so no refresh is sent, and ranges index the
  embedded text.
- A library file the client opens gets the lexer's tokens and nothing else.
  `shutdown` replies at once.

**Semantic tokens.** Keywords, comments, strings, numbers and operators
come from the lexer. Identifier tokens take their type and modifiers from
name uses and the declaration tables. Only the protocol's standard types and
modifiers are used. String pieces are separate lexer tokens that stop at
`${`, so no token overlaps another, and multiline tokens are split per line.

**Broken files.** In landing 9, while a root fails to analyse, its files
get only the lexer's tokens (the prefix, if lexing failed), definition
returns `null` and references `[]`. Landing 11 then keeps the root's
last analysis that checked, sealed with the texts it read. A line diff (Keith,
2026-11-21, in place of one edit window) matches each file's lines then and
now: a position on an unchanged line moves with its line, and one on an
inserted, deleted or edited line finds nothing. Requests map back through
their file's diff, and answers forward through theirs. A file's text now is
its open document's, else the latest analysis's, else the sealed one's,
unless a change to it was reported since.

**Definition** returns the declaration of the use at the position, or
`null`. A position at an identifier's end counts as inside it. From landing
13 it is a plain `Location`: only CLion's own client read a link's origin.

**References** returns every use with that referent. It includes the
declaration only on request. Analysis checks a library body only when the
program can reach it (`LIBRARY_COST_PLAN.md`, option (b), approved
2026-11-16), so uses inside library bodies the program never reaches are not
recorded and references omit them; Keith accepted that on 2026-11-16.

**Lifecycle.** `shutdown` returns `null`. `exit` ends with status 0 after
`shutdown` and 1 otherwise, as does end of input without `exit`, even
mid-header. Requests before `initialize` get -32002, unknown requests
-32601, invalid JSON -32700. Unknown notifications and cancellations are
ignored.

### v1 limitation: the open file is the root

Go-to and references cover the open file's program: the file, its imports
and the library, not importers. The README documents this. A later
landing has the plugin pass the workspace's roots in
`initializationOptions.roots`, and once packages exist a manifest does.

### Later

- Lexing resumes after an error, if colour below an unclosed string is
  missed.
- Incremental sync and cancellation, if latency exceeds its ceilings.
- More errors per phase, and `TMPDIR`.
- More facts as features need them: declaration extents, attached
  documentation, binding scopes, a reverse import graph, a position index.
- One line-start table for `positions` and `common/cli/report.brp`.

## Code

**Analysis without `main`.** Today the missing entry is an error inside
signature checking (`src/common/analysis/check/signatures.brp:179`):

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

**Comments.** Today `LexedProgram` (`src/common/syntax/syntax.brp:258`) has no
comments, and `lex` (`src/common/syntax/lex.brp:1781`) fails with a bare
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

**Name uses** (`src/common/analysis/check/name_uses.brp`):

```blorp
-- What a name used in source resolved to: an identity the compiler already
-- owns. `declaration_span` joins it to where it is declared.
fixed union Referent:
    FunctionReferent(FunctionId)
    TraitMethodReferent(TraitMethodId)
    ConstantReferent(ConstantId)
    -- A record, union or opaque type, or a built-in one such as `Int`.
    TypeReferent(TypeHead)
    TraitReferent(TraitId)
    FieldReferent(FieldId)
    VariantReferent(VariantId)
    TypeParameterReferent(TypeParameterId)
    BindingReferent(ScopedBindingId)
    ModuleReferent(ModuleId)


-- One name used in source. Declarations are not uses: the declaration tables
-- already hold them.
fixed record NameUse {
    span: Span,
    referent: Referent,
}


-- Where go-to lands: the referent's written name, a module's first byte, or
-- None for a built-in type.
pure func declaration_span(analysis: Analysis, referent: Referent) -> Option[Span]


-- Every referent the analysis declares, for colouring declarations.
pure func declarations(analysis: Analysis) -> List[Referent]
```

Today's `check` (above) records six uses: `ParsedProgram`, `CheckedProgram`
and `CheckFailure` (`TypeReferent` of an `OpaqueHead`), `Result` (of a
`UnionHead`), `program` (`BindingReferent`) and `check_program`
(`FunctionReferent`).

**The console**, reviewed for ergonomics, in one module per error type:

```blorp
-- io/console/output.brp, beside print and print_error.
-- The bytes exactly as given; no newline is added. Output a closed pipe
-- refuses is dropped, under the SIGPIPE guard `capture` already uses, so a
-- client that has gone does not end the program.
func write(data: Bytes) -> Void
func write_error(data: Bytes) -> Void
-- Sends buffered standard output now. Every read does this first.
func flush() -> Void


-- io/console/read_line.brp. Each read has its own exact error union, as the
-- library's convention requires; variant names are unique within a module, so
-- each union has its own module. Both implement Stringable.
fixed union ReadLineError:
    -- EISDIR: standard input is a directory.
    IsADirectory
    -- Any other errno, such as EIO or EBADF.
    OtherOs(Int)


-- Bytes, unlike `io/files`'s String line functions: those before the next LF,
-- without it or a CR just before it (a lone CR stays). A last line with no
-- LF comes as it is; None once input has ended.
func read_line() -> Result[Option[Bytes], ReadLineError]


-- io/console/read_exact.brp.
fixed union ReadExactError:
    -- Input ended after this many of the bytes asked for.
    EndedEarly(Int)
    IsADirectory
    OtherOs(Int)


-- Exactly `byte_count` bytes. A count of zero or less gives Some(empty)
-- without reading; None means input ended before the first byte. Bytes are
-- held only as they arrive, so a large count costs only the input received.
func read_exact(byte_count: Int) -> Result[Option[Bytes], ReadExactError]
```

The transport counts and sends the same bytes:

```blorp
import:
    bytes: Bytes, String methods
    io/console/output: write, flush
    json: Json, render


-- One message: a header counting the body's UTF-8 bytes, then the body.
func send(message: Json) -> Void:
    body: Bytes = message.render().to_bytes()
    write("Content-Length: ${body.length()}\r\n\r\n".to_bytes() + body)
    flush()
```

A text prompt converts once each way, and needs no flush:

```blorp
import:
    bytes: Bytes, String methods
    io/console/output: write
    io/console/read_line: read_line


func main() -> Int:
    write("Name: ".to_bytes())
    match read_line():
        Ok(Some(line)):
            match line.to_text():
                Some(name): print("Hello, ${name}")
                None: print_error("the name is not UTF-8")
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
    analyse: Option[Path],
}

pure func receive(server: Server, message: Json) -> Step

pure func analysed(server: Server, root: Path, result: DocumentAnalysis) -> Step
```

**`Command`** (`src/main.brp:15`) gains a case, and the overview text
(`src/main.brp:24`) gains a line:

```blorp
union Command:
    Compile(CompileRequest)
    Format(FormatRequest)
    LanguageServer
    Help(String)
```

## Scope and non-goals

**May touch:** `src/common/syntax/`, `src/format/`,
`src/common/analysis/{check,namespace,load}/`, the new `src/lsp/`,
`src/main.brp` (the `Command` case and overview), `io/console`, the runtime,
the builtin tables, `editor/`, the README and the tests.

**Not:** completion, hover, rename, formatting through the server, TextMate,
threads, incremental analysis, or grammar changes.

**Concurrent work:** of the String plan's breaking switch and this work, whichever lands second migrates
the other's `length` and `slice` uses.

## Risks and unknowns

- **Does LSP4IJ open a `blorp-library:` file as Blorp?** Landing 13 checks
  that first, through the plugin's headless tests: the editor's file type,
  its tokens and its `didOpen`.

## Dependencies

- Landing 11 follows 10, and 13 follows 12, since only LSP4IJ opens a
  `blorp-library:` file.

## Release strategy

Each landing is one squashed commit, gated and reviewed on its own. A revert
backs it out; for landing 7, re-pinning the previous seed does.

1. **Analysis without an entry point.**
2. **Comments as lexer output.** Formatter output stays byte-identical.
3. **The lexer keeps its prefix on failure.**
4. **Fixed identities:** the seven types become `fixed`.
5. **Name uses**, always recorded.
6. **Console labels:** builtin labels, runtime and emission, no library.
7. **Seed rotation**, pinning `blorp-seed-4fee244ad96f`.
8. **The `io/console` functions.**
9. **`blorp lsp`**, in three landings (Keith, 2026-11-17): **9a** the
   command, transport, lifecycle, positions, open documents and diagnostics;
   **9b** semantic tokens, staleness and watched files; **9c** definition,
   references and the library on disk.
10. **The CLion plugin.**
11. **Broken files** served from the last good analysis.
12. **The plugin on LSP4IJ** (Keith, 2026-11-21).
13. **Library files through `workspace/textDocumentContent`**, and plain
    `Location`s.

**Ceilings** are against the parent commit, on
`blorp/scripts/self-compile-cost`'s own-source rows unless stated, with test
lines counted apart. Compile cost must also fit the e2e instruction ceilings'
15% margin.

| Landing | Instructions | Allocations | Peak heap | Production lines |
| --- | --- | --- | --- | --- |
| 1 analysis | ≤ +0.2% | ≤ +0.05% | ≤ +0.1% | ≤ +80 net |
| 2 comments | ≤ +0.5%, and formatting the repository ≤ +0.7% | ≤ +0.32% | ≤ +0.3% | ≤ +60 net |
| 3 prefix | ≤ +0.1% | ≤ +0.05% | ≤ +0.1% | ≤ +60 net |
| 4 fixed identities | ≤ +0.1% | no increase | ≤ +0.1% | ≤ +20 net |
| 5 name uses, fixed input | ≤ +1% | ≤ +0.6% | unchanged | ≤ +1,320 net |
| 6 console labels, fixed input | ≤ +0.1% | ≤ +0.01% | ≤ +0.1% | ≤ +280 net |
| 8 console functions, fixed input | ≤ +0.1% | ≤ +0.01% | ≤ +0.1% | ≤ +170 net |
| 9a server core, fixed input | ≤ +0.1% | ≤ +0.01% | ≤ +0.1% | ≤ +1,350 net |
| 9b semantic tokens, fixed input | ≤ +0.1% | ≤ +0.01% | ≤ +0.1% | ≤ +780 net |
| 9c navigation, fixed input | ≤ +0.1% | ≤ +0.01% | ≤ +0.1% | ≤ +470 net |
| 10 the CLion plugin | not compiled | not compiled | not compiled | ≤ 580 Kotlin and XML |
| 11 broken files, fixed input | ≤ +0.1% | ≤ +0.01% | ≤ +0.1% | ≤ +460 net |
| 12 the plugin on LSP4IJ | not compiled | not compiled | not compiled | ≤ 500 Kotlin and XML |
| 13 library files, fixed input | ≤ +0.1% (noise) | no increase | no increase | ≤ −80 net |

**Latency.** Per request after one change, on this host: ≤ 1.0 s for
`blorp/src/main.brp`, and ≤ 50 ms for a one-module program. Landing 1
reports `analyze`'s one-shot time on `main.brp` as the baseline.

## Measurements

All on this host (macOS, Apple clang), each run serial on a machine other
sessions share. Raw samples are under `blorp/build/lsp-analyze/`,
`blorp/build/lsp-comments/`, `blorp/build/lsp-prefix/`,
`blorp/build/lsp-fixed-identities/`, `blorp/build/lsp-name-uses/` and
`blorp/build/lsp-console-natives/` in the main checkout.

**Landing 1** (`873869eb0`, against `286e8a01b`). Both compilers were
generated by the candidate, linked `-O2 -DBLORP_MEMORY_DIAGNOSTICS=1`, and
compiled the candidate's `main.brp` under `BLORP_LEAK_CHECK=strict` in three
alternating rounds.

| Measure | Base | Candidate | Change |
| --- | ---: | ---: | ---: |
| Allocations | 13,828,995 | 13,828,996 | +1 |
| Instructions, best of 3 | 13,456,358,170 | 13,458,844,566 | +0.018% |
| Peak footprint, best | 204,554,768 | 204,522,000 | within noise |
| Lines, production and tests | | | +56 and +182 net |

Output identity: 666 inputs (`main.brp` and every e2e fixture with `main`)
gave identical C, stdout, stderr and exit status. The latency baseline is
`check.analyze_program`'s inclusive share of a sampled `-O2 -g` self-compile
(`blorp/scripts/attribution/run`, stage `profile`): 28.5% of 2.18 s, about
0.62 s (0.48 s user). That is one run, so re-measure it on a quiet machine
before landing 9.

**Landing 2** (against `1bd73de06`; the measured candidate, `0529dc99d`, has
this landing's code). `self-compile-cost`, `-O2`, 11 rounds:

| Measure | Base | Candidate | Change |
| --- | ---: | ---: | ---: |
| Fixed input, allocations | 13,826,299 | 13,865,290 | +0.282% |
| Fixed input, instructions (median) | 12,078,357,646 | 12,103,842,967 | +0.211% |
| Own source, allocations | 13,826,299 | 13,869,787 | +0.315% |
| Own source, instructions (median) | 12,071,492,242 | 12,102,538,881 | +0.257% |
| Formatting the repository, instructions (median of 21) | 9,818,320,072 | 9,848,094,160 | +0.30% |
| Lines, production and tests | | | +27 and +133 net |

- **Identity.** The fixed-input C is identical. Against `873869eb0`, 671
  compiler inputs gave identical C, stdout, stderr and exit status, and
  formatting 1,264 files gave identical trees.
- **Formatting.** This is `format --check` of `FORMAT_ROOTS`, using compilers
  built as `self-compile-cost` builds them, in alternating rounds. Its mean
  is +0.48% and its paired median +0.57%, with a spread of 1.3 to 2.7%.
- **Peak heap.** `self-compile-cost` does not report it. The best
  footprints were equal, and the comment lists hold about 0.13 MB.
- **Allocations.** `BLORP_ALLOCATION_SITES` puts 37,160 of them on the
  lexer's `CodeLine`. It lost `fixed` to carry its comments, so it is now a
  heap record built once per code line. The rest are 1,794 for the comment
  lists' growth and +78 elsewhere.
- **The `append_modules` expectation** rose by 64, one end-of-file `CodeLine`
  per empty module.
- **The compiler cost.** A plain record returned by value is heap-allocated
  even when it never escapes. The design keeps it, per `AGENTS.md`.
- **Corrections.** The coordinator corrected allocations from +0.3% to
  +0.32% and formatting from +0.5% to +0.7% (standing delegation,
  2026-11-11). The estimate counted the comment lists but not the
  `CodeLine` record, and the own-source workload also compiles the
  change's own code.

**Landing 3** (against `355e9669a`). `self-compile-cost`, `-O2`, 11 rounds:

| Measure | Base | Candidate | Change |
| --- | ---: | ---: | ---: |
| Fixed input, allocations | 13,891,669 | 13,891,669 | 0 |
| Fixed input, instructions (median) | 12,091,761,451 | 12,089,809,475 | −0.016% |
| Own source, allocations | 13,891,669 | 13,897,482 | +0.042% |
| Own source, instructions (median) | 12,124,662,027 | 12,131,728,248 | +0.058% |
| Lines, production and tests | | | +45 and +241 net |

- **Identity.** The fixed-input C is identical. Against `5c190352a`, 671
  compiler inputs gave identical C, stdout, stderr and exit status. None of
  them fails in the lexer, so two that do (an unterminated string, and a tab
  then spaces) were compared as well, also identical.
- **Peak heap.** `self-compile-cost` does not report it. The best
  footprints moved −0.9% (fixed input) and +0.13% (own source), within their
  spread between runs; the implementer's run against `5c190352a` gave −1.0%
  for own source. The success path allocates exactly as before.
- **Allocations.** `CodeLine` is `fixed` again, and `SkippedLines`, which
  carries the comments skipped before a code line whether or not that line
  lexes, is the one heap record per code line in its place. Compiling the
  same input costs the same allocations; the own-source rise is the compiler
  compiling this landing's own lines, about 130 allocations a line.
- **Correction.** The coordinator corrected allocations from +0.01% to
  +0.05% (standing delegation, 2026-11-12). The ceiling left no room for
  compiling the landing's own lines, which the own-source row includes; the
  fixed-input row did not move. At about 0.001% a production line, the
  +0.01% ceilings of landings 6 and 8 do not allow for their lines either.

**Landing 4** (against `525b653c2`). `self-compile-cost`, `-O2`, 11 rounds:

| Measure | Base | Candidate | Change |
| --- | ---: | ---: | ---: |
| Fixed input, allocations | 14,130,156 | 14,010,842 | −0.844% |
| Fixed input, instructions (median) | 12,387,657,063 | 12,336,674,697 | −0.412% |
| Own source, allocations | 14,130,156 | 14,011,895 | −0.837% |
| Own source, instructions (median) | 12,385,087,229 | 12,343,137,243 | −0.339% |
| Own source, peak heap (requested bytes) | 163,063,337 | 162,982,584 | −0.050% |
| Lines, production and tests | | | +5 and +44 net |

- **Identity.** The fixed-input C is identical. Against `95f37e437`, 682
  compiler inputs (585 compile, 97 rejected) gave identical C, stdout,
  stderr and exit status.
- **Peak heap**, against `95f37e437`. Both compilers were generated by the
  pinned seed, given the same probe for peak live bytes (requested, and
  rounded by `malloc_size`), linked `-O2 -DBLORP_MEMORY_DIAGNOSTICS=1` and
  run twice under `BLORP_LEAK_CHECK=strict`; both runs gave the same
  figures. Fixed input: unchanged (4 bytes less, from a shorter output path;
  rounded bytes equal). Own source: −0.05% requested and −0.06% rounded.
  The peak comes while the final C is assembled, which these types do not
  reach. The best `peak memory footprint` samples read +0.2% to +0.8%,
  which is allocator noise: the probe shows no rise.
- **Allocations.** 119,314 fewer. `BLORP_ALLOCATION_SITES` puts the fall on
  `model.family_for` (−52,345), `scope.binding_site` (−41,617),
  `scope.bind_data` (−18,151), `model.type_parameter_id` (−4,540),
  `results.translated_list` (−2,176) and `namespace.bind` (−1,489), where
  a value of these types was a heap object and is now inline.
  `patterns.resolve_alternatives` and `parse.consume_interpolated` rose by
  about 3,000 each; not investigated.
- **Tests.** `FieldId`'s `==` is checked against a sibling field and against
  another record's field at the same position. An equality over the
  position alone, or over the owner alone, fails it.

**Landing 5** (against `01cbcd56d`; the parent, `918f93f3e`, adds only
documentation). The measured candidate, `b4945ef41`, generates the same
compiler C as the landed commit, which rewraps two of its comments.
`self-compile-cost`, `-O2`, 11 rounds:

| Measure | Base | Candidate | Change |
| --- | ---: | ---: | ---: |
| Fixed input, allocations | 13,956,806 | 14,039,769 | +0.594% |
| Fixed input, instructions (median) | 12,408,285,295 | 12,529,708,579 | +0.979% |
| Fixed input, peak heap (requested bytes) | 169,103,902 | 169,103,910 | +8 bytes |
| Own source, allocations | 13,956,806 | 14,198,835 | +1.734% |
| Own source, instructions (median) | 12,394,681,726 | 12,675,942,219 | +2.269% |
| Own source, peak heap (requested bytes) | 169,103,901 | 170,305,362 | +0.711% |
| Lines, production and tests | | | +1,320 and +894 net |

- **Correction.** The ceilings were ≤ +1% instructions, ≤ +0.5% allocations
  and ≤ +0.5% peak heap on own source, and ≤ +650 production lines. The
  estimate missed the result records that carry each syntax's uses to its
  parent, and the own-source rows also compile the landing's 1,320 lines.
  Keith accepted the measured costs as the new ceilings on 2026-11-16: on the
  fixed input, ≤ +1% instructions, ≤ +0.6% allocations and peak heap
  unchanged, with ≤ +1,320 production lines.
- **Earlier runs.** Threading one use list through the walk (`fade7a376`,
  against `7bccfadfb`) cost +11.85% fixed-input instructions: a value the walk
  keeps for a later read is duplicated, so each append copied the whole list
  (6.95 GB requested, against 0.95 GB). Building uses bottom-up, each result
  carrying only its own syntax's uses, gave +0.91% and +0.88% (two runs at
  `90f597501`), +0.91% (`ffa69a7e2`) and +0.98% after review. Run-to-run
  noise is about ±0.05%. Samples: `cost-1` to `cost-5`.
- **Identity.** The fixed-input C is identical (`2473ba89c7cce0c7`). Against
  `01cbcd56d`, 704 compiler inputs (`main.brp` and 703 fixtures with `main`;
  603 compile, 101 rejected) gave identical C, stdout, stderr and exit status.
- **Allocations.** `BLORP_ALLOCATION_SITES` at `ffa69a7e2`, +83,084 on the
  fixed input:
  - 39,059 first appends, one list per scope that records (`with_uses`
    13.7k, `resolve_constructor` 6.6k, `elaborate_value` 6.6k);
  - 12,523 concatenation copies (8.0 MB): a list read out of a record that
    stays live, or one concatenated onto `[]` (`resolve_join_arms` 3,709,
    `resolve_assignment` 1,795, `resolve_if_branch` 1,758, `finish_body`
    1,287, `checked_record` and `checked_union` 1,607);
  - namespace `ResolvedName` rows, `bind` +4,518 and `select_union` +4,084:
    heap records, since `Entity.Alias` holds a path;
  - `SelectedReceiver` +2,216;
  - moved code, `annotated_types` +11,700 and `resolve_signature` +7,285
    against `resolve_parameters` −22,893.

  Dropping the uses of a failed pattern field or alternative saved 964.
- **`ResolvedType`** is a one-case union because a union is returned by
  value. As a plain record it cost 22,253 more allocations (+0.157%, one
  round, `24db9c489` against the unlanded `27083f82e`). It becomes a record
  once records are passed by value (`COST_QUIRKS_PLAN.md`).
- **e2e compile ceilings.** Three allocation ceilings rose by the measured
  rise: files read +3,571, files write +3,760, and a user module read
  +3,284. `INSTRUCTION_CHECK=on` passes with every instruction ceiling
  unchanged.
- **Audit.** Every use in the self-compile was listed and joined back to its
  source: 118,207 uses, none duplicated, none with the wrong text or the
  wrong declaration. 6,050 have no declaration, all built-in types.
  `declarations()` returns 25,763 referents. 1,140 identifiers have neither
  a use nor a declaration, mostly import path segments (decision g); the
  rest are required trait methods' parameter names, an or-pattern's later
  binders, and words the audit's scan finds inside strings.
- **Plan corrections.**
  - Blorp has no record patterns, so fields have no pattern uses.
  - `declaration_span` returns `None` for the primitive heads and `List`,
    whose declarations are in `ParsedContents.builtin_types`.
  - The test wrapper is a typed fact, `ParsedContents.synthesized_entry`,
    set by `prepare_test_entry`; Check records none of its uses.
  - `BindingDefinition.named` marks the bindings that are declarations;
    `_` and compiler temporaries are not.
  - `Self` is a `TraitReferent` in a trait and its defaults, and a
    `TypeReferent` of the receiver's head in an implementation.
  - Each implementation method has its own `TypeParameterId` for each header
    parameter, and `declaration_span` maps them all to the header's written
    parameter. Landing 9's references must group by declaration span, not by
    referent.
  - `type_parameter_span` and `default_owner` scan the implementations or
    traits, so landing 9 indexes them before asking per token.
  - A module's declaration span is zero-width at its first byte.
  - Never recorded: import paths and `as` aliases, required trait methods'
    parameter names, an or-pattern's later binders (`A(x) | B(x)` records the
    first), and `type Int = builtin` declarations.
  - `CheckedValueResult`, `ResolvedBody` and `CheckedBodies` left `model`,
    which cannot import `name_uses`.
- **Tests.** 31 cases in `test_name_uses.brp`, at least one per `Referent`
  case. Not recording fields in record construction and update fails the 4
  tests whose source has a record literal or update; not recording constant
  reads fails only the constant test; not recording type parameters in types
  fails only the two type-parameter tests; recording the test wrapper's body
  fails only the wrapper test.

**Landing 6** (measured as `db1eef7bf` against `4d350add0`, then replayed
onto `07ff200b4`, whose new commits touch none of its compiler files;
`make test` and the fixpoint ran again after the replay).
`self-compile-cost`, `-O2`, 11 rounds:

| Measure | Base | Candidate | Change |
| --- | ---: | ---: | ---: |
| Fixed input, allocations | 14,198,835 | 14,198,835 | unchanged |
| Fixed input, instructions (median) | 12,671,251,741 | 12,669,837,041 | −0.011% |
| Fixed input, peak heap (requested bytes) | 170,305,111 | 170,305,111 | unchanged |
| Own source, allocations | 14,198,835 | 14,219,163 | +0.143% |
| Own source, instructions (median) | 12,654,723,656 | 12,676,202,074 | +0.170% |
| Own source, peak heap (requested bytes) | 170,305,110 | 170,384,493 | +0.047% |
| Lines, production and tests | | | +280 and +996 net |

- **Correction.** The ceilings were on the own-source rows, with ≤ +150
  production lines. Own source also compiles the landing's own lines, so
  the coordinator moved them to the fixed input, letting own source exceed
  them by 0.002% instructions and 0.001% allocations and peak heap per net
  production line. The line estimate predated the exit handler, the shared
  guard and the error helper; the coordinator raised it to ≤ +280 under the
  standing budget delegation (2026-11-16). Own source fits: +0.170% against
  +0.66%, +0.143% against +0.29%, +0.047% against +0.38%.
- **Identity.** The fixed-input C is identical (`8fd09726e84223d3`). Against
  `4d350add0`, 704 compiler inputs (603 compile, 101 rejected) gave identical
  stdout, stderr and exit status, and identical C except for the two
  fixtures that call `capture`, `process/natives_capture` and
  `process/natives_together`: the SIGPIPE guard moved, unchanged but for its
  names, into its own fragment (`runtime/sigpipe.brp`), which `capture` and
  the console share.
- **Natives.** `console.read_line` returns the bytes through the LF, so an
  empty result is end of input; landing 8 drops the LF or CRLF.
  `console.read_exact(count)` returns fewer than `count` bytes only at end
  of input, and a count of zero or less reads and flushes nothing. Both
  read stdin's stdio buffer, flush stdout first under the guard and clear a
  sticky end of input. Errors use the files protocol, with `IsADirectory`
  the one named kind. The labels are not library-only: there is no handle
  to protect.
- **Exit.** Every console operation arms, once, an `atexit` handler that
  closes stdout under the guard. Otherwise stdio's own flush at exit retries
  a buffer a failed flush kept, unguarded, and the program dies of SIGPIPE
  instead of exiting with its status. Review found that only `write` armed
  it; a program that printed and then only flushed or read died.
- **EINTR.** Reads retry it. Writes and flushes report it: Blorp installs no
  catching handler, so only a handler installed elsewhere without
  `SA_RESTART` can raise it, and a write may have sent some bytes.
- **Tests.** 25 C cases in `console_test.c`, built with ASan, UBSan and
  `-Werror` and run under the strict leak check, in `test-e2e`. Both
  closed-reader exit cases for flush and read fail with SIGPIPE before the
  review fix. The check test asserts the mismatch message and its help; the
  emission tests assert the guard and helpers appear once when `capture`
  and every console operation are used together.
- **Linux.** Main's CI failed two closed-reader cases on Linux x64 GCC
  alone: each passed `error` beside the call that sets it, and GCC on x86_64
  evaluates arguments right to left, so the test read -1. `4fee244ad` stores
  each result first; all 25 cases, the directory on stdin among them, now
  pass on Linux x64 and ARM64 with GCC and Clang.
- **Found, not fixed.**
  - A small write to a closed reader reports EPIPE at the next flush, or not
    at all if the program exits first.
  - `console_suite.brp` repeats about 40 lines of `fs_suite.brp`'s helpers,
    and five tests repeat the label list in their help text.

**Landing 7** (a plain rotation). The pin names `blorp-seed-4fee244ad96f`,
which main's CI built from `4fee244ad`: landing 6 with its test fix. The
seed also carries the impure trait methods plan's landing 1 (`07ff200b4`).
A program that declares and calls the five console labels fails under the
old seed with "unknown builtin operation" and compiles under the new one.
The compiler build, `test_bootstrap.sh`, `make test`, the fixpoint and
`make -C blorp test-e2e INSTRUCTION_CHECK=on` pass with no ceiling raised.

**Landing 8** (against `e4e2eb735`). `self-compile-cost`, `-O2`, 3 rounds:

| Measure | Base | Candidate | Change |
| --- | ---: | ---: | ---: |
| Fixed input, allocations | 14,551,725 | 14,551,727 | +2 |
| Fixed input, instructions (median) | 12,998,488,299 | 12,995,282,725 | −0.025% |
| Fixed input, peak heap (requested bytes) | 173,267,667 | 173,267,797 | +130 bytes |
| Own source, allocations | 14,551,725 | 14,554,126 | +0.017% |
| Own source, instructions (median) | 12,987,308,263 | 12,992,831,394 | +0.043% |
| Own source, peak heap (requested bytes) | 173,267,666 | 173,296,305 | +0.017% |
| Lines, production and tests | | | +152 and +377 net |

- **Modules.** The planned API put `ReadLineError` and `ReadExactError` in
  one module, but variant names are unique across a module's unions. Keith
  chose modules built around types, within reason (2026-11-17), so
  `io/console.brp` became `io/console/output` (`print`, `print_error`,
  `write`, `write_error`, `flush`), `io/console/read_line` and
  `io/console/read_exact`, each union as approved. A module file beside a
  folder of its name is rejected, so no `io/console.brp` remains; every
  `io/console: print` import, the prelude's among them, names
  `io/console/output`.
- **Correction.** The line ceiling was +60, estimated from the plan's sketch.
  A compiled spike measured +155: three module headers and imports, two
  unions, two decoders, two `Stringable` implementations, five natives, five
  functions and the line-ending helper, none of it redundant. The
  coordinator set ≤ +170 from it, as the 2026-11-16 rule for sketch
  estimates provides. Review then trimmed three unused imports.
- **Identity.** The fixed-input C is identical (`bc35d2e8456ec168`): the
  compiler imports no console function.
- **Tests.** `test_console_errors.brp` binds both decoders to literal codes
  and checks every phrase. `test_compile/console.brp` runs three fixtures,
  normal and strict, through `capture` with stdin: LF, CRLF, empty lines, a
  lone CR kept, one CR of two stripped, no final LF, end of input, headers
  then an exact body, a short body, input ending before the body, a zero
  and a negative count, a prompt before the reply, `print` and `write` in
  order, and `write` beside `write_text`. Applied together, four mutations
  (no CR strip, `EndedEarly(n + 1)`, `<=` as `<`, `write` to stderr) fail all
  three tests, though only the first case each test reaches was seen to fail;
  `<=` as `==` alone fails the negative count. Their compile ceilings are
  measured plus 15%.
- **Criterion 8.** `capture` carries Strings, so no e2e case can send bytes
  that are not UTF-8 or close the reader. Landing 6's C cases cover both at
  the natives, and the library passes the bytes through unchanged.
- **Rough edges.** `NativeRun` has no stdin field, so `console.brp` has its
  own small runner over `run_expecting`, as `streaming_files.brp` does.
  `test-e2e` cannot run one suite.

**Landing 9a** (against `1ca3f4b1c`). `self-compile-cost`, `-O2`, 3 rounds:

| Measure | Base | Candidate | Change |
| --- | ---: | ---: | ---: |
| Fixed input, allocations | 14,730,759 | 14,730,759 | unchanged |
| Fixed input, instructions (median) | 13,213,542,067 | 13,214,711,034 | +0.009% |
| Fixed input, peak heap (requested bytes) | 174,395,154 | 174,395,866 | +712 bytes |
| Own source, allocations | 14,730,759 | 15,256,707 | +3.57% |
| Own source, instructions (median) | 13,203,493,079 | 13,682,754,052 | +3.63% |
| Own source, peak heap (requested bytes) | 174,395,153 | 178,720,409 | +2.48% |
| Lines, production and tests | | | +1,292 and +1,375 net |

Latency, an `-O2` build (Apple clang 21), a fresh process per run, from
writing `didOpen` to reading the reply (`latency/measure.py`):

| Input | Median | Range | Runs |
| --- | ---: | ---: | ---: |
| One module with a type error | 3.0 ms | 2.9–10.1 ms | 9 |
| `blorp/src/main.brp`, clean | 342 ms | 338–347 ms | 7 |
| `main.brp` with a type error appended | 154 ms | 153–160 ms | 7 |

- **Split.** Keith split landing 9 into 9a, 9b and 9c on 2026-11-17.
  Staleness and watched files moved from 9a to 9b, where the token requests
  that read staleness arrive, and the library on disk to 9c, which needs
  real library paths. 9a analyses on `didOpen` only.
- **Correction.** The plan's +1,700 lines for all of landing 9 was a sketch.
  A compiled spike of 9a measured +1,138 (`47b4e4e45`: protocol 364,
  server 500, transport 176, positions 84), none of it padding; the largest
  single piece is `file://` encoding and decoding. The coordinator set 9a's
  ceiling at ≤ +1,350 from it; expect 9a, 9b and 9c together near +2,200.
  The own-source rows are reported, not held (`blorp/AGENTS.md`), so the old
  ≤ +3% no longer binds.
- **Identity.** The fixed-input C is identical (`1a8d5a3ff943f162`).
- **Design.**
  - The loader records each module's role in `SourceInputs`
    (`ModuleSource`), and the server reads it rather than reclassifying.
  - `Step.analyse` and `analysed` take a `Path`.
  - `initialize` picks UTF-8 if offered, else UTF-16, and announces full
    sync only.
  - -32600 answers an invalid message, a request after `shutdown`, a second
    `initialize`, and an id that is neither an integer nor a string.
  - Positions go through a line index built once per text.
  - Each root keeps what it last published per file. When a root stops
    reporting in a file, by re-analysis or `didClose`, the most recently
    analysed other open root's diagnostics are republished there, or `[]`.
  - Open documents are published to by the URI the client sent.
  - A diagnostic in a library module shows at the root's start, with its
    location in the message.
- **Tests.** 62 unit tests in `test/test_lsp/`, two role tests and e2e
  sessions in `cli.brp`, among them a body that is not UTF-8 fed by
  `sh -c 'exec "$0" lsp < "$1"'`, since process stdin is a String. Each of 26
  unit mutations and 8 more after review failed exactly its tests, run one
  at a time.
- **Found, not fixed.**
  - Note spans are dropped; they could become `relatedInformation`.
  - `--stdio`, which VS Code clients pass, is rejected.
  - A closed file another open root still reports in keeps that root's
    diagnostics, as LSP allows; they were computed against the closed
    document's unsaved text, so 9b's staleness rule must re-analyse that
    root.
  - After `didClose` the server forgets the client's URI, so when the client
    spelled it differently from `file_uri(path)`, a set published under the
    client's spelling is later updated only under ours (open a file as
    `%6D…`, analyse an importer, close both). 9b publishes `[]` to the
    client's URI on close when the spellings differ.

**Landing 9b** (against `7564157d3`). `self-compile-cost`, `-O2`, 3 rounds:

| Measure | Base | Candidate | Change |
| --- | ---: | ---: | ---: |
| Fixed input, allocations | 15,256,707 | 15,256,707 | unchanged |
| Fixed input, instructions (median) | 13,688,607,855 | 13,686,862,021 | −0.013% |
| Fixed input, peak heap (requested bytes) | 178,719,922 | 178,719,922 | unchanged |
| Own source, allocations | 15,256,707 | 15,464,958 | +1.37% |
| Own source, instructions (median) | 13,676,411,636 | 13,889,211,044 | +1.56% |
| Own source, peak heap (requested bytes) | 178,719,921 | 180,478,124 | +0.98% |
| Lines, production and tests | | | +772 and +1,042 net |

`semanticTokens/full` after one `didChange`, an `-O2` build, a fresh server
per run, measured before review (its fixes leave the analysis and token
paths unchanged):

| Input | Tokens | Median | Range | Runs |
| --- | ---: | ---: | ---: | ---: |
| One module | 44 | 3.8 ms | 3.4–8.3 ms | 9 |
| `blorp/src/main.brp` | 282 | 344 ms | 342–354 ms | 7 |
| `common/syntax/lex.brp` | 5,816 | 23.8 ms | 23.4–24.1 ms | 5 |

With `main.brp` open (open, tokens, change, tokens, exit), peak heap is
86.2 MB, and the strict leak check reports nothing leaked.

- **Ceiling.** A compiled spike measured +627 (`365086533`; `tokens.brp`
  426), none of it padding; the coordinator set ≤ +780 from it.
- **Identity.** The fixed-input C is identical (`2301c6be4f3782bc`).
- **Design.**
  - The server re-lexes the requested document, so compile cost is
    untouched; a broken file needs the lexer anyway.
  - A token's identity comes only from `NameUse` and the declaration
    tables. Its type is the `Referent`'s case, with bindings split into
    `parameter` and `variable` by their definition, and implementation
    methods `method` through a new pure `function_role`. Modifiers are
    `declaration`, `readonly`, `defaultLibrary` (the module's role, or a
    built-in head) and `documentation` (`Comment.documentation`).
  - `TOKEN_TYPES` orders the legend; the mapping tests decode each token
    through the legend's names, so a type missing from it fails them.
  - Each open root keeps its whole `Analysis`, which 9c reads.
  - Staleness: `didChange`, `didClose` and a watched change stale every
    root whose last analysis read the file, a failed load is stale on any
    change, and a watched change to an open file stales nothing. A token
    request on a stale document analyses first; the step that asks for the
    analysis carries the request's id, and `analysed` answers exactly that
    id. A burst of edits costs one analysis.
  - `client/registerCapability` for `**/*.brp` goes out once after
    `initialized`, only when the client supports dynamic registration; the
    server numbers its requests and ignores the answer.
  - 9a's follow-ups: on `didClose`, `[]` goes to the client's URI when it
    differs from `file_uri(path)`, then what other roots report there is
    republished under ours; closing stales the roots that read the closed
    file's unsaved text.
- **Tests.** `test_tokens.brp`, server tests built from real analyses,
  line pieces, and an e2e session: a broken file's lexer tokens, an edit,
  then full tokens and `[]`. Each of 30 mutations, and 7 more after review,
  run alone, failed its test; two of the first 30 were rerun after a fix.
- **Not coloured, by decision.** Import paths and an alias's declaration
  have no `NameUse` (landing 5's decision g), so their names stay plain and
  `..` and `/` there read as operators; the contextual words `fixed` and
  `methods`; a trait requirement's parameters; and a pipe string's
  continuation `|`.
- **For the plugin.** An edit to A leaves an open importer B stale until the
  editor next asks for B's tokens. If CLion does not re-ask for visible
  files, the server can send `workspace/semanticTokens/refresh`.
- **Found, not fixed (review nits, for 9c).**
  - Each identifier's `Classified` still holds the analysis's span, which
    the lexer's span replaces before sending; mapping each offset to its
    type and modifiers would drop the field.
  - The test meant for a trait default's body may resolve to a
    `TraitMethodReferent`, leaving the `TraitDefaultBody` case unproven;
    a mutation of it would tell.
  - Closing a document while its token request waits answers `null`, as
    `analysed` promises, but no test pins it.

**Landing 9c** (against `15879f95f`). `self-compile-cost`, `-O2`, 3 rounds:

| Measure | Base | Candidate | Change |
| --- | ---: | ---: | ---: |
| Fixed input, allocations | 15,464,958 | 15,464,958 | unchanged |
| Fixed input, instructions (median) | 13,875,056,592 | 13,873,312,915 | −0.013% |
| Fixed input, peak heap (requested bytes) | 180,477,630 | 180,477,630 | unchanged |
| Own source, allocations | 15,464,958 | 15,645,094 | +1.16% |
| Own source, instructions (median) | 13,882,456,578 | 14,033,281,207 | +1.09% |
| Own source, peak heap (requested bytes) | 180,477,629 | 181,231,736 | +0.42% |
| Lines, production and tests | | | +468 and +1,110 net |

Latency after one `didChange`, an `-O2` build, a fresh server per run,
measured at `c0fe10f7b` (the last round changed no request path):

| Input | Request | Median | Range | Runs |
| --- | --- | ---: | ---: | ---: |
| `blorp/src/main.brp` | definition | 343 ms | 341–347 ms | 7 |
| `blorp/src/main.brp` | references | 345 ms | 343–353 ms | 7 |
| `blorp/src/main.brp` | references on `Result`, 1,521 locations | 363 ms | 361–365 ms | 5 |
| One module | definition | 3.4 ms | 3.4–3.6 ms | 9 |
| One module | references | 3.5 ms | 3.5–3.6 ms | 9 |

Writing the library at start costs less than the noise: a whole process
life took 12.6 ms against 12.8 ms before (101 runs).

- **Ceiling.** A compiled spike measured +392 (`59f98e888`); the
  coordinator set ≤ +450 from it, then raised it to ≤ +470 under the standing
  delegation for Keith's fold-in below, which added the view layout and the
  loader's two path accessors.
- **The library as a view (Keith, 2026-11-18).** Review found that analysing
  `LibraryDirectory(folder)` let an editor's save change the library for the
  rest of a session, and `io/files` cannot make a file read-only. Keith
  rejected a permissions API (several landings, consumers still
  speculative, and an IDE can clear a read-only flag) and chose this:
  analyses read the embedded library, the folder is written only to be
  shown, and the loader's `library_relative_path` and `library_path` place a
  library span's file in it. `ServedLibrary` holds the analysed layout and
  the view's.
- **Identity.** The fixed-input C is identical (`99d63a84584d0498`).
- **Design.**
  - Definition answers the declaration of the use or declaration at the
    position (an identifier's end counts), or `null`; a built-in type has
    none.
  - References group by declaration span within the root's one analysis
    (across analyses, path and range must be compared); `includeDeclaration`
    adds the declaration; a built-in type lists every use.
  - A request on a stale document waits for its analysis as a
    `WaitingRequest`, and closing the document first answers `null`.
  - Locations use the client's URI for an open file, else `file_uri`, and a
    library file's place in the view.
  - A library file the client opens is classified by the view's
    `module_role` and gets lexer tokens, `null` and `[]`: as a root it would
    be a user module that the library's own imports reject.
  - The folder is removed on every path the program controls; failing to
    make, fill or remove it exits 3, an impossible embedded-library mismatch
    exits 4.
- **Tests.** Definition and references for every referent kind, the view
  classification, the library-diagnostic location, and an e2e session that
  overwrites the view's copy of `io/console/output.brp` mid-session and gets
  identical replies. That one runs through a small `sh` driver over a FIFO,
  since `capture` sends stdin whole; it only orchestrates, and the review
  found it needs no approval. Each mutation, run alone, failed its tests;
  analysing the folder again fails the view test.
- **9b's follow-ups.** The span is gone from the identifier map. A trait
  default's body is unreachable as a referent (calls record the trait
  method), so its arm stays for exhaustiveness. Closing a document while its
  request waits is tested.
- **Found, not fixed.**
  - Navigating onward from a library file needs the loader to keep a library
    root's role, or a new mechanism; Keith's call.
  - References on an implementation method's own name return only it,
    because calls record the trait method.
  - `/tmp` is a symlink on macOS: a client that opens a view file as
    `/private/tmp/…` makes it a user file; the plugin checklist checks what
    CLion sends.
  - Cleaners of `/tmp` may delete view files during a session lasting days.
  - The process API has no streaming stdin, which is why the view test
    needs its driver.

**Server fixes from the CLion plugin's checklist** (against `e3ebc276f`).
`self-compile-cost`, `-O2`, 3 rounds:

| Measure | Base | Candidate | Change |
| --- | ---: | ---: | ---: |
| Fixed input, allocations | 12,854,450 | 12,854,450 | unchanged |
| Fixed input, instructions (median) | 12,965,432,911 | 12,963,874,497 | −0.012% |
| Fixed input, peak heap (requested bytes) | 183,036,020 | 183,036,020 | unchanged |
| Own source, allocations | 12,854,450 | 12,878,025 | +0.18% |
| Own source, instructions (median) | 12,949,029,948 | 12,966,257,449 | +0.13% |
| Own source, peak heap (requested bytes) | 183,036,019 | 183,272,960 | +0.13% |
| Lines, production and tests | | | +161 and +399 net |

Keith ran the plugin's checklist in CLion 2026.3 on 2026-11-21; its
`idea.log` and a trace of the stdio traffic (a `tee` wrapper set as the
plugin's executable) found three server defects.

- **The view folder leaked.** CLion sends `shutdown`, waits for its reply,
  sends `exit`, and kills the process 4–14 ms later (exit 137 in three of four
  sessions), before the server had removed 34 files. Now `shutdown` puts the
  server in `LeavingLibrary(id)`: the transport leaves the folder's scope, the
  folder is removed, and only then is the reply written; `exit` is read
  outside the scope. When removal fails the server exits 3 without the reply,
  because `with_temporary_directory` discards its body's value on that path; a
  library follow-up.
- **An open importer never refreshed.** When an open, change, close or
  watched change stales an open root other than the document's own, and the
  client sets `workspace.semanticTokens.refreshSupport` (CLion does), the
  server sends one `workspace/semanticTokens/refresh`; the client re-asks for
  visible files' tokens, which re-analyses them.
- **Cmd-hover underlined nothing.** CLion asks for a definition on every
  Cmd-hover move, and the server answered each with a `Location`. CLion's
  `LspImplicitReferenceProvider` turns a result without an
  `originSelectionRange` into an empty range at the mouse, which Cmd-hover
  cannot underline. With `textDocument.definition.linkSupport` (CLion sets
  it), definition now answers a one-element `LocationLink[]` whose origin is
  the name under the position. This was taken for the cause of Cmd-click
  failing; landing 10 found the real one.
- **Ceiling.** A sketch estimate of +80, raised to +120 when links joined, then
  corrected to +150 and +165 under the standing delegation: the audit found
  the shutdown state, refresh and links about 25, 55 and 45 lines, with
  comments, and review's fixes (one shutdown accessor, the link built where the
  definition is answered) the rest.
- **Identity.** The fixed-input C is identical (`f9801c340f4048e5`).
- **Tests.** Shutdown holds its reply until the folder is gone, and an e2e
  through the FIFO driver checks the folder is absent when the reply arrives;
  input ending after `shutdown` gives the reply and status 1; refresh is sent
  only with the capability, only for another root that was current, once per
  notification, with the next id, and the client's answer is ignored; a link's
  origin is exactly the name, its end included, and the answer is an array.
  Each mutation, run alone, failed its tests.

**Landing 10, the CLion plugin** (`editor/intellij/`, against `c0d78722d`).
A Gradle Kotlin project built against the installed CLion 2026.3
(`-PclionPath`, with CLion's JBR as `JAVA_HOME`). It registers `.brp` with an
icon, a lexer and flat parser, the LSP integration provider, a declaration
handler and one setting, the `blorp` path. A changed path restarts the
server, and a path that cannot start shows a balloon.

- **What CLion needed beyond the brief**, read from CLion's class files and
  confirmed in Keith's runs:
  - `LspSemanticTokensSupport.shouldAskServerForSemanticTokens` asks only
    for the language ids `TEXT` and `textmate`, so a plugin with its own
    language overrides it, or nothing is coloured.
  - The bundled schemes colour neither `DEFAULT_PARAMETER` nor
    `DEFAULT_CLASS_NAME`, so a parameter and its type looked the same. Tokens
    map to keys the schemes do colour (the plugin README's table). Keith
    wanted no colour settings page.
  - New Scratch File lists a language only with a `ParserDefinition`. Its
    word-sized leaves are what Go to Declaration underlines and lands on, and
    quoted strings split at their `${…}` holes so a name in a hole is a leaf.
- **Cmd-click.** CLion's `LspImplicitReferenceProvider` answers Go to
  Declaration only while the running action id is `GotoDeclaration`, or
  during Cmd-hover. CLion's C/C++ engine runs Cmd-B and Cmd-click inside
  `RiderActionUpdateInterceptor$RiderBackendCompositeAction`, so both
  reported "Cannot find declaration to go to" while the server answered every
  request in about 1 ms, and Navigate > Declaration or Usages worked. A probe
  build that logged each action and reference request in a `.brp` file found
  it: all 15 shortcut attempts got no reference. CLion asks declaration
  handlers whatever the action, so `BlorpGotoDeclarationHandler` sends the
  definition request itself through the public `LspClient` API. Keith
  confirmed Cmd-click and Cmd-B on 2026-11-21.
- **Tests.** 41 Gradle tests: launch paths and problems; the lexer, with
  holes and a restart inside one; the PSI; semantic tokens; definition
  targets; and one test that runs the repository's `blorp/build/blorp`. In
  it, under the C/C++ engine's action id, Go to Declaration reaches `helper`'s
  declaration and `print` in the library folder; with no server the handler
  gives no target; on a declaration the menu lists usages. Unregistering the
  handler fails that test, and a lexer that drops its state fails the restart
  test.
- **Review.** 0 blockers, 2 majors, 4 minors, 2 nits. The handler's wait
  matches CLion's own definition request (10 s, giving way to cancellation),
  now said in the code; holes are lexed as code; a bare name missing from
  PATH gets the balloon; `.brp` matching already ignored case, as the
  platform's extension matching does. The visibility and settings-state nits
  were declined.
- **Ceiling.** The brief's sketch set Kotlin and XML under 350; corrected to
  580 under the standing delegation. Launcher, path, settings and settings
  page 179; language, file type and `plugin.xml` 58; lexer and parser 203;
  semantic tokens 49; launch balloon 22; declaration handler 68. Each piece
  answers a CLion requirement above or a fix Keith asked for. Tests are 516
  lines.
- **Known limits.** On a declaration's own name, Cmd-B and Cmd-click find
  nothing instead of listing usages, since listing them is the LSP support's
  job, which the wrapper blocks; reporting the wrapper to JetBrains is
  Keith's call. Cmd-click finds nothing until the server has started. No CI
  builds or tests the plugin.

**Landing 11, broken files** (against `0cdfe13ae`). `self-compile-cost`, `-O2`,
3 rounds, on the final commit:

| Measure | Base | Candidate | Change |
| --- | ---: | ---: | ---: |
| Fixed input, allocations | 12,877,571 | 12,877,571 | unchanged |
| Fixed input, instructions (median) | 12,985,811,064 | 12,991,023,360 | +0.040% |
| Fixed input, peak heap (requested bytes) | 183,265,630 | 183,265,630 | unchanged |
| Own source, allocations | 12,877,571 | 12,974,188 | +0.75% |
| Own source, instructions (median) | 13,012,309,333 | 13,100,592,392 | +0.68% |
| Own source, peak heap (requested bytes) | 183,265,629 | 184,295,575 | +0.56% |
| Lines, production and tests | | | +448 and about +650 net |

- **What landed.**
  - A root's state is one union: `Current` with the latest outcome
    (`Checked`, or `Failed` with the sealed analysis if any), or `Stale` with
    the sealed analysis if any. The sealed analysis owns `changed_since`, the
    files reported changed since it checked.
  - `src/lsp/line_map.brp` trims the common first and last lines, then runs
    Myers' O(ND) on the rest. Past 512 inserted and deleted lines
    (`DIFF_LIMIT`) the untrimmed middle counts as changed.
  - A line's ending is part of its identity.
- **Ceilings.**
  - **Lines.** The sketch of +300 assumed one window. It was corrected to +460
    under the standing delegation after milestone 1 (+443), since the line diff
    adds about 250 lines with comments.
  - **Cost.** The row's old ≤ +0.5% bound own source, which
    `blorp/AGENTS.md` reports and does not hold. The row now binds fixed
    input, and that is met with identical C. Own source grew with the 448
    lines it compiles.
- **Latency** at `-O2`:
  - `blorp/src/main.brp`, tokens after an edit that fails to check: median
    128 ms (128–133);
  - definition there: 1 ms;
  - a one-module program: 2.3 ms;
  - the diff on `parse.brp` (6,808 lines): about 6 ms.
- **Tests.** Each mutation, run alone, failed its tests (the records are under
  the worktree's `blorp/build/lsp-broken-files/`). The CLion plugin's tests
  pass against this server.
- **Review.** 0 blockers, 0 majors, 4 minors and 3 nits, all fixed.

## Testing

Each landing starts with a failing test.

| Landing | Tests |
| --- | --- |
| 1 | `test_common/test_analysis/test_check/`: a module without `main` analyses, and `check` reports `MissingMain` with exact message, help and span. A malformed `main` fails both. |
| 2 | `test_common/test_syntax/test_lex/`: one case per comment site. Formatter suites and the formatted repository are unchanged. |
| 3 | An unclosed string keeps the tokens before it and drops its own. The loader's diagnostic is unchanged. |
| 4 | Existing suites, unchanged. |
| 5 | One case per `Referent` case, checking the use's span and, through `declaration_span`, its declaration's. Mutation proof: stop recording one case, and only its test fails. |
| 6 | Direct C tests of the natives, under `test/test_common/test_codegen/test_runtime/`. |
| 8 | e2e programs through `capture`: LF and CRLF, a last line without LF, header and body in one chunk, a short `read_exact`, a zero count at end of input, bytes that are not UTF-8 through each read, `write` output before a read, `print` and `write` output in order, a write after the reader closes, and `write` imported beside `io/files/write`'s `write_text`. |
| 9a | `test/test_lsp/`: framing; a body that is not UTF-8; positions for `é`, an astral emoji and `\r`; lifecycle errors; a shared file's diagnostics; each message through `receive`. An e2e session in `cli.brp` runs `initialize` through `exit` and checks replies, a diagnostic and the status. |
| 9b | Token splitting; a broken file's lexer tokens; staleness after a new import, a late open, a shared file's edit and a close. |
| 9c | Each request through `receive`. |
| 10 | Gradle tests in `editor/intellij/`, one running the repository's server, and the manual checklist in the plugin's README. |
| 11 | `test/test_lsp/`: the line diff (edited, interleaved and distant lines, a moved block, line ends, the limit, both directions) and serving a failed root (tokens, definition above and below an edit, other open documents, references, UTF-16, a close or reported change). An e2e session in `cli.brp`. |
| 12 | The Gradle tests against the repository's server: Go to Declaration under the C/C++ engine's action id, and LSP4IJ's usage search from a name in a hole. |
| 13 | `test/test_lsp/`: library locations are `blorp-library:` URIs, and the `initialize` reply is exact; `workspace/textDocumentContent` answers the embedded text, with -32602 and its message for a wrong scheme, a bad escape and an unknown path; without the capability only library entries go; a library document gets lexer tokens; definition is a `Location`; `shutdown` replies at once. The e2e session leaves no folder, and the README drops the folder. |

**Commands:** those in `blorp/AGENTS.md`, `scripts/blorp-fixpoint --prove`
for compiler landings, and `make -C blorp test-e2e INSTRUCTION_CHECK=on`
when compile cost changes.

## Acceptance criteria

- [ ] **1.** A module without `main` analyses, and `blorp compile` of it
  prints the unchanged `MissingMain`.
- [ ] **2.** `make -C blorp format-check` passes, formatter expectations are
  unchanged, and only the lexer recognises comments.
- [ ] **4.** Output identity holds on the e2e fixtures, and the
  measurements are recorded.
- [ ] **5.** Every `Referent` case passes, and the measurements are in
  this plan.
- [ ] **7.** `scripts/blorp-fixpoint --prove` passes with the new seed.
- [ ] **8.** The console e2e programs pass on all four CI platforms, and
  both reads return bytes that are not UTF-8 unchanged.
- [ ] **9.** The e2e replies match exactly, with -32700 for a body that is
  not UTF-8. A broken file gets only lexer tokens. Definition on `print`
  lands in the temporary folder, which is gone after `exit`. Latency is in
  ceiling.
- [ ] **10.** CLion colours a file, and definition and references work,
  into the library too.
- [ ] **11.** CLion colours a file while it has an error, and definition
  works above and below the edit.
- [ ] **12.** With LSP4IJ, CLion colours a file, Cmd-click and Cmd-B work
  into the library, and Find Usages lists usages.
- [ ] **13.** Cmd-click on `print` opens it read-only, coloured, and no
  `blorp-lsp-` folder is made.
- [ ] **Every landing** meets its ceilings, passes `make -C blorp test`, and
  is reviewed and test-run.

## Handback

Each landing returns its commit, evidence per criterion, measurements with
raw-sample paths, and anything found but not fixed.

Stop and ask if:
- a ceiling is exceeded;
- CLion shows no colour;
- a name use needs information the checker has discarded;
- the console errors conflict with `UINT8_BYTES_PLAN.md`.

Console API changes go to Keith.
