# Language server: `blorp lsp`

**Status: plan, 2026-11-10; Keith settled its decisions and asked for a byte
console on 2026-11-11. Landings 1 to 4 have landed; landing 5 is next.**

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

**What is missing:**

- **`check` requires `main`**, failing with `MissingMain`
  (`common/analysis/check/signatures.brp:189`).
- **Name uses go unrecorded.**
- **The lexer skips comments**, and the formatter finds them again
  (`format/trivia.brp:185`).
- **A failed lex keeps no tokens**, because names are interned only after a
  successful scan (`common/syntax/lex.brp:1954`).
- **The console cannot read**, and `print` always adds a newline.

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
- **CLion plugin** (`editor/intellij/`): it launches `blorp lsp`, as the
  old plugin's launcher did (`ee9e001c6de8:editor/intellij/`). JetBrains
  supports `semanticTokens/full` from 2024.2.2.

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
and parameters; types and type parameters; fields, in access, update,
construction and patterns; variants, traits and module aliases; import-list
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
`write_bytes(data)`, which clash with `io/fs`'s.

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

**The library on disk.** The server runs inside
`fs.with_temporary_directory("/tmp", "blorp-lsp-", …)`, writes each module
in the generated `EMBEDDED_LIBRARY_PATHS` there, and analyses with
`LibraryDirectory(folder)`, so library spans carry real paths. `/tmp` is a
named constant; every supported platform is POSIX.

**Semantic tokens.** Keywords, comments, strings, numbers and operators
come from the lexer. Identifier tokens take their type and modifiers from
name uses and the declaration tables. Only the protocol's standard types and
modifiers are used. String pieces are separate lexer tokens that stop at
`${`, so no token overlaps another, and multiline tokens are split per line.

**Broken files.** In landing 9, while a root fails to analyse, its files
get only the lexer's tokens (the prefix, if lexing failed), definition
returns `null` and references `[]`. Landing 11 then keeps the last
successful analysis sealed, with each file's text then. Each file's edits
since form one window, between the longest common prefix and the longest
non-overlapping common suffix: positions before it hold, positions after
shift by the length change, and positions inside find nothing. Requests map
back through their file's window, and answers forward through theirs.

**Definition** returns the declaration of the use at the position, or
`null`. A position at an identifier's end counts as inside it.

**References** returns every use with that referent. It includes the
declaration only on request.

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

**The console.** Today all of `standard_library/io/console.brp` is:

```blorp
func print(value: String) -> Void:
    builtin("string.print")


func print_error(message: String) -> Void:
    builtin("string.print_error")
```

The additions, reviewed for ergonomics:

```blorp
-- The bytes exactly as given; no newline is added. Output a closed pipe
-- refuses is dropped, under the SIGPIPE guard `capture` already uses, so a
-- client that has gone does not end the program.
func write(data: Bytes) -> Void
func write_error(data: Bytes) -> Void
-- Sends buffered standard output now. Every read does this first.
func flush() -> Void
-- Bytes, unlike `io/fs`'s String line functions: those before the next LF,
-- without it or a CR just before it (a lone CR stays). A last line with no
-- LF comes as it is; None once input has ended.
func read_line() -> Result[Option[Bytes], ReadLineError]
-- Exactly `byte_count` bytes. A count of zero or less gives Some(empty)
-- without reading; None means input ended before the first byte. Bytes are
-- held only as they arrive, so a large count costs only the input received.
func read_exact(byte_count: Int) -> Result[Option[Bytes], ReadExactError]


-- Why standard input could not be read: one exact union per operation, as
-- the library's exact-error convention requires. Both implement Stringable.
fixed union ReadLineError:
    -- EISDIR: standard input is a directory.
    IsADirectory
    -- Any other errno, such as EIO or EBADF.
    OtherOs(Int)


fixed union ReadExactError:
    -- Input ended after this many of the bytes asked for.
    EndedEarly(Int)
    IsADirectory
    OtherOs(Int)
```

The transport counts and sends the same bytes:

```blorp
import:
    bytes: Bytes, String methods
    io/console: write, flush
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
    io/console: write, read_line


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
    analyse: Option[String],
}

pure func receive(server: Server, message: Json) -> Step

pure func analysed(server: Server, path: String, result: DocumentAnalysis) -> Step
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

**Concurrent work:** `UINT8_BYTES_PLAN.md` edits the same builtin tables,
so coordinate before our landings 6 and 8. Of the
String plan's breaking switch and this work, whichever lands second migrates
the other's `length` and `slice` uses.

## Risks and unknowns

- **Recording cost:** every compile pays it, measured in landing 5.
- **Do semantic tokens alone colour a file in CLion?** The plugin landing
  probes it first with a stub server, with `null` and error replies too.
- **Bootstrap.** A library call to a `builtin` label the seed lacks stops
  the seed parsing the library (`common/syntax/parse.brp:4708`). So the
  console labels land alone, a rotation follows, and then the library.
- **Latency.** Analysing `blorp/src/main.brp` may be slow.

## Dependencies

- Landing 5 follows 1 and 4; landings 6, 7 and 8 go strictly in order.
- Landing 6 needs `UINT8_BYTES_PLAN.md`'s L1, since its natives pass byte
  lists. If it lands before that plan's L2, L2's rotation carries it and
  landing 7 is dropped.
- Landing 8 needs `Bytes` (L3).
- Landing 9's pure modules follow landings 1, 3 and 5; its transport, 8.
- Landing 11 follows 10.

## Release strategy

Each landing is one squashed commit, gated and reviewed on its own. A revert
backs it out; for landing 7, re-pinning the previous seed does.

1. **Analysis without an entry point.**
2. **Comments as lexer output.** Formatter output stays byte-identical.
3. **The lexer keeps its prefix on failure.**
4. **Fixed identities:** the seven types become `fixed`.
5. **Name uses**, always recorded.
6. **Console labels:** builtin labels, runtime and emission, no library.
7. **Seed rotation**, a plain one (the `Path` landing's was `c0512c385`).
8. **The `io/console` functions.**
9. **`blorp lsp`:** the `src/lsp/` modules, the transport, and the README's
   v1 limitation.
10. **The CLion plugin.**
11. **Broken files** served from the last good analysis.

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
| 5 name uses | ≤ +1% | ≤ +0.5% | ≤ +0.5% | ≤ +650 net |
| 6 console labels | ≤ +0.1% | ≤ +0.01% | ≤ +0.1% | ≤ +150 net |
| 8 console functions | ≤ +0.1% | ≤ +0.01% | ≤ +0.1% | ≤ +60 net |
| 9 server | ≤ +3% (more source to compile) | ≤ +3% | ≤ +3% | ≤ +1,700 |
| 11 broken files | ≤ +0.5% (more source to compile) | ≤ +0.5% | ≤ +0.5% | ≤ +300 |

**Latency.** Per request after one change, on this host: ≤ 1.0 s for
`blorp/src/main.brp`, and ≤ 50 ms for a one-module program. Landing 1
reports `analyze`'s one-shot time on `main.brp` as the baseline.

## Measurements

All on this host (macOS, Apple clang), each run serial on a machine other
sessions share. Raw samples are under `blorp/build/lsp-analyze/`,
`blorp/build/lsp-comments/`, `blorp/build/lsp-prefix/` and
`blorp/build/lsp-fixed-identities/` in the main checkout.

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
| 8 | e2e programs through `capture`: LF and CRLF, a last line without LF, header and body in one chunk, a short `read_exact`, a zero count at end of input, bytes that are not UTF-8 through each read, `write` output before a read, `print` and `write` output in order, a write after the reader closes, and `write` imported beside `io/fs/write`'s `write_text`. |
| 9 | `test/test_lsp/`: framing; a body that is not UTF-8; positions for `é`, an astral emoji and `\r`; token splitting; a broken file's lexer tokens; lifecycle errors; staleness after a new import, a late open, a shared file's edit and a close; each request through `receive`. An e2e session in `cli.brp` runs `initialize` through `exit` and checks replies, a diagnostic and the status. |
| 10 | A manual checklist in the plugin's README. |
| 11 | `test/test_lsp/`: edit windows, with positions before, inside and after one, and two distant edits. |

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
