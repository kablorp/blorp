# Language server: `blorp lsp`

**Status: plan, 2026-11-10, revised the same day; Keith settled its open
decisions on 2026-11-11. Next: landing 1.**

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

**On 2026-11-11:** CLion first; `read_exact` returns `Bytes`, since a byte
count can end inside a character; name uses always recorded, with no spike;
and broken files served from the last good analysis, after the plugin. The
console names and flushing await approval at landing 8.

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
- **Each phase reports only its first error.**

**Related plans:** `STRING_PLAN.md` moves byte work to `byte_*` functions,
and `PATH_PLAN.md`'s naming and exact-error rules apply here.

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

  The layer suite (`test/unit/test_layout/test_dependencies.brp`) gains an
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
Check's identities. Import selections name only declarations, which `namespace` resolves (`import_row`,
`namespace/namespace.brp:1058`) but keeps no spans for. It gains a table of
each selection's span and entity, which `check` turns into uses.

**Inline rows.** `NameUse` is a `fixed record` over a `fixed union`, so rows
take no allocation each. Seven plain types become `fixed`, which they
already qualify for: `TypeHead` and `PrimitiveType` in `namespace/`, and
`TypeParameterIdentity`, `TypeParameterOwner`, `ScopedBindingId`,
`BodyOwner` and `AggregateId` in `check/model.brp`. `FieldId` gains the
`Equatable` that `Referent`'s `==` needs.

**Across analyses**, the server compares a declaration's path and byte
range, never ids or `SourceId`s.

**Rejected:** copying the declaration's span into each row (the first
draft), a kind tag, and re-resolving names in the server. Each duplicates a
fact the compiler owns, and copies can disagree.

### The console

`io/console` keeps `print` and `print_error`, and gains:

- `write` and `write_error`, which write text as given;
- `flush`;
- `read_line`;
- `read_exact(byte_count)`.

**Flushing.** Every read flushes standard output first, as Python's `input`
does, so a prompt shows before the program waits. `flush` covers output that
no read follows.

**`read_line`** drops LF or CRLF, as `fold_lines` does. A last line without
LF is returned as is.

**`read_exact`** returns `Bytes`: `None` only when input has already ended,
empty for a count of zero or less, and an error when input ends part-way.
The server decodes a body with `bytes.to_text`, answering -32700 for
invalid UTF-8. A line that is not UTF-8 is a `read_line` error. Both reads
share one buffer, and each has its own exact error union, per
`PATH_PLAN.md`.

**Rejected:** `print(text, ending = "")` (named optional arguments),
dropping `print`'s newline (breaks every call), and `read_bytes(n)` (clashes
with `fs.read_bytes`).

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

**Diagnostics** refresh when an analysis runs, so an edit's errors appear
with the next request. Each analysis publishes to every file it reports in,
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
successful analysis sealed, with each file's text then. A file's
edits since form one window, between the longest common prefix and the
longest non-overlapping common suffix. Positions before it are unchanged,
positions after shift by the change in length, and positions inside find
nothing; two distant edits make one wide window. A request's position maps
back through its file's window, and each answer span forward through its
own file's.

**Definition** returns the declaration of the use at the position, or
`null`. A position at an identifier's end counts as inside it.

**References** returns every use with that referent. It includes the
declaration only on request.

**Lifecycle.** `shutdown` returns `null`. `exit` ends with status 0 after
`shutdown` and 1 otherwise, as does end of input without `exit`. Requests
before `initialize` get -32002, unknown requests -32601, invalid JSON
-32700. Unknown notifications and cancellations are ignored.

### v1 limitation: the open file is the root

Go-to and references cover the open file's program: the file, its imports
and the library. References from importers are missed: asked in
`common/syntax/lex.brp`, references to `lex` miss
`common/analysis/load/load.brp:582`. The README documents this. A later
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
(`FunctionReferent`). The declarations of `check` and `program` come from
the function table and `check`'s `bindings`.

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
-- Exactly `byte_count` bytes; None once input has ended; empty for a count
-- of zero or less; an error if input ends part-way.
func read_exact(byte_count: Int) -> Result[Option[Bytes], ReadExactError]
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
so coordinate before our landings 6 and 8; its L3 adds `Bytes`. Of the
String plan's breaking switch and this work, whichever lands second migrates
the other's `length` and `slice` uses.

## Risks and unknowns

- **Recording cost.** Every compile records name uses; landing 5 measures
  the cost.
- **Do semantic tokens alone colour a file in CLion?** The plugin landing
  probes it first with a stub server, with `null` and error replies too. If
  nothing colours, stop and ask.
- **Bootstrap.** A library call to a `builtin` label the seed lacks stops
  the seed parsing the library (`common/syntax/parse.brp:4708`). So the
  console labels land alone, a rotation follows, and then the library.
- **Latency.** Analysing `blorp/src/main.brp` may be slow.

## Dependencies

- Landing 5 follows 1 and 4; landings 6, 7 and 8 go strictly in order.
- Landing 8 needs `Bytes` (`UINT8_BYTES_PLAN.md`'s L3), and Keith's approval
  of the names and of reads flushing.
- Landing 9's pure modules follow landings 1, 3 and 5; its transport, 8.
- Landing 11 follows 10.

## Release strategy

Each landing is one squashed commit, gated and reviewed on its own. A revert
backs it out; for landing 7, re-pinning the previous seed does.

1. **Analysis without an entry point.**
2. **Comments as lexer output.** Formatter output stays byte-identical.
3. **The lexer keeps its prefix on failure.**
4. **Fixed identities:** the seven types become `fixed`, with matched
   before/after measurements, as a data-model refactor requires.
5. **Name uses**, always recorded.
6. **Console labels:** builtin labels, runtime and emission, no library.
7. **Seed rotation**, a plain one (`PATH_PLAN.md`'s landed as `c0512c385`).
8. **The `io/console` functions**, after ergonomics review and Keith's
   approval.
9. **`blorp lsp`:** the `src/lsp/` modules (buildable during landings 6
   to 8), the transport, and the README's v1 limitation.
10. **The CLion plugin.**
11. **Broken files** served from the last good analysis.

**Ceilings** are against the parent commit, as a stage-2 self-compile
unless stated, with test lines counted apart. Compile cost must also fit the
e2e instruction ceilings' 15% margin.

| Landing | Instructions | Allocations | Peak heap | Production lines |
| --- | --- | --- | --- | --- |
| 1 analysis | ≤ +0.2% | ≤ +0.05% | ≤ +0.1% | ≤ +80 net |
| 2 comments | ≤ +0.5%, and formatting the repository ≤ +0.5% | ≤ +0.3% | ≤ +0.3% | ≤ +60 net |
| 3 prefix | ≤ +0.1% | ≤ +0.01% | ≤ +0.1% | ≤ +60 net |
| 4 fixed identities | ≤ +0.1% | no increase | ≤ +0.1% | ≤ +20 net |
| 5 name uses | ≤ +1% | ≤ +0.5% | ≤ +0.5% | ≤ +650 net |
| 6 console labels | ≤ +0.1% | ≤ +0.01% | ≤ +0.1% | ≤ +150 net |
| 8 console functions | ≤ +0.1% | ≤ +0.01% | ≤ +0.1% | ≤ +60 net |
| 9 server | ≤ +3% (more source to compile) | ≤ +3% | ≤ +3% | ≤ +1,700 |
| 11 broken files | ≤ +0.5% (more source to compile) | ≤ +0.5% | ≤ +0.5% | ≤ +300 |

**Latency.** Per request after one change, on this host: ≤ 1.0 s for
`blorp/src/main.brp`, and ≤ 50 ms for a one-module program. Landing 1
reports `analyze`'s one-shot time on `main.brp` as the baseline.

## Testing

Each landing starts with a failing test.

| Landing | Tests |
| --- | --- |
| 1 | `test_common/test_analysis/test_check/`: a module without `main` analyses, and `check` reports `MissingMain` with exact message, help and span. A malformed `main` fails both. |
| 2 | `test_common/test_syntax/test_lex/`: one case per comment site. Formatter suites and the formatted repository are unchanged. |
| 3 | An unclosed string keeps the tokens before it and drops its own. The loader's diagnostic is unchanged. |
| 4 | Existing suites, unchanged. |
| 5 | One case per `Referent` case, checking the use's span and, through `declaration_span`, its declaration's. Mutation proof: stop recording one case, and only its test fails. |
| 6 | Direct C tests of the natives, under `test/runtime/`. |
| 8 | e2e programs through `capture`: LF and CRLF, a last line without LF, header and body in one chunk, a short `read_exact`, a zero count, input that is not UTF-8 to each read, and `write` output before a read. |
| 9 | `test/unit/test_lsp/`: framing; a body that is not UTF-8; positions for `é`, an astral emoji and `\r`; token splitting; a broken file's lexer tokens; lifecycle errors; staleness after a new import, a late open, a shared file's edit and a close; each request through `receive`. An e2e session in `self_hosted_cli.brp` runs `initialize` through `exit` and checks replies, a diagnostic and the status. |
| 10 | A manual checklist in the plugin's README. |
| 11 | `test/unit/test_lsp/`: edit windows, with positions before, inside and after one, and two distant edits. |

**Commands:** `make -C blorp test-target-components
TARGET_COMPONENT_SOURCES=<suite>` to iterate; then `make -C blorp test`;
`scripts/blorp-fixpoint --prove` for compiler landings; and `make -C blorp
test-e2e INSTRUCTION_CHECK=on` when compile cost changes.

## Acceptance criteria

- [ ] **1.** A module without `main` analyses, and `blorp compile` of it
  prints the unchanged `MissingMain`.
- [ ] **2.** `make -C blorp format-check` passes, formatter expectations are
  unchanged, and only the lexer recognises comments.
- [ ] **4.** Output identity holds on the e2e fixtures, and the
  measurements are recorded.
- [ ] **5.** Every `Referent` case passes, and the measurements are in
  `benchmarks/results/`.
- [ ] **7.** `scripts/blorp-fixpoint --prove` passes with the new seed.
- [ ] **8.** The console e2e programs pass on all four CI platforms, and
  `read_exact` returns bytes that are not UTF-8 unchanged.
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
