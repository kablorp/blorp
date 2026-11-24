# Language server: `blorp lsp`

**Status: plan, 2026-11-10; Keith settled its decisions and asked for a byte
console on 2026-11-11. Landings 1–16 and 17a have landed. Landing 17,
completion, was planned on 2026-11-23: 17a, names and qualifiers, is done,
and Keith chose a completion hole for 17b, which a spike has tried.**

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
input and output, launched by a minimal editor extension. Keith's priorities
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

**On 2026-11-22:** a trace showed CLion losing answers the server gave, so
Keith dropped the CLion plugin for a VS Code extension ("Let's just go with
pure LSP and VSCode for now"), and asked that no CLion crutches enter the
server. The server implements the LSP specification only.

**On 2026-11-23:** completion, with a probe analysis for a member (landing
17).

**Related plans:** `STRING_PLAN.md` moves byte work to `byte_*` functions,
and the README's naming rules and the library's exact-error convention apply here.

## Proposed solution

### Shape

- **Compiler** (`src/common/`): pure analysis, with no editor state.
- **The `lsp` command** (`src/lsp/`), a command directory like `compile/`:
  - `protocol`: framing, and JSON-RPC to and from `Json`;
  - `positions`: byte offsets to and from LSP positions;
  - `tokens`: semantic-token encoding;
  - `completion`: the site at the cursor and the items it allows (landing
    17);
  - `server`: open documents, one step per message;
  - `lsp_command.brp`: the help text and the transport, the only impure code
    (read, step, analyse or read a closed file's saved text on request,
    write).

  The layer suite (`test/test_layout/test_dependencies.brp`) gains an
  `lsp/` layer that imports itself and `common/`. `main.brp` dispatches
  `lsp` there.
- **VS Code extension** (`editor/vscode/`, landing 14): it starts `blorp lsp`
  through Microsoft's `vscode-languageclient` and adds nothing to the
  protocol. Landings 10 and 12's CLion plugin is gone.
- **The server implements the LSP specification only.** A client's quirk is
  handled in that client's extension or upstream, never in `src/lsp/`.

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

**Declarations outside the inventory.** A built-in type such as `Int` is
declared by `type Int = builtin` in `_base.brp`, which
`ParsedContents.builtin_types` holds rather than the declaration inventory.
Go-to returned `null` for it until landing 16, which joins it to that name.
A module's declaration is the start of its file. A trait's `Self` resolves
to the trait's name.

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
- `didChange` and watched `**/*.brp` changes stale every root that read the
  file, and every root whose load failed, since a missing file may now
  exist.
- `didOpen` and `didClose` stale only the roots that read other text for the
  file than the text it now has, and the failed loads that did not read it as
  that text. An open's text replaces the saved text. A close reverts to the
  saved text, which the transport reads with `read_text`, as a load reads a
  user module; a file it cannot read stales every root that read it. The
  texts compare exactly, against the `SourceInputs` each analysis read.
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
  the decoded path. `didOpen` tells a library file by its scheme, and `targets`
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
From landing 16 a built-in type's is its name in `_base.brp`'s
`type X = builtin`, a `blorp-library:` location.

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
landing has the extension pass the workspace's roots in
`initializationOptions.roots`, and once packages exist a manifest does.

### Completion (landing 17)

**Keith asked on 2026-11-23** for completion, "especially when starting from
blank or after typing `.` after an entity". For a member he chose a probe
(A): analyse a copy of the open text with the unfinished member removed, and
read the receiver's type from the checked body. He rejected answering from
the last good analysis alone (B), which knows a receiver's type only for a
plain name, and error recovery in parser and checker (C), a large project
because each phase stops at its first error.

Landing **17a** completes names and qualifiers from facts the namespace
already publishes. Landing **17b** completes a value's members and the
locals at the cursor through a completion hole, which Keith chose on
2026-11-23 because the cut does not check in most of the places a member is
typed (17b below).

#### The protocol

- `initialize` announces `completionProvider: { triggerCharacters: ["."] }`
  without `resolveProvider`, since every item is complete when sent.
- `textDocument/completion` becomes `CompletionQuery(Position)` of
  `DocumentQuery`, answered like a definition: from the root's analysis,
  analysed first when stale. While the root fails, its last analysis that
  checked answers. `context.triggerKind` is not read, because the text says
  whether a dot comes before the cursor.
- The answer is a `CompletionList` with `isIncomplete: false`. It holds every
  name the site allows, unfiltered, so the client filters as the word grows
  and asks again only at a new word. A site with nothing to offer, a program
  that never checked and a library document get an empty list. A document
  that is not open gets `null`.
- Each item has `label`, `kind`, `sortText`, and a `textEdit` that replaces
  the site's prefix with the label. The specification recommends `textEdit`
  over `insertText`, which a client may reinterpret. `sortText` is a rank,
  then the label, so the order is total. The ranks are 0 for locals (17b), 1
  for the module's own declarations, 2 for its imports and aliases, 3 for the
  prelude's names and 4 for keywords.
- `kind` is the protocol's `CompletionItemKind`:
  - Function for a function;
  - Method for a trait's method, and for every member call;
  - Constant, Field and Keyword for what they name;
  - EnumMember for a variant;
  - Struct for a record, Enum for a union, and Class for an opaque or
    built-in type;
  - Interface for a trait and Module for an alias;
  - Variable for a local or a parameter.
- A member call (17b) inserts the call, since `x.f` without parentheses is a
  field read. It inserts `length()`, or the snippet `get($0)` when the
  function takes more than its receiver and the client sets
  `completionItem.snippetSupport`. Every other name inserts the name alone,
  since a function's name is also a value.
- `detail` is not sent. A type's text needs `render`'s private
  `type_spelling` (`check/render.brp:2210`), which hover needs too, so both
  come with hover.

#### The site, read from the lexer's tokens

The server lexes the editor's text with the analysis's name table, so a name
the analysis knows keeps its id. The site comes from the lexer's output
around the cursor, never from spellings. `completion_site` in the code below
is the rule.

- **Nothing** is offered at these places:
  - inside a comment. Comments are the lexer's separate `comments` list, not
    tokens; a comment's span stops before its LF;
  - inside a string. A quoted string, a char literal and an interpolated
    string's closing quote each close their string, so the cursor at their
    end is outside. Any other piece holds the cursor at its end: an opening
    quote, a text segment, a hole's closing `}`, and a pipe string's line;
  - in a number or at its end;
  - inside an import block: after an `import` at the margin, before the
    Dedent that closes its rows. Import blocks come first in a module
    (`grammar.ebnf:763-764`). Selecting from the imported module is
    auto-import's work;
  - right after a word that declares a new name: `func`, `var`, `for`,
    `record`, `union`, `trait`, `type`, `opaque` or `as`. `for` also starts
    an implementation's type (`implements Trait for Type`), and that gets
    nothing too, since the word alone does not say which form it starts;
  - at or past the first error of a text that does not lex. Before the
    error, the failure's prefix tokens are read as usual.
- **A name:** the prefix is the part before the cursor of the identifier or
  keyword the cursor is in or ends. Otherwise the prefix is empty at the
  cursor. `..` and `...` are their own symbols, so `0..` is a name site, not
  a member.
- **A member:** the token right before the prefix is a `.`. The qualifier is
  the identifier right before the dot, when the dot's `Spacing` is
  `Adjacent`. Newline and Indent are tokens, so a dot that starts the line of
  an indented chain is a member site, and a dot that ends the line above is
  not.
- **Accepted noise.** A name that is being declared with no keyword before it
  gets the name list, since telling these places apart needs the parser:
  - a parameter or a lambda's parameter;
  - a record's field or a union's variant line;
  - a trait method's name or a type parameter;
  - a binding's name before its `=`, and a match arm's capture.

  An annotation's name after `@` gets the list too. A name site also offers
  type names in expression position, and value names in type position.
- **Not offered:** `fixed`, `methods` and `tail_recursive`. The parser
  recognises them by seeded id (`syntax/lex.brp:775-777`); they are not
  keywords. `methods` is written only in an import block, and the other two
  only lead a declaration.

#### 17a: names and qualifiers

**Where names come from.** The namespace already holds every name a module
can write (`module_entries`, `namespace/namespace.brp:1353`):
- its declarations, private ones included;
- its import selections and aliases;
- the names the prelude supplies.

`offer` (`:473`) is the one rule for what a module offers its importers.
`Analysis` drops the namespace today. 17a keeps it, shared as
`declarations` and `builtin_types` are, together with the parsed name table
that spells it. A module's names hold everywhere in it, so they need no
position in the analysed text. While the root fails they come from its last
analysis that checked, and the line diff is not read. No `line_map` query is
added.

**Each entity once.** A scope's `names` are keyed by `space_key`
(`namespace/namespace.brp:347`). `claimed` (`:397`) stores an alias at both
its Values and its Types key, so `module_entries` returns an alias twice. A
new namespace query, `module_names`, lists each entity once: it skips the
entry at an alias's Types key, using `space_key` itself. The namespace owns
`space_key`, so no consumer decodes keys.

Two entries that remain can still share a spelling, as `union Box: Box(Int)`
does. They are two entities, a type and a constructor, and both are listed,
as Enum and EnumMember. So there is one item per label and kind. This
follows from the scope rule, which lets a spelling name at most one entity
in each space. Values become Function, Method, Constant or EnumMember items,
and types become Struct, Enum, Class or Interface items. The two sets share
only Module, which only an alias has. Keywords are never identifiers,
variants are unique within their union, and `offer` never offers an alias.

**What each site offers.**
- **A name:** every entity `module_names` lists for the root. Also the
  keywords of the forms the compiler reads, except `builtin` (the base's
  alone) and the reserved words. `word_kind` (`syntax/lex.brp:779`) is the
  one spelling map, so the server keeps a list of spellings, and a test
  checks that each offered keyword lexes as a keyword. Locals and parameters
  come in 17b.
- **A member whose qualifier the root names as an alias** (`named_value`
  gives `NamedAlias`): what that module offers, through a new
  `offered_entries` that filters `module_names` through `offer`. That
  includes its types and traits, as `alias.Type` is also written in
  annotations. A member site does not know whether it is in a type or an
  expression, so it offers both.
- **A member whose qualifier the root names as a union** (`named_type` gives
  `UnionHead`): its variants, read from the declaration inventory the
  analysis already shares, and ordered by label like every other item.
- **Any other member** gets nothing until 17b: one with no qualifier, or a
  qualifier that names a value, a function or another type.

This distinction comes from name resolution, and it is exact: a qualifier
that the root's scope holds as an alias or a type is never a local.
- A type, a union among them, is CapitalizedCamelCase by its declaration
  role. A local or a parameter is lower_snake_case by its binding-name role
  (`role_style`, `syntax/naming.brp:56`). So no local is spelled like a
  union.
- An alias is lower_snake_case like a local. But it claims its spelling in
  the Values space, and `bind_data` (`check/scope.brp:94`) rejects a local
  whose spelling the module's Values space holds. It finds the alias
  through `value_binding` (`namespace/namespace.brp:1242`), which looks only
  in that space.
- The parser reads `alias.name` the same way: it makes a `ParsedQualified`
  (`syntax/syntax.brp:298`) only for the import block's aliases.

All labels are spelled from one read of the name table, because
`name_spelling` (`syntax/names.brp:254`) copies the table's keys on every
call.

**Rejected:**
- filtering by the prefix in the server, since the client filters a
  complete list;
- answering a stale root without analysing it, which would make 17a's
  answers older than its definitions are.

**Docs.**
- `blorp/README.md`, "The language server", gains a paragraph after
  references. It says that `initialize` announces completion with `.` as
  its trigger, and that completion offers:
  - the names the open file's module can write (its declarations, imports
    and aliases, and the prelude's names) and the keywords, as one complete
    list that the editor filters, each replacing the word before the
    cursor;
  - after `alias.`, the names that module offers, its types and traits
    among them;
  - after `Union.`, its variants.

  The paragraph also says:
  - while the program fails, these names come from its last analysis that
    checked;
  - nothing is offered in a comment, a string, a number or an import block,
    or after a word that declares a new name;
  - other places that declare a name, such as a parameter, get the list
    anyway;
  - until 17b, a value's members and the locals are not offered.
- `editor/vscode/README.md`:
  - the features list gains completion;
  - Known limits drops "Go to Definition on a type built into the language,
    such as `Int`, goes nowhere", which landing 16 fixed, and gains 17a's
    missing locals and members;
  - the test list gains the two completion checks.

**Code.** `AnalysisContents` (`check/check.brp:80`) ends with:

```blorp
    -- The parsed program's own declaration inventory, shared rather than
    -- copied, which joins a referent to its written name.
    declarations: DeclarationInventory,
    -- The base's `type X = builtin` declarations, shared likewise.
    builtin_types: List[ParsedBuiltinDeclaration]
}
```

It gains the namespace and the spelling table, which `analyze_program`
(`:102`) already holds as `namespace` and `parsed.names`. `check` drops both,
as it drops `uses`, so compilation pays only the reference counts of two
shared fields:

```blorp
    builtin_types: List[ParsedBuiltinDeclaration],
    -- Every module's scope, shared: the names each module can write, which an
    -- editor offers.
    namespace: Namespace,
    -- The program's one spelling table, shared. It spells the namespace's
    -- names, and lexes an editor's text to the same ids.
    names: NameTable
}


-- The scopes the analysis resolved names in. Ids live for one analysis.
pure func analysis_namespace(analysis: Analysis) -> Namespace:
    from_opaque Analysis(analysis).namespace


pure func analysis_names(analysis: Analysis) -> NameTable:
    from_opaque Analysis(analysis).names


-- The written names of `union_id`'s variants, in declaration order. The
-- inventory issued the id, so its row is there; `get` is the host's Option.
pure func variant_names(analysis: Analysis, union_id: UnionId) -> List[WrittenName]:
    rows = from_opaque Analysis(analysis).declarations.inventory_unions()
    match rows.get(union_id.union_number()):
        Some(row): row.variants.map(pure func(variant: VariantRow) -> WrittenName: variant.declaration.name)
        None: []
```

The namespace gains two queries beside `module_entries`
(`namespace/namespace.brp:1353`). `module_names` is the dedupe, and the
offer stays `offer`'s. The name table gains a bulk read
(`syntax/names.brp`):

```blorp
-- The module's names, each entity once, in the order they entered. An alias
-- claims its spelling in both spaces (`claimed`) and is listed by its Values
-- entry; a type and a constructor spelled alike are two entities, both listed.
pure func module_names(namespace: Namespace, module: ModuleId) -> List[Entry]:
    scopes: List[ModuleScope] = from_opaque Namespace(namespace)
    var listed: List[Entry] = []
    match scopes.get(module.module_number()):
        Some(scope):
            for (key, entry) in scope.names.entries():
                types_copy: Bool = match entry.entity:
                    Alias(_): key == space_key(Types, entry.name.id)
                    _: False
                if not(types_copy):
                    listed = listed.append(entry)
        None:
            void
    listed


-- What `target` offers its importers, by `offer`: its public declarations,
-- each once, in the order they entered.
pure func offered_entries(namespace: Namespace, target: ModuleId) -> List[Entry]:
    namespace
        .module_names(target)
        .filter(pure func(entry: Entry) -> Bool: offer(Some(entry)).is_ok())


-- Every spelling at its id's position, from one read of the table.
pure func name_spellings(names: NameTable) -> List[String]:
    from_opaque NameTable(names).by_spelling.keys()
```

`DocumentQuery` (`lsp/server.brp:212`) gains a case, which `receive`
(`:366`) builds from `textDocument/completion` the way it builds
`DefinitionQuery`:

```blorp
union DocumentQuery:
    TokensQuery
    DefinitionQuery(Position)
    ReferencesQuery(ReferencesAt)
    -- What may be written at the position.
    CompletionQuery(Position)
```

`initialize_result` (`:520`) adds one capability:

```blorp
        "referencesProvider" => Boolean(True),
        "completionProvider" => Object({ "triggerCharacters" => Array([Text(MEMBER_TRIGGER)]) })
```

```blorp
-- The character after which an editor asks for completion unprompted: the
-- dot before a member.
private MEMBER_TRIGGER: String = "."
```

`served` (`:756`) answers from the editor's text and the analysis that
answers its other queries. `completion.brp` returns data, the prefix and the
items, as `tokens.brp` returns its integers. The server renders the range
with the root's `LineIndex`, which `served` already holds, and with its own
`range_json` (`:1457`), which stays where it is.

`completion_json` is the one `CompletionList` shape. `unanalysed_answer`
(`:823`) answers `completion_json([])`, so no `empty_completion` is needed:

```blorp
        CompletionQuery(at):
            -- A module's names hold everywhere in it, so the editor's own text
            -- gives the site, and no offset goes back through the line diff.
            items: List[Json] = match text.completion(root.index.offset_of(at, session.encoding), analysis):
                Some(offering):
                    range = root.index.range_json(offering.prefix, session.encoding)
                    offering.items.map(pure func(item: Offered) -> Json: item.offered_json(range))
                None:
                    []
            completion_json(items)
```

```blorp
-- The `textDocument/completion` result: a complete list, which the client
-- filters as the word grows.
private pure func completion_json(items: List[Json]) -> Json:
    Object({ "isIncomplete" => Boolean(False), "items" => Array(items) })
```

The new `src/lsp/completion.brp` holds the site and the items. Below is the
sketch the line ceiling counts, after `blorp format`. It leaves out the
6-line module header, the 52 lines of imports and the 2 blank lines after
them. It also packs the keyword list, which the formatter puts one string to
a line (27 lines). `KEYWORD_ITEMS` cannot be
a constant: a constant's initializer must be closed, with no call. So
`completion` maps `OFFERED_KEYWORDS` itself.

```blorp
-- What the editor's text says is being written at the cursor, read from its
-- tokens.
union CompletionSite:
    -- Nothing completes here: in a comment, a string, a number or an import
    -- block, after a word that declares a new name, or at or past where
    -- lexing stopped.
    NoCompletion
    -- A name. The span is the prefix an item replaces: the part before the
    -- cursor of the identifier or keyword the cursor is in or ends, else empty
    -- at the cursor.
    NameSite(Span)
    -- A member, after a `.`.
    MemberSite(MemberAt)


fixed record MemberAt {
    -- The identifier written against the dot's left, if there is one: an
    -- alias, a union or a value, as the namespace says.
    qualifier: Option[WrittenName],
    prefix: Span
}


-- What a site allows: the items, each replacing `prefix`.
record Completion {
    prefix: Span,
    items: List[Offered]
}


-- One item: the label it shows and inserts, its kind and its rank.
record Offered {
    label: String,
    kind: CompletionKind,
    rank: ItemRank
}


-- Where an offered name comes from, nearest first. An item's sortText leads
-- with its rank's digit, then its label, so the order is total.
private union ItemRank:
    DeclaredRank
    ImportedRank
    ProvidedRank
    KeywordRank


private pure func rank_digit(rank: ItemRank) -> String:
    match rank:
        DeclaredRank: "1"
        ImportedRank: "2"
        ProvidedRank: "3"
        KeywordRank: "4"


-- The protocol's CompletionItemKind of each item 17a offers.
private union CompletionKind:
    MethodItem
    FunctionItem
    ClassItem
    InterfaceItem
    ModuleItem
    EnumItem
    KeywordItem
    EnumMemberItem
    ConstantItem
    StructItem


-- Each kind's number in LSP 3.17.
private pure func kind_number(kind: CompletionKind) -> Int:
    match kind:
        MethodItem: 2
        FunctionItem: 3
        ClassItem: 7
        InterfaceItem: 8
        ModuleItem: 9
        EnumItem: 13
        KeywordItem: 14
        EnumMemberItem: 20
        ConstantItem: 21
        StructItem: 22


-- The keywords of the forms the compiler reads, as a writer spells them; not
-- `builtin`, which only the base writes, nor the words the lexer reserves for
-- forms it does not read. `word_kind` is the one spelling map: a test checks
-- that each lexes as a keyword. `fixed`, `methods` and `tail_recursive` are
-- names the parser recognises by seeded id, not keywords, and are not offered.
private OFFERED_KEYWORDS: List[String] = [
    "as", "break", "continue", "else", "for", "from_opaque", "func", "if", "implements",
    "import", "in", "into_opaque", "match", "opaque", "private", "pure", "record", "resource",
    "scoped", "trait", "type", "union", "var", "void", "while"
]


-- What may be written at `offset` of `text`, the root as the editor shows it,
-- from `analysis`, the root's latest analysis that checked. None where nothing
-- completes.
pure func completion(text: String, offset: Int, analysis: Analysis) -> Option[Completion]:
    namespace = analysis.analysis_namespace()
    names = analysis.analysis_names()
    -- Spelled once: `name_spelling` copies the table's keys per call.
    spellings = names.name_spellings()
    root = root_module_id()
    match text.completion_site(names, offset):
        NoCompletion:
            None
        NameSite(prefix):
            keywords = OFFERED_KEYWORDS.map(
                pure func(word: String) -> Offered: {
                    label = word,
                    kind = KeywordItem,
                    rank = KeywordRank
                }
            )
            Some({
                prefix = prefix,
                items = namespace
                    .module_names(root)
                    .scope_items(spellings)
                    .concat(keywords)
            })
        MemberSite(member):
            items: List[Offered] = match member.qualifier:
                Some(qualifier):
                    match namespace.named_value(root, qualifier.id):
                        Some(NamedAlias(aliased)):
                            namespace
                                .offered_entries(aliased.target)
                                .scope_items(spellings)
                        _:
                            named: Option[TypeHead] = namespace
                                .named_type(root, qualifier.id)
                                .map(pure func(found: NamedType) -> TypeHead: found.head)
                            match named:
                                Some(UnionHead(id)):
                                    analysis
                                        .variant_names(id)
                                        .variant_items(spellings)
                                -- A value, a function or another type.
                                _:
                                    []
                -- A value's members come in 17b.
                None:
                    []
            Some({ prefix = member.prefix, items = items })


-- The site at `offset`, from the tokens `names` lexes `text` to. `names` is
-- the analysis's table, so a qualifier the analysis knows keeps its id.
pure func completion_site(text: String, names: NameTable, offset: Int) -> CompletionSite:
    source = module_source(root_module_id())
    -- A text that does not lex keeps the tokens before its first error, which
    -- say nothing about what follows it.
    (lexed, stopped) = match lex(source, text, names):
        Ok(whole): (whole, None)
        Err(failure): (failure.prefix, Some(failure.error.span.start))
    tokens = lexed.tokens
    -- How many tokens start before the cursor: the last of them is the one the
    -- cursor is in or follows.
    var reached = 0
    for token in tokens:
        if token.span.start >= offset:
            break
        reached = reached + 1
    beyond: Bool = match stopped:
        Some(start): offset >= start
        None: False
    -- Comments are not tokens; a comment's span stops before its LF.
    commented = lexed.comments.any(
        pure func(comment: Comment) -> Bool: and(
            comment.span.start < offset,
            offset <= comment.span.end
        )
    )
    if or(or(beyond, commented), tokens.in_import_block(reached)):
        NoCompletion
    else:
        empty: Span = { source = source, start = offset, end = offset }
        match tokens.get(reached - 1):
            None:
                NameSite(empty)
            Some(last):
                if last.span.end < offset:
                    -- A space or a line break separates the cursor from `last`.
                    tokens.site_after(reached - 1, empty)
                else:
                    match last.kind:
                        IdentifierToken(_, _) | KeywordToken(_):
                            tokens.site_after(reached - 2, { last.span | end = offset })
                        IntegerLiteral(_) | FloatLiteral(_):
                            NoCompletion
                        _:
                            if last.in_string(offset):
                                NoCompletion
                            else:
                                -- A symbol, such as `.`, `..` or `${`, or a closing
                                -- quote, ends at the cursor.
                                tokens.site_after(reached - 1, empty)


-- The site whose prefix is `prefix`, when `tokens[index]` is written right
-- before it: a member after a dot, nothing after a word that declares a new
-- name, else a name. Newline, Indent and Dedent are tokens, so a dot that ends
-- the line above is not right before the prefix.
private pure func site_after(tokens: List[Token], index: Int, prefix: Span) -> CompletionSite:
    match tokens.get(index):
        None:
            NameSite(prefix)
        Some(written):
            match written.kind:
                SymbolToken(Dot):
                    qualifier: Option[WrittenName] = match tokens.get(index - 1):
                        Some(left):
                            match (left.kind, written.spacing):
                                (IdentifierToken(id, _), Adjacent):
                                    Some({ id = id, span = left.span })
                                _:
                                    None
                        None:
                            None
                    MemberSite({ qualifier = qualifier, prefix = prefix })
                KeywordToken(FunctionKeyword | VarKeyword | ForKeyword | RecordKeyword | UnionKeyword | TraitKeyword | TypeKeyword | OpaqueKeyword | AsKeyword):
                    NoCompletion
                _:
                    NameSite(prefix)


-- Whether `offset` is inside the string `token` is a piece of. A piece that
-- closes its string ends before the cursor at its end; any other piece,
-- including a hole's closing brace, holds the cursor at its end.
private pure func in_string(token: Token, offset: Int) -> Bool:
    after_start = token.span.start < offset
    match token.kind:
        QuotedString(_) | StringEnd | CharLiteral:
            and(after_start, offset < token.span.end)
        PipeString(_) | StringStart(_) | StringSegment(_) | InterpolationClose:
            and(after_start, offset <= token.span.end)
        _:
            False


-- Whether the first `reached` tokens end inside an import block: after an
-- `import` at the margin, before the Dedent that closes its rows. Import
-- blocks come first (`grammar.ebnf:763`); a block the text never closes runs
-- to its end.
private pure func in_import_block(tokens: List[Token], reached: Int) -> Bool:
    var depth = 0
    var inside = False
    for position in 0..reached:
        match tokens.get(position):
            Some(token):
                match token.kind:
                    KeywordToken(ImportKeyword):
                        if depth == 0:
                            inside = True
                    SymbolToken(Indent):
                        depth = depth + 1
                    SymbolToken(Dedent):
                        depth = depth - 1
                        if depth == 0:
                            inside = False
                    _:
                        void
            None:
                void
    inside


-- An item for each entry, spelled from `spellings`, the analysis's names by id.
-- `module_names` and `offered_entries` list each entity once, and a spelling
-- names at most one entity per space, so each label and kind is one item.
private pure func scope_items(entries: List[Entry], spellings: List[String]) -> List[Offered]:
    var items: List[Offered] = []
    for entry in entries:
        match spellings.get(entry.name.id.name_number()):
            Some(label):
                items = items.append({
                    label = label,
                    kind = entry.entity.entity_kind(),
                    rank = entry.origin.origin_rank()
                })
            -- The table issued the id, so its spelling is there.
            None:
                void
    items


-- An item for each of a union's variants.
private pure func variant_items(
    variants: List[WrittenName],
    spellings: List[String]
) -> List[Offered]:
    var items: List[Offered] = []
    for variant in variants:
        match spellings.get(variant.id.name_number()):
            Some(label):
                items = items.append({ label = label, kind = EnumMemberItem, rank = DeclaredRank })
            None:
                void
    items


private pure func entity_kind(entity: Entity) -> CompletionKind:
    match entity:
        Function(_): FunctionItem
        Method(_): MethodItem
        Constant(_): ConstantItem
        Constructor(_): EnumMemberItem
        Type(RecordHead(_)): StructItem
        Type(UnionHead(_)): EnumItem
        Type(OpaqueHead(_) | PrimitiveHead(_) | ListHead): ClassItem
        Trait(_): InterfaceItem
        Alias(_): ModuleItem


private pure func origin_rank(origin: Origin) -> ItemRank:
    match origin:
        Declared(_): DeclaredRank
        Imported: ImportedRank
        Implicit: ProvidedRank


-- The protocol's CompletionItem for `item`, replacing the text at `range`.
pure func offered_json(item: Offered, range: Json) -> Json:
    Object(
        {
            "label" => Text(item.label),
            "kind" => Number(integer(item.kind.kind_number())),
            "sortText" => Text("${item.rank.rank_digit()}${item.label}"),
            "textEdit" => Object({ "range" => range, "newText" => Text(item.label) })
        }
    )
```

#### 17b: a value's members and the locals at the cursor

**What the cut meets.** Checking stops at its first error, so a probe
answers only if its text checks. The cut puts the receiver where the
member's value was, and most places constrain that value. Each row below is
a small program with the cut already applied, compiled by an `-O2` build of
main from 2026-11-22:

| Where the member is typed | After the cut | Result |
| --- | --- | --- |
| the last line of a Void function | `name` | checks |
| a statement in the middle of a body | `name` | `expression statement must return Void` |
| bound without annotation, unused so far | `n = items` | checks |
| bound, then used | `n = items` then `n + 1` | `argument type does not match the parameter type` |
| bound with an annotation | `n: Int = items` | `expression does not match the expected type` |
| a typed function's result | `name` in `-> Int` | `expression does not match the expected type` |
| an argument | `size(items)` | `argument type does not match the parameter type` |
| an `if` condition | `if items:` | `condition must have the designated Bool type` |
| a `match` scrutinee | `match items:` | `pattern does not match the value's type` |
| a typed lambda's result | `x` in `-> Int` | `expression does not match the expected type` |
| a `for` iterable | `for x in items:` | checks |
| interpolated | `"${name}"`, `"${items}"` | checks for a `String`; for a `List[Int]`, `interpolation hole has type List[Int], which does not implement Stringable` |

`_ = name` is not a statement either (`expected a return expression`). So
the cut fails on a new line in the middle of a body, which is the most common
place to type `name.`. It also fails in typed results, arguments, conditions
and `match` scrutinees. This is why Keith chose option 2 on 2026-11-23,
"starting with a spike".

The same programs with `.zzz()` in place of the cut show what a probe can
rely on. The mid-body statement, the typed result, the condition, the
scrutinee, the lambda's result and a chained call as an argument each fail
first with `no method zzz for String is in scope` or `... for List[Int] ...`.
The checker reaches a receiver's member before it compares the member's
value with its place.

**Option 1: the cut, as Keith chose it.** The probe text is the editor's
text without the bytes from the dot's start to the prefix's end. The loader
takes it as the root's snapshot, unchanged.
- **The receiver** is the innermost `CheckedExpr` of the root whose span
  ends at the cut. An enclosing expression that also ends there, such as
  `total + name`, starts earlier. No expression ends there when the receiver
  is a parenthesized group (`(a + b).`), since Check does not see groups.
- **Its candidates** come from the root's receiver scope, which `Analysis`
  would have to keep. Today the scopes end with body checking
  (`check/model.brp:29`). A new
  check query applies `admits` (`check/inference.brp:2221`) to a complete
  type, which is the fitting rule `choose_receiver` (`:2360`) uses.
- **Locals** need to know where each binding is visible, and nothing records
  that today. There are two ways:
  - check records an extent in each `BindingDefinition`
    (`check/model.brp:958`). That is one fact at the phase that owns scope,
    but every compile pays for it;
  - the server walks `CheckedFunctionBody` and derives the scope rule again.
    That is a second authority for matches, loops and captures, so it is
    rejected.
- **A line being written** is not in the root's last checked analysis, so
  `line_map` would need an insertion point. The end of the previous
  unchanged line can sit in a block the new line has left by its
  indentation, so the query would need the cursor's indentation too.

It answers in 3 of the table's 12 rows, and in a fourth when the
interpolated value is Stringable.

**Option 2: a completion hole (recommended).** The probe keeps the editor's
text and names the prefix's span as the hole.
- **Lexing** turns the hole into one `HoleToken` in place of the prefix, so
  no later phase reads a position.
- **Parsing** accepts the hole where it requires a name today: as an
  expression's base (`NameHole`) and as a member after a value
  (`MemberHole`, at `consume_postfix`, `syntax/parse.brp:1865`).
- **Checking** checks the body that holds the hole first. When it reaches
  the hole it stops with what it knows there:
  - the bindings a read at the hole would accept, which is its own `scope`
    (`check/scope.brp:44`) without an enclosing body's mutable bindings
    inside a lambda, since a read there rejects them;
  - for a member hole: the receiver's type as far as it is known; the names
    in the module's receiver scope that have a function whose receiver
    parameter admits it, by `choose_receiver`'s rule without the name; the
    trait methods the type implements; and a record's fields.

It should answer in every row of the table. The `.zzz()` programs show the
checker reaching the member before the member's place in six of the rows,
and the spike checks the others. `join` is offered on a `List[String]` and
not on a `List[Int]`. The probe
checks the signatures and only one body, and that body only up to the hole,
so it may cost less than an analysis; a spike measures it. Locals come from
the checker's own scope, so it needs no binding extents, no walk in the
server and no `line_map` query.

It fails only when checking stops before the hole: a load or declaration
error, or an error earlier in the same body. Then a name site falls back to
17a, and a member site offers nothing.

It is not error recovery. No phase continues past an error, and the hole is
a site the caller names, which compilation never does. Lean 4 is the
closest precedent: its elaborator records completion information at the
cursor (a dot's receiver and the local context) for the server to read.
GHC's typed holes report a hole's type and the bindings in scope, and
Merlin types its recovery holes at any type.

It adds a mechanism to lex, parse and check, and to the loader's root
snapshot, so `blorp/AGENTS.md` requires Keith's approval. One question
remains open inside it: how checking stops at the hole. The cheapest way is
one more `CheckError` case, `HoleReached(CompletionFacts)`. Only
`analyze_completion` unwraps it, and `render` reports it as a checker
invariant, since compilation never lexes a hole. The alternative threads a
probe result through every checking function's return type.

**Rejected: a member that cannot resolve.** Writing a call such as `.zzz()`
in place of the prefix reaches `NoApplicableMethod`, whose
`MissingMethod.receiver` (`check/errors.brp:119`) is the receiver's type, in
each of the six places tested. But it reads a fact out of a failure, and it
depends on that
error being the first one checking reports. It also needs a name that no
function can have. A member must be lower_snake (`syntax/parse.brp:1865`),
so no spelling is guaranteed never to resolve.

**What both options share.** A completion probe never disturbs the root. It
is a fourth `Followup`, and the server answers its result without storing
anything. The root keeps its analysis, its staleness and its published
diagnostics, because the probe's text is not the document's. `Followup`
(`lsp/server.brp:246`) gains:

```blorp
    -- Analyse a completion probe of an open root, with every other open
    -- document as it is, and hand the result to `probed`.
    Probe(ProbeRequest)


-- A completion request that waits for its probe: the root, the request, and
-- what the probe analyses in place of the root's text (option 1: the cut
-- text; option 2: the text and its hole) with the prefix its items replace.
record ProbeRequest {
    root: Path,
    id: RequestId,
    probe: CompletionProbe
}


-- Answers `asked` from `result` and changes nothing else.
pure func probed(server: Server, asked: ProbeRequest, result: ProbeResult) -> Step
```

`perform` (`lsp/lsp_command.brp:120`) gains its fourth arm. It is the only
impure part of the probe:

```blorp
        Probe(request):
            step.server
                .probed(request, request.probe.probe_result(step.server.snapshots()))
                .perform()
```

Under option 2, the syntax (`syntax/syntax.brp:214`, `:365`, `:415`) and
check's boundary gain:

```blorp
union TokenKind:
    ...
    -- Where an editor asks what may be written. Only lexing that is given a
    -- hole makes one, in place of the prefix; compilation never does.
    HoleToken

union ExpressionBase:
    ...
    NameHole(Span)

union PostfixOperation:
    ...
    MemberHole(Span)
```

```blorp
-- What checking knew at the hole, with the scopes that spell it.
record CompletionFacts {
    visible: List[VisibleBinding],
    member: Option[MemberFacts],
    namespace: Namespace,
    names: NameTable
}


pure func analyze_completion(program: ParsedProgram) -> Result[CompletionFacts, CheckFailure]
```

With option 2, a completion request on the root probes and never analyses
the root. A name site takes its locals and module names from the probe,
which removes 17a's analysis of a stale root at each new word. A member
call's snippet needs `completionItem.snippetSupport`, which `initialize`
reads into the session, as it reads `refreshSupport`.

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
answers it. A close needs the file's saved text, which the transport reads
and hands to `reverted`:

```blorp
-- src/lsp/server.brp
union Followup:
    Idle
    -- The root to analyse, and the request that waits for it, if any.
    Analyse(AnalysisRequest)
    -- The closed document whose saved text to read.
    ReadSaved(Path)

record Step {
    server: Server,
    replies: List[Json],
    followup: Followup
}

pure func receive(server: Server, message: Json) -> Step

pure func analysed(server: Server, asked: AnalysisRequest, result: DocumentAnalysis) -> Step

-- None when the saved text could not be read.
pure func reverted(server: Server, path: Path, saved: Option[String]) -> Step
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

**Not:** hover, signature help, rename, formatting through the server,
TextMate, threads, incremental analysis, or grammar changes. Landing 17 also
leaves out snippets beyond a call's parentheses, completion inside library
files, auto-import, and error recovery in the parser or checker.

**Concurrent work:** of the String plan's breaking switch and this work, whichever lands second migrates
the other's `length` and `slice` uses.

## Risks and unknowns

- **A client without LSP 3.18's `workspace/textDocumentContent`** gets no
  library locations. VS Code's client has it from 11.0.1.
- **Completion after an edit analyses the root first in 17a**, as a
  definition does. VS Code asks once at each new word, so typing in
  `main.brp` costs about one analysis per word, about 340 ms at `-O2`.
  Option 2 of 17b replaces that analysis with the probe.

## Dependencies

- Landing 11 follows 10, 13 follows 12, since only LSP4IJ opened a
  `blorp-library:` file then, and 14 follows 13.
- 17b follows 17a. Option 2 adds a mechanism to lex, parse and check, which
  Keith approved on 2026-11-23 with a spike first, which sets its line
  ceiling.

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
10. **The CLion plugin**, removed in 14.
11. **Broken files** served from the last good analysis.
12. **The plugin on LSP4IJ** (Keith, 2026-11-21), removed in 14.
13. **Library files through `workspace/textDocumentContent`**, and plain
    `Location`s.
14. **VS Code** (Keith, 2026-11-22), in two commits: the server accepts a
    library URI without its empty authority, the form VS Code writes; then
    `editor/vscode/` replaces `editor/intellij/`.
15. **Unchanged opens and closes** stale no program. A close reads the saved
    text (Keith, 2026-11-22).
16. **Built-in type definitions:** definition on `Int`, `String` or `List`
    answers its `type X = builtin` line in `_base.brp`. A follow-up commit
    has `render`'s import notes reuse `referent_declaration` (Keith,
    2026-11-23).
17. **Completion** (Keith, 2026-11-23), in two landings. 17a reads only
    facts the namespace already publishes and changes no checking. 17b adds a
    probe analysis and the transport's fourth followup, and with option 2 a
    mechanism in three phases. Each is useful and reviewable alone.
    - **17a, names and qualifiers:** `completionProvider`, the root's names
      and keywords, `alias.` and `Union.`. It also fixes the VS Code README's
      stale limit on built-in types, which landing 16 removed.
    - **17b, a value's members and the locals at the cursor,** through a
      completion hole (Keith, 2026-11-23).

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
| 12 the plugin on LSP4IJ | not compiled | not compiled | not compiled | ≤ 570 Kotlin and XML |
| 13 library files, fixed input | ≤ +0.1% (noise) | no increase | no increase | ≤ −40 net |
| 14 VS Code, fixed input | ≤ +0.1% (noise) | no increase | no increase | ≤ +20 net in `blorp/src`; ≤ 150 JavaScript and JSON |
| 15 unchanged opens and closes, fixed input | ≤ +0.1% | ≤ +0.1% | not set | not set |
| 16 built-in type definitions, fixed input | ≤ +0.3% | ≤ +0.3% | not set | not set |
| 16 follow-up, notes reuse `referent_declaration`, fixed input | ≤ +0.1%, C identical | ≤ +0.1% | not set | ≤ −90 net |
| 17a names and qualifiers, fixed input | ≤ +0.1%, C identical | no increase | no increase | ≤ +590 net, from a 512-line sketch |
| 17b members and locals, fixed input | set with the option; option 2 ≤ +0.1%, C identical | option 2 no increase | option 2 no increase | from a spike |

**17a's line ceiling** comes from its sketch, written out in full with
comments, blank lines and imports. `completion.brp` was run through
`blorp format`, which parsed it and laid it out; the sketch was not compiled.
It counts 512 lines:
- the new `completion.brp`, 416:
  - header and imports, 60;
  - the site's types, 22;
  - the item types, ranks and kinds, 60;
  - the keyword list, 34;
  - `completion`, 52;
  - the site (`completion_site`, `site_after`, `in_string` and
    `in_import_block`), 122;
  - the items (`scope_items`, `variant_items`, `entity_kind`, `origin_rank`
    and `offered_json`), 65;
- `server.brp`, 34: the query and its request, the capability and its
  constant, the `served` arm, the `unanalysed_answer` arm, and
  `completion_json`;
- `check.brp`, 29: imports, two fields and three queries;
- `namespace.brp`, 28: `module_names` and `offered_entries`;
- `names.brp`, 5: `name_spellings`.

The ceiling, ≤ +590 net, leaves about 15% for what a sketch misses.
Exceeding it stops the landing for a growth audit, and the coordinator then
decides whether to cut, accept or rescope the landing.

**Option 2's sketch** for 17b is about +300 in the compiler (lexing 25,
parsing 40, syntax 15, the loader 25, assembly 15, checking 150, `render` 10,
`check.brp` 20) and about +250 in the server, before a spike.

**Latency.** Per request after one change, on this host: ≤ 1.0 s for
`blorp/src/main.brp`, and ≤ 50 ms for a one-module program. Landing 1
reports `analyze`'s one-shot time on `main.brp` as the baseline. A completion
is held to the same limits, and also to ≤ 50 ms on a current analysis of
`blorp/src/common/syntax/parse.brp`, the largest compiler file, which it
lexes in full.

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
Landing 12 moved it to LSP4IJ, which removed the workarounds below.
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

**Landing 12, the plugin on LSP4IJ** (against `0cdfe13ae`). Keith chose LSP4IJ
0.30.1 (Red Hat, EPL-2.0) on 2026-11-21, after a spike. On CLion's own LSP API
the plugin needed three workarounds, and CLion's C/C++ engine wraps the
shortcuts that later features need.

- **What changed.**
  - The plugin depends on `com.redhat.devtools.lsp4ij`, which users install
    from the Marketplace, and defines one server and a language mapping.
  - The token-type, Go to Declaration and integration workarounds are gone.
    Colours go through LSP4IJ's colours provider, with the same keys.
  - A path change restarts the server through LSP4IJ's forced restart, which
    waits for the stop; a stop then a start would race.
- **Lexer.**
  - LSP4IJ takes the word from the element before the caret, unless that is
    whitespace or one punctuation character. So a hole's `$`, `{` and `}` are
    one-character tokens; with landing 10's lexer, a name at a hole's start
    targets `"${`.
  - The hole state is a sealed type, encoded in the lexer's state, and every
    lexer input relexes from any token start as a full pass does.
- **Keith's run of the spike.**
  - Passed: colours, Cmd-click and Cmd-B into the library, diagnostics and
    scratch files.
  - Cmd-click on a declaration's own name still finds nothing.
  - Alt+F7 lists no usages, though it did on landing 10.
  - Neither failure reproduces headlessly, even with CLion's own plugins
    loaded, where Find Usages lists every usage. The plugin README gives both
    as known limits, and Keith's next run checks Alt+F7 with the new lexer.
- **Tests.**
  - 39 Gradle tests, which pass against landing 11's server.
  - One of them runs the repository's server: Go to Declaration under the
    C/C++ engine's action id, LSP4IJ's usage search from a name in a hole at
    exact offsets, and a restart on a path change.
- **Ceiling.** 500 was set from the spike's 465. It is corrected to 570 under
  the standing delegation: +30 for the hole tokens, and +32 for the sealed
  hole state that review asked for. Tests are 581 lines.
- **Review.** 0 blockers, 2 majors, 3 minors and 3 nits, all fixed.

**Landing 13, library files without a folder** (against `631ab9a73`).
`self-compile-cost`, `-O2`, 3 rounds, on the final commit:

| Measure | Base | Candidate | Change |
| --- | ---: | ---: | ---: |
| Fixed input, allocations | 12,974,188 | 12,974,188 | unchanged |
| Fixed input, instructions (median) | 13,098,442,619 | 13,096,379,489 | −0.016% |
| Fixed input, peak heap (requested bytes) | 184,295,479 | 184,295,479 | unchanged |
| Own source, allocations | 12,974,188 | 12,918,138 | −0.43% |
| Own source, instructions (median) | 13,077,544,943 | 13,011,081,202 | −0.51% |
| Own source, peak heap (requested bytes) | 184,295,478 | 183,699,955 | −0.32% |
| Lines, production | | | −56 net |

- **What changed.**
  - A library location is a `blorp-library:` URI of the file's path below the
    library root.
  - `workspace/textDocumentContent` answers the embedded text by exact lookup.
    It has two -32602 messages: not a `blorp-library:` URI, and no such file.
  - The scheme is announced only when the client's
    `workspace.textDocumentContent` is present; without it, library entries
    are left out.
  - The folder, its shutdown order (`LeavingLibrary`, `ShutdownAnswer`), the
    second layout and the `LocationLink` code are gone. `shutdown` replies at
    once, and a definition is a plain `Location`.
  - A `DocumentUri` union keeps user and library documents apart. A library
    document gets lexer tokens, and its edits are dropped, since its editor is
    read-only.
  - This retires 9c's open folder items (the `/tmp` link, and folders left by
    killed sessions) and the server fixes' known gap, where a failed removal
    lost the `shutdown` reply.
- **LSP4IJ.** Checked first, headlessly, in milestone 1: it fetches the text,
  opens the file read-only as Blorp, sends `didOpen` under that URI, and gets
  tokens. Its own highlighting pass asking for them is checked by hand in
  CLion.
- **Ceiling.**
  - The sketch of −80 predates the spike, which measured the URI and content
    handling at +153.
  - The first pass came to +2, because the coordinator over-specified typed
    URI errors and path checks that the exact lookup makes redundant. Cut
    back, it came to −56.
  - The ceiling is corrected to −40 under the standing delegation.
- **Tests.**
  - The URI pair; the exact `initialize` reply with and without the
    capability; and the content request's text and both errors, including
    `..`, `.` and empty paths.
  - Library locations, and a client that cannot fetch them; a library
    document's tokens and its dropped edits; and `shutdown` at once.
  - An e2e session, and the plugin's `blorp-library:` target.
  - Each oracle was proven by mutation.
- **Review.** 0 blockers, 1 major (a dead `library_path`), 3 minors and 2
  nits, all fixed.

**Landing 14, VS Code** (against `9e7e19dd5`). Keith chose it on 2026-11-22.

- **The CLion trace.** A wrapper recorded the traffic between CLion and the
  server:
  - The server answered every request correctly, and the faults were CLion's.
  - LSP4IJ 0.30.1 fetched a library file and sent `didOpen`, but never asked
    for its tokens. That is LSP4IJ issue 2026, fixed for its unreleased 0.30.2.
  - Find Usages sent `textDocument/references`, and the server answered the
    declaration and both uses. CLion's Find window showed only the
    declaration.
- **The spike** ran the installed VS Code 1.135 against the server, and all
  eight checks passed once one server bug was fixed. VS Code writes
  `blorp-library:///io/x.brp` as `blorp-library:/io/x.brp`, which the decoder
  refused. RFC 3986 lets a scheme say whether an empty authority matters, and
  this one now says it does not.
- **Lines.**
  - `blorp/src`: +28 −10, net +18 against a ceiling of +20. Tests: +12.
  - The extension: 147 lines of JavaScript and JSON against a ceiling of 150.
    Tests: 224 lines, plus a 7-line fixture.
  - `editor/intellij/`'s 27 files and 1,857 lines are deleted.
- **Cost** of the server commit, `self-compile-cost --rounds 3`:

  | Row | Allocations | Peak heap | Instructions |
  | --- | --- | --- | --- |
  | fixed input | +0.0000% | +0.0000% | +0.0246% |
  | own source | +0.0177% | +0.0111% | +0.1535% |

  The fixed-input C is identical.
- **Latency** of one cross-file definition in `blorp/src/main.brp`:

  | Step | `-O0` | `-O2` |
  | --- | --- | --- |
  | first definition | 3,087 ms | 344 ms |
  | a definition after `compile_command.brp` opens | 5,603 ms | 589 ms |
  | any other request | ≤ 17 ms | ≤ 2 ms |

  The default build is `-O0`, so the extension's README asks for `-O2`. An
  open whose text is unchanged still stales the programs that read the file.
  That is a separate change.
- **Review.** No blockers. The minors and nits are fixed: the restart is
  serialized and survives a failed start, which a ninth check now covers, and
  the oracles are exact.
- **A flake.** One run of the VS Code test in five failed. Every request on
  `main.brp` answered nothing, though diagnostics arrived. Four runs passed,
  two of them right after. If it recurs, trace that run.

**Landing 15, unchanged opens and closes** (against `a21669be2`).
`self-compile-cost`, `-O2`, 3 rounds, on the final commit:

| Measure | Base | Candidate | Change |
| --- | ---: | ---: | ---: |
| Fixed input, allocations | 12,984,954 | 12,984,954 | unchanged |
| Fixed input, instructions (median) | 13,082,029,241 | 13,087,465,399 | +0.042% |
| Fixed input, peak heap (requested bytes) | 184,334,939 | 184,334,939 | unchanged |
| Own source, allocations | 12,984,954 | 12,993,723 | +0.068% |
| Own source, instructions (median) | 13,080,950,473 | 13,080,857,561 | −0.001% |
| Own source, peak heap (requested bytes) | 184,334,938 | 184,422,154 | +0.047% |
| Lines, production and tests | | | +103 and +315 net |

The fixed-input C is identical (`add626b105c49f1f`), so the instruction
change is noise. Own source grows with the lines it compiles.

- **Why.** An editor opens a file after a jump to a definition there, with
  the text on the disk, and closes it unedited. Each stale-marked every
  program that read the file, so the importer was analysed again in full.
- **What changed.**
  - `didOpen` and `didClose` stale only the roots that read other text for
    the file than the text it now has, compared exactly against the
    `SourceInputs` each analysis read. Edits and watched changes stale as
    before.
  - `didClose` carries no text, so its step asks the transport to read the
    saved text (`Followup.ReadSaved`), with `read_text`, as a load reads a
    user module. `reverted` then closes the document. An unreadable file
    stales every root that read it. Keith approved this read as a new
    mechanism on 2026-11-22.
  - A step's work for the transport is one union, `Followup` (`Idle`,
    `Analyse`, `ReadSaved`), not an optional analysis beside an optional
    read.
  - A sealed analysis notes a file only when it read other text for it, so
    an unchanged close keeps answers into the file.
- **Latency** at `-O2`, `latency.py` with a close step added, 3 runs each,
  macOS ARM64, binaries linked from the `blorp/build/blorp.c` of `9e7e19dd5`
  and of this change before its rebase onto `a21669be2`, whose URI change the
  script does not reach:

  | Step, in `blorp/src/main.brp` | Base | Candidate |
  | --- | ---: | ---: |
  | First definition (open and analyse) | 320–324 ms | 322–329 ms |
  | Definition after opening `compile_command.brp` unedited | 595–598 ms | 279–281 ms |
  | Definition after closing it unedited | 318–324 ms | 1 ms |

  The step after the open is now `compile_command.brp`'s own analysis,
  which alone takes 280–282 ms.

- **Tests.** `test/test_lsp/`: an open or a close as the text a root read
  stales none of them, for a checked root, a rejected one and a failed load;
  other text stales them; an unreadable close stales every reader; no
  refresh goes when nothing went stale; an unchanged close keeps answers into
  the closed file; a close of a document not open is dropped. An e2e session
  in `cli.brp` opens and closes an imported file on the disk and counts the
  importer's publications. Each oracle was
  proven by mutation: nine in `server.brp`, run one at a time, and one in
  the transport, which the e2e session catches. The session also fails
  against `9e7e19dd5`.
- **Found, not fixed.**
  - Edits are still not compared, as briefed: an edit back to the text a
    root read stales it.
  - When the client spells an opened file's URI differently from
    `file_uri(path)`, the current importers' diagnostics in it stay under
    the server's spelling until they are next analysed. `didClose` already
    republishes under the server's spelling; an open could do the reverse.
- **Review.** 0 blockers, 0 majors, 3 minors and 3 nits. Fixed: the
  load-failed comparison reuses `reads_otherwise`; `reverted` says why its
  other states cannot arrive; a close of a document that is not open is
  dropped without a read. Kept: `noted` repeats the check `staled` made, as
  it did before, and `supplied` stays an `Option`, whose None means one
  thing, that every reader is affected.

**Landing 16, built-in type definitions** (against `e65b646b5`).
`self-compile-cost`, `-O2`, 3 rounds, ceiling +0.3% on the fixed-input
allocations and instructions. Raw samples are under
`blorp/build/self-compile-cost/e65b646b5-cf09e38a3/`.

| Measure | Base | Candidate | Change |
| --- | ---: | ---: | ---: |
| Fixed input, allocations | 12,993,723 | 12,993,723 | unchanged |
| Fixed input, instructions (median) | 13,062,109,166 | 13,056,188,294 | −0.045% |
| Fixed input, peak heap (requested bytes) | 184,421,650 | 184,421,650 | unchanged |
| Own source, allocations | 12,993,723 | 12,981,492 | −0.094% |
| Own source, instructions (median) | 13,063,202,061 | 13,043,384,211 | −0.152% |
| Own source, peak heap (requested bytes) | 184,421,649 | 184,245,154 | −0.096% |
| Lines, production and tests | | | +15 and +94 net |

The fixed-input C is identical (`0cd7de0ab1d61716`), so the instruction
change is noise.

- **Why.** Cmd-click on `List` or `String` in VS Code did nothing.
  Definition answered `null` on a built-in type, since `Analysis` kept no
  span for the base's `type X = builtin` declarations, though
  `ParsedContents.builtin_types` held them.
- **What changed.**
  - `Analysis` shares `builtin_types` with the parsed program, and
    `referent_declaration` joins a built-in head to its name through
    `builtin_declaration` in `namespace`, which `render`'s notes now share
    in place of their own loop.
  - With every written name declared, two special cases go. `references`
    no longer groups an undeclared referent by identity, so a defect
    answers `[]`. `tokens`' `library_declared` drops its built-in case:
    `_base.brp` is a library file.
  - References with `includeDeclaration` lead with the `_base.brp`
    declaration, as for any type. `declarations()` still leaves built-in
    types out: only the base declares them, and it is never a root.
- **Tests.** `test/test_lsp/`: definition of `Int` is its `_base.brp`
  location; references list it only when asked; a client that cannot
  fetch library files gets `null`. `test_name_uses.brp`: `Int`, `Float`,
  `List`, `String` and `Void` each resolve to their own declaration, and
  every built-in use renders its declaration. Each new oracle failed
  before the change and was proven by mutation, one at a time: a lookup
  that ignores the head, one that finds nothing, a zero-width span, the
  declaration always or last in references, and library locations for
  every client.
- **Review.** 0 blockers, 0 majors, 2 minors and 1 nit. Fixed: the
  non-fetching client's `null` and `Float` and `Void` are now tested; the
  README names the definition a library location. The nit, that
  `defaultLibrary` on built-ins now follows the declaration span, is
  covered by `test_tokens.brp`, which fails when the lookup finds nothing.
- **Follow-up.** `check/render.brp`'s entity `declaration_span` repeated
  `referent_declaration` case by case; the follow-up below removes it.

**Landing 16 follow-up, import notes reuse `referent_declaration`**
(against `3d7bbe195`). Keith approved it on 2026-11-23 after an
investigation. Ceilings: fixed-input allocations and instructions ≤ +0.1%
with the C identical, production lines ≤ −90 net. `self-compile-cost`,
`-O2`, 7 rounds on an idle machine. Raw samples are under
`blorp/build/self-compile-cost/3d7bbe195-606eeb492-r7/`.

| Measure | Base | Candidate | Change |
| --- | ---: | ---: | ---: |
| Fixed input, allocations | 12,981,492 | 12,981,492 | unchanged |
| Fixed input, instructions (median) | 13,043,946,794 | 13,055,475,952 | +0.088% |
| Fixed input, peak heap (requested bytes) | 184,244,653 | 184,244,653 | unchanged |
| Own source, allocations | 12,981,492 | 12,963,961 | −0.135% |
| Own source, instructions (median) | 13,044,616,007 | 13,040,212,610 | −0.034% |
| Own source, peak heap (requested bytes) | 184,244,652 | 184,074,401 | −0.092% |
| Lines, production and tests | | | −98 and +35 net |

The fixed-input C is identical (`acb3355377d8451a`). A first run of 3
rounds read +0.204% while an e2e run shared the machine; the base's own 7
rounds spread 0.12%. On the success path only `resolved_name_use` changed,
now calling `entity_referent`, a small switch.

- **Why.** The note on "X is imported by M, not declared there" found X's
  declaration with its own 106-line `declaration_span` in `render.brp`, one
  arm per entity, the same lookups `referent_declaration` makes.
- **What changed.** `name_uses.brp` gains `entity_referent`, taken out of
  `resolved_name_use`. The note's one caller asks
  `entity.entity_referent().referent_declaration(…)`, passing no checked
  functions or lambdas, which only a binding needs: no entity is one. A
  narrower lookup by entity was weighed and dropped: it would only move the
  empty lists, or make `referent_declaration` answer `None` for bindings.
- **What the old code guarded.**
  - Its fault for a trait method without a header cannot fire.
    `issue_inventory` issues each default method with its body's row, and
    `build_namespace` runs `declared_entries`, which rejects a missing
    header as `InvalidTraitInventory`, before any selection resolves; a
    `Method` entry exists only when its header was found.
  - Its `Alias` arm was dead: `offer` reports an alias as an unknown name,
    so `ImportedThere` never holds one.
- **Output.** Probe programs that select, from a module that imports it, a
  required trait method, a default one, a record and an alias give
  byte-identical diagnostics before and after; the first three keep their
  `note: declared here` at the declaring module.
- **Test.** A surface e2e case, `a module does not reexport an imported
  trait method`, pins the note at the method's header name. Mapping a
  method to its trait in `entity_referent` fails it and no other case.
- **Review.** 0 blockers, majors or minors; all four claims above
  confirmed. Taken: the comment at the call names `declared_entries`'s
  guarantee, and the trait method case above.

**Landing 17a, completion of names and qualifiers** (against `0af133ca1`).
`self-compile-cost`, `-O2`, 3 rounds, on a machine other sessions share.
Ceilings: fixed-input instructions ≤ +0.1% with the C identical, no increase
in allocations or peak heap, production lines ≤ +590 net. Raw samples are
under `blorp/build/self-compile-cost/0af133ca1-22b15d0e7/`, the log is
`blorp/build/self-compile-cost-17a.log`.

| Measure | Base | Candidate | Change |
| --- | ---: | ---: | ---: |
| Fixed input, allocations | 12,963,961 | 12,963,961 | unchanged |
| Fixed input, instructions (median) | 13,079,086,279 | 13,064,834,146 | −0.109% |
| Fixed input, peak heap (requested bytes) | 184,078,076 | 184,078,076 | unchanged |
| Own source, allocations | 12,963,961 | 13,041,693 | +0.600% |
| Own source, instructions (median) | 13,072,314,118 | 13,131,097,197 | +0.450% |
| Own source, peak heap (requested bytes) | 184,078,075 | 184,847,932 | +0.418% |
| Lines, production and tests | | | +538 and +899 net |

The fixed-input C is identical (`5eaf5a758c1277e3`), so the instruction
change is noise. The own-source row grows with the 538 new lines and is
reported, not held.

- **Lines.** Production: `completion.brp` 433, `server.brp` +37, `check.brp`
  +34, `namespace.brp` +29, `names.brp` +5. The sketch counted 416 for
  `completion.brp`. Tests: `test_completion.brp` 645, `test_server.brp`
  +253, the driver's list +1.
- **Latency** at `-O2` (`blorp/build/blorp` linked with
  `TEST_COMPILER_FLAGS=-O2`), a fresh `blorp lsp` per run, 3 runs each,
  from `didOpen` to the reply (`blorp/build/lsp-completion/completion_latency.py`;
  log `blorp/build/lsp-completion/latency.log`). The first completion waits
  for the analysis the open staled:

  | Program, cursor at a body's first line | First | Current analysis | Ceiling |
  | --- | ---: | ---: | --- |
  | one module (`editor/vscode/test/fixture/completion.brp`), 57 items | 6.0–13.4 ms | 0.3–0.6 ms | 50 ms |
  | `blorp/src/main.brp`, 80 items | 318–331 ms | 0.3–0.8 ms | 1.0 s |
  | `blorp/src/common/syntax/parse.brp`, 785 items | 45–48 ms | 5.1–5.5 ms | 50 ms (current) |

- **What changed.** As designed: `Analysis` shares the namespace and the
  name table; `module_names` lists each entity once and `offered_entries`
  filters it through `offer`; `completion.brp` reads the site from the
  lexer's tokens and returns data; the server renders ranges.
- **Deviations from the sketch.** All found by compiling it.
  - `ItemRank` and `CompletionKind` are public, because `Offered` is public
    and holds them.
  - `MemberAt` is a plain `record`: a `fixed record` field must be inline,
    and `Option[WrittenName]` is not.
  - `completion_site` binds the lexer's result once, as a typed tuple,
    since `None` needs its union type.
  - `in_import_block` also treats a cursor past the last row's line break,
    with enough Dedents next to close it to its opening depth, as outside the block, at any nesting. The lexer makes that
    Dedent at the next code line, so a blank line after the block, or the
    margin of the next declaration, counted as inside and offered nothing.
    A new row typed at the end of the block, with code after it, gets the
    name list: accepted noise.
- **Tests.** `test_completion.brp`: 27 cases for the sites and the items;
  `test_server.brp`: ten from real analyses; the `initialize` replies in
  `test_server.brp` and `cli.brp`; two VS Code checks in `suite.js`. Mutations,
  one at a time, each failing only its own tests: no member site after a dot
  (8 completion and server cases about a dot), an alias's Types copy kept
  (the once-only and repeat cases), an alias target's imports offered (the
  alias cases), a range that ends at the token's end (the cursor-inside-a-name
  cases) and a hole's `}` closing its string (the hole case). Logs:
  `blorp/build/mutation-*.log`.

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
| 14 | `test/test_lsp/`: a library URI without its empty authority names the same file, and one with an authority names none. `npm test` in `editor/vscode/` runs the installed VS Code against the repository's server: colours in a user file and a library file, Go to Definition locally and into the library, the library text, Find All References, a declaration's own definition, and a diagnostic. |
| 15 | `test/test_lsp/`: an open or close as the text a root read stales none of them, other text and an unreadable close stale them, no refresh goes for an unchanged open or close, and an unchanged close keeps answers into the file. An e2e session in `cli.brp` opens and closes an imported file on the disk. |
| 16 | `test/test_lsp/`: definition on `Int` is its library location, references list its declaration only on request, and without the capability definition is `null`. `test_name_uses`: `Int`, `Float`, `List`, `String` and `Void` each resolve to their own declaration. |
| 16 follow-up | No oracle changes. A surface e2e case pins the note for an imported trait method, beside the `Box` one for a union. |
| 17a | `test/test_lsp/test_completion.brp`, a new suite, which must be added to the `private COMPONENT_SOURCES` list in `blorp/test/driver/driver.brp` (a full run fails on a suite it does not list; the Makefile's `TARGET_COMPONENT_SOURCES` only picks suites to run). Each site: a blank line; a partial name; a cursor inside a name; a comment; inside a quoted string and at its closing quote; after a hole's `}` in a string; a hole in a string; a number; an import block's row, and the first line after the block; `func `, `var ` and `for `; a text that stops lexing before and after the cursor; `"abc".`; `alias.`; `Union.Va`; an indented chain's `.ma`; a dot that ends the line above; `0..`. `test_server.brp`, from real analyses: the exact `initialize` reply. A name site lists a declared function, a private one, an imported one, `print`, a constant, a record, a union and its variant, a trait and the keywords, each with its kind and rank. Each item that is a keyword lexes as one, and `detach` and `builtin` are not offered. An alias is listed once, as a Module. `union Box: Box(Int)` lists `Box` twice, as an Enum and as an EnumMember. The `textEdit` range is correct in UTF-8, and in UTF-16 after an `é`. `alias.` lists the module's public names, its types among them, but not its private names or its imports; `Option.` lists `None` and `Some`; `Int.` and a value's dot list nothing. A failing root answers from its last checked analysis; a root that never checked and a library document get `[]`; a stale root is analysed first. Mutations: drop the dot test; keep an alias's Types copy; offer an alias target's imports; end the range at the token's end; treat a hole's `}` as closing its string. Each fails only its own tests. `editor/vscode`: completion on a blank line of a body lists `helper`, `print` and `match`, and after `Option.` it lists `None` and `Some`. |
| 17b | Each row of the cut table lists the receiver's members. `join` is offered on a `List[String]` and not on a `List[Int]`. A record's fields come as fields and its functions as calls, with the snippet only for a client that sets `snippetSupport`. A trait method the receiver implements is offered. Locals: a parameter; an earlier local but not a later one; a match capture only inside its arm; a `for` item only inside its loop; inside a lambda, its parameters and the enclosing immutable bindings but not mutable ones. A probe leaves the root's analysis, staleness and diagnostics as they were. When a probe fails before the hole, a name site falls back and a member site offers nothing. An e2e session in `cli.brp` carries a probe through the transport. `editor/vscode`: `name.` typed on a new line in the middle of a body lists `length`. |

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
- [ ] **14.** In VS Code a file is coloured; Cmd-click on `print` opens the
  library file read-only and coloured; Find All References lists every use;
  and Cmd-click on a declaration lists its references.
- [ ] **15.** A Cmd-click into another file and back analyses neither
  program again.
- [ ] **16.** Cmd-click on `String` opens `_base.brp` at its declaration.
- [ ] **17a.** This command passes, and each listed mutation fails only its
  own tests:
  `make -C blorp test-target-components TARGET_COMPONENT_SOURCES="blorp/test/test_lsp/test_completion.brp blorp/test/test_lsp/test_server.brp"`.
  `cd editor/vscode && npm test` reports PASS for both completion checks.
  `blorp/scripts/self-compile-cost` with `--rounds 3` meets 17a's row, with
  the fixed-input C identical, and completion latency is within its
  ceilings. In VS Code, Ctrl+Space on a blank line of a body lists the
  file's functions, `print` and `match`, and `Option.` lists its variants.
- [ ] **17b.** In VS Code, typing `name.` lists the receiver's members in
  each of these places: a new line in the middle of a body, a typed
  function's result, an argument, an `if` condition and a `match`
  scrutinee. `join` is offered on a `List[String]` and not on a
  `List[Int]`. Ctrl+Space lists the parameters and the locals declared above
  the cursor. 17b's tests pass, and its row's ceilings are met.
- [ ] **Every landing** meets its ceilings, passes `make -C blorp test`, and
  is reviewed and test-run.

## Handback

Each landing returns its commit, evidence per criterion, measurements with
raw-sample paths, and anything found but not fixed.

Stop and ask if:
- a ceiling is exceeded;
- the editor shows no colour;
- a name use needs information the checker has discarded;
- the console errors conflict with `UINT8_BYTES_PLAN.md`;
- 17b's probe gives no receiver in a row of the cut table.

Console API changes go to Keith.
